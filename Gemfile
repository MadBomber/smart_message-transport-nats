# frozen_string_literal: true

source "https://rubygems.org"

# Specify your gem's dependencies in smart_message-transport-nats.gemspec
gemspec

gem "irb"
gem "rake", "~> 13.0"

# Testing
gem "minitest", "~> 5.16"
gem "minitest-hooks", "~> 1.5"
gem "minitest-reporters", "~> 1.6"
gem "mocha", "~> 2.1"
gem "simplecov", "~> 0.22", require: false

# Code quality
gem "rubocop", "~> 1.21"
gem "rubocop-minitest", "~> 0.31", require: false
gem "rubocop-rake", "~> 0.6", require: false

# Held below 0.28 until smart_message stops relying on activesupport's
# Integer#seconds: breaker_machines 0.28 no longer loads activesupport,
# and smart_message 0.0.17 then fails with NoMethodError.
gem "breaker_machines", "< 0.28"
