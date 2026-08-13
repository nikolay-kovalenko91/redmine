# Strengthen API Authentication — Personal Access Tokens (issue #43881)

## 1. Approach

Plan-first: repository reconnaissance and design were completed and written up in
[`doc/issue-43881/plan.md`](doc/issue-43881/plan.md) *before* any application code was
touched, per the explicit gate in that document. Implementation then proceeded
incrementally — model, then authentication integration, then management UI — with a
focused test written and run at each step, followed by the full regression suite and an
independent security review. Detailed rationale, alternatives considered, and trade-offs
live in the plan; this section only summarizes outcomes.

## 2. Implemented scope

- `PersonalAccessToken` model + `personal_access_tokens` table (new, additive).
- Multiple, named, hashed, mandatory-expiry tokens per user.
- Authentication via `X-Redmine-API-Key` header and HTTP Basic (username slot).
- Self-service management from My Account: list, create (with one-time plaintext
  reveal), revoke.
- Physical revocation (row deletion), scoped to the owning user.

## 3. Explicitly deferred scope

Out of scope by instruction: **rate limiting**.

Deferred as optional pillars: scopes/granular endpoint control, audit logging, CORS.

Deferred as scope decisions: `last_used_on` tracking, configurable maximum token
lifetime, admin management of other users' PATs, REST API endpoints for PAT
management, migration of existing legacy keys to PATs, a setting to disable legacy
keys, bulk cleanup of expired PAT rows, and locale backfill beyond `en.yml`.

Deferred as unrelated legacy hardening (each would change existing Redmine behavior):
adding `'api'` to `destroy_tokens` on password change/lock/2FA enrolment, adding `:key`
to `config.filter_parameters`, enforcing `must_change_password?` on the header/param
vector, and any change to `X-Redmine-Switch-User` semantics.

Full rationale for each: `doc/issue-43881/plan.md` §8.

## 4. Architecture and why

A new `PersonalAccessToken` model backed by an additive table, integrated into
`ApplicationController#find_current_user` via a small `if/else` dispatch. This was
chosen over two alternatives:

- **Extending the existing `Token` model** with a `pat` action — rejected: `tokens`
  backs seven actions sharing one lookup/expiry/uniqueness path, so widening `value` or
  hashing it risks all of them, and `Token.destroy_expired`'s return value is asserted
  by an existing test.
