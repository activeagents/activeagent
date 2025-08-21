class TravelAgent < ApplicationAgent
  MockUser = Data.define(:name) unless defined?(MockUser)
  before_action :set_user

  def search
    @departure = params[:departure]
    @destination = params[:destination]
    @results = params[:results] || []
    prompt(content_type: :html)
  end

  def book
    @flight_id = params[:flight_id]
    @passenger_name = params[:passenger_name]
    @confirmation_number = params[:confirmation_number]
    prompt(content_type: :text)
  end

  def confirm
    @confirmation_number = params[:confirmation_number]
    @passenger_name = params[:passenger_name]
    @flight_details = params[:flight_details]
    prompt(content_type: :text)
  end

  private

  def set_user
    @user = params[:user] || MockUser.new(name: "Guest")
  end
end
