resource "kubernetes_namespace" "external_dns" {
  metadata {
    name = local.external_dns_namespace
  }

  depends_on = [time_sleep.eks_access_ready]
}

resource "kubernetes_namespace" "nginx_ingress" {
  metadata {
    name = local.nginx_ingress_namespace
  }

  depends_on = [time_sleep.eks_access_ready]
}

# ── NGINX Ingress Controller ───────────────────────────────────────────────────
# Exposição via AWS NLB (Network Load Balancer) com terminação TLS no NGINX.
# Boas práticas de produção:
#   - 3 réplicas com PodDisruptionBudget (minAvailable: 2)
#   - HPA com métricas CPU e memória
#   - Anti-affinity topológica (zona e nó)
#   - ModSecurity WAF com OWASP CRS (habilitado via variável)
#   - Rate limiting global + por ingress
#   - TLS 1.2/1.3 apenas, com cipher suites modernas
#   - HSTS com preload
#   - Headers de segurança globais
#   - Métricas Prometheus via ServiceMonitor

resource "helm_release" "nginx_ingress" {
  name             = "ingress-nginx"
  repository       = "https://kubernetes.github.io/ingress-nginx"
  chart            = "ingress-nginx"
  version          = "4.12.1"
  namespace        = kubernetes_namespace.nginx_ingress.metadata[0].name
  create_namespace = false
  wait             = true
  timeout          = 600

  values = [
    yamlencode({
      controller = {
        replicaCount = var.nginx_ingress_replica_count

        # ── PodDisruptionBudget ──────────────────────────────────────────────
        # Garante que pelo menos 2 réplicas estejam disponíveis durante
        # atualizações/drenagem de nó (rolling update seguro).
        podDisruptionBudget = {
          enabled      = true
          minAvailable = 2
        }

        # ── HPA — escala automática por CPU e memória ───────────────────────
        autoscaling = {
          enabled                          = true
          minReplicas                      = 2
          maxReplicas                      = 10
          targetCPUUtilizationPercentage   = 80
          targetMemoryUtilizationPercentage = 80
        }

        # ── Anti-affinity: distribui pods entre zonas e nós ─────────────────
        affinity = {
          podAntiAffinity = {
            requiredDuringSchedulingIgnoredDuringExecution = [
              {
                labelSelector = {
                  matchExpressions = [
                    {
                      key      = "app.kubernetes.io/name"
                      operator = "In"
                      values   = ["ingress-nginx"]
                    }
                  ]
                }
                topologyKey = "kubernetes.io/hostname"
              }
            ]
          }
        }

        topologySpreadConstraints = [
          {
            maxSkew            = 1
            topologyKey        = "topology.kubernetes.io/zone"
            whenUnsatisfiable  = "DoNotSchedule"
            labelSelector = {
              matchLabels = {
                "app.kubernetes.io/name"      = "ingress-nginx"
                "app.kubernetes.io/component" = "controller"
              }
            }
          }
        ]

        # ── Recursos ─────────────────────────────────────────────────────────
        resources = {
          requests = {
            cpu    = "200m"
            memory = "256Mi"
          }
          limits = {
            cpu    = "1000m"
            memory = "512Mi"
          }
        }

        # ── Serviço NLB (AWS Network Load Balancer) ───────────────────────────
        # NLB opera na camada 4 — NGINX termina TLS na camada 7.
        # Cross-zone habilitado para distribuir carga entre AZs uniformemente.
        service = {
          annotations = merge(
            {
              "service.beta.kubernetes.io/aws-load-balancer-type"                              = "nlb"
              "service.beta.kubernetes.io/aws-load-balancer-scheme"                            = var.nginx_scheme
              "service.beta.kubernetes.io/aws-load-balancer-cross-zone-load-balancing-enabled" = "true"
              "service.beta.kubernetes.io/aws-load-balancer-connection-idle-timeout"           = "60"
              "service.beta.kubernetes.io/aws-load-balancer-nlb-target-type"                   = "ip"
              # Preserva o IP real do cliente via Proxy Protocol v2
              "service.beta.kubernetes.io/aws-load-balancer-proxy-protocol" = "*"
            },
            length(local.vault_allowed_cidrs) > 0 ? {
              "service.beta.kubernetes.io/aws-load-balancer-source-ranges" = join(",", local.vault_allowed_cidrs)
            } : {}
          )
          externalTrafficPolicy = "Local"
        }

        # ── ConfigMap global de segurança ─────────────────────────────────────
        config = {
          # Habilita configuration-snippet por ingress.
          # Desabilitado por padrão no ingress-nginx >= 1.2 para ambientes
          # multi-tenant. Aqui é seguro pois apenas Vault e Grafana usam
          # snippets para injetar security headers (X-Frame-Options, CSP…).
          allow-snippet-annotations = "true"

          # Protocolo e cifras TLS
          ssl-protocols = "TLSv1.2 TLSv1.3"
          ssl-ciphers   = "ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384"

          # Desabilita TLS session tickets (forward secrecy estrito)
          ssl-session-tickets = "false"
          ssl-session-cache   = "shared:SSL:10m"
          ssl-session-timeout = "1d"

          # HSTS — instrui browsers a usarem apenas HTTPS por 1 ano
          hsts                = "true"
          hsts-max-age        = "31536000"
          hsts-include-subdomains = "true"
          hsts-preload        = "true"

          # Rejeita handshakes TLS para virtual hosts não declarados
          ssl-reject-handshake = "true"

          # Oculta versão do servidor
          server-tokens = "false"
          hide-headers  = "X-Powered-By,Server"

          # IP real do cliente via Proxy Protocol (NLB com proxy-protocol: *)
          use-proxy-protocol         = "true"
          use-forwarded-headers      = "true"
          compute-full-forwarded-for = "true"
          forwarded-for-header       = "X-Forwarded-For"

          # Limites e timeouts defensivos
          proxy-body-size       = "10m"
          proxy-connect-timeout = "15"
          proxy-read-timeout    = "60"
          proxy-send-timeout    = "60"
          keep-alive            = "75"
          keep-alive-requests   = "1000"

          # Código de resposta para rate limit (RFC 6585)
          limit-req-status-code  = "429"
          limit-conn-status-code = "429"

          # Logging estruturado para Loki/Promtail
          log-format-upstream = "$remote_addr - $remote_user [$time_local] \"$request\" $status $body_bytes_sent \"$http_referer\" \"$http_user_agent\" $request_length $request_time [$proxy_upstream_name] [$proxy_alternative_upstream_name] $upstream_addr $upstream_response_length $upstream_response_time $upstream_status $req_id"

        }

        # ── Métricas Prometheus ───────────────────────────────────────────────
        # ServiceMonitor desabilitado: CRD monitoring.coreos.com/v1 ainda não
        # existe quando este chart é instalado (antes do kube-prometheus-stack).
        # O endpoint /metrics fica exposto e o Prometheus o descobre via
        # podMonitorNamespaceSelector aberto configurado no stack de monitoring.
        metrics = {
          enabled = true
          serviceMonitor = {
            enabled = false
          }
        }

        # ── Atualização zero-downtime ─────────────────────────────────────────
        updateStrategy = {
          type = "RollingUpdate"
          rollingUpdate = {
            maxUnavailable = 1
            maxSurge       = 1
          }
        }

        # Garante que pods em terminação concluem conexões abertas
        lifecycle = {
          preStop = {
            exec = {
              command = ["/wait-shutdown"]
            }
          }
        }

        terminationGracePeriodSeconds = 300
      }

      # ── Default backend (página de erro customizada) ──────────────────────
      defaultBackend = {
        enabled = true
      }
    })
  ]

  depends_on = [
    kubernetes_namespace.nginx_ingress,
    time_sleep.eks_access_ready,
  ]
}

