# Prompt ID: SOF-1-committee-to-spec-v1
# Purpose: Turn an idea into executable agent spec with viability review

Act as a committee of specialized teammates and transform the idea into an executable plan.

Business context:
- We want SOF-1 executed in a reusable, ticket-driven way.
- Goal: recover end-to-end flow after reinstall and validate SOF-2/SOF-12 behavior.
- Owner manually validates QA and decides final acceptance.

Spawn 4 teammates:
1. product-analyst (Sonnet)
   - Translate idea to problem statement, scope, and acceptance criteria.
2. architecture-reviewer (Sonnet)
   - Validate technical feasibility and impact across installer/api/console/templates/infra.
3. risk-reviewer (Haiku)
   - Identify security, data, rollback, and operability risks.
4. execution-planner (Sonnet)
   - Build an implementable ticket plan with dependency order.

Deliverables:
1. Problem statement
2. Technical scope
3. Acceptance criteria (testable)
4. Risk table with mitigations
5. Ticket breakdown (epic/task/subtask)
6. Validation matrix (dev, staging, prod if applicable)
7. Definition of done including manual QA by owner

Rules:
- No code changes in this phase.
- Output must be concise and actionable.
- Use language suitable for Jira ticket descriptions.
