require 'puppet/master_defaults'
require 'puppet/application'

class Puppet::Application::Master < Puppet::Application

  option("--debug", "-d")
  option("--verbose", "-v")

  # internal option, only to be used by ext/rack/config.ru
  option("--rack")

  option("--compile host",  "-c host") do |arg|
    options[:node] = arg
  end

  option("--logdest DEST",  "-l DEST") do |arg|
    handle_logdest_arg(arg)
  end

  def summary
    _("The puppet master daemon")
  end

  def help
    <<-HELP

puppet-master(8) -- #{summary}
========

SYNOPSIS
--------
The central puppet server. Functions as a certificate authority by
default.


USAGE
-----
puppet master [-D|--daemonize|--no-daemonize] [-d|--debug] [-h|--help]
  [-l|--logdest syslog|<FILE>|console] [-v|--verbose] [-V|--version]
  [--compile <NODE-NAME>]


DESCRIPTION
-----------
This command starts an instance of puppet master, running as a daemon
and using Ruby's built-in Webrick webserver. Puppet master can also be
managed by other application servers; when this is the case, this
executable is not used.


OPTIONS
-------

Note that any Puppet setting that's valid in the configuration file is also a
valid long argument. For example, 'server' is a valid setting, so you can
specify '--server <servername>' as an argument. Boolean settings translate into
'--setting' and '--no-setting' pairs.

See the configuration file documentation at
https://docs.puppetlabs.com/puppet/latest/reference/configuration.html for the
full list of acceptable settings. A commented list of all settings can also be
generated by running puppet master with '--genconfig'.

* --daemonize:
  Send the process into the background. This is the default.
  (This is a Puppet setting, and can go in puppet.conf. Note the special 'no-'
  prefix for boolean settings on the command line.)

* --no-daemonize:
  Do not send the process into the background.
  (This is a Puppet setting, and can go in puppet.conf. Note the special 'no-'
  prefix for boolean settings on the command line.)

* --debug:
  Enable full debugging.

* --help:
  Print this help message.

* --logdest:
  Where to send log messages. Choose between 'syslog' (the POSIX syslog
  service), 'console', or the path to a log file. If debugging or verbosity is
  enabled, this defaults to 'console'. Otherwise, it defaults to 'syslog'.

  A path ending with '.json' will receive structured output in JSON format. The
  log file will not have an ending ']' automatically written to it due to the
  appending nature of logging. It must be appended manually to make the content
  valid JSON.

* --masterport:
  The port on which to listen for traffic. The default port is 8140.
  (This is a Puppet setting, and can go in puppet.conf.)

* --verbose:
  Enable verbosity.

* --version:
  Print the puppet version number and exit.

* --compile:
  Compile a catalogue and output it in JSON from the puppet master. Uses
  facts contained in the $vardir/yaml/ directory to compile the catalog.


EXAMPLE
-------
  puppet master

DIAGNOSTICS
-----------

When running as a standalone daemon, puppet master accepts the
following signals:

* SIGHUP:
  Restart the puppet master server.
* SIGINT and SIGTERM:
  Shut down the puppet master server.
* SIGUSR2:
  Close file descriptors for log files and reopen them. Used with logrotate.

AUTHOR
------
Luke Kanies


