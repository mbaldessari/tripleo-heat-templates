# Copyright 2015 Red Hat, Inc.
# All Rights Reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License"); you may
# not use this file except in compliance with the License. You may obtain
# a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
# WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
# License for the specific language governing permissions and limitations
# under the License.

class pcmk_node_tag_controller($node) {
  define process_property {
    pacemaker::property { "property $name-osprole-controller":
      node     => $name,
      property => 'osprole',
      value    => 'controller',
    }
  }
  process_property { $node: } 
}

class pcmk_node_tag_compute($node) {
  define process_property {
    pacemaker::property { "property $name-osprole-compute":
      node     => $name,
      property => 'osprole',
      value    => 'compute',
    }
  }
  process_property { $node: } 
}

class pcmk_node_stonith_compute($node) {
  define process_property {
    exec { "property stonith $node-$name":
      command => "/usr/sbin/pcs stonith level add 1 stonith-fence_xvm-${name} ${name},fence-nova",
      onlyif  => "/usr/sbin/pcs stonith level | grep -v ${name}",
      require => [ Exec["wait-for-settle"],
                   Class['::pacemaker::corosync']],
    }
  }
  process_property { $node: } 
}

Pcmk_resource <| |> {
  tries     => 10,
  try_sleep => 3,
}

include ::tripleo::packages
include ::tripleo::firewall

if $::hostname == downcase(hiera('bootstrap_nodeid')) {
  $pacemaker_master = true
  $sync_db = true
} else {
  $pacemaker_master = false
  $sync_db = false
}

$instance_ha = hiera('instance_ha')
$pacemaker_admin_uri = hiera('pacemaker_admin_uri')
$admin_password = hiera('admin_password')

$enable_fencing = str2bool(hiera('enable_fencing', false)) and hiera('step') >= 5
$enable_load_balancer = hiera('enable_load_balancer', true)

# When to start and enable services which haven't been Pacemakerized
# FIXME: remove when we start all OpenStack services using Pacemaker
# (occurences of this variable will be gradually replaced with false)
$non_pcmk_start = hiera('step') >= 4

if hiera('step') >= 1 {

  create_resources(sysctl::value, hiera('sysctl_settings'), {})

  include ::timezone

  if count(hiera('ntp::servers')) > 0 {
    include ::ntp
  }

  $controller_node_ips = split(hiera('controller_node_ips'), ',')
  $controller_node_names = split(downcase(hiera('controller_node_names')), ',')
  if $enable_load_balancer {
    class { '::tripleo::loadbalancer' :
      controller_hosts       => $controller_node_ips,
      controller_hosts_names => $controller_node_names,
      manage_vip             => false,
      mysql_clustercheck     => true,
      haproxy_service_manage => false,
    }
  }

  $pacemaker_cluster_members = downcase(regsubst(hiera('controller_node_names'), ',', ' ', 'G'))
  user { 'hacluster':
    ensure => present,
  } ->
  class { '::pacemaker':
    hacluster_pwd => hiera('hacluster_pwd'),
  } ->
  class { '::pacemaker::corosync':
    cluster_members => $pacemaker_cluster_members,
    setup_cluster   => $pacemaker_master,
    remote_authkey  => hiera('pacemaker_remote_pwd'),
  }
  class { '::pacemaker::stonith':
    disable => !$enable_fencing,
  }
  if $enable_fencing {
    include ::tripleo::fencing

    # enable stonith after all fencing devices have been created
    Class['tripleo::fencing'] -> Class['pacemaker::stonith']
  }

  # Step 11
  if $instance_ha {
    class { "pcmk_node_tag_controller":
      node => $controller_node_names,
    }
  }

  # FIXME(gfidente): sets 200secs as default start timeout op
  # param; until we can use pcmk global defaults we'll still
  # need to add it to every resource which redefines op params
  Pacemaker::Resource::Service {
    op_params => 'start timeout=200s stop timeout=200s',
  }

  # Only configure RabbitMQ in this step, don't start it yet to
  # avoid races where non-master nodes attempt to start without
  # config (eg. binding on 0.0.0.0)
  # The module ignores erlang_cookie if cluster_config is false
  class { '::rabbitmq':
    service_manage          => false,
    tcp_keepalive           => false,
    config_kernel_variables => hiera('rabbitmq_kernel_variables'),
    config_variables        => hiera('rabbitmq_config_variables'),
    environment_variables   => hiera('rabbitmq_environment'),
  } ->
  file { '/var/lib/rabbitmq/.erlang.cookie':
    ensure  => file,
    owner   => 'rabbitmq',
    group   => 'rabbitmq',
    mode    => '0400',
    content => hiera('rabbitmq::erlang_cookie'),
    replace => true,
  }

  if downcase(hiera('ceilometer_backend')) == 'mongodb' {
    include ::mongodb::globals
    class { '::mongodb::server' :
      service_manage => false,
    }
  }

  # Memcached
  class {'::memcached' :
    service_manage => false,
  }

  # Redis
  class { '::redis' :
    service_manage => false,
    notify_service => false,
  }

  # Galera
  if str2bool(hiera('enable_galera', true)) {
    $mysql_config_file = '/etc/my.cnf.d/galera.cnf'
  } else {
    $mysql_config_file = '/etc/my.cnf.d/server.cnf'
  }
  $galera_nodes = downcase(hiera('galera_node_names', $::hostname))
  $galera_nodes_count = count(split($galera_nodes, ','))

  $mysqld_options = {
    'mysqld' => {
      'skip-name-resolve'             => '1',
      'binlog_format'                 => 'ROW',
      'default-storage-engine'        => 'innodb',
      'innodb_autoinc_lock_mode'      => '2',
      'innodb_locks_unsafe_for_binlog'=> '1',
      'query_cache_size'              => '0',
      'query_cache_type'              => '0',
      'bind-address'                  => hiera('mysql_bind_host'),
      'max_connections'               => hiera('mysql_max_connections'),
      'open_files_limit'              => '-1',
      'wsrep_provider'                => '/usr/lib64/galera/libgalera_smm.so',
      'wsrep_cluster_name'            => 'galera_cluster',
      'wsrep_slave_threads'           => '1',
      'wsrep_certify_nonPK'           => '1',
      'wsrep_max_ws_rows'             => '131072',
      'wsrep_max_ws_size'             => '1073741824',
      'wsrep_debug'                   => '0',
      'wsrep_convert_LOCK_to_trx'     => '0',
      'wsrep_retry_autocommit'        => '1',
      'wsrep_auto_increment_control'  => '1',
      'wsrep_drupal_282555_workaround'=> '0',
      'wsrep_causal_reads'            => '0',
      'wsrep_sst_method'              => 'rsync',
    },
  }

  class { '::mysql::server':
    create_root_user        => false,
    create_root_my_cnf      => false,
    config_file             => $mysql_config_file,
    override_options        => $mysqld_options,
    remove_default_accounts => $pacemaker_master,
    service_manage          => false,
    service_enabled         => false,
  }

}

