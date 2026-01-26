ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"
require "mocha/minitest"

class ActiveSupport::TestCase
  # Run tests in parallel with specified workers
  parallelize(workers: 1)

  # Setup all fixtures in test/fixtures/*.yml for all tests in alphabetical order.
  fixtures :all

  # Add more helper methods to be used by all tests here...
end

# Mock Redis class for testing
class MockRedis
  def initialize
    @data = {}
    @locks = {}
    @lists = Hash.new { |h, k| h[k] = [] }
    @expirations = {}
  end

  def get(key)
    @data[key]
  end

  def set(key, value, **options)
    if options[:nx]
      return nil if @data.key?(key)
    end
    @data[key] = value
    @expirations[key] = options[:ex] if options[:ex]
    true
  end

  def del(*keys)
    keys.flatten.each { |key| @data.delete(key) }
  end

  def lpush(key, value)
    @lists[key].unshift(value)
  end

  def rpop(key)
    @lists[key].pop
  end

  def brpop(key, timeout: nil)
    value = @lists[key].pop
    return nil unless value
    [key, value]
  end

  def expire(key, seconds)
    @expirations[key] = seconds
    true
  end

  def eval(script, keys: [], argv: [])
    # Simplified Lua script simulation
    if script.include?("DEL")
      # Release lock script
      key = keys.first
      owner = argv.first
      if @data[key] == owner
        @data.delete(key)
        1
      else
        0
      end
    elsif script.include?("EXPIRE")
      # Extend lock script
      key = keys.first
      owner = argv.first
      ttl = argv[1]
      if @data[key] == owner
        @expirations[key] = ttl
        1
      else
        0
      end
    else
      0
    end
  end

  def flushdb
    @data.clear
    @lists.clear
    @expirations.clear
  end
end
