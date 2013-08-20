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

descartes_secret = Chef::EncryptedDataBagItem.load_secret("#{node['descartes']['secretpath']}")
postgresql_creds = Chef::EncryptedDataBagItem.load("secrets", "postgresql", descartes_secret)

pg_superuser = postgresql_creds['super_user']
pg_superuser_passwd = postgresql_creds['password'][pg_superuser]
pg_appuser = postgresql_creds['app_user']
pg_appuser_passwd = postgresql_creds['password'][pg_appuser]

postgresql_connection_info = { :host     => 'localhost',
                               :port     => node['postgresql']['config']['port'],
                               :username => pg_superuser,
                               :password => pg_superuser_passwd
                             }

postgresql_database 'descartes' do
  connection postgresql_connection_info
  action :create
end

postgresql_database_user pg_appuser do
  connection postgresql_connection_info
  password pg_appuser_passwd
  database_name 'descartes'
  privileges [:all]
  action [:create, :grant]
end

descartes_db_url = "postgres://#{pg_appuser}:#{pg_appuser_passwd}@localhost/descartes"

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

template '/etc/init.d/descartes' do
  source 'init.d.erb'
  owner 'root'
  group 'root'
  mode '0755'
  variables(
   :install_root => node['descartes']['install_root'],
   :user => node['descartes']['user'],
   :group => node['descartes']['group'],
   :thin_port => node['descartes']['thin_port']
  )
end

service 'descartes' do
  supports :status => true, :start => true, :stop => true, :restart => true
  action [:enable] 
end

# Deploy descartes
deploy node['descartes']['install_root'] do
  user node['descartes']['user']
  group node['descartes']['group']
  repository 'git://github.com/obfuscurity/descartes.git'
  revision 'master'
  # env is needed for db migration
  environment :DATABASE_URL => descartes_db_url
  # Override the default behavior i.e. to avoid symlinking database.yml(it is not present in our case)
  symlink_before_migrate ({})
  # Don't create any dir as we don't need any.
  create_dirs_before_symlink []
  # This layout modifier will create symlinks from shared folder to release directory
  # We don't want to create any.
  symlinks ({}) 
            
  before_migrate do
    # Create directory in shared path
    directory "#{new_resource.shared_path}/vendor_bundle" do
      owner new_resource.user
      group new_resource.group
      mode '0755'
    end
    # release_path contains the current release path
    directory "#{release_path}/vendor" do
      owner new_resource.user
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
      variables(
         :DATABASE_URL => descartes_db_url
      )
    end
    # Install gems using bundle install. It will look for a Gemfile.lock in current release
    execute "bundle install --path=vendor/bundle --deployment" do
      Chef::Log.info "Running bundle install"
      cwd release_path
      user new_resource.user
      only_if {::File.exists?(::File.join(release_path, "Gemfile.lock"))}
    end
  end

  migrate true
  migration_command "cd #{node['descartes']['install_root']}/current; bundle exec rake db:migrate:up"
  action :deploy
  notifies :restart, "service[descartes]"
end