if hiera('step') >= 2 {

  # NOTE(gfidente): the following vars are needed on all nodes so they
  # need to stay out of pacemaker_master conditional
  $mongo_node_ips_with_port = suffix(hiera('mongo_node_ips'), ':27017')
  $mongodb_replset = hiera('mongodb::server::replset')

  if $pacemaker_master {

    if $enable_load_balancer {

      include ::pacemaker::resource_defaults

      # FIXME: we should not have to access tripleo::loadbalancer class
      # parameters here to configure pacemaker VIPs. The configuration
      # of pacemaker VIPs could move into puppet-tripleo or we should
      # make use of less specific hiera parameters here for the settings.
      pacemaker::resource::service { 'haproxy':
        clone_params => true,
      }
      if $instance_ha {
        pacemaker::constraint::location_rule { 'haproxy-controller':
          resource           => 'haproxy-clone',
          expression         => 'osprole eq controller',
          resource_discovery => 'exclusive',
          score              => 0,
          require            => Pacemaker::Resource::Service['haproxy'],
        }
      }
      $control_vip = hiera('tripleo::loadbalancer::controller_virtual_ip')
      pacemaker::resource::ip { 'control_vip':
        ip_address => $control_vip,
      }
      if $instance_ha {
        pacemaker::constraint::location_rule { 'controller_vip-ctrl':
          resource           => "ip-${control_vip}",
          expression         => 'osprole eq controller',
          resource_discovery => 'exclusive',
          score              => 0,
          require            => Pacemaker::Resource::Ip['control_vip'],
       }
      }
      pacemaker::constraint::base { 'control_vip-then-haproxy':
        constraint_type   => 'order',
        first_resource    => "ip-${control_vip}",
        second_resource   => 'haproxy-clone',
        first_action      => 'start',
        second_action     => 'start',
        constraint_params => 'kind=Optional',
        require           => [Pacemaker::Resource::Service['haproxy'],
                              Pacemaker::Resource::Ip['control_vip']],
      }
      pacemaker::constraint::colocation { 'control_vip-with-haproxy':
        source  => "ip-${control_vip}",
        target  => 'haproxy-clone',
        score   => 'INFINITY',
        require => [Pacemaker::Resource::Service['haproxy'],
                    Pacemaker::Resource::Ip['control_vip']],
      }

      $public_vip = hiera('tripleo::loadbalancer::public_virtual_ip')
      if $public_vip and $public_vip != $control_vip {
        pacemaker::resource::ip { 'public_vip':
          ip_address => $public_vip,
        }
        if $instance_ha {
          pacemaker::constraint::location_rule { 'public_vip-ctrl':
            resource           => "ip-${public_vip}",
            expression         => 'osprole eq controller',
            resource_discovery => 'exclusive',
            score              => 0,
            require            => Pacemaker::Resource::Ip['public_vip'],
          }
        }
        pacemaker::constraint::base { 'public_vip-then-haproxy':
          constraint_type   => 'order',
          first_resource    => "ip-${public_vip}",
          second_resource   => 'haproxy-clone',
          first_action      => 'start',
          second_action     => 'start',
          constraint_params => 'kind=Optional',
          require           => [Pacemaker::Resource::Service['haproxy'],
                                Pacemaker::Resource::Ip['public_vip']],
        }
        pacemaker::constraint::colocation { 'public_vip-with-haproxy':
          source  => "ip-${public_vip}",
          target  => 'haproxy-clone',
          score   => 'INFINITY',
          require => [Pacemaker::Resource::Service['haproxy'],
                      Pacemaker::Resource::Ip['public_vip']],
        }
      }

      $redis_vip = hiera('redis_vip')
      if $redis_vip and $redis_vip != $control_vip {
        pacemaker::resource::ip { 'redis_vip':
          ip_address => $redis_vip,
        }
        if $instance_ha {
          pacemaker::constraint::location_rule { 'redis_vip-ctrl':
            resource           => "ip-${redis_vip}",
            expression         => 'osprole eq controller',
            resource_discovery => 'exclusive',
            score              => 0,
            require            => Pacemaker::Resource::Ip['redis_vip'],
          }
        }
        pacemaker::constraint::base { 'redis_vip-then-haproxy':
          constraint_type   => 'order',
          first_resource    => "ip-${redis_vip}",
          second_resource   => 'haproxy-clone',
          first_action      => 'start',
          second_action     => 'start',
          constraint_params => 'kind=Optional',
          require           => [Pacemaker::Resource::Service['haproxy'],
                                Pacemaker::Resource::Ip['redis_vip']],
        }
        pacemaker::constraint::colocation { 'redis_vip-with-haproxy':
          source  => "ip-${redis_vip}",
          target  => 'haproxy-clone',
          score   => 'INFINITY',
          require => [Pacemaker::Resource::Service['haproxy'],
                      Pacemaker::Resource::Ip['redis_vip']],
        }
      }

      $internal_api_vip = hiera('tripleo::loadbalancer::internal_api_virtual_ip')
      if $internal_api_vip and $internal_api_vip != $control_vip {
        pacemaker::resource::ip { 'internal_api_vip':
          ip_address => $internal_api_vip,
        }
        if $instance_ha {
          pacemaker::constraint::location_rule { 'internal_vip-ctrl':
            resource           => "ip-${internal_api_vip}",
            expression         => 'osprole eq controller',
            resource_discovery => 'exclusive',
            score              => 0,
            require            => Pacemaker::Resource::Ip['internal_api_vip'],
          }
        }
        pacemaker::constraint::base { 'internal_api_vip-then-haproxy':
          constraint_type   => 'order',
          first_resource    => "ip-${internal_api_vip}", 
          second_resource   => 'haproxy-clone',
          first_action      => 'start',
          second_action     => 'start',
          constraint_params => 'kind=Optional',
          require           => [Pacemaker::Resource::Service['haproxy'],
                                Pacemaker::Resource::Ip['internal_api_vip']],
        }
        pacemaker::constraint::colocation { 'internal_api_vip-with-haproxy':
          source  => "ip-${internal_api_vip}",
          target  => 'haproxy-clone',
          score   => 'INFINITY',
          require => [Pacemaker::Resource::Service['haproxy'],
                      Pacemaker::Resource::Ip['internal_api_vip']],
        }
      }

      $storage_vip = hiera('tripleo::loadbalancer::storage_virtual_ip')
      if $storage_vip and $storage_vip != $control_vip {
        pacemaker::resource::ip { 'storage_vip':
          ip_address => $storage_vip,
        }
        if $instance_ha {
          pacemaker::constraint::location_rule { 'storage_vip-ctrl':
            resource           => "ip-${storage_vip}",
            expression         => 'osprole eq controller',
            resource_discovery => 'exclusive',
            score              => 0,
            require            => Pacemaker::Resource::Ip['storage_vip'],
          }
        }
        pacemaker::constraint::base { 'storage_vip-then-haproxy':
          constraint_type   => 'order',
          first_resource    => "ip-${storage_vip}",
          second_resource   => 'haproxy-clone',
          first_action      => 'start',
          second_action     => 'start',
          constraint_params => 'kind=Optional',
          require           => [Pacemaker::Resource::Service['haproxy'],
                                Pacemaker::Resource::Ip['storage_vip']],
        }
        pacemaker::constraint::colocation { 'storage_vip-with-haproxy':
          source  => "ip-${storage_vip}",
          target  => 'haproxy-clone',
          score   => 'INFINITY',
          require => [Pacemaker::Resource::Service['haproxy'],
                      Pacemaker::Resource::Ip['storage_vip']],
        }
      }

      $storage_mgmt_vip = hiera('tripleo::loadbalancer::storage_mgmt_virtual_ip')
      if $storage_mgmt_vip and $storage_mgmt_vip != $control_vip {
        pacemaker::resource::ip { 'storage_mgmt_vip':
          ip_address => $storage_mgmt_vip,
        }
        if $instance_ha {
          pacemaker::constraint::location_rule { 'storage_mgmt_vip-ctrl':
            resource           => "ip-${storage_mgmt_vip}",
            expression         => 'osprole eq controller',
            resource_discovery => 'exclusive',
            score              => 0,
            require            => Pacemaker::Resource::Ip['storage_mgmt_vip'],
          }
        }
        pacemaker::constraint::base { 'storage_mgmt_vip-then-haproxy':
          constraint_type   => 'order',
          first_resource    => "ip-${storage_mgmt_vip}",
          second_resource   => 'haproxy-clone',
          first_action      => 'start',
          second_action     => 'start',
          constraint_params => 'kind=Optional',
          require           => [Pacemaker::Resource::Service['haproxy'],
                                Pacemaker::Resource::Ip['storage_mgmt_vip']],
        }
        pacemaker::constraint::colocation { 'storage_mgmt_vip-with-haproxy':
          source  => "ip-${storage_mgmt_vip}",
          target  => 'haproxy-clone',
          score   => 'INFINITY',
          require => [Pacemaker::Resource::Service['haproxy'],
                      Pacemaker::Resource::Ip['storage_mgmt_vip']],
        }
      }

    }

    pacemaker::resource::service { $::memcached::params::service_name :
      clone_params => 'interleave=true',
      require      => Class['::memcached'],
    }
    if $instance_ha {
      pacemaker::constraint::location_rule { "${::memcached::params::service_name}-controller":
        resource           => "${::memcached::params::service_name}-clone",
        expression         => 'osprole eq controller',
        resource_discovery => 'exclusive',
        score              => 0,
        require            => Pacemaker::Resource::Service[$::memcached::params::service_name],
      }
    }

    pacemaker::resource::ocf { 'rabbitmq':
      ocf_agent_name  => 'heartbeat:rabbitmq-cluster',
      resource_params => 'set_policy=\'ha-all ^(?!amq\.).* {"ha-mode":"all"}\'',
      clone_params    => 'ordered=true interleave=true',
      require         => Class['::rabbitmq'],
    }
    if $instance_ha {
      pacemaker::constraint::location_rule { "rabbitmq-controller":
        resource           => "rabbitmq-clone",
        expression         => 'osprole eq controller',
        resource_discovery => 'exclusive',
        score              => 0,
        require            => Pacemaker::Resource::Ocf["rabbitmq"],
      }
    }
    if downcase(hiera('ceilometer_backend')) == 'mongodb' {
      pacemaker::resource::service { $::mongodb::params::service_name :
        op_params    => 'start timeout=370s stop timeout=200s',
        clone_params => true,
        require      => Class['::mongodb::server'],
      }
      if $instance_ha {
        pacemaker::constraint::location_rule { "${::mongodb::params::service_name}-controller":
          resource           => "${::mongodb::params::service_name}-clone",
          expression         => 'osprole eq controller',
          resource_discovery => 'exclusive',
          score              => 0,
          require            => Pacemaker::Resource::Service[$::mongodb::params::service_name],
        }
      }
      # NOTE (spredzy) : The replset can only be run
      # once all the nodes have joined the cluster.
      mongodb_conn_validator { $mongo_node_ips_with_port :
        timeout => '600',
        require => Pacemaker::Resource::Service[$::mongodb::params::service_name],
        before  => Mongodb_replset[$mongodb_replset],
      }
      mongodb_replset { $mongodb_replset :
        members => $mongo_node_ips_with_port,
      }
    }

    pacemaker::resource::ocf { 'galera' :
      ocf_agent_name  => 'heartbeat:galera',
      op_params       => 'promote timeout=300s on-fail=block',
      master_params   => '',
      meta_params     => "master-max=${galera_nodes_count} ordered=true",
      resource_params => "additional_parameters='--open-files-limit=16384' enable_creation=true wsrep_cluster_address='gcomm://${galera_nodes}'",
      require         => Class['::mysql::server'],
      before          => Exec['galera-ready'],
    }
    if $instance_ha {
      pacemaker::constraint::location_rule { "galera-controller":
        resource           => "galera-master",
        expression         => 'osprole eq controller',
        resource_discovery => 'exclusive',
        score              => 0,
        require            => Pacemaker::Resource::Ocf['galera'],
      }
    }

    pacemaker::resource::ocf { 'redis':
      ocf_agent_name  => 'heartbeat:redis',
      master_params   => '',
      meta_params     => 'notify=true ordered=true interleave=true',
      resource_params => 'wait_last_known_master=true',
      require         => Class['::redis'],
    }
    if $instance_ha {
      pacemaker::constraint::location_rule { "redis-controller":
        resource           => "redis-master",
        expression         => 'osprole eq controller',
        resource_discovery => 'exclusive',
        score              => 0,
        require            => Pacemaker::Resource::Ocf['redis'],
      }
    }
  }

  exec { 'galera-ready' :
    command     => '/usr/bin/clustercheck >/dev/null',
    timeout     => 30,
    tries       => 180,
    try_sleep   => 10,
    environment => ['AVAILABLE_WHEN_READONLY=0'],
    require     => File['/etc/sysconfig/clustercheck'],
  }

  file { '/etc/sysconfig/clustercheck' :
    ensure  => file,
    content => "MYSQL_USERNAME=root\n
MYSQL_PASSWORD=''\n
MYSQL_HOST=localhost\n",
  }

  xinetd::service { 'galera-monitor' :
    port           => '9200',
    server         => '/usr/bin/clustercheck',
    per_source     => 'UNLIMITED',
    log_on_success => '',
    log_on_failure => 'HOST',
    flags          => 'REUSE',
    service_type   => 'UNLISTED',
    user           => 'root',
    group          => 'root',
    require        => File['/etc/sysconfig/clustercheck'],
  }

  # Create all the database schemas
  if $sync_db {
    class { '::keystone::db::mysql':
      require => Exec['galera-ready'],
    }
    class { '::glance::db::mysql':
      require => Exec['galera-ready'],
    }
    class { '::nova::db::mysql':
      require => Exec['galera-ready'],
    }
    class { '::neutron::db::mysql':
      require => Exec['galera-ready'],
    }
    class { '::cinder::db::mysql':
      require => Exec['galera-ready'],
    }
    class { '::heat::db::mysql':
      require => Exec['galera-ready'],
    }

    if downcase(hiera('ceilometer_backend')) == 'mysql' {
      class { '::ceilometer::db::mysql':
        require => Exec['galera-ready'],
      }
    }

    class { '::sahara::db::mysql':
      require       => Exec['galera-ready'],
    }
  }

  # pre-install swift here so we can build rings
  include ::swift

  # Ceph
  $enable_ceph = hiera('ceph_storage_count', 0) > 0 or hiera('enable_ceph_storage', false)

  if $enable_ceph {
    class { '::ceph::profile::params':
      mon_initial_members => downcase(hiera('ceph_mon_initial_members')),
    }
    include ::ceph::conf
    include ::ceph::profile::mon
  }

  if str2bool(hiera('enable_ceph_storage', false)) {
    if str2bool(hiera('ceph_osd_selinux_permissive', true)) {
      exec { 'set selinux to permissive on boot':
        command => "sed -ie 's/^SELINUX=.*/SELINUX=permissive/' /etc/selinux/config",
        onlyif  => "test -f /etc/selinux/config && ! grep '^SELINUX=permissive' /etc/selinux/config",
        path    => ['/usr/bin', '/usr/sbin'],
      }

      exec { 'set selinux to permissive':
        command => 'setenforce 0',
        onlyif  => "which setenforce && getenforce | grep -i 'enforcing'",
        path    => ['/usr/bin', '/usr/sbin'],
      } -> Class['ceph::profile::osd']
    }

    include ::ceph::conf
    include ::ceph::profile::osd
  }

  if str2bool(hiera('enable_external_ceph', false)) {
    include ::ceph::conf
    include ::ceph::profile::client
  }


} #END STEP 2

