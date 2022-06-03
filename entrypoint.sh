#!/bin/bash

export PATH=/opt/puppetlabs/puppet/bin:$PATH

fqdn=$( facter fqdn )

runuser - puppet -c '/usr/share/puppet_webrick/puppet_ca --confdir=/etc/puppetlabs/puppet list --all'
runuser - puppet -c "/usr/share/puppet_webrick/puppet_ca --confdir=/etc/puppetlabs/puppet generate ${fqdn}"

sed -i "s/__FQDN__/${fqdn}/" /etc/httpd/conf.d/puppet_apache.conf

/usr/sbin/httpd -D FOREGROUND
