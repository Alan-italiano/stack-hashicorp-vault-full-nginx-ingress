# ── External DNS IRSA ─────────────────────────────────────────────────────────

data "aws_iam_policy_document" "external_dns" {
  statement {
    sid = "AllowRoute53Changes"

    actions = [
      "route53:ChangeResourceRecordSets"
    ]

    resources = [
      "arn:${data.aws_partition.current.partition}:route53:::hostedzone/${var.route53_zone_id}"
    ]
  }

  statement {
    sid = "AllowRoute53Read"

    actions = [
      "route53:ListHostedZones",
      "route53:ListHostedZonesByName",
      "route53:ListResourceRecordSets",
      "route53:ListTagsForResource"
    ]

    resources = ["*"]
  }
}

resource "aws_iam_policy" "external_dns" {
  name   = "${var.cluster_name}-external-dns"
  policy = data.aws_iam_policy_document.external_dns.json
}

module "irsa_external_dns" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.0"

  role_name = "${var.cluster_name}-external-dns"

  oidc_providers = {
    this = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["${local.external_dns_namespace}:${local.external_dns_service_account}"]
    }
  }

  role_policy_arns = {
    external_dns = aws_iam_policy.external_dns.arn
  }

  tags = local.tags
}

# ── cert-manager IRSA (Route53 DNS-01 challenge) ──────────────────────────────
# cert-manager precisa de permissões para criar/remover registros TXT no Route53
# a fim de validar certificados Let's Encrypt via challenge DNS-01.

data "aws_iam_policy_document" "cert_manager_route53" {
  statement {
    sid = "AllowRoute53GetChange"

    actions = [
      "route53:GetChange"
    ]

    resources = ["arn:${data.aws_partition.current.partition}:route53:::change/*"]
  }

  statement {
    sid = "AllowRoute53UpsertRecords"

    actions = [
      "route53:ChangeResourceRecordSets",
      "route53:ListResourceRecordSets"
    ]

    resources = [
      "arn:${data.aws_partition.current.partition}:route53:::hostedzone/${var.route53_zone_id}"
    ]
  }

  statement {
    sid = "AllowRoute53ListHostedZones"

    actions = [
      "route53:ListHostedZonesByName"
    ]

    resources = ["*"]
  }
}

resource "aws_iam_policy" "cert_manager_route53" {
  name   = "${var.cluster_name}-cert-manager-route53"
  policy = data.aws_iam_policy_document.cert_manager_route53.json
}

module "irsa_cert_manager" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.0"

  role_name = "${var.cluster_name}-cert-manager"

  oidc_providers = {
    this = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["${local.cert_manager_namespace}:${local.cert_manager_service_account}"]
    }
  }

  role_policy_arns = {
    cert_manager = aws_iam_policy.cert_manager_route53.arn
  }

  tags = local.tags
}
