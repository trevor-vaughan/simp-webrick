Vagrant.configure("2") do |c|
  c.ssh.insert_key = false

  c.vm.define 'centos7' do |v|
    v.vm.hostname = 'centos7.test.net'
    v.vm.box = 'centos/7'
    v.vm.box_check_update = 'false'
    v.vm.provider :virtualbox do |vb|
      vb.customize ['modifyvm', :id, '--memory', '6144', '--cpus', '2']
    end

    v.vm.synced_folder './', '/vagrant', type: 'rsync',
      rsync__auto: true

    v.vm.provision 'shell', inline: 'yum -y install podman buildah git slirp4netns'
    v.vm.provision 'shell', inline: 'yum -y update'

    v.vm.provision 'shell', inline: 'echo 10000 > /proc/sys/user/max_user_namespaces'
    v.vm.provision 'shell', inline: 'echo "vagrant:100000:65536" >> /etc/subuid'
    v.vm.provision 'shell', inline: 'echo "vagrant:100000:65536" >> /etc/subgid'

    # Install RVM for development
    v.vm.provision 'shell', inline: 'runuser vagrant -l -c "gpg --keyserver hkp://pool.sks-keyservers.net --recv-keys 409B6B1796C275462A1703113804BB82D39DC0E3 7D2BAF1CF37B13E2069D6956105BD0E739499BDB"'
    v.vm.provision 'shell', inline: 'runuser vagrant -l -c "curl -sSL https://get.rvm.io | bash"'
  end
end
