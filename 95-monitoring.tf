resource "kubernetes_namespace" "monitoring" {
  metadata {
    name = local.monitoring_namespace
  }

  depends_on = [time_sleep.eks_access_ready]
}

resource "helm_release" "kube_prometheus_stack" {
  name             = "kube-prometheus-stack"
  repository       = "https://prometheus-community.github.io/helm-charts"
  chart            = "kube-prometheus-stack"
  version          = "82.15.1"
  namespace        = kubernetes_namespace.monitoring.metadata[0].name
  create_namespace = false
  timeout          = 600

  values = [
    yamlencode({
      grafana = {
        enabled = true
        additionalDataSources = [
          {
            name      = "Loki"
            type      = "loki"
            uid       = "loki"
            access    = "proxy"
            url       = "http://loki-gateway.monitoring.svc.cluster.local"
            isDefault = false
          }
        ]
        # Ingress gerenciado externamente em 63-ingress-resources.tf
        ingress = {
          enabled = false
        }
        "grafana.ini" = {
          server = {
            domain   = var.grafana_hostname
            root_url = "https://${var.grafana_hostname}"
          }
        }
      }
      prometheus = {
        prometheusSpec = {
          retention                               = "10d"
          serviceMonitorSelectorNilUsesHelmValues = false
          serviceMonitorSelector                  = {}
          serviceMonitorNamespaceSelector         = {}
          podMonitorSelectorNilUsesHelmValues     = false
          podMonitorSelector                      = {}
          podMonitorNamespaceSelector             = {}
        }
      }
      alertmanager = {
        enabled = true
      }
    })
  ]

  depends_on = [
    helm_release.cert_manager,
    kubectl_manifest.vault_server_certificate,
  ]
}
