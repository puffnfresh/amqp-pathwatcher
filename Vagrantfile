# -*- mode: ruby -*-
# vi: set ft=ruby :

VAGRANTFILE_API_VERSION = "2"

Vagrant.configure(VAGRANTFILE_API_VERSION) do |config|
  config.vm.define "amqp-pathwatcher" do |v|
    v.vm.box = "hashicorp/precise32"

    v.vm.provider "virtualbox" do |vb|
      vb.customize ["modifyvm", :id, "--memory", "2048"]
    end

    v.vm.network "forwarded_port", guest: 55672, host: 15672
    v.vm.provision :shell, :path => "bootstrap.sh"
  end
end
