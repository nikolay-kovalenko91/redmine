# Redmine Strengthen API authentication (https://www.redmine.org/issues/43881)

## Goal

Implement a focused, production-defensible slice of the Redmine API
authentication challenge based on Redmine 6.1.2.

The required core is working Personal Access Tokens (PATs).

## Scope constraints

- Rate limiting is explicitly out of scope.
- Do not implement optional pillars unless the approved plan explicitly
  includes them.
- Prefer a small complete vertical slice over broad partial implementation.
- Do not introduce unrelated refactors.
- Do not introduce new dependencies without explicit human approval.
- Preserve existing Redmine behaviour unless the approved plan explicitly
  changes it.

## Engineering workflow

1. Inspect existing repository behaviour before proposing changes.
2. Separate repository evidence from assumptions.
3. Do not modify application code before the implementation plan is
   explicitly approved by the human.
4. Record approved scope, alternatives considered, decisions, rationale,
   trade-offs, deferred work, acceptance criteria and verification strategy
   in `docs/plan.md`.
5. During implementation, work incrementally and use tests as the primary
   deterministic feedback loop.
6. If implementation requires changing an approved architecture, migration
   strategy, security invariant or scope, stop and request human approval.
7. Do not expand scope simply because an adjacent improvement is easy.
8. After three unsuccessful attempts to resolve the same failure, stop and
   report evidence instead of continuing speculative changes.
9. Before completion, all mandatory quality gates defined below must pass.
   A task is not complete because focused tests alone are green.
10. Treat independent review findings as recommendations; do not silently
    change approved scope to satisfy them.

## Security rules

- Never place credentials or unrelated personal information in source files,
  prompts, commands or logs.
- Authentication and credential-storage decisions require explicit reasoning.
- Backward compatibility with existing Redmine API authentication must be
  considered explicitly.
- Security-sensitive behaviour must be demonstrated by deterministic tests.
- Never weaken a test or security invariant merely to make a test pass.

## Verification and quality gates

Deterministic verification is mandatory. Do not declare the task complete
based only on code inspection or reasoning.

### During implementation

- Run focused tests for the behaviour currently being changed.
- After changing authentication behaviour, run the relevant API
  authentication regression tests.
- After changing token-management behaviour, run the relevant controller
  or model tests.
- Do not weaken or remove an existing test merely to make the implementation
  pass.

### Database migrations

Whenever a migration is added or changed:

1. Run:

   `bundle exec rails db:migrate`

2. Verify that the migration completes successfully.
3. Run the relevant tests after the migration.
4. Before final completion, verify that the migration can be applied starting
   from the expected Redmine 6.1.2 database schema.

If the migration is intended to be reversible, verify rollback when practical.

A migration failure is a release-blocking failure.

### Mandatory final checks

Before declaring the implementation complete, all of the following must pass:

1. Ruby/Rails style checks:

   `bundle exec rubocop`

2. Full automated test suite:

   `rake test`

3. Database migrations:

   `bundle exec rails db:migrate`

4. Relevant focused authentication and PAT tests.

5. Application boot after migrations.

6. Manual or deterministic verification of the implemented PAT happy path.

7. Verification that invalid, expired and revoked PATs are rejected.

8. Verification that existing legacy API-key authentication still works.

Do not report completion while any mandatory check is failing.

If a mandatory check cannot be run because of an environment problem,
stop and report the exact command, error and evidence instead of silently
skipping it.

## Repository conventions

- Follow existing Redmine/Rails patterns discovered in the repository before
  introducing a new abstraction.
- Prefer the smallest existing integration seam that satisfies the approved
  design.
- Avoid unrelated formatting or refactoring.

## Human-owned decisions

The human candidate owns:

- final scope;
- architecture choice;
- data model and migration decisions;
- security invariants;
- backward-compatibility trade-offs;
- acceptance or rejection of review findings;
- final verification;
- claims made in the README.

AI may research, propose alternatives, implement approved work, run checks,
debug ordinary failures, and review the result.