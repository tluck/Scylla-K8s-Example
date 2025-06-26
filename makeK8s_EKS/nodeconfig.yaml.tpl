apiVersion: node.eks.aws/v1alpha1
kind: NodeConfig
spec:
  cluster:
    name: ${cluster_name}
    apiServerEndpoint: ${cluster_endpoint}
    cidr: ${cluster_service_cidr}
    certificateAuthority: "${module.eks.cluster_certificate_authority_data}"
  kubelet:
    config:
      kind: KubeletConfiguration
      apiVersion: kubelet.config.k8s.io/v1beta1
      cpuManagerPolicy: static