- **Minting PATs as Doorkeeper access tokens** — rejected: wrong transport (`Bearer`
  vs. `X-Redmine-API-Key`, breaking existing clients) and wrong semantics (`oauth_scope`
  changes `User#admin?`/`allowed_to?` behavior; a PAT isn't an OAuth grant).

The chosen design has the lowest regression surface: the legacy `Token` model, table,
and lookup are not modified at all.

## 5. PAT behaviour

- **Format**: `pat_` + 40 lowercase hex (160 bits from `Redmine::Utils.random_hex(20)`),
  strictly anchored (`\Apat_[0-9a-f]{40}\z`) — provably disjoint from legacy keys, which
  the legacy lookup already rejects if they contain `_`.
- **Storage**: `Digest::SHA256.hexdigest(plaintext)`, unique-indexed; lookup is one
  indexed query followed by `ActiveSupport::SecurityUtils.secure_compare`.
- **Authentication**: accepted via the `X-Redmine-API-Key` header and HTTP Basic
  (username slot). **Never** accepted as a `?key=` query parameter — a PAT sent that way
  simply fails to authenticate (401), by construction, not by a rejection check.
- **Expiry**: mandatory, date-typed (`expires_on`), no default and no maximum lifetime.
  Valid through the whole of `expires_on`, expires at the start of the next day
  (`expires_on < Date.today`).
- **Revocation**: physical `DELETE` of the row — no soft-delete, no `revoked_at`.
- **Ownership**: `belongs_to :user, optional: false`; deleting a user cascades
  (`dependent: :delete_all`).
- **Management**: list/create/revoke live behind `require_sudo_mode`, deliberately
  *not* declared under `accept_api_auth` — a PAT cannot be used to create or revoke a
  PAT. Revocation is scoped to `User.current.personal_access_tokens`, so one user cannot
  revoke another's token.
- **Reveal**: the plaintext exists only in memory (`attr_reader :plain_token`, backed by
  an ivar with no corresponding column) and is rendered once, in place, never via
  redirect/flash/session/URL.

## 6. Backward compatibility

The legacy `Token` model, `tokens` table, and `User.find_by_api_key` lookup are
unmodified. `ApplicationController#find_current_user` gained an `if/else` around the
existing `User.find_by_api_key(key)` calls (header/param branch and HTTP Basic branch);
the pre-existing precedence, gating (`Setting.rest_api_enabled? && accept_api_auth?`),
Doorkeeper handling, and `X-Redmine-Switch-User` logic are untouched. The full legacy
authentication test file (`test/integration/api_test/authentication_test.rb`) and the
disabled-REST-API, `Token`, and `User` regression suites pass unmodified alongside the
new PAT cases.

## 7. Migration behaviour

One additive migration, `db/migrate/20260813192431_create_personal_access_tokens.rb`:
creates `personal_access_tokens` (`user_id`, `name`, `token_hash`, `expires_on`,
`created_on`), with a unique index on `token_hash` and a plain index on `user_id`. No
foreign key (consistent with the rest of this schema, which has none), no
partial/functional/expression indexes (portable across the sqlite3 / postgresql /
mysql2 CI matrix). Verified in this environment: `db:migrate` applies cleanly against
the stock 6.1.2 schema, `db:rollback` reverts cleanly (table and both indexes dropped),
and a subsequent `db:migrate` re-applies cleanly.

## 8. Install / run / migrate / verify

Standard Redmine 6.1.2 setup, per `doc/INSTALL` and `doc/RUNNING_TESTS`:

```
bundle install                          # doc/INSTALL step 4 (add --without development test
                                         # for a production-only install; omit it, as done here,
                                         # to also get the test/dev groups per doc/RUNNING_TESTS)
# configure config/database.yml (development and test) — doc/RUNNING_TESTS
bundle exec rake generate_secret_token  # doc/INSTALL step 5
bundle exec rake db:migrate             # doc/INSTALL step 7 — creates all tables, including
                                         # personal_access_tokens, and an administrator account
bin/rails server                        # doc/INSTALL step 9 (add -e production for a
                                         # production boot; verified here in development)
```

Commands actually run against this slice in this environment, with their observed results:

```
bundle exec rails db:migrate      # applies cleanly against the 6.1.2 schema
bundle exec rails db:rollback     # reverts cleanly; re-migrate to restore
bundle exec rubocop               # doc/RUNNING_TESTS "Running RuboCop"
                                   # 1026 files inspected, no offenses
bundle exec rake test             # doc/RUNNING_TESTS "Running Tests"
                                   # 5519 runs, 24831 assertions, 0 failures, 0 errors
                                   # (44 skips — pre-existing, unrelated to this change: tests
                                   # needing VCS test repositories not set up in this environment,
                                   # see doc/RUNNING_TESTS "Creating test repositories")
```

Manual verification against the running server (dev DB, `Setting.rest_api_enabled`
temporarily set to `'1'`), via `curl`:

- PAT via `X-Redmine-API-Key` header → 200
- PAT via HTTP Basic (token as username) → 200
- PAT via `?key=` → 401 (rejected)
- Unknown / revoked PAT → 401
- Legacy API key via header, Basic, and `?key=` → 200 (all three, unaffected)

## 9. Limitations and trade-offs

- **The prefix-based dispatch is the security-critical hinge.** The entire
  "legacy is untouched" property depends on `PersonalAccessToken.pat_format?`
  partitioning the credential space correctly and on the legacy lookup's existing
  `_`-rejection guard. Both are covered by tests, but the property is structural, not
  self-evident from either code path in isolation.
- **Hashing forecloses recovery.** Unlike the legacy key (re-readable from the
  database indefinitely via "show API key"), a lost PAT cannot be recovered — the
  one-time reveal is the only chance. This is the intended security property, at a real
  UX cost versus the legacy mechanism.
- **PAT management remains session-authenticated only**, following the existing My
  Account API-key management pattern. PAT credentials cannot be used to create or
  revoke PATs.

Reasoning behind a few specific decisions:

- **`?key=<PAT>` is forbidden as an insecure option.** During repository analysis I
  found that legacy `?key=` credentials may be exposed in application/request logging.
  I deliberately left the legacy transport unchanged for backward compatibility and did
  not extend query-parameter authentication to new PATs. Filtering legacy `:key`
  parameters is a separate hardening opportunity outside this slice.
- **PATs survive password changes.** Tokens owned by inactive/locked users cannot
  authenticate, but changing a password does not revoke a user's PATs. Password
  credentials and integration credentials have different lifecycles — a password
  authenticates an interactive human login, a PAT authenticates a server-to-server/CI
  integration — so automatically revoking PATs on password change would introduce an
  additional credential-lifecycle policy outside this focused slice.
- **`rake locales:update` was not run.** Backfilling the other 49 locale files is not
  yet necessary for this slice; keeping the diff to `en.yml` only gives the reviewer a
  clear, short diff to review.

## 10. AI workflow

- ChatGPT was used as a secondary reasoning and workflow-design tool before and 
  during the planning phase. I used it to compare agentic workflow options, challenge 
  design assumptions, and formulate follow-up questions for Claude Code. 
  Claude Code remained the repository-facing implementation agent, while repository 
  evidence, deterministic tests, and my own review were the decision gates.
- **Claude Code** was used throughout, across two sessions.
- Repository reconnaissance was performed with the **Explore** subagent (two parallel
  investigations: the REST API auth flow, and the Token/User/My Account models), whose
  findings anchor every "verified repository fact" cited in the plan.
- Implementation was blocked behind an **explicit human architecture-approval gate**:
  the plan was written and reviewed as a standalone step, and application code was not
  touched until that plan was explicitly approved in a separate instruction.
- Implementation itself ran as a **Sonnet-driven loop**: one behavior at a time,
  smallest existing convention first, focused test before/alongside the change, fix,
  then the surrounding regression tests, before moving to the next behavior.
- **Deterministic tests and migrations were the acceptance gate**, not model
  self-assessment: `bundle exec rubocop`, `bundle exec rake test`, and
  `db:migrate`/`db:rollback` all had to pass before completion was reported, per
  `CLAUDE.md`.
- An **independent `security-reviewer` subagent** — read-only, no access to the
  implementation conversation or rationale beyond the plan and the diff — assessed the
  finished implementation separately and reported two low-severity findings.
- **The human made the final call** on those findings (accepted both as-is without
  code changes); AI proposed, the human decided.

Raw AI session artifacts (recon, design, and implementation transcripts) are kept
unedited in [`AI_LOGS/`](AI_LOGS).
