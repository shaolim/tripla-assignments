require 'net/http'
require 'json'
require 'uri'
require 'digest'

# PricingService using Leader-Follower pattern
# Optimized for the Tripla case requirements:
# - Handles expensive API operations (auto-extending lock)
# - Respects rate limits (circuit breaker, no duplicate calls)
# - Graceful degradation (stale cache fallback)
# - User-friendly timeouts (15s instead of 55s)
# - Production-ready error handling
class PricingService
  DEFAULT_API_URL = ENV.fetch('RATE_API_URL', 'http://rate-api:8080/pricing').freeze
  CACHE_PREFIX = 'pricing:'.freeze
  CACHE_TTL = 300 # 5 minutes (per requirements)

  class Error < StandardError; end

  class ApiError < Error
    attr_reader :code

    def initialize(code, message)
      @code = code
      super("API error #{code}: #{message}")
    end
  end

  class << self
    def instance
      @instance ||= new(
        token: ENV.fetch('API_TOKEN', ''),
        redis: redis_connection,
        logger: Rails.logger
      )
    end

    def redis_connection
      @redis ||= Redis.new(url: ENV.fetch('REDIS_URL', 'redis://localhost:6379'))
    end
  end

  def initialize(token:, redis:, logger: nil, api_url: DEFAULT_API_URL)
    @uri = URI(api_url)
    @token = token
    @logger = logger || Rails.logger
    @cache = LeaderFollowerCache.new(redis: redis, logger: @logger, ttl: CACHE_TTL)
  end

  # Fetch pricing for a single room
  # @param period [String] Season period (Summer, Autumn, Winter, Spring)
  # @param hotel [String] Hotel name
  # @param room [String] Room type
  # @return [Hash] Pricing data with rate
  def fetch_pricing(period:, hotel:, room:)
    attributes = { period: period, hotel: hotel, room: room }
    cache_key = build_cache_key(attributes)

    result = @cache.fetch(cache_key) do
      fetch_from_api([attributes])
    end

    # The API returns an array, extract the first result
    extract_rate(result, attributes)
  rescue AsyncRequest::Timeout => e
    @logger.error { "[PricingService] Follower timeout: #{e.message}" }
    raise Error, 'Price calculation timed out. The service is experiencing high load. Please retry in a few seconds.'
  rescue DistributedLock::LockError => e
    @logger.error { "[PricingService] Lock error: #{e.message}" }
    raise Error, 'Unable to coordinate price calculation. Please retry.'
  rescue CircuitBreaker::CircuitBreakerError => e
    @logger.error { "[PricingService] Circuit breaker open: #{e.message}" }
    raise Error, 'Pricing service is temporarily unavailable. Please try again later.'
  end

  # Reset circuit breaker (for manual intervention)
  def reset_circuit_breaker
    @cache.reset_circuit_breaker
  end

  private

  attr_reader :uri, :token, :logger

  def build_cache_key(attributes)
    normalized = normalize_attr(attributes)
    hash = Digest::SHA256.hexdigest(normalized.to_json)
    "#{CACHE_PREFIX}#{hash}"
  end

  def fetch_from_api(attributes)
    request = build_request(attributes)

    logger.info { "[PricingService] API request: POST #{uri}" }

    response = Net::HTTP.start(uri.hostname, uri.port) do |http|
      http.open_timeout = 10
      http.read_timeout = 30
      http.request(request)
    end

    unless response.is_a?(Net::HTTPSuccess)
      logger.error { "[PricingService] API error: #{response.code} - #{response.body}" }
      raise ApiError.new(response.code, response.body)
    end

    JSON.parse(response.body)
  end

  def build_request(attributes)
    request = Net::HTTP::Post.new(uri)
    request['Content-Type'] = 'application/json'
    request['Accept'] = 'application/json'
    request['token'] = token
    request.body = { attributes: attributes.map { |a| normalize_attr(a) } }.to_json
    request
  end

  def normalize_attr(raw)
    {
      period: raw[:period] || raw['period'],
      hotel: raw[:hotel] || raw['hotel'],
      room: raw[:room] || raw['room']
    }.compact
  end

  def extract_rate(result, attributes)
    # The API returns {"rates": [...]} with pricing results
    # Find the matching result for our attributes
    rates = result.is_a?(Hash) ? result['rates'] : result

    if rates.is_a?(Array) && rates.any?
      item = rates.find do |r|
        r['period'] == attributes[:period] &&
          r['hotel'] == attributes[:hotel] &&
          r['room'] == attributes[:room]
      end || rates.first

      { 'rate' => item['rate'].to_s }
    else
      raise Error, 'Invalid response from pricing service'
    end
  end
end
