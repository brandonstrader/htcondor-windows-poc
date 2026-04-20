variable "aws_region" {
  description = "AWS region for all resources"
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Prefix applied to all resource names and tags"
  type        = string
  default     = "htcondor-poc"
}

variable "admin_password" {
  description = <<-EOF
    Password for the Windows local Administrator account on all VMs.
    Must meet Windows complexity requirements: 12+ chars, upper, lower,
    digit, symbol. Reused as the AD Administrator password on the domain
    controller.
  EOF
  type      = string
  sensitive = true
  validation {
    condition     = length(var.admin_password) >= 12
    error_message = "admin_password must be at least 12 characters."
  }
}

variable "brandon_password" {
  description = <<-EOF
    Password for the 'brandon' domain user created on the DC. Must meet
    Windows complexity requirements (12+ chars, mixed case, digit, symbol).
    This is a regular (non-admin) domain user used to prove run_as_owner
    job impersonation in later stages.
  EOF
  type      = string
  sensitive = true
  validation {
    condition     = length(var.brandon_password) >= 12
    error_message = "brandon_password must be at least 12 characters."
  }
}

variable "domain_name" {
  description = "FQDN of the AD domain created on the DC"
  type        = string
  default     = "fort.wow.dev"
}

variable "domain_netbios" {
  description = "NetBIOS (short) name of the AD domain. Uppercase, ≤15 chars."
  type        = string
  default     = "FORTWOW"
}

variable "htcondor_msi_s3_key" {
  description = <<-EOF
    S3 object key where the HTCondor Windows MSI will be uploaded. The
    user uploads the MSI manually after terraform apply; later stages pull
    it from this location.
  EOF
  type        = string
  default     = "installers/condor-23.4.0-Windows-x64.msi"
}

variable "htcondor_pool_password" {
  description = <<-EOF
    Shared secret used for HTCondor's PASSWORD authentication between
    daemons. Any ASCII string ≥ 8 chars. Stored on every node via
    `condor_store_cred add -c` during setup.
  EOF
  type      = string
  sensitive = true
  validation {
    condition     = length(var.htcondor_pool_password) >= 8
    error_message = "htcondor_pool_password must be at least 8 characters."
  }
}

variable "instance_type" {
  description = "EC2 instance type for all nodes"
  type        = string
  default     = "t3.medium"
}
