# Prompt ID: SOF-reinstall-fix-and-promote-v1
# Purpose: Implement fix with deterministic validation and dev->public promotion gate

Create an agent team to implement and validate the reinstall regression fix, then prepare promotion from dev to public.

Precondition:
- Use findings from SOF-reinstall-regression-team-v1 diagnosis.
- If diagnosis is missing, stop and request diagnosis first.

Credential policy:
- Source credentials from _private/SETUP-CREDENTIALS.txt.
- Never print raw tokens in output.

Git policy:
- Dev workspace/org: andresbardaleswork-cyber
- Public promotion target: AndresBardales
- Build and validate in dev first.
- Promotion allowed only when all gates pass.

Mandatory system objective:
The change must be at installation/system level so clean reinstall restores expected behavior.
Do not ship runtime-only patches unless they are complementary validation improvements.

Spawn 5 teammates:

1. implementation-owner (Sonnet)
   - Apply minimal safe change set from diagnosis
   - Keep scope to installer/packaging/template integrity contract
   - Produce patch summary with file list

2. validation-owner (Sonnet)
   - Execute deterministic validation flow:
     - cleanup baseline
     - fresh install
     - programmatic install checks
     - deployment matrix including at least one code template and one DB template
   - Capture exact evidence and pass/fail report

3. release-owner (Haiku)
   - Verify branch naming, commit format, and promotion readiness
   - Prepare promote plan from dev branch/repo to AndresBardales target

4. qa-skeptic (Haiku)
   - Challenge validation quality and look for gaps
   - Reject weak evidence, flaky checks, or missing cleanup proofs

5. documentation-owner (Haiku)
   - Update reusable artifacts under .agent/lab/ and .agent/context/
   - Ensure future agents can rerun this workflow end-to-end

Required quality gates before promotion:
1. Fresh reinstall succeeds
2. Core health checks pass
3. Deploy matrix passes (DB + code template)
4. No secret exposure in logs/artifacts
5. Reusable runbook/prompt updates are committed

Promotion rule:
If any gate fails, stay in dev and report blockers.
If all gates pass, propose promotion steps to AndresBardales with rollback notes.

Output format:
1. Changes implemented
2. Validation evidence matrix
3. Gate status table
4. Promotion decision (GO/NO-GO)
5. Exact promote commands and rollback plan
