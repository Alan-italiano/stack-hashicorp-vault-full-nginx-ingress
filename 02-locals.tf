locals {
  tags = {
    Project     = "vault-eks"
    Environment = var.environment
    ManagedBy   = "OpenTofu"
  }

  vault_allowed_cidrs = distinct(var.vault_allowed_cidrs)

  vault_namespace              = "vault"
  vault_service_account        = "vault"
  monitoring_namespace         = "monitoring"
  postgres_namespace           = "postgres"
  cert_manager_namespace       = "cert-manager"
  cert_manager_service_account = "cert-manager"
  external_dns_namespace       = "external-dns"
  external_dns_service_account = "external-dns"
  nginx_ingress_namespace      = "ingress-nginx"
}
