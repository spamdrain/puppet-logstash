# This mangages the system service for Logstash.
#
# It is usually used only by the top-level `logstash` class. It's unlikely
# that you will need to declare this class yourself.
#
# @example Include this class to ensure its resources are available.
#   include logstash::service
#
# @author https://github.com/elastic/puppet-logstash/graphs/contributors
#
class logstash::service {
  $default_settings = {
    'path.data'   => '/var/lib/logstash',
    'path.config' => '/etc/logstash/conf.d',
    'path.logs'   => '/var/log/logstash',
  }

  $default_startup_options = {
    'LS_HOME'             => $logstash::home_dir,
    'LS_SETTINGS_DIR'     => $logstash::config_dir,
    'LS_PIDFILE'          => '/var/run/logstash.pid',
    'LS_USER'             => $logstash::logstash_user,
    'LS_GROUP'            => $logstash::logstash_group,
    'LS_GC_LOG_FILE'      => '/var/log/logstash/gc.log',
    'LS_OPEN_FILES'       => '16384',
    'LS_NICE'             => '19',
    'SERVICE_NAME'        => '"logstash"',
    'SERVICE_DESCRIPTION' => '"logstash"',
    'LS_OPTS'             => "--path.settings=${logstash::config_dir}",
    'LS_JAVA_OPTS'        => '""',
  }

  $settings = merge($default_settings, $logstash::settings)
  $startup_options = merge($default_startup_options, $logstash::startup_options)
  $pipelines = $logstash::pipelines

  File {
    owner  => 'root',
    group  => 'root',
    mode   => '0644',
    notify => Exec['logstash-system-install'],
  }

  if $logstash::ensure == 'present' {
    case $logstash::status {
      'enabled': {
        $service_ensure = 'running'
        $service_enable = true
      }
      'disabled': {
        $service_ensure = 'stopped'
        $service_enable = false
      }
      'running': {
        $service_ensure = 'running'
        $service_enable = false
      }
      default: {
        fail("\"${logstash::status}\" is an unknown service status value")
      }
    }
  } else {
    $service_ensure = 'stopped'
    $service_enable = false
  }

  if $service_ensure == 'running' {
    # Then make sure the Logstash startup options are up to date.
    file {'/etc/logstash/startup.options':
      content => template('logstash/startup.options.erb'),
    }

    # Add any additional JVM options
    $logstash::jvm_options.each |String $jvm_option| {
      file_line { "logstash_jvm_option_${jvm_option}":
        ensure => present,
        path   => "${logstash::config_dir}/jvm.options",
        line   => $jvm_option,
        notify => Service['logstash'],
        require => Package['logstash'],
      }
    }

    # ..and pipelines.yml, if the user provided such. If they didn't, zero out
    # the file, which will default Logstash to traditional single-pipeline
    # behaviour.
    if(empty($pipelines)) {
      file {'/etc/logstash/pipelines.yml':
        content => '',
      }
    }
    else {
      file {'/etc/logstash/pipelines.yml':
        content => template('logstash/pipelines.yml.erb'),
      }
    }

    # ..and the Logstash internal settings too.
    file {'/etc/logstash/logstash.yml':
      content => template('logstash/logstash.yml.erb'),
    }

    # Invoke 'system-install', which generates startup scripts based on the
    # contents of the 'startup.options' file.
    # Only if restart_on_change is not false
    if $::logstash::restart_on_change {
      exec { 'logstash-system-install':
        command     => "${logstash::home_dir}/bin/system-install",
        refreshonly => true,
        notify      => Service['logstash'],
      }
    } else {
      exec { 'logstash-system-install':
        command     => "${logstash::home_dir}/bin/system-install",
        refreshonly => true,
      }
    }
  }

  # Figure out which service provider (init system) we should be using.
  # In general, we'll try to guess based on the operating system.
  $os = downcase($::operatingsystem)
  $release = $::operatingsystemmajrelease
  # However, the operator may have explicitly defined the service provider.
  if($logstash::service_provider) {
    $service_provider = $logstash::service_provider
  }
  # In the absence of an explicit choice, we'll try to figure out a sensible
  # default.
  # Puppet 3 doesn't know that Debian 8 uses systemd, not SysV init, so we'll
  # help it out with our knowledge from the future.
  elsif($os == 'debian' and $release == '8') {
    $service_provider = 'systemd'
  }
  # RedHat/CentOS/OEL 6 uses Upstart by default, but Puppet can get confused about this too.
  elsif($os =~ /(redhat|centos|oraclelinux)/ and $release == '6') {
    $service_provider = 'upstart'
  }
  elsif($os =~ /ubuntu/ and $release == '12.04') {
    $service_provider = 'upstart'
  }
  elsif($os =~ /opensuse/ and $release == '13') {
    $service_provider = 'systemd'
  }
  #Older Amazon Linux AMIs has its release based on the year
  #it came out (2010 and up); the provider needed to be set explicitly;
  #New Amazon Linux 2 AMIs has the release set to 2, Puppet can handle it 
  elsif($os =~ /amazon/ and versioncmp($release, '2000') > 0) {
    $service_provider = 'upstart'
  }
  else {
    # In most cases, Puppet(4) can figure out the correct service
    # provider on its own, so we'll just say 'undef', and let it do
    # whatever it thinks is best.
    $service_provider = undef
  }

  service { 'logstash':
    ensure     => $service_ensure,
    enable     => $service_enable,
    hasstatus  => true,
    hasrestart => true,
    provider   => $service_provider,
  }

  # If any files tagged as config files for the service are changed, notify
  # the service so it restarts.
  if $::logstash::restart_on_change {
    File<| tag == 'logstash_config' |> ~> Service['logstash']
    Logstash::Plugin<| |> ~> Service['logstash']
  }
}
