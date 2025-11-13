# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

# Code coverage (must be required before application code)
require 'simplecov'
SimpleCov.start do
  add_filter '/test/'
  add_filter '/vendor/'

  add_group 'Transport', 'lib/smart_message/transport/nats.rb'
  add_group 'Helpers', 'lib/smart_message/transport/nats/**/*'

  # Lower coverage requirement for initial testing
  minimum_coverage 50
end

# Set up SmartMessage Logger before requiring our transport
require 'logger'
module SmartMessage
  # Configure logger for SmartMessage framework
  class << self
    attr_writer :logger

    def logger
      @logger ||= ::Logger.new($stdout).tap { |l| l.level = ::Logger::ERROR }
    end
  end

  # Wrapper for breaker logger compatibility
  module Logger
    def self.default
      SmartMessage.logger
    end
  end

  # Mock Dispatcher for testing
  class Dispatcher
    attr_reader :subscribers

    def initialize
      @subscribers = Hash.new { |h, k| h[k] = [] }
    end

    def register(message_class, process_method, filter_options = {})
      @subscribers[message_class] << process_method
    end

    def unregister(message_class, process_method)
      @subscribers[message_class].delete(process_method)
      @subscribers.delete(message_class) if @subscribers[message_class].empty?
    end

    def process(message_class, serialized_message)
      # Stub for processing messages
    end
  end

  # Mock Serializer for testing
  class Serializer
    # JSON serializer subclass
    class Json
      def serialize(message)
        message.to_json
      end

      def deserialize(data)
        JSON.parse(data)
      end
    end

    def serialize(message)
      message.to_json
    end

    def deserialize(data)
      JSON.parse(data)
    end
  end

  # Define VERSION constant if not already defined
  VERSION = '0.0.1' unless defined?(VERSION)
end

require "smart_message/transport/nats"

require "minitest/autorun"
require "minitest/reporters"
require "minitest/hooks/test"

# Use spec-style reporters for better output
Minitest::Reporters.use! [
  Minitest::Reporters::SpecReporter.new,
  Minitest::Reporters::HtmlReporter.new(
    reports_dir: 'test/reports',
    clean: true,
    add_timestamp: true
  )
]

# Test helpers
module TestHelpers
  def setup
    super
    # Reset any class variables or state
  end

  def teardown
    super
    # Clean up any test artifacts
  end

  # Helper to create a mock NATS client
  def mock_nats_client
    @mock_client ||= MockNATSClient.new
  end

  # Helper to create test options
  def default_test_options
    {
      servers: ['nats://localhost:4222'],
      reconnect: false, # Disable for tests
      connect_timeout: 1.0,
      max_reconnect_attempts: 0
    }
  end

  # Helper to create a test message class
  def create_test_message_class(name = 'TestMessage')
    Class.new do
      define_singleton_method(:to_s) { name }
      define_singleton_method(:name) { name }
    end
  end
end

# Mock NATS Client for unit testing
class MockNATSClient
  attr_reader :connected, :published_messages, :subscriptions, :callbacks
  attr_accessor :should_fail

  def initialize
    @connected = false
    @published_messages = []
    @subscriptions = {}
    @callbacks = {
      reconnect: [],
      disconnect: [],
      close: [],
      error: []
    }
    @should_fail = false
    @server_info = {
      server_id: 'mock-server',
      version: '2.9.0',
      max_payload: 1048576
    }
    @stats = {
      in_msgs: 0,
      out_msgs: 0,
      in_bytes: 0,
      out_bytes: 0
    }
  end

  def connected?
    @connected
  end

  def publish(subject, data, headers: {}, reply: nil)
    raise 'Not connected' unless @connected
    raise 'Mock failure' if @should_fail

    @published_messages << {
      subject: subject,
      data: data,
      headers: headers,
      reply: reply
    }
    @stats[:out_msgs] += 1
    @stats[:out_bytes] += data.bytesize
    true
  end

  def subscribe(subject, queue: nil, &block)
    raise 'Not connected' unless @connected

    subscription = MockSubscription.new(subject, queue, block)
    @subscriptions[subject] = subscription
    subscription
  end

  def request(subject, data, timeout: 2.0, headers: {})
    raise 'Not connected' unless @connected
    raise 'Mock failure' if @should_fail

    # Simulate a request/reply
    MockMessage.new(subject, "reply-data", {})
  end

  def flush(timeout = nil)
    raise 'Not connected' unless @connected
    true
  end

  def drain(timeout: 30.0)
    @connected = false
    true
  end

  def close
    @connected = false
    @callbacks[:close].each(&:call)
  end

  def on_reconnect(&block)
    @callbacks[:reconnect] << block
  end

  def on_disconnect(&block)
    @callbacks[:disconnect] << block
  end

  def on_close(&block)
    @callbacks[:close] << block
  end

  def on_error(&block)
    @callbacks[:error] << block
  end

  def server_info
    @server_info
  end

  def stats
    @stats
  end

  # Simulate receiving a message
  def simulate_message(subject, data, headers = {})
    subscription = @subscriptions[subject]
    return unless subscription

    message = MockMessage.new(subject, data, headers)
    subscription.callback.call(message) if subscription.callback
  end

  # Simulate connection
  def connect!
    @connected = true
  end

  # Simulate disconnection
  def trigger_disconnect(reason = 'Test disconnect')
    @connected = false
    @callbacks[:disconnect].each { |cb| cb.call(reason) }
  end

  # Simulate reconnection
  def trigger_reconnect
    @connected = true
    @callbacks[:reconnect].each(&:call)
  end

  # Simulate error
  def trigger_error(error)
    @callbacks[:error].each { |cb| cb.call(error) }
  end
end

class MockSubscription
  attr_reader :subject, :queue, :callback
  attr_accessor :unsubscribed

  def initialize(subject, queue, callback)
    @subject = subject
    @queue = queue
    @callback = callback
    @unsubscribed = false
  end

  def unsubscribe
    @unsubscribed = true
  end
end

class MockMessage
  attr_reader :subject, :data, :header

  def initialize(subject, data, headers)
    @subject = subject
    @data = data
    @header = headers
  end
end

# Include helpers in all tests
class Minitest::Test
  include TestHelpers
end
