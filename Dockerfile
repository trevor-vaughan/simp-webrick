FROM centos:8

WORKDIR /home/root/puppetmaster

RUN yum -y install http://yum.puppet.com/puppet-release-el-8.noarch.rpm
RUN yum -y install puppet-agent
RUN yum -y install libyaml glibc-headers autoconf gcc gcc-c++ glibc-devel readline-devel make automake libtool bison sqlite-devel

# Force update to the latest puppet gem
#RUN /opt/puppetlabs/puppet/bin/gem install --force --no-ri --no-rdoc puppet

RUN /opt/puppetlabs/puppet/bin/gem install --no-ri --no-rdoc msgpack

RUN useradd -m puppet

ADD conf/auth.conf /etc/puppetlabs/puppet/auth.conf
RUN chown puppet:puppet /etc/puppetlabs/puppet/auth.conf
RUN chmod o-rwx /etc/puppetlabs/puppet/auth.conf

ADD . /home/root/puppetmaster

# Create the certs
#RUN ./puppet_server --user=root --group=root && kill $!

CMD ./puppet_server --user=root --group=root --no-daemonize --debug
