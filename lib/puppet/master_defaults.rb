require 'puppet/util/platform'

module Puppet
  define_settings(:master,
    :masterhttplog => {
      :default => "$logdir/masterhttp.log",
      :type => :file,
      :owner => "service",
      :group => "service",
      :mode => "0660",
      :create => true,
      :desc => "Where the puppet master web server saves its access log. This is
        only used when running a WEBrick puppet master. When puppet master is
        running under a Rack server like Passenger, that web server will have
        its own logging behavior."
    },
    :ca => {
      :default    => true,
      :type       => :boolean,
      :desc       => "Whether the master should function as a certificate authority.",
    }
  )

  define_settings(:ca,
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
  settings.instance_variable_get('@deprecated_setting_names').delete(:ssl_server_ca_auth)

end
