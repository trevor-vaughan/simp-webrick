# Master-specific config.ru

require 'rack'
require 'puppet/util/command_line'

# Set up the load path
$LOAD_PATH.unshift('/usr/share/puppet_webrick/lib')

# Set the process name
$0 = "puppet-master"

# Configure Puppet settings
ARGV.clear
ARGV << "--rack"
ARGV << "--confdir" << "/etc/puppetlabs/puppet"
ARGV << "--vardir"  << "/opt/puppetlabs/server/data/puppetmaster"
ARGV << "--logdir"  << "/var/log/puppetlabs/puppetmaster"
ARGV << "--rundir"  << "/var/run/puppetlabs/puppetmaster"
ARGV << "--codedir" << "/etc/puppetlabs/code"

# Master-specific settings
ARGV << "--no-ca"
ARGV << "--no-daemonize"

# Initialize Puppet
require 'puppet'

# Puppet 8 pre-loads puppet/ssl/certificate and puppet/ssl/certificate_request
# via require_relative (absolute paths), bypassing our $LOAD_PATH prepend.
# Use `load` to force our custom versions to reopen those classes and add
# the Indirector support that the rest of this library depends on.
[
  'puppet/ssl/certificate',
  'puppet/ssl/certificate_request',
].each do |lib|
  load(File.join('/usr/share/puppet_webrick/lib', lib + '.rb'))
end

require 'puppet/ssl/host'
require 'puppet/network/http/rack'

# Initialize settings/logs
Puppet::Util::Log.newdestination(:console)
Puppet.initialize_settings

# The Rack app initialises in 'user' run_mode.  Force the facts terminus to
# 'memory' so the catalog compiler can hold incoming agent facts during
# compilation.  'facter' (the default) raises on save(); 'yaml' tries to
# write to the puppet user's home directory which is not prepared for
# server use.
Puppet[:facts_terminus] = 'memory'

# Puppet 8's scope.rb deep-freezes the facts hash during catalog compilation
# (scope.rb: setvar('facts', deep_freeze(hash), ...)).  Because the memory
# terminus stores the same Ruby object, the stored facts hash becomes frozen.
# Subsequent requests that call Puppet::Node::Facts#sanitize then fail with
# "can't modify frozen Hash".  Dup the values before sanitizing if frozen.
require 'puppet/node/facts'
Puppet::Node::Facts.prepend(Module.new do
  def sanitize
    @values = @values.dup if @values.frozen?
    super
  end
end)

# Ensure we are NOT a CA
Puppet::SSL::Host.ca_location = :none

run Puppet::Network::HTTP::Rack.new
