# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

module SmartMessage
  module Transport
    class TestNats < Minitest::Test
      def setup
        super
        @mock_client = MockNATSClient.new
        @mock_client.connect!

        # Stub NATS.connect to return our mock client
        ::NATS.stubs(:connect).returns(@mock_client)

        # Create a test message class
        @test_message_class = create_test_message_class('TestMessage')

        # Stub the dispatcher for some tests
        @mock_dispatcher = mock('dispatcher')
        @mock_dispatcher.stubs(:subscribers).returns({})
      end

      def teardown
        super
        ::NATS.unstub(:connect)
      end

      # ========================================
      # Version Tests
      # ========================================

      def test_that_it_has_a_version_number
        refute_nil ::SmartMessage::Transport::Nats::VERSION
        assert_match(/\d+\.\d+\.\d+/, ::SmartMessage::Transport::Nats::VERSION)
      end

      # ========================================
      # Initialization Tests
      # ========================================

      def test_initialize_with_default_options
        transport = NATS.new

        assert_kind_of NATS, transport
        assert_empty transport.subscriptions
      end

      def test_initialize_with_custom_options
        custom_options = {
          servers: ['nats://custom:4222'],
          user: 'testuser',
          password: 'testpass'
        }

        transport = NATS.new(**custom_options)
        assert_kind_of NATS, transport
      end

      def test_default_options
        transport = NATS.new

        defaults = transport.default_options
        assert_includes defaults[:servers], 'nats://localhost:4222'
        assert_equal 'smart_message', defaults[:subject_prefix]
        assert_equal 'smart_message_workers', defaults[:queue_group]
        assert_equal 1048576, defaults[:max_payload]
      end

      def test_default_options_from_environment
        ENV['NATS_SERVERS'] = 'nats://env1:4222,nats://env2:4222'
        ENV['NATS_USER'] = 'envuser'
        ENV['SMART_MESSAGE_SUBJECT_PREFIX'] = 'custom_prefix'

        # Need to reload the class to pick up env vars
        transport = NATS.new

        # Clean up
        ENV.delete('NATS_SERVERS')
        ENV.delete('NATS_USER')
        ENV.delete('SMART_MESSAGE_SUBJECT_PREFIX')
      end

      # ========================================
      # Connection Tests
      # ========================================

      def test_configure_connects_to_nats
        transport = NATS.new(servers: ['nats://localhost:4222'])

        # Verify NATS.connect is called
        ::NATS.expects(:connect).returns(@mock_client)

        transport.configure

        assert_equal @mock_client, transport.client
      end

      def test_connect_calls_configure
        transport = NATS.new

        transport.connect

        assert transport.connected?
      end

      def test_connected_returns_true_when_connected
        transport = NATS.new
        transport.configure

        assert transport.connected?
      end

      def test_connected_returns_false_when_disconnected
        transport = NATS.new
        transport.configure
        transport.disconnect

        refute transport.connected?
      end

      def test_connected_returns_false_when_shutdown
        transport = NATS.new
        transport.configure
        transport.instance_variable_set(:@shutdown, true)

        refute transport.connected?
      end

      def test_connection_with_authentication_options
        transport = NATS.new(
          user: 'testuser',
          password: 'testpass',
          token: 'testtoken'
        )

        ::NATS.expects(:connect).with do |options|
          options[:user] == 'testuser' &&
            options[:password] == 'testpass' &&
            options[:token] == 'testtoken'
        end.returns(@mock_client)

        transport.configure
      end

      def test_connection_with_tls_options
        transport = NATS.new(
          tls: true,
          tls_ca_file: '/path/to/ca.pem',
          tls_cert_file: '/path/to/cert.pem',
          tls_key_file: '/path/to/key.pem'
        )

        ::NATS.expects(:connect).with do |options|
          options[:tls].is_a?(Hash) &&
            options[:tls][:ca_file] == '/path/to/ca.pem' &&
            options[:tls][:cert_file] == '/path/to/cert.pem' &&
            options[:tls][:key_file] == '/path/to/key.pem'
        end.returns(@mock_client)

        transport.configure
      end

      def test_connection_failure_raises_error
        ::NATS.unstub(:connect)
        ::NATS.stubs(:connect).raises(StandardError.new('Connection failed'))

        transport = NATS.new

        error = assert_raises(NATS::Error) do
          transport.configure
        end

        assert_match(/Failed to connect to NATS/, error.message)
      end

      # ========================================
      # Disconnect Tests
      # ========================================

      def test_disconnect_drains_and_closes_client
        transport = NATS.new
        transport.configure

        # Mock expects drain and close
        @mock_client.expects(:drain).with(timeout: 30.0)
        @mock_client.expects(:close)

        transport.disconnect

        refute transport.connected?
      end

      def test_disconnect_unsubscribes_all_subscriptions
        transport = NATS.new
        transport.configure

        # Add some subscriptions
        transport.instance_variable_get(:@dispatcher).stubs(:register)
        transport.subscribe(@test_message_class, :process_message)

        assert_equal 1, transport.subscriptions.size

        transport.disconnect

        assert_empty transport.subscriptions
      end

      # ========================================
      # Publishing Tests
      # ========================================

      def test_publish_message_success
        transport = NATS.new
        transport.configure

        serialized = '{"test": "data"}'
        subject = transport.send(:derive_subject, @test_message_class)

        transport.send(:do_publish, @test_message_class, serialized)

        published = @mock_client.published_messages.last
        assert_equal subject, published[:subject]
        assert_equal serialized, published[:data]
        assert_equal @test_message_class.to_s, published[:headers]['Smart-Message-Class']
        assert_equal 'application/json', published[:headers]['Content-Type']
      end

      def test_publish_adds_headers
        transport = NATS.new
        transport.configure

        serialized = '{"test": "data"}'

        transport.send(:do_publish, @test_message_class, serialized)

        published = @mock_client.published_messages.last
        headers = published[:headers]

        assert_equal @test_message_class.to_s, headers['Smart-Message-Class']
        assert_equal SmartMessage::VERSION, headers['Smart-Message-Version']
        assert_equal 'application/json', headers['Content-Type']
        assert headers.key?('Timestamp')
      end

      def test_publish_exceeds_max_payload_raises_error
        transport = NATS.new(max_payload: 100)
        transport.configure

        large_message = 'x' * 200

        error = assert_raises(NATS::Error) do
          transport.send(:do_publish, @test_message_class, large_message)
        end

        assert_match(/exceeds max payload/, error.message)
      end

      def test_publish_with_custom_subject_prefix
        transport = NATS.new(subject_prefix: 'custom_app')
        transport.configure

        serialized = '{"test": "data"}'
        transport.send(:do_publish, @test_message_class, serialized)

        subject = @mock_client.published_messages.last[:subject]
        assert_match(/^custom_app\./, subject)
      end

      # ========================================
      # Subject Derivation Tests
      # ========================================

      def test_derive_subject_simple_class
        transport = NATS.new

        message_class = create_test_message_class('UserMessage')
        subject = transport.send(:derive_subject, message_class)

        assert_equal 'smart_message.usermessage', subject
      end

      def test_derive_subject_namespaced_class
        transport = NATS.new

        message_class = create_test_message_class('MyApp::UserMessage')
        subject = transport.send(:derive_subject, message_class)

        assert_equal 'smart_message.myapp.usermessage', subject
      end

      def test_derive_subject_camel_case
        transport = NATS.new

        message_class = create_test_message_class('OrderConfirmation')
        subject = transport.send(:derive_subject, message_class)

        # Should convert CamelCase to snake_case
        assert_equal 'smart_message.order_confirmation', subject
      end

      def test_derive_subject_with_custom_prefix
        transport = NATS.new(subject_prefix: 'my_prefix')

        message_class = create_test_message_class('TestMessage')
        subject = transport.send(:derive_subject, message_class)

        assert_equal 'my_prefix.testmessage', subject
      end

      # ========================================
      # Subscription Tests
      # ========================================

      def test_subscribe_creates_subscription
        transport = NATS.new
        transport.configure
        transport.instance_variable_set(:@dispatcher, @mock_dispatcher)

        @mock_dispatcher.expects(:register).with(@test_message_class, :process_message, {})

        transport.subscribe(@test_message_class, :process_message)

        subject = transport.send(:derive_subject, @test_message_class)
        assert transport.subscriptions.key?(subject)
      end

      def test_subscribe_uses_queue_group
        transport = NATS.new(queue_group: 'test_workers')
        transport.configure
        transport.instance_variable_set(:@dispatcher, @mock_dispatcher)

        @mock_dispatcher.expects(:register)

        transport.subscribe(@test_message_class, :process_message)

        subject = transport.send(:derive_subject, @test_message_class)
        subscription = @mock_client.subscriptions[subject]

        assert_equal 'test_workers', subscription.queue
      end

      def test_subscribe_only_creates_one_subscription_per_subject
        transport = NATS.new
        transport.configure
        transport.instance_variable_set(:@dispatcher, @mock_dispatcher)

        @mock_dispatcher.stubs(:register)

        # Subscribe twice with different methods
        transport.subscribe(@test_message_class, :process_message)
        transport.subscribe(@test_message_class, :another_method)

        # Should only have one NATS subscription
        assert_equal 1, transport.subscriptions.size
      end

      def test_unsubscribe_removes_subscription
        transport = NATS.new
        transport.configure

        mock_dispatcher = transport.instance_variable_get(:@dispatcher)
        mock_dispatcher.stubs(:register)
        mock_dispatcher.stubs(:unregister)
        mock_dispatcher.stubs(:subscribers).returns({@test_message_class => []})

        transport.subscribe(@test_message_class, :process_message)
        assert_equal 1, transport.subscriptions.size

        transport.unsubscribe(@test_message_class, :process_message)

        # Should remove subscription when no more subscribers
        assert_empty transport.subscriptions
      end

      def test_unsubscribe_keeps_subscription_if_other_subscribers_exist
        transport = NATS.new
        transport.configure

        mock_dispatcher = transport.instance_variable_get(:@dispatcher)
        mock_dispatcher.stubs(:register)
        mock_dispatcher.stubs(:unregister)
        mock_dispatcher.stubs(:subscribers).returns({@test_message_class => [:another_method]})

        transport.subscribe(@test_message_class, :process_message)

        transport.unsubscribe(@test_message_class, :process_message)

        # Should keep subscription since other subscribers exist
        assert_equal 1, transport.subscriptions.size
      end

      # ========================================
      # Message Handling Tests
      # ========================================

      def test_handle_message_validates_message_class
        transport = NATS.new
        transport.configure

        message = MockMessage.new(
          'test.subject',
          '{"test": "data"}',
          {'Smart-Message-Class' => 'WrongClass'}
        )

        # Should not call receive since class doesn't match
        transport.expects(:receive).never

        transport.send(:handle_message, message, @test_message_class)
      end

      def test_handle_message_calls_receive
        transport = NATS.new
        transport.configure

        message = MockMessage.new(
          'test.subject',
          '{"test": "data"}',
          {'Smart-Message-Class' => @test_message_class.to_s}
        )

        transport.expects(:receive).with(@test_message_class.to_s, '{"test": "data"}')

        transport.send(:handle_message, message, @test_message_class)
      end

      def test_handle_message_rescues_errors
        transport = NATS.new
        transport.configure

        message = MockMessage.new(
          'test.subject',
          '{"test": "data"}',
          {'Smart-Message-Class' => @test_message_class.to_s}
        )

        transport.stubs(:receive).raises(StandardError.new('Processing error'))

        # Should not raise, just log the error
        assert_silent do
          transport.send(:handle_message, message, @test_message_class)
        end
      end

      # ========================================
      # Connection Handler Tests
      # ========================================

      def test_setup_connection_handlers_registers_callbacks
        transport = NATS.new
        transport.configure

        assert_equal 1, @mock_client.callbacks[:reconnect].size
        assert_equal 1, @mock_client.callbacks[:disconnect].size
        assert_equal 1, @mock_client.callbacks[:close].size
        assert_equal 1, @mock_client.callbacks[:error].size
      end

      def test_on_reconnect_callback
        transport = NATS.new
        transport.configure

        # Trigger reconnect
        @mock_client.trigger_reconnect

        # Should log but not raise
        assert transport.connected?
      end

      def test_on_disconnect_callback
        transport = NATS.new
        transport.configure

        # Trigger disconnect
        @mock_client.trigger_disconnect('Test disconnect')

        # Should log but not raise
        refute @mock_client.connected?
      end

      def test_on_error_callback
        transport = NATS.new
        transport.configure

        error = StandardError.new('Test error')

        # Should log but not raise
        assert_silent do
          @mock_client.trigger_error(error)
        end
      end

      # ========================================
      # Server Info & Stats Tests
      # ========================================

      def test_server_info_returns_info
        transport = NATS.new
        transport.configure

        info = transport.server_info

        assert_kind_of Hash, info
        assert_equal 'mock-server', info[:server_id]
        assert_equal '2.9.0', info[:version]
      end

      def test_stats_returns_statistics
        transport = NATS.new
        transport.configure

        # Publish a message to increment stats
        transport.send(:do_publish, @test_message_class, '{"test": "data"}')

        stats = transport.stats

        assert_kind_of Hash, stats
        assert_equal 1, stats[:out_msgs]
        assert stats[:out_bytes] > 0
      end

      def test_server_info_when_not_connected
        transport = NATS.new

        info = transport.server_info

        assert_equal({}, info)
      end

      # ========================================
      # Flush Tests
      # ========================================

      def test_flush_success
        transport = NATS.new
        transport.configure

        assert transport.flush
      end

      def test_flush_with_timeout
        transport = NATS.new
        transport.configure

        @mock_client.expects(:flush).with(5.0)

        transport.flush(timeout: 5.0)
      end

      def test_flush_when_not_connected
        transport = NATS.new

        # Should return nil when not connected
        assert_nil transport.flush
      end

      # ========================================
      # Request/Reply Tests
      # ========================================

      def test_request_sends_request
        transport = NATS.new
        transport.configure

        response = transport.send(:request, 'test.subject', 'request data')

        assert_kind_of MockMessage, response
        assert_equal 'reply-data', response.data
      end

      def test_request_with_timeout
        transport = NATS.new
        transport.configure

        @mock_client.expects(:request).with(
          'test.subject',
          'request data',
          timeout: 5.0,
          headers: {}
        ).returns(MockMessage.new('test.subject', 'reply', {}))

        transport.send(:request, 'test.subject', 'request data', timeout: 5.0)
      end

      def test_publish_with_reply_subject
        transport = NATS.new
        transport.configure

        subject = transport.send(:derive_subject, @test_message_class)

        transport.send(:publish_with_reply, subject, '{"test": "data"}', 'reply.subject')

        published = @mock_client.published_messages.last
        assert_equal 'reply.subject', published[:reply]
      end

      # ========================================
      # Edge Cases & Error Scenarios
      # ========================================

      def test_multiple_connects
        transport = NATS.new

        transport.connect
        transport.connect # Should handle gracefully

        assert transport.connected?
      end

      def test_multiple_disconnects
        transport = NATS.new
        transport.configure

        transport.disconnect
        transport.disconnect # Should handle gracefully

        refute transport.connected?
      end

      def test_publish_when_not_connected
        transport = NATS.new

        # Don't call configure

        error = assert_raises(NoMethodError) do
          transport.send(:do_publish, @test_message_class, '{"test": "data"}')
        end
      end

      def test_graceful_shutdown
        transport = NATS.new
        transport.configure

        # Simulate receiving messages
        transport.instance_variable_get(:@dispatcher).stubs(:register)
        transport.subscribe(@test_message_class, :process_message)

        # Disconnect should be clean
        assert_nothing_raised do
          transport.disconnect
        end

        refute transport.connected?
        assert_empty transport.subscriptions
      end
    end
  end
end
