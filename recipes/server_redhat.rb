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

include_recipe "postgresql::client"

svc_name = node['postgresql']['server']['service_name']
dir = node['postgresql']['dir']
initdb_locale = node['postgresql']['initdb_locale']

# Create a group and user like the package will.
# Otherwise the templates fail.

group "postgres" do
  gid 26
end

user "postgres" do
  shell "/bin/bash"
  comment "PostgreSQL Server"
  home "/var/lib/pgsql"
  gid "postgres"
  system true
  uid 26
  supports :manage_home => false
end

directory dir do
  owner "postgres"
  group "postgres"
  recursive true
  action :create
end

node['postgresql']['server']['packages'].each do |pg_pack|

  package pg_pack

end

# Starting with Fedora 16, the pgsql sysconfig files are no longer used.
# The systemd unit file does not support 'initdb' or 'upgrade' actions.
# Use the postgresql-setup script instead.

unless platform_family?("fedora") and node['platform_version'].to_i >= 16

  directory "/etc/sysconfig/pgsql" do
    mode "0644"
    recursive true
    action :create
  end

  template "/etc/sysconfig/pgsql/#{svc_name}" do
    source "pgsql.sysconfig.erb"
    mode "0644"
    notifies :restart, "service[postgresql]", :delayed
  end

end

bash 'replicate slave from master' do
  user 'postgres'
  flags '-x -v'
  code <<-EOH
  cd #{node['postgresql']['config']['data_directory']} && \
  pg_basebackup -w -R -h #{node['postgresql']['master_ip']} --dbname="host=#{node['postgresql']['master_ip']} user=#{node['postgresql']['recovery_user']} password=#{node['postgresql']['recovery_user_pass']}" -D - -P -Ft | bzip2 > /tmp/pg_basebackup.tar.bz2 && \
  rm -rf * && \
  tar -xjvf /tmp/pg_basebackup.tar.bz2 && \
  sleep 1 && \
  touch ./slave_synced
  EOH
  action :run
  only_if { !File.exists?("#{node['postgresql']['config']['data_directory']}/slave_synced") && node['postgresql']['recovery']['standby_mode'] == 'on' }
end

if platform_family?("fedora") and node['platform_version'].to_i >= 16

  execute "postgresql-setup initdb #{svc_name}" do
    not_if { ::FileTest.exist?(File.join(dir, "PG_VERSION")) }
  end

elsif platform?("redhat") and node['platform_version'].to_i >= 7

  execute "postgresql#{node['postgresql']['version'].split('.').join}-setup initdb #{svc_name}" do
    not_if { ::FileTest.exist?(File.join(dir, "PG_VERSION")) }
  end

elsif platform?("centos") and node['platform_version'].to_i >= 7

  execute "/usr/pgsql-#{node['postgresql']['version']}/bin/postgresql#{node['postgresql']['version'].split('.').join}-setup initdb #{svc_name}" do
    not_if { ::FileTest.exist?(File.join(dir, "PG_VERSION")) }
  end

else
  unless platform_family?("suse")

    execute "/sbin/service #{node['postgresql']['server']['service_name']} initdb #{node['postgresql']['initdb_locale']}" do
      not_if { ::FileTest.exist?(File.join(node['postgresql']['dir'], "PG_VERSION")) }
    end

  end
end
if platform_family?('fedora')
  provider_service = Chef::Provider::Service::Systemd
else
  provider_service = Chef::Provider::Service::Init
end

include_recipe "postgresql::server_conf"

service "postgresql" do
  service_name svc_name
  supports :restart => true, :status => true, :reload => true
  action [:enable, :start]
end
