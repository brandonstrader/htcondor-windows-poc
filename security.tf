# ── Security Groups ─────────────────────────────────────────────────────────

# Shared SG: all instances. Allows all traffic within the VPC.
# Port 9618 is HTCondor's shared port. All AD/DNS/SMB traffic is
# covered by the VPC-wide allow rule below.
resource "aws_security_group" "instances" {
  name_prefix = "${local.project}-instances-"
  vpc_id      = aws_vpc.main.id
  description = "All HTCondor PoC instances - full intra-VPC access"

  ingress {
    description = "All traffic within VPC"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [local.vpc_cidr]
  }

  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  lifecycle { create_before_destroy = true }
}

# FSx SG: only needs inbound SMB from the instances SG.
resource "aws_security_group" "fsx" {
  name_prefix = "${local.project}-fsx-"
  vpc_id      = aws_vpc.main.id
  description = "FSx Windows File Server"

  ingress {
    description     = "SMB from instances"
    from_port       = 445
    to_port         = 445
    protocol        = "tcp"
    security_groups = [aws_security_group.instances.id]
  }

  ingress {
    description = "FSx management from VPC"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [local.vpc_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  lifecycle { create_before_destroy = true }
}


# ── IAM ─────────────────────────────────────────────────────────────────────

resource "aws_iam_role" "instance" {
  name               = "${local.project}-instance-role"
  description        = "Role for all HTCondor PoC EC2 instances"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

# SSM Session Manager (no public IPs required)
resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.instance.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# Read artifacts from the S3 bucket
resource "aws_iam_policy" "s3_read" {
  name        = "${local.project}-instance-s3-read"
  description = "Allow EC2 instances to read setup artifacts from S3"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["s3:GetObject", "s3:ListBucket"]
      Resource = [
        aws_s3_bucket.artifacts.arn,
        "${aws_s3_bucket.artifacts.arn}/*"
      ]
    }]
  })
}

resource "aws_iam_role_policy_attachment" "s3_read" {
  role       = aws_iam_role.instance.name
  policy_arn = aws_iam_policy.s3_read.arn
}

# Read secrets from SSM Parameter Store
resource "aws_iam_policy" "ssm_params_read" {
  name        = "${local.project}-instance-ssm-params-read"
  description = "Allow EC2 instances to read SSM parameters for this project"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "ssm:GetParameter",
        "ssm:GetParameters",
        "ssm:GetParametersByPath"
      ]
      Resource = "arn:aws:ssm:${var.aws_region}:*:parameter${local.ssm_prefix}/*"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ssm_params_read" {
  role       = aws_iam_role.instance.name
  policy_arn = aws_iam_policy.ssm_params_read.arn
}

resource "aws_iam_instance_profile" "instance" {
  name = "${local.project}-instance-profile"
  role = aws_iam_role.instance.name
}
