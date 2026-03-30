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

  # Snippet ModSecurity — definido como local para evitar heredoc dentro de ternário (inválido em HCL)
  nginx_modsecurity_snippet = var.nginx_enable_modsecurity ? <<-MODSEC
    SecRuleEngine On
    SecRequestBodyAccess On
    SecResponseBodyAccess Off
    SecRequestBodyLimit 13107200
    SecRequestBodyNoFilesLimit 131072
    SecPcreMatchLimit 100000
    SecPcreMatchLimitRecursion 100000
    # Evita falsos positivos do Vault API (body JSON grande)
    SecRule REQUEST_URI "@beginsWith /v1/" "id:9001,phase:1,pass,nolog,ctl:requestBodyAccess=On"
  MODSEC
  : ""
}
