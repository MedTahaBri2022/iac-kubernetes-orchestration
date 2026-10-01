variable "project" {
  description = "Name used as a prefix for every resource."
  type        = string
  default     = "k8s-platform"
}

variable "environment" {
  description = "Deployment environment."
  type        = string
  default     = "dev"

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be dev, staging or prod."
  }
}

variable "region" {
  description = "AWS region."
  type        = string
  default     = "eu-west-3"
}

variable "vpc_cidr" {
  description = "CIDR block of the VPC."
  type        = string
  default     = "10.20.0.0/16"

  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0))
    error_message = "vpc_cidr must be a valid IPv4 CIDR block."
  }
}

variable "public_subnet_cidr" {
  description = "CIDR block of the public subnet hosting the node."
  type        = string
  default     = "10.20.1.0/24"
}

variable "admin_cidr" {
  description = "CIDR allowed to reach SSH (22) and the Kubernetes API (6443). Use your own IP, e.g. 203.0.113.7/32."
  type        = string

  validation {
    condition     = can(cidrhost(var.admin_cidr, 0)) && var.admin_cidr != "0.0.0.0/0"
    error_message = "admin_cidr must be a valid CIDR and must not be open to the whole internet."
  }
}

variable "app_cidr" {
  description = "CIDR allowed to reach the application NodePort."
  type        = string
  default     = "0.0.0.0/0"
}

variable "app_node_port" {
  description = "NodePort on which the application Service is exposed."
  type        = number
  default     = 30080

  validation {
    condition     = var.app_node_port >= 30000 && var.app_node_port <= 32767
    error_message = "app_node_port must be in the Kubernetes NodePort range (30000-32767)."
  }
}

variable "instance_type" {
  description = "EC2 instance type of the Kubernetes node (k3s needs about 1 GB of RAM)."
  type        = string
  default     = "t3.small"
}

variable "root_volume_gb" {
  description = "Size of the node's root volume."
  type        = number
  default     = 20
}

variable "ssh_public_key" {
  description = "Public key installed on the node. Leave null to create the node without SSH access."
  type        = string
  default     = null
}

variable "ami_id" {
  description = "AMI of the node. Leave null to use the latest Ubuntu 24.04 LTS image."
  type        = string
  default     = null
}

variable "k3s_version" {
  description = "k3s release installed on the node."
  type        = string
  default     = "v1.31.5+k3s1"
}

variable "emulator_endpoint" {
  description = "URL of a local AWS emulator (LocalStack, moto). Leave null to target real AWS."
  type        = string
  default     = null
}
