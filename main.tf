//module "test_instance" {
//  source = "./ec2"
//
//  aws_region         = var.aws_region
//  name_tag           = var.name_tag
//  vpc_security_group = module.vpc_sg.security-group-id
//  subnet_id = element(module.subnets.public_subnet_ids, 0)
//}
//
//module "vpc_sg" {
//  source = "./sg"
//
//  vpc_id   = module.vpc.vpc_id
//  name_tag = var.sg_name_tag
//}

locals {
  # enforce usage of eks_worker_ami_name_filter variable to set the right kubernetes version for EKS workers,
  # otherwise the first version of Kubernetes supported by AWS (v1.11) for EKS workers will be used, but
  # EKS control plane will use the version specified by kubernetes_version variable.
  eks_worker_ami_name_filter = "amazon-eks-node-${var.kubernetes_version}*"
}

data "null_data_source" "wait_for_cluster_and_kubernetes_configmap" {
  inputs = {
    cluster_name             = module.eks_cluster.eks_cluster_id
    kubernetes_config_map_id = module.eks_cluster.kubernetes_config_map_id
  }
}

module "vpc" {
  source     = "./vpc"
  cidr_block = "172.31.208.0/22" #172.31.212.0/22     172.31.216.0/22
}

module "subnets" {
  source              = "./subnet"
  vpc_id              = module.vpc.vpc_id
  igw_id              = module.vpc.igw_id
  nat_gateway_enabled = false
}

# load balancer
module "network_loadbalancer" {
  source                         = "./nlb"
  name                           = var.name
  aws_region                     = var.aws_region
  vpc_id                         = module.vpc.vpc_id
  vpc_public_subnet_ids          = module.subnets.public_subnet_ids
  aws-load-balancer-ssl-cert-arn = "arn:aws:acm:ap-southeast-1:384367358464:certificate/c5e33e2e-2d72-40f5-ae10-751ee7596199"

  listeners = [
    {
      port     = 80
      protocol = "TCP",
      target_groups = {
        port              = 30080
        proxy_protocol    = false
        health_check_port = "traffic-port"
      }
    },
    {
      port     = 443
      protocol = "TLS",
      target_groups = {
        port              = 30080
        proxy_protocol    = false
        health_check_port = "traffic-port"
      }
    }
  ]

  # below security group will need to be changed, once we know which port and ip.
  security_group_for_eks = [
    {
      port_from  = 0
      port_to    = 65535
      protocol   = "-1"
      cidr_block = ["0.0.0.0/0"]
    }
  ]
  # this value will be needed when the https required.
  #  aws-load-balancer-ssl-cert-arn =
}

module "eks_workers" {
  source                    = "./eks-worker"
  name                      = module.eks_cluster.eks_cluster_id
  key_name                  = var.key_name
  image_id                  = var.image_id
  instance_type             = var.instance_type
  vpc_id                    = module.vpc.vpc_id
  subnet_ids                = module.subnets.public_subnet_ids
  health_check_type         = var.health_check_type
  min_size                  = var.min_size
  max_size                  = var.max_size
  wait_for_capacity_timeout = var.wait_for_capacity_timeout

  cluster_name                       = module.eks_cluster.eks_cluster_id
  cluster_endpoint                   = module.eks_cluster.eks_cluster_endpoint
  cluster_certificate_authority_data = module.eks_cluster.eks_cluster_certificate_authority_data

  cluster_security_group_id              = var.cluster_security_group_id
  additional_security_group_ids          = [module.network_loadbalancer.security_group_k8s]
  cluster_security_group_ingress_enabled = var.cluster_security_group_ingress_enabled
  associate_public_ip_address            = true

  # Auto-scaling policies and CloudWatch metric alarms
  autoscaling_policies_enabled           = false //set false for the policy
  cpu_utilization_high_threshold_percent = var.cpu_utilization_high_threshold_percent
  cpu_utilization_low_threshold_percent  = var.cpu_utilization_low_threshold_percent

  target_group_arns = concat(module.network_loadbalancer.target_group_arns)
}

module "eks_cluster" {
  source     = "./eks-cluster"
  name       = var.name
  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.subnets.public_subnet_ids

  kubernetes_version    = var.kubernetes_version
  oidc_provider_enabled = false

  workers_role_arns          = [module.eks_workers.workers_role_arn]
  workers_security_group_ids = [module.eks_workers.security_group_id]
}