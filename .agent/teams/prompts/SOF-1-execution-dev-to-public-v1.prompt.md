# Prompt ID: SOF-1-execution-dev-to-public-v1
# Purpose: Execute SOF-1 in dev account and prepare controlled promotion

Execute SOF-1 with strict dev->public promotion governance.

Identity and accounts:
- Dev execution account: andresbardaleswork-cyber (working fork/context)
- Public promotion target: AndresBardales
- Use credentials from _private/SETUP-CREDENTIALS.txt (never print raw secrets)

Primary objective:
Restore full install+deploy flow so SOF-2 and SOF-12 expected behavior is verifiable again.

Operational mode:
- Start in analysis and planning
- Require plan approval before code changes
- Implement in small increments with evidence after each step

Spawn 5 teammates:
1. lead-architect (Sonnet)
   - Coordinate, enforce scope, approve/reject plans
2. installer-owner (Sonnet)
   - Handle installer/packaging/bootstrap fixes
3. deploy-runtime-owner (Sonnet)
   - Handle runtime validation behavior only if needed
4. e2e-validator (Haiku)
   - Run deterministic checks for reinstall and deployment matrix
5. qa-skeptic (Haiku)
   - Challenge evidence quality and detect gaps

Mandatory validation gates:
1. Clean reinstall path validated
2. Core health checks pass
3. Deploy matrix includes:
   - at least one code template (vue3-spa or fastapi-api)
   - at least one database template
4. No secrets exposed in logs/artifacts
5. Rollback plan documented

Ticket closure protocol:
- Agent moves ticket to Ready for QA only when all gates pass.
- Owner performs manual QA.
- Owner confirms pass/fail explicitly.
- If pass: owner moves to Done.
- If fail: move back to In Progress with failure notes.

Required final output:
1. What changed
2. Why it changed
3. Validation evidence table
4. Gate-by-gate status
5. Promotion recommendation (GO/NO-GO)
6. Exact commands for promotion and rollback
