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

# ── SSM Parameter Store ──────────────────────────────────────────────────────
# At v1 we publish only what a bare Windows instance needs. Later stages add
# htcondor-pool-password, brandon-password, domain-name, etc.

resource "aws_ssm_parameter" "admin_password" {
  name  = "${local.ssm_prefix}/admin-password"
  type  = "SecureString"
  value = var.admin_password
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
