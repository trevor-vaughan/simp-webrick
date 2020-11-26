require 'puppet/daemon'

module Puppet::WebrickServer
  class FakeAgent
    def run(args=nil)
      #noop
    end
  end

  class Daemon < Puppet::Daemon
    attr_accessor :server

    def initialize(pidfile, scheduler = Puppet::Scheduler::Scheduler.new())
      super(FakeAgent.new, pidfile, scheduler)
    end

    def reload
      #noop
    end

    def stop(args = {:exit => true})
      Puppet::Application.stop!
      server.stop

      super(args)
    end

    def start
      create_pidfile
      server.start
      server.wait_for_shutdown
    end
  end
end
