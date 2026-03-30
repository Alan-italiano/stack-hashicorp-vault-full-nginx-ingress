resource "helm_release" "loki" {
  name             = "loki"
  repository       = "https://grafana.github.io/helm-charts"
  chart            = "loki"
  version          = "6.55.0"
  namespace        = kubernetes_namespace.monitoring.metadata[0].name
  create_namespace = false
  timeout          = 900

  values = [
    yamlencode({
      deploymentMode = "SingleBinary"
      singleBinary = {
        replicas = 1
        persistence = {
          enabled      = true
          storageClass = var.vault_storage_class_name
          size         = "20Gi"
        }
      }
      loki = {
        auth_enabled = false
        commonConfig = {
          replication_factor = 1
        }
        storage = {
          type = "filesystem"
          bucketNames = {
            chunks = "chunks"
            ruler  = "ruler"
            admin  = "admin"
          }
        }
        schemaConfig = {
          configs = [
            {
              from         = "2024-01-01"
              store        = "tsdb"
              object_store = "filesystem"
              schema       = "v13"
              index = {
                prefix = "loki_index_"
                period = "24h"
              }
            }
          ]
        }
        limits_config = {
          allow_structured_metadata = false
        }
      }
      gateway = {
        enabled = true
      }
      monitoring = {
        serviceMonitor = {
          enabled = true
        }
      }
      chunksCache = {
        enabled = false
      }
      resultsCache = {
        enabled = false
      }
      backend = {
        replicas = 0
      }
      read = {
        replicas = 0
      }
      write = {
        replicas = 0
      }
    })
  ]

  depends_on = [
    helm_release.kube_prometheus_stack
  ]
}

resource "helm_release" "promtail" {
  name             = "promtail"
  repository       = "https://grafana.github.io/helm-charts"
  chart            = "promtail"
  version          = "6.17.1"
  namespace        = kubernetes_namespace.monitoring.metadata[0].name
  create_namespace = false

  values = [
    yamlencode({
      config = {
        clients = [
          {
            url = "http://loki-gateway.monitoring.svc.cluster.local/loki/api/v1/push"
          }
        ]
      }
      serviceMonitor = {
        enabled = true
      }
    })
  ]

  depends_on = [
    helm_release.loki
  ]
}
