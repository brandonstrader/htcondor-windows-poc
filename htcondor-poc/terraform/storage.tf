resource "random_id" "bucket" {
  byte_length = 4
}

resource "aws_s3_bucket" "artifacts" {
  bucket        = "${local.project}-artifacts-${random_id.bucket.hex}"
  force_destroy = true   # allow `terraform destroy` to empty it
}

resource "aws_s3_bucket_versioning" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "artifacts" {
  bucket                  = aws_s3_bucket.artifacts.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Upload setup scripts (scripts/*.ps1 → s3://bucket/scripts/)
resource "aws_s3_object" "scripts" {
  for_each = fileset("${path.module}/../scripts", "*.ps1")

  bucket = aws_s3_bucket.artifacts.id
  key    = "scripts/${each.value}"
  source = "${path.module}/../scripts/${each.value}"
  etag   = filemd5("${path.module}/../scripts/${each.value}")
}

# Upload HTCondor config files (htcondor/*.conf → s3://bucket/htcondor/)
resource "aws_s3_object" "htcondor_configs" {
  for_each = fileset("${path.module}/../htcondor", "*.conf")

  bucket = aws_s3_bucket.artifacts.id
  key    = "htcondor/${each.value}"
  source = "${path.module}/../htcondor/${each.value}"
  etag   = filemd5("${path.module}/../htcondor/${each.value}")
}

# Upload test job files (jobs/* → s3://bucket/jobs/)
resource "aws_s3_object" "jobs" {
  for_each = fileset("${path.module}/../jobs", "*")

  bucket = aws_s3_bucket.artifacts.id
  key    = "jobs/${each.value}"
  source = "${path.module}/../jobs/${each.value}"
  etag   = filemd5("${path.module}/../jobs/${each.value}")
}

# ── SSM Parameter Store ──────────────────────────────────────────────────────
# Setup scripts read these instead of having secrets baked into user data.

resource "aws_ssm_parameter" "admin_password" {
  name  = "${local.ssm_prefix}/admin-password"
  type  = "SecureString"
  value = var.admin_password
}

resource "aws_ssm_parameter" "htcondor_pool_password" {
  name  = "${local.ssm_prefix}/htcondor-pool-password"
  type  = "SecureString"
  value = var.htcondor_pool_password
}

resource "aws_ssm_parameter" "brandon_password" {
  name  = "${local.ssm_prefix}/brandon-password"
  type  = "SecureString"
  value = var.brandon_password
}

resource "aws_ssm_parameter" "domain_name" {
  name  = "${local.ssm_prefix}/domain-name"
  type  = "String"
  value = var.domain_name
}

resource "aws_ssm_parameter" "domain_netbios" {
  name  = "${local.ssm_prefix}/domain-netbios"
  type  = "String"
  value = var.domain_netbios
}

resource "aws_ssm_parameter" "dc_ip" {
  name  = "${local.ssm_prefix}/dc-ip"
  type  = "String"
  value = local.dc_ip
}

resource "aws_ssm_parameter" "s3_bucket" {
  name  = "${local.ssm_prefix}/s3-bucket"
  type  = "String"
  value = aws_s3_bucket.artifacts.id
}

resource "aws_ssm_parameter" "htcondor_msi_key" {
  name  = "${local.ssm_prefix}/htcondor-msi-key"
  type  = "String"
  value = var.htcondor_msi_s3_key
}

resource "aws_ssm_parameter" "share_host" {
  name  = "${local.ssm_prefix}/share-host"
  type  = "String"
  value = "mgr.${var.domain_name}"
}