if hiera('step') >= 3 {

  class { '::keystone':
    sync_db        => $sync_db,
    manage_service => false,
    enabled        => false,
  }
  include ::keystone::config

  #TODO: need a cleanup-keystone-tokens.sh solution here

  file { [ '/etc/keystone/ssl', '/etc/keystone/ssl/certs', '/etc/keystone/ssl/private' ]:
    ensure  => 'directory',
    owner   => 'keystone',
    group   => 'keystone',
    require => Package['keystone'],
  }
  file { '/etc/keystone/ssl/certs/signing_cert.pem':
    content => hiera('keystone_signing_certificate'),
    owner   => 'keystone',
    group   => 'keystone',
    notify  => Service['keystone'],
    require => File['/etc/keystone/ssl/certs'],
  }
  file { '/etc/keystone/ssl/private/signing_key.pem':
    content => hiera('keystone_signing_key'),
    owner   => 'keystone',
    group   => 'keystone',
    notify  => Service['keystone'],
    require => File['/etc/keystone/ssl/private'],
  }
  file { '/etc/keystone/ssl/certs/ca.pem':
    content => hiera('keystone_ca_certificate'),
    owner   => 'keystone',
    group   => 'keystone',
    notify  => Service['keystone'],
    require => File['/etc/keystone/ssl/certs'],
  }

  $glance_backend = downcase(hiera('glance_backend', 'swift'))
  case $glance_backend {
      'swift': { $backend_store = 'glance.store.swift.Store' }
      'file': { $backend_store = 'glance.store.filesystem.Store' }
      'rbd': { $backend_store = 'glance.store.rbd.Store' }
      default: { fail('Unrecognized glance_backend parameter.') }
  }
  $http_store = ['glance.store.http.Store']
  $glance_store = concat($http_store, $backend_store)

  if $glance_backend == 'file' and hiera('glance_file_pcmk_manage', false) {
    $secontext = 'context="system_u:object_r:glance_var_lib_t:s0"'
    pacemaker::resource::filesystem { 'glance-fs':
      device       => hiera('glance_file_pcmk_device'),
      directory    => hiera('glance_file_pcmk_directory'),
      fstype       => hiera('glance_file_pcmk_fstype'),
      fsoptions    => join([$secontext, hiera('glance_file_pcmk_options', '')],','),
      clone_params => '',
    }
  }

  # TODO: notifications, scrubber, etc.
  include ::glance
  include ::glance::config
  class { '::glance::api':
    known_stores   => $glance_store,
    manage_service => false,
    enabled        => false,
  }
  class { '::glance::registry' :
    sync_db        => $sync_db,
    manage_service => false,
    enabled        => false,
  }
  include join(['::glance::backend::', $glance_backend])

  class { '::nova' :
    memcached_servers => suffix(hiera('memcache_node_ips'), ':11211'),
  }

  include ::nova::config

  class { '::nova::api' :
    sync_db        => $sync_db,
    manage_service => false,
    enabled        => false,
  }
  class { '::nova::cert' :
    manage_service => false,
    enabled        => false,
  }
  class { '::nova::conductor' :
    manage_service => false,
    enabled        => false,
  }
  class { '::nova::consoleauth' :
    manage_service => false,
    enabled        => false,
  }
  class { '::nova::vncproxy' :
    manage_service => false,
    enabled        => false,
  }
  include ::nova::scheduler::filter
  class { '::nova::scheduler' :
    manage_service => false,
    enabled        => false,
  }
  include ::nova::network::neutron

  if hiera('neutron::core_plugin') == 'midonet.neutron.plugin_v1.MidonetPluginV2' {

    # TODO(devvesa) provide non-controller ips for these services
    $zookeeper_node_ips = hiera('neutron_api_node_ips')
    $cassandra_node_ips = hiera('neutron_api_node_ips')

    # Run zookeeper in the controller if configured
    if hiera('enable_zookeeper_on_controller') {
      class {'::tripleo::cluster::zookeeper':
        zookeeper_server_ips => $zookeeper_node_ips,
        zookeeper_client_ip  => $ipaddress,
        zookeeper_hostnames  => hiera('controller_node_names')
      }
    }

    # Run cassandra in the controller if configured
    if hiera('enable_cassandra_on_controller') {
      class {'::tripleo::cluster::cassandra':
        cassandra_servers => $cassandra_node_ips,
        cassandra_ip      => $ipaddress
      }
    }

    class {'::tripleo::network::midonet::agent':
      zookeeper_servers => $zookeeper_node_ips,
      cassandra_seeds   => $cassandra_node_ips
    }

    class {'::tripleo::network::midonet::api':
      zookeeper_servers    => hiera('neutron_api_node_ips'),
      vip                  => $public_vip,
      keystone_ip          => $public_vip,
      keystone_admin_token => hiera('keystone::admin_token'),
      bind_address         => $ipaddress,
      admin_password       => hiera('admin_password')
    }

    # Configure Neutron
    class {'::neutron':
      service_plugins => []
    }

  }
  else {
    # Neutron class definitions
    include ::neutron
  }

  include ::neutron::config
  class { '::neutron::server' :
    sync_db        => $sync_db,
    manage_service => false,
    enabled        => false,
  }
  include ::neutron::server::notifications
  if  hiera('neutron::core_plugin') == 'neutron.plugins.nuage.plugin.NuagePlugin' {
    include ::neutron::plugins::nuage
  }
  if hiera('neutron::core_plugin') == 'midonet.neutron.plugin_v1.MidonetPluginV2' {
    class {'::neutron::plugins::midonet':
      midonet_api_ip    => $public_vip,
      keystone_tenant   => hiera('neutron::server::auth_tenant'),
      keystone_password => hiera('neutron::server::auth_password')
    }
  }
  if hiera('neutron::enable_dhcp_agent',true) {
    class { '::neutron::agents::dhcp' :
      manage_service => false,
      enabled        => false,
    }
    file { '/etc/neutron/dnsmasq-neutron.conf':
      content => hiera('neutron_dnsmasq_options'),
      owner   => 'neutron',
      group   => 'neutron',
      notify  => Service['neutron-dhcp-service'],
      require => Package['neutron'],
    }
  }
  if hiera('neutron::enable_l3_agent',true) {
    class { '::neutron::agents::l3' :
      manage_service => false,
      enabled        => false,
    }
  }
  if hiera('neutron::enable_metadata_agent',true) {
    class { '::neutron::agents::metadata':
      manage_service => false,
      enabled        => false,
    }
  }
  include ::neutron::plugins::ml2
  class { '::neutron::agents::ml2::ovs':
    manage_service => false,
    enabled        => false,
  }

  if 'cisco_ucsm' in hiera('neutron::plugins::ml2::mechanism_drivers') {
    include ::neutron::plugins::ml2::cisco::ucsm
  }
  if 'cisco_nexus' in hiera('neutron::plugins::ml2::mechanism_drivers') {
    include ::neutron::plugins::ml2::cisco::nexus
    include ::neutron::plugins::ml2::cisco::type_nexus_vxlan
  }
  if 'cisco_n1kv' in hiera('neutron::plugins::ml2::mechanism_drivers') {
    include ::neutron::plugins::ml2::cisco::nexus1000v

    class { '::neutron::agents::n1kv_vem':
      n1kv_source  => hiera('n1kv_vem_source', undef),
      n1kv_version => hiera('n1kv_vem_version', undef),
    }

    class { '::n1k_vsm':
      n1kv_source  => hiera('n1kv_vsm_source', undef),
      n1kv_version => hiera('n1kv_vsm_version', undef),
    }
  }

  if hiera('neutron_enable_bigswitch_ml2', false) {
    include ::neutron::plugins::ml2::bigswitch::restproxy
  }
  neutron_l3_agent_config {
    'DEFAULT/ovs_use_veth': value => hiera('neutron_ovs_use_veth', false);
  }
  neutron_dhcp_agent_config {
    'DEFAULT/ovs_use_veth': value => hiera('neutron_ovs_use_veth', false);
  }

  include ::cinder
  include ::cinder::config
  class { '::cinder::api':
    sync_db        => $sync_db,
    manage_service => false,
    enabled        => false,
  }
  class { '::cinder::scheduler' :
    manage_service => false,
    enabled        => false,
  }
  class { '::cinder::volume' :
    manage_service => false,
    enabled        => false,
  }
  include ::cinder::glance
  class { '::cinder::setup_test_volume':
    size => join([hiera('cinder_lvm_loop_device_size'), 'M']),
  }

  $cinder_enable_iscsi = hiera('cinder_enable_iscsi_backend', true)
  if $cinder_enable_iscsi {
    $cinder_iscsi_backend = 'tripleo_iscsi'

    cinder::backend::iscsi { $cinder_iscsi_backend :
      iscsi_ip_address => hiera('cinder_iscsi_ip_address'),
      iscsi_helper     => hiera('cinder_iscsi_helper'),
    }
  }

  if $enable_ceph {

    $ceph_pools = hiera('ceph_pools')
    ceph::pool { $ceph_pools :
      pg_num  => hiera('ceph::profile::params::osd_pool_default_pg_num'),
      pgp_num => hiera('ceph::profile::params::osd_pool_default_pgp_num'),
      size    => hiera('ceph::profile::params::osd_pool_default_size'),
    }

    $cinder_pool_requires = [Ceph::Pool[hiera('cinder_rbd_pool_name')]]

  } else {
    $cinder_pool_requires = []
  }

  if hiera('cinder_enable_rbd_backend', false) {
    $cinder_rbd_backend = 'tripleo_ceph'

    cinder::backend::rbd { $cinder_rbd_backend :
      rbd_pool        => hiera('cinder_rbd_pool_name'),
      rbd_user        => hiera('ceph_client_user_name'),
      rbd_secret_uuid => hiera('ceph::profile::params::fsid'),
      require         => $cinder_pool_requires,
    }
  }

  if hiera('cinder_enable_eqlx_backend', false) {
    $cinder_eqlx_backend = hiera('cinder::backend::eqlx::volume_backend_name')

    cinder_config {
      "${cinder_eqlx_backend}/host": value => 'hostgroup';
    }

    cinder::backend::eqlx { $cinder_eqlx_backend :
      volume_backend_name => hiera('cinder::backend::eqlx::volume_backend_name', undef),
      san_ip              => hiera('cinder::backend::eqlx::san_ip', undef),
      san_login           => hiera('cinder::backend::eqlx::san_login', undef),
      san_password        => hiera('cinder::backend::eqlx::san_password', undef),
      san_thin_provision  => hiera('cinder::backend::eqlx::san_thin_provision', undef),
      eqlx_group_name     => hiera('cinder::backend::eqlx::eqlx_group_name', undef),
      eqlx_pool           => hiera('cinder::backend::eqlx::eqlx_lpool', undef),
      eqlx_use_chap       => hiera('cinder::backend::eqlx::eqlx_use_chap', undef),
      eqlx_chap_login     => hiera('cinder::backend::eqlx::eqlx_chap_login', undef),
      eqlx_chap_password  => hiera('cinder::backend::eqlx::eqlx_san_password', undef),
    }
  }

  if hiera('cinder_enable_dellsc_backend', false) {
    $cinder_dellsc_backend = hiera('cinder::backend::dellsc_iscsi::volume_backend_name')

    cinder_config {
      "${cinder_dellsc_backend}/host": value => 'hostgroup';
    }

    cinder::backend::dellsc_iscsi{ $cinder_dellsc_backend :
      volume_backend_name   => hiera('cinder::backend::dellsc_iscsi::volume_backend_name', undef),
      san_ip                => hiera('cinder::backend::dellsc_iscsi::san_ip', undef),
      san_login             => hiera('cinder::backend::dellsc_iscsi::san_login', undef),
      san_password          => hiera('cinder::backend::dellsc_iscsi::san_password', undef),
      dell_sc_ssn           => hiera('cinder::backend::dellsc_iscsi::dell_sc_ssn', undef),
      iscsi_ip_address      => hiera('cinder::backend::dellsc_iscsi::iscsi_ip_address', undef),
      iscsi_port            => hiera('cinder::backend::dellsc_iscsi::iscsi_port', undef),
      dell_sc_port          => hiera('cinder::backend::dellsc_iscsi::dell_sc_port', undef),
      dell_sc_server_folder => hiera('cinder::backend::dellsc_iscsi::dell_sc_server_folder', undef),
      dell_sc_volume_folder => hiera('cinder::backend::dellsc_iscsi::dell_sc_volume_folder', undef),
    }
  }

  if hiera('cinder_enable_netapp_backend', false) {
    $cinder_netapp_backend = hiera('cinder::backend::netapp::title')

    cinder_config {
      "${cinder_netapp_backend}/host": value => 'hostgroup';
    }

    if hiera('cinder::backend::netapp::nfs_shares', undef) {
      $cinder_netapp_nfs_shares = split(hiera('cinder::backend::netapp::nfs_shares', undef), ',')
    }

    cinder::backend::netapp { $cinder_netapp_backend :
      netapp_login                 => hiera('cinder::backend::netapp::netapp_login', undef),
      netapp_password              => hiera('cinder::backend::netapp::netapp_password', undef),
      netapp_server_hostname       => hiera('cinder::backend::netapp::netapp_server_hostname', undef),
      netapp_server_port           => hiera('cinder::backend::netapp::netapp_server_port', undef),
      netapp_size_multiplier       => hiera('cinder::backend::netapp::netapp_size_multiplier', undef),
      netapp_storage_family        => hiera('cinder::backend::netapp::netapp_storage_family', undef),
      netapp_storage_protocol      => hiera('cinder::backend::netapp::netapp_storage_protocol', undef),
      netapp_transport_type        => hiera('cinder::backend::netapp::netapp_transport_type', undef),
      netapp_vfiler                => hiera('cinder::backend::netapp::netapp_vfiler', undef),
      netapp_volume_list           => hiera('cinder::backend::netapp::netapp_volume_list', undef),
      netapp_vserver               => hiera('cinder::backend::netapp::netapp_vserver', undef),
      netapp_partner_backend_name  => hiera('cinder::backend::netapp::netapp_partner_backend_name', undef),
      nfs_shares                   => $cinder_netapp_nfs_shares,
      nfs_shares_config            => hiera('cinder::backend::netapp::nfs_shares_config', undef),
      netapp_copyoffload_tool_path => hiera('cinder::backend::netapp::netapp_copyoffload_tool_path', undef),
      netapp_controller_ips        => hiera('cinder::backend::netapp::netapp_controller_ips', undef),
      netapp_sa_password           => hiera('cinder::backend::netapp::netapp_sa_password', undef),
      netapp_storage_pools         => hiera('cinder::backend::netapp::netapp_storage_pools', undef),
      netapp_eseries_host_type     => hiera('cinder::backend::netapp::netapp_eseries_host_type', undef),
      netapp_webservice_path       => hiera('cinder::backend::netapp::netapp_webservice_path', undef),
    }
  }

  if hiera('cinder_enable_nfs_backend', false) {
    $cinder_nfs_backend = 'tripleo_nfs'

    if str2bool($::selinux) {
      selboolean { 'virt_use_nfs':
        value      => on,
        persistent => true,
      } -> Package['nfs-utils']
    }

    package { 'nfs-utils': } ->
    cinder::backend::nfs { $cinder_nfs_backend:
      nfs_servers       => hiera('cinder_nfs_servers'),
      nfs_mount_options => hiera('cinder_nfs_mount_options',''),
      nfs_shares_config => '/etc/cinder/shares-nfs.conf',
    }
  }

  $cinder_enabled_backends = delete_undef_values([$cinder_iscsi_backend, $cinder_rbd_backend, $cinder_eqlx_backend, $cinder_dellsc_backend, $cinder_netapp_backend, $cinder_nfs_backend])
  class { '::cinder::backends' :
    enabled_backends => $cinder_enabled_backends,
  }

  class { '::sahara':
    sync_db => $sync_db,
  }
  class { '::sahara::service::api':
    manage_service => false,
    enabled        => false,
  }
  class { '::sahara::service::engine':
    manage_service => false,
    enabled        => false,
  }

  # swift proxy
  class { '::swift::proxy' :
    manage_service => $non_pcmk_start,
    enabled        => $non_pcmk_start,
  }
  include ::swift::proxy::proxy_logging
  include ::swift::proxy::healthcheck
  include ::swift::proxy::cache
  include ::swift::proxy::keystone
  include ::swift::proxy::authtoken
  include ::swift::proxy::staticweb
  include ::swift::proxy::ratelimit
  include ::swift::proxy::catch_errors
  include ::swift::proxy::tempurl
  include ::swift::proxy::formpost

  # swift storage
  if str2bool(hiera('enable_swift_storage', true)) {
    class {'::swift::storage::all':
      mount_check => str2bool(hiera('swift_mount_check')),
    }
    class {'::swift::storage::account':
      manage_service => $non_pcmk_start,
      enabled        => $non_pcmk_start,
    }
    class {'::swift::storage::container':
      manage_service => $non_pcmk_start,
      enabled        => $non_pcmk_start,
    }
    class {'::swift::storage::object':
      manage_service => $non_pcmk_start,
      enabled        => $non_pcmk_start,
    }
    if(!defined(File['/srv/node'])) {
      file { '/srv/node':
        ensure  => directory,
        owner   => 'swift',
        group   => 'swift',
        require => Package['openstack-swift'],
      }
    }
    $swift_components = ['account', 'container', 'object']
    swift::storage::filter::recon { $swift_components : }
    swift::storage::filter::healthcheck { $swift_components : }
  }

  # Ceilometer
  case downcase(hiera('ceilometer_backend')) {
    /mysql/: {
      $ceilometer_database_connection = hiera('ceilometer_mysql_conn_string')
    }
    default: {
      $mongo_node_string = join($mongo_node_ips_with_port, ',')
      $ceilometer_database_connection = "mongodb://${mongo_node_string}/ceilometer?replicaSet=${mongodb_replset}"
    }
  }
  include ::ceilometer
  include ::ceilometer::config
  class { '::ceilometer::api' :
    manage_service => false,
    enabled        => false,
  }
  class { '::ceilometer::agent::notification' :
    manage_service => false,
    enabled        => false,
  }
  class { '::ceilometer::agent::central' :
    manage_service => false,
    enabled        => false,
  }
  class { '::ceilometer::collector' :
    manage_service => false,
    enabled        => false,
  }
  include ::ceilometer::expirer
  class { '::ceilometer::db' :
    database_connection => $ceilometer_database_connection,
    sync_db             => $sync_db,
  }
  include ::ceilometer::agent::auth

  Cron <| title == 'ceilometer-expirer' |> { command => "sleep $((\$(od -A n -t d -N 3 /dev/urandom) % 86400)) && ${::ceilometer::params::expirer_command}" }

  # Heat
  include ::heat::config
  class { '::heat' :
    sync_db => $sync_db,
  }
  class { '::heat::api' :
    manage_service => false,
    enabled        => false,
  }
  class { '::heat::api_cfn' :
    manage_service => false,
    enabled        => false,
  }
  class { '::heat::api_cloudwatch' :
    manage_service => false,
    enabled        => false,
  }
  class { '::heat::engine' :
    manage_service => false,
    enabled        => false,
  }

  # httpd/apache and horizon
  # NOTE(gfidente): server-status can be consumed by the pacemaker resource agent
  class { '::apache' :
    service_enable => false,
    # service_manage => false, # <-- not supported with horizon&apache mod_wsgi?
  }
  include ::apache::mod::status
  if 'cisco_n1kv' in hiera('neutron::plugins::ml2::mechanism_drivers') {
    $_profile_support = 'cisco'
  } else {
    $_profile_support = 'None'
  }
  $neutron_options   = {'profile_support' => $_profile_support }
  class { '::horizon':
    cache_server_ip => hiera('memcache_node_ips', '127.0.0.1'),
    neutron_options => $neutron_options,
  }

  $snmpd_user = hiera('snmpd_readonly_user_name')
  snmp::snmpv3_user { $snmpd_user:
    authtype => 'MD5',
    authpass => hiera('snmpd_readonly_user_password'),
  }
  class { '::snmp':
    agentaddress => ['udp:161','udp6:[::1]:161'],
    snmpd_config => [ join(['rouser ', hiera('snmpd_readonly_user_name')]), 'proc  cron', 'includeAllDisks  10%', 'master agentx', 'trapsink localhost public', 'iquerySecName internalUser', 'rouser internalUser', 'defaultMonitors yes', 'linkUpDownNotifications yes' ],
  }

  hiera_include('controller_classes')

} #END STEP 3

