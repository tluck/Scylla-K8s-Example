#!/usr/bin/env bash 

currentContext=$(kubectl config current-context)
kubectl config unset current-context
[[ -e init.conf ]] && source init.conf
[[ -n ${currentContext} ]] && kubectl config set current-context ${currentContext}

if [[ $1 == "-d" ]]; then
    delete=1
    shift;
fi

if [[ $1 == "-l" ]]; then
    listout=1
    shift;
fi

verb=${1:-"apply -auto-approve"}

#instance="${instance0:-m5a.2xlarge}" # "i3en.2xlarge"
mountPath=${1:-${mountPath}}

if [[ $delete == 1 ]]; then
    clusterName=$(terraform output -raw eks_cluster_name)
    [[ ${clusterName} != *"No output"* ]] && delete-k8s-config.bash $( kubectl config get-clusters|grep $(terraform output -raw eks_cluster_name) )
    terraform destroy -auto-approve
    exit
else

    if [[ ${listout} == 1 ]]; then 
        terraform output | sed -e's/ = /=/' -e's/\[/(/' -e's/\]/)/' -e's/,$//'
    else

    if [[ ! -e .terraform ]]; then
        printf "%s\n" "No .terraform directory found, running terraform init"
        terraform init
    fi
    printf "%s\n" "Running terraform ${verb}"
    terraform ${verb} \
        -var="eks_cluster_version=${k8sVersion}" \
        -var="eks_nodegroup_version=${ngVersion}" \
        -var="capacity_type=${capacityType}" \
        -var=ng_0_size=${nodeGroup0size} \
        -var=ng_1_size=${nodeGroup1size} \
        -var=ng_2_size=${nodeGroup2size} \
        -var="instance0=${instance0}" \
        -var="instance1=${instance1}" \
        -var="instance2=${instance2}" \
        -var="ebsSize=${ebsSize}" \
        -var="prefix=${prefix}" \
        -var="vpc_id=${vpcId}" \
        -var="ssh_public_key_file=${sshKey}"

    if [[ ${verb} != *"apply"* ]]; then
        exit 0
    fi
    fi 
    region=$(terraform output -raw region)
    clusterName=$(terraform output -raw eks_cluster_name)
    printf "Making the kubeconfig for the new cluster\n"
    aws --region ${region} eks update-kubeconfig --name ${clusterName}
    printf "Making gp2 the default storage class\n"
    kubectl patch storageclass gp2 -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'

    sshKey=$(terraform output -raw sshKey) # is the public key name (was set in variables)
    ngc=0
    for ng in $(aws --region ${region} eks list-nodegroups --cluster-name ${clusterName} |jq -r '.nodegroups[]' ); do

    instanceIds=$( aws --region ${region} autoscaling describe-auto-scaling-groups --auto-scaling-group-names \
        $(aws --region ${region} eks describe-nodegroup  --cluster-name ${clusterName} --nodegroup ${ng} \
        |jq -r ".nodegroup.resources.autoScalingGroups[].name") \
        |jq -r ".AutoScalingGroups[].Instances[].InstanceId" )

    nodesPublic=(  $( aws --region ${region} ec2 describe-instances --instance-ids ${instanceIds} --query 'Reservations[*].Instances[*].PublicDnsName' --output text ) )
    nodesPrivate=( $( aws --region ${region} ec2 describe-instances --instance-ids ${instanceIds} --query 'Reservations[*].Instances[*].PrivateDnsName' --output text ) )
    nc=0
    for n in ${nodesPublic[@]}
    do
    if [[ ${listout} != 1 ]] ; then
    ssh-keyscan -H $n >> ~/.ssh/known_hosts 2> /dev/null
    kubectl label nodes ${nodesPrivate[$nc]} name=node-${ngc}-${nc} --overwrite=true
    fi

    nc=$((nc+1))
    done
    ngc=$((ngc+1))
    done

    [[ ${listout} != 1 ]] && terraform output
    ngc=0
    for ng in $(aws --region ${region} eks list-nodegroups --cluster-name ${clusterName} |jq -r '.nodegroups[]' ); do
    printf "Node group $ng\n"

    instanceIds=$( aws --region ${region} autoscaling describe-auto-scaling-groups --auto-scaling-group-names \
        $(aws --region ${region} eks describe-nodegroup  --cluster-name ${clusterName} --nodegroup ${ng} \
        |jq -r ".nodegroup.resources.autoScalingGroups[].name") \
        |jq -r ".AutoScalingGroups[].Instances[].InstanceId" )

    nodesPublic=(  $( aws --region ${region} ec2 describe-instances --instance-ids ${instanceIds} --query 'Reservations[*].Instances[*].PublicDnsName' --output text ) )
    nodesPrivate=( $( aws --region ${region} ec2 describe-instances --instance-ids ${instanceIds} --query 'Reservations[*].Instances[*].PrivateDnsName' --output text ) )
    nc=0
      for n in ${nodesPublic[@]}
      do
      printf "\tssh -i ${sshKey/pub/pem} ec2-user@${n}\n"
      nc=$((nc+1))
      done
    ngc=$((ngc+1))
    done
    # this is now configured in the TF script
    # ./run_nodeconfig.bash

fi
