# encoding: UTF-8

# --
# Copyright (C) 2008-2010 10gen Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
# ++

require 'set'
require 'socket'
require 'thread'

module Mongo

  # Instantiates and manages connections to MongoDB.
  class Connection

    # Abort connections if a ConnectionError is raised.
    Thread.abort_on_exception = true

    DEFAULT_PORT = 27017
    STANDARD_HEADER_SIZE = 16
    RESPONSE_HEADER_SIZE = 20

    MONGODB_URI_MATCHER = /(([.\w\d]+):([\w\d]+)@)?([.\w\d]+)(:([\w\d]+))?(\/([-\d\w]+))?/
    MONGODB_URI_SPEC = "mongodb://[username:password@]host1[:port1][,host2[:port2],...[,hostN[:portN]]][/database]"

    attr_reader :logger, :size, :host, :port, :nodes, :auths, :sockets, :checked_out

    # Counter for generating unique request ids.
    @@current_request_id = 0

    # Create a connection to MongoDB. Specify either one or a pair of servers,
    # along with a maximum connection pool size and timeout.
    #
    # If connecting to just one server, you may specify whether connection to slave is permitted.
    # In all cases, the default host is "localhost" and the default port is 27017.
    #
    # To specify a pair, use Connection.paired.
    #
    # Note that there are a few issues when using connection pooling with Ruby 1.9 on Windows. These
    # should be resolved in the next release.
    #
    # @param [String, Hash] host.
    # @param [Integer] port specify a port number here if only one host is being specified.
    #
    # @option options [Boolean] :slave_ok (false) Must be set to +true+ when connecting
    #   to a single, slave node.
    # @option options [Logger, #debug] :logger (nil) Logger instance to receive driver operation log.
    # @option options [Integer] :pool_size (1) The maximum number of socket connections that can be opened to the database.
    # @option options [Float] :timeout (5.0) When all of the connections to the pool are checked out,
    #   this is the number of seconds to wait for a new connection to be released before throwing an exception.
    #
    # @example localhost, 27017
    #   Connection.new
    #
    # @example localhost, 27017
    #   Connection.new("localhost")
    #
    # @example localhost, 3000, max 5 connections, with max 5 seconds of wait time.
    #   Connection.new("localhost", 3000, :pool_size => 5, :timeout => 5)
    #
    # @example localhost, 3000, where this node may be a slave
    #   Connection.new("localhost", 3000, :slave_ok => true)
    #
    # @see http://www.mongodb.org/display/DOCS/Replica+Pairs+in+Ruby Replica pairs in Ruby
    #
    # @core connections
    def initialize(host=nil, port=nil, options={})
      @auths        = []

      if block_given?
        @nodes = yield self
      else
        @nodes = format_pair(host, port)
      end

      # Host and port of current master.
      @host = @port = nil

      # Lock for request ids.
      @id_lock = Mutex.new

      # Pool size and timeout.
      @size      = options[:pool_size] || 1
      @timeout   = options[:timeout]   || 5.0

      # Mutex for synchronizing pool access
      @connection_mutex = Mutex.new
      @safe_mutex = Mutex.new

      # Condition variable for signal and wait
      @queue = ConditionVariable.new

      @sockets      = []
      @checked_out  = []

      # slave_ok can be true only if one node is specified
      @slave_ok = options[:slave_ok] && @nodes.length == 1
      @logger   = options[:logger] || nil
      @options  = options

      should_connect = options[:connect].nil? ? true : options[:connect]
      connect_to_master if should_connect
    end

    # Initialize a paired connection to MongoDB.
    #
    # @param nodes [Array] An array of arrays, each of which specified a host and port.
    # @param opts Takes the same options as Connection.new
    #
    # @example
    #   Connection.paired([["db1.example.com", 27017],
    #                   ["db2.example.com", 27017]])
    #
    # @example
    #   Connection.paired([["db1.example.com", 27017],
    #                   ["db2.example.com", 27017]],
    #                   :pool_size => 20, :timeout => 5)
    #
    # @return [Mongo::Connection]
    def self.paired(nodes, opts={})
      unless nodes.length == 2 && nodes.all? {|n| n.is_a? Array}
        raise MongoArgumentError, "Connection.paired requires that exactly two nodes be specified."
      end
      # Block returns an array, the first element being an array of nodes and the second an array
      # of authorizations for the database.
      new(nil, nil, opts) do |con|
        [con.pair_val_to_connection(nodes[0]), con.pair_val_to_connection(nodes[1])]
      end
    end

    # Initialize a connection to MongoDB using the MongoDB URI spec:
    #
    # @param uri [String]
    #   A string of the format mongodb://[username:password@]host1[:port1][,host2[:port2],...[,hostN[:portN]]][/database]
    #
    # @param opts Any of the options available for Connection.new
    #
    # @return [Mongo::Connection]
    def self.from_uri(uri, opts={})
      new(nil, nil, opts) do |con|
        con.parse_uri(uri)
      end
    end

    # Apply each of the saved database authentications.
    #
    # @return [Boolean] returns true if authentications exist and succeeed, false
    #   if none exists.
    #
    # @raise [AuthenticationError] raises an exception if any one
    #   authentication fails.
    def apply_saved_authentication
      return false if @auths.empty?
      @auths.each do |auth|
        self[auth['db_name']].authenticate(auth['username'], auth['password'], false)
      end
      true
    end

    # Save an authentication to this connection. When connecting,
    # the connection will attempt to re-authenticate on every db
    # specificed in the list of auths. This method is called automatically
    # by DB#authenticate.
    #
    # Note: this method will not actually issue an authentication command. To do that,
    # either run Connection#apply_saved_authentication or DB#authenticate.
    #
    # @param [String] db_name
    # @param [String] username
    # @param [String] password
    #
    # @return [Hash] a hash representing the authentication just added.
    def add_auth(db_name, username, password)
      remove_auth(db_name)
      auth = {}
      auth['db_name']  = db_name
      auth['username'] = username
      auth['password'] = password
      @auths << auth
      auth
    end

    # Remove a saved authentication for this connection.
    #
    # @param [String] db_name
    #
    # @return [Boolean]
    def remove_auth(db_name)
      return unless @auths
      if @auths.reject! { |a| a['db_name'] == db_name }
        true
      else
        false
      end
    end

    # Remove all authenication information stored in this connection.
    #
    # @return [true] this operation return true because it always succeeds.
    def clear_auths
      @auths = []
      true
    end

    # Return a hash with all database names
    # and their respective sizes on disk.
    #
    # @return [Hash]
    def database_info
      doc = self['admin'].command({:listDatabases => 1})
      returning({}) do |info|
        doc['databases'].each { |db| info[db['name']] = db['sizeOnDisk'].to_i }
      end
    end

    # Return an array of database names.
    #
    # @return [Array]
    def database_names
      database_info.keys
    end

    # Return a database with the given name.
    # See DB#new for valid options hash parameters.
    #
    # @param [String] db_name a valid database name.
    #
    # @return [Mongo::DB]
    #
    # @core databases db-instance_method
    def db(db_name, options={})
      DB.new(db_name, self, options.merge(:logger => @logger))
    end

    # Shortcut for returning a database. Use DB#db to accept options.
    #
    # @param [String] db_name a valid database name.
    #
    # @return [Mongo::DB]
    #
    # @core databases []-instance_method
    def [](db_name)
      DB.new(db_name, self, :logger => @logger)
    end

    # Drop a database.
    #
    # @param [String] name name of an existing database.
    def drop_database(name)
      self[name].command(:dropDatabase => 1)
    end

    # Copy the database +from+ to +to+ on localhost. The +from+ database is
    # assumed to be on localhost, but an alternate host can be specified.
    #
    # @param [String] from name of the database to copy from.
    # @param [String] to name of the database to copy to.
    # @param [String] from_host host of the 'from' database.
    # @param [String] username username for authentication against from_db (>=1.3.x).
    # @param [String] password password for authentication against from_db (>=1.3.x).
    def copy_database(from, to, from_host="localhost", username=nil, password=nil)
      oh = BSON::OrderedHash.new
      oh[:copydb]   = 1
      oh[:fromhost] = from_host
      oh[:fromdb]   = from
      oh[:todb]     = to
      if username || password
        unless username && password
          raise MongoArgumentError, "Both username and password must be supplied for authentication."
        end
        nonce_cmd = BSON::OrderedHash.new
        nonce_cmd[:copydbgetnonce] = 1
        nonce_cmd[:fromhost] = from_host
        result = self["admin"].command(nonce_cmd)
        oh[:nonce] = result["nonce"]
        oh[:username] = username
        oh[:key] = Mongo::Support.auth_key(username, password, oh[:nonce])
      end
      self["admin"].command(oh)
    end

    # Increment and return the next available request id.
    #
    # return [Integer]
    def get_request_id
      request_id = ''
      @id_lock.synchronize do
        request_id = @@current_request_id += 1
      end
      request_id
    end

    # Get the build information for the current connection.
    #
    # @return [Hash]
    def server_info
      self["admin"].command({:buildinfo => 1})
    end

    # Get the build version of the current server.
    #
    # @return [Mongo::ServerVersion]
    #   object allowing easy comparability of version.
    def server_version
      ServerVersion.new(server_info["version"])
    end

    # Is it okay to connect to a slave?
    #
    # @return [Boolean]
    def slave_ok?
      @slave_ok
    end


    ## Connections and pooling ##

    # Send a message to MongoDB, adding the necessary headers.
    #
    # @param [Integer] operation a MongoDB opcode.
    # @param [BSON::ByteBuffer] message a message to send to the database.
    # @param [String] log_message text version of +message+ for logging.
    #
    # @return [True]
    def send_message(operation, message, log_message=nil)
      @logger.debug("  MONGODB #{log_message || message}") if @logger
      begin
        packed_message = add_message_headers(operation, message).to_s
        socket = checkout
        send_message_on_socket(packed_message, socket)
      ensure
        checkin(socket)
      end
    end

    # Sends a message to the database, waits for a response, and raises
    # an exception if the operation has failed.
    #
    # @param [Integer] operation a MongoDB opcode.
    # @param [BSON::ByteBuffer] message a message to send to the database.
    # @param [String] db_name the name of the database. used on call to get_last_error.
    # @param [String] log_message text version of +message+ for logging.
    # @param [Hash] last_error_params parameters to be sent to getLastError. See DB#error for
    #   available options.
    #
    # @see DB#error for valid last error params.
    #
    # @return [Array]
    #   An array whose indexes include [0] documents returned, [1] number of document received,
    #   and [3] a cursor_id.
    def send_message_with_safe_check(operation, message, db_name, log_message=nil, last_error_params=false)
      message_with_headers = add_message_headers(operation, message)
      message_with_check   = last_error_message(db_name, last_error_params)
      @logger.debug("  MONGODB #{log_message || message}") if @logger
      begin
        sock = checkout
        packed_message = message_with_headers.append!(message_with_check).to_s
        docs = num_received = cursor_id = ''
        @safe_mutex.synchronize do
          send_message_on_socket(packed_message, sock)
          docs, num_received, cursor_id = receive(sock)
        end
      ensure
        checkin(sock)
      end
      if num_received == 1 && (error = docs[0]['err'] || docs[0]['errmsg'])
        raise Mongo::OperationFailure, error
      end
      [docs, num_received, cursor_id]
    end

    # Sends a message to the database and waits for the response.
    #
    # @param [Integer] operation a MongoDB opcode.
    # @param [BSON::ByteBuffer] message a message to send to the database.
    # @param [String] log_message text version of +message+ for logging.
    # @param [Socket] socket a socket to use in lieu of checking out a new one.
    #
    # @return [Array]
    #   An array whose indexes include [0] documents returned, [1] number of document received,
    #   and [3] a cursor_id.
    def receive_message(operation, message, log_message=nil, socket=nil)
      packed_message = add_message_headers(operation, message).to_s
      @logger.debug("  MONGODB #{log_message || message}") if @logger
      begin
        sock = socket || checkout

        result = ''
        @safe_mutex.synchronize do
          send_message_on_socket(packed_message, sock)
          result = receive(sock)
        end
      ensure
        checkin(sock)
      end
      result
    end

    # Create a new socket and attempt to connect to master.
    # If successful, sets host and port to master and returns the socket.
    #
    # @raise [ConnectionFailure] if unable to connect to any host or port.
    def connect_to_master
      close
      @host = @port = nil
      for node_pair in @nodes
        host, port = *node_pair
        begin
          socket = TCPSocket.new(host, port)
          socket.setsockopt(Socket::IPPROTO_TCP, Socket::TCP_NODELAY, 1)

          # If we're connected to master, set the @host and @port
          result = self['admin'].command({:ismaster => 1}, :check_response => false, :sock => socket)
          if result['ok'] == 1 && ((is_master = result['ismaster'] == 1) || @slave_ok)
            @host, @port = host, port
            apply_saved_authentication
          end

          # Note: slave_ok can be true only when connecting to a single node.
          if @nodes.length == 1 && !is_master && !@slave_ok
            raise ConfigurationError, "Trying to connect directly to slave; " +
              "if this is what you want, specify :slave_ok => true."
          end

          break if is_master || @slave_ok
        rescue SocketError, SystemCallError, IOError => ex
          socket.close if socket
          close
          false
        end
      end
      raise ConnectionFailure, "failed to connect to any given host:port" unless socket
    end

    # Are we connected to MongoDB? This is determined by checking whether
    # host and port have values, since they're set to nil on calls to #close.
    def connected?
      @host && @port
    end

    # Close the connection to the database.
    def close
      @sockets.each do |sock|
        sock.close
      end
      @host = @port = nil
      @sockets.clear
      @checked_out.clear
    end

    ## Configuration helper methods

    # Returns an array of host-port pairs.
    #
    # @private
    def format_pair(pair_or_host, port)
      case pair_or_host
        when String
          [[pair_or_host, port ? port.to_i : DEFAULT_PORT]]
        when nil
          [['localhost', DEFAULT_PORT]]
      end
    end

    # Convert an argument containing a host name string and a
    # port number integer into a [host, port] pair array.
    #
    # @private
    def pair_val_to_connection(a)
      case a
      when nil
        ['localhost', DEFAULT_PORT]
      when String
        [a, DEFAULT_PORT]
      when Integer
        ['localhost', a]
      when Array
        a
      end
    end

    # Parse a MongoDB URI. This method is used by Connection.from_uri.
    # Returns an array of nodes and an array of db authorizations, if applicable.
    #
    # @private
    def parse_uri(string)
      if string =~ /^mongodb:\/\//
        string = string[10..-1]
      else
        raise MongoArgumentError, "MongoDB URI must match this spec: #{MONGODB_URI_SPEC}"
      end

      nodes = []
      auths = []
      specs = string.split(',')
      specs.each do |spec|
        matches  = MONGODB_URI_MATCHER.match(spec)
        if !matches
          raise MongoArgumentError, "MongoDB URI must match this spec: #{MONGODB_URI_SPEC}"
        end

        uname = matches[2]
        pwd   = matches[3]
        host  = matches[4]
        port  = matches[6] || DEFAULT_PORT
        if !(port.to_s =~ /^\d+$/)
          raise MongoArgumentError, "Invalid port #{port}; port must be specified as digits."
        end
        port  = port.to_i
        db    = matches[8]

        if (uname || pwd || db) && !(uname && pwd && db)
          raise MongoArgumentError, "MongoDB URI must include all three of username, password, " +
            "and db if any one of these is specified."
        else
          add_auth(db, uname, pwd)
        end

        nodes << [host, port]
      end

      nodes
    end

    private

    # Return a socket to the pool.
    def checkin(socket)
      @connection_mutex.synchronize do
        @checked_out.delete(socket)
        @queue.signal
      end
      true
    end

    # Adds a new socket to the pool and checks it out.
    #
    # This method is called exclusively from #checkout;
    # therefore, it runs within a mutex.
    def checkout_new_socket
      begin
      socket = TCPSocket.new(@host, @port)
      socket.setsockopt(Socket::IPPROTO_TCP, Socket::TCP_NODELAY, 1)
      rescue => ex
        raise ConnectionFailure, "Failed to connect socket: #{ex}"
      end
      @sockets << socket
      @checked_out << socket
      socket
    end

    # Checks out the first available socket from the pool.
    #
    # This method is called exclusively from #checkout;
    # therefore, it runs within a mutex.
    def checkout_existing_socket
      socket = (@sockets - @checked_out).first
      @checked_out << socket
      socket
    end

    # Check out an existing socket or create a new socket if the maximum
    # pool size has not been exceeded. Otherwise, wait for the next
    # available socket.
    def checkout
      connect_to_master if !connected?
      start_time = Time.now
      loop do
        if (Time.now - start_time) > @timeout
            raise ConnectionTimeoutError, "could not obtain connection within " +
              "#{@timeout} seconds. The max pool size is currently #{@size}; " +
              "consider increasing the pool size or timeout."
        end

        @connection_mutex.synchronize do
          socket = if @checked_out.size < @sockets.size
                     checkout_existing_socket
                   elsif @sockets.size < @size
                     checkout_new_socket
                   end

          return socket if socket

          # Otherwise, wait
          if @logger
            @logger.warn "Waiting for available connection; #{@checked_out.size} of #{@size} connections checked out."
          end
          @queue.wait(@connection_mutex)
        end
      end
    end

    def receive(sock)
      receive_header(sock)
      number_received, cursor_id = receive_response_header(sock)
      read_documents(number_received, cursor_id, sock)
    end

    def receive_header(sock)
      header = BSON::ByteBuffer.new
      header.put_array(receive_message_on_socket(16, sock).unpack("C*"))
      unless header.size == STANDARD_HEADER_SIZE
        raise "Short read for DB response header: " +
          "expected #{STANDARD_HEADER_SIZE} bytes, saw #{header.size}"
      end
      header.rewind
      size        = header.get_int
      request_id  = header.get_int
      response_to = header.get_int
      op          = header.get_int
    end

    def receive_response_header(sock)
      header_buf = BSON::ByteBuffer.new
      header_buf.put_array(receive_message_on_socket(RESPONSE_HEADER_SIZE, sock).unpack("C*"))
      if header_buf.length != RESPONSE_HEADER_SIZE
        raise "Short read for DB response header; " +
          "expected #{RESPONSE_HEADER_SIZE} bytes, saw #{header_buf.length}"
      end
      header_buf.rewind
      result_flags     = header_buf.get_int
      cursor_id        = header_buf.get_long
      starting_from    = header_buf.get_int
      number_remaining = header_buf.get_int
      [number_remaining, cursor_id]
    end

    def read_documents(number_received, cursor_id, sock)
      docs = []
      number_remaining = number_received
      while number_remaining > 0 do
        buf = BSON::ByteBuffer.new
        buf.put_array(receive_message_on_socket(4, sock).unpack("C*"))
        buf.rewind
        size = buf.get_int
        buf.put_array(receive_message_on_socket(size - 4, sock).unpack("C*"), 4)
        number_remaining -= 1
        buf.rewind
        docs << BSON::BSON_CODER.deserialize(buf)
      end
      [docs, number_received, cursor_id]
    end

    # Constructs a getlasterror message. This method is used exclusively by
    # Connection#send_message_with_safe_check.
    def last_error_message(db_name, opts)
      message = BSON::ByteBuffer.new
      message.put_int(0)
      BSON::BSON_RUBY.serialize_cstr(message, "#{db_name}.$cmd")
      message.put_int(0)
      message.put_int(-1)
      cmd = BSON::OrderedHash.new
      cmd[:getlasterror] = 1
      if opts.is_a?(Hash)
        opts.assert_valid_keys(:w, :wtimeout, :fsync)
        cmd.merge!(opts)
      end
      message.put_array(BSON::BSON_CODER.serialize(cmd, false).unpack("C*"))
      add_message_headers(Mongo::Constants::OP_QUERY, message)
    end

    # Prepares a message for transmission to MongoDB by
    # constructing a valid message header.
    def add_message_headers(operation, message)
      headers = BSON::ByteBuffer.new

      # Message size.
      headers.put_int(16 + message.size)

      # Unique request id.
      headers.put_int(get_request_id)

      # Response id.
      headers.put_int(0)

      # Opcode.
      headers.put_int(operation)
      message.prepend!(headers)
    end

    # Low-level method for sending a message on a socket.
    # Requires a packed message and an available socket,
    def send_message_on_socket(packed_message, socket)
      begin
      socket.send(packed_message, 0)
      rescue => ex
        close
        raise ConnectionFailure, "Operation failed with the following exception: #{ex}"
      end
    end

    # Low-level method for receiving data from socket.
    # Requires length and an available socket.
    def receive_message_on_socket(length, socket)
      message = ""
      begin
        while message.length < length do
          chunk = socket.recv(length - message.length)
          raise ConnectionFailure, "connection closed" unless chunk.length > 0
          message += chunk
        end
        rescue => ex
          close
          raise ConnectionFailure, "Operation failed with the following exception: #{ex}"
      end
      message
    end
  end
end
