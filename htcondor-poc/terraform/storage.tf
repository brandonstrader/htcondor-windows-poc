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

# ── SSM Parameter Store ──────────────────────────────────────────────────────
# At v2 we publish AD + artifact-location params so setup scripts can do
# domain join and locate the MSI. HTCondor-specific params (pool password)
# come in at v3 when we actually install.

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

resource "aws_ssm_parameter" "s3_bucket" {
  name  = "${local.ssm_prefix}/s3-bucket"
  type  = "String"
  value = aws_s3_bucket.artifacts.id
}
