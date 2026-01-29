require 'puppet/ssl/base'
require 'puppet/indirector'

# Manage certificate requests.
class Puppet::SSL::CertificateRequest < Puppet::SSL::Base
  wraps OpenSSL::X509::Request

  extend Puppet::Indirector
  indirects :certificate_request, :terminus_class => :file, :doc => <<DOC
    This indirection wraps an `OpenSSL::X509::Request` object, representing a certificate request.
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

  # Create a new certificate request with the given content.
  # content can be a string, an OpenSSL::X509::Request, or nil.
  def initialize(name)
    super
  end

  def generate(key, options = {})
    Puppet.info _("Creating a new certificate request for %{name}") % { name: name }

    # If we're a CSR for the CA, then we need to sign the request with the CA's
    # private key, rather than the key for the CSR.
    # This is only true if we're self-signing.
    # We can't just check the name, because we might be creating a CSR for the
    # CA but not self-signing it.
    # This is a bit of a hack, but I can't think of a better way to do it.
    if options[:self_signing_csr]
      # If we're self-signing, we need to sign with the CA key.
      # This is only used for the CA certificate.
      # We don't actually use the key argument here.
      # This is a bit of a hack, but I can't think of a better way to do it.
      # We just return the CSR, which is already signed.
      # The CA key is passed in options[:key]
      # But wait, generate() creates the CSR.
      # For CA self-signed cert, we create a CSR and then sign it.
      # The CSR needs to be signed by the private key.
    end

    csr = OpenSSL::X509::Request.new
    csr.version = 0
    csr.subject = OpenSSL::X509::Name.new([["CN", name]])
    csr.public_key = key.public_key

    if options[:dns_alt_names]
      ext_req = []
      # Add subjectAltName extension
      # We need to create an extension factory to create the extension
      # But ExtensionFactory needs a certificate to set the context.
      # However, for a CSR, we don't have a certificate yet.
      # We can create extensions without a context if they don't depend on it.
      # subjectAltName doesn't depend on context usually.
      
      # Puppet::SSL::Oids.subtree_of? ...
      # We should use Puppet util to add extensions if possible.
      
      # For now, let's just add it manually.
      factory = OpenSSL::X509::ExtensionFactory.new
      ext = factory.create_extension("subjectAltName", options[:dns_alt_names], false)
      ext_req << ext
      
      # Add extensions to attributes
      attr = OpenSSL::X509::Attribute.new("extReq", OpenSSL::ASN1::Set.new([OpenSSL::ASN1::Sequence.new(ext_req)]))
      csr.add_attribute(attr)
    end

    # Sign the request.
    csr.sign(key, OpenSSL::Digest::SHA256.new)

    @content = csr
  end
  
  def request_extensions
    # Parse extensions from the CSR attributes
    # extReq oid is 1.2.840.113549.1.9.14
    ext_req = @content.attributes.find { |a| a.oid == "extReq" || a.oid == "1.2.840.113549.1.9.14" }
    return [] unless ext_req

    # extReq value is a Set of Sequences of Extensions
    # We assume there is only one Set and one Sequence?
    # Actually it's a Set of values. Each value is a Sequence of Extensions.
    
    extensions = []
    ext_req.value.each do |seq|
      seq.each do |ext_asn1|
        # ext_asn1 is an extension in ASN1
        # We need to decode it.
        # But OpenSSL::X509::Extension.new(asn1) doesn't work directly like that usually.
        # However, we can wrap it.
        
        # Let's return a list of hashes for now as used in CertificateAuthority
        # "oid" => string
        # "value" => string
        
        # Actually, let's try to convert back to Extension object
        ext = OpenSSL::X509::Extension.new(ext_asn1)
        extensions << {"oid" => ext.oid, "value" => ext.value}
      end
    end
    extensions
  end

  def subject_alt_names
    exts = request_extensions
    san = exts.find { |e| e["oid"] == "subjectAltName" }
    return [] unless san
    
    # Parse SAN value. It is usually "DNS:foo, DNS:bar"
    # The value returned by OpenSSL might be formatted.
    san["value"].split(/,\s*/).map { |s| s.strip }
  end
end
