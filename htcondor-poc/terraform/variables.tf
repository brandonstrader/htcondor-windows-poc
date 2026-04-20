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
    digit, symbol. At v1 this is the local Administrator password; later
    stages reuse it as the AD Administrator password.
  EOF
  type      = string
  sensitive = true
  validation {
    condition     = length(var.admin_password) >= 12
    error_message = "admin_password must be at least 12 characters."
  }
}

variable "instance_type" {
  description = "EC2 instance type for all nodes"
  type        = string
  default     = "t3.medium"
}
