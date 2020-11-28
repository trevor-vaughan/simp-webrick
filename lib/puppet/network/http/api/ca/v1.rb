require 'puppet/network/http/api/indirected_routes'
class Puppet::Network::HTTP::API::IndirectedRoutesMunge < Puppet::Network::HTTP::API::IndirectedRoutes
  def call(request, response)
    if request.path =~ /puppet-ca/
      unless request.params[:environment]
        request.params[:environment] = 'production'
      end
    end

    super(request, response)
  end
end

class Puppet::Network::HTTP::API::CA::V1

  INDIRECTED = Puppet::Network::HTTP::Route.
    path(/.*/).
    any(Puppet::Network::HTTP::API::IndirectedRoutesMunge.new)

  def self.routes
    Puppet::Network::HTTP::Route.path(%r{v1}).any.chain(INDIRECTED)
  end
end
