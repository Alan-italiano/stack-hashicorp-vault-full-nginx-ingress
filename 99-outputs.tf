output "eks_cluster_name" {
  value       = module.eks.cluster_name
  description = "EKS cluster name"
}

output "eks_cluster_endpoint" {
  value       = module.eks.cluster_endpoint
  description = "EKS API endpoint"
}

output "eks_cluster_certificate_authority_data" {
  value       = module.eks.cluster_certificate_authority_data
  description = "Base64-encoded CA certificate for the EKS cluster API"
}

output "vault_kms_key_arn" {
  value       = aws_kms_key.vault_unseal.arn
  description = "KMS key ARN used by Vault auto-unseal"
}

output "vault_irsa_role_arn" {
  value       = module.irsa_vault.iam_role_arn
  description = "IAM role used only by Vault service account"
}

output "vault_snapshot_bucket" {
  value       = aws_s3_bucket.vault_snapshots.id
  description = "S3 bucket for Vault snapshots"
}

output "vault_url" {
  value       = "https://${var.vault_hostname}"
  description = "Vault public URL exposed through NGINX Ingress / NLB"
}

output "vault_status_command" {
  value       = "kubectl exec -n vault vault-0 -- sh -lc 'VAULT_ADDR=https://vault-0.vault-internal.vault.svc.cluster.local:8200 VAULT_CACERT=/vault/userconfig/ca/ca.crt vault status'"
  description = "Command to check Vault status from the active pod"
}

output "vault_raft_peers_command" {
  value       = "ROOT_TOKEN=$(jq -r .root_token bootstrap/vault-init.json) && kubectl exec -n vault vault-0 -- sh -lc \"VAULT_ADDR=https://vault-0.vault-internal.vault.svc.cluster.local:8200 VAULT_CACERT=/vault/userconfig/ca/ca.crt VAULT_TOKEN=$ROOT_TOKEN vault operator raft list-peers\""
  description = "Command to list Vault raft peers using the persisted bootstrap root token"
}

output "grafana_url" {
  value       = "https://${var.grafana_hostname}"
  description = "Grafana public URL exposed through NGINX Ingress / NLB"
}

output "grafana_admin_username" {
  value       = "admin"
  description = "Default Grafana admin username"
}

output "grafana_admin_password_command" {
  value       = "kubectl -n monitoring get secret kube-prometheus-stack-grafana -o jsonpath=\"{.data.admin-password}\" | base64 -d; echo"
  description = "Command to retrieve the default Grafana admin password"
}

output "nginx_ingress_nlb_hostname_command" {
  value       = "kubectl -n ingress-nginx get svc ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'"
  description = "Command to retrieve the NLB hostname provisioned for the NGINX Ingress Controller"
}

output "nginx_cert_manager_irsa_role_arn" {
  value       = module.irsa_cert_manager.iam_role_arn
  description = "IAM role ARN used by cert-manager for Route53 DNS-01 challenge"
}

output "route53_zone_id" {
  value       = var.route53_zone_id
  description = "Route53 hosted zone ID used by cert-manager DNS-01 and external-dns"
}

output "postgres_internal_host" {
  value       = "postgres-service.${local.postgres_namespace}.svc.cluster.local"
  description = "PostgreSQL internal DNS name inside the cluster"
}

output "postgres_internal_port" {
  value       = 5432
  description = "PostgreSQL internal port"
}

output "postgres_portforward_command" {
  value       = "kubectl port-forward -n ${local.postgres_namespace} svc/postgres-service 5432:5432"
  description = "Command to access PostgreSQL locally via kubectl port-forward (no external LB)"
}

# ── Outputs usados pelo step de bootstrap no GitHub Actions ───────────────────

output "vault_namespace" {
  value       = local.vault_namespace
  description = "Kubernetes namespace onde o Vault está instalado"
}

output "vault_service_account" {
  value       = local.vault_service_account
  description = "Service account do Vault no Kubernetes"
}

output "vault_hostname" {
  value       = var.vault_hostname
  description = "Hostname do Vault (sem https://)"
}

output "postgres_database_name" {
  value       = var.postgres_database_name
  description = "Nome do banco de dados PostgreSQL"
}

output "postgres_admin_username" {
  value       = var.postgres_admin_username
  description = "Usuário administrador do PostgreSQL"
}

output "vault_oidc_discovery_url" {
  value       = coalesce(var.vault_oidc_discovery_url, "")
  description = "OIDC discovery URL configurada no Vault"
}

output "vault_oidc_client_id" {
  value       = coalesce(var.vault_oidc_client_id, "")
  description = "OIDC client ID configurado no Vault"
}

output "vault_oidc_bound_email" {
  value       = coalesce(var.vault_oidc_bound_email, "")
  description = "Email vinculado ao role OIDC de administrador"
}

output "vault_oidc_role_name" {
  value       = var.vault_oidc_role_name
  description = "Nome do role OIDC criado no Vault"
}
