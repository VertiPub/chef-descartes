#
# Cookbook Name:: descartes
# Recipe:: default
#
# Copyright 2013, RideCharge, Inc.
#
# All rights reserved - Do Not Redistribute
#

include_recipe 'postgresql::server'
include_recipe 'database::postgresql'
include_recipe 'redis'

postgresql_connection_info = { :host     => 'localhost',
                               :port     => node['postgresql']['config']['port'],
                               :username => node['postgresql']['user'],
                               :password => node['postgresql']['password']['postgres'] }

postgresql_database 'descartes' do
  connection postgresql_connection_info
  action :create
end

descartes_env = {
  "DATABASE_URL" => "postgres://#{node['postgresql']['user']}:#{node['postgresql']['password']['postgres']}@localhost/descartes",
  "RACK_ENV" => 'production',
  "SESSION_SECRET" => node['descartes']['session_secret'],
  "GRAPHITE_URL" => node['descartes']['graphite_url'],
  "OAUTH_PROVIDER" => node['descartes']['oauth_provider'],
  "GOOGLE_OAUTH_DOMAIN" => node['descartes']['google_oauth_domain'],
  "METRICS_UPDATE_INTERVAL" => node['descartes']['metrics_update_interval']
}
descartes_env['GRAPHITE_USER'] = node['descartes']['graphite_user'] if node['descartes']['graphite_user']
descartes_env['GRAPHITE_PASS'] = node['descartes']['graphite_pass'] if node['descartes']['graphite_pass']
descartes_env['API_KEY'] = node['descartes']['api_key'] if node['descartes']['api_key']

#Install all the required gems, in this case it will just install bundler
#Rest of the gems will be installed using bundle install
node['descartes']['gems'].each do | gem |
    gem_package gem['name'] do
        action :install
        version gem['version']
    end
end

# These are the packages required for nokogiri gem
%w{gcc ruby-devel libxml2 libxml2-devel libxslt libxslt-devel}.each do |pkg|
  package pkg do
    action :install
  end
end

#create user for descartes
user node['descartes']['user']

#Deploy descartes
deploy "#{node['descartes']['install_root']}" do
  user node['descartes']['user']
  repository 'git://github.com/obfuscurity/descartes.git'
  revision 'master'

#Override the default behavior i.e. to avoid symlinking database.yml(it is not present in our case)

  symlink_before_migrate({})

#Don't create any dir as we don't need any.
  create_dirs_before_symlink   %w{}

#This layout modifier will create symlinks from shared folder to release directory
  symlinks   "pids" => "pids", 
             "log" => "log"

#Following callback will create the required directory in shared and current release directory
#and then will be running bundle install to install gems in vendor/bundle directory
#release_path contains the path to current release

  before_migrate do
   #create directorioes in shared path
    %w{vendor_bundle pids log}.each do |dname|
      directory "#{new_resource.shared_path}/#{dname}" do
        user new_resource.user
        group new_resource.group
        mode '0755'
      end
    end

   #Release path contains the current release path
      directory "#{release_path}/vendor" do
        user new_resource.user
        group new_resource.group
        mode '0755'
      end

    link "#{release_path}/vendor/bundle" do
      to "#{new_resource.shared_path}/vendor_bundle"
    end
  
   #install gems using bundle install. It will look for a Gemfile.lock in current release
    execute "bundle install --path=vendor/bundle --deployment" do
      Chef::Log.info "Running bundle install"
      cwd release_path
      user new_resource.user
      environment new_resource.environment
      only_if { ::File.exists?(::File.join(release_path, "Gemfile.lock")) }
    end
 end

  migrate false
  migration_command "cd #{node['descartes']['install_root']}/current; bundle exec rake db:migrate:up"

  environment descartes_env
  action :deploy

 #This before_restart callback will first stop any of the running instances.
  before_restart do
    execute "stop-descartes" do
      Chef::Log.info "Stop if descartes is running"
      cwd release_path
      user node['descartes']['user']
      pid_file = "pids/descartes.pid"
      command "if [ -f #{pid_file} ] && [ -e /proc/$(cat #{pid_file}) ]; then kill -9 `cat #{pid_file}`; fi"
      action :run
    end
  end

  notifies :run, "execute[start-descartes]"	

end


execute "start-descartes" do
  Chef::Log.info "Start descartes"
  cwd "#{node['descartes']['install_root']}/current"
  user node['descartes']['user']
  command "bundle exec rackup -p #{node['descartes']['thin_port']} -s thin -P pids/descartes.pid -D"
  environment descartes_env
  action :nothing
end

