require 'puppet/ssl/base'
require 'puppet/indirector'

# Manage certificates.
class Puppet::SSL::Certificate < Puppet::SSL::Base
  # This is actually a certificate request.
  wraps OpenSSL::X509::Certificate

  extend Puppet::Indirector
  indirects :certificate, :terminus_class => :file, :doc => <<DOC
    This indirection wraps an `OpenSSL::X509::Certificate` object, representing a public SSL certificate.
    The indirection key is the certificate CN (generally a hostname).
DOC

  # Convert a string into an instance.
  def self.from_s(string)
    super(string, 'foo') # The name doesn't matter
  end

  # Because of how the format handler class is included, this
  # can't be in the base class.
  def self.supported_formats
    [:s]
  end

  def fingerprint(md = :SHA256)
    mds = md.to_s.upcase
    digest = OpenSSL::Digest.new(mds)
    digest.update(content.to_der).to_s.scan(/../).join(':')
  end
end
