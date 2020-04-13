FROM centos:8

WORKDIR /home/root/puppetmaster

RUN yum -y install http://yum.puppet.com/puppet-release-el-8.noarch.rpm
RUN yum -y install puppet-agent
#RUN yum -y install puppetserver

RUN useradd -m puppet

ADD . /home/root/puppetmaster

CMD ./puppetmaster
ENTRYPOINT ./puppetmaster
