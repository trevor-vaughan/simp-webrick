require 'puppet/network/http/api/indirected_routes'
require 'puppet/network/authconfig'

# Puppet 8 replaced Master::V3 with Server::V3, which calls
# Puppet::Network::Authorization.check_external_authorization on every
# request. That method raises HTTPNotAuthorizedError unless an external
# authconfigloader_class is set (a Puppet Server / JRuby concept that does
# not exist in the pure-Ruby master).
#
# This override restores the Puppet 6/7-style routing: requests are routed
# directly to IndirectedRoutes, which sets TrustedInformation from the
# params[:authenticated] / params[:node] values that extract_client_info
# (in rack/rest.rb) populated from Apache's X-Client-Verify / X-Client-DN
# SSL headers.  Authorization is enforced by Apache SSL client-cert
# verification at the transport layer.
class Puppet::Network::HTTP::API::Master::V3
  INDIRECTED = Puppet::Network::HTTP::Route
               .path(/.*/)
               .any(Puppet::Network::HTTP::API::IndirectedRoutes.new)

  def self.routes
    Puppet::Network::HTTP::Route.path(/v3/).any.chain(INDIRECTED)
  end
end
