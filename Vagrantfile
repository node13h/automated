Vagrant.configure("2") do |config|

  config.vm.provision "file", source: ".", destination: "/tmp/code"
  config.vm.provision "shell", path: "vagrant-provision.sh"

  config.vm.define "fedora" do |fedora|
    fedora.vm.box = "generic/fedora27"
    fedora.vm.hostname = "fedora"
    fedora.vm.network "private_network", ip: "192.168.50.2"
  end

  config.vm.define "centos" do |centos|
    centos.vm.box = "centos/7"
    centos.vm.hostname = "centos"
    centos.vm.network "private_network", ip: "192.168.50.3"
  end

  config.vm.define "ubuntu" do |ubuntu|
    ubuntu.vm.box = "ubuntu/xenial64"
    ubuntu.vm.hostname = "ubuntu"
    ubuntu.vm.network "private_network", ip: "192.168.50.4"
  end

  config.vm.define "freebsd" do |freebsd|
    freebsd.vm.box = "generic/freebsd11"
    freebsd.vm.hostname = "freebsd"
    freebsd.vm.network "private_network", ip: "192.168.50.5"
  end

end