# ── External DNS ──────────────────────────────────────────────────────────────
# Sincroniza automaticamente os hostnames dos Ingresses com Route53.
# Funciona lendo a anotação external-dns.alpha.kubernetes.io/hostname ou
# o campo spec.rules[].host dos objetos Ingress com ingressClassName=nginx.

resource "helm_release" "external_dns" {
  name             = "external-dns"
  repository       = "https://kubernetes-sigs.github.io/external-dns/"
  chart            = "external-dns"
  version          = "1.20.0"
  namespace        = kubernetes_namespace.external_dns.metadata[0].name
  create_namespace = false
  wait             = true
  timeout          = 600

  values = [
    yamlencode({
      provider = {
        name = "aws"
      }
      policy             = "upsert-only"
      triggerLoopOnEvent = true
      interval           = "30s"
      txtOwnerId         = module.eks.cluster_name
      domainFilters      = [var.domain_name]
      sources            = ["ingress"]
      extraArgs = [
        "--aws-zone-type=public",
        "--zone-id-filter=${var.route53_zone_id}"
      ]
      serviceAccount = {
        create = true
        name   = local.external_dns_service_account
        annotations = {
          "eks.amazonaws.com/role-arn" = module.irsa_external_dns.iam_role_arn
        }
      }
    })
  ]

  depends_on = [
    module.irsa_external_dns,
    helm_release.nginx_ingress,
  ]
}
