# Deploy — v1 Infrastructure Only

This tag stands up the AWS infrastructure for the PoC but installs **no
software** — no Active Directory, no HTCondor, no domain join. You get
four bare Windows Server 2022 instances reachable via SSM.

## What gets built

| VM | Hostname | Private IP | State at v1 |
|----|----------|------------|-------------|
| dc | (default) | 10.0.1.10 | bare Windows |
| mgr | (default) | 10.0.1.11 | bare Windows |
| ws-0 | (default) | 10.0.1.12 | bare Windows |
| compute-0 | (default) | 10.0.1.13 | bare Windows |

Also: VPC + public/private subnets + NAT Gateway + S3 Gateway endpoint +
IAM role/profile granting SSM + S3-read + SSM-params-read + the artifacts
S3 bucket (empty).

All instances are in a private subnet. Access is exclusively via **AWS
Systems Manager Session Manager**.

**Estimated cost while running:** ~$0.20/hr.

---

## Step 1 — Prerequisites

Complete `prerequisites.md` first.

---

## Step 2 — Create terraform.tfvars

```bash
cd htcondor-poc/terraform
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars` and fill in `admin_password` (12+ chars, mixed
case, digit, symbol). This is the local Administrator password on every
VM — later stages reuse it as the AD Administrator password.

---

## Step 3 — Deploy

```bash
terraform init
terraform apply
```

Terraform will create: VPC, subnets, NAT Gateway, S3 endpoint, IAM roles,
security groups, the empty S3 bucket, 3 SSM parameters
(`/htcondor-poc/admin-password`, `/htcondor-poc/dc-ip`,
`/htcondor-poc/s3-bucket`), and four EC2 instances.

**Wall time:** ~5 minutes.

---

## Step 4 — Verify

```bash
terraform output instance_ids
terraform output ssm_connect_commands
```

Open an SSM session to each instance and confirm PowerShell is
responsive:

```bash
aws ssm start-session --target <dc-instance-id> --region us-east-1
```

```powershell
Get-ComputerInfo | Select-Object CsName, WindowsProductName
hostname     # will show the EC2 default name — renaming happens at v2
```

---

## Teardown

```bash
terraform destroy
```

---

## What's next

Check out **v2-ad-and-artifacts** to add Active Directory and stage the
HTCondor installer + scripts + configs in the S3 bucket. See that tag's
DEPLOY.md for next steps.
