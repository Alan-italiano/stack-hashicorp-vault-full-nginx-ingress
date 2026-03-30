# ── Segurança adicional: NetworkPolicies e PodSecurityStandards ───────────────
#
# Este arquivo substitui o AWS WAF (64-edge-waf.tf do stack ALB).
# A estratégia de defesa em profundidade usa múltiplas camadas:
#
#   1. NGINX ModSecurity (OWASP CRS)  — filtragem de payloads maliciosos
#   2. NGINX rate limiting             — proteção contra brute-force e DDoS L7
#   3. NetworkPolicies                 — segmentação de rede no cluster
#   4. NLB source ranges               — restrição de IPs a nível de LB (opcional)
#
# As políticas de rede abaixo seguem o princípio de menor privilégio:
#   - Vault só aceita tráfego do NGINX Ingress e do namespace vault (peers/raft)
#   - Grafana só aceita tráfego do NGINX Ingress
#   - Saída irrestrita (necessária para KMS, S3, OIDC, DB)

# ── NetworkPolicy: Vault namespace ────────────────────────────────────────────

resource "kubernetes_network_policy_v1" "vault_ingress" {
  metadata {
    name      = "vault-allow-ingress-and-peers"
    namespace = kubernetes_namespace.vault.metadata[0].name
  }

  spec {
    pod_selector {
      match_labels = {
        "app.kubernetes.io/name" = "vault"
      }
    }

    policy_types = ["Ingress"]

    # Permite tráfego do NGINX Ingress Controller
    ingress {
      from {
        namespace_selector {
          match_labels = {
            "kubernetes.io/metadata.name" = local.nginx_ingress_namespace
          }
        }
      }
      ports {
        port     = "8200"
        protocol = "TCP"
      }
    }

    # Permite comunicação Raft entre peers Vault (porta 8201)
    ingress {
      from {
        namespace_selector {
          match_labels = {
            "kubernetes.io/metadata.name" = local.vault_namespace
          }
        }
        pod_selector {
          match_labels = {
            "app.kubernetes.io/name" = "vault"
          }
        }
      }
      ports {
        port     = "8200"
        protocol = "TCP"
      }
      ports {
        port     = "8201"
        protocol = "TCP"
      }
    }

    # Permite scrape de métricas pelo Prometheus
    ingress {
      from {
        namespace_selector {
          match_labels = {
            "kubernetes.io/metadata.name" = local.monitoring_namespace
          }
        }
      }
      ports {
        port     = "8200"
        protocol = "TCP"
      }
    }
  }

  depends_on = [kubernetes_namespace.vault]
}

# ── NetworkPolicy: Grafana ─────────────────────────────────────────────────────

resource "kubernetes_network_policy_v1" "grafana_ingress" {
  metadata {
    name      = "grafana-allow-nginx-ingress"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
  }

  spec {
    pod_selector {
      match_labels = {
        "app.kubernetes.io/name" = "grafana"
      }
    }

    policy_types = ["Ingress"]

    # Permite tráfego do NGINX Ingress Controller
    ingress {
      from {
        namespace_selector {
          match_labels = {
            "kubernetes.io/metadata.name" = local.nginx_ingress_namespace
          }
        }
      }
      ports {
        port     = "3000"
        protocol = "TCP"
      }
    }
  }

  depends_on = [kubernetes_namespace.monitoring]
}

# ── NetworkPolicy: NGINX Ingress Controller ───────────────────────────────────
# Permite que o NGINX acesse os backends nos namespaces vault e monitoring.

resource "kubernetes_network_policy_v1" "nginx_egress_to_backends" {
  metadata {
    name      = "nginx-allow-egress-to-backends"
    namespace = local.nginx_ingress_namespace
  }

  spec {
    pod_selector {
      match_labels = {
        "app.kubernetes.io/name"      = "ingress-nginx"
        "app.kubernetes.io/component" = "controller"
      }
    }

    policy_types = ["Egress"]

    # Vault
    egress {
      to {
        namespace_selector {
          match_labels = {
            "kubernetes.io/metadata.name" = local.vault_namespace
          }
        }
      }
      ports {
        port     = "8200"
        protocol = "TCP"
      }
    }

    # Grafana
    egress {
      to {
        namespace_selector {
          match_labels = {
            "kubernetes.io/metadata.name" = local.monitoring_namespace
          }
        }
      }
      ports {
        port     = "3000"
        protocol = "TCP"
      }
    }

    # DNS (CoreDNS)
    egress {
      ports {
        port     = "53"
        protocol = "UDP"
      }
      ports {
        port     = "53"
        protocol = "TCP"
      }
    }
  }

  depends_on = [kubernetes_namespace.nginx_ingress]
}

# ── Labels nos namespaces para NetworkPolicy selector ─────────────────────────
# Os namespaces precisam do label kubernetes.io/metadata.name para que as
# NetworkPolicies com namespaceSelector funcionem corretamente.
# O Kubernetes 1.21+ aplica esse label automaticamente.

resource "kubernetes_labels" "vault_ns_label" {
  api_version = "v1"
  kind        = "Namespace"
  metadata {
    name = local.vault_namespace
  }
  labels = {
    "kubernetes.io/metadata.name" = local.vault_namespace
  }
  depends_on = [kubernetes_namespace.vault]
}

resource "kubernetes_labels" "monitoring_ns_label" {
  api_version = "v1"
  kind        = "Namespace"
  metadata {
    name = local.monitoring_namespace
  }
  labels = {
    "kubernetes.io/metadata.name" = local.monitoring_namespace
  }
  depends_on = [kubernetes_namespace.monitoring]
}

resource "kubernetes_labels" "nginx_ns_label" {
  api_version = "v1"
  kind        = "Namespace"
  metadata {
    name = local.nginx_ingress_namespace
  }
  labels = {
    "kubernetes.io/metadata.name" = local.nginx_ingress_namespace
  }
  depends_on = [kubernetes_namespace.nginx_ingress]
}
