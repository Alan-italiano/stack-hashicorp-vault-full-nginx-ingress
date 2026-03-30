resource "kubernetes_cluster_role_binding_v1" "vault_auth_delegator" {
  metadata {
    name = "${var.cluster_name}-vault-auth-delegator"
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = "system:auth-delegator"
  }

  subject {
    kind      = "ServiceAccount"
    name      = local.vault_service_account
    namespace = kubernetes_namespace.vault.metadata[0].name
  }
}

resource "null_resource" "vault_bootstrap" {
  count = var.vault_bootstrap_enabled ? 1 : 0

  triggers = {
    always_run               = timestamp()
    script_hash              = filesha1("${path.module}/scripts/bootstrap_vault.py")
    postgres_host            = "postgres-service.${local.postgres_namespace}.svc.cluster.local"
    postgres_port            = "5432"
    postgres_database_name   = var.postgres_database_name
    postgres_admin_username  = var.postgres_admin_username
    postgres_admin_password  = sha1(var.postgres_admin_password)
    vault_ca_cert_hash       = sha1(tls_self_signed_cert.vault_internal_ca.cert_pem)
    vault_db_connection_name = "postgres"
    vault_db_role_name       = "postgres-dynamic"
    vault_oidc_discovery_url = coalesce(var.vault_oidc_discovery_url, "")
    vault_oidc_client_id     = coalesce(var.vault_oidc_client_id, "")
    vault_oidc_client_secret = sha1(coalesce(var.vault_oidc_client_secret, ""))
    vault_oidc_bound_email   = coalesce(var.vault_oidc_bound_email, "")
    vault_oidc_role_name     = var.vault_oidc_role_name
    vault_hostname           = var.vault_hostname
  }

  provisioner "local-exec" {
    command = <<-EOT
      python3 "${path.module}/scripts/bootstrap_vault.py" \
        --namespace "${local.vault_namespace}" \
        --service-account "${local.vault_service_account}" \
        --cluster-name "${module.eks.cluster_name}" \
        --region "${var.region}" \
        --kubernetes-host "${module.eks.cluster_endpoint}" \
        --kubernetes-ca-b64 "${module.eks.cluster_certificate_authority_data}" \
        --vault-ca-cert-b64 "${base64encode(tls_self_signed_cert.vault_internal_ca.cert_pem)}" \
        --output-file "${path.module}/bootstrap/vault-init.json" \
        --postgres-host "postgres-service.${local.postgres_namespace}.svc.cluster.local" \
        --postgres-port "5432" \
        --postgres-database-name "${var.postgres_database_name}" \
        --postgres-admin-username "${var.postgres_admin_username}" \
        --postgres-admin-password "${var.postgres_admin_password}" \
        --vault-db-connection-name "postgres" \
        --vault-db-role-name "postgres-dynamic" \
        --vault-hostname "${var.vault_hostname}" \
        --oidc-discovery-url "${coalesce(var.vault_oidc_discovery_url, "")}" \
        --oidc-client-id "${coalesce(var.vault_oidc_client_id, "")}" \
        --oidc-client-secret "${coalesce(var.vault_oidc_client_secret, "")}" \
        --oidc-bound-email "${coalesce(var.vault_oidc_bound_email, "")}" \
        --oidc-role-name "${var.vault_oidc_role_name}"
    EOT
  }

  depends_on = [
    module.eks,
    module.irsa_vault,
    helm_release.cert_manager,
    kubectl_manifest.vault_server_certificate,
    kubernetes_namespace.vault,
    kubernetes_role_binding_v1.vault_discovery,
    kubernetes_cluster_role_binding_v1.vault_auth_delegator,
    kubernetes_storage_class_v1.vault_ebs_gp3,
    aws_kms_key_policy.vault_unseal,
    aws_s3_bucket_policy.vault_snapshots,
    helm_release.kube_prometheus_stack,
    helm_release.vault,
    kubernetes_stateful_set_v1.postgres,
    kubernetes_service_v1.postgres
  ]
}
