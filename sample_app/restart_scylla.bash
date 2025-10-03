#!/bin/bash
#
sudo systemctl stop scylla-server
sudo rm -rf /var/lib/scylla/data
sudo find /var/lib/scylla/commitlog -type f -delete
sudo find /var/lib/scylla/hints -type f -delete
sudo find /var/lib/scylla/view_hints -type f -delete
sleep 10
sudo systemctl start scylla-server
sudo systemctl status scylla-server
sleep 10
nodetool repair
nodetool status
nodetool cluster repair |tee -a repair.out
