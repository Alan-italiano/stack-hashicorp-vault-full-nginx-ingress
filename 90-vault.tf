resource "kubernetes_namespace" "vault" {
  metadata {
    name = local.vault_namespace
  }

  depends_on = [time_sleep.eks_access_ready]
}

resource "kubernetes_role_v1" "vault_discovery" {
  metadata {
    name      = "vault-discovery"
    namespace = kubernetes_namespace.vault.metadata[0].name
  }

  rule {
    api_groups = [""]
    resources  = ["pods", "services", "endpoints"]
    verbs      = ["get", "list", "watch"]
  }

  rule {
    api_groups = ["discovery.k8s.io"]
    resources  = ["endpointslices"]
    verbs      = ["get", "list", "watch"]
  }
}

resource "kubernetes_role_binding_v1" "vault_discovery" {
  metadata {
    name      = "vault-discovery"
    namespace = kubernetes_namespace.vault.metadata[0].name
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role_v1.vault_discovery.metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = local.vault_service_account
    namespace = kubernetes_namespace.vault.metadata[0].name
  }
}

resource "helm_release" "vault" {
  name             = "vault"
  repository       = "https://helm.releases.hashicorp.com"
  chart            = "vault"
  version          = "0.32.0"
  namespace        = kubernetes_namespace.vault.metadata[0].name
  create_namespace = false
  wait             = false

  values = [
    yamlencode({
      global = {
        tlsDisable = false
      }
      injector = {
        enabled = false
      }
      server = {
        image = {
          repository = "hashicorp/vault"
          tag        = var.vault_image_tag
        }
        readinessProbe = {
          enabled = true
          path    = "/v1/sys/health?standbyok=true&sealedcode=204&uninitcode=204"
          port    = 8200
        }
        dataStorage = {
          enabled      = true
          storageClass = var.vault_storage_class_name
          accessMode   = "ReadWriteOnce"
          size         = "10Gi"
        }
        serviceAccount = {
          create = true
          name   = local.vault_service_account
          annotations = {
            "eks.amazonaws.com/role-arn" = module.irsa_vault.iam_role_arn
          }
        }
        volumes = [
          {
            name = "tls"
            secret = {
              secretName = "vault-server-tls"
            }
          },
          {
            name = "vault-ca"
            secret = {
              secretName = kubernetes_secret_v1.vault_internal_ca.metadata[0].name
            }
          }
        ]
        volumeMounts = [
          {
            name      = "tls"
            mountPath = "/vault/userconfig/tls"
            readOnly  = true
          },
          {
            name      = "vault-ca"
            mountPath = "/vault/userconfig/ca"
            readOnly  = true
          }
        ]
        ha = {
          enabled  = true
          replicas = 3
          raft = {
            enabled = true
            config  = <<-EOT
              ui = true

              listener "tcp" {
                address            = "[::]:8200"
                cluster_address    = "[::]:8201"
                tls_disable        = 0
                tls_cert_file      = "/vault/userconfig/tls/tls.crt"
                tls_key_file       = "/vault/userconfig/tls/tls.key"
                tls_client_ca_file = "/vault/userconfig/ca/ca.crt"

                telemetry {
                  unauthenticated_metrics_access = "true"
                }
              }

              storage "raft" {
                path = "/vault/data"

                retry_join {
                  leader_api_addr         = "https://vault-0.vault-internal.${local.vault_namespace}.svc.cluster.local:8200"
                  leader_ca_cert_file     = "/vault/userconfig/ca/ca.crt"
                  leader_client_cert_file = "/vault/userconfig/tls/tls.crt"
                  leader_client_key_file  = "/vault/userconfig/tls/tls.key"
                  leader_tls_servername   = "vault-0.vault-internal.${local.vault_namespace}.svc.cluster.local"
                }

                retry_join {
                  leader_api_addr         = "https://vault-1.vault-internal.${local.vault_namespace}.svc.cluster.local:8200"
                  leader_ca_cert_file     = "/vault/userconfig/ca/ca.crt"
                  leader_client_cert_file = "/vault/userconfig/tls/tls.crt"
                  leader_client_key_file  = "/vault/userconfig/tls/tls.key"
                  leader_tls_servername   = "vault-1.vault-internal.${local.vault_namespace}.svc.cluster.local"
                }

                retry_join {
                  leader_api_addr         = "https://vault-2.vault-internal.${local.vault_namespace}.svc.cluster.local:8200"
                  leader_ca_cert_file     = "/vault/userconfig/ca/ca.crt"
                  leader_client_cert_file = "/vault/userconfig/tls/tls.crt"
                  leader_client_key_file  = "/vault/userconfig/tls/tls.key"
                  leader_tls_servername   = "vault-2.vault-internal.${local.vault_namespace}.svc.cluster.local"
                }
              }

              seal "awskms" {
                region     = "${var.region}"
                kms_key_id = "${aws_kms_key.vault_unseal.arn}"
              }

              service_registration "kubernetes" {}

              telemetry {
                disable_hostname = true
              }
            EOT
          }
        }
      }
      serverTelemetry = {
        prometheusOperator = true
        serviceMonitor = {
          enabled = true
        }
      }
      ui = {
        enabled = true
      }
    })
  ]

  depends_on = [
    helm_release.cert_manager,
    kubectl_manifest.vault_server_certificate,
    helm_release.kube_prometheus_stack,
    kubernetes_storage_class_v1.vault_ebs_gp3,
    aws_kms_key_policy.vault_unseal,
    aws_s3_bucket_policy.vault_snapshots,
    kubernetes_role_binding_v1.vault_discovery
  ]
}
