resource "aws_kms_key" "vault_unseal" {
  description             = "KMS key for Vault auto-unseal"
  deletion_window_in_days = 7
  enable_key_rotation     = true
  tags                    = local.tags
}

resource "aws_kms_alias" "vault_unseal" {
  name          = "alias/${var.cluster_name}-vault-unseal"
  target_key_id = aws_kms_key.vault_unseal.key_id
}

data "aws_iam_policy_document" "vault_runtime" {
  statement {
    sid    = "AllowKMSAutoUnseal"
    effect = "Allow"

    actions = [
      "kms:Encrypt",
      "kms:Decrypt",
      "kms:DescribeKey",
      "kms:GenerateDataKey"
    ]

    resources = [aws_kms_key.vault_unseal.arn]
  }

  statement {
    sid    = "AllowS3Snapshots"
    effect = "Allow"

    actions = [
      "s3:ListBucket"
    ]

    resources = [aws_s3_bucket.vault_snapshots.arn]
  }

  statement {
    sid    = "AllowS3SnapshotObjects"
    effect = "Allow"

    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject"
    ]

    resources = ["${aws_s3_bucket.vault_snapshots.arn}/*"]
  }
}

resource "aws_iam_policy" "vault_runtime" {
  name   = "${var.cluster_name}-vault-runtime"
  policy = data.aws_iam_policy_document.vault_runtime.json
}

module "irsa_vault" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.0"

  role_name = "${var.cluster_name}-vault"

  oidc_providers = {
    this = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["${local.vault_namespace}:${local.vault_service_account}"]
    }
  }

  role_policy_arns = {
    runtime = aws_iam_policy.vault_runtime.arn
  }

  tags = local.tags
}

data "aws_iam_policy_document" "kms_policy" {
  statement {
    sid    = "EnableAccountAdminPermissions"
    effect = "Allow"

    principals {
      type        = "AWS"
      identifiers = ["arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:root"]
    }

    actions   = ["kms:*"]
    resources = ["*"]
  }

  statement {
    sid    = "AllowOnlyVaultServiceAccountRole"
    effect = "Allow"

    principals {
      type        = "AWS"
      identifiers = [module.irsa_vault.iam_role_arn]
    }

    actions = [
      "kms:Encrypt",
      "kms:Decrypt",
      "kms:DescribeKey",
      "kms:GenerateDataKey"
    ]

    resources = ["*"]
  }
}

resource "aws_kms_key_policy" "vault_unseal" {
  key_id = aws_kms_key.vault_unseal.id
  policy = data.aws_iam_policy_document.kms_policy.json
}
