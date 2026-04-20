# Deploy — v2 AD + Staged Artifacts

This tag adds **Active Directory** and a **script-fetching bootstrap** on
top of the v1 infrastructure. After apply the four instances rename
themselves, set DNS to the DC, and domain-join `fort.wow.dev` — but
**HTCondor is not yet installed**. That comes at v3.

## What gets built on top of v1

| VM | Final hostname | State at v2 |
|----|----------------|-------------|
| dc | DC | AD DS installed, `fort.wow.dev` forest, OUs `HTCondorPoc/{Users,Computers}`, `brandon` domain user, DNS forwarder to AmazonDNS |
| mgr | MGR | domain-joined, idle (no HTCondor yet) |
| ws-0 | WS-0 | domain-joined, idle |
| compute-0 | COMPUTE-0 | domain-joined, idle |

New Terraform resources vs. v1:

- S3 uploads of the four role setup scripts (`scripts/dc-setup.ps1`,
  `scripts/cm-setup.ps1`, `scripts/submit-setup.ps1`,
  `scripts/execute-setup.ps1`).
- Extra SSM parameters: `domain-name`, `domain-netbios`,
  `brandon-password`, `htcondor-msi-key`.
- `user_data` now downloads and runs the role script, and registers a
  scheduled task so setup resumes automatically across the reboots that
  AD promotion and domain-join each require.

**Estimated cost while running:** ~$0.20/hr (same as v1 — same four EC2
instances).

---

## Step 1 — Prerequisites

Complete `prerequisites.md` first. At v2 you DO need the HTCondor MSI
downloaded locally — you'll upload it in step 4 below.

---

## Step 2 — Create terraform.tfvars

```bash
cd htcondor-poc/terraform
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars` and fill in:

- `admin_password` — 12+ chars, complexity-compliant. Local Administrator
  password on every VM AND the AD Administrator password after DC
  promotion.
- `brandon_password` — 12+ chars, complexity-compliant. Password for the
  `brandon` domain user (a regular, non-admin user).
- `domain_name` / `domain_netbios` — defaults (`fort.wow.dev` / `FORTWOW`)
  are fine unless you want to change them.
- `htcondor_msi_s3_key` — S3 key where you'll upload the MSI. Default
  `installers/condor-23.4.0-Windows-x64.msi`.

---

## Step 3 — Deploy infrastructure

```bash
terraform init
terraform apply
```

Terraform creates everything from v1 plus the new S3 script uploads and
SSM parameters. The instances boot, run the `v2` bootstrap, download
their role script from S3, and begin the rename → domain-join dance.

**Wall time for Terraform:** ~5 minutes.

---

## Step 4 — Upload the HTCondor MSI

Even though v2 doesn't install HTCondor, we stage the MSI now so v3 can
find it. Uploading it now also confirms your S3 path is correct.

```bash
aws s3 cp /path/to/condor-23.4.0-Windows-x64.msi \
  s3://$(terraform output -raw s3_bucket)/installers/condor-23.4.0-Windows-x64.msi \
  --region us-east-1
```

Verify:

```bash
aws s3 ls s3://$(terraform output -raw s3_bucket)/installers/
```

---

## Step 5 — Wait for DC promotion + domain joins

The DC needs ~15 minutes to rename, install AD DS, promote the forest,
and reboot twice. The other three nodes block on the DC's LDAP port
before domain-joining, then reboot and sit idle.

Watch progress via SSM:

```bash
aws ssm start-session --target $(terraform output -raw instance_ids | jq -r .dc) --region us-east-1
```

```powershell
Get-Content C:\HTCondorSetup.log -Tail 50
Test-Path C:\SetupComplete.txt    # True when DC is done
```

Once the DC shows complete, the other three will finish their joins
within another ~5 minutes. Check each:

```powershell
(Get-WmiObject Win32_ComputerSystem).Domain   # should show fort.wow.dev
Test-Path C:\SetupComplete.txt                # True when v2 work is done
```

---

## Teardown

```bash
terraform destroy
```

`force_destroy = true` on the artifacts bucket lets Terraform empty it
(including the MSI you uploaded) before deleting.

---

## What's next

v3-minimal-install installs HTCondor with the default pool / CM / submit /
execute layout. The configs it uses are intentionally minimal — no
LocalCredd, no CREDD_PORT override, no run_as_owner yet. v4 layers on
the fixes that make run_as_owner actually work.
