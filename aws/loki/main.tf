provider "aws" {
  region = var.region
}

terraform {
  backend "s3" {
  }
}

# taken from zarf bb repo
resource "random_id" "default" {
  byte_length = 2
}

data "aws_eks_cluster" "existing" {
  name = var.name
}

data "aws_caller_identity" "current" {}

data "aws_partition" "current" {}

data "aws_region" "current" {}

locals {
  oidc_url_without_protocol = substr(data.aws_eks_cluster.existing.identity[0].oidc[0].issuer, 8, -1)
  oidc_arn                  = "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:oidc-provider/${local.oidc_url_without_protocol}"

  generate_kms_key = var.create_kms_key ? 1 : 0
  kms_key_arn      = var.kms_key_arn == null ? module.generate_kms[0].kms_key_arn : var.kms_key_arn
  name             = "${var.name}-loki"

  # The conditional may need to look like this depending on how we decide to handle the way varf wants to template things
  # generate_kms_key          = var.kms_key_arn == "" ? 1 : 0
  # kms_key_arn               = var.kms_key_arn == "" ? module.generate_kms[0].kms_key_arn : var.kms_key_arn
}

module "S3" {
  source                  = "github.com/defenseunicorns/terraform-aws-uds-s3?ref=v0.0.6"
  name_prefix             = "${var.bucket_name}-"
  kms_key_arn             = local.kms_key_arn
  force_destroy           = var.force_destroy
  create_bucket_lifecycle = true
}

resource "aws_s3_bucket_policy" "bucket_policy" {
  bucket = module.S3.bucket_name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = [
          "s3:ListBucket",
          "s3:GetObject",
          "s3:PutObject"
        ]
        Effect = "Allow"
        Principal = {
          AWS = "${module.irsa.role_arn}"
        }
        Resource = [
          module.S3.bucket_arn,
          "${module.S3.bucket_arn}/*"
        ]
      }
    ]
  })
}

module "generate_kms" {
  count  = local.generate_kms_key
  source = "github.com/defenseunicorns/terraform-aws-uds-kms?ref=v0.0.2"

  key_owners = var.key_owner_arns
  # A list of IAM ARNs for those who will have full key permissions (`kms:*`)
  kms_key_alias_name_prefix = "${local.name}-" # Prefix for KMS key alias.
  kms_key_deletion_window   = 7
  # Waiting period for scheduled KMS Key deletion. Can be 7-30 days.
  kms_key_description = "${var.name} DUBBD deployment Loki Key" # Description for the KMS key.
  tags = {
    Deployment = "UDS DUBBD ${local.name}"
  }
}


module "irsa" {
  source                     = "github.com/defenseunicorns/terraform-aws-uds-irsa?ref=v0.0.2"
  name                       = local.name
  kubernetes_service_account = var.kubernetes_service_account
  kubernetes_namespace       = var.kubernetes_namespace
  oidc_provider_arn          = local.oidc_arn

  role_policy_arns = tomap({
    "loki" = aws_iam_policy.loki_policy.arn
  })

}

resource "random_id" "unique_id" {
  byte_length = 4
}


resource "aws_iam_policy" "loki_policy" {
  name        = "${local.name}-irsa-${random_id.unique_id.hex}"
  path        = "/"
  description = "IAM policy for Loki to have necessary permissions to use S3 for storing logs."
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = ["arn:${data.aws_partition.current.partition}:s3:::${module.S3.bucket_name}"]
      },
      {
        Effect   = "Allow"
        Action   = ["s3:*Object"]
        Resource = ["arn:${data.aws_partition.current.partition}:s3:::${module.S3.bucket_name}/*"]
      },
      {
        Effect = "Allow"
        Action = [
          "kms:GenerateDataKey",
          "kms:Decrypt"
        ]
        Resource = ["${local.kms_key_arn}"]
      }
    ]
  })
}
