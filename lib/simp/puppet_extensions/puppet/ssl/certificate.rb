module SIMP; end
module SIMP::PuppetExtensions; end
module SIMP::PuppetExtensions::SSL; end
module SIMP::PuppetExtensions::SSL::Certificate
  require 'puppet/ssl/certificate'

  unless Puppet::SSL::Certificate.methods.include?(:indirects)
    class Puppet::SSL::Certificate
      require 'puppet/indirector'

      extend Puppet::Indirector
      indirects :certificate, :terminus_class => :file, :doc => <<~DOC
        This indirection wraps an `OpenSSL::X509::Certificate` object, representing a certificate (signed public key).
        The indirection key is the certificate CN (generally a hostname).
      DOC
    end
  end
end
