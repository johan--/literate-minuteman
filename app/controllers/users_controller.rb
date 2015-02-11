class UsersController < ApplicationController
  before_filter :require_login, :except => [:login, :logout, :oauth_callback]

  def login
    request_token = get_consumer.get_request_token
    session[:oauth_token] = request_token.token
    session[:oauth_secret] = request_token.secret
    redirect_to request_token.authorize_url
  end

  def oauth_callback
    @user = get_authorized_user
    @user.update_shelves

    session[:user_id] = @user.id
    redirect_to :controller => :books, :action => :index
  end

  def logout
    session[:user_id] = nil
    redirect_to '/'
  end

  def edit
  end

  def update
    if @user.update_attributes(user_params)
      @user.sync_books

      @user.books.pluck(:id).each do |id|
        Resque.enqueue UpdateBook, id
      end

      flash[:notice_good] = "Settings updated."
      redirect_to :controller => :books, :action => :index
    else
      flash[:notice_bad] = "Couldn't save settings."
      render :edit
    end
  end

  private
  def user_params
    params[:user] ||= {}
    params[:user][:location_ids] ||= []
    params[:user][:library_system_ids] ||= []

    params.require(:user).permit(active_shelves: [], location_ids: [], library_system_ids: [])
  end

  def get_consumer
    OAuth::Consumer.new(GOODREADS_API_KEY,
                        GOODREADS_API_SECRET,
                        :site => 'http://www.goodreads.com')
  end

  def get_authorized_user
    request_token = OAuth::RequestToken.new(get_consumer, session[:oauth_token], session[:oauth_secret])
    access_token = request_token.get_access_token
    client = Goodreads::Client.new(oauth_token: access_token)

    User.where(goodreads_id: client.user_id).first_or_create.tap do |user|
      user.oauth_access_token = access_token.token
      user.oauth_access_secret = access_token.secret
      user.save
    end
  end
end
