# Deploy — v3 Minimal HTCondor Install

This tag adds the HTCondor install itself. After apply:

- **mgr** runs HTCondor as CM + CREDD and hosts the SMB share used by jobs.
- **ws-0** runs the submit node (SCHEDD).
- **compute-0** runs the execute node (STARTD + local CREDD cache).
- The pool password is stored on every HTCondor node so daemon-to-daemon
  auth works. A test job (`test-brandon.sub`) is staged on submit and
  execute for you to try.

The configs in this tag match the initial setup from mid-April 2026 —
they *wire up* run_as_owner (STARTER_ALLOW_RUNAS_OWNER, CREDD_CACHE_LOCALLY,
CREDD.COLLECTOR_HOST=127.0.0.1 on execute, etc.) but they do NOT yet
include the fixes needed to actually *complete* a run_as_owner job. That's
what v4 does. Submitting the test job at v3 will get to "Jobs started"
but the job will be held by the starter with a credential-lookup error.

## What's new vs. v2

| Area | Change |
|------|--------|
| scripts | `cm`, `submit`, `execute` setup scripts grow stage 2: MSI download, HTCondor install, config placement, pool-password store |
| scripts | `submit-setup.ps1` also stores `brandon@fort.wow.dev` from SYSTEM context (this is one of the things v4 fixes — it currently fails) |
| configs | `htcondor/*.conf` uploaded to `s3://<bucket>/htcondor/` (4 files) |
| jobs | `jobs/test-brandon.{sub,bat}` uploaded to `s3://<bucket>/jobs/` |
| terraform | new var `htcondor_pool_password`; new SSM params `htcondor-pool-password`, `share-host` |
| CM setup | creates SMB share `\\mgr.fort.wow.dev\share` backed by `C:\HTCondorShare` |

**Estimated cost while running:** ~$0.20/hr.

---

## Step 1 — Prerequisites

Complete `prerequisites.md` first. You need the HTCondor 23.4.0 MSI
downloaded locally.

---

## Step 2 — Create terraform.tfvars

```bash
cd htcondor-poc/terraform
cp terraform.tfvars.example terraform.tfvars
```

Fill in:

- `admin_password` — local Administrator / AD Administrator password
- `brandon_password` — password for the `brandon` domain user
- `htcondor_pool_password` — HTCondor shared secret (≥8 chars, any ASCII)
- `domain_name`, `domain_netbios` — defaults fine
- `htcondor_msi_s3_key` — default fine if your MSI will be at
  `installers/condor-23.4.0-Windows-x64.msi`

---

## Step 3 — Deploy infrastructure

```bash
terraform init
terraform apply
```

**Wall time:** ~5 minutes.

---

## Step 4 — Upload the HTCondor MSI

Upload your local MSI to the S3 key that matches `htcondor_msi_s3_key`:

```bash
aws s3 cp /path/to/condor-23.4.0-Windows-x64.msi \
  s3://$(terraform output -raw s3_bucket)/installers/condor-23.4.0-Windows-x64.msi \
  --region us-east-1
```

The setup scripts retry the MSI download for up to 10 minutes, so you can
upload before or shortly after `terraform apply` finishes — whichever is
more convenient.

---

## Step 5 — Wait for setup to complete

Expected timings, serial:

| Node | Completes in |
|------|--------------|
| DC | ~15 min (AD install + forest promotion + 2 reboots) |
| mgr, ws-0, compute-0 | ~25 min after DC is done (domain join + MSI install) |

Watch any node via SSM:

```bash
aws ssm start-session --target $(terraform output -raw instance_ids | jq -r .cm) --region us-east-1
```

```powershell
Get-Content C:\HTCondorSetup.log -Tail 80
Test-Path C:\SetupComplete.txt   # True when done
```

Once all four `SetupComplete.txt` markers exist, verify the pool from mgr:

```powershell
& 'C:\condor\bin\condor_status.exe' -any
```

You should see entries for the collector, negotiator, schedd (ws-0),
startd (compute-0), and two credd records (mgr's and compute-0's local).

---

## Step 6 — Try the test job (expected to NOT complete at v3)

On ws-0 (submit node):

```bash
aws ssm start-session --target $(terraform output -raw instance_ids | jq -r .submit) --region us-east-1
```

```powershell
runas /user:FORTWOW\brandon cmd.exe
# Inside the runas shell:
cd C:\HTCondorConfig
C:\condor\bin\condor_submit.exe test-brandon.sub
C:\condor\bin\condor_q.exe
```

At v3 the job will be submitted but will end up **held** by the starter
with a message like `Could not locate valid credential` or
`TARGET.LocalCredd did not match`. That's exactly what v4 fixes — see
its DEPLOY.md and `POC-REPORT.md` for the six root causes.

---

## Teardown

```bash
terraform destroy
```

---

## What's next

v4-run-as-owner-fixes bakes in the six fixes that make the held job
complete successfully and produce `S:\brandon-test.txt`.
