#!/bin/bash
# Bdsync install script by Thelogh
#Bdsync install script for automatic restore of VMs from the Proxmox Backup Server (PBS) 3.X to the Proxmox VE 8.1.X
#https://github.com/rolffokkens/bdsync
#https://www.alldiscoveries.com/prevent-long-disaster-recovery-on-hyper-converged-ceph-cluster-with-proxmox-v8-with-high-availability/
#For all requests write on the blog
#REPOSITORY
#https://github.com/thelogh/proxmox-restore-script
#V.1.0.0

apt-get install build-essential -y

apt-get install libssl-dev pandoc -y

apt-get install unzip -y

wget https://github.com/rolffokkens/bdsync/archive/master.zip

unzip master.zip

cd ./bdsync-master

make

chmod 755 ./bdsync

cp ./bdsync /usr/sbin

