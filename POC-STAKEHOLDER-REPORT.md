# HTCondor Windows PoC — Why This Has Been Hard

**Audience:** peers and management.
**Date:** 2026-04-20.
**Status:** end-to-end PoC is working. A second review against HTCondor source code and upstream docs shows ~half the workarounds are removable; the rest are genuine upstream issues, some already fixed in the next major release.

---

## What the PoC proved

A Windows domain user (`brandon`) can submit a compute job and have it run on a remote machine **as brandon** — preserving his file ownership, security context, and access to network shares. This is the feature called `run_as_owner = True` in HTCondor. The PoC demonstrates it works end-to-end on HTCondor 23.4 on Windows Server 2022 inside a fresh AWS-hosted Active Directory domain.

This matters because most of our compute workloads involve file-ownership-sensitive data: shared storage, audit trails, Kerberos-authenticated SMB. Running jobs as a generic service account loses that attribution. `run_as_owner` is the only HTCondor mode that preserves it on Windows.

## Why it took longer than it should have

Short version: **HTCondor on Windows is noticeably rougher than on Linux, and its documentation occasionally contradicts its source code.**

Longer version — the pattern that kept repeating was:

1. Do what the docs appeared to say.
2. Observe a failure that didn't match any documented error mode.
3. Dig through source code, logs, and mailing list threads to find the actual behavior.
4. Either find a documented escape hatch buried elsewhere in the 600-page manual, or build a workaround.
5. Move to the next failure.

Roughly half of those cycles would have been avoided with clearer cross-referencing in the upstream docs. Some were genuinely our lack of familiarity. Some were real bugs that the HTCondor team has since fixed in the next major release.

## What actually went wrong — and what we learned on second look

The PoC surfaced six distinct blockers. A focused post-mortem against HTCondor's source code and the 23.0/24.0 docs reclassified them:

### Three that were genuine upstream limitations

| Issue | Status |
|---|---|
| The HTCondor credential daemon ("credd") doesn't work with HTCondor's default shared-port networking in 23.x | **Real bug**, fixed upstream in HTCondor 24.4.0 (released Feb 2025). Our workaround matches what upstream's own example config ships. |
| Windows authentication returns NetBIOS domain names (`brandon@FORTWOW`) but HTCondor's authorization matcher expects DNS names (`brandon@fort.wow.dev`) — with no aliasing | **Real, undocumented**, still applies in 24.x. Workaround is to list both forms everywhere. |
| HTCondor's Windows installer locks down its own config file such that non-admin users can't read it | **Real, undocumented**. Fix is one `icacls` command per machine. |

These three we keep the workarounds for. Upgrading to HTCondor 24.4+ would eliminate the first.

### Three that were our misreads of documentation

| Issue | What we did | What we should have done |
|---|---|---|
| "HTCondor rejects credential-store attempts unless the caller is the target user himself" | Built an elaborate scheduled-task mechanism that runs as brandon, calls the tool, captures output via a file | The documented one-liner `CRED_SUPER_USERS = SYSTEM, Administrator` lets privileged accounts store any user's credentials. This macro is in the configuration reference; we missed it. |
| "The execute node doesn't auto-publish which credd it's using, breaking job matchmaking" | Hand-wrote the attribute value into a config file at setup time | HTCondor **does** auto-publish this attribute via a periodic probe. Our probe was failing because of the credd-port issue above (cascading failure) and because we were running a redundant second credd that was hijacking the collector. Once those are fixed, auto-publish works as designed. |
| "Running a local credd on each execute node speeds up job starts" | Ran a second credd daemon per execute node, then fought the collector-advertisement conflicts that caused | The documented way to cache credentials locally is a single configuration flag (`CREDD_CACHE_LOCALLY = True`), not a second daemon. The docs explicitly say to run **one** credd per pool. |

These three we can rip out of the repo — roughly 100 lines of PowerShell scaffolding and 7 config lines.

## The debugging pattern that burned the most time

Three things compounded and made this harder than it should have been:

1. **Cascading symptoms.** The shared-port credd bug (real) caused job-matchmaking to fail (symptom), which looked like a missing attribute (red herring), which we "fixed" by pinning the attribute manually (workaround masking the real fix). Finding the bottom of the stack took source-code reading.

2. **The manual is organized by macro, not by workflow.** The escape hatch we needed for credential storage was documented in the configuration-macros reference under `CRED_SUPER_USERS`, not on the Windows platform page that walks through setup. Someone who doesn't already know the macro name can't find it.

3. **Secrets pipeline through AWS SSM + PowerShell + bash loses characters.** Passwords containing `$` silently disappear through bash interpolation. We lost time thinking HTCondor was rejecting the credential when actually the credential arriving at HTCondor was the empty string. Fix is operational — ship scripts as files, don't interpolate secrets inline.

## Current state and path forward

**Today:** PoC works end-to-end, reproducible from `terraform apply`. Six workarounds documented in the PoC repo.

**Short-term cleanup:** apply the three "misread" removals. Net effect: ~100 fewer lines of setup PowerShell, three fewer config files, simpler architecture. No functional regression — the docs describe the simpler architecture as the correct one. Estimated effort: half a day to modify, one day to re-test end-to-end.

**Medium-term:** upgrade the pool to HTCondor 24.4+ LTS. Upstream's `HTCONDOR-2721` fixes the shared-port credd issue (our biggest remaining workaround) and `HTCONDOR-3281` makes the credd-discovery path more robust. Estimated effort: one-week pool upgrade cycle.

**Long-term:** the NetBIOS/DNS identity mismatch is a codebase-wide behavior and unlikely to change. We live with it.

## Takeaways for future Windows+HTCondor work

1. **Budget 2–3× longer than a comparable Linux PoC.** The Windows-specific behavior gaps are real.
2. **Read the source when the docs stop helping.** The HTCondor codebase is reasonable C++ and well-structured by subsystem. Three hours of source reading saved us a week of empirical fiddling.
3. **When a workaround feels too clever, go look for a documented escape hatch.** Two of our three "misreads" were macros that solve the problem in one line.
4. **Separate the secret-delivery pipeline from the debug loop.** Passwords through bash-through-SSM-through-PowerShell is four interpolation steps, and any one can silently drop characters. Move that out of the inner loop.
5. **Consider upgrading to HTCondor 24.x for production.** 23.x LTS will not back-port the credd shared-port fix; all new work in that area goes into 24.x.

## Decisions requested

1. **Approve the short-term cleanup** (remove misread workarounds). Low risk, high readability win, stays on 23.4.
2. **Approve planning for a 24.4+ upgrade.** Separate ticket, not blocking any current work.
3. **Approve filing upstream doc patches** for the three gaps we hit: `CREDD_PORT`/`CREDD_ARGS` reference, NetBIOS/DNS authorization note, LocalCredd auto-publish description.

---

*Details — including cited source code lines, doc URLs, and mailing-list threads — are in `POC-DESIGN-ANALYSIS.md`.*
