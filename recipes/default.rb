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
                               :password => node['postgresql']['password']['postgres'] 
                             }

postgresql_database 'descartes' do
  connection postgresql_connection_info
  action :create
end

=begin
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
=end

# Install bundler
# Rest of the gems will be installed using bundle install
gem_package 'bundler' do
  action :install
end

# These are the packages required for nokogiri gem
%w{gcc ruby-devel libxml2 libxml2-devel libxslt libxslt-devel}.each do |pkg|
  package pkg do
    action :install
  end
end

group node['descartes']['group'] do
  gid node['descartes']['gid']
  system true
  action :create
end


# Create user for descartes
user node['descartes']['user'] do
  uid node['descartes']['uid']
  gid node['descartes']['gid']
  # should the user be system ?
  system true
  action :create
end

service 'descartes' do
  supports :status => true, :start => true, :stop => true, :restart => true
  action [:enable] 
end

# Deploy descartes
deploy node['descartes']['install_root'] do
  user node['descartes']['user']
  repository 'git://github.com/obfuscurity/descartes.git'
  revision 'master'
  # Override the default behavior i.e. to avoid symlinking database.yml(it is not present in our case)
  symlink_before_migrate ({})
  # Don't create any dir as we don't need any.
  create_dirs_before_symlink []
  # This layout modifier will create symlinks from shared folder to release directory
  symlinks  "pids" => "pids", 
            "logs" => "logs" 

  before_migrate do
    # Create directorioes in shared path
    %w{vendor_bundle pids logs}.each do |dname|
      directory "#{new_resource.shared_path}/#{dname}" do
        user new_resource.user
        group new_resource.group
        mode '0755'
      end
    end

    # release_path contains the current release path
    directory "#{release_path}/vendor" do
      user new_resource.user
      group new_resource.group
      mode '0755'
    end

    link "#{release_path}/vendor/bundle" do
      to "#{new_resource.shared_path}/vendor_bundle"
    end
   
    # Create a file for all the required env variables for descartes
    template "#{node['descartes']['install_root']}/shared/env" do
      source 'descartes-env.erb'
      owner new_resource.user
      group new_resource.group
      mode '0644'
    end

    # Install gems using bundle install. It will look for a Gemfile.lock in current release
    execute "bundle install --path=vendor/bundle --deployment" do
      Chef::Log.info "Running bundle install"
      cwd release_path
      user new_resource.user
      #environment new_resource.environment
      only_if {::File.exists?(::File.join(release_path, "Gemfile.lock"))}
    end

  end
  
  before_restart do
    template '/etc/init.d/descartes' do
    source 'init.d.erb'
    owner 'root'
    group 'root'
    mode '0755'
    variables(
     :install_root => node['descartes']['install_root'],
     :user => node['descartes']['user'],
     :thin_port => node['descartes']['thin_port']
    )
    end
  end

  migrate true
  migration_command "cd #{node['descartes']['install_root']}/current; bundle exec rake db:migrate:up"
  #environment descartes_env
  action :deploy
  notifies :restart, "service[descartes]"
end
