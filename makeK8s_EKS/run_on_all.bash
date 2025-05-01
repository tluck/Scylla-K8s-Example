#!/usr/bin/env bash 

allNgs=false

if [[ $1 == "-a" ]]; then
    allNgs=true
    shift;
fi

source init.conf
region=$(terraform output -raw region)
clusterName=$(terraform output -raw eks_cluster_name)
sshKey=$(terraform output -raw sshKey|sed -e's/pub/private.pem/')
ngc=0

terraform output

for ng in $(aws --region ${region} eks list-nodegroups --cluster-name ${clusterName} |jq -r .nodegroups[] ); do
    printf "\nRunning on nodegroup ${ng}\n"
    instanceIds=$( aws --region ${region} autoscaling describe-auto-scaling-groups --auto-scaling-group-names \
        $(aws --region ${region} eks describe-nodegroup  --cluster-name ${clusterName} --nodegroup ${ng} \
        |jq -r ".nodegroup.resources.autoScalingGroups[].name") \
        |jq -r ".AutoScalingGroups[].Instances[].InstanceId" )
    nodesPublic=(  $( aws --region ${region} ec2 describe-instances --instance-ids ${instanceIds} --query 'Reservations[*].Instances[*].PublicDnsName' --output text ) )
#    nodesPrivate=( $( aws --region ${region} ec2 describe-instances --instance-ids ${instanceIds} --query 'Reservations[*].Instances[*].PrivateDnsName' --output text ) )
for n in ${nodesPublic[@]}
do
    printf "\nssh -i ${sshKey} ec2-user@${n} sudo $@\n"
    ssh -i ${sshKey} ec2-user@${n} sudo "$@"
done
[[ ${allNgs} != true ]] && exit
done
