# HTCondor `run_as_owner` PoC on AWS — Team Report

**Date:** 2026-04-20
**Outcome:** ✅ End-to-end success. A job submitted as `FORTWOW\brandon` ran on compute-0 under brandon's identity and wrote a file to the CM's SMB share with owner `FORTWOW\brandon`.
**Repo state:** reproducible from `terraform apply` — all live fixes are baked into `htcondor-poc/`. Two commits on `main`: `f5a0ddf` (initial), `4cdfee2` (the full fix set below).

---

## 1. What we were trying to prove

HTCondor's `run_as_owner = True` impersonates the submitting Windows domain user on the execute node, rather than running the job as the HTCondor service account. For file-ownership-sensitive workloads (shared storage, audit logs, Kerberos-backed SMB), this is the only correct mode. We wanted to confirm it works end-to-end on HTCondor 23.4 on Windows Server 2022 in a fresh AD-joined pool.

## 2. Architecture

Four Windows Server 2022 EC2 instances in a private subnet in `us-east-1`, reachable only via SSM Session Manager:

| Node | Role | IP |
|---|---|---|
| `dc` | AD DC + DNS for `fort.wow.dev` / `FORTWOW` | 10.0.1.10 |
| `mgr` | HTCondor CM (collector, negotiator, credd) + SMB share | 10.0.1.11 |
| `ws-0` | Submit node (schedd) — brandon's daily-use box | 10.0.1.12 |
| `compute-0` | Execute node (startd, local credd) | 10.0.1.13 |

Setup is Terraform-driven: scripts + configs shipped to an S3 bucket, pulled down on first boot, scheduled task drives multi-stage setup across reboots.

## 3. The biggest problems (what actually burned time)

### 🔴 Problem 1 — HTCondor enforces "self-store" on `condor_store_cred`

**Symptom:** every attempt to store brandon's credential from an Administrator or SYSTEM session failed with `DENIED` / `FAILURE_NOT_SECURE`, even though those identities have CONFIG-level authorization.

**Root cause:** `store_cred_handler` in HTCondor 23.x has an undocumented check that the **authenticated user's base name must equal the target user's base name**. Admin rights don't bypass it. This means:
- Setup scripts (running as SYSTEM via SSM) **cannot store brandon's credential on brandon's behalf**.
- Interactively: Administrator cannot store brandon's cred either.
- Only a process authenticated *as brandon* can store brandon's credential.

**Fix (now automated):** `cm-setup.ps1` and `execute-setup.ps1` register a short-lived scheduled task that runs *as brandon*, invokes `condor_store_cred`, and writes the result to a file we then read back. This requires:
- `SeBatchLogonRight` granted to brandon's SID (via `secedit /export` → edit → `/import` + `/configure`).
- `icacls BUILTIN\Users:(R)` on `C:\condor\condor_config` and `C:\ProgramData\HTCondor\config.d` so brandon can read config.
- `_CONDOR_CREDD_HOST` env var inside the task pointing at the full sinful string (bypasses collector lookup).

### 🔴 Problem 2 — HTCondor 23.4 on Windows does NOT auto-publish `LocalCredd` on the startd

**Symptom:** jobs submitted as brandon sat idle forever. `condor_q -better-analyze` showed the slot requirement `TARGET.LocalCredd is "<sinful>"` was unmatched even though `condor_status -any` listed a CREDD in the collector.

**Root cause:** on Windows 23.4, the startd does NOT auto-populate its `LocalCredd` ClassAd attribute from the collector's CREDD advertisement, despite the documentation suggesting otherwise. The attribute stayed `UNDEF` and `run_as_owner` jobs could not be matched to any slot.

**Fix (now automated):** `02-execute.conf` declares `STARTD_ATTRS = $(STARTD_ATTRS) LocalCredd`, and `execute-setup.ps1` resolves `mgr.fort.wow.dev` at setup time and writes `04-localcredd.conf` containing:
```
LocalCredd = "<10.0.1.11:9620?addrs=10.0.1.11-9620&alias=MGR.fort.wow.dev>"
```
Hours were lost on this one; the config-val output showed `LocalCredd=UNDEF` while `condor_status -any` happily showed a CREDD ad, so the problem looked network-level when it was actually a missing attribute publish.

