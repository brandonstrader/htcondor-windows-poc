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

# ── Staged artifacts ─────────────────────────────────────────────────────────
# Setup scripts get uploaded at apply time so the user_data bootstrap can
# fetch and run the role-specific one. The HTCondor MSI is NOT uploaded by
# Terraform — it's a binary the user downloads from HTCondor's site and
# uploads manually to s3://<bucket>/<htcondor_msi_s3_key> (see DEPLOY.md).

resource "aws_s3_object" "script_dc" {
  bucket = aws_s3_bucket.artifacts.id
  key    = "scripts/dc-setup.ps1"
  source = "${path.module}/../scripts/dc-setup.ps1"
  etag   = filemd5("${path.module}/../scripts/dc-setup.ps1")
}

resource "aws_s3_object" "script_cm" {
  bucket = aws_s3_bucket.artifacts.id
  key    = "scripts/cm-setup.ps1"
  source = "${path.module}/../scripts/cm-setup.ps1"
  etag   = filemd5("${path.module}/../scripts/cm-setup.ps1")
}

resource "aws_s3_object" "script_submit" {
  bucket = aws_s3_bucket.artifacts.id
  key    = "scripts/submit-setup.ps1"
  source = "${path.module}/../scripts/submit-setup.ps1"
  etag   = filemd5("${path.module}/../scripts/submit-setup.ps1")
}

resource "aws_s3_object" "script_execute" {
  bucket = aws_s3_bucket.artifacts.id
  key    = "scripts/execute-setup.ps1"
  source = "${path.module}/../scripts/execute-setup.ps1"
  etag   = filemd5("${path.module}/../scripts/execute-setup.ps1")
}

# HTCondor config files — consumed by cm/submit/execute setup scripts at
# stage 2 (install). All four are uploaded together; each node picks the
# role-appropriate one as its 01-role.conf after download.
locals {
  htcondor_configs = toset([
    "00-common.conf",
    "01-cm.conf",
    "02-execute.conf",
    "03-submit.conf",
  ])
  job_files = toset([
    "test-brandon.bat",
    "test-brandon.sub",
  ])
}

resource "aws_s3_object" "htcondor_config" {
  for_each = local.htcondor_configs
  bucket   = aws_s3_bucket.artifacts.id
  key      = "htcondor/${each.value}"
  source   = "${path.module}/../htcondor/${each.value}"
  etag     = filemd5("${path.module}/../htcondor/${each.value}")
}

resource "aws_s3_object" "job_file" {
  for_each = local.job_files
  bucket   = aws_s3_bucket.artifacts.id
  key      = "jobs/${each.value}"
  source   = "${path.module}/../jobs/${each.value}"
  etag     = filemd5("${path.module}/../jobs/${each.value}")
}

# ── SSM Parameter Store ──────────────────────────────────────────────────────
# At v3 we add HTCondor-specific params (pool password, SMB share host) so
# setup scripts can install + configure the pool.

resource "aws_ssm_parameter" "admin_password" {
  name  = "${local.ssm_prefix}/admin-password"
  type  = "SecureString"
  value = var.admin_password
}

resource "aws_ssm_parameter" "brandon_password" {
  name  = "${local.ssm_prefix}/brandon-password"
  type  = "SecureString"
  value = var.brandon_password
}

resource "aws_ssm_parameter" "dc_ip" {
  name  = "${local.ssm_prefix}/dc-ip"
  type  = "String"
  value = local.dc_ip
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

resource "aws_ssm_parameter" "htcondor_msi_key" {
  name  = "${local.ssm_prefix}/htcondor-msi-key"
  type  = "String"
  value = var.htcondor_msi_s3_key
}

resource "aws_ssm_parameter" "htcondor_pool_password" {
  name  = "${local.ssm_prefix}/htcondor-pool-password"
  type  = "SecureString"
  value = var.htcondor_pool_password
}

resource "aws_ssm_parameter" "s3_bucket" {
  name  = "${local.ssm_prefix}/s3-bucket"
  type  = "String"
  value = aws_s3_bucket.artifacts.id
}

resource "aws_ssm_parameter" "share_host" {
  name  = "${local.ssm_prefix}/share-host"
  type  = "String"
  value = "mgr.${var.domain_name}"
}
