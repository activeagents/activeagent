class ApplicationController < ActionController::Base
  allow_browser versions: :modern

  before_action :set_current_user
  helper_method :current_user

  private

  # No passwords in a demo: "sign in" is picking a teammate in the header.
  def set_current_user
    Current.user = User.find_by(id: session[:user_id]) || User.order(:id).first
  end

  def current_user = Current.user
end
