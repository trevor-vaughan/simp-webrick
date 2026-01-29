# CA operations are handled by the Go puppet-ca service.
# Apache proxies all /puppet-ca traffic to it before Passenger sees it.
# This stub exists as a safety net for any requests that bypass the proxy.
class Puppet::Network::HTTP::API::CA::V1
  STUB = Puppet::Network::HTTP::Route.
    path(/.*/).
    any(lambda do |_req, res|
      msg = "CA operations are not handled by this master.\n" \
            "Direct /puppet-ca requests to the puppet-ca service (Go CA).\n"
      res.respond_with(503, "text/plain", msg)
    end)

  def self.routes
    Puppet::Network::HTTP::Route.path(%r{v1}).any.chain(STUB)
  end
end
