# HTCondor 23.4 → 25.0.9 LTS Upgrade Analysis

**Subject:** What upgrading the Windows `run_as_owner` PoC from HTCondor 23.4 to the current LTS (25.0.9) would fix, what it wouldn't, and why.
**Date:** 2026-04-21.
**Scope:** Targeted against the six problems documented in `POC-REPORT.md` / `POC-STAKEHOLDER-REPORT.md` / `POC-DESIGN-ANALYSIS.md`. Verified against upstream source at tags `v23.4.0`, `v24.4.0`, `v24.12.19`, `v25.0.9`, and the feature-track tip `v25.8.2`.
**TL;DR:** 25.0.9 removes exactly one of the three genuine workarounds (the big one — shared-port credd). The NetBIOS/DNS identity mismatch and the Windows-installer ACL lockdown are **not fixed, not acknowledged, not on anyone's radar upstream**.

---

## 1. Version landscape as of 2026-04-21

| Track | Latest version | Released | Role |
|---|---|---|---|
| **25.0 LTS** | **25.0.9** | 2026-04-16 | **Current LTS, upgrade target** |
| 24.12 LTS | 24.12.19 | 2026-04-16 | Prior LTS (still supported) |
| 24.0 LTS | 24.0.19 | 2026-04-16 | Original 24.x LTS (still supported) |
| 25.x feature | 25.8.2 | 2026-04-16 | Current feature-track tip |
| 23.0 LTS | 23.0.x | (EOL-track) | Our current deployment's LTS lineage |

