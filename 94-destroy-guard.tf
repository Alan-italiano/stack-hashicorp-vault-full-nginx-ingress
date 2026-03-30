resource "null_resource" "nginx_destroy_guard" {
  triggers = {
    monitoring_namespace = kubernetes_namespace.monitoring.metadata[0].name
    vault_namespace      = kubernetes_namespace.vault.metadata[0].name
    nginx_namespace      = local.nginx_ingress_namespace
    grafana_ingress      = kubernetes_ingress_v1.grafana.metadata[0].name
    vault_ingress        = kubernetes_ingress_v1.vault.metadata[0].name
  }

  provisioner "local-exec" {
    when        = destroy
    interpreter = ["/bin/bash", "-lc"]

    command = <<-EOT
      set -euo pipefail

      # Remove os Ingresses para que o External DNS possa limpar os registros
      # Route53 antes de o namespace ser destruído.
      kubectl delete ingress \
        -n "${self.triggers.monitoring_namespace}" \
        "${self.triggers.grafana_ingress}" \
        --ignore-not-found=true 2>/dev/null || true

      kubectl delete ingress \
        -n "${self.triggers.vault_namespace}" \
        "${self.triggers.vault_ingress}" \
        --ignore-not-found=true 2>/dev/null || true

      # Aguarda External DNS remover os registros Route53 (até 2 min)
      echo "Aguardando External DNS limpar registros Route53..."
      sleep 30

      # Remove o Service do NGINX Ingress Controller para desprovisionar o NLB.
      # O AWS Cloud Provider Controller processa a deleção do Service e remove
      # o NLB antes de qualquer recurso VPC ser destruído pelo Terraform.
      kubectl delete svc \
        -n "${self.triggers.nginx_namespace}" \
        ingress-nginx-controller \
        --ignore-not-found=true 2>/dev/null || true

      echo "Aguardando NLB ser desprovisionado (até 3 min)..."
      for i in $(seq 1 18); do
        COUNT=$(kubectl get svc \
          -n "${self.triggers.nginx_namespace}" \
          ingress-nginx-controller \
          --ignore-not-found=true 2>/dev/null | wc -l || echo "0")
        if [ "$COUNT" -le 1 ]; then
          echo "  Service NGINX removido."
          break
        fi
        echo "  Aguardando... ($i/18)"
        sleep 10
      done

      # Pausa adicional para garantir que as ENIs do NLB sejam liberadas
      sleep 30

      echo "Pré-destroy NGINX concluído."
    EOT
  }

  depends_on = [
    helm_release.nginx_ingress,
    kubernetes_ingress_v1.grafana,
    kubernetes_ingress_v1.vault,
  ]
}
