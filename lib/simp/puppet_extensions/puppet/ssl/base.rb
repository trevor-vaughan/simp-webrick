module SIMP; end
module SIMP::PuppetExtensions; end
module SIMP::PuppetExtensions::SSL; end
module SIMP::PuppetExtensions::SSL::Base
  require 'puppet/ssl/base'

  unless Puppet::SSL::Base.methods.include?(:ca?)
    class Puppet::SSL::Base
      # Is this file for the CA?
      def ca?
        require 'puppet/ssl/host'

        name == Puppet::SSL::Host.ca_name
      end
    end
  end
end
