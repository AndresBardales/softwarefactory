# Dev to Public Promotion Checklist

Use this checklist before promoting from andresbardaleswork-cyber to AndresBardales.

## Identity and Scope
- [ ] Work executed in dev context first
- [ ] Public target identified (repo + branch)
- [ ] No secrets committed

## Deterministic Validation
- [ ] Cleanup baseline documented
- [ ] Fresh install validated
- [ ] Core health checks passed
- [ ] Deployment matrix passed (at least 1 DB + 1 code template)
- [ ] Evidence captured in run artifact

## Quality and Traceability
- [ ] Prompt version used is committed in .agent/teams/prompts/
- [ ] Run metadata contains prompt hash and timestamp
- [ ] Change summary and rollback are documented

## Promotion Readiness
- [ ] GO/NO-GO decision recorded
- [ ] Promote commands prepared
- [ ] Rollback plan prepared

## Suggested Promote Command Pattern
Use your normal git remotes and branch strategy, for example:
1. Push validated dev branch
2. Open PR to public target
3. Verify pipeline
4. Merge only after checks pass
