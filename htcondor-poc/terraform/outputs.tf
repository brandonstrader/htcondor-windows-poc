output "instance_ids" {
  description = "EC2 instance IDs for SSM Session Manager access"
  value = {
    dc      = aws_instance.dc.id
    cm      = aws_instance.cm.id
    submit  = aws_instance.submit.id
    execute = aws_instance.execute.id
  }
}

output "private_ips" {
  description = "Private IP addresses of each instance"
  value = {
    dc      = aws_instance.dc.private_ip
    cm      = aws_instance.cm.private_ip
    submit  = aws_instance.submit.private_ip
    execute = aws_instance.execute.private_ip
  }
}

output "s3_bucket" {
  description = "S3 artifacts bucket name (used by later stages to stage installers)"
  value       = aws_s3_bucket.artifacts.id
}

output "ssm_connect_commands" {
  description = "Copy-paste AWS CLI commands to open SSM sessions"
  value = {
    dc      = "aws ssm start-session --target ${aws_instance.dc.id}      --region ${var.aws_region}"
    cm      = "aws ssm start-session --target ${aws_instance.cm.id}      --region ${var.aws_region}"
    submit  = "aws ssm start-session --target ${aws_instance.submit.id}  --region ${var.aws_region}"
    execute = "aws ssm start-session --target ${aws_instance.execute.id} --region ${var.aws_region}"
  }
}

output "ssm_prefix" {
  description = "SSM Parameter Store path prefix for all project secrets"
  value       = local.ssm_prefix
}
