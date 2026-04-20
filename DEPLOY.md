# Deployment Guide — HTCondor 23.4.0 run_as_owner PoC

## Architecture recap

| VM | Hostname | Private IP | Role |
|----|----------|------------|------|
| dc | dc.fort.wow.dev | 10.0.1.10 | Active Directory DC + DNS |
| mgr | mgr.fort.wow.dev | 10.0.1.11 | HTCondor CM + CREDD |
| ws-0 | ws-0.fort.wow.dev | 10.0.1.12 | HTCondor submit node |
| compute-0 | compute-0.fort.wow.dev | 10.0.1.13 | HTCondor execute node |
| FSx | (dynamic DNS) | AWS-assigned | Shared file system (S: drive) |

All instances are in a private subnet. Access is exclusively via **AWS Systems Manager Session Manager** — no public IPs, no open inbound ports.

**Estimated cost while running:** ~$0.25/hr total.
**Estimated cost when stopped:** ~$0.04/hr (FSx storage + EBS snapshots).

---

## Step 1 — Clone / unzip the project

```
htcondor-poc/
├── terraform/          ← Terraform code
├── scripts/            ← PowerShell setup scripts (uploaded to S3)
├── htcondor/           ← HTCondor config files (uploaded to S3)
├── jobs/               ← Test job files (uploaded to S3)
├── prerequisites.md
└── DEPLOY.md
```

---

## Step 2 — Create terraform.tfvars

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars` and fill in all values. Choose strong passwords that meet
Windows complexity rules (12+ chars, upper + lower + digit + symbol).

> **Do not commit `terraform.tfvars` — it contains passwords in plaintext.**
> Add it to `.gitignore`.

---

## Step 3 — Create the S3 bucket and upload the HTCondor MSI

The setup scripts on each VM download the HTCondor MSI from S3. The bucket must
exist and the MSI must be uploaded **before** the instances try to run stage 2
of their setup. Do this as a separate targeted apply first.

```bash
# Inside the terraform/ directory:
terraform init
terraform apply -target=aws_s3_bucket.artifacts \
                -target=aws_s3_bucket_public_access_block.artifacts \
                -target=aws_s3_bucket_server_side_encryption_configuration.artifacts \
                -target=random_id.bucket
```

After it completes, note the bucket name from the output:
```bash
terraform output s3_bucket
# e.g.  htcondor-poc-artifacts-a1b2c3d4
```

Upload the HTCondor MSI (replace the filename with the one you downloaded):
```bash
aws s3 cp /path/to/condor-23.4.0-Windows-x64.msi \
    s3://$(terraform output -raw s3_bucket)/installers/condor-23.4.0-Windows-x64.msi
```

Verify the upload:
```bash
aws s3 ls s3://$(terraform output -raw s3_bucket)/installers/
```

---

## Step 4 — Deploy everything

```bash
terraform apply
```

Terraform will:
1. Create VPC, subnets, NAT Gateway, S3 endpoint
2. Create IAM roles, security groups
3. Upload scripts and configs to S3
4. Create SSM parameters for all secrets
5. Launch all four EC2 instances
6. **Wait 20 minutes** (`time_sleep.wait_for_dc_ad`) for DC to finish AD setup
7. Create the FSx file system and join it to the AD domain (another ~20-30 min)

**Total wall time: 45–60 minutes.** This is dominated by the AD and FSx setup.

When `terraform apply` finishes, note the outputs:
```bash
terraform output ssm_connect_commands
terraform output fsx_dns_name
```

---

## Step 5 — Monitor setup progress

Each instance runs its setup script automatically. Check progress via SSM:

```bash
# Connect to DC (substitute the actual instance ID from terraform output)
aws ssm start-session --target <dc-instance-id> --region us-east-1
```

Inside the SSM session (PowerShell):
```powershell
Get-Content C:\HTCondorSetup.log -Wait    # live tail
Get-Content C:\SetupStage.txt             # current stage (0/1/2/99)
Test-Path C:\SetupComplete.txt            # True when done
```

**Expected timelines after `terraform apply` completes:**

| VM | Setup complete |
|----|---------------|
| dc | ~20 min (AD forest creation includes 1 auto-reboot) |
| mgr | ~30 min (waits for DC, 2 reboots, HTCondor install) |
| ws-0 | ~30 min (same) |
| compute-0 | ~30 min (same) |

All four VMs can set up in parallel once the DC is ready.

---

## Step 6 — Verify the HTCondor pool

Connect to the CM:
```bash
aws ssm start-session --target <cm-instance-id> --region us-east-1
```

```powershell
# All nodes should appear
condor_status

# CREDD must be listed
condor_status -any | Select-String "CREDD"

# Verify LocalCredd is NOT UNDEF on the execute node
condor_status -f "%s`t" Name -f "%s`n" LocalCredd

