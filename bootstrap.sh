#!/usr/bin/env bash

apt-get update
apt-get install -y rabbitmq-server haskell-platform
/usr/lib/rabbitmq/lib/rabbitmq_server-2.7.1/sbin/rabbitmq-plugins enable rabbitmq_management 
service rabbitmq-server restart

cd /vagrant
cabal update
cabal install --only-dep
cabal configure
cabal build
