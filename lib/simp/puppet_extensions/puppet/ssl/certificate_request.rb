module SIMP; end
module SIMP::PuppetExtensions; end
module SIMP::PuppetExtensions::SSL; end
module SIMP::PuppetExtensions::SSL::CertificateRequest
  require 'puppet/ssl/certificate_request'

  unless Puppet::SSL::CertificateRequest.methods.include?(:indirects)
    class Puppet::SSL::CertificateRequest
      require 'puppet/indirector'

      extend Puppet::Indirector
      indirects :certificate_request, :terminus_class => :file, :doc => <<~DOC
        This indirection wraps an `OpenSSL::X509::Request` object, representing a certificate signing request (CSR).
        The indirection key is the certificate CN (generally a hostname).
      DOC
    end
  end
end