# Expected output:
# compute-0.fort.wow.dev   mgr.fort.wow.dev
# (any UNDEF = pool password not stored on that node or CREDD not up)
```

If `LocalCredd` shows UNDEF on compute-0, re-run from compute-0:
```powershell
condor_store_cred add -c -p <your-pool-password>
condor_reconfig
# Wait 60 seconds, then re-check condor_status
```

---

## Step 7 — Run the test job as brandon

### 7a. Verify brandon's credential is stored

From the CM (mgr):
```powershell
condor_store_cred query 2>&1    # should list brandon@fort.wow.dev
```

If missing, store it manually from ws-0:
```powershell
# On ws-0 (connect via SSM):
condor_store_cred add -u brandon@fort.wow.dev -p <brandon-password>
```

### 7b. Submit the job

Connect to the submit node (ws-0):
```bash
aws ssm start-session --target <submit-instance-id> --region us-east-1
```

Inside the SSM session you are running as SYSTEM. Switch to brandon's context
to properly exercise run_as_owner:

```powershell
# Get brandon's password from SSM Parameter Store (admin convenience)
$pw = aws ssm get-parameter --name "/htcondor-poc/brandon-password" `
        --with-decryption --query Parameter.Value --output text

# Launch a process as brandon
$cred = New-Object System.Management.Automation.PSCredential(
    "FORTWOW\brandon",
    (ConvertTo-SecureString $pw -AsPlainText -Force)
)
Start-Process cmd.exe -Credential $cred -ArgumentList `
    "/K cd C:\HTCondorConfig && condor_submit test-brandon.sub" `
    -WorkingDirectory "C:\HTCondorConfig" -Wait
```

Or use `runas` interactively:
```cmd
runas /user:FORTWOW\brandon cmd.exe
# In the new window:
cd C:\HTCondorConfig
condor_submit test-brandon.sub
```

### 7c. Watch the job

```powershell
condor_q                          # should show job in I (idle) → R (running)
condor_q -format "%d\n" ClusterId -format "%s\n" JobStatus
```

### 7d. Verify the result

After the job completes (`condor_q` shows empty):

```powershell
# On ws-0 or compute-0 — the proof file is on the FSx share:
$fsx = aws ssm get-parameter --name "/htcondor-poc/fsx-dns" --query Parameter.Value --output text
net use S: "\\$fsx\share"
Get-Content S:\brandon-test.txt
# Expected: "Written by FORTWOW\brandon on COMPUTE-0 at ..."
dir S:\
```

The job wrote to FSx as `brandon` — proving impersonation worked end-to-end.

---

## Troubleshooting

### job goes on hold: "Could not locate valid credential"
- Pool password not stored on compute-0: run `condor_store_cred add -c -p <pw>` on compute-0
- UID_DOMAIN mismatch: confirm `fort.wow.dev` (not `FORTWOW`) on all nodes
- Credd not running: check `condor_status -any | grep -i credd`

### LocalCredd = UNDEF
- Usually means CREDD started after STARTD. Verify `02-execute.conf` has `DAEMON_LIST = MASTER, CREDD, STARTD` (CREDD before STARTD)
- Run `condor_reconfig -all` and wait 60 seconds

### job goes on hold: "Failed to initialize user_priv as (null)\brandon"
- UID_DOMAIN is wrong — check that all nodes have `UID_DOMAIN = fort.wow.dev`

### condor_store_cred fails with "FAILURE_NOT_SECURE"
- `SEC_CONFIG_ENCRYPTION = REQUIRED` not set — confirm `00-common.conf` is loaded
- Run `condor_config_val SEC_CONFIG_ENCRYPTION` on the node to verify

### Domain join fails (Add-Computer error)
- DC not yet ready — check `C:\SetupStage.txt` on dc (needs to be `99`)
- DNS not pointing to DC — run on the failing node:
  ```powershell
  $nic = Get-NetAdapter | Where-Object { $_.Status -eq 'Up' } | Select-Object -First 1
  Set-DnsClientServerAddress -InterfaceIndex $nic.ifIndex -ServerAddresses @("10.0.1.10","169.254.169.253")
  ```
  Then re-run the setup script manually.

### SSM session won't open ("Target ... not connected")
- Instance may still be booting (allow 5 min after `terraform apply`)
- Check instance state in EC2 console
- SSM agent must be running; it's pre-installed on the Amazon Windows 2022 AMI

### How to re-run a setup stage manually
```powershell
# Set stage back to the one you want to re-run (e.g. stage 2)
Set-Content C:\SetupStage.txt 2
# Then run the script directly:
& C:\setup-cm.ps1 -Bucket <bucket-name> -Region us-east-1
```

---

## Connecting via RDP (optional)

If you prefer a GUI session, use SSM port forwarding instead of opening RDP
to the internet:

```bash
# Forwards local port 13389 → instance port 3389
aws ssm start-session --target <instance-id> --region us-east-1 \
    --document-name AWS-StartPortForwardingSession \
    --parameters '{"portNumber":["3389"],"localPortNumber":["13389"]}'
```

Then open Remote Desktop to `localhost:13389`.
Username: `Administrator` (pre-domain-join) or `FORTWOW\Administrator` (post-join).
Password: the `admin_password` from your `terraform.tfvars`.

---

## Teardown

When finished testing:
```bash
terraform destroy
```

This destroys everything including the S3 bucket, FSx, all instances, and all
networking. The `htcondor-poc-key.pem` file remains locally.

Estimated cost if you forget to destroy and leave it running overnight (~8 hr): ~$2.