Release-plan reference: [htcondor.org/htcondor/release-plan](https://htcondor.org/htcondor/release-plan/).

### A correction to prior reports

`POC-STAKEHOLDER-REPORT.md` twice claims the upgrade target should be "HTCondor 24.4+ LTS." That framing is wrong:

- **24.4 is a feature release, not an LTS release.** The LTS branches are 24.0 and 24.12 (and now 25.0). Upgrading to "24.4+ LTS" is not a thing you can do — you'd be on the feature track, not LTS.
- The fix we care about (HTCONDOR-2763, detailed below) shipped in **24.4.0 feature** and was **not back-ported to the 24.0 LTS line**. It *is* present in 24.12 LTS and 25.0 LTS.
- The correct upgrade target is therefore **25.0 LTS** (equivalently, the still-supported **24.12 LTS**, if staying on the previous major is preferred).

### A second correction to prior reports

Prior reports cite **HTCONDOR-2721** as the shared-port credd fix. That ticket number is wrong. HTCONDOR-2721 is an unrelated ticket about "Avg/Total TransferInput/Output MB attributes on the Startd ad" (merged Jan 2025 via commit `82c43ae1`). The real ticket for our fix is **HTCONDOR-2763**.

### A third correction to prior reports

Prior reports imply HTCONDOR-3281 improves the startd-side `LocalCredd` advertisement. It does not. Its release-notes scope is strictly the **submit → schedd → credd** path for the Kerberos local-issuer case (generalized to all credential types by HTCONDOR-3536 in the 25.x-feature line). The `LocalCredd` attribute advertised by the startd to the collector is governed by different code that has not changed since 2009.

---

## 2. Per-problem verdict

Mapped to the six problems from `POC-STAKEHOLDER-REPORT.md`. The first three are genuine upstream issues; the last three are "we misread the docs" and apply regardless of version.

### Problem 1 — Credd + shared_port incompatibility (genuine) — **FIXED in 24.4.0 feature and 25.0 LTS**

**What we hit in 23.4:**
```ini
# 01-cm.conf (current workaround)
CREDD_PORT = 9620
CREDD_ARGS = -p $(CREDD_PORT) -f
CREDD.USE_SHARED_PORT = False
```
The credd daemon, run under `condor_master`, refused to participate in HTCondor's shared-port networking. Jobs couldn't store credentials. Workaround: pin credd to its own TCP port.

**Upstream fix:**
- **Ticket:** [HTCONDOR-2763](https://github.com/htcondor/htcondor/pull/3035) — "credd uses shared port"
- **PR:** [htcondor/htcondor#3035](https://github.com/htcondor/htcondor/pull/3035), merge commit `832dbaec`, author Greg Thain, merged **2024-12-10** into branch `V24_4`
- **Core source diff:** commit `0c9062a5` — "Change credd default params to use shared port, not 9620" — a **6-line diff** in `src/condor_utils/param_info.in` that simply **removes** the `[CREDD_PORT]` and `[CREDD_ARGS]` default-params blocks entirely
- **Docs diff:** commit `2a84bb9a`
- **First shipped release:** **24.4.0** (2025-02-06)
- **Backport status:** Present in 24.12 LTS, present in all 25.0 LTS releases. **NOT present in 24.0 LTS** (`v24.0.19` still contains the old hardcoded defaults).

**Verification performed:**
- Fetched `src/condor_utils/param_info.in` from the `v25.0.9` tag directly — confirmed **no `CREDD_PORT` or `CREDD_ARGS` default-params blocks exist**. Credd now uses `condor_shared_port` transparently.
- Release-notes text from `docs/version-history/v24-version.hist` under `*** 24.4.0 features`: *"The condor_credd daemon no longer listens on port 9620 by default, but rather uses the condor_shared_port daemon. :jira:`2763`"*

**What you delete after upgrading to 25.0.9:**
```ini
# 01-cm.conf — remove all three lines:
CREDD_PORT = 9620                     # delete
CREDD_ARGS = -p $(CREDD_PORT) -f      # delete
CREDD.USE_SHARED_PORT = False         # delete
```
Net: credd rides `condor_shared_port` like every other daemon. The hand-crafted port block disappears. Cascading symptoms documented in `POC-DESIGN-ANALYSIS.md` §Problem 2 (the `LocalCredd` auto-publish failures that we had masked by hand-pinning the attribute) should also resolve, which — if combined with the misread-cleanup for Problems 4–6 below — lets us delete the manual `STARTD_ATTRS = $(STARTD_ATTRS) LocalCredd` pin as well.

---

### Problem 2 — NetBIOS vs DNS domain mismatch on Windows (genuine) — **NOT FIXED, NOT ACKNOWLEDGED**

**What we hit in 23.4:**
Windows NTSSPI authentication identifies users as `brandon@FORTWOW` (NetBIOS short-name form), but HTCondor's authorization matcher does byte-literal string comparison against whatever appears in the allow-lists. If the allow-list says `brandon@fort.wow.dev` (FQDN form), `brandon@FORTWOW` fails to match. There is no alias mechanism, no domain-normalization pass, no case-insensitive short-to-long mapping. Workaround: list **both** forms in every allow-list, for every principal we care about (users plus machine principals).

**Upstream fix search results — all negative:**

- `gh search commits --repo htcondor/htcondor NetBIOS` between 2024-06 and 2026-04: **zero hits**.
- `gh search commits --repo htcondor/htcondor SSPI` across the 23 → 25 range: all SSPI commits are from **1999–2011**. The last substantive SSPI commit is `84ceb35f` in 2011: "call setAuthenticatedName for SSPI so that CERTIFICATE_MAPFILE can actually map something." No SSPI-authenticator changes have been made in 23, 24, or 25.
- No `UID_DOMAIN` aliasing / no `CERTIFICATE_MAPFILE`-for-NTSSPI enhancement in any 24.x or 25.x release-notes file.
- htcondor-users mailing-list archive (2025-01 through 2026-04): no threads matching NetBIOS/DNS domain-form mismatch. The archive returns only 2007–2018 hits, and none match our scenario.
- htcondor-devel: same — silent.

**Conclusion:** Nobody has filed this upstream. There is no open ticket. There is no discussion. Upstream has not been asked.

**What stays after upgrading to 25.0.9:**
Everything. The workaround — listing both `brandon@FORTWOW` and `brandon@fort.wow.dev` (and every machine principal in both forms) in `ALLOW_READ`, `ALLOW_WRITE`, `ALLOW_DAEMON`, `ALLOW_ADVERTISE_*`, etc. — remains required.

**If we want this fixed,** we file the ticket. A clean bug report with a minimal repro (Windows domain join + NTSSPI auth attempt against a DNS-form allow-list) would likely get traction. The fix is probably non-trivial (the matcher is called from many sites and changing it has pool-wide semantic implications), but a first-class aliasing mechanism is a reasonable ask. Until someone files it, this is forever.

---

### Problem 3 — Windows installer locks down `condor_config` (genuine) — **NOT FIXED, NOT ACKNOWLEDGED**

**What we hit in 23.4:**
The HTCondor Windows MSI installs `C:\condor\condor_config` with an ACL that breaks inheritance and denies read access to non-admin users. After a fresh install, a domain user like `brandon` cannot read the config file, which means `condor_submit` (and any other user-run client) can't initialize HTCondor. We fix this manually with:
```powershell
icacls C:\condor\condor_config /grant "FORTWOW\brandon:(F)" /C
```
(or the broader `Users:(R)` equivalent) on every machine post-install. We hit the same issue recursively inside `C:\condor` and had to discover that `/T` silently skips files with inheritance-disabled standalone ACLs, forcing per-file grants.

**Upstream fix search results — all negative:**

- `gh search commits --repo htcondor/htcondor icacls`: zero hits in the 23 → 25 range.
- `gh search commits --repo htcondor/htcondor msi`, `WiX`, `wxs`, `condor_config ACL`: zero relevant hits.
- Windows-specific changes in 24.x / 25.x are peripheral and touch neither the installer nor config-file ACLs. The landing ones are:
  - **HTCONDOR-3578** — Kerberos library updated to 1.22 (25.8 feature only, not in 25.0 LTS)
  - **HTCONDOR-3207** — Python 3.12+ build support
  - **HTCONDOR-3492** — MSBUILD parallelism improvement
  - **HTCONDOR-3179** — an `ImageSize` fix on Windows
  - **HTCONDOR-3247** — `ornithology` test-framework port to Windows
  - **HTCONDOR-3662** — rare `strncpy` bug fix in `store_cred` on Windows, merged 2026-04-17 into V25_10 branch, post-25.0.9 (will appear in 25.0.10)
- None touch installer ACLs or default config-file permissions.

**Conclusion:** No commits, no tickets, no mailing-list threads about this in the relevant timeframe. The MSI still installs a locked-down config file in 25.0.9.

**What stays after upgrading to 25.0.9:**
The `icacls` post-install grant. Same "we'd have to file it" path as Problem 2.

---

### Problems 4–6 — Our misreads of the documentation — **IRRELEVANT to version upgrade**

These three were never HTCondor bugs; they were things we did wrong. The fixes are:

4. **Use `CRED_SUPER_USERS = SYSTEM, Administrator`** instead of the scheduled-task-as-brandon scaffolding. This macro has been in the codebase for years and is documented in the configuration-macros reference. Upgrading neither adds nor removes it — it already works in 23.4.
5. **Remove the manual `STARTD_ATTRS = $(STARTD_ATTRS) LocalCredd` pin.** The `credd_test()` periodic NOP probe has auto-published the attribute for years. It was failing in 23.4 for us because of the cascading shared-port credd issue (Problem 1). After fixing Problem 1 (via upgrade), this auto-publish *should* start working without the manual pin. We'll want to verify this in a test environment post-upgrade — if for any reason the auto-publish still misfires on 25.0.9, the manual pin is a safe fallback.
6. **Use `CREDD_CACHE_LOCALLY = True` with a single pool-wide credd** instead of running a second credd daemon on each execute node. This has been the documented approach since long before 23.x. Fixing this is a pure config change: `DAEMON_LIST = MASTER, STARTD` (was: `MASTER, CREDD, STARTD`), and delete the now-unneeded `CREDD.COLLECTOR_HOST` / `CREDD.USE_SHARED_PORT` / `CREDD_PORT` lines from `02-execute.conf`.

---

## 3. Other Windows / run_as_owner-relevant changes in 24.0 → 25.0.9

A scan of `docs/version-history/v24-version.hist` and `v25-version.hist` in the `v25.0.9` tree for subsystems touching credd, store_cred, SSPI, Windows auth, and run_as_owner:

| Ticket | Summary | Shipped | PoC impact |
|---|---|---|---|
| **HTCONDOR-2763** | credd uses shared_port (detailed above) | 24.4.0, 25.0.0 | **Direct** — removes 3 workaround lines |
| **HTCONDOR-3281** | schedd includes credd address in its ClassAd and address file; Kerberos local-issuer uses it instead of collector lookup | 25.0.0 (via #3683 cherry-pick), 24.12 (via #3747 cherry-pick) | **Tangential** — helps the submit→credd discovery path; does not affect startd-side `LocalCredd` advertisement. Release-notes text: *"The condor_schedd will now include the address of a condor_credd that is running under the same condor_master in its ClassAd and address file. … The Kerberos local issuer will now use this mechanism and no longer query the collector for the address of the condor_credd."* |
| **HTCONDOR-3536** | Generalizes 3281 to all credential types, not just Kerberos | 25.x feature only (not yet in 25.0 LTS) | Future-looking |
| **HTCONDOR-3183** | Fix stack corruption in credd if we cannot talk to the credmon | 24.11+, in 25.0 | **Robustness** — matters if credmon is ever unreachable |
| **HTCONDOR-3116** | Fix memory leak in credd | 24.10+, in 25.0 | Robustness — long-running credd stability |
| **HTCONDOR-3213** | `condor_store_cred add` sets `NeedRefresh` only for oauth creds; legacy password mode was incorrectly failing when the attribute was set unconditionally | 24.0.11+, 25.0 | **Relevant** — our password-cred path in `run_as_owner` uses the legacy mode this fixes |
| **HTCONDOR-2803** | `condor_store_cred add-oauth` now requires a service name (better error message) | 24.x, 25.0 | Not relevant — we don't use OAuth |
| **HTCONDOR-3662** | Rare `strncpy` boundary bug in `src/condor_utils/store_cred.cpp` on Windows | 25.0.10 (expected), not in 25.0.9 | Watch next LTS patch |
| **HTCONDOR-3578** | Kerberos lib updated to 1.22 | 25.8 feature only | Not in 25.0 LTS |
| **HTCONDOR-3207** | Python 3.12+ build support | — | No PoC impact |
| **HTCONDOR-3492** | MSBUILD parallelism | — | Build-time only |
| **HTCONDOR-3179** | `ImageSize` fix on Windows | — | Peripheral |
| **HTCONDOR-3247** | `ornithology` test-framework ported to Windows | — | Testing infra |

Notably **absent** from the entire 24→25 window: any change to Windows SSPI authentication, NetBIOS domain handling, UID_DOMAIN aliasing, the MSI's ACL logic, `run_as_owner` itself, `SeBatchLogonRight` handling, or the startd's `LocalCredd`-via-`credd_test()` publish path.

---

## 4. What the upgrade actually gets you

### Removed config lines (after upgrading and applying the misread-cleanup)

Starting state — current 23.4 PoC configs (abridged to workaround-related lines):
```ini
# 01-cm.conf
CREDD_PORT = 9620
CREDD_ARGS = -p $(CREDD_PORT) -f
CREDD.USE_SHARED_PORT = False
# (plus ALLOW_* lines listing both NetBIOS and FQDN forms — stays)

# 02-execute.conf
DAEMON_LIST = MASTER, CREDD, STARTD
CREDD.COLLECTOR_HOST = 127.0.0.1
CREDD.USE_SHARED_PORT = False
CREDD_PORT = 9620
STARTD_ATTRS = $(STARTD_ATTRS) LocalCredd
LocalCredd = "<hand-pinned sinful string>"
```

Ending state — on 25.0.9 LTS with misread-cleanup applied (additionally adding `CRED_SUPER_USERS` per Problem 4):
```ini
# 01-cm.conf
CRED_SUPER_USERS = SYSTEM, Administrator
# (ALLOW_* lines listing both NetBIOS and FQDN forms — still needed, Problem 2 unfixed)

# 02-execute.conf
DAEMON_LIST = MASTER, STARTD
CREDD_CACHE_LOCALLY = True
# (no CREDD_PORT, no CREDD_ARGS, no USE_SHARED_PORT, no STARTD_ATTRS pin, no LocalCredd literal)
```

Roughly 6–8 config lines removed across the pool, plus ~100 lines of PowerShell scaffolding deleted from the misread-cleanup (per `POC-STAKEHOLDER-REPORT.md`).

### What stays required, regardless of version

1. **Dual-listing NetBIOS + FQDN forms** in every HTCondor allow-list for every principal. Problem 2 is not fixed in 25.0.9.
2. **Post-install `icacls` grant** on `C:\condor\condor_config` (and the rest of `C:\condor` / `C:\ProgramData\HTCondor` per user requirements). Problem 3 is not fixed in 25.0.9.
3. **Secrets-pipeline hygiene** — `$` in passwords disappearing through bash/SSM/PowerShell interpolation is an operational problem, not an HTCondor version problem.

---

## 5. Risk assessment for the upgrade

**Upgrade surface (low → moderate):**

- **Major version jump (23 → 25):** two major releases. Upstream's upgrade docs for 24.0→25.0 ([upgrading-from-24-0-to-25-0-versions.rst](https://raw.githubusercontent.com/htcondor/htcondor/v25.0.9/docs/version-history/upgrading-from-24-0-to-25-0-versions.rst)) and for 23→24 ([upgrading-from-23-0-to-24-0-versions.rst](https://raw.githubusercontent.com/htcondor/htcondor/v25.0.9/docs/version-history/upgrading-from-23-0-to-24-0-versions.rst)) should be read end-to-end. Neither is expected to contain a breaking change that affects a 4-node Windows PoC, but it's table-stakes reading.
- **ClassAd / attribute renames or deprecations** in 24.x (e.g., HTCONDOR-2721's transfer-MB attributes) don't affect `run_as_owner`, but would require a brief review if the PoC ever grew a job-script that read StartD ads programmatically.
- **Windows MSI regression risk:** the 25.0.9 MSI is relatively fresh (2026-04-16). No known regressions specific to run_as_owner, but the 25.0.10 patch with HTCONDOR-3662 is coming. If we want the rare `store_cred` `strncpy` fix before deploying, waiting for 25.0.10 is low-cost.
- **Shared-port behavior change:** because credd now *does* speak shared_port, firewall rules that allowed **only** TCP 9620 to the credd node will stop working. In our PoC the firewall is permissive (security-group inside VPC), so this is a non-issue — but a stricter pool would need the firewall rule updated to `SHARED_PORT_PORT` (default 9618).
- **The manual `STARTD_ATTRS = $(STARTD_ATTRS) LocalCredd` pin** could, in principle, stop working if upstream ever tightens the auto-publish mechanism. In practice, removing it is the goal — the pin was masking real issues in our 23.4 setup. On 25.0.9 we expect auto-publish to work unaided. If it doesn't, the pin is a safe fallback.

**What to test post-upgrade:**

1. Credd accepts credentials over shared_port without a hand-pinned port block.
2. The execute-node startd's periodic `credd_test()` NOP probe succeeds and auto-publishes `LocalCredd` in the StartD ad (check `condor_status -l <slot>` for the attribute).
3. `condor_submit run_as_owner = True` jobs submitted by `brandon` match, start, run as `brandon`, and preserve file-ownership semantics end-to-end. Golden path and edge cases (password rotation, user logoff during job, SMB share with NTFS ACLs).
4. `CRED_SUPER_USERS` lets our setup automation store brandon's credential as SYSTEM/Administrator without needing the scheduled-task-as-brandon scaffolding.
5. Dual-listed allow-lists still work (sanity check that nothing changed in the matcher).
6. `condor_submit` runs as a non-admin user (no regression in the `icacls` grant requirement — expected to still be required).

**Rough upgrade effort estimate:**

- Deploy-side: update the Terraform variable `htcondor_msi_s3_key` to the new MSI path, replace the MSI object in S3, re-run `terraform apply`. One setup-script pass. Half a day.
- Verification: end-to-end run_as_owner test suite across all four roles (DC / CM / WS / Compute). One day.
- Misread-cleanup (if bundled): half a day of config edits + another full E2E pass. One day total.

Call it **2 days elapsed** to upgrade + cleanup + verify, for a single-pool 4-node PoC.

---

## 6. Recommendation

**Yes, upgrade — but set expectations correctly.**

- **Do it if:** we want to be on current LTS, delete the shared-port workaround, simplify the config, align with upstream-documented defaults, and pick up the credd robustness fixes (HTCONDOR-3183, HTCONDOR-3116, HTCONDOR-3213) along the way.
- **Don't expect:** the NetBIOS/DNS aliasing problem or the installer-ACL lockdown to go away. They stay.
- **Recommended target:** **25.0.9 LTS now**, or wait a week or two for 25.0.10 to pick up HTCONDOR-3662's `store_cred` `strncpy` fix. Either works; 25.0.9 has been in the wild for 5 days with no known regressions.
- **Recommended sequencing:** apply the misread-cleanup on 23.4 first (removes Problems 4–6 workarounds, confirms nothing regressed), **then** upgrade to 25.0.9 (removes Problem 1 workaround, verifies auto-publish). Doing them in one shot is possible but loses the ability to attribute any regression to the correct change.
- **Upstream contributions to consider filing** after the upgrade:
  - A clean bug report for the NetBIOS/DNS mismatch (Problem 2) with a minimal Windows-domain repro.
  - A clean bug report for the Windows MSI ACL lockdown (Problem 3) with the `icacls` diff we're applying.
  - Doc patches per `POC-STAKEHOLDER-REPORT.md` §Decisions Requested: `CREDD_PORT`/`CREDD_ARGS` reference (now deprecated — trivial patch), NetBIOS/DNS authorization note, LocalCredd auto-publish description.

**The short answer:** upgrading to 25.0.9 LTS deletes one of our three real workarounds (the biggest one). It does not delete the other two, and the other two have no open upstream activity — so if we want them gone, we file the tickets ourselves.

---

## References

**Upstream source (pinned tags):**
- [htcondor/htcondor @ v25.0.9](https://github.com/htcondor/htcondor/tree/v25.0.9)
- [`src/condor_utils/param_info.in` @ v25.0.9](https://raw.githubusercontent.com/htcondor/htcondor/v25.0.9/src/condor_utils/param_info.in) — confirms `CREDD_PORT` / `CREDD_ARGS` default blocks removed
- [`docs/version-history/v24-version.hist` @ v25.0.9](https://raw.githubusercontent.com/htcondor/htcondor/v25.0.9/docs/version-history/v24-version.hist)
- [`docs/version-history/v25-version.hist` @ v25.0.9](https://raw.githubusercontent.com/htcondor/htcondor/v25.0.9/docs/version-history/v25-version.hist)
- [`docs/version-history/upgrading-from-24-0-to-25-0-versions.rst` @ v25.0.9](https://raw.githubusercontent.com/htcondor/htcondor/v25.0.9/docs/version-history/upgrading-from-24-0-to-25-0-versions.rst)
- [`docs/version-history/upgrading-from-23-0-to-24-0-versions.rst` @ v25.0.9](https://raw.githubusercontent.com/htcondor/htcondor/v25.0.9/docs/version-history/upgrading-from-23-0-to-24-0-versions.rst)

**Pull requests and commits:**
- [PR #3035 — HTCONDOR-2763 credd uses shared port](https://github.com/htcondor/htcondor/pull/3035) (merge `832dbaec`, merged 2024-12-10 into V24_4)
- Core commit `0c9062a5` — "Change credd default params to use shared port, not 9620"
- Docs commit `2a84bb9a`
- [PR #3669 — HTCONDOR-3281 credd address in schedd ad](https://github.com/htcondor/htcondor/pull/3669)
- [PR #3683 — HTCONDOR-3281 V25_0 cherry-pick](https://github.com/htcondor/htcondor/pull/3683)
- [PR #3747 — HTCONDOR-3281 V24_12 cherry-pick](https://github.com/htcondor/htcondor/pull/3747)

**Release documentation:**
- [HTCondor 25.0 LTS version-history](https://htcondor.readthedocs.io/en/lts/version-history/lts-versions-25-0.html)
- [HTCondor Release Plans](https://htcondor.org/htcondor/release-plan/)
- [HTCondor 23.0 Windows platform-specific docs](https://htcondor.readthedocs.io/en/23.0/platform-specific/microsoft-windows.html)
- [HTCondor LTS Windows platform-specific docs](https://htcondor.readthedocs.io/en/lts/platform-specific/microsoft-windows.html)

**Mailing-list archives (checked, all negative for NetBIOS/DNS and installer-ACL threads in the 2025-01 → 2026-04 window):**
- [htcondor-users](https://www-auth.cs.wisc.edu/lists/htcondor-users/)
- [htcondor-devel](https://www-auth.cs.wisc.edu/lists/htcondor-devel/)

**In-repo cross-references:**
- `POC-REPORT.md` — original six-problem narrative
- `POC-DESIGN-ANALYSIS.md` — technical post-mortem with source-code citations
- `POC-STAKEHOLDER-REPORT.md` — peer/management-facing summary (contains the HTCONDOR-2721 → HTCONDOR-2763 correction and the "24.4+ LTS" → "25.0 LTS" correction called out above)
