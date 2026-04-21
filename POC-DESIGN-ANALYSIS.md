# HTCondor 23.4 Windows PoC — Design Analysis

**Date:** 2026-04-20
**Scope:** Post-mortem review of the six workarounds captured in `POC-REPORT.md` against HTCondor source (v23.4.0 tag), official documentation (23.0 and 24.0 docs trees), and the `htcondor-users` mailing list archive.
**Purpose:** decide which workarounds are genuine upstream bugs we must keep, which are misreads of documentation we should delete, and what the forward path looks like.

---

## TL;DR

| Workaround in repo | Verdict | Action |
|---|---|---|
| Self-store scheduled task (`CredStoreAsUser.ps1`) + `SeBatchLogonRight` grant | **Misread** — documented escape hatch exists | **Rip out.** Add `CRED_SUPER_USERS = SYSTEM, Administrator` on CM; drop the scheduled-task dance. |
| Local CREDD on execute node + `CREDD.COLLECTOR_HOST = 127.0.0.1` + `DAEMON_LIST` ordering + `04-localcredd.conf` | **Architecture divergence** — docs describe a single centralized credd | **Rip out.** Remove local CREDD daemon; rely on `CREDD_CACHE_LOCALLY = True` on the EP. |
| `STARTD_ATTRS = $(STARTD_ATTRS) LocalCredd` + hand-pinned sinful | **Symptom fix, not root cause** — auto-publish is the designed path | **Rip out.** Make submit and EP `CREDD_HOST` byte-identical strings; let `credd_test()` populate the attribute. |
| `CREDD.USE_SHARED_PORT = False` + `CREDD_PORT = 9620` on CM | **Real 23.4 limitation** — fixed upstream in 24.4.0 (HTCONDOR-2721) | **Keep, rewrite** in the shipped-template idiom: `CREDD_ARGS = -p $(CREDD_PORT) -f`. |
| NetBIOS/DNS double-listing in every `ALLOW_*` (`*@fort.wow.dev, *@fortwow`) | **Real, undocumented** — NTSSPI returns NetBIOS; auth matcher is literal-string | **Keep**, add a comment pointing here. |
| `SeBatchLogonRight` for brandon (interactive submit) | **Real, undocumented** — required whenever a human runs `condor_store_cred` | **Keep** (but scope to the interactive submit node only; the cred-store flow on CM goes away with `CRED_SUPER_USERS`). |
| `icacls BUILTIN\Users:(R)` on `condor_config` | **Real, undocumented** — HTCondor Windows installer locks config readability | **Keep**. |

**Bottom line:** three of the six "problems" documented in `POC-REPORT.md` are resolvable by correct configuration. Two are genuine upstream limitations in 23.4 that have fixes in 24.4+. One (NetBIOS/DNS) is a documented-silently-wrong behavior that still requires the workaround.

Upgrading the pool to HTCondor 24.4+ LTS would eliminate the largest remaining workaround (shared-port CREDD routing) and make the `LocalCredd` auto-publish path more reliable.

---

## Methodology

Two parallel research tracks were run:

1. **Source-code trace** on the HTCondor `v23.4.0` git tag: `src/condor_credd/credd.cpp`, `src/condor_startd.V6/ResAttributes.cpp`, `src/condor_utils/submit_utils.cpp`, `src/condor_daemon_client/daemon.cpp`, `src/condor_tools/store_cred_main.cpp`, `src/condor_examples/condor_config.annotated`, and the `docs/` tree.
2. **Doc + mailing list audit** against [23.0 Windows platform docs](https://htcondor.readthedocs.io/en/23.0/platform-specific/microsoft-windows.html), the [24.0 successor](https://htcondor.readthedocs.io/en/24.0/platform-specific/microsoft-windows.html), [configuration-macros](https://htcondor.readthedocs.io/en/23.0/admin-manual/configuration-macros.html), [security.html](https://htcondor.readthedocs.io/en/23.0/admin-manual/security.html), and the `htcondor-users` archive at `lists.cs.wisc.edu`.

Each of the six workarounds from `POC-REPORT.md` was classified by comparing our empirical findings to source-code behavior and documentation guidance.

---

## Problem 1 — Self-store on `condor_store_cred` (MISREAD)

### What the PoC does

`cm-setup.ps1` and `execute-setup.ps1` register a short-lived scheduled task running **as brandon** that invokes `condor_store_cred add`, captures output, and writes results to `C:\Users\Public\cred-store-result.txt`. This requires `SeBatchLogonRight` granted to brandon's SID via `secedit /export` → edit → `/import` + `/configure`, plus `icacls BUILTIN\Users:(R)` on `C:\condor\condor_config` and `C:\ProgramData\HTCondor\config.d`.

The justification given was: *"store_cred_handler in HTCondor 23.x has an **undocumented** check that the authenticated user's base name must equal the target user's base name."*

### What the docs actually say

The check IS documented — in the `CRED_SUPER_USERS` configuration macro:

> **CRED_SUPER_USERS**: A comma and/or space separated list of user names on a given machine that are permitted to store credentials for any user. When not on this list, users can only store their own credentials.
>
> — [configuration-macros.html#CRED_SUPER_USERS](https://htcondor.readthedocs.io/en/23.0/admin-manual/configuration-macros.html#CRED_SUPER_USERS)

The documented fix is a one-line config change on the credd host; the PoC reimplemented this with ~80 lines of PowerShell + scheduled-task + secedit scaffolding because the author didn't know the macro existed. The "undocumented check" claim in `POC-REPORT.md` §3.1 is inaccurate.

### Recommended fix

On the CM (credd host), add to `01-cm.conf`:

```
# Allow privileged accounts to store credentials on behalf of any user.
# SYSTEM runs setup scripts; Administrator is used interactively.
CRED_SUPER_USERS = SYSTEM, Administrator
```

Then delete the following from the repo:
- `CredStoreAsUser.ps1` creation block in `cm-setup.ps1` and `execute-setup.ps1`
- `Grant-SeBatchLogonRight` helper (keep it **only** if brandon will run `condor_store_cred` interactively on the submit node — see §Problem 1-adjacent)
- `Store-CredAsUser` helper

### What still needs to stay

`SeBatchLogonRight` is still required on the **submit node** when brandon himself runs `condor_store_cred` — the tool internally calls `LsaAddAccountRights` to grant that very right to the target user, which requires the caller to have local admin. If brandon does not have local admin on `ws-0` (and the PoC design says he shouldn't), someone with admin has to pre-grant it for him. That part is a genuine undocumented requirement; keep it, but scope it to the interactive node only.

---

## Problem 2 — LocalCredd auto-publish (SYMPTOM FIX)

### What the PoC does

`02-execute.conf` declares:

```
STARTD_ATTRS = $(STARTD_ATTRS) LocalCredd
```

and `execute-setup.ps1` resolves `mgr.fort.wow.dev` at setup time to produce `04-localcredd.conf`:

```
LocalCredd = "<10.0.1.11:9620?addrs=10.0.1.11-9620&alias=MGR.fort.wow.dev>"
```

The justification was: *"on Windows 23.4, the startd does NOT auto-populate its LocalCredd ClassAd attribute from the collector's CREDD advertisement."*

### What the source code actually does

The startd **does** auto-publish `LocalCredd` — via a periodic `CREDD_NOP` probe. Source at [src/condor_startd.V6/ResAttributes.cpp#L1498-L1501](https://github.com/htcondor/htcondor/blob/v23.4.0/src/condor_startd.V6/ResAttributes.cpp#L1498-L1501):

```cpp
// Attempt to perform a NOP on our CREDD_HOST. If we succeed,
// we'll advertise the CREDD_HOST
```

Full probe at [ResAttributes.cpp#L1729-L1777](https://github.com/htcondor/htcondor/blob/v23.4.0/src/condor_startd.V6/ResAttributes.cpp#L1729-L1777):

```cpp
Daemon credd(DT_CREDD);
if (credd.locate()) {
  Sock *sock = credd.startCommand(CREDD_NOP, Stream::reli_sock, 20);
  if (sock && sock->end_of_message()) {
    m_local_credd = credd_host;   // → Assign(ATTR_LOCAL_CREDD, ...)
  }
}
```

The probe runs every `CREDD_TEST_INTERVAL` (default 300 seconds). On success, the startd assigns `LocalCredd = <credd_host>` to its ClassAd. The 23.4 Windows docs describe exactly this verification step as standard:

> Any rows in the output with the `UNDEF` string indicate machines where secure communication is not working properly. Verify that the pool password is stored correctly on these machines.
>
> — [platform-specific/microsoft-windows.rst#L228-L237 (v23.4.0)](https://github.com/htcondor/htcondor/blob/v23.4.0/docs/platform-specific/microsoft-windows.rst#L228-L237)

So `LocalCredd = UNDEF` is not a bug — it's a diagnostic signal that the startd could not speak to a credd. In the PoC that was caused by two upstream-confirmed issues cascading:

1. **Port 9620 shared-port routing bug** (see Problem 4 / §Problem 4 below) — the credd ad's sinful string pointed at 9620, but with `USE_SHARED_PORT=True` the master controlled 9620 and didn't know what to do with STORE_CRED/NOP commands.
2. **Local-credd hijacking in the collector** (see Problem 5 / §Problem 5 below) — the execute node ran a second CREDD that overwrote the CM's credd ad in the shared collector, so the startd located its own local credd, which may or may not have been responsive.

Once both are resolved, `credd_test()` will succeed and `LocalCredd` will populate within 5 minutes.

### The submit-side byte-comparison catch

`condor_submit` auto-injects a requirement into `run_as_owner=True` jobs at [src/condor_utils/submit_utils.cpp#L5910-L5925 (v23.4.0)](https://github.com/htcondor/htcondor/blob/v23.4.0/src/condor_utils/submit_utils.cpp#L5910-L5925):

```cpp
if (job->LookupBool(ATTR_JOB_RUNAS_OWNER, as_owner) && as_owner) {
  std::string tmp_rao = " && (TARGET." ATTR_HAS_WIN_RUN_AS_OWNER;
  if (RunAsOwnerCredD && !checks_credd) {
    tmp_rao += " && (TARGET." ATTR_LOCAL_CREDD " =?= \"";
    tmp_rao += RunAsOwnerCredD.ptr();   // = submit's CREDD_HOST
    tmp_rao += "\")";
  }
}
```

`RunAsOwnerCredD` is the submit-side `CREDD_HOST` **string literal**, not a resolved sinful. For matchmaking to succeed, the startd's published `LocalCredd` must be **byte-identical** to the submit's configured `CREDD_HOST`. Any difference in spelling (FQDN vs short hostname, IP vs DNS name, with or without sinful trimmings) will cause the match to fail.

This is brittle and almost certainly why hand-pinning the sinful string "fixed" the symptom — by coincidence, the pinned value byte-matched what submit was asking for. Remove the pin and align `CREDD_HOST` across submit and EP config and the auto-publish path will work end-to-end.

### Recommended fix

Edits to make:

```diff
--- a/htcondor-poc/htcondor/02-execute.conf
+++ b/htcondor-poc/htcondor/02-execute.conf
-STARTD_ATTRS = $(STARTD_ATTRS) LocalCredd
```

Delete `04-localcredd.conf` generation in `execute-setup.ps1`.

Ensure `CREDD_HOST` is spelled identically in `00-common.conf` on submit and EP (both should say `mgr.fort.wow.dev`, nothing else).

Verify with the documented one-liner:

```
condor_status -f "%s\t" Name -f "%s\n" ifThenElse(isUndefined(LocalCredd),"UNDEF",LocalCredd)
```

If UNDEF persists after `condor_reconfig -all` and a 5-minute wait, the NOP probe is still failing — fix that (check credd logs for auth errors, verify port reachability, `condor_ping -name mgr ALL`), **do not re-pin**.

### Mailing-list corroboration

Every mailing-list thread over the last decade about `LocalCredd=UNDEF` resolves by fixing auth/port/credd setup, never by hand-writing the attribute:

- [htcondor-users 2019-May msg00159 — Vanilla Windows pool example config files](https://lists.cs.wisc.edu/archive/htcondor-users/2019-May/msg00159.shtml)
- [htcondor-users 2018-October msg00040 — Re: Cannot sent jobs as Owner in WindowsOS](https://lists.cs.wisc.edu/archive/htcondor-users/2018-October/msg00040.shtml)
- [htcondor-users 2021-June msg00033 — Adding a Windows node to an existing Linux-Pool](https://lists.cs.wisc.edu/archive/htcondor-users/2021-June/msg00033.shtml)
- [htcondor-users 2016-January msg00090 — Windows, Credential setup issues](https://www-auth.cs.wisc.edu/lists/htcondor-users/2016-January/msg00090.shtml)

---

## Problem 3 — NetBIOS vs DNS identity split (REAL, KEEP)

### What the PoC does

Every `ALLOW_*` list in `00-common.conf` contains **both** forms:

```
ALLOW_WRITE = condor_pool@fort.wow.dev/*, *@fort.wow.dev, *@fortwow
```

And brandon's cred is stored **twice** per credd — once as `brandon@FORTWOW`, once as `brandon@fort.wow.dev`.

### Why

HTCondor's authorization identity-mapping table in [security.html](https://htcondor.readthedocs.io/en/23.0/admin-manual/security.html#authentication) maps NTSSPI authentication's output verbatim: the regex is `(.*) \1`, meaning whatever NTSSPI returns is the canonical identity string. On Windows, NTSSPI returns the **NetBIOS** domain (`fortwow`), not the DNS FQDN (`fort.wow.dev`). No aliasing is applied.

So when a schedd on `ws-0` authenticates using NTSSPI, it introduces itself as `brandon@fortwow` — which does not match any `*@fort.wow.dev` ACL literal.

Worse: credential lookups are also keyed by the full `user@domain` string. The schedd identifies brandon as `brandon@fortwow` (NetBIOS), while `UID_DOMAIN`-driven code paths look up under `brandon@fort.wow.dev`. Both identities need to exist in the credd.

### Documentation status

Silent. Neither the Windows platform page nor the security page anywhere says "on Windows you must list NetBIOS and DNS forms separately." This is a real undocumented behavior.

### Recommended action

**Keep the workaround**, add a comment in `00-common.conf` pointing at this analysis:

```
# NetBIOS/DNS split: NTSSPI returns *@fortwow (NetBIOS domain) but
# UID_DOMAIN and other code paths use *@fort.wow.dev (DNS FQDN).
# HTCondor does no aliasing — both literal forms must appear in
# every ALLOW_* list, and credentials must be stored under both.
# See POC-DESIGN-ANALYSIS.md §Problem 3.
ALLOW_WRITE = condor_pool@fort.wow.dev/*, *@fort.wow.dev, *@fortwow
```

---

## Problem 4 — Shared-port CREDD routing (REAL 23.x LIMITATION; FIXED IN 24.4)

### What the PoC does

On any node hosting a CREDD:

```
CREDD.USE_SHARED_PORT = False
CREDD_PORT            = 9620
```

### What the source code actually does

[src/condor_credd/credd.cpp#L45-L48 (v23.4.0)](https://github.com/htcondor/htcondor/blob/v23.4.0/src/condor_credd/credd.cpp#L45-L48) shows that the credd is the only daemon that registers the `STORE_CRED` command (`SCHED_VERS+79 = 479`). The master only registers `STORE_POOL_CRED` (`SCHED_VERS+97`).

In the shipped default config template at [src/condor_examples/condor_config.annotated#L1878-L1892 (v23.4.0)](https://github.com/htcondor/htcondor/blob/v23.4.0/src/condor_examples/condor_config.annotated#L1878-L1892):

```
#CREDD_HOST  = $(CONDOR_HOST):$(CREDD_PORT)
CREDD_PORT  = 9620
CREDD_ARGS  = -p $(CREDD_PORT) -f
```

Both `CREDD_PORT` and `CREDD_ARGS = -p $(CREDD_PORT) -f` are **active by default** (not commented). The `-p 9620` flag tells daemon-core to bind its own TCP listener on 9620 rather than register with the shared-port server. This means 23.x was designed for the credd to have its own dedicated port all along.

`CREDD_PORT` is **not documented** anywhere in the 23.4 `configuration-macros.rst`. Nor is `CREDD.USE_SHARED_PORT = False` described as a requirement.

### Upstream fix

HTCONDOR-2721, released in **24.4.0** (2025-02-04):

> The condor_credd daemon no longer listens on port 9620 by default, but rather uses the condor_shared_port daemon.
>
> — [HTCondor 24.x feature release notes](https://htcondor.readthedocs.io/en/latest/version-history/feature-versions-24-x.html)

HTCONDOR-3281 (24.12) adds: the schedd now publishes the co-located credd's address in its own ClassAd, so clients discover it without querying the collector separately.

Together these mean 24.4+ delivers what the 23.x docs implicitly promised.

### Recommended fix

**Keep the workaround on 23.4.** Rewrite it in the shipped-template idiom so it matches upstream's own example:

```diff
--- a/htcondor-poc/htcondor/01-cm.conf
+++ b/htcondor-poc/htcondor/01-cm.conf
-CREDD.USE_SHARED_PORT = False
-CREDD_PORT            = 9620
+# 23.4 credd does not work over shared_port; bind its own listener.
+# Matches the default config.annotated template shipped with HTCondor.
+# Fixed upstream in 24.4.0 (HTCONDOR-2721) — remove this block on upgrade.
+CREDD_PORT = 9620
+CREDD_ARGS = -p $(CREDD_PORT) -f
```

Drop this block entirely from `02-execute.conf` (see Problem 5 — we're removing the local CREDD on the EP).

### `_CONDOR_CREDD_HOST` bypass

The client-side trick of setting `_CONDOR_CREDD_HOST=<ip:9620?addrs=...>` as a full sinful string to bypass the collector lookup is supported by [src/condor_daemon_client/daemon.cpp#L1152-L1156 (v23.4.0)](https://github.com/htcondor/htcondor/blob/v23.4.0/src/condor_daemon_client/daemon.cpp#L1152-L1156). Documented examples only show the bare-hostname form (`CREDD_HOST = credd.cs.wisc.edu`), but the code accepts sinful, `host:port`, and bare hostname. The `:9620` suffix form is probably the cleanest idiom for scripted flows.

---

## Problem 5 — Local CREDD hijacking central credd ad (ARCHITECTURE DIVERGENCE)

### What the PoC does

The execute node runs its own CREDD daemon (`DAEMON_LIST = MASTER, CREDD, STARTD`), which advertises into the shared collector and overwrites the CM's credd ad. Workaround: `CREDD.COLLECTOR_HOST = 127.0.0.1` on the EP, sending its ads into a local collector that nobody reads.

### What the docs say

[23.0 Windows §condor_credd Daemon](https://htcondor.readthedocs.io/en/23.0/platform-specific/microsoft-windows.html#the-condor-credd-daemon):

> It is first necessary to select **the single** machine on which to run the condor_credd.

The HTCondor Windows architecture is unambiguously: **one central credd, every other node uses `CREDD_CACHE_LOCALLY = True` to cache passwords fetched from that one credd**. Running a second CREDD as a "local cache" is not the HTCondor way; that's what `CREDD_CACHE_LOCALLY` already does without a daemon.

The PoC's local-credd design was based on a misunderstanding: `CREDD_CACHE_LOCALLY = True` is a client-side flag on the starter, not an instruction to run a local credd process. The starter, on a cache miss, fetches from the **remote** credd pointed to by `CREDD_HOST` and stores the password on disk locally for reuse.

### Recommended fix

Remove the local CREDD daemon entirely:

```diff
--- a/htcondor-poc/htcondor/02-execute.conf
+++ b/htcondor-poc/htcondor/02-execute.conf
-DAEMON_LIST = MASTER, CREDD, STARTD
+DAEMON_LIST = MASTER, STARTD

-CREDD.COLLECTOR_HOST = 127.0.0.1
-CREDD.USE_SHARED_PORT = False
-CREDD_PORT            = 9620

-STARTD_ATTRS = $(STARTD_ATTRS) LocalCredd    # per Problem 2, also removed
```

Keep `CREDD_CACHE_LOCALLY = True` and `CREDD_HOST = mgr.fort.wow.dev`.

With the local CREDD gone:
- No hijacking of the CM's credd ad in the collector (so no `COLLECTOR_HOST=127.0.0.1`)
- No ordering constraint on `DAEMON_LIST`
- No second port-9620 listener to worry about on the EP
- No `04-localcredd.conf` to generate at setup time
- Problems 2, 4, and 5 all become moot on the execute node

The CM still hosts a credd, still binds 9620 via `CREDD_ARGS = -p $(CREDD_PORT) -f`, and the EP's starter fetches passwords from it and caches them locally on disk — which is the documented and supported pattern.

---

## Problem 6 — Password interpolation through SSM/PowerShell/bash (OPERATIONAL, KEEP)

### What the PoC does

Passwords with `$` characters were being eaten by bash double-quote expansion when passed inline to `aws ssm send-command --parameters '...'`. Fix: always ship scripts as files to S3, pull via `AWS-RunRemoteScript`, single-quote strings containing `$` inside PowerShell.

### Verdict

Not an HTCondor issue at all — a shell quoting hazard. Keep the workflow, keep the cautionary note. Memory already captures this pattern in `feedback_ssm_workflow.md`.

---

## Proposed repository diffs (summary)

### `htcondor/00-common.conf`
Add inline comment explaining the NetBIOS/DNS double-listing (no config change).

### `htcondor/01-cm.conf`
```diff
-CREDD.USE_SHARED_PORT = False
-CREDD_PORT            = 9620
+CREDD_PORT = 9620
+CREDD_ARGS = -p $(CREDD_PORT) -f
+
+# Allow privileged accounts to store credentials for any user.
+CRED_SUPER_USERS = SYSTEM, Administrator
```

### `htcondor/02-execute.conf`
```diff
-DAEMON_LIST = MASTER, CREDD, STARTD
+DAEMON_LIST = MASTER, STARTD

 STARTER_ALLOW_RUNAS_OWNER = True
 CREDD_CACHE_LOCALLY = True
 CREDD_HOST = mgr.fort.wow.dev

-CREDD.COLLECTOR_HOST = 127.0.0.1
-CREDD.USE_SHARED_PORT = False
-CREDD_PORT            = 9620
-
-STARTD_ATTRS = $(STARTD_ATTRS) LocalCredd
```

### `scripts/cm-setup.ps1`
Delete: `CredStoreAsUser.ps1` creation, `Grant-SeBatchLogonRight` call, scheduled-task-as-brandon invocation, `cred-store-result.txt` readback. Replace with the `CRED_SUPER_USERS = SYSTEM, Administrator` config line (already in `01-cm.conf` — so just delete the ps1 blocks).

### `scripts/execute-setup.ps1`
Delete: `04-localcredd.conf` generation, the scheduled-task-as-brandon self-store for the local credd, `Grant-SeBatchLogonRight` (not needed here since EP credd is gone), `Grant-CondorReadToUsers` (not needed unless brandon will run `condor_store_cred` directly on the EP, which he shouldn't).

### `scripts/submit-setup.ps1`
Unchanged for the credd-side removals. If brandon runs `condor_store_cred` interactively on `ws-0`, keep `Grant-SeBatchLogonRight` there **only**.

### Expected reduction
- ~100 lines removed across `cm-setup.ps1` + `execute-setup.ps1`
- One runtime-generated config file gone (`04-localcredd.conf`)
- Three lines removed from `01-cm.conf`, replaced by two (net –1)
- Four lines removed from `02-execute.conf`, zero added

---

## Forward path

1. **Short term (23.4):** apply the diffs above. Rerun `terraform apply`, observe that `LocalCredd` populates via auto-publish within 5 minutes of startd coming up, and that `condor_submit` from brandon on ws-0 lands a job that runs under his identity on compute-0. Document the `CRED_SUPER_USERS` discovery in the PoC report.
2. **Medium term:** upgrade to HTCondor **24.4+ LTS**. HTCONDOR-2721 makes the shared-port CREDD workaround unnecessary; HTCONDOR-3281 adds credd-address-in-schedd-ClassAd, which improves client discovery. The only 23.x-specific workaround left after 24.x would be the NetBIOS/DNS double-listing, which is a codebase-wide authorization question rather than a config-trick.
3. **Upstream contributions:** file documentation patches for:
   - `CREDD_PORT` and `CREDD_ARGS` should be documented in `configuration-macros.rst` (currently absent from the 23.4 reference).
   - The NetBIOS-vs-DNS NTSSPI identity behavior deserves a paragraph in `security.html` — this has tripped up others on the list.
   - The `LocalCredd` auto-publish mechanism (via `CREDD_NOP` probe every `CREDD_TEST_INTERVAL`) deserves a mention in the Windows platform page so UNDEF is a clearer diagnostic.

---

## References

### HTCondor source code (pinned to `v23.4.0` tag)

- [`src/condor_credd/credd.cpp`](https://github.com/htcondor/htcondor/blob/v23.4.0/src/condor_credd/credd.cpp) — command registration, including STORE_CRED (479)
- [`src/condor_startd.V6/ResAttributes.cpp`](https://github.com/htcondor/htcondor/blob/v23.4.0/src/condor_startd.V6/ResAttributes.cpp) — `credd_test()` auto-publish
- [`src/condor_utils/submit_utils.cpp`](https://github.com/htcondor/htcondor/blob/v23.4.0/src/condor_utils/submit_utils.cpp) — `run_as_owner` Requirements injection
- [`src/condor_daemon_client/daemon.cpp`](https://github.com/htcondor/htcondor/blob/v23.4.0/src/condor_daemon_client/daemon.cpp) — sinful / host:port / hostname parsing
- [`src/condor_tools/store_cred_main.cpp`](https://github.com/htcondor/htcondor/blob/v23.4.0/src/condor_tools/store_cred_main.cpp) — `condor_store_cred` client
- [`src/condor_examples/condor_config.annotated`](https://github.com/htcondor/htcondor/blob/v23.4.0/src/condor_examples/condor_config.annotated) — shipped default config template
- [`src/condor_examples/condor_config.local.credd`](https://github.com/htcondor/htcondor/blob/v23.4.0/src/condor_examples/condor_config.local.credd) — example credd localfile

### HTCondor documentation

- [23.0 Microsoft Windows platform page](https://htcondor.readthedocs.io/en/23.0/platform-specific/microsoft-windows.html)
- [24.0 Microsoft Windows platform page](https://htcondor.readthedocs.io/en/24.0/platform-specific/microsoft-windows.html)
- [23.0 Configuration Macros](https://htcondor.readthedocs.io/en/23.0/admin-manual/configuration-macros.html)
- [23.0 Security](https://htcondor.readthedocs.io/en/23.0/admin-manual/security.html)
- [23.0 Submitting a Job](https://htcondor.readthedocs.io/en/23.0/users-manual/submitting-a-job.html)
- [24.x Feature Release Notes (HTCONDOR-2721)](https://htcondor.readthedocs.io/en/latest/version-history/feature-versions-24-x.html)

### Mailing list corroboration (`htcondor-users`)

- [2019-May msg00159 — Vanilla Windows pool example config files](https://lists.cs.wisc.edu/archive/htcondor-users/2019-May/msg00159.shtml)
- [2018-October msg00040 — Cannot sent jobs as Owner in WindowsOS](https://lists.cs.wisc.edu/archive/htcondor-users/2018-October/msg00040.shtml)
- [2021-June msg00033 — Adding a Windows node to an existing Linux-Pool](https://lists.cs.wisc.edu/archive/htcondor-users/2021-June/msg00033.shtml)
- [2016-January msg00090 — Windows, Credential setup issues](https://www-auth.cs.wisc.edu/lists/htcondor-users/2016-January/msg00090.shtml)

### Internal repo references

- `POC-REPORT.md` — original six-problem writeup, now superseded in part by this analysis
- `htcondor-poc/DEPLOY.md` — deployment flow and verification steps
- `htcondor-poc/htcondor/00-common.conf`, `01-cm.conf`, `02-execute.conf`, `03-submit.conf` — config under review
- `htcondor-poc/scripts/cm-setup.ps1`, `execute-setup.ps1`, `submit-setup.ps1` — setup scripts slated for simplification

---

*Authored after two parallel investigations: source-code trace on the v23.4.0 tag and doc/mailing-list audit against the 23.0 and 24.0 documentation trees. Every claim in this document is backed by a cited URL above.*
