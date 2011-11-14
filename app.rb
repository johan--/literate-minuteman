require 'rubygems'
require 'sinatra'
require 'sinatra/redis'
require 'haml'
require 'yaml'
require 'sass'
require 'set'
require 'bcrypt'
require 'pp'
require 'oauth'
require 'resque'
require 'lookup'

require 'bundler'
Bundler.setup
require 'goodreads'

require 'padrino-helpers'
Sinatra.register Padrino::Helpers

set :redis, ENV['REDIS_URL'] || 'redis://127.0.0.1:6379/0' 
enable :sessions

@@conf = YAML::load(IO.read('config.yml'))
Goodreads::Client.configure({ :api_key => @@conf['api_key'] })

def signup(username, password)
  redis.hset("user:#{username}", 'username', username)
  redis.hmset("user:#{username}", 'password', BCrypt::Password.create(password))
  {'username' => username}
end

def authenticate(username, password)
  user = redis.hgetall "user:#{username}"
  unless user.empty?
    if BCrypt::Password.new(user['password']) == password
      {:username => user['username'], :goodreads_id => user['goodreads_id']} 
    end
  end
end

def read_from_cache
  books = redis.hgetall("books:#{session[:goodreads_id]}")
  books['results'] = YAML.load(books['results']) if books['results']
  books
end

def locations(books)
  set = SortedSet.new
  books.each do |book|
    book[:results].each do |result|
      set.merge result[:locations].keys
    end
  end
  set
end

def build_results(data, branch=nil)
  books = data['results']
  enabled = get_enabled_branches
  enabled_keys = enabled.map {|e| e.gsub(/\s*\/\s*/, '-').downcase }
  locs = locations(books)

  unless !branch 
    books = books.map do |b| 
      b[:results], b[:elsewhere] = b[:results].partition do |r|
        locations = r[:locations].select { |name, avail| (avail == "Available") }
        locations = locations.map {|l| l[0].gsub(/\s*\/\s*/, '-').downcase }
        (locations.member? branch) 
      end
      b
    end
  end

  no_results, books = books.partition {|b| b[:results].empty? && (b[:elsewhere] || []).empty?}
  only_elsewhere, books = books.partition {|b| b[:results].empty? }

  unless enabled.empty?
    books.each do |b|
      b[:elsewhere] ||= []
      b[:results].each do |r|
        r[:locations].each do |name, avail| 
          unless enabled.member? name
            r[:locations].delete name
            elsewhere = b[:elsewhere].find {|i| i[:title] == r[:title]} 
            if elsewhere
              elsewhere[:locations][name] = avail
            else
              b[:elsewhere].push({:title => r[:title], :locations => {name => avail}})
            end
          end
        end
      end
    end
  end
  books.each do |b|
    b[:results].delete_if {|r| r[:locations].empty? }
  end

  {:books => books, 
   :last_updated => data['last_updated'],
   :no_results => no_results,
   :only_elsewhere => only_elsewhere,
   :locations => locs,
   :enabled => enabled,
   :branch => branch}
end

def save_enabled_branches(branches)
  username = session[:username]
  redis.del("user:#{username}:branches")
  branches.each {|b| redis.sadd("user:#{username}:branches", b)}
end

def get_enabled_branches
  redis.smembers("user:#{session[:username]}:branches")
end

get '/style.css' do
  sass :style
end

get '/branch/:branch' do |branch|
  haml :index, :locals => build_results(read_from_cache, branch) 
end

get '/branches' do
  branches = locations(read_from_cache['results'])
  enabled = get_enabled_branches
  haml :branches, :locals => {:branches => branches, :enabled => enabled}
end

post '/branches' do
  save_enabled_branches(params.keys)
  redirect '/' 
end

get '/signup' do 
  haml :signup, :locals => {:errors => []}
end

post '/signup' do
  errors = []
  username = params[:username]
  password = params[:password]
  errors << "Username required." unless username
  errors << "Password required." unless password
  errors << "Username '#{username}' already taken, sorry." unless redis.hgetall("user:#{username}").empty?
   
  if errors.empty?
    signup(username, password)
    consumer = OAuth::Consumer.new(@@conf['api_key'], @@conf['secret_key'], :site => 'http://www.goodreads.com')
    request_token = consumer.get_request_token
    redis.hset("oauth:#{request_token.token}", 'username', username)
    redis.hset("oauth:#{request_token.token}", 'token', Marshal.dump(request_token))
    redirect request_token.authorize_url
  else
    haml :signup, :locals => {:errors => errors}
  end
end

get '/oauth-callback' do
  data = redis.hgetall("oauth:#{params[:oauth_token]}")
  request_token = Marshal.load(data['token'])
  access_token = request_token.get_access_token
  redis.hset("user:#{data['username']}", 'oauth_access_token', access_token.token)  
  redis.hset("user:#{data['username']}", 'oauth_access_secret', access_token.secret)  
  client = Goodreads::Client.new(access_token)
  goodreads_id = client.user_id
  redis.hset("user:#{data['username']}", 'goodreads_id', goodreads_id)  
  session[:username] = data['username'] 
  session[:goodreads_id] = goodreads_id
  Resque.enqueue(ShelfLookupWorker, goodreads_id)
  redirect '/'
end

get '/login' do
  haml :login, :locals => {:username => '', :errors => []}
end

post '/login' do
  user = authenticate(params[:username], params[:password])
  pp user
  if user
    user.each {|k,v| session[k] = v}
    redirect '/' 
  else
    haml :login, :locals => {:username => params[:username], 
                             :errors => ['Username and password combination not found.']}
  end
end

get '/' do
  if session[:username]
    cache = read_from_cache
    unless cache.empty?
      haml :index, :locals => build_results(cache) 
    else
      haml :wait
    end
  else
    haml :intro
  end
end