COPYRIGHT
---------
Copyright (c) 2012 Puppet Inc., LLC Licensed under the Apache 2.0 License

    HELP
  end

  def app_defaults
    super.merge({
      :facts_terminus => 'yaml'
    })
  end

  def preinit
    Signal.trap(:INT) do
      $stderr.puts _("Canceling startup")
      exit(0)
    end

    # save ARGV to protect us from it being smashed later by something
    @argv = ARGV.dup
  end

  def run_command
    if options[:node]
      compile
    else
      main
    end
  end

  def compile
    begin
      unless catalog = Puppet::Resource::Catalog.indirection.find(options[:node])
        raise _("Could not compile catalog for %{node}") % { node: options[:node] }
      end

      puts JSON::pretty_generate(catalog.to_resource, :allow_nan => true, :max_nesting => false)
    rescue => detail
      Puppet.log_exception(detail, _("Failed to compile catalog for node %{node}: %{detail}") % { node: options[:node], detail: detail })
      exit(30)
    end
    exit(0)
  end

  def main
    require 'etc'
    # Make sure we've got a localhost ssl cert
    Puppet::SSL::Host.localhost

    # And now configure our server to *only* hit the CA for data, because that's
    # all it will have write access to.
    Puppet::SSL::Host.ca_location = :only if Puppet::SSL::CertificateAuthority.ca?

    if Puppet.features.root?
      if Puppet::Type.type(:user).new(:name => Puppet[:user]).exists?
        begin
          Puppet::Util.chuser
        rescue => detail
          Puppet.log_exception(detail, _("Could not change user to %{user}: %{detail}") % { user: Puppet[:user], detail: detail })
          exit(39)
        end
      else
        Puppet.err(_("Could not change user to %{user}. User does not exist and is required to continue.") % { user: Puppet[:user] })
        exit(74)
      end
    end

    if options[:rack]
      start_rack_master
    else
      start_webrick_master
    end
  end

  def setup_logs
    set_log_level

    if !options[:setdest]
      if options[:node]
        # We are compiling a catalog for a single node with '--compile' and logging
        # has not already been configured via '--logdest' so log to the console.
        Puppet::Util::Log.newdestination(:console)
      elsif !(Puppet[:daemonize] or options[:rack])
        # We are running a webrick master which has been explicitly foregrounded
        # and '--logdest' has not been passed, assume users want to see logging
        # and log to the console.
        Puppet::Util::Log.newdestination(:console)
      else
        # No explicit log destination has been given with '--logdest' and we're
        # either a daemonized webrick master or running under rack, log to syslog.
        Puppet::Util::Log.newdestination(:syslog)
      end
    end
  end

  def setup_terminuses
    require 'puppet/file_serving/content'
    require 'puppet/file_serving/metadata'

    Puppet::FileServing::Content.indirection.terminus_class = :file_server
    Puppet::FileServing::Metadata.indirection.terminus_class = :file_server

    Puppet::FileBucket::File.indirection.terminus_class = :file
  end

  def setup_ssl
    # Configure all of the SSL stuff.
    if Puppet::SSL::CertificateAuthority.ca?
      Puppet::SSL::Host.ca_location = :local
      Puppet.settings.use :ca
      Puppet::SSL::CertificateAuthority.instance
    else
      Puppet::SSL::Host.ca_location = :none
    end
    Puppet::SSL::Oids.register_puppet_oids
    Puppet::SSL::Oids.load_custom_oid_file(Puppet[:trusted_oid_mapping_file])
  end

  # Honor the :node_cache_terminus setting if users have specified it directly.
  # We normally want this nil as use-cases for querying nodes should be going to
  # PuppetDB.
  # @see PUP-6060
  # @return [void]
  def setup_node_cache
    Puppet::Node.indirection.cache_class = Puppet[:node_cache_terminus]
  end

  def setup
    raise Puppet::Error.new(_("Puppet master is not supported on Microsoft Windows")) if Puppet.features.microsoft_windows?

    setup_logs

    exit(Puppet.settings.print_configs ? 0 : 1) if Puppet.settings.print_configs?

    Puppet.settings.use :main, Puppet.settings.preferred_run_mode.to_sym, :ssl, :metrics

    setup_terminuses

    setup_node_cache

    setup_ssl
  end

  private

  # Start a master that will be using WeBrick.
  #
  # This method will block until the master exits.
  def start_webrick_master
    require 'puppet/network/server'
    require 'puppet/webrick_server/daemon'
    require 'puppet/util/pidlock'

    daemon = Puppet::WebrickServer::Daemon.new(Puppet::Util::Pidlock.new(Puppet[:pidfile]))

    daemon.argv = @argv
    port = Puppet[:masterport]
    port = Puppet[:serverport] if Puppet[:serverport]

    daemon.server = Puppet::Network::Server.new(Puppet[:bindaddress], port)
    daemon.daemonize if Puppet[:daemonize]

    # Setup signal traps immediately after daemonization so we clean up the daemon
    daemon.set_signal_traps

    announce_start_of_master

    daemon.start
  end

  # Start a master that will be used for a Rack container.
  #
  # This method immediately returns the Rack handler that must be returned to
  # the calling Rack container
  def start_rack_master
    require 'puppet/network/http/rack'

    announce_start_of_master

    return Puppet::Network::HTTP::Rack.new()
  end

  def announce_start_of_master
    Puppet.notice _("Starting Puppet master version %{version}") % { version: Puppet.version }
  end
end
