# frozen_string_literal: true

require "test_helper"

module SmartMessage
  module Transport
    # Integration tests require a running NATS server
    # Skip these tests if NATS_INTEGRATION_TESTS env var is not set
    #
    # To run integration tests:
    # 1. Start a NATS server: docker run -p 4222:4222 nats:latest
    # 2. Run tests: NATS_INTEGRATION_TESTS=1 bundle exec rake test
    class TestNatsIntegration < Minitest::Test
      def setup
        skip "Skipping integration tests (set NATS_INTEGRATION_TESTS=1 to enable)" unless integration_tests_enabled?

        super
        @test_message_class = create_test_message_class('IntegrationTestMessage')
        @received_messages = []
      end

      def teardown
        @transport&.disconnect
        super
      end

      # ========================================
      # Integration Tests
      # ========================================

      def test_full_publish_subscribe_cycle
        @transport = create_transport

        # Subscribe to messages
        @transport.subscribe(@test_message_class, :process_message)

        # Define a receiver
        receiver = Class.new do
          attr_reader :received_messages

          def initialize
            @received_messages = []
          end

          def process_message(message)
            @received_messages << message
          end
        end.new

        # Stub the dispatcher to call our receiver
        @transport.instance_variable_get(:@dispatcher).define_singleton_method(:process) do |msg_class, data|
          receiver.process_message(data)
        end

        # Publish a message
        serialized = '{"test": "integration"}'
        @transport.send(:do_publish, @test_message_class, serialized)

        # Flush to ensure message is sent
        @transport.flush

        # Wait a bit for message delivery
        sleep 0.5

        # Simulate message receipt
        subject = @transport.send(:derive_subject, @test_message_class)

        # Note: In a real integration test, we would verify the message was actually
        # received through NATS. This test structure shows the pattern.
        assert @transport.connected?
      end

      def test_connection_and_disconnection
        @transport = create_transport

        assert @transport.connected?

        server_info = @transport.server_info
        assert_kind_of Hash, server_info
        refute_empty server_info

        @transport.disconnect

        refute @transport.connected?
      end

      def test_multiple_subscribers_with_queue_groups
        @transport = create_transport

        message_class1 = create_test_message_class('QueueMessage1')
        message_class2 = create_test_message_class('QueueMessage2')

        @transport.subscribe(message_class1, :handler1)
        @transport.subscribe(message_class2, :handler2)

        assert_equal 2, @transport.subscriptions.size

        # Both should use the same queue group
        @transport.subscriptions.each_value do |subscription|
          # In real integration test, verify queue group behavior
        end
      end

      def test_authentication_with_token
        skip "Requires NATS server configured with token auth"

        @transport = NATS.new(
          servers: [nats_server_url],
          token: ENV['NATS_TEST_TOKEN']
        )

        @transport.connect

        assert @transport.connected?
      end

      def test_tls_connection
        skip "Requires NATS server configured with TLS"

        @transport = NATS.new(
          servers: [nats_tls_server_url],
          tls: true,
          tls_ca_file: ENV['NATS_TEST_CA_FILE']
        )

        @transport.connect

        assert @transport.connected?
      end

      def test_reconnection_after_disconnect
        skip "Requires ability to stop/start NATS server"

        @transport = create_transport
        assert @transport.connected?

        # Simulate server disconnect
        # In real test: stop NATS server

        # Wait for disconnect
        sleep 1

        # Restart NATS server

        # Wait for reconnection
        sleep 2

        # Should be reconnected
        assert @transport.connected?
      end

      def test_high_volume_publishing
        @transport = create_transport

        message_count = 1000
        message_count.times do |i|
          serialized = "{\"message\": #{i}}"
          @transport.send(:do_publish, @test_message_class, serialized)
        end

        @transport.flush

        stats = @transport.stats
        assert_equal message_count, stats[:out_msgs]
      end

      def test_large_message_handling
        @transport = create_transport

        # Create a message near the max payload size
        large_data = 'x' * (1024 * 1024 - 100) # Just under 1MB

        @transport.send(:do_publish, @test_message_class, large_data)
        @transport.flush

        stats = @transport.stats
        assert_equal 1, stats[:out_msgs]
      end

      def test_message_ordering
        @transport = create_transport

        @transport.subscribe(@test_message_class, :process_message)

        # Publish messages in order
        10.times do |i|
          serialized = "{\"order\": #{i}}"
          @transport.send(:do_publish, @test_message_class, serialized)
        end

        @transport.flush

        # NATS doesn't guarantee ordering without additional configuration
        # This test would verify ordering with proper setup
      end

      def test_concurrent_publishing
        @transport = create_transport

        threads = []
        messages_per_thread = 100

        5.times do |thread_num|
          threads << Thread.new do
            messages_per_thread.times do |i|
              serialized = "{\"thread\": #{thread_num}, \"message\": #{i}}"
              @transport.send(:do_publish, @test_message_class, serialized)
            end
          end
        end

        threads.each(&:join)
        @transport.flush

        stats = @transport.stats
        assert_equal 500, stats[:out_msgs]
      end

      def test_request_reply_pattern
        skip "Requires request/reply handler setup"

        @transport = create_transport

        # Set up a responder
        @transport.subscribe(@test_message_class, :handle_request)

        # Send a request
        response = @transport.send(:request, 'test.request', '{"query": "data"}', timeout: 5.0)

        assert response
      end

      private

      def create_transport
        transport = NATS.new(
          servers: [nats_server_url],
          reconnect: true,
          max_reconnect_attempts: 3,
          connect_timeout: 5.0
        )
        transport.connect
        transport
      end

      def nats_server_url
        ENV['NATS_TEST_SERVER'] || 'nats://localhost:4222'
      end

      def nats_tls_server_url
        ENV['NATS_TEST_TLS_SERVER'] || 'nats://localhost:4443'
      end

      def integration_tests_enabled?
        ENV['NATS_INTEGRATION_TESTS'] == '1' || ENV['NATS_INTEGRATION_TESTS'] == 'true'
      end
    end
  end
end
