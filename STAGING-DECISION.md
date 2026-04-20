# Decision Record — Should we split the repo into staged branches/tags?

**Date:** 2026-04-20
**Status:** Decided to defer. Re-evaluate if a concrete trigger (below) occurs.

---

## Context

After the PoC reached working state, we considered restructuring the repo
so the history (or a set of branches/tags) would walk through four stages:

1. **v1 — infra only** — VPC, EC2, AD, SSM, no HTCondor at all
2. **v2 — software available** — MSI + configs + scripts staged in S3, not yet installed
3. **v3 — minimal install** — default HTCondor install, no `run_as_owner` tweaks
4. **v4 — run_as_owner fixes** — current working state

Motivation: easier to track changes, easier for a newcomer to reproduce any
single stage, easier to teach.

## Decision

**Defer.** Probably never do it unless one of the triggers below fires.

## Reasoning

1. **The PoC goal is already met.** `run_as_owner` is validated, the repo
   reproduces the working state, and `POC-REPORT.md` explains the journey.
   A 4-stage split is educational polish, not engineering value.

2. **Each stage would need to actually deploy to be trustworthy.** If
   `v1-infra-only` has never been `terraform apply`'d on its own, it's a
   lie — the first person who tries it will hit bugs. That means four
   separate apply/destroy cycles: ~2–3 hours of wall time and $2–3 of AWS
   cost just to verify the stages work in isolation. Otherwise we're
   handing teammates pre-sliced stages that have never been tested.

3. **Most of the untangling is non-trivial.** `execute-setup.ps1` has
   `run_as_owner` logic interleaved with basic install logic.
   `storage.tf` uploads scripts that don't exist in the early stages.
   Splitting these cleanly is a real refactor (~1–2 hours of code
   changes), and mistakes would be easy to miss without end-to-end
   testing of each stage.

4. **The current commit history already tells a story.** `f5a0ddf`
   (initial working state) → `4cdfee2` (fixes baked in) → `71d987b`
   (report) is a reasonable narrative on its own. `POC-REPORT.md` § 3
   lists the six problems in order of pain, which serves the "stages"
   purpose better than branches would.

5. **If you want to practice git — practice on a throwaway repo.**
   Refactoring a working PoC to learn branching is high-risk for low
   educational value. Make a toy repo with `hello.txt` and practice
   tags / branches / rebase there. Way cheaper to make mistakes.

## Triggers that would change the decision

Do the refactor if any of these become true:

- **A teammate says "I want just the AD + VPC infra for a different
  project."** Then `v1-infra-only` has a real consumer and gets tested
  because they'll actually use it.
- **We publish this as a tutorial** (blog post, workshop, onboarding
  doc). Then the stages are a teaching artifact and worth the effort
  to verify.
- **We adapt this for production** and the production team needs a
  minimum-viable-deploy they can extend. Then stages reflect real
  deployment phases and must be deployable on their own.

## Recommended path (absent a trigger)

Push to GitHub, link `POC-REPORT.md` in the team channel, move on.

## Notes on the mechanics (for future reference)

If we do eventually want staged snapshots, the recommended mechanism is
**tags on a linear history**, not branches:

- Branches are meant for parallel work that may later merge; sequential
  stages are not parallel.
- Branching off `main` means working backwards by deletion (fragile).
- Reconstructing *forward* — start empty, add infra, commit; add
  software, commit; etc. — gives the same stages via a clean commit
  history on a single branch, with `git tag` marking each stage.
- Tags are immutable and render as "Releases" on GitHub; branches move
  when you commit, which confuses newcomers.
- Fixing a bug on a tagged-history layout is one commit + re-tag.
  Fixing the same bug across four stacked branches requires
  cherry-picks or rebases across all four.
