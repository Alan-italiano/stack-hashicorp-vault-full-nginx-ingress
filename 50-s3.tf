locals {
  vault_snapshot_bucket_allowed_principal_arns = distinct(concat(
    var.vault_snapshot_bucket_admin_principal_arns,
    [
      data.aws_caller_identity.current.arn,
      module.irsa_vault.iam_role_arn,
      "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:root"
    ]
  ))
}

resource "aws_s3_bucket" "vault_snapshots" {
  bucket        = var.vault_snapshot_bucket_name
  force_destroy = false
  tags          = local.tags
}

resource "aws_s3_bucket_versioning" "vault_snapshots" {
  bucket = aws_s3_bucket.vault_snapshots.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "vault_snapshots" {
  bucket = aws_s3_bucket.vault_snapshots.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.vault_unseal.arn
    }
  }
}

resource "aws_s3_bucket_public_access_block" "vault_snapshots" {
  bucket = aws_s3_bucket.vault_snapshots.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

data "aws_iam_policy_document" "vault_snapshots_bucket" {
  statement {
    sid    = "DenyInsecureTransport"
    effect = "Deny"

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    actions = ["s3:*"]

    resources = [
      aws_s3_bucket.vault_snapshots.arn,
      "${aws_s3_bucket.vault_snapshots.arn}/*"
    ]

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }

  statement {
    sid    = "DenyAccessIfNotVaultRole"
    effect = "Deny"

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    actions = ["s3:*"]

    resources = [
      aws_s3_bucket.vault_snapshots.arn,
      "${aws_s3_bucket.vault_snapshots.arn}/*"
    ]

    condition {
      test     = "ArnNotEquals"
      variable = "aws:PrincipalArn"
      values   = local.vault_snapshot_bucket_allowed_principal_arns
    }
  }

  statement {
    sid    = "AllowVaultRoleAccess"
    effect = "Allow"

    principals {
      type        = "AWS"
      identifiers = local.vault_snapshot_bucket_allowed_principal_arns
    }

    actions = [
      "s3:GetBucketLocation",
      "s3:GetBucketPolicy",
      "s3:GetBucketPublicAccessBlock",
      "s3:GetBucketTagging",
      "s3:GetBucketVersioning",
      "s3:GetEncryptionConfiguration",
      "s3:ListBucket",
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject"
    ]

    resources = [
      aws_s3_bucket.vault_snapshots.arn,
      "${aws_s3_bucket.vault_snapshots.arn}/*"
    ]
  }
}

resource "aws_s3_bucket_policy" "vault_snapshots" {
  bucket = aws_s3_bucket.vault_snapshots.id
  policy = data.aws_iam_policy_document.vault_snapshots_bucket.json
}
