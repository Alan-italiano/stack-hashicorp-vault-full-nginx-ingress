resource "kubernetes_namespace" "postgres" {
  metadata {
    name = local.postgres_namespace
  }

  depends_on = [
    helm_release.kube_prometheus_stack
  ]
}

resource "kubernetes_service_v1" "postgres_headless" {
  metadata {
    name      = "postgres-headless"
    namespace = kubernetes_namespace.postgres.metadata[0].name
  }

  spec {
    cluster_ip = "None"

    selector = {
      app = "postgres"
    }

    port {
      name        = "postgres"
      port        = 5432
      target_port = 5432
      protocol    = "TCP"
    }
  }

  depends_on = [
    kubernetes_namespace.postgres
  ]
}

resource "kubernetes_stateful_set_v1" "postgres" {
  metadata {
    name      = "postgres"
    namespace = kubernetes_namespace.postgres.metadata[0].name
    labels = {
      app = "postgres"
    }
  }

  spec {
    service_name = kubernetes_service_v1.postgres_headless.metadata[0].name
    replicas     = 1

    selector {
      match_labels = {
        app = "postgres"
      }
    }

    template {
      metadata {
        labels = {
          app = "postgres"
        }
      }

      spec {
        container {
          name  = "postgres"
          image = "postgres:17"

          port {
            container_port = 5432
            name           = "postgres"
          }

          env {
            name  = "POSTGRES_DB"
            value = var.postgres_database_name
          }

          env {
            name  = "POSTGRES_USER"
            value = var.postgres_admin_username
          }

          env {
            name  = "POSTGRES_PASSWORD"
            value = var.postgres_admin_password
          }

          env {
            name  = "PGDATA"
            value = "/var/lib/postgresql/data/pgdata"
          }

          volume_mount {
            name       = "postgres-storage"
            mount_path = "/var/lib/postgresql/data"
          }
        }
      }
    }

    volume_claim_template {
      metadata {
        name = "postgres-storage"
      }

      spec {
        access_modes       = ["ReadWriteOnce"]
        storage_class_name = var.vault_storage_class_name

        resources {
          requests = {
            storage = "5Gi"
          }
        }
      }
    }
  }

  depends_on = [
    kubernetes_namespace.postgres,
    kubernetes_service_v1.postgres_headless,
    kubernetes_storage_class_v1.vault_ebs_gp3
  ]
}

# ── Serviço ClusterIP — acesso interno apenas ─────────────────────────────────
# PostgreSQL é acessível somente dentro do cluster (via Vault database engine
# e kubectl port-forward). Não há NLB externo para reduzir a superfície de ataque.
# Use: kubectl port-forward -n postgres svc/postgres-service 5432:5432

resource "kubernetes_service_v1" "postgres" {
  metadata {
    name      = "postgres-service"
    namespace = kubernetes_namespace.postgres.metadata[0].name
  }

  spec {
    type = "ClusterIP"

    selector = {
      app = "postgres"
    }

    port {
      name        = "postgres"
      port        = 5432
      target_port = 5432
      protocol    = "TCP"
    }
  }

  depends_on = [
    kubernetes_stateful_set_v1.postgres
  ]
}
