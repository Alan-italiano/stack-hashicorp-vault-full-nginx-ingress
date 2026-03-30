# ── Ingress: Vault ────────────────────────────────────────────────────────────
# NGINX termina TLS público (cert-manager / Let's Encrypt) e re-encripta
# para o backend Vault (HTTPS interno com CA própria).

resource "kubernetes_ingress_v1" "vault" {
  metadata {
    name      = "vault-nginx"
    namespace = kubernetes_namespace.vault.metadata[0].name
    annotations = {
      # IngressClass
      "kubernetes.io/ingress.class" = "nginx"

      # TLS terminado no NGINX → backend Vault em HTTPS (re-encrypt)
      "nginx.ingress.kubernetes.io/backend-protocol" = "HTTPS"

      # CA interna do Vault não é pública — desabilita verificação do proxy
      "nginx.ingress.kubernetes.io/proxy-ssl-verify" = "off"

      # Força redirect HTTP → HTTPS
      "nginx.ingress.kubernetes.io/ssl-redirect"       = "true"
      "nginx.ingress.kubernetes.io/force-ssl-redirect" = "true"

      # Rate limiting por IP de origem
      "nginx.ingress.kubernetes.io/limit-rps"         = tostring(var.nginx_rate_limit_rps)
      "nginx.ingress.kubernetes.io/limit-connections" = tostring(var.nginx_rate_limit_connections)

      # Healthcheck (Vault retorna 200/204/429 quando healthy/standby)
      "nginx.ingress.kubernetes.io/healthcheck-path" = "/v1/sys/health?standbyok=true&sealedcode=204&uninitcode=204"

      # Timeouts agressivos para API de secrets
      "nginx.ingress.kubernetes.io/proxy-read-timeout" = "60"
      "nginx.ingress.kubernetes.io/proxy-body-size"    = "10m"

      # Cabeçalhos de segurança adicionais por ingress
      "nginx.ingress.kubernetes.io/configuration-snippet" = <<-SNIPPET
        more_set_headers "X-Frame-Options: DENY";
        more_set_headers "X-Content-Type-Options: nosniff";
        more_set_headers "X-XSS-Protection: 0";
        more_set_headers "Referrer-Policy: strict-origin-when-cross-origin";
        more_set_headers "Permissions-Policy: geolocation=(), microphone=(), camera=()";
        more_set_headers "Content-Security-Policy: default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; img-src 'self' data:;";
      SNIPPET

      # cert-manager emite certificado público via Let's Encrypt DNS-01
      "cert-manager.io/cluster-issuer" = "letsencrypt-prod"

      # External DNS atualiza o registro A/CNAME no Route53
      "external-dns.alpha.kubernetes.io/hostname" = var.vault_hostname
    }
  }

  spec {
    ingress_class_name = "nginx"

    tls {
      hosts       = [var.vault_hostname]
      secret_name = "vault-tls-public"
    }

    rule {
      host = var.vault_hostname

      http {
        path {
          path      = "/"
          path_type = "Prefix"

          backend {
            service {
              name = "vault-active"
              port {
                number = 8200
              }
            }
          }
        }
      }
    }
  }

  timeouts {
    delete = "10m"
  }

  depends_on = [
    helm_release.nginx_ingress,
    helm_release.cert_manager,
    kubectl_manifest.letsencrypt_prod_issuer,
    helm_release.external_dns,
    helm_release.vault,
  ]
}

# ── Ingress: Grafana ──────────────────────────────────────────────────────────

resource "kubernetes_ingress_v1" "grafana" {
  metadata {
    name      = "grafana-nginx"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
    annotations = {
      "kubernetes.io/ingress.class" = "nginx"

      # Grafana serve HTTP internamente
      "nginx.ingress.kubernetes.io/backend-protocol" = "HTTP"

      "nginx.ingress.kubernetes.io/ssl-redirect"       = "true"
      "nginx.ingress.kubernetes.io/force-ssl-redirect" = "true"

      # Rate limiting por IP de origem
      "nginx.ingress.kubernetes.io/limit-rps"        = tostring(var.nginx_rate_limit_rps)
      "nginx.ingress.kubernetes.io/limit-connections" = tostring(var.nginx_rate_limit_connections)

      # Segurança extra para o dashboard de monitoramento
      "nginx.ingress.kubernetes.io/configuration-snippet" = <<-SNIPPET
        more_set_headers "X-Frame-Options: SAMEORIGIN";
        more_set_headers "X-Content-Type-Options: nosniff";
        more_set_headers "X-XSS-Protection: 0";
        more_set_headers "Referrer-Policy: strict-origin-when-cross-origin";
      SNIPPET

      "cert-manager.io/cluster-issuer"                   = "letsencrypt-prod"
      "external-dns.alpha.kubernetes.io/hostname"        = var.grafana_hostname
    }
  }

  spec {
    ingress_class_name = "nginx"

    tls {
      hosts       = [var.grafana_hostname]
      secret_name = "grafana-tls-public"
    }

    rule {
      host = var.grafana_hostname

      http {
        path {
          path      = "/"
          path_type = "Prefix"

          backend {
            service {
              name = "kube-prometheus-stack-grafana"
              port {
                number = 80
              }
            }
          }
        }
      }
    }
  }

  timeouts {
    delete = "10m"
  }

  depends_on = [
    helm_release.nginx_ingress,
    helm_release.cert_manager,
    kubectl_manifest.letsencrypt_prod_issuer,
    helm_release.external_dns,
    helm_release.kube_prometheus_stack,
  ]
}
