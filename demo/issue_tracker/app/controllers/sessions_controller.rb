class SessionsController < ApplicationController
  def update
    session[:user_id] = User.find(params[:user_id]).id
    redirect_back fallback_location: root_path
  end
end
