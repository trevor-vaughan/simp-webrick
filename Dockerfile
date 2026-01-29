FROM quay.io/centos/centos:stream10 AS builder

WORKDIR /home/root/puppetmaster

RUN yum -y install https://yum.voxpupuli.org/openvox8-release-el-10.noarch.rpm \
    && yum -y install openvox-agent \
    && yum -y install libyaml glibc-headers autoconf gcc gcc-c++ glibc-devel readline-devel make automake libtool bison sqlite-devel \
    && /opt/puppetlabs/puppet/bin/gem install msgpack webrick --no-document \
    && yum clean all

FROM quay.io/centos/centos:stream10

WORKDIR /home/root/puppetmaster

COPY --from=builder /opt/puppetlabs/puppet/lib/ruby/gems/3.2.0 /opt/puppetlabs/puppet/lib/ruby/gems/3.2.0

RUN useradd -m puppet

COPY conf/auth.conf /etc/puppetlabs/puppet/auth.conf
RUN chown puppet:puppet /etc/puppetlabs/puppet/auth.conf
RUN chmod o-rwx /etc/puppetlabs/puppet/auth.conf

COPY . /home/root/puppetmaster

USER puppet
CMD ./puppet_server --user=puppet --group=puppet --no-daemonize --debug