if hiera('step') >= 4 {
  $keystone_enable_db_purge = hiera('keystone_enable_db_purge', true)
  $nova_enable_db_purge = hiera('nova_enable_db_purge', true)
  $cinder_enable_db_purge = hiera('cinder_enable_db_purge', true)

  if $keystone_enable_db_purge {
    include ::keystone::cron::token_flush
  }
  if $nova_enable_db_purge {
    include ::nova::cron::archive_deleted_rows
  }
  if $cinder_enable_db_purge {
    include ::cinder::cron::db_purge
  }

  if $pacemaker_master {

    # Keystone
    pacemaker::resource::service { $::keystone::params::service_name :
      clone_params     => 'interleave=true',
      verify_on_create => true,
      require          => [File['/etc/keystone/ssl/certs/ca.pem'],
                            File['/etc/keystone/ssl/private/signing_key.pem'],
                            File['/etc/keystone/ssl/certs/signing_cert.pem']],
    }
    if $instance_ha {
      pacemaker::constraint::location_rule { "${::keystone::params::service_name}-controller":
        resource           => "${::keystone::params::service_name}-clone",
        expression         => 'osprole eq controller',
        resource_discovery => 'exclusive',
        score              => 0,
        require            => Pacemaker::Resource::Service[$::keystone::params::service_name],
      }
    }
    if $enable_load_balancer {
      pacemaker::constraint::base { 'haproxy-then-keystone-constraint':
        constraint_type => 'order',
        first_resource  => 'haproxy-clone',
        second_resource => "${::keystone::params::service_name}-clone",
        first_action    => 'start',
        second_action   => 'start',
        require         => [Pacemaker::Resource::Service['haproxy'],
                            Pacemaker::Resource::Service[$::keystone::params::service_name]],
      }
    }
    pacemaker::constraint::base { 'rabbitmq-then-keystone-constraint':
      constraint_type => 'order',
      first_resource  => 'rabbitmq-clone',
      second_resource => "${::keystone::params::service_name}-clone",
      first_action    => 'start',
      second_action   => 'start',
      require         => [Pacemaker::Resource::Ocf['rabbitmq'],
                          Pacemaker::Resource::Service[$::keystone::params::service_name]],
    }
    pacemaker::constraint::base { 'memcached-then-keystone-constraint':
      constraint_type => 'order',
      first_resource  => 'memcached-clone',
      second_resource => "${::keystone::params::service_name}-clone",
      first_action    => 'start',
      second_action   => 'start',
      require         => [Pacemaker::Resource::Service['memcached'],
                          Pacemaker::Resource::Service[$::keystone::params::service_name]],
    }
    pacemaker::constraint::base { 'galera-then-keystone-constraint':
      constraint_type => 'order',
      first_resource  => 'galera-master',
      second_resource => "${::keystone::params::service_name}-clone",
      first_action    => 'promote',
      second_action   => 'start',
      require         => [Pacemaker::Resource::Ocf['galera'],
                          Pacemaker::Resource::Service[$::keystone::params::service_name]],
    }

    # Cinder
    pacemaker::resource::service { $::cinder::params::api_service :
      clone_params => 'interleave=true',
      require      => Pacemaker::Resource::Service[$::keystone::params::service_name],
    }
    if $instance_ha {
      pacemaker::constraint::location_rule { "${::cinder::params::api_service}-controller":
        resource           => "${::cinder::params::api_service}-clone",
        expression         => 'osprole eq controller',
        resource_discovery => 'exclusive',
        score              => 0,
        require            => Pacemaker::Resource::Service[$::cinder::params::api_service],
      }
    }
    pacemaker::resource::service { $::cinder::params::scheduler_service :
      clone_params => 'interleave=true',
    }
    if $instance_ha {
      pacemaker::constraint::location_rule { "${::cinder::params::scheduler_service}-controller":
        resource           => "${::cinder::params::scheduler_service}-clone",
        expression         => 'osprole eq controller',
        resource_discovery => 'exclusive',
        score              => 0,
        require            => Pacemaker::Resource::Service[$::cinder::params::scheduler_service],
      }
    }
    pacemaker::resource::service { $::cinder::params::volume_service : }
    if $instance_ha {
      pacemaker::constraint::location_rule { "${::cinder::params::volume_service}-controller":
        resource           => "${::cinder::params::volume_service}",
        expression         => 'osprole eq controller',
        resource_discovery => 'exclusive',
        score              => 0,
        require            => Pacemaker::Resource::Service[$::cinder::params::volume_service],
      }
    }
    pacemaker::constraint::base { 'keystone-then-cinder-api-constraint':
      constraint_type => 'order',
      first_resource  => "${::keystone::params::service_name}-clone",
      second_resource => "${::cinder::params::api_service}-clone",
      first_action    => 'start',
      second_action   => 'start',
      require         => [Pacemaker::Resource::Service[$::cinder::params::api_service],
                          Pacemaker::Resource::Service[$::keystone::params::service_name]],
    }
    pacemaker::constraint::base { 'cinder-api-then-cinder-scheduler-constraint':
      constraint_type => 'order',
      first_resource  => "${::cinder::params::api_service}-clone",
      second_resource => "${::cinder::params::scheduler_service}-clone",
      first_action    => 'start',
      second_action   => 'start',
      require         => [Pacemaker::Resource::Service[$::cinder::params::api_service],
                          Pacemaker::Resource::Service[$::cinder::params::scheduler_service]],
    }
    pacemaker::constraint::colocation { 'cinder-scheduler-with-cinder-api-colocation':
      source  => "${::cinder::params::scheduler_service}-clone",
      target  => "${::cinder::params::api_service}-clone",
      score   => 'INFINITY',
      require => [Pacemaker::Resource::Service[$::cinder::params::api_service],
                  Pacemaker::Resource::Service[$::cinder::params::scheduler_service]],
    }
    pacemaker::constraint::base { 'cinder-scheduler-then-cinder-volume-constraint':
      constraint_type => 'order',
      first_resource  => "${::cinder::params::scheduler_service}-clone",
      second_resource => $::cinder::params::volume_service,
      first_action    => 'start',
      second_action   => 'start',
      require         => [Pacemaker::Resource::Service[$::cinder::params::scheduler_service],
                          Pacemaker::Resource::Service[$::cinder::params::volume_service]],
    }
    pacemaker::constraint::colocation { 'cinder-volume-with-cinder-scheduler-colocation':
      source  => $::cinder::params::volume_service,
      target  => "${::cinder::params::scheduler_service}-clone",
      score   => 'INFINITY',
      require => [Pacemaker::Resource::Service[$::cinder::params::scheduler_service],
                  Pacemaker::Resource::Service[$::cinder::params::volume_service]],
    }

    # Sahara
    pacemaker::resource::service { $::sahara::params::api_service_name :
      clone_params => 'interleave=true',
      require      => Pacemaker::Resource::Service[$::keystone::params::service_name],
    }
    pacemaker::resource::service { $::sahara::params::engine_service_name :
      clone_params => 'interleave=true',
    }
    pacemaker::constraint::base { 'keystone-then-sahara-api-constraint':
      constraint_type => 'order',
      first_resource  => "${::keystone::params::service_name}-clone",
      second_resource => "${::sahara::params::api_service_name}-clone",
      first_action    => 'start',
      second_action   => 'start',
      require         => [Pacemaker::Resource::Service[$::sahara::params::api_service_name],
                          Pacemaker::Resource::Service[$::keystone::params::service_name]],
    }

    # Glance
    pacemaker::resource::service { $::glance::params::registry_service_name :
      clone_params => 'interleave=true',
      require      => Pacemaker::Resource::Service[$::keystone::params::service_name],
    }
    if $instance_ha {
      pacemaker::constraint::location_rule { "${::glance::params::registry_service_name}-controller":
        resource           => "${::glance::params::registry_service_name}-clone",
        expression         => 'osprole eq controller',
        resource_discovery => 'exclusive',
        score              => 0,
        require            => Pacemaker::Resource::Service[$::glance::params::registry_service_name],
      }
    }
    pacemaker::resource::service { $::glance::params::api_service_name :
      clone_params => 'interleave=true',
    }
    if $instance_ha {
      pacemaker::constraint::location_rule { "${::glance::params::api_service_name}-controller":
        resource           => "${::glance::params::api_service_name}-clone",
        expression         => 'osprole eq controller',
        resource_discovery => 'exclusive',
        score              => 0,
        require            => Pacemaker::Resource::Service[$::glance::params::api_service_name],
      }
    }

    pacemaker::constraint::base { 'keystone-then-glance-registry-constraint':
      constraint_type => 'order',
      first_resource  => "${::keystone::params::service_name}-clone",
      second_resource => "${::glance::params::registry_service_name}-clone",
      first_action    => 'start',
      second_action   => 'start',
      require         => [Pacemaker::Resource::Service[$::glance::params::registry_service_name],
                          Pacemaker::Resource::Service[$::keystone::params::service_name]],
    }
    pacemaker::constraint::base { 'glance-registry-then-glance-api-constraint':
      constraint_type => 'order',
      first_resource  => "${::glance::params::registry_service_name}-clone",
      second_resource => "${::glance::params::api_service_name}-clone",
      first_action    => 'start',
      second_action   => 'start',
      require         => [Pacemaker::Resource::Service[$::glance::params::registry_service_name],
                          Pacemaker::Resource::Service[$::glance::params::api_service_name]],
    }
    pacemaker::constraint::colocation { 'glance-api-with-glance-registry-colocation':
      source  => "${::glance::params::api_service_name}-clone",
      target  => "${::glance::params::registry_service_name}-clone",
      score   => 'INFINITY',
      require => [Pacemaker::Resource::Service[$::glance::params::registry_service_name],
                  Pacemaker::Resource::Service[$::glance::params::api_service_name]],
    }

    if hiera('step') == 4 {
      # Neutron
      # NOTE(gfidente): Neutron will try to populate the database with some data
      # as soon as neutron-server is started; to avoid races we want to make this
      # happen only on one node, before normal Pacemaker initialization
      # https://bugzilla.redhat.com/show_bug.cgi?id=1233061
      # NOTE(emilien): we need to run this Exec only at Step 4 otherwise this exec
      # will try to start the service while it's already started by Pacemaker
      # It would result to a deployment failure since systemd would return 1 to Puppet
      # and the overcloud would fail to deploy (6 would be returned).
      # This conditional prevents from a race condition during the deployment.
      # https://bugzilla.redhat.com/show_bug.cgi?id=1290582
      exec { 'neutron-server-systemd-start-sleep' :
        command => 'systemctl start neutron-server && /usr/bin/sleep 5',
        path    => '/usr/bin',
        unless  => '/sbin/pcs resource show neutron-server',
      } ->
      pacemaker::resource::service { $::neutron::params::server_service:
        clone_params => 'interleave=true',
        require      => Pacemaker::Resource::Service[$::keystone::params::service_name]
      }
    } else {
      pacemaker::resource::service { $::neutron::params::server_service:
        clone_params => 'interleave=true',
        require      => Pacemaker::Resource::Service[$::keystone::params::service_name]
      }
    }
    if $instance_ha {
      pacemaker::constraint::location_rule { "${::neutron::params::server_service}-controller":
        resource           => "${::neutron::params::server_service}-clone",
        expression         => 'osprole eq controller',
        resource_discovery => 'exclusive',
        score              => 0,
        require            => Pacemaker::Resource::Service[$::neutron::params::server_service],
      }
    }
    if hiera('neutron::enable_l3_agent', true) {
      pacemaker::resource::service { $::neutron::params::l3_agent_service:
        clone_params => 'interleave=true',
      }
      if $instance_ha {
        pacemaker::constraint::location_rule { "${::neutron::params::l3_agent_service}-controller":
          resource           => "${::neutron::params::l3_agent_service}-clone",
          expression         => 'osprole eq controller',
          resource_discovery => 'exclusive',
          score              => 0,
          require            => Pacemaker::Resource::Service[$::neutron::params::l3_agent_service],
        }
      }
    }
    if hiera('neutron::enable_dhcp_agent', true) {
      pacemaker::resource::service { $::neutron::params::dhcp_agent_service:
        clone_params => 'interleave=true',
      }
      if $instance_ha {
        pacemaker::constraint::location_rule { "${::neutron::params::dhcp_agent_service}-controller":
          resource           => "${::neutron::params::dhcp_agent_service}-clone",
          expression         => 'osprole eq controller',
          resource_discovery => 'exclusive',
          score              => 0,
          require            => Pacemaker::Resource::Service[$::neutron::params::dhcp_agent_service],
        }
      }
    }
    if hiera('neutron::enable_ovs_agent', true) {
      pacemaker::resource::service { $::neutron::params::ovs_agent_service:
        clone_params => 'interleave=true',
      }
      if $instance_ha {
        pacemaker::constraint::location_rule { "${::neutron::params::ovs_agent_service}-controller":
          resource           => "${::neutron::params::ovs_agent_service}-clone",
          expression         => 'osprole eq controller',
          resource_discovery => 'exclusive',
          score              => 0,
          require            => Pacemaker::Resource::Service[$::neutron::params::ovs_agent_service],
        }
      }
    }
    if hiera('neutron::core_plugin') == 'midonet.neutron.plugin_v1.MidonetPluginV2' {
      pacemaker::resource::service {'tomcat':
        clone_params => 'interleave=true',
      }
      if $instance_ha {
        pacemaker::constraint::location_rule { "tomcat-controller":
          resource           => 'tomcat-clone',
          expression         => 'osprole eq controller',
          resource_discovery => 'exclusive',
          score              => 0,
          require            => 'tomcat',
        }
      }
    }
    if hiera('neutron::enable_metadata_agent', true) {
      pacemaker::resource::service { $::neutron::params::metadata_agent_service:
        clone_params => 'interleave=true',
      }
      if $instance_ha {
        pacemaker::constraint::location_rule { "${::neutron::params::metadata_agent_service}-controller":
          resource           => "${::neutron::params::metadata_agent_service}-clone",
          expression         => 'osprole eq controller',
          resource_discovery => 'exclusive',
          score              => 0,
          require            => Pacemaker::Resource::Service[$::neutron::params::metadata_agent_service],
        }
      }
    }
    if hiera('neutron::enable_ovs_agent', true) {
      pacemaker::resource::ocf { $::neutron::params::ovs_cleanup_service:
        ocf_agent_name => 'neutron:OVSCleanup',
        clone_params   => 'interleave=true',
      }
      if $instance_ha {
        pacemaker::constraint::location_rule { "${::neutron::params::ovs_cleanup_service}-controller":
          resource           => "${::neutron::params::ovs_cleanup_service}-clone",
          expression         => 'osprole eq controller',
          resource_discovery => 'exclusive',
          score              => 0,
          require            => Pacemaker::Resource::Ocf[$::neutron::params::ovs_cleanup_service],
        }
      }
      pacemaker::resource::ocf { 'neutron-netns-cleanup':
        ocf_agent_name => 'neutron:NetnsCleanup',
        clone_params   => 'interleave=true',
      }
      if $instance_ha {
        pacemaker::constraint::location_rule { "neutron-netns-cleanup-controller":
          resource           => 'neutron-netns-cleanup-clone',
          expression         => 'osprole eq controller',
          resource_discovery => 'exclusive',
          score              => 0,
          require            => Pacemaker::Resource::Ocf['neutron-netns-cleanup'],
        }
      }

      # neutron - one chain ovs-cleanup-->netns-cleanup-->ovs-agent
      pacemaker::constraint::base { 'neutron-ovs-cleanup-to-netns-cleanup-constraint':
        constraint_type => 'order',
        first_resource  => "${::neutron::params::ovs_cleanup_service}-clone",
        second_resource => 'neutron-netns-cleanup-clone',
        first_action    => 'start',
        second_action   => 'start',
        require         => [Pacemaker::Resource::Ocf[$::neutron::params::ovs_cleanup_service],
                            Pacemaker::Resource::Ocf['neutron-netns-cleanup']],
      }
      pacemaker::constraint::colocation { 'neutron-ovs-cleanup-to-netns-cleanup-colocation':
        source  => 'neutron-netns-cleanup-clone',
        target  => "${::neutron::params::ovs_cleanup_service}-clone",
        score   => 'INFINITY',
        require => [Pacemaker::Resource::Ocf[$::neutron::params::ovs_cleanup_service],
                    Pacemaker::Resource::Ocf['neutron-netns-cleanup']],
      }
      pacemaker::constraint::base { 'neutron-netns-cleanup-to-openvswitch-agent-constraint':
        constraint_type => 'order',
        first_resource  => 'neutron-netns-cleanup-clone',
        second_resource => "${::neutron::params::ovs_agent_service}-clone",
        first_action    => 'start',
        second_action   => 'start',
        require         => [Pacemaker::Resource::Ocf['neutron-netns-cleanup'],
                            Pacemaker::Resource::Service[$::neutron::params::ovs_agent_service]],
      }
      pacemaker::constraint::colocation { 'neutron-netns-cleanup-to-openvswitch-agent-colocation':
        source  => "${::neutron::params::ovs_agent_service}-clone",
        target  => 'neutron-netns-cleanup-clone',
        score   => 'INFINITY',
        require => [Pacemaker::Resource::Ocf['neutron-netns-cleanup'],
                    Pacemaker::Resource::Service[$::neutron::params::ovs_agent_service]],
      }
    }

    if $instance_ha {
      # 14.1 ron agent running on compute
      pacemaker::resource::service { "${::neutron::params::ovs_agent_service}-compute":
        service_name => "${::neutron::params::ovs_agent_service}",
        clone_params => "interleave=true",
      } 
      pacemaker::constraint::location_rule { "${::neutron::params::ovs_agent_service}-location-compute":
        resource           => "${::neutron::params::ovs_agent_service}-compute-clone",
        expression         => 'osprole eq compute',
        resource_discovery => 'exclusive',
        score              => 0,
        require            => Pacemaker::Resource::Service["${::neutron::params::ovs_agent_service}-compute"],
      }
      pacemaker::constraint::base { "${::neutron::params::server_service}-then-${::neutron::params::ovs_agent_service}-compute":
        constraint_type   => 'order',
        first_resource    => "${::neutron::params::server_service}-clone",
        second_resource   => "${::neutron::params::ovs_agent_service}-compute-clone",
        first_action      => 'start',
        second_action     => 'start',
        constraint_params => 'require-all=false',
        require           => [Pacemaker::Resource::Service[$::neutron::params::server_service],
                              Pacemaker::Resource::Service["${::neutron::params::ovs_agent_service}-compute"]],
      }

      # 14.2 libvirtd agent running on compute
      pacemaker::resource::service { "libvirtd-compute":
        service_name => "libvirtd",
        clone_params => "interleave=true",
      }
      pacemaker::constraint::location_rule { 'libvirtd-location-compute':
        resource           => 'libvirtd-compute-clone',
        expression         => 'osprole eq compute',
        resource_discovery => 'exclusive',
        score              => 0,
        require            => Pacemaker::Resource::Service['libvirtd-compute'],
      }
      pacemaker::constraint::base { "${::neutron::params::ovs_agent_service}-compute-then-libvirtd-compute":
        constraint_type   => 'order',
        first_resource    => "${::neutron::params::ovs_agent_service}-compute-clone",
        second_resource   => 'libvirtd-compute-clone',
        first_action      => 'start',
        second_action     => 'start',
        require           => [Pacemaker::Resource::Service["libvirtd-compute"],
                              Pacemaker::Resource::Service["${::neutron::params::ovs_agent_service}-compute"]],
      } 
      pacemaker::constraint::colocation { "${::neutron::params::ovs_agent_service}-compute-with-libvirtd-compute":
        source  => 'libvirtd-compute-clone',
        target  => "${::neutron::params::ovs_agent_service}-compute-clone",
        score   => 'INFINITY',
        require => [Pacemaker::Resource::Service["libvirtd-compute"],
                    Pacemaker::Resource::Service["${::neutron::params::ovs_agent_service}-compute"]],
      } 

      # 14.3 openstack-ceilometer-compute running on compute
      pacemaker::resource::service { "openstack-ceilometer-compute":
        clone_params => "interleave=true",
      }
      pacemaker::constraint::location_rule { 'openstack-ceilometer-compute-location-compute':
        resource           => 'openstack-ceilometer-compute-clone',
        expression         => 'osprole eq compute',
        resource_discovery => 'exclusive',
        score              => 0,
        require            => Pacemaker::Resource::Service['openstack-ceilometer-compute'],
      }
      pacemaker::constraint::base { "${::ceilometer::params::agent_notification_service_name}-then-openstack-ceilometer-compute":
        constraint_type   => 'order',
        first_resource    => "${::ceilometer::params::agent_notification_service_name}-clone",
        second_resource   => 'openstack-ceilometer-compute-clone',
        first_action      => 'start',
        second_action     => 'start',
        constraint_params => 'require-all=false',
        require           => [Pacemaker::Resource::Service["openstack-ceilometer-compute"],
                              Pacemaker::Resource::Service[$::ceilometer::params::agent_notification_service_name]],
      }
      pacemaker::constraint::base { "libvirtd-compute-clone-then-openstack-ceilometer-compute":
        constraint_type   => 'order',
        first_resource    => "libvirtd-compute-clone",
        second_resource   => 'openstack-ceilometer-compute-clone',
        first_action      => 'start',
        second_action     => 'start',
        require           => [Pacemaker::Resource::Service["openstack-ceilometer-compute"],
                              Pacemaker::Resource::Service["libvirtd-compute"]],
      }
      pacemaker::constraint::colocation { "openstack-ceilometer-compute-with-libvirtd-compute":
        source  => 'openstack-ceilometer-compute-clone',
        target  => "libvirtd-compute-clone",
        score   => 'INFINITY',
        require => [Pacemaker::Resource::Service["openstack-ceilometer-compute"],
                    Pacemaker::Resource::Service["libvirtd-compute"]],
      } 

      # 14.4 nova-compute
      pacemaker::resource::ocf { 'nova-compute' :
        ocf_agent_name  => 'openstack:nova-compute-wait',
        clone_params    => 'interleave=true',
        resource_params => "auth_url=${pacemaker_admin_uri} username=admin password=${admin_password} tenant_name=admin domain=localdomain op start timeout=300",
        require => Pacemaker::Resource::Service["libvirtd-compute"],
      }

      pacemaker::constraint::location_rule { 'nova-compute-location':
        resource           => 'nova-compute-clone',
        expression         => 'osprole eq compute',
        resource_discovery => 'exclusive',
        score              => 0,
        require            => Pacemaker::Resource::Ocf['nova-compute'],
      }
      pacemaker::constraint::base { "${::nova::params::conductor_service_name}-then-nova-compute":
        constraint_type   => 'order',
        first_resource    => "${::nova::params::conductor_service_name}-clone",
        second_resource   => 'nova-compute-clone',
        first_action      => 'start',
        second_action     => 'start',
        constraint_params => 'require-all=false',
        require           => [Pacemaker::Resource::Ocf['nova-evacuate'],
                              Pacemaker::Resource::Service[$::nova::params::conductor_service_name]],
      }
      pacemaker::constraint::base { "nova-compute-clone-then-nova-evacuate":
        constraint_type   => 'order',
        first_resource    => "nova-compute-clone",
        second_resource   => 'nova-evacuate',
        first_action      => 'start',
        second_action     => 'start',
        constraint_params => 'require-all=false',
        require           => [Pacemaker::Resource::Ocf["nova-compute"],
                              Pacemaker::Resource::Ocf["nova-evacuate"]],
      }
      pacemaker::constraint::base { "libvirtd-compute-clone-then-nova-compute":
        constraint_type   => 'order',
        first_resource    => "libvirtd-compute-clone",
        second_resource   => 'nova-compute-clone',
        first_action      => 'start',
        second_action     => 'start',
        require           => [Pacemaker::Resource::Ocf["nova-compute"],
                              Pacemaker::Resource::Service["libvirtd-compute"]],
      }
      pacemaker::constraint::colocation { "nova-compute-with-libvirtd-compute":
        source  => 'nova-compute-clone',
        target  => "libvirtd-compute-clone",
        score   => 'INFINITY',
        require => [Pacemaker::Resource::Ocf["nova-compute"],
                    Pacemaker::Resource::Service["libvirtd-compute"]],
      } 
    } # instance-ha

    pacemaker::constraint::base { 'keystone-to-neutron-server-constraint':
      constraint_type => 'order',
      first_resource  => "${::keystone::params::service_name}-clone",
      second_resource => "${::neutron::params::server_service}-clone",
      first_action    => 'start',
      second_action   => 'start',
      require         => [Pacemaker::Resource::Service[$::keystone::params::service_name],
                          Pacemaker::Resource::Service[$::neutron::params::server_service]],
    }
    if hiera('neutron::enable_ovs_agent',true) {
      pacemaker::constraint::base { 'neutron-server-to-openvswitch-agent-constraint':
        constraint_type => 'order',
        first_resource  => "${::neutron::params::server_service}-clone",
        second_resource => "${::neutron::params::ovs_agent_service}-clone",
        first_action    => 'start',
        second_action   => 'start',
        require         => [Pacemaker::Resource::Service[$::neutron::params::server_service],
                            Pacemaker::Resource::Service[$::neutron::params::ovs_agent_service]],
      }
    }
    if hiera('neutron::enable_dhcp_agent',true) and hiera('neutron::enable_ovs_agent',true) {
      pacemaker::constraint::base { 'neutron-openvswitch-agent-to-dhcp-agent-constraint':
        constraint_type => 'order',
        first_resource  => "${::neutron::params::ovs_agent_service}-clone",
        second_resource => "${::neutron::params::dhcp_agent_service}-clone",
        first_action    => 'start',
        second_action   => 'start',
        require         => [Pacemaker::Resource::Service[$::neutron::params::ovs_agent_service],
                            Pacemaker::Resource::Service[$::neutron::params::dhcp_agent_service]],

      }
      pacemaker::constraint::colocation { 'neutron-openvswitch-agent-to-dhcp-agent-colocation':
        source  => "${::neutron::params::dhcp_agent_service}-clone",
        target  => "${::neutron::params::ovs_agent_service}-clone",
        score   => 'INFINITY',
        require => [Pacemaker::Resource::Service[$::neutron::params::ovs_agent_service],
                    Pacemaker::Resource::Service[$::neutron::params::dhcp_agent_service]],
      }
    }
    if hiera('neutron::enable_dhcp_agent',true) and hiera('l3_agent_service',true) {
      pacemaker::constraint::base { 'neutron-dhcp-agent-to-l3-agent-constraint':
        constraint_type => 'order',
        first_resource  => "${::neutron::params::dhcp_agent_service}-clone",
        second_resource => "${::neutron::params::l3_agent_service}-clone",
        first_action    => 'start',
        second_action   => 'start',
        require         => [Pacemaker::Resource::Service[$::neutron::params::dhcp_agent_service],
                            Pacemaker::Resource::Service[$::neutron::params::l3_agent_service]]
      }
      pacemaker::constraint::colocation { 'neutron-dhcp-agent-to-l3-agent-colocation':
        source  => "${::neutron::params::l3_agent_service}-clone",
        target  => "${::neutron::params::dhcp_agent_service}-clone",
        score   => 'INFINITY',
        require => [Pacemaker::Resource::Service[$::neutron::params::dhcp_agent_service],
                    Pacemaker::Resource::Service[$::neutron::params::l3_agent_service]]
      }
    }
    if hiera('neutron::enable_l3_agent',true) and hiera('neutron::enable_metadata_agent',true) {
      pacemaker::constraint::base { 'neutron-l3-agent-to-metadata-agent-constraint':
        constraint_type => 'order',
        first_resource  => "${::neutron::params::l3_agent_service}-clone",
        second_resource => "${::neutron::params::metadata_agent_service}-clone",
        first_action    => 'start',
        second_action   => 'start',
        require         => [Pacemaker::Resource::Service[$::neutron::params::l3_agent_service],
                            Pacemaker::Resource::Service[$::neutron::params::metadata_agent_service]]
      }
      pacemaker::constraint::colocation { 'neutron-l3-agent-to-metadata-agent-colocation':
        source  => "${::neutron::params::metadata_agent_service}-clone",
        target  => "${::neutron::params::l3_agent_service}-clone",
        score   => 'INFINITY',
        require => [Pacemaker::Resource::Service[$::neutron::params::l3_agent_service],
                    Pacemaker::Resource::Service[$::neutron::params::metadata_agent_service]]
      }
    }
    if hiera('neutron::core_plugin') == 'midonet.neutron.plugin_v1.MidonetPluginV2' {
      #midonet-chain chain keystone-->neutron-server-->dhcp-->metadata->tomcat
      pacemaker::constraint::base { 'neutron-server-to-dhcp-agent-constraint':
        constraint_type => 'order',
        first_resource  => "${::neutron::params::server_service}-clone",
        second_resource => "${::neutron::params::dhcp_agent_service}-clone",
        first_action    => 'start',
        second_action   => 'start',
        require         => [Pacemaker::Resource::Service[$::neutron::params::server_service],
                            Pacemaker::Resource::Service[$::neutron::params::dhcp_agent_service]],
      }
      pacemaker::constraint::base { 'neutron-dhcp-agent-to-metadata-agent-constraint':
        constraint_type => 'order',
        first_resource  => "${::neutron::params::dhcp_agent_service}-clone",
        second_resource => "${::neutron::params::metadata_agent_service}-clone",
        first_action    => 'start',
        second_action   => 'start',
        require         => [Pacemaker::Resource::Service[$::neutron::params::dhcp_agent_service],
                            Pacemaker::Resource::Service[$::neutron::params::metadata_agent_service]],
      }
      pacemaker::constraint::base { 'neutron-metadata-agent-to-tomcat-constraint':
        constraint_type => 'order',
        first_resource  => "${::neutron::params::metadata_agent_service}-clone",
        second_resource => 'tomcat-clone',
        first_action    => 'start',
        second_action   => 'start',
        require         => [Pacemaker::Resource::Service[$::neutron::params::metadata_agent_service],
                            Pacemaker::Resource::Service['tomcat']],
      }
      pacemaker::constraint::colocation { 'neutron-dhcp-agent-to-metadata-agent-colocation':
        source  => "${::neutron::params::metadata_agent_service}-clone",
        target  => "${::neutron::params::dhcp_agent_service}-clone",
        score   => 'INFINITY',
        require => [Pacemaker::Resource::Service[$::neutron::params::dhcp_agent_service],
                    Pacemaker::Resource::Service[$::neutron::params::metadata_agent_service]],
      }
    }

    # Nova
    pacemaker::resource::service { $::nova::params::api_service_name :
      clone_params => 'interleave=true',
      op_params    => 'start timeout=200s stop timeout=200s monitor start-delay=10s',
    }
    if $instance_ha {
      pacemaker::constraint::location_rule { "${::nova::params::api_service_name}-controller":
        resource           => "${::nova::params::api_service_name}-clone",
        expression         => 'osprole eq controller',
        resource_discovery => 'exclusive',
        score              => 0,
        require            => Pacemaker::Resource::Service[$::nova::params::api_service_name],
      }
    }
    pacemaker::resource::service { $::nova::params::conductor_service_name :
      clone_params => 'interleave=true',
      op_params    => 'start timeout=200s stop timeout=200s monitor start-delay=10s',
    }
    if $instance_ha {
      pacemaker::constraint::location_rule { "${::nova::params::conductor_service_name}-controller":
        resource           => "${::nova::params::conductor_service_name}-clone",
        expression         => 'osprole eq controller',
        resource_discovery => 'exclusive',
        score              => 0,
        require            => Pacemaker::Resource::Service[$::nova::params::conductor_service_name],
      }
    }
    pacemaker::resource::service { $::nova::params::consoleauth_service_name :
      clone_params => 'interleave=true',
      op_params    => 'start timeout=200s stop timeout=200s monitor start-delay=10s',
      require      => Pacemaker::Resource::Service[$::keystone::params::service_name],
    }
    if $instance_ha {
      pacemaker::constraint::location_rule { "${::nova::params::consoleauth_service_name}-controller":
        resource           => "${::nova::params::consoleauth_service_name}-clone",
        expression         => 'osprole eq controller',
        resource_discovery => 'exclusive',
        score              => 0,
        require            => Pacemaker::Resource::Service[$::nova::params::consoleauth_service_name],
      }
    }
    pacemaker::resource::service { $::nova::params::vncproxy_service_name :
      clone_params => 'interleave=true',
      op_params    => 'start timeout=200s stop timeout=200s monitor start-delay=10s',
    }
    if $instance_ha {
      pacemaker::constraint::location_rule { "${::nova::params::vncproxy_service_name}-controller":
        resource           => "${::nova::params::vncproxy_service_name}-clone",
        expression         => 'osprole eq controller',
        resource_discovery => 'exclusive',
        score              => 0,
        require            => Pacemaker::Resource::Service[$::nova::params::vncproxy_service_name],
      }
    }
    pacemaker::resource::service { $::nova::params::scheduler_service_name :
      clone_params => 'interleave=true',
      op_params    => 'start timeout=200s stop timeout=200s monitor start-delay=10s',
    }
    if $instance_ha {
      pacemaker::constraint::location_rule { "${::nova::params::scheduler_service_name}-controller":
        resource           => "${::nova::params::scheduler_service_name}-clone",
        expression         => 'osprole eq controller',
        resource_discovery => 'exclusive',
        score              => 0,
        require            => Pacemaker::Resource::Service[$::nova::params::scheduler_service_name],
      }
    }

    pacemaker::constraint::base { 'keystone-then-nova-consoleauth-constraint':
      constraint_type => 'order',
      first_resource  => "${::keystone::params::service_name}-clone",
      second_resource => "${::nova::params::consoleauth_service_name}-clone",
      first_action    => 'start',
      second_action   => 'start',
      require         => [Pacemaker::Resource::Service[$::nova::params::consoleauth_service_name],
                          Pacemaker::Resource::Service[$::keystone::params::service_name]],
    }
    pacemaker::constraint::base { 'nova-consoleauth-then-nova-vncproxy-constraint':
      constraint_type => 'order',
      first_resource  => "${::nova::params::consoleauth_service_name}-clone",
      second_resource => "${::nova::params::vncproxy_service_name}-clone",
      first_action    => 'start',
      second_action   => 'start',
      require         => [Pacemaker::Resource::Service[$::nova::params::consoleauth_service_name],
                          Pacemaker::Resource::Service[$::nova::params::vncproxy_service_name]],
    }
    pacemaker::constraint::colocation { 'nova-vncproxy-with-nova-consoleauth-colocation':
      source  => "${::nova::params::vncproxy_service_name}-clone",
      target  => "${::nova::params::consoleauth_service_name}-clone",
      score   => 'INFINITY',
      require => [Pacemaker::Resource::Service[$::nova::params::consoleauth_service_name],
                  Pacemaker::Resource::Service[$::nova::params::vncproxy_service_name]],
    }
    pacemaker::constraint::base { 'nova-vncproxy-then-nova-api-constraint':
      constraint_type => 'order',
      first_resource  => "${::nova::params::vncproxy_service_name}-clone",
      second_resource => "${::nova::params::api_service_name}-clone",
      first_action    => 'start',
      second_action   => 'start',
      require         => [Pacemaker::Resource::Service[$::nova::params::vncproxy_service_name],
                          Pacemaker::Resource::Service[$::nova::params::api_service_name]],
    }
    pacemaker::constraint::colocation { 'nova-api-with-nova-vncproxy-colocation':
      source  => "${::nova::params::api_service_name}-clone",
      target  => "${::nova::params::vncproxy_service_name}-clone",
      score   => 'INFINITY',
      require => [Pacemaker::Resource::Service[$::nova::params::vncproxy_service_name],
                  Pacemaker::Resource::Service[$::nova::params::api_service_name]],
    }
    pacemaker::constraint::base { 'nova-api-then-nova-scheduler-constraint':
      constraint_type => 'order',
      first_resource  => "${::nova::params::api_service_name}-clone",
      second_resource => "${::nova::params::scheduler_service_name}-clone",
      first_action    => 'start',
      second_action   => 'start',
      require         => [Pacemaker::Resource::Service[$::nova::params::api_service_name],
                          Pacemaker::Resource::Service[$::nova::params::scheduler_service_name]],
    }
    pacemaker::constraint::colocation { 'nova-scheduler-with-nova-api-colocation':
      source  => "${::nova::params::scheduler_service_name}-clone",
      target  => "${::nova::params::api_service_name}-clone",
      score   => 'INFINITY',
      require => [Pacemaker::Resource::Service[$::nova::params::api_service_name],
                  Pacemaker::Resource::Service[$::nova::params::scheduler_service_name]],
    }
    pacemaker::constraint::base { 'nova-scheduler-then-nova-conductor-constraint':
      constraint_type => 'order',
      first_resource  => "${::nova::params::scheduler_service_name}-clone",
      second_resource => "${::nova::params::conductor_service_name}-clone",
      first_action    => 'start',
      second_action   => 'start',
      require         => [Pacemaker::Resource::Service[$::nova::params::scheduler_service_name],
                          Pacemaker::Resource::Service[$::nova::params::conductor_service_name]],
    }
    pacemaker::constraint::colocation { 'nova-conductor-with-nova-scheduler-colocation':
      source  => "${::nova::params::conductor_service_name}-clone",
      target  => "${::nova::params::scheduler_service_name}-clone",
      score   => 'INFINITY',
      require => [Pacemaker::Resource::Service[$::nova::params::scheduler_service_name],
                  Pacemaker::Resource::Service[$::nova::params::conductor_service_name]],
    }

    # Ceilometer
    case downcase(hiera('ceilometer_backend')) {
      /mysql/: {
        pacemaker::resource::service { $::ceilometer::params::agent_central_service_name :
          clone_params => 'interleave=true',
          require      => Pacemaker::Resource::Service[$::keystone::params::service_name],
        }
      }
      default: {
        pacemaker::resource::service { $::ceilometer::params::agent_central_service_name :
          clone_params => 'interleave=true',
          require      => [Pacemaker::Resource::Service[$::keystone::params::service_name],
                            Pacemaker::Resource::Service[$::mongodb::params::service_name]],
        }
      }
    }
    if $instance_ha {
      pacemaker::constraint::location_rule { "${::ceilometer::params::agent_central_service_name}-controller":
        resource           => "${::ceilometer::params::agent_central_service_name}-clone",
        expression         => 'osprole eq controller',
        resource_discovery => 'exclusive',
        score              => 0,
        require            => Pacemaker::Resource::Service[$::ceilometer::params::agent_central_service_name],
      }
    }
    pacemaker::resource::service { $::ceilometer::params::collector_service_name :
      clone_params => 'interleave=true',
    }
    if $instance_ha {
      pacemaker::constraint::location_rule { "${::ceilometer::params::collector_service_name}-controller":
        resource           => "${::ceilometer::params::collector_service_name}-clone",
        expression         => 'osprole eq controller',
        resource_discovery => 'exclusive',
        score              => 0,
        require            => Pacemaker::Resource::Service[$::ceilometer::params::collector_service_name],
      }
    }
    pacemaker::resource::service { $::ceilometer::params::api_service_name :
      clone_params => 'interleave=true',
    }
    if $instance_ha {
      pacemaker::constraint::location_rule { "${::ceilometer::params::api_service_name}-controller":
        resource           => "${::ceilometer::params::api_service_name}-clone",
        expression         => 'osprole eq controller',
        resource_discovery => 'exclusive',
        score              => 0,
        require            => Pacemaker::Resource::Service[$::ceilometer::params::api_service_name],
      }
    }
    pacemaker::resource::service { $::ceilometer::params::agent_notification_service_name :
      clone_params => 'interleave=true',
    }
    if $instance_ha {
      pacemaker::constraint::location_rule { "${::ceilometer::params::agent_notification_service_name}-controller":
        resource           => "${::ceilometer::params::agent_notification_service_name}-clone",
        expression         => 'osprole eq controller',
        resource_discovery => 'exclusive',
        score              => 0,
        require            => Pacemaker::Resource::Service[$::ceilometer::params::agent_notification_service_name],
      }
    }
    pacemaker::resource::ocf { 'delay' :
      ocf_agent_name  => 'heartbeat:Delay',
      clone_params    => 'interleave=true',
      resource_params => 'startdelay=10',
    }
    if $instance_ha {
      pacemaker::constraint::location_rule { 'delay-controller':
        resource           => "delay-clone",
        expression         => 'osprole eq controller',
        resource_discovery => 'exclusive',
        score              => 0,
        require            => Pacemaker::Resource::Ocf['delay'],
      }
    }
    # Fedora doesn't know `require-all` parameter for constraints yet
    if $::operatingsystem == 'Fedora' {
      $redis_ceilometer_constraint_params = undef
    } else {
      $redis_ceilometer_constraint_params = 'require-all=false'
    }
    pacemaker::constraint::base { 'redis-then-ceilometer-central-constraint':
      constraint_type   => 'order',
      first_resource    => 'redis-master',
      second_resource   => "${::ceilometer::params::agent_central_service_name}-clone",
      first_action      => 'promote',
      second_action     => 'start',
      constraint_params => $redis_ceilometer_constraint_params,
      require           => [Pacemaker::Resource::Ocf['redis'],
                            Pacemaker::Resource::Service[$::ceilometer::params::agent_central_service_name]],
    }
    pacemaker::constraint::base { 'keystone-then-ceilometer-central-constraint':
      constraint_type => 'order',
      first_resource  => "${::keystone::params::service_name}-clone",
      second_resource => "${::ceilometer::params::agent_central_service_name}-clone",
      first_action    => 'start',
      second_action   => 'start',
      require         => [Pacemaker::Resource::Service[$::ceilometer::params::agent_central_service_name],
                          Pacemaker::Resource::Service[$::keystone::params::service_name]],
    }
    pacemaker::constraint::base { 'ceilometer-central-then-ceilometer-collector-constraint':
      constraint_type => 'order',
      first_resource  => "${::ceilometer::params::agent_central_service_name}-clone",
      second_resource => "${::ceilometer::params::collector_service_name}-clone",
      first_action    => 'start',
      second_action   => 'start',
      require         => [Pacemaker::Resource::Service[$::ceilometer::params::agent_central_service_name],
                          Pacemaker::Resource::Service[$::ceilometer::params::collector_service_name]],
    }
    pacemaker::constraint::base { 'ceilometer-collector-then-ceilometer-api-constraint':
      constraint_type => 'order',
      first_resource  => "${::ceilometer::params::collector_service_name}-clone",
      second_resource => "${::ceilometer::params::api_service_name}-clone",
      first_action    => 'start',
      second_action   => 'start',
      require         => [Pacemaker::Resource::Service[$::ceilometer::params::collector_service_name],
                          Pacemaker::Resource::Service[$::ceilometer::params::api_service_name]],
    }
    pacemaker::constraint::colocation { 'ceilometer-api-with-ceilometer-collector-colocation':
      source  => "${::ceilometer::params::api_service_name}-clone",
      target  => "${::ceilometer::params::collector_service_name}-clone",
      score   => 'INFINITY',
      require => [Pacemaker::Resource::Service[$::ceilometer::params::api_service_name],
                  Pacemaker::Resource::Service[$::ceilometer::params::collector_service_name]],
    }
    pacemaker::constraint::base { 'ceilometer-api-then-ceilometer-delay-constraint':
      constraint_type => 'order',
      first_resource  => "${::ceilometer::params::api_service_name}-clone",
      second_resource => 'delay-clone',
      first_action    => 'start',
      second_action   => 'start',
      require         => [Pacemaker::Resource::Service[$::ceilometer::params::api_service_name],
                          Pacemaker::Resource::Ocf['delay']],
    }
    pacemaker::constraint::colocation { 'ceilometer-delay-with-ceilometer-api-colocation':
      source  => 'delay-clone',
      target  => "${::ceilometer::params::api_service_name}-clone",
      score   => 'INFINITY',
      require => [Pacemaker::Resource::Service[$::ceilometer::params::api_service_name],
                  Pacemaker::Resource::Ocf['delay']],
    }
    if downcase(hiera('ceilometer_backend')) == 'mongodb' {
      pacemaker::constraint::base { 'mongodb-then-ceilometer-central-constraint':
        constraint_type => 'order',
        first_resource  => "${::mongodb::params::service_name}-clone",
        second_resource => "${::ceilometer::params::agent_central_service_name}-clone",
        first_action    => 'start',
        second_action   => 'start',
        require         => [Pacemaker::Resource::Service[$::ceilometer::params::agent_central_service_name],
                            Pacemaker::Resource::Service[$::mongodb::params::service_name]],
      }
    }

    # Heat
    pacemaker::resource::service { $::heat::params::api_service_name :
      clone_params => 'interleave=true',
    }
    if $instance_ha {
      pacemaker::constraint::location_rule { "${::heat::params::api_service_name}-controller":
        resource           => "${::heat::params::api_service_name}-clone",
        expression         => 'osprole eq controller',
        resource_discovery => 'exclusive',
        score              => 0,
        require            => Pacemaker::Resource::Service[$::heat::params::api_service_name],
      }
    }
    pacemaker::resource::service { $::heat::params::api_cloudwatch_service_name :
      clone_params => 'interleave=true',
    }
    if $instance_ha {
      pacemaker::constraint::location_rule { "${::heat::params::api_cloudwatch_service_name}-controller":
        resource           => "${::heat::params::api_cloudwatch_service_name}-clone",
        expression         => 'osprole eq controller',
        resource_discovery => 'exclusive',
        score              => 0,
        require            => Pacemaker::Resource::Service[$::heat::params::api_cloudwatch_service_name],
      }
    }
    pacemaker::resource::service { $::heat::params::api_cfn_service_name :
      clone_params => 'interleave=true',
    }
    if $instance_ha {
      pacemaker::constraint::location_rule { "${::heat::params::api_cfn_service_name}-controller":
        resource           => "${::heat::params::api_cfn_service_name}-clone",
        expression         => 'osprole eq controller',
        resource_discovery => 'exclusive',
        score              => 0,
        require            => Pacemaker::Resource::Service[$::heat::params::api_cfn_service_name],
      }
    }
    pacemaker::resource::service { $::heat::params::engine_service_name :
      clone_params => 'interleave=true',
    }
    if $instance_ha {
      pacemaker::constraint::location_rule { "${::heat::params::engine_service_name}-controller":
        resource           => "${::heat::params::engine_service_name}-clone",
        expression         => 'osprole eq controller',
        resource_discovery => 'exclusive',
        score              => 0,
        require            => Pacemaker::Resource::Service[$::heat::params::engine_service_name],
      }
    }
    pacemaker::constraint::base { 'keystone-then-heat-api-constraint':
      constraint_type => 'order',
      first_resource  => "${::keystone::params::service_name}-clone",
      second_resource => "${::heat::params::api_service_name}-clone",
      first_action    => 'start',
      second_action   => 'start',
      require         => [Pacemaker::Resource::Service[$::heat::params::api_service_name],
                          Pacemaker::Resource::Service[$::keystone::params::service_name]],
    }
    pacemaker::constraint::base { 'heat-api-then-heat-api-cfn-constraint':
      constraint_type => 'order',
      first_resource  => "${::heat::params::api_service_name}-clone",
      second_resource => "${::heat::params::api_cfn_service_name}-clone",
      first_action    => 'start',
      second_action   => 'start',
      require         => [Pacemaker::Resource::Service[$::heat::params::api_service_name],
                          Pacemaker::Resource::Service[$::heat::params::api_cfn_service_name]],
    }
    pacemaker::constraint::colocation { 'heat-api-cfn-with-heat-api-colocation':
      source  => "${::heat::params::api_cfn_service_name}-clone",
      target  => "${::heat::params::api_service_name}-clone",
      score   => 'INFINITY',
      require => [Pacemaker::Resource::Service[$::heat::params::api_cfn_service_name],
                  Pacemaker::Resource::Service[$::heat::params::api_service_name]],
    }
    pacemaker::constraint::base { 'heat-api-cfn-then-heat-api-cloudwatch-constraint':
      constraint_type => 'order',
      first_resource  => "${::heat::params::api_cfn_service_name}-clone",
      second_resource => "${::heat::params::api_cloudwatch_service_name}-clone",
      first_action    => 'start',
      second_action   => 'start',
      require         => [Pacemaker::Resource::Service[$::heat::params::api_cloudwatch_service_name],
                          Pacemaker::Resource::Service[$::heat::params::api_cfn_service_name]],
    }
    pacemaker::constraint::colocation { 'heat-api-cloudwatch-with-heat-api-cfn-colocation':
      source  => "${::heat::params::api_cloudwatch_service_name}-clone",
      target  => "${::heat::params::api_cfn_service_name}-clone",
      score   => 'INFINITY',
      require => [Pacemaker::Resource::Service[$::heat::params::api_cfn_service_name],
                  Pacemaker::Resource::Service[$::heat::params::api_cloudwatch_service_name]],
    }
    pacemaker::constraint::base { 'heat-api-cloudwatch-then-heat-engine-constraint':
      constraint_type => 'order',
      first_resource  => "${::heat::params::api_cloudwatch_service_name}-clone",
      second_resource => "${::heat::params::engine_service_name}-clone",
      first_action    => 'start',
      second_action   => 'start',
      require         => [Pacemaker::Resource::Service[$::heat::params::api_cloudwatch_service_name],
                          Pacemaker::Resource::Service[$::heat::params::engine_service_name]],
    }
    pacemaker::constraint::colocation { 'heat-engine-with-heat-api-cloudwatch-colocation':
      source  => "${::heat::params::engine_service_name}-clone",
      target  => "${::heat::params::api_cloudwatch_service_name}-clone",
      score   => 'INFINITY',
      require => [Pacemaker::Resource::Service[$::heat::params::api_cloudwatch_service_name],
                  Pacemaker::Resource::Service[$::heat::params::engine_service_name]],
    }
    pacemaker::constraint::base { 'ceilometer-notification-then-heat-api-constraint':
      constraint_type => 'order',
      first_resource  => "${::ceilometer::params::agent_notification_service_name}-clone",
      second_resource => "${::heat::params::api_service_name}-clone",
      first_action    => 'start',
      second_action   => 'start',
      require         => [Pacemaker::Resource::Service[$::heat::params::api_service_name],
                          Pacemaker::Resource::Service[$::ceilometer::params::agent_notification_service_name]],
    }

    # Horizon
    pacemaker::resource::service { $::horizon::params::http_service:
      clone_params => 'interleave=true',
    }
    if $instance_ha {
      pacemaker::constraint::location_rule { "${::horizon::params::http_service}-controller":
        resource           => "${::horizon::params::http_service}-clone",
        expression         => 'osprole eq controller',
        resource_discovery => 'exclusive',
        score              => 0,
        require            => Pacemaker::Resource::Service[$::horizon::params::http_service],
      }
    }

    # Add NovaEvacuate active/passive resource (step 7 of the article)
    # FIXME: without shared_storage=1 ?!? see newest env requirement
    if $instance_ha {
      pacemaker::resource::ocf { 'nova-evacuate':
        ocf_agent_name  => 'openstack:NovaEvacuate',
        resource_params => "auth_url=${pacemaker_admin_uri} username=admin password=${admin_password} tenant_name=admin no_shared_storage=1",
      }
      pacemaker::constraint::location_rule { "nova-evacuate-controller":
        resource           => 'nova-evacuate',
        expression         => 'osprole eq controller',
        resource_discovery => 'exclusive',
        score              => 0,
        require            => Pacemaker::Resource::Ocf['nova-evacuate'],
      }

      # Step 8 - add constraints to start ip addresses first and then nova-evacuate
      pacemaker::constraint::base { 'control_vip-then-nova-evacuate':
        constraint_type   => 'order',
        first_resource    => "ip-${control_vip}",
        second_resource   => 'nova-evacuate',
        first_action      => 'start',
        second_action     => 'start',
        require => [Pacemaker::Resource::Ocf['nova-evacuate'],
                    Pacemaker::Resource::Ip['control_vip']],
      }
      if $public_vip and $public_vip != $control_vip {
        pacemaker::constraint::base { 'public_vip-then-nova-evacuate':
          constraint_type   => 'order',
          first_resource    => "ip-${public_vip}",
          second_resource   => 'nova-evacuate',
          first_action      => 'start',
          second_action     => 'start',
          require => [Pacemaker::Resource::Ocf['nova-evacuate'],
                      Pacemaker::Resource::Ip['public_vip']],
        }
      }
      if $redis_vip and $redis_vip != $control_vip {
        pacemaker::constraint::base { 'redis_vip-then-nova-evacuate':
          constraint_type   => 'order',
          first_resource    => "ip-${redis_vip}",
          second_resource   => 'nova-evacuate',
          first_action      => 'start',
          second_action     => 'start',
          require => [Pacemaker::Resource::Ocf['nova-evacuate'],
                      Pacemaker::Resource::Ip['redis_vip']],
        }
      }
      if $internal_api_vip and $internal_api_vip != $control_vip {
        pacemaker::constraint::base { 'internal_api_vip-then-nova-evacuate':
          constraint_type   => 'order',
          first_resource    => "ip-${internal_api_vip}",
          second_resource   => 'nova-evacuate',
          first_action      => 'start',
          second_action     => 'start',
          require => [Pacemaker::Resource::Ocf['nova-evacuate'],
                      Pacemaker::Resource::Ip['internal_api_vip']],
        }
      }
      if $storage_vip and $storage_vip != $control_vip {
        pacemaker::constraint::base { 'storage_vip-then-nova-evacuate':
          constraint_type   => 'order',
          first_resource    => "ip-${storage_vip}",
          second_resource   => 'nova-evacuate',
          first_action      => 'start',
          second_action     => 'start',
          require => [Pacemaker::Resource::Ocf['nova-evacuate'],
                      Pacemaker::Resource::Ip['storage_vip']],
        }
      }
      if $storage_mgmt_vip and $storage_mgmt_vip != $control_vip {
        pacemaker::constraint::base { 'storage_mgmt_vip-then-nova-evacuate':
          constraint_type   => 'order',
          first_resource    => "ip-${storage_mgmt_vip}",
          second_resource   => 'nova-evacuate',
          first_action      => 'start',
          second_action     => 'start',
          require => [Pacemaker::Resource::Ocf['nova-evacuate'],
                      Pacemaker::Resource::Ip['storage_mgmt_vip']],
        }
      }
      # step 8 - openstack-glance-api-clone neutron-metadata-agent-clone openstack-nova-conductor-clone
      # FIXME: require-all: fedora does not have require-all yet? Which version anyway
      pacemaker::constraint::base { "${::glance::params::api_service_name}-then-nova-evacuate":
        constraint_type   => 'order',
        first_resource    => "${::glance::params::api_service_name}-clone",
        second_resource   => 'nova-evacuate',
        first_action      => 'start',
        second_action     => 'start',
        constraint_params => 'require-all=false',
        require => [Pacemaker::Resource::Ocf['nova-evacuate'],
                    Pacemaker::Resource::Service[$::glance::params::api_service_name]],
      }

      pacemaker::constraint::base { "${::neutron::params::metadata_agent_service}-then-nova-evacuate":
        constraint_type   => 'order',
        first_resource    => "${::neutron::params::metadata_agent_service}-clone",
        second_resource   => 'nova-evacuate',
        first_action      => 'start',
        second_action     => 'start',
        constraint_params => 'require-all=false',
        require => [Pacemaker::Resource::Ocf['nova-evacuate'],
                    Pacemaker::Resource::Service[$::neutron::params::metadata_agent_service]],
      }

      pacemaker::constraint::base { "${::nova::params::conductor_service_name}-then-nova-evacuate":
        constraint_type   => 'order',
        first_resource    => "${::nova::params::conductor_service_name}-clone",
        second_resource   => 'nova-evacuate',
        first_action      => 'start',
        second_action     => 'start',
        constraint_params => 'require-all=false',
        require => [Pacemaker::Resource::Ocf['nova-evacuate'],
                    Pacemaker::Resource::Service[$::nova::params::conductor_service_name]],
      }
      
      # Step 18 Instance HA
      # Add resource pacemaker:remote for compute nodes
      # FIXME: we need to guarantee that it happens as late as possible
      # not sure nova-evacuate is enough as a dependency
      $compute_node_names = split(downcase(hiera('compute_node_names')), ',')
      pacemaker::resource::ocf { $compute_node_names:
        ocf_agent_name  => 'pacemaker:remote',
        meta_params     => 'reconnect_interval=60 op monitor interval=20',
        require         => [Pacemaker::Resource::Ocf['nova-evacuate']],
      } ->
      class { "pcmk_node_tag_compute":
        node => $compute_node_names,
      } ->
      exec { "fence-nova-stonith":
        command => "/usr/sbin/pcs stonith create fence-nova fence_compute auth-url=${pacemaker_admin_uri} username=admin password=${admin_password} tenant_name=admin domain=localdomain record-only=1 action=off --force",
        unless => "/usr/sbin/pcs stonith show fence-nova > /dev/null 2>&1",
      } ->
      exec { "cluster-recheck-interval":
        command => "/usr/sbin/pcs property set cluster-recheck-interval=1min",
      } ->
      class { "pcmk_node_stonith_compute":
        node => $compute_node_names,
      }
    } #instance_ha

    #VSM
    if 'cisco_n1kv' in hiera('neutron::plugins::ml2::mechanism_drivers') {
      pacemaker::resource::ocf { 'vsm-p' :
        ocf_agent_name  => 'heartbeat:VirtualDomain',
        resource_params => 'force_stop=true config=/var/spool/cisco/vsm/vsm_primary_deploy.xml',
        require         => Class['n1k_vsm'],
        meta_params     => 'resource-stickiness=INFINITY',
      }
      if str2bool(hiera('n1k_vsm::pacemaker_control', true)) {
        pacemaker::resource::ocf { 'vsm-s' :
          ocf_agent_name  => 'heartbeat:VirtualDomain',
          resource_params => 'force_stop=true config=/var/spool/cisco/vsm/vsm_secondary_deploy.xml',
          require         => Class['n1k_vsm'],
          meta_params     => 'resource-stickiness=INFINITY',
        }
        pacemaker::constraint::colocation { 'vsm-colocation-contraint':
          source  => 'vsm-p',
          target  => 'vsm-s',
          score   => '-INFINITY',
          require => [Pacemaker::Resource::Ocf['vsm-p'],
                      Pacemaker::Resource::Ocf['vsm-s']],
        }
      }
    }

  }

} #END STEP 4

