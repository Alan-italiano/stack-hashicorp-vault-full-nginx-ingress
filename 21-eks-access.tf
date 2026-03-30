resource "time_sleep" "eks_access_ready" {
  depends_on = [module.eks]

  # EKS access entries can take a short time to propagate after cluster creation.
  create_duration = "60s"
}
