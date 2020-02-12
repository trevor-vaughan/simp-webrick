namespace :oci do
  directory 'oci/images'

  CLEAN.include('oci/images')
  CLOBBER.include('oci')

  desc <<~EOM
    Spin up an OCI image for the project based on the underlying system.

    Arguments:
      * :image_name => The name that you wish to give the resulting OCI image
      * :releasever => The EL release version that you want to support. Defaults to 7
  EOM
  task :image, [:image_name, :releasever] => ['oci/images'] do |t, args|
    args.with_defaults(:image_name => 'simp_puppetmaster')
    args.with_defaults(:releasever => '7')

    new_container = %x{buildah from scratch}.strip
    tmpdir = %x{buildah unshare -- sh -c 'buildah mount #{new_container}'}.strip

    sh %{yum install --installroot #{tmpdir} bash coreutils --releasever #{args[:releasever]} --setopt=tsflags=nodocs --setopt=override_install_langs=en_US.utf8 -y}

    rm_rf "#{tmpdir}/var/cache/yum" if File.directory?(tmpdir)

    sh %{buildah config --label name="#{args[:image_name]}" #{new_container}}
    sh %{buildah config --cmd /bin/bash #{new_container}}

    sh %{buildah unshare -- sh -c 'buildah unmount #{new_container}'}.strip
    sh %{buildah commit #{new_container} "#{args[:image_name]}"}
  end
end
