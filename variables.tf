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

variable "domain_name" {
  description = "Active Directory FQDN"
  type        = string
  default     = "fort.wow.dev"
}

variable "domain_netbios" {
  description = "AD NetBIOS (short) domain name"
  type        = string
  default     = "FORTWOW"
}

variable "admin_password" {
  description = <<-EOF
    Password for the Windows local Administrator account on all VMs and for the
    AD Administrator account on the DC. Must meet Windows complexity requirements:
    12+ chars, upper, lower, digit, symbol.
  EOF
  type      = string
  sensitive = true
  validation {
    condition     = length(var.admin_password) >= 12
    error_message = "admin_password must be at least 12 characters."
  }
}

variable "htcondor_pool_password" {
  description = <<-EOF
    Shared secret for HTCondor PASSWORD authentication method.
    Used by the credd subsystem. Must be the same on all pool nodes.
  EOF
  type      = string
  sensitive = true
  validation {
    condition     = length(var.htcondor_pool_password) >= 8
    error_message = "htcondor_pool_password must be at least 8 characters."
  }
}

variable "brandon_password" {
  description = <<-EOF
    Password for the AD user 'brandon', who submits the test job.
    Must meet Windows complexity requirements.
  EOF
  type      = string
  sensitive = true
  validation {
    condition     = length(var.brandon_password) >= 12
    error_message = "brandon_password must be at least 12 characters."
  }
}

variable "htcondor_msi_s3_key" {
  description = <<-EOF
    S3 object key for the HTCondor 23.4.0 Windows MSI.
    You must upload the MSI to this key in the artifacts bucket before
    the setup scripts run. See DEPLOY.md step 3.
  EOF
  type    = string
  default = "installers/condor-23.4.0-Windows-x64.msi"
}

variable "instance_type" {
  description = "EC2 instance type for all nodes"
  type        = string
  default     = "t3.medium"
}
