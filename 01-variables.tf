variable "region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "environment" {
  description = "Environment name"
  type        = string
  default     = "lab"
}

variable "cluster_name" {
  description = "EKS cluster name"
  type        = string
  default     = "vault-eks-lab"
}

variable "kubernetes_version" {
  description = "EKS Kubernetes version"
  type        = string
  default     = "1.30"
}

variable "cluster_service_ipv4_cidr" {
  description = "CIDR used by Kubernetes Services in the EKS cluster"
  type        = string
  default     = "172.20.0.0/16"
}

variable "vault_hostname" {
  description = "Vault FQDN"
  type        = string
  default     = "vault.lab-internal.com.br"
}

variable "vault_image_tag" {
  description = "Vault container image tag"
  type        = string
  default     = "1.21.4"
}

variable "domain_name" {
  description = "Primary DNS zone domain name"
  type        = string
  default     = "lab-internal.com.br"
}

variable "route53_zone_id" {
  description = "Route53 hosted zone ID"
  type        = string
  default     = "Z085094335FXPD3PXEQRT"
}

variable "letsencrypt_email" {
  description = "Email address for Let's Encrypt ACME account registration and expiry notices"
  type        = string
  default     = "admin@lab-internal.com.br"
}

variable "nginx_ingress_replica_count" {
  description = "Number of NGINX Ingress Controller replicas (minimum for HA)"
  type        = number
  default     = 3
}

variable "nginx_rate_limit_rps" {
  description = "Per-ingress rate limit in requests per second per source IP (applied to Vault and Grafana ingresses)"
  type        = number
  default     = 20
}

variable "nginx_rate_limit_connections" {
  description = "Maximum simultaneous connections per source IP per ingress"
  type        = number
  default     = 20
}

variable "nginx_scheme" {
  description = "Scheme for the NGINX Ingress NLB (internet-facing or internal)"
  type        = string
  default     = "internet-facing"
}

variable "vault_allowed_cidrs" {
  description = "Source CIDRs allowed to reach Vault via the NLB. Leave empty to keep Vault publicly reachable."
  type        = list(string)
  default     = []
}

variable "vault_snapshot_bucket_name" {
  description = "Bucket used by Vault snapshots"
  type        = string
  default     = "vault-lab-snapshots-unique"
}

variable "vault_snapshot_bucket_admin_principal_arns" {
  description = "Additional IAM principal ARNs allowed to administer and read the Vault snapshots bucket"
  type        = list(string)
  default     = []
}

variable "vpc_cidr" {
  description = "VPC CIDR"
  type        = string
  default     = "10.42.0.0/16"
}

variable "private_subnets" {
  description = "Private subnet CIDRs"
  type        = list(string)
  default     = ["10.42.1.0/24", "10.42.2.0/24", "10.42.3.0/24"]
}

variable "public_subnets" {
  description = "Public subnet CIDRs"
  type        = list(string)
  default     = ["10.42.101.0/24", "10.42.102.0/24", "10.42.103.0/24"]
}

variable "node_instance_type" {
  description = "EKS node instance type"
  type        = string
  default     = "t3.large"
}

variable "vault_storage_class_name" {
  description = "StorageClass used by Vault data PVCs"
  type        = string
  default     = "ebs-gp3"
}

variable "grafana_hostname" {
  description = "Grafana FQDN"
  type        = string
  default     = "grafana.lab-internal.com.br"
}

variable "postgres_database_name" {
  description = "PostgreSQL database name"
  type        = string
}

variable "postgres_admin_username" {
  description = "PostgreSQL admin username"
  type        = string
}

variable "postgres_admin_password" {
  description = "PostgreSQL admin password"
  type        = string
  sensitive   = true
}

variable "vault_oidc_discovery_url" {
  description = "OIDC discovery URL used by Vault"
  type        = string
  default     = null
}

variable "vault_oidc_client_id" {
  description = "OIDC client ID used by Vault"
  type        = string
  default     = null
}

variable "vault_oidc_client_secret" {
  description = "OIDC client secret used by Vault"
  type        = string
  sensitive   = true
  default     = null
}

variable "vault_oidc_bound_email" {
  description = "Email claim allowed to authenticate in the Vault OIDC admin role"
  type        = string
  default     = null
}

variable "vault_oidc_role_name" {
  description = "Vault role name created for OIDC authentication"
  type        = string
  default     = "auth0-admin"
}

variable "vault_bootstrap_enabled" {
  description = "Executa o bootstrap do Vault via null_resource local-exec. Desabilite em CI (false) e execute o bootstrap como step separado no workflow."
  type        = bool
  default     = true
}
