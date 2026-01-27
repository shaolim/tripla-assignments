require 'json'
require 'timeout'


class LeaderFollowerCache
  DEFAULT_TTL = 300 # 5 minutes (per requirements)
  STALE_TTL = 900 # 15 minutes (keep stale for fallback)
  FOLLOWER_TIMEOUT = 15 # seconds (user-friendly timeout)
  MAX_RETRIES = 2
  API_TIMEOUT = 30 # seconds (max time for API call)
  CIRCUIT_BREAKER_THRESHOLD = 5
  CIRCUIT_BREAKER_TIMEOUT = 60 # seconds

  def initialize(redis:, logger: nil, ttl: DEFAULT_TTL)
    @redis = redis
    @logger = logger || Rails.logger
    @ttl = ttl
    @circuit_breaker = CircuitBreaker.new(
      threshold: CIRCUIT_BREAKER_THRESHOLD,
      timeout: CIRCUIT_BREAKER_TIMEOUT,
      logger: @logger
    )
  end

  def fetch(key, &block)
    cached = get(key)
    return cached if cached

    if @circuit_breaker.open?
      @logger.warn { "Circuit breaker open for key: #{key}, using fallback" }
      return fallback_value(key)
    end

    lock = DistributedLock.new(@redis, lock_key(key))

    begin
      @logger.info { "Attempting to become leader for key: #{key}" }

      lock.with_lock do
        cached = get(key)
        return cached if cached

        @logger.info { "Became leader for key: #{key}" }

        result = @circuit_breaker.call do
          execute_with_timeout(&block)
        end

        # Cache the result (with longer TTL for stale fallback)
        set(key, result)
        set_stale(key, result) # Keep a stale copy

        # Publish to all waiting followers
        publish_to_followers(key, result)

        result
      end
    rescue DistributedLock::LockError => e
      @logger.info { "Became follower for key: #{key}" }
      execute_as_follower_with_retry(key)
    rescue CircuitBreaker::CircuitBreakerError => e
      @logger.error { "Circuit breaker error for key #{key}: #{e.message}" }
      fallback_value(key)
    rescue Timeout::Error => e
      @logger.error { "API timeout for key #{key}: #{e.message}" }
      @circuit_breaker.record_failure
      fallback_value(key)
    rescue StandardError => e
      @logger.error { "Unexpected error for key #{key}: #{e.class} - #{e.message}" }
      @circuit_breaker.record_failure
      fallback_value(key)
    end
  end

  def get(key)
    data = @redis.get(key)
    return nil unless data

    @logger.info { "Cache hit: #{key}" }
    JSON.parse(data)
  rescue JSON::ParserError => e
    @logger.error { "Invalid JSON in cache for key #{key}: #{e.message}" }
    nil
  end

  def set(key, value, ttl: @ttl)
    @redis.set(key, value.to_json, ex: ttl)
    @logger.info { "Cached for #{ttl}s: #{key}" }
  end

  def delete(key)
    @redis.del(key)
    @redis.del(stale_key(key))
  end

  # Reset circuit breaker (useful for manual intervention)
  def reset_circuit_breaker
    @circuit_breaker.reset
  end

  private

  def lock_key(key)
    "lock:#{key}"
  end

  def stale_key(key)
    "stale:#{key}"
  end

  def execute_with_timeout(&block)
    Timeout.timeout(API_TIMEOUT) do
      block.call
    end
  end

  def execute_as_follower_with_retry(key)
    retries = 0

    begin
      request = AsyncRequest.create(key, timeout: FOLLOWER_TIMEOUT, redis: @redis)

      request.wait!
    rescue AsyncRequest::Timeout
      retries += 1

      if retries < MAX_RETRIES
        backoff_time = 0.5 * (2**(retries - 1)) # Exponential backoff: 0.5s, 1s
        @logger.warn { "Follower timeout for key #{key}, retry #{retries}/#{MAX_RETRIES} after #{backoff_time}s" }
        sleep(backoff_time)
        retry
      else
        # Max retries exceeded, use fallback
        @logger.error { "Follower max retries exceeded for key #{key}, using fallback" }
        fallback_value(key)
      end
    end
  end

  def publish_to_followers(key, result)
    result_payload = result.to_json
    followers_notified = 0

    # Drain the waiters list and publish to each follower's queue
    while (waiter_queue = @redis.rpop("waiters:#{key}"))
      @redis.lpush(waiter_queue, result_payload)
      followers_notified += 1
    end

    if followers_notified.positive?
      @logger.info do
        "Published result to #{followers_notified} followers for key: #{key}"
      end
    end
  ensure
    # Cleanup waiter list
    @redis.del("waiters:#{key}")
  end

  def set_stale(key, value)
    # Keep a stale copy for fallback with longer TTL
    @redis.set(stale_key(key), value.to_json, ex: STALE_TTL)
  end

  def get_stale(key)
    data = @redis.get(stale_key(key))
    return nil unless data

    @logger.warn { "Using stale cache for key: #{key}" }
    JSON.parse(data)
  rescue JSON::ParserError => e
    @logger.error { "Invalid JSON in stale cache for key #{key}: #{e.message}" }
    nil
  end

  def fallback_value(key)
    # Try to get stale cache
    stale = get_stale(key)
    return stale if stale

    # No stale cache available, raise an error
    @logger.error { "No fallback available for key: #{key}" }
    raise PricingService::Error, 'Pricing service is temporarily unavailable. Please try again later.'
  end
end