### 🔴 Problem 3 — NetBIOS vs DNS domain identity split

**Symptom:** `condor_submit` on ws-0 got `SECMAN:2010: Received "DENIED" from server for user brandon@fortwow using method NTSSPI`. All our ALLOW_* lists had `*@fort.wow.dev`.

**Root cause:** Windows NTSSPI authentication maps a domain user to the **NetBIOS** domain (`fortwow`), not the DNS FQDN (`fort.wow.dev`). HTCondor's authorization matcher is string-based: `brandon@fortwow` ≠ `brandon@fort.wow.dev`, so even though the intent is identical, every ALLOW_* list silently rejects NetBIOS-authenticated users.

Compounded by: **credentials are also keyed by the full `user@domain` string**, so the credd has to have `brandon@FORTWOW` AND `brandon@fort.wow.dev` stored separately — the schedd on ws-0 identifies the submitter as `brandon@FORTWOW` (NetBIOS), but other code paths look up by UID_DOMAIN (`fort.wow.dev`).

**Fix (now automated):** every ALLOW_* list in `00-common.conf` lists both forms (`*@fort.wow.dev, *@fortwow`), `CREDD.ALLOW_CONFIG` on the CM allows both, and the self-store scheduled task stores brandon's credential under both `brandon@FORTWOW` and `brandon@fort.wow.dev`, on **both** the CM credd AND compute-0's local credd (because `CREDD_CACHE_LOCALLY=True` means the starter only ever consults the local one at job-start time).

### 🟠 Problem 4 — `UNREGISTERED COMMAND 479` from the master

**Symptom:** `condor_store_cred` reported `no classad from server`. Master log on the CM showed `UNREGISTERED COMMAND!` on port 9620.

**Root cause:** HTCondor 23.x's default uses `USE_SHARED_PORT = True`, which routes all incoming connections through the master on port 9618. Command 479 (STORE_CRED) isn't registered on the shared-port path; the master closes the connection. Clients that bypass the collector (new behavior in 23.x) target port 9620 directly, but with shared port the master still owns 9620 and doesn't know what to do.

**Fix (now in config):** on any credd-hosting node, set `CREDD.USE_SHARED_PORT = False` + `CREDD_PORT = 9620` — this makes the master delegate port-9620 connections to the credd subprocess. Clients also need `_CONDOR_CREDD_HOST` set to the full sinful string so they skip the collector lookup entirely.

### 🟠 Problem 5 — Local credd "hijacking" the central credd ad

**Symptom:** after adding a local credd on compute-0 (for `CREDD_CACHE_LOCALLY`), `condor_status -any` showed only one CREDD entry — and it was compute-0, not mgr. `condor_store_cred` from a client then tried compute-0 instead of mgr.

**Root cause:** a credd advertises into the collector under `Name = <DNS-hostname>`. Both mgr and compute-0 were advertising with `Name = mgr.fort.wow.dev` because `CREDD_HOST = mgr.fort.wow.dev` was global — the local credd inherited the central credd's identity and overwrote its ad.

**Fix:** set `CREDD.COLLECTOR_HOST = 127.0.0.1` on execute nodes. The local credd still advertises (into its own local collector, which nobody reads), but the central collector on mgr keeps mgr's CREDD ad intact. The startd discovers the local credd via the local master, not via the collector — so this doesn't break anything.

### 🟠 Problem 6 — SSM / PowerShell / bash password eating

