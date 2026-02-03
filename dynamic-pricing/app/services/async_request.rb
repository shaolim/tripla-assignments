require 'securerandom'
require 'json'

class AsyncRequest
  class Timeout < StandardError; end

  attr_reader :key, :waiter_queue, :timeout, :redis

  def self.create(key, redis:, timeout: 55)
    new(key, timeout: timeout, redis: redis).tap(&:register)
  end

  def initialize(key, redis:, timeout: 55)
    @key = key
    @timeout = timeout
    @redis = redis
    @waiter_queue = "waiter:#{key}:#{SecureRandom.uuid}"
  end

  # Register this follower in the waiters list
  def register
    redis.lpush("waiters:#{key}", waiter_queue)
    self
  end

  # Block until leader publishes result or timeout occurs
  def wait!
    # BRPOP blocks until data is available or timeout
    # Returns [queue_name, value] or nil on timeout
    result = redis.brpop(waiter_queue, timeout: timeout)

    raise Timeout, "No response within #{timeout}s for key: #{key}" if result.nil?

    payload = result[1]
    cleanup

    JSON.parse(payload)
  rescue JSON::ParserError => e
    raise "Invalid JSON payload: #{e.message}"
  ensure
    cleanup
  end

  private

  def cleanup
    redis.del(waiter_queue)
  rescue StandardError => e
    # Best effort cleanup
    Rails.logger.warn "Failed to cleanup waiter queue: #{e.message}"
  end
end