if hiera('step') >= 5 {

  if $pacemaker_master {
    if $instance_ha {
      # FIXME
      notify {"meh":}
    } 
    else {
      class {'::keystone::roles::admin' :
        require => Pacemaker::Resource::Service[$::keystone::params::service_name],
      } ->
      class {'::keystone::endpoint' :
        require => Pacemaker::Resource::Service[$::keystone::params::service_name],
      }
    }
    if $enable_fencing {
      include tripleo::fencing
      # FIXME: Currently we set up the compute fencing resources under the pacemaker_master branch
      # because we cannot run on compute nodes (lack of pcs command) and we do not want to run this
      # on each controller. Also we need to run this at the end because compute_map is calculated 
      # late in the game (at least from anedoctal evidence, need to investigate more)
      $compute_map = hiera('compute_map')
      $ret = compute_stonith($compute_map, $tripleo::fencing::config['devices'])
      $xvm = $ret[0]
      $ipmilan = $ret[1]
      $common_params = {
        'tries' => 10,
        'try_sleep' => 3,
        'manage_fw' => false,
      }

      # FIXME: We use the pacemaker::stonith::fence_xvm but we had to comment out the package fence-virt requirement as
      # it would give a duplicate definition error. Also had to set "manage_fw" to errors about duplicate Firewall resources
      create_resources('pacemaker::stonith::fence_xvm', $xvm, $common_params) 
      create_resources('pacemaker::stonith::fence_ipmilan', $ipmilan, $common_params)

      # Step 18
      # FIXME: need to create function that maps compute node name to stonith resource
      # that will/has been created
      #pcmk_node_stonith_compute($xvm.keys())
    }
  }

} #END STEP 5

$package_manifest_name = join(['/var/lib/tripleo/installed-packages/overcloud_controller_pacemaker', hiera('step')])
package_manifest{$package_manifest_name: ensure => present}