**Symptom:** passwords containing `$` (brandon's password was `HTCond0r$ecret!42`) silently became `HTCond0rcret!42` or empty string by the time they reached Windows.

**Root cause:** every interpolation step is a chance to lose characters. `aws ssm send-command --parameters 'commands=["condor_store_cred add -p $ecret!42"]'` — bash eats `$ecret`. Nesting bash → JSON → PowerShell doubles the escape surface.

**Fix:** never interpolate passwords through bash double-quotes. Write the `.ps1` file on the Mac (Python `str` or bash single-quoted heredoc), upload to S3, pull down via `AWS-RunRemoteScript`. Inside PowerShell, always single-quote strings containing `$`.

Also: ws-0 has no AWS CLI installed, so `aws s3 cp` fails inline. Use the `AWS-RunRemoteScript` SSM document with `sourceType=S3` — SSM downloads the script itself. Note: its `CommandPlugins` output only shows "Content downloaded to …" — actual script stdout is NOT captured, so scripts must write results to a file (`C:\Users\Public\…`) and a second SSM call fetches them.

## 4. What's baked into the repo now

`htcondor-poc/` is authoritative. A fresh `terraform destroy && terraform apply` reproduces the working pool:

- **`htcondor/00-common.conf`** — `*@fort.wow.dev` AND `*@fortwow` in every ALLOW_\*; `IDTOKENS, PASSWORD, NTSSPI` auth methods; `SEC_CONFIG_*` explicitly REQUIRED.
- **`htcondor/01-cm.conf`** — `CREDD_PORT = 9620`, `CREDD.USE_SHARED_PORT = False`, `CREDD.ALLOW_CONFIG` with both domain forms.
- **`htcondor/02-execute.conf`** — `DAEMON_LIST = MASTER, CREDD, STARTD` (order matters: credd must be registered before startd comes up); `CREDD.COLLECTOR_HOST = 127.0.0.1`; `STARTD_ATTRS = $(STARTD_ATTRS) LocalCredd`.
- **`scripts/cm-setup.ps1`** — grants `SeBatchLogonRight` + `icacls BUILTIN\Users:(R)`; self-stores brandon's cred on the CM credd via scheduled-task-as-user.
- **`scripts/execute-setup.ps1`** — resolves mgr IP at runtime, writes `04-localcredd.conf`; same self-store pattern for the LOCAL credd.
- **`scripts/submit-setup.ps1`** — removed the SYSTEM-context cred store that was always denied. Submit nodes only need the pool password.
- **`DEPLOY.md`** — rewritten verification steps and a full troubleshooting section covering every failure mode above, plus a Security caveats section.

## 5. Known caveats (deliberate PoC tradeoffs)

- **Password on disk.** The self-store scheduled task is backed by `C:\CredStoreAsUser.ps1`, which contains brandon's password in cleartext and has `BUILTIN\Users:(R)` so the scheduled-task runtime can read it. The task is unregistered after it runs, but the file remains. For production, this file should be deleted post-setup, or the credential-store flow should be performed interactively by the user.
- **`C:\Users\Public\cred-store-result.txt`** contains raw stderr/stdout from `condor_store_cred` and is not deleted after being logged.
- The setup scripts are idempotent *after* the initial install; re-running stage 2 will re-apply icacls/secedit/self-store but will not clean up the artifacts above.

## 6. Takeaways for the team

1. **HTCondor 23.x on Windows is noticeably rougher than on Linux.** Auto-publish of `LocalCredd`, the shared-port credd routing, and the self-store check all behave differently or are poorly documented. Budget extra time for Windows-specific debugging.
2. **Authorization strings are literal.** NetBIOS vs DNS is not aliased — every ALLOW_\* list needs both forms, and credentials need to be stored under both forms, on every credd a starter might query.
3. **`CREDD_CACHE_LOCALLY = True` changes where credentials are read.** Stores on the CM credd are useless if the starter checks only the local credd. Either disable local caching or replicate the store to every execute node.
4. **The password-via-bash-via-SSM pipeline is a trap.** Always ship script files through S3 for any workflow involving secrets. Inline `--parameters` should be treated as plaintext and credential-free.
5. **HTCondor logs need to be read in order.** CREDD log showed `DENIED` because `store_cred_handler` rejected cross-user stores, but that message was buried between unrelated `D_SECURITY` chatter; the shorter-path clue was the `UNREGISTERED COMMAND 479` in the master log, which pointed at a completely different config fix.

---

*Source of truth: commits `f5a0ddf` and `4cdfee2` on `main` in the `claude-htcondor-1` repo.*
