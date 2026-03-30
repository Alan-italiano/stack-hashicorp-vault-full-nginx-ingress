resource "kubernetes_namespace" "cert_manager" {
  depends_on = [time_sleep.eks_access_ready]

  metadata {
    name = local.cert_manager_namespace
  }
}

resource "helm_release" "cert_manager" {
  name             = "cert-manager"
  repository       = "https://charts.jetstack.io"
  chart            = "cert-manager"
  version          = "v1.20.0"
  namespace        = kubernetes_namespace.cert_manager.metadata[0].name
  create_namespace = false
  wait             = true
  timeout          = 600

  values = [
    yamlencode({
      crds = {
        enabled = true
      }
      serviceAccount = {
        create = true
        name   = local.cert_manager_service_account
        annotations = {
          "eks.amazonaws.com/role-arn" = module.irsa_cert_manager.iam_role_arn
        }
      }
      # Garante que o pod do cert-manager herda as credenciais IRSA para DNS-01
      podLabels = {
        "app.kubernetes.io/component" = "controller"
      }
      prometheus = {
        enabled = true
        servicemonitor = {
          enabled = true
        }
      }
    })
  ]

  depends_on = [
    module.irsa_cert_manager,
    time_sleep.eks_access_ready,
  ]
}

# ── Issuer interno para TLS Vault peer-to-peer (mutual TLS via CA própria) ────

resource "kubectl_manifest" "vault_internal_ca_issuer" {
  yaml_body = yamlencode({
    apiVersion = "cert-manager.io/v1"
    kind       = "Issuer"
    metadata = {
      name      = "vault-internal-ca"
      namespace = local.vault_namespace
    }
    spec = {
      ca = {
        secretName = kubernetes_secret_v1.vault_internal_ca.metadata[0].name
      }
    }
  })

  depends_on = [
    helm_release.cert_manager,
    kubernetes_namespace.vault,
    kubernetes_secret_v1.vault_internal_ca,
  ]
}

resource "kubectl_manifest" "vault_server_certificate" {
  yaml_body = yamlencode({
    apiVersion = "cert-manager.io/v1"
    kind       = "Certificate"
    metadata = {
      name      = "vault-server-tls"
      namespace = local.vault_namespace
    }
    spec = {
      secretName  = "vault-server-tls"
      duration    = "2160h"
      renewBefore = "360h"
      issuerRef = {
        name = "vault-internal-ca"
        kind = "Issuer"
      }
      commonName = var.vault_hostname
      dnsNames = [
        var.vault_hostname,
        "vault",
        "vault.${local.vault_namespace}",
        "vault.${local.vault_namespace}.svc",
        "vault.${local.vault_namespace}.svc.cluster.local",
        "vault-active.${local.vault_namespace}.svc",
        "vault-active.${local.vault_namespace}.svc.cluster.local",
        "vault-internal.${local.vault_namespace}.svc",
        "vault-internal.${local.vault_namespace}.svc.cluster.local",
        "*.vault-internal.${local.vault_namespace}.svc.cluster.local",
        "localhost",
      ]
      ipAddresses = [
        "127.0.0.1",
      ]
      usages = [
        "server auth",
        "client auth",
        "digital signature",
        "key encipherment",
      ]
    }
  })

  depends_on = [
    kubectl_manifest.vault_internal_ca_issuer,
  ]
}

# ── ClusterIssuer Let's Encrypt (produção) ─────────────────────────────────────
# Usa challenge DNS-01 via Route53 para emitir certificados públicos
# sem precisar de acesso HTTP inbound durante a validação.

resource "kubectl_manifest" "letsencrypt_prod_issuer" {
  yaml_body = yamlencode({
    apiVersion = "cert-manager.io/v1"
    kind       = "ClusterIssuer"
    metadata = {
      name = "letsencrypt-prod"
    }
    spec = {
      acme = {
        server = "https://acme-v02.api.letsencrypt.org/directory"
        email  = var.letsencrypt_email
        privateKeySecretRef = {
          name = "letsencrypt-prod-account-key"
        }
        solvers = [
          {
            dns01 = {
              route53 = {
                region      = var.region
                hostedZoneID = var.route53_zone_id
              }
            }
          }
        ]
      }
    }
  })

  depends_on = [
    helm_release.cert_manager,
    module.irsa_cert_manager,
  ]
}

# ── ClusterIssuer Let's Encrypt (staging — para testes sem rate limit) ─────────

resource "kubectl_manifest" "letsencrypt_staging_issuer" {
  yaml_body = yamlencode({
    apiVersion = "cert-manager.io/v1"
    kind       = "ClusterIssuer"
    metadata = {
      name = "letsencrypt-staging"
    }
    spec = {
      acme = {
        server = "https://acme-staging-v02.api.letsencrypt.org/directory"
        email  = var.letsencrypt_email
        privateKeySecretRef = {
          name = "letsencrypt-staging-account-key"
        }
        solvers = [
          {
            dns01 = {
              route53 = {
                region       = var.region
                hostedZoneID = var.route53_zone_id
              }
            }
          }
        ]
      }
    }
  })

  depends_on = [
    helm_release.cert_manager,
    module.irsa_cert_manager,
  ]
}
