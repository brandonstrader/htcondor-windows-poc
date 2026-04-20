# FSx for Windows File Server backed by the self-managed AD on the DC.
#
# TIMING: time_sleep.wait_for_dc_ad ensures the DC has finished setting up
# Active Directory (install AD DS role + Install-ADDSForest + post-forest
# restart) before Terraform attempts to create FSx. If FSx cannot reach
# a healthy AD domain controller it will fail.
#
# COST (us-east-1 SSD SINGLE_AZ_2):
#   Storage : 32 GB  × $0.23/GB-mo  ≈ $0.010/hr
#   Throughput: 8 MB/s × $2.20/MB/s-mo ≈ $0.024/hr
#   Total   ≈ $0.034/hr  (~$0.82/day)

resource "aws_fsx_windows_file_system" "shared" {
  # Self-managed AD: point to our DC
  self_managed_active_directory {
    dns_ips     = [local.dc_ip]
    domain_name = var.domain_name
    username    = "Administrator"    # AD Administrator joins FSx to domain
    password    = var.admin_password
  }

  storage_type        = "SSD"
  storage_capacity    = 32           # GB (minimum for SSD single-AZ)
  throughput_capacity = 8            # MB/s (minimum)
  deployment_type     = "SINGLE_AZ_2"

  subnet_ids         = [aws_subnet.private.id]
  security_group_ids = [aws_security_group.fsx.id]

  skip_final_backup = true           # No automated backups for this PoC

  tags = { Name = "${local.project}-shared-fs" }

  # Must wait for AD to be healthy before FSx can join the domain
  depends_on = [time_sleep.wait_for_dc_ad]
}
