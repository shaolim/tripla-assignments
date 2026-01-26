class PricingController < ApplicationController
  VALID_PERIODS = %w[Summer Autumn Winter Spring].freeze
  VALID_HOTELS = %w[FloatingPointResort GitawayHotel RecursionRetreat].freeze
  VALID_ROOMS = %w[SingletonRoom BooleanTwin RestfulKing].freeze

  before_action :validate_params

  def index
    period = params[:period]
    hotel  = params[:hotel]
    room   = params[:room]

    result = pricing_service.fetch_pricing(period: period, hotel: hotel, room: room)
    render json: result
  rescue PricingService::ApiError => e
    render json: { error: e.message }, status: e.code.to_i
  rescue PricingService::Error => e
    render json: { error: e.message }, status: :service_unavailable
  rescue StandardError => e
    Rails.logger.error { "Unexpected error in PricingController: #{e.class} - #{e.message}" }
    render json: { error: 'An unexpected error occurred. Please try again.' }, status: :internal_server_error
  end

  private

  def pricing_service
    PricingService.instance
  end

  def validate_params
    # Validate required parameters
    unless params[:period].present? && params[:hotel].present? && params[:room].present?
      return render json: { error: "Missing required parameters: period, hotel, room" }, status: :bad_request
    end

    # Validate parameter values
    unless VALID_PERIODS.include?(params[:period])
      return render json: { error: "Invalid period. Must be one of: #{VALID_PERIODS.join(', ')}" }, status: :bad_request
    end

    unless VALID_HOTELS.include?(params[:hotel])
      return render json: { error: "Invalid hotel. Must be one of: #{VALID_HOTELS.join(', ')}" }, status: :bad_request
    end

    unless VALID_ROOMS.include?(params[:room])
      return render json: { error: "Invalid room. Must be one of: #{VALID_ROOMS.join(', ')}" }, status: :bad_request
    end
  end
end
