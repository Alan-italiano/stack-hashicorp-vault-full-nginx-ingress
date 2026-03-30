resource "helm_release" "metrics_server" {
  name             = "metrics-server"
  repository       = "https://kubernetes-sigs.github.io/metrics-server/"
  chart            = "metrics-server"
  version          = "3.13.0"
  namespace        = "kube-system"
  create_namespace = false

  values = [
    yamlencode({
      args = [
        "--kubelet-insecure-tls",
        "--kubelet-preferred-address-types=InternalIP,Hostname,ExternalIP"
      ]
    })
  ]

  depends_on = [
    module.eks
  ]
}
