# Agent Team Prompt Registry

This folder versions long-running team prompts and preserves run evidence locally.

## Canonical Workflow
- Primary process guide: `.agent/context/ORCHESTRATION-WORKFLOW-GUIDE.md`
- Use this guide as the default lifecycle for intake -> Jira -> team execution -> validation -> QA closure.

## Epic Prompt History (Recommended)
- For milestone runs, post one structured Jira comment at Epic level with prompt path, hash, timestamp, summary, and impacted tickets.
- Keep this lightweight: only significant runs (scope, pivots, RC validation), not every micro-run.

## Structure
- prompts/: versioned prompts (tracked in git)
- scripts/: runner scripts (tracked in git)
- runs/: local run outputs and metadata (ignored by git)

## Why this exists
- Traceability: know exactly which prompt produced which result
- Reproducibility: rerun same prompt with hash and timestamp
- Team sharing: commit prompt versions without leaking credentials

## Rules
- Never put raw secrets in prompt files.
- Refer to _private/SETUP-CREDENTIALS.txt as source of credentials.
- Use dev identity first (andresbardaleswork-cyber).
- Promote to public (AndresBardales) only after validation gates pass.

## Run a prompt
1. Login once:
   claude login

2. Run a versioned prompt (non-interactive):
   powershell -ExecutionPolicy Bypass -File .agent/teams/scripts/run-team-prompt.ps1 -PromptFile .agent/teams/prompts/SOF-reinstall-regression-team-v1.prompt.md

3. Interactive mode (recommended for Agent Teams):
   powershell -ExecutionPolicy Bypass -File .agent/teams/scripts/run-team-prompt.ps1 -PromptFile .agent/teams/prompts/SOF-reinstall-regression-team-v1.prompt.md -Interactive

4. Team interactive launcher (copies prompt to clipboard + starts Claude):
   powershell -ExecutionPolicy Bypass -File .agent/teams/scripts/start-team-interactive.ps1 -PromptFile .agent/teams/prompts/SOF-1-committee-to-spec-v1.prompt.md -Model sonnet

## Recommended SOF-1 sequence
1. Committee/spec phase:
   - Prompt: `.agent/teams/prompts/SOF-1-committee-to-spec-v1.prompt.md`
2. Execution phase (dev -> public):
   - Prompt: `.agent/teams/prompts/SOF-1-execution-dev-to-public-v1.prompt.md`
3. Reinstall regression deep-dive:
   - Prompt: `.agent/teams/prompts/SOF-reinstall-regression-team-v1.prompt.md`
4. Fix + promotion gate:
   - Prompt: `.agent/teams/prompts/SOF-reinstall-fix-and-promote-v1.prompt.md`
5. Dev hard reset + clean reinstall validation:
   - Prompt: `.agent/teams/prompts/SOF-dev-hard-reset-and-reinstall-v1.prompt.md`

## Output artifacts
Each run creates:
- runs/<timestamp>__<prompt-name>/prompt.md
- runs/<timestamp>__<prompt-name>/meta.json
- runs/<timestamp>__<prompt-name>/output.txt (non-interactive mode)

meta.json includes SHA256 prompt hash for exact traceability.

## Manual QA close loop (owner)
- Agent finishes in Ready for QA with evidence.
- Owner validates manually and replies with explicit result:
   - `QA PASS: move to Done`
   - `QA FAIL: back to In Progress` + failure notes
