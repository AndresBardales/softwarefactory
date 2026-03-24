# Prompt ID: SOF-reinstall-regression-team-v1
# Owner: andresbardaleswork-cyber (dev) -> AndresBardales (public promote)
# Purpose: Diagnose and fix post-reinstall regression at installer/system level
# Last updated: 2026-03-21

Create an agent team to investigate and fix a post-reinstall regression in Kaanbal Engine.

Context:
We already had SOF-2 and SOF-12 working in the past as end-to-end installation and deployment flow.
After a nuclear cleanup and fresh reinstall, the base platform comes up healthy, but app deployment is partially broken.

Observed bug:
Launching a Vue app fails with:
"npm is not available for Vue scaffolding, and no fallback template was found in kaanbal-templates"

Recent evidence from previous investigation:
- Fresh install completed successfully
- Core services became healthy
- Database templates deployed successfully
- Code templates failed
- Previous replay suggests kaanbal-templates content may be missing after packaging/bootstrap
- package.sh may be archiving only committed files
- app_deployer expects scaffold sources or fallback template files that may not exist after reinstall

Critical goal:
Do NOT optimize for a local patch in the deployer only.
The fix must be evaluated at installation/system level so that a clean reinstall restores the full expected workflow.
The final standard is:
nuclear cleanup -> fresh install -> programmatic install validation -> app deployment matrix -> expected deploy behavior restored.

Scope:
Investigate the entire reinstall pipeline and determine where the regression is introduced:
- installer
- repo packaging
- repo bootstrap/push to git provider
- template repo content
- runtime deployer expectations
- SOF-2 / SOF-12 behavior regression

Credentials and environment policy:
- Use credentials from _private/SETUP-CREDENTIALS.txt (do not print secrets in output)
- Dev execution identity is andresbardaleswork-cyber
- Promotion target is AndresBardales public org/repo
- Validate in dev first, promote only after deterministic evidence passes

Constraints:
- Prefer root-cause analysis over surface fixes
- Do not hardcode values
- Do not make ad hoc cluster-only fixes unless strictly needed for evidence
- Any accepted fix must be reproducible from a fresh install
- Keep all scripts/artifacts under .agent/lab/
- If the bug is caused by missing template source content in kaanbal-templates, prove whether installer should populate it, package it, or validate and fail earlier

Spawn 5 teammates:

1. installer-auditor (Sonnet)
   - Analyze install and repackaging path end to end
   - Focus: softwarefactory/package.sh, softwarefactory/installer/steps/, bootstrap/push logic
   - Deliver exact point where reinstall may lose required template content

2. template-repo-auditor (Sonnet)
   - Analyze kaanbal-templates artifact integrity after reinstall
   - Focus: manifest.json, catalog.json, scaffold path/file presence
   - Deliver which templates are complete vs incomplete

3. runtime-path-reviewer (Sonnet)
   - Analyze runtime expectations in kaanbal-api/app/services/app_deployer.py
   - Deliver whether runtime behavior is correct given installer contract

4. e2e-validator (Haiku)
   - Define pass/fail matrix for SOF-2/SOF-12 parity after reinstall
   - Reuse .agent/lab scripts and identify missing checks

5. skeptic (Haiku)
   - Challenge all findings
   - Deliver strongest alternative explanation and missing evidence

Workflow:
- installer-auditor, template-repo-auditor, runtime-path-reviewer, e2e-validator run in parallel
- skeptic waits, then challenges findings
- lead synthesizes
- do not implement immediately

Required lead output:
1. Problem statement
2. Most likely root cause
3. Why this is reinstall/system-level regression
4. Correct fix ownership (installer, packaging, template content, runtime, or combo)
5. Smallest safe change set
6. Validation plan from cleanup to deploy matrix
7. Promotion gate: dev evidence required before AndresBardales promotion

Important:
- Wait for teammates before concluding
- Reject any plan that cannot be proven by clean reinstall
- Require plan approval before implementation
