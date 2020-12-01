require 'puppet/util/platform'

module Puppet
  settings_target = :master

  if settings[:serverport]
    settings_target = :server
  end

  settings.preferred_run_mode = "#{settings_target}"

  # Override for compatibility with Puppet 7+
  settings[:cadir] = File.join(settings[:ssldir], 'ca')

  settings.define_settings(settings_target,
    :"#{settings_target}httplog" => {
      :default => "$logdir/#{settings_target}http.log",
      :type => :file,
      :owner => "service",
      :group => "service",
      :mode => "0660",
      :create => true,
      :desc => "Where the puppet #{settings_target} web server saves its access log. This is
        only used when running a WEBrick puppet #{settings_target}. When puppet #{settings_target} is
        running under a Rack server like Passenger, that web server will have
        its own logging behavior."
    },
    :ca => {
      :default    => true,
      :type       => :boolean,
      :desc       => "Whether the #{settings_target} should function as a certificate authority.",
    }
  )

  settings.define_settings(:ca,
    :caprivatedir => {
      :default => "$cadir/private",
      :type => :directory,
      :owner => "service",
      :group => "service",
      :mode => "0750",
      :desc => "Where the CA stores private certificate information."
    },
    :capass => {
      :default => "$caprivatedir/ca.pass",
      :type => :file,
      :owner => "service",
      :group => "service",
      :mode => "0640",
      :desc => "Where the CA stores the password for the private key."
    }
  )

  # Work around deprecation notices
  deprecated_settings_to_ignore = [
    :ssl_server_ca_auth,
    :rest_authconfig,
    :authconfig
  ]

  deprecated_settings_to_ignore.each do |setting|
    settings.instance_variable_get('@deprecated_setting_names').delete(setting)
  end
end
