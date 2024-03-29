# Bash script for automatic restore of VMs from the Proxmox Backup Server (PBS) 3.X to the Proxmox VE 8.X.X
# Complete Guide https://www.alldiscoveries.com/prevent-long-disaster-recovery-on-hyper-converged-ceph-cluster-with-proxmox-v8-with-high-availability/
## The script allows the restoration of the "VM" from a backup, the synchronization of the disks, and the use of snapshots on ZFS to maintain previous versions.
## To synchronize disks we will use:
1 - Blocksync https://github.com/guppy/blocksync
2 - Bdsync https://github.com/rolffokkens/bdsync/

## Automatic installation and Bdsync compilation script for Proxmox VE 8.X.X available in this repository
https://github.com/thelogh/proxmox-restore-script/bdsync/bdsync-install.sh

## The Binary already compiled on Proxmox VE 8.1.2 is available here
https://github.com/thelogh/proxmox-restore-script/bdsync/bdsync
# Checksum
sha-512 = b9b339154e5fcdd40cc2a72ba9727e5df4e1bd0c10622f41c212afc104a42e1eb1502bdb0b08083aff3e908bddc0e7ec6561bad038d7a3439c43f3dadb8c21ef
