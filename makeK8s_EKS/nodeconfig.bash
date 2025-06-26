#!/bin/bash

KUBELET_CONFIG="/etc/kubernetes/kubelet/config.json"
jq '.cpuManagerPolicy = "static"' ${KUBELET_CONFIG} > ${KUBELET_CONFIG}.tmp
mv -f ${KUBELET_CONFIG}.tmp ${KUBELET_CONFIG}
rm -f /var/lib/kubelet/cpu_manager_state 
# Restart kubelet to apply changes
systemctl restart kubelet
sleep 2
cat /var/lib/kubelet/cpu_manager_state 
