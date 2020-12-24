require 'puppet/indirector/ssl_file'
require 'puppet/ssl/key'

# @deprecated
class Puppet::SSL::Key::File < Puppet::Indirector::SslFile
  desc "Manage SSL private and public keys on disk."

  store_in :privatekeydir

  def allow_remote_requests?
    false
  end

  # Where should we store the public key?
  def public_key_path(name)
    File.join(Puppet[:publickeydir], name.to_s + ".pem")
  end

  # Remove the public key, in addition to the private key
  def destroy(request)
    super

    key_path = Puppet::FileSystem.pathname(public_key_path(request.key))
    return unless Puppet::FileSystem.exist?(key_path)

    begin
      Puppet::FileSystem.unlink(key_path)
    rescue => detail
      raise Puppet::Error, _("Could not remove %{request} public key: %{detail}") % { request: request.key, detail: detail }, detail.backtrace
    end
  end

  # Save the public key, in addition to the private key.
  def save(request)
    super

    begin
      # RFC 1421 states PEM is 7-bit ASCII https://tools.ietf.org/html/rfc1421
      Puppet.settings.setting(:publickeydir).open_file(public_key_path(request.key), 'w:ASCII') do |f|
        f.print request.instance.content.public_key.to_pem
      end
    rescue => detail
      raise Puppet::Error, _("Could not write %{request}: %{detail}") % { request: request.key, detail: detail }, detail.backtrace
    end
  end
end
