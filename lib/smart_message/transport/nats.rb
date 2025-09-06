# frozen_string_literal: true

require_relative "nats/version"
require 'smart_message/transport/base'
require 'nats/client'

module SmartMessage
  module Transport
    class NATS < Base
      class Error < StandardError; end
      
      DEFAULT_CONFIG = {
        servers: ENV['NATS_SERVERS']&.split(',') || ['nats://localhost:4222'],
        user: ENV['NATS_USER'],
        password: ENV['NATS_PASSWORD'],
        token: ENV['NATS_TOKEN'],
        nkeys_seed: ENV['NATS_NKEY_SEED'],
        jwt: ENV['NATS_JWT'],
        tls: ENV['NATS_TLS'] == 'true',
        tls_ca_file: ENV['NATS_TLS_CA_FILE'],
        tls_cert_file: ENV['NATS_TLS_CERT_FILE'],
        tls_key_file: ENV['NATS_TLS_KEY_FILE'],
        reconnect: true,
        reconnect_time_wait: ENV['NATS_RECONNECT_TIME_WAIT']&.to_f || 2.0,
        max_reconnect_attempts: ENV['NATS_MAX_RECONNECT_ATTEMPTS']&.to_i || 60,
        connect_timeout: ENV['NATS_CONNECT_TIMEOUT']&.to_f || 2.0,
        drain_timeout: ENV['NATS_DRAIN_TIMEOUT']&.to_f || 30.0,
        subject_prefix: ENV['SMART_MESSAGE_SUBJECT_PREFIX'] || 'smart_message',
        queue_group: ENV['SMART_MESSAGE_QUEUE_GROUP'] || 'smart_message_workers',
        max_payload: ENV['NATS_MAX_PAYLOAD']&.to_i || 1048576 # 1MB default
      }.freeze

      attr_reader :client, :subscriptions

      def initialize(**options)
        super(**options)
        @subscriptions = {}
        @shutdown = false
      end

      def configure
        connect_to_nats
        setup_connection_handlers
        logger.info { "[NATS] Transport configured with servers: #{@options[:servers].join(', ')}" }
      end

      def default_options
        DEFAULT_CONFIG
      end

      def do_publish(message_class, serialized_message)
        subject = derive_subject(message_class)
        
        # Check payload size
        if serialized_message.bytesize > @options[:max_payload]
          raise Error, "Message size (#{serialized_message.bytesize}) exceeds max payload (#{@options[:max_payload]})"
        end
        
        headers = {
          'Smart-Message-Class' => message_class.to_s,
          'Smart-Message-Version' => SmartMessage::VERSION,
          'Content-Type' => 'application/json',
          'Timestamp' => Time.now.iso8601
        }
        
        @client.publish(subject, serialized_message, headers: headers)
        logger.debug { "[NATS] Published message to subject: #{subject}" }
      end

      def subscribe(message_class, process_method, filter_options = {})
        super(message_class, process_method, filter_options)
        
        subject = derive_subject(message_class)
        create_subscription(subject, message_class) unless @subscriptions[subject]
      end

      def unsubscribe(message_class, process_method)
        super(message_class, process_method)
        
        # Only remove subscription if no more subscribers for this message class
        if @dispatcher.subscribers[message_class].empty?
          subject = derive_subject(message_class)
          remove_subscription(subject)
        end
      end

      def connected?
        !@shutdown && @client&.connected?
      end

      def connect
        configure
        logger.info { "[NATS] Transport connected" }
      end

      def disconnect
        @shutdown = true
        
        # Unsubscribe from all subscriptions
        @subscriptions.each_value do |subscription|
          subscription.unsubscribe
        end
        @subscriptions.clear
        
        # Drain and close client
        if @client&.connected?
          @client.drain(timeout: @options[:drain_timeout])
          @client.close
        end
        
        logger.info { "[NATS] Transport disconnected" }
      end

      # Get server information for debugging/monitoring
      def server_info
        @client&.server_info || {}
      end

      # Get connection statistics
      def stats
        @client&.stats || {}
      end

      # Flush pending messages and wait for server acknowledgment
      def flush(timeout: 2.0)
        @client&.flush(timeout)
      end

      private

      def connect_to_nats
        connection_options = build_connection_options
        
        @client = ::NATS.connect(connection_options)
        logger.debug { "[NATS] Connected to NATS servers" }
      rescue => e
        logger.error { "[NATS] Connection failed: #{e.message}" }
        raise Error, "Failed to connect to NATS: #{e.message}"
      end

      def build_connection_options
        options = {
          servers: @options[:servers],
          reconnect: @options[:reconnect],
          reconnect_time_wait: @options[:reconnect_time_wait],
          max_reconnect_attempts: @options[:max_reconnect_attempts],
          connect_timeout: @options[:connect_timeout],
          drain_timeout: @options[:drain_timeout],
          max_payload: @options[:max_payload]
        }

        # Add authentication if provided
        options[:user] = @options[:user] if @options[:user]
        options[:password] = @options[:password] if @options[:password]
        options[:token] = @options[:token] if @options[:token]
        options[:nkeys_seed] = @options[:nkeys_seed] if @options[:nkeys_seed]
        options[:jwt] = @options[:jwt] if @options[:jwt]

        # Add TLS configuration if enabled
        if @options[:tls]
          tls_options = { verify_peer: true }
          tls_options[:ca_file] = @options[:tls_ca_file] if @options[:tls_ca_file]
          tls_options[:cert_file] = @options[:tls_cert_file] if @options[:tls_cert_file]
          tls_options[:key_file] = @options[:tls_key_file] if @options[:tls_key_file]
          options[:tls] = tls_options
        end

        options
      end

      def setup_connection_handlers
        @client.on_reconnect do
          logger.info { "[NATS] Reconnected to NATS server" }
          # Subscriptions are automatically re-established by NATS client
        end

        @client.on_disconnect do |reason|
          logger.warn { "[NATS] Disconnected from NATS server: #{reason}" }
        end

        @client.on_close do
          logger.info { "[NATS] Connection to NATS server closed" }
        end

        @client.on_error do |error|
          logger.error { "[NATS] NATS client error: #{error.message}" }
        end
      end

      def create_subscription(subject, message_class)
        return if @subscriptions[subject]
        
        # Use queue group for load balancing across multiple instances
        subscription = @client.subscribe(subject, queue: @options[:queue_group]) do |msg|
          handle_message(msg, message_class)
        end
        
        @subscriptions[subject] = subscription
        logger.debug { "[NATS] Created subscription for subject: #{subject}" }
      end

      def remove_subscription(subject)
        subscription = @subscriptions.delete(subject)
        if subscription
          subscription.unsubscribe
          logger.debug { "[NATS] Removed subscription for subject: #{subject}" }
        end
      end

      def handle_message(msg, expected_message_class)
        begin
          # Validate headers
          headers = msg.header || {}
          message_class = headers['Smart-Message-Class']
          
          unless message_class == expected_message_class.to_s
            logger.warn { "[NATS] Message class mismatch. Expected: #{expected_message_class}, Got: #{message_class}" }
            return
          end
          
          # Process the message
          receive(message_class, msg.data)
          
        rescue => e
          logger.error { "[NATS] Error processing message from subject #{msg.subject}: #{e.message}" }
          logger.error { "[NATS] Message data length: #{msg.data&.length}" }
          logger.error { "[NATS] Headers: #{msg.header}" }
        end
      end

      def derive_subject(message_class)
        # Convert class name to NATS subject format
        # e.g., "MyApp::UserMessage" -> "smart_message.myapp.user_message"
        class_parts = message_class.to_s.split('::').map(&:downcase)
        subject_parts = [@options[:subject_prefix]] + class_parts.map { |part| part.gsub(/([a-z])([A-Z])/, '\1_\2').downcase }
        subject_parts.join('.')
      end

      # Request/reply pattern support for future enhancement
      def request(subject, data, timeout: 2.0, headers: {})
        @client.request(subject, data, timeout: timeout, headers: headers)
      end

      # Publish with reply subject for request/reply pattern
      def publish_with_reply(subject, data, reply_subject, headers: {})
        @client.publish(subject, data, reply: reply_subject, headers: headers)
      end

      # JetStream support methods (for future enhancement)
      def jetstream
        @jetstream ||= @client.jetstream
      end

      def create_stream(name, subjects, **options)
        jetstream.add_stream(name: name, subjects: subjects, **options)
      end

      def create_consumer(stream_name, consumer_name, **options)
        jetstream.add_consumer(stream_name, name: consumer_name, **options)
      end

      # Key-Value store support (for future enhancement)  
      def key_value_store(bucket)
        @client.key_value(bucket)
      end

      # Object store support (for future enhancement)
      def object_store(bucket)
        @client.object_store(bucket)
      end
    end
  end
end
