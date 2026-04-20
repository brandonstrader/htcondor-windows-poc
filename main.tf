terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.4"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.9"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = var.project_name
      Environment = "poc"
      ManagedBy   = "terraform"
    }
  }
}

# Windows Server 2022 AMI (latest, from Amazon)
data "aws_ami" "windows_2022" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["Windows_Server-2022-English-Full-Base-*"]
  }
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
}

locals {
  project      = var.project_name
  ssm_prefix   = "/${var.project_name}"

  # Static private IPs in 10.0.1.0/24
  dc_ip        = "10.0.1.10"
  cm_ip        = "10.0.1.11"
  submit_ip    = "10.0.1.12"
  execute_ip   = "10.0.1.13"

  # Network
  vpc_cidr     = "10.0.0.0/16"
  public_cidr  = "10.0.0.0/24"   # NAT Gateway only
  private_cidr = "10.0.1.0/24"   # All instances
  az           = "${var.aws_region}a"
}

# EC2 Key Pair (saved locally for Windows password decryption if needed)
resource "tls_private_key" "main" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "aws_key_pair" "main" {
  key_name   = "${local.project}-key"
  public_key = tls_private_key.main.public_key_openssh
}

resource "local_file" "private_key" {
  content         = tls_private_key.main.private_key_pem
  filename        = "${path.module}/${local.project}-key.pem"
  file_permission = "0600"
}

# Wait for DC to finish Active Directory setup before creating FSx.
# AD setup (install role + create forest + restart) takes ~15-20 minutes.
resource "time_sleep" "wait_for_dc_ad" {
  depends_on      = [aws_instance.dc]
  create_duration = "20m"
}
