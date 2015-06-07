#
# Cookbook Name:: postgresql
# Recipe:: server
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

::Chef::Recipe.send(:include, Opscode::OpenSSL::Password)

include_recipe "postgresql::client"

# randomly generate postgres password, unless using solo - see README
if Chef::Config[:solo]
  missing_attrs = %w{
    postgres
  }.select do |attr|
    node['postgresql']['password'][attr].nil?
  end.map { |attr| "node['postgresql']['password']['#{attr}']" }

  if !missing_attrs.empty?
    Chef::Log.fatal([
        "You must set #{missing_attrs.join(', ')} in chef-solo mode.",
        "For more information, see https://github.com/opscode-cookbooks/postgresql#chef-solo-note"
      ].join(' '))
    raise
  end
else
  # TODO: The "secure_password" is randomly generated plain text, so it
  # should be converted to a PostgreSQL specific "encrypted password" if
  # it should actually install a password (as opposed to disable password
  # login for user 'postgres'). However, a random password wouldn't be
  # useful if it weren't saved as clear text in Chef Server for later
  # retrieval.
  unless node.key?('postgresql') && node['postgresql'].key?('password') && node['postgresql']['password'].key?('postgres')
    node.set_unless['postgresql']['password']['postgres'] = secure_password
    node.save
  end
end

# Include the right "family" recipe for installing the server
# since they do things slightly differently.
case node['platform_family']
when "rhel", "fedora", "suse"
  include_recipe "postgresql::server_redhat"
when "debian"
  include_recipe "postgresql::server_debian"
end

template "#{node['postgresql']['dir']}/recovery.conf" do
  source "recovery.conf.erb"
  owner "postgres"
  group "postgres"
  mode 0600
  notifies :reload, 'service[postgresql]', :immediately
  only_if { node['postgresql']['recovery']['standby_mode'] == 'on' }
end

# Versions prior to 9.2 do not have a config file option to set the SSL
# key and cert path, and instead expect them to be in a specific location.
if node['postgresql']['version'].to_f < 9.2 && node['postgresql']['config'].attribute?('ssl_cert_file')
  link ::File.join(node['postgresql']['config']['data_directory'], 'server.crt') do
    to node['postgresql']['config']['ssl_cert_file']
  end
end

if node['postgresql']['version'].to_f < 9.2 && node['postgresql']['config'].attribute?('ssl_key_file')
  link ::File.join(node['postgresql']['config']['data_directory'], 'server.key') do
    to node['postgresql']['config']['ssl_key_file']
  end
end

# NOTE: Consider two facts before modifying "assign-postgres-password":
# (1) Passing the "ALTER ROLE ..." through the psql command only works
#     if passwordless authorization was configured for local connections.
#     For example, if pg_hba.conf has a "local all postgres ident" rule.
# (2) It is probably fruitless to optimize this with a not_if to avoid
#     setting the same password. This chef recipe doesn't have access to
#     the plain text password, and testing the encrypted (md5 digest)
#     version is not straight-forward.
bash "create replica user" do
  user 'postgres'
  code <<-EOH
echo "CREATE USER #{node['postgresql']['recovery_user']} REPLICATION ENCRYPTED PASSWORD '#{node['postgresql']['recovery_user_pass']}';" | psql
  EOH
  action :run
  only_if { node['postgresql']['recovery_user'].size > 0 && node['postgresql']['recovery_user_pass'].size > 0 && node['postgresql']['recovery']['standby_mode'] == 'off'}
end

execute 'stop pg' do
  command 'echo "stop postgresql"'
  notifies :stop, 'service[postgresql]', :immediately
  only_if { !File.exists?("#{node['postgresql']['config']['data_directory']}/slave_synced") && node['postgresql']['recovery']['standby_mode'] == 'on' }
end
bash "replicate slave from master" do
  user 'postgres'
  code <<-EOH
  pg_basebackup -w -R -h #{node['postgresql']['master_ip']} --dbname="host=#{node['postgresql']['master_ip']} user=#{node['postgresql']['recovery_user']} password=#{node['postgresql']['recovery_user_pass']}" -D - -P -Ft | bzip2 > /tmp/pg_basebackup.tar.bz2
  cd #{node['postgresql']['config']['data_directory']}
  rm -rf *
  tar -xjvf /tmp/pg_basebackup.tar.bz2
  sleep 1
  touch ./slave_synced
  EOH
  action :run
  notifies :restart, 'service[postgresql]', :immediately
  only_if { !File.exists?("#{node['postgresql']['config']['data_directory']}/slave_synced") && node['postgresql']['recovery']['standby_mode'] == 'on' }
end

bash "assign-postgres-password" do
  user 'postgres'
  code <<-EOH
  echo "ALTER ROLE postgres ENCRYPTED PASSWORD '#{node['postgresql']['password']['postgres']}';" | psql -p #{node['postgresql']['config']['port']}
  EOH
  not_if { node['postgresql']['recovery']['standby_mode'] == 'on' }
  action :run
  not_if "ls #{node['postgresql']['config']['data_directory']}/recovery.conf"
  only_if { node['postgresql']['assign_postgres_password'] }
end
