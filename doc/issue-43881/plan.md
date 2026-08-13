# Personal Access Tokens for the Redmine REST API

Issue: <https://www.redmine.org/issues/43881> — "Strengthen API authentication"
Base: Redmine 6.1.2 (`lib/redmine/version.rb` — MAJOR 6, MINOR 1, TINY 2, BRANCH `stable`)
Branch: `feature/43881-strengthen-API-authentication`
Date: 2026-08-13

**Status: plan approved. Implementation not started and not yet authorised.**
Creating this document is the only action taken so far. Application code changes require
a separate, explicit approval (see [Execution gate](#execution-gate)).

---

## 1. Problem

Redmine 6.1.2's REST API credential is a single, per-user, plaintext, never-expiring
string stored in `tokens.value`:

- **Plaintext at rest.** `db/schema.rb:549-557` stores `value` as a plain `string(40)`;
  `token.rb:118` looks it up with `Token.find_by(:action =>, :value =>)`. A database
  disclosure yields directly usable credentials. By contrast, the OAuth tokens added in
  6.1 *are* hashed (`config/initializers/30-redmine.rb:41` `hash_token_secrets`).
- **One per user.** `token.rb:39` `add_action :api, max_instances: 1` — a user cannot
  issue separate credentials per integration, so revoking one revokes all of them.
- **Never expires.** Same line, `validity_time: nil`.
- **Unnamed.** No way to tell which integration a credential belongs to, which makes
  informed revocation impossible.
- **Survives credential changes.** `user.rb:958-967` `destroy_tokens` deletes
  `['recovery', 'autologin', 'session']` on password change, lock, or 2FA enrolment.
  `'api'` is deliberately absent.

## 2. Approved scope

Add **Personal Access Tokens (PATs)** as a parallel, additive credential mechanism:
multiple named tokens per user, hashed at rest, mandatory expiry, individually revocable,
managed self-service from My Account.

The legacy Token storage and User.find_by_api_key lookup remain unchanged. ApplicationController is extended only to dispatch PAT-formatted credentials to the new lookup. 
PATs are a new mechanism alongside it, not a replacement for it.

Out of scope by instruction: **rate limiting**. Optional pillars (scopes, granular
endpoint control, audit logging, CORS) are **not** implemented — see
[§8 Deferred work](#8-deferred-work).

## 3. Reconnaissance — verified repository facts

Every design decision below rests on these, all verified by direct inspection.

| Fact | Evidence |
|---|---|
| Single authentication seam | `app/controllers/application_controller.rb:112-173` `find_current_user` |
| API credential block is gated on `Setting.rest_api_enabled? && accept_api_auth?` — **not** on `api_request?` | `application_controller.rb:130`. API credentials therefore work on HTML requests for opted-in actions; exercised by `test/integration/api_test/authentication_test.rb:131-163` |
| Key entry points | `application_controller.rb:727-734` `api_key_from_request` (param wins over header); `:152` (HTTP Basic username) |
| Precedence is a plain `if/elsif` chain | `application_controller.rb:131/134/142` — a present-but-invalid `key` param short-circuits Doorkeeper and Basic |
| Legacy keys are plaintext and never expire | `db/schema.rb:549-557`; `token.rb:39` |
| Legacy lookup rejects any key containing `_`, `-` or `.` | `token.rb:116` `return nil unless action.present? && /\A[a-z0-9]+\z/i.match?(key)` |
| `Token` lookup trio to mirror | `token.rb:96-126` `find_active_user` / `find_user` / `find_token` |
| `belongs_to` is **optional** in this app | No `config.load_defaults` and no `belongs_to_required_by_default` anywhere in `config/`; `activerecord-7.2.3/lib/active_record/core.rb:89` declares the attribute with no default (→ falsy). Corroborated by `test/unit/token_test.rb:27-32` saving a userless `Token`. |
| Core uses `t.date` for date columns | `db/schema.rb:273` `due_date`, `:283` `start_date`, `:535` `spent_on`, `:606` `effective_date` |
| Date-boundary idiom | `issue.rb:994`, `version.rb:268` — `x < User.current.today`; `user.rb:583-589` `User#today` falls back to `Date.today` when `time_zone` is nil |
| Column naming | Every Redmine-core table uses `_on`; every `_at` column belongs to a vendored or generated table (doorkeeper, `imports`, `reactions`) |
| Timezone | `config/application.rb:37` `config.active_record.default_timezone = :local`; `config.time_zone` commented out (`:51-53`). Core consistently uses `Time.now`, never `Time.zone.now` (`token.rb:70`, `token.rb:123`, `user.rb:363`) |
| Migration convention | `ActiveRecord::Migration[7.2]`; `db/schema.rb` (not `structure.sql`); **no FK constraints anywhere** |
| CI database matrix | `.github/workflows/tests.yml:11-15` — sqlite3 / postgresql / mysql2 |
| Credential management is already session-only | `my_controller.rb:26-29` — `show_api_key` / `reset_api_key` are **absent** from `accept_api_auth` and **present** in `require_sudo_mode` |
| `require_sudo_mode` is off by default | `config/configuration.yml.example:167` "Disabled by default"; `lib/redmine/sudo_mode.rb:233` |
| Revocation precedent is physical deletion | `token.rb:144`, `user.rb:966`, `user.rb:993`, `my_controller.rb:145` — no soft-delete pattern for credentials exists in core |
| Reusable RNG | `Redmine::Utils.random_hex` (`lib/redmine/utils.rb`), used by `token.rb:129` |
| Reusable copy UI | `app/javascript/controllers/api_key_copy_controller.js` |
| No shared API-auth test macros exist in 6.1.2 | `should_allow_api_authentication` was removed; `test/test_helper.rb:433-505` defines `Redmine::ApiTest::Base` only |

Confirmed by the maintainer, not re-verified here: the baseline test suite is green, and
`db/redmine.sqlite3` reflects the stock Redmine 6.1.2 schema.

### Open assumption

The **mandatory expiry** requirement rests on the maintainer's statement of the ticket's
contents. There is no copy of issue #43881 in this repository, so it could not be
verified from source. Every other requirement below is traceable to repository evidence.

## 4. Alternatives considered

### Option 1 — New `PersonalAccessToken` model and table — **CHOSEN**

Separate ActiveRecord model backed by an additive `personal_access_tokens` table.
Integration is a few lines inside `find_current_user`.

- Regression surface: **lowest.** `Token`, `tokens`, `destroy_expired` and
  `delete_previous_tokens` are untouched, so `test/unit/token_test.rb` and the
  session / autologin / recovery / register / feeds / twofa_backup_code actions cannot
  regress.
- Migration impact: one additive `create_table`, trivially reversible, portable.
- Backward compatibility: total — the legacy path is not modified.
- Security: hashing, expiry, per-token identity and revocation are all natural.
- Complexity: moderate, and concentrated in new files.

### Option 2 — Extend the existing `Token` model with a `pat` action

Add `name` / `expires_on` columns to `tokens`, widen `value`, add
`add_action :pat, max_instances: nil`.

- Regression surface: **highest.** `tokens` backs seven actions. Changing `value`'s width
  or semantics, the `token.rb:116` format guard, `delete_previous_tokens`'s
  `max_instances` logic, or `destroy_expired`'s Arel affects all of them.
  `test/unit/token_test.rb` asserts the **return value** of `Token.destroy_expired`.
- Migration impact: `change_column` on a hot shared table carrying a unique index — the
  2013 migration adding that index already warns it "may take some time".
- Security: hashing PAT values would require either hashing everything (breaking
  autologin and recovery lookups, which need plaintext equality) or making `value`
  polymorphic per action — an unpleasant invariant to maintain.
- **Rejected:** deceptively cheap to write, expensive to verify.

### Option 3 — Mint Doorkeeper access tokens as PATs

Reuse `Doorkeeper::AccessToken` with a synthetic "personal" application.

- Gets hashing, expiry, revocation and scopes for free; `find_current_user:134` already
  accepts such tokens; no migration at all.
- Backward compatibility: **poor.** PATs would arrive as `Authorization: Bearer`, not via
  `X-Redmine-API-Key`, so every existing Redmine client would need changing. Worse,
  `api_key_from_request` takes precedence over the Bearer branch, so a client sending
  both breaks.
- Security semantics are wrong: a PAT is not an OAuth grant, there is no application or
  consent to point at, and setting `oauth_scope` silently changes `User#admin?`
  (`user.rb:736-744`) and `User#allowed_to?` (`user.rb:770`, `:789`) — a behavioural
  change to existing code paths.
- **Rejected:** least code, highest conceptual and review risk.

## 5. Decisions and rationale

### 5.1 Token format — `pat_` + 40 lowercase hex

44 characters total, generated with `Redmine::Utils.random_hex(20)` (160 bits) — the same
generator as `token.rb:129`.

The prefix is not cosmetic. `token.rb:116` rejects any key not matching
`/\A[a-z0-9]+\z/i`, so a `pat_`-prefixed string **cannot** be resolved as a legacy token
even if dispatch were buggy. The two credential namespaces are provably disjoint, and a
dispatch error fails closed rather than authenticating the wrong principal. The prefix is
also greppable for secret scanning.

### 5.2 Transport — `X-Redmine-API-Key` header and HTTP Basic only

PATs are **not** accepted as a `?key=` query parameter. A URL-borne credential survives in
places Rails cannot reach:

1. Reverse-proxy and web-server access logs (nginx `$request`, Apache `%r`) — unaffected
   by `config.filter_parameters`.
2. `Referer` headers leaked to third parties. This is sharper in Redmine than usual
   because `application_controller.rb:130` is not gated on `api_request?`, so an API
   credential authenticates **HTML** responses on `accept_api_auth` actions.
3. Browser history, bookmarks, and URLs pasted into tickets or chat.
4. CDN, WAF and corporate TLS-terminating proxy logs.
5. `request.url` in exception reports and error pages.

Rails' own logs *are* covered by `filter_parameters` — `railties/lib/rails/rack/logger.rb:59`
uses `request.filtered_path`, built from `filtered_query_string`
(`actionpack/.../filter_parameters.rb:45-46`) — but that addresses only item 0 of the list.

Legacy keys keep `?key=` unchanged for backward compatibility.

This requires **no rejection code**: a PAT sent as `?key=` falls through to
`User.find_by_api_key`, which returns nil via the `token.rb:116` guard. The dispatch
simply does not attempt a PAT lookup when the value came from the parameter.

### 5.3 Storage — SHA-256, not bcrypt

Store `Digest::SHA256.hexdigest(plaintext)` (64 hex chars), unique-indexed. Lookup is a
single indexed query on the hash, followed by
`ActiveSupport::SecurityUtils.secure_compare` as defence in depth, mirroring
`token.rb:121`.

bcrypt was rejected: the secret is already 160 bits of `SecureRandom`, not a
human-chosen password, so a slow KDF buys nothing — and bcrypt cannot be indexed, forcing
either an id component in the token or a full table scan.

A side benefit over the legacy design: the index is over the hash, not the secret, so
index-timing side channels cannot leak the credential.

### 5.4 Expiry — mandatory, date-typed, midnight boundary

`expires_on` is a **`t.date`**, `null: false`.

A PAT is valid through the whole of `expires_on` and dies at **midnight at the start of
the next day**:

```ruby
def expired?
  expires_on < Date.today
end
```

A date column encodes that boundary exactly and removes all timezone-serialization
subtlety — relevant because `config.active_record.default_timezone = :local` while
`Time.zone` is UTC, a combination that makes `Time.now` and `Time.zone.now` diverge on
any non-UTC server.

`Date.today` (system-local) is used rather than Redmine's usual `User.current.today` idiom
(`issue.rb:994`, `version.rb:268`) because **`User.current` is not yet resolved during
authentication** — it is precisely what `find_current_user` is computing. `Date.today` is
exactly the fallback branch of `User#today` (`user.rb:584-588`), and an authentication
decision must not depend on a display preference.

**No default expiry and no maximum lifetime.** The user must supply a date. A blank field
fails validation with "Expiration date is required"; a past date is rejected; today is
accepted, yielding a one-day token. A configurable maximum lifetime was considered and
deferred as unrequested policy.

### 5.5 Ownership — `belongs_to :user, :optional => false`

Explicit and load-bearing. Because this application sets no `config.load_defaults`,
`belongs_to_required_by_default` is falsy, so a bare `belongs_to` would happily persist an
ownerless token. `Token` depends on that laxity deliberately (`token.rb:21`;
`test/unit/token_test.rb:27-32` saves a userless token) — a PAT must not.

`:optional => false` also validates that the association **resolves**, so a dangling
`user_id` pointing at no row is rejected, not merely a nil one.

### 5.6 Revocation — physical `DELETE`, not `revoked_at`

1. Redmine's precedent is unanimous: `token.rb:144` `scope.delete_all`, `user.rb:966`,
   `user.rb:993`, `my_controller.rb:145` `.destroy`. No soft-delete or tombstone pattern
   for credentials exists in core. Doorkeeper uses `revoked_at`, but it is a vendored gem
   that needs it for refresh-token rotation, which this design does not have.
2. **Fail-safe defaults.** `revoked_at` would require every lookup to carry
   `revoked_at IS NULL`; a forgotten condition is an authentication bypass. With deletion,
   that condition cannot be forgotten because it does not exist.
3. `revoked_at` earns its keep mainly as an audit trail, and audit logging is deferred.

Accepted cost: no record that a token existed and was revoked.

### 5.7 Account-state rules

| Condition | Behaviour | Basis |
|---|---|---|
| Unknown token | 401 | — |
| Expired (`expires_on < Date.today`) | 401 | §5.4 |
| Revoked (row deleted) | 401 | §5.6 |
| **Inactive user** | 401 | Parity with `Token.find_active_user` (`token.rb:96-101`). `active?` is `status == STATUS_ACTIVE` (`principal.rb:146-147`), so **locked (3) and registered (2) are both rejected** |
| User destroyed | PATs deleted | `has_many … :dependent => :delete_all`, mirroring the intent of `user.rb:993` |
| 2FA active | **No effect on PATs** | Intended design, not a gap: `application_controller.rb:146-150` blocks Basic username/password under 2FA with the message *"HTTP Basic authentication is not allowed. Use API key instead"* — token credentials **are** Redmine's 2FA-compatible path |
| Password changed | **PATs survive** | Parity with legacy `'api'` tokens (`user.rb:958-967`). Revoking on password change was considered and rejected as excessive |
| `must_change_password?` | **No new check added** | See below |

No `must_change_password?` enforcement is added. PATs presented via HTTP Basic are already
covered by the pre-existing check at `application_controller.rb:154-157`, which sits
outside the `authenticate_with_http_basic` block and applies to whatever `user` resolved
to; PATs presented via the header are not.

**This asymmetry is inherited from Redmine 6.1.2, not introduced here** — legacy keys
behave identically today. It is recorded explicitly because a reviewer will notice it.
Making it uniform would be an unrelated authentication-policy change, deliberately
excluded.

### 5.8 Management endpoints — session-only, structurally

PAT management actions are added to `require_sudo_mode` and are deliberately **not** added
to `accept_api_auth`. The consequence needs no new authorization code:

1. `find_current_user:130` opens the API block only when `accept_api_auth?` is true.
2. For an undeclared action it is false (`application_controller.rb:653-655`).
3. The API block is skipped entirely → `User.current` is anonymous.
4. `before_action :require_login` (`my_controller.rb:22`) fires.
5. `require_login`'s `format.api` branch returns **403** (`application_controller.rb:293-297`).

**A PAT therefore cannot mint or revoke a PAT**, closing the escalation path where a
stolen credential issues a replacement to outlive its own revocation. This mirrors exactly
how `show_api_key` / `reset_api_key` are already protected (`my_controller.rb:26-29`).

Revocation additionally scopes the lookup to the owner —
`User.current.personal_access_tokens.find(params[:id])` — so one user cannot revoke
another's token.

### 5.9 Create-and-reveal — render, never redirect

The plaintext is generated in memory, returned once in the create response, and never
persisted. Specifically:

- `attr_reader :plain_token` is backed by an ivar, and **there is no corresponding column**,
  so ActiveRecord physically cannot persist it. The guarantee is structural, not a
  discipline.
- The create action **renders in place** rather than redirecting, which is what keeps the
  value out of `flash`, out of the session, and out of the URL. This diverges deliberately
  from `reset_api_key` (`my_controller.rb:139-150`), which can redirect only because it
  re-reads plaintext from the database — an option hashing removes.
- Logs are unaffected at creation because the token is generated server-side and is never
  an inbound parameter; Rails does not log response bodies.

## 6. Design summary

### Migration — `db/migrate/<ts>_create_personal_access_tokens.rb` (`[7.2]`)

```ruby
create_table :personal_access_tokens do |t|
  t.integer  :user_id,    null: false
  t.string   :name,       limit: 60, null: false
  t.string   :token_hash, limit: 64, null: false
  t.date     :expires_on, null: false
  t.datetime :created_on, precision: nil, null: false
end
add_index :personal_access_tokens, :token_hash, unique: true
add_index :personal_access_tokens, :user_id
```

Every field justified:

| Field | Why |
|---|---|
| `user_id` | Owner. `integer`, no FK — Redmine has none. `null: false` is load-bearing given §5.5 |
| `name` | The point of PATs over a single key: revocation is only meaningful if tokens are distinguishable. `limit: 60` follows the house habit of bounded strings (`tokens.action limit: 30`) |
| `token_hash` | SHA-256 hex is exactly 64 chars. The unique index provides both the constraint and the single-query lookup path |
| `expires_on` | Mandatory expiry; `date` per §5.4 |
| `created_on` | Needed by the UI, mirroring `label_api_access_key_created_on` (`en.yml:1032`, rendered at `_sidebar.html.erb:39`) |

Deliberately **absent**: `updated_on` (nothing mutates a PAT after creation),
`last_used_on` (tracking deferred — an always-null column is a false affordance in both
schema and UI), `revoked_at` (§5.6).

Both indexes are plain single-column B-trees — no partial, functional or expression
indexes — so they are portable across the sqlite3 / postgresql / mysql2 CI matrix.

### Model — `app/models/personal_access_token.rb`

Mirrors `Token`'s lookup trio (`token.rb:96-126`):

```ruby
PREFIX        = 'pat_'
TOKEN_PATTERN = /\Apat_[0-9a-f]{40}\z/

belongs_to :user, :optional => false
validates :name,       :presence => true, :length => {:maximum => 60}
validates :expires_on, :presence => true
validate  :expires_on_cannot_be_in_the_past

def self.pat_format?(key)         # cheap gate, no DB hit
def self.hash_token(plain)        # Digest::SHA256.hexdigest
def self.find_token(plain)        # format -> hash lookup -> secure_compare -> expired?
def self.find_user(plain)
def self.find_active_user(plain)  # + user.active?
def expired?                      # expires_on < Date.today
def generate_token!               # sets @plain_token and token_hash
attr_reader :plain_token          # ivar only — no column, cannot be persisted
```

`User` gains exactly one line: `has_many :personal_access_tokens, :dependent => :delete_all`.

### Authentication integration — two edits only

`application_controller.rb:131-133`:

```ruby
if (key = api_key_from_request)
  if PersonalAccessToken.pat_format?(key)
    # Personal access tokens are never accepted as a query parameter
    user = PersonalAccessToken.find_active_user(key) if params[:key].blank?
  else
    user = User.find_by_api_key(key)          # UNCHANGED
  end
elsif access_token = Doorkeeper.authenticate(request)   # UNCHANGED
```

`application_controller.rb:152`, inside the existing Basic branch:

```ruby
user ||= if PersonalAccessToken.pat_format?(username)
           PersonalAccessToken.find_active_user(username)
         else
           User.find_by_api_key(username)     # UNCHANGED
         end
```

Precedence, the `rest_api_enabled?` / `accept_api_auth?` gate, Doorkeeper, atom-key
authentication and `X-Redmine-Switch-User` are all untouched. The legacy path costs one
extra regex match per request.

### Routes — `config/routes.rb`, beside the `my/` block at `:97-99`

```ruby
get    'my/personal_access_tokens',     :to => 'my#personal_access_tokens', :as => 'my_personal_access_tokens'
post   'my/personal_access_tokens',     :to => 'my#create_personal_access_token'
delete 'my/personal_access_tokens/:id', :to => 'my#revoke_personal_access_token', :as => 'my_personal_access_token'
```

Explicit routes rather than `resources`, matching the hand-written style of the
surrounding `my/` block. The verbose path avoids any confusion with the legacy "API key"
in URLs, logs and UI.

### Views and locales

New `app/views/my/personal_access_tokens.html.erb` — list, create form, one-time reveal
panel — reusing the existing Stimulus copy controller. Sidebar link in
`app/views/my/_sidebar.html.erb`, inside the existing `if Setting.rest_api_enabled?` block
(`:21`).

**`config/locales/en.yml` only.** `rake locales:update` backfill of the other 49 locale
files is deliberately skipped to keep the review diff short.

### Files to change

| File | Change |
|---|---|
| `db/migrate/<ts>_create_personal_access_tokens.rb` | new |
| `app/models/personal_access_token.rb` | new |
| `app/models/user.rb` | `has_many … :dependent => :delete_all` (one line) |
| `app/controllers/application_controller.rb` | dispatch at `:131-133` and `:152` only |
| `app/controllers/my_controller.rb` | 3 actions + `require_sudo_mode`; **no** `accept_api_auth` |
| `config/routes.rb` | 3 routes |
| `app/views/my/personal_access_tokens.html.erb` | new |
| `app/views/my/_sidebar.html.erb` | link |
| `config/locales/en.yml` | new keys |
| `test/unit/personal_access_token_test.rb` | new |
| `test/integration/api_test/authentication_test.rb` | PAT cases appended |
| `test/functional/my_controller_test.rb` | management cases appended |
| `test/fixtures/personal_access_tokens.yml` | new |

## 7. Acceptance criteria

A PAT-authenticated request succeeds via the `X-Redmine-API-Key` header and via HTTP
Basic, and is rejected when the token is unknown, expired, revoked, owned by a non-active
user, or sent as a query parameter. Legacy API-key authentication continues to work
unchanged on all three of its existing vectors. A PAT cannot be used to create or revoke
a PAT. One user cannot revoke another's PAT. The plaintext is disclosed exactly once and
is not recoverable from the database.

Expressed as required tests:

1. Happy path — `X-Redmine-API-Key` header → 200; HTTP Basic username → 200
2. PAT via `?key=` → 401 (query-parameter authentication forbidden)
3. Unknown token → 401
4. Expiry boundary — `expires_on = Date.today` valid; `expires_on = Date.today - 1` → 401
5. Revoked (row deleted) → 401
6. Locked user (`STATUS_LOCKED`) → 401; registered user (`STATUS_REGISTERED`) → 401
7. PAT rejected when `Setting.rest_api_enabled = '0'`
8. PAT rejected on an action without `accept_api_auth`
9. **Regression:** legacy 40-hex key still works via `?key=`, header and Basic
10. `POST /my/personal_access_tokens.json` with a PAT → 403 (no privilege escalation)
11. User A cannot revoke User B's PAT → 404, and B's token still authenticates
12. Plaintext appears in the create response exactly once; a follow-up GET does not contain it
13. `token_hash` in the database ≠ plaintext; no column holds plaintext
14. Blank expiry → "Expiration date is required"; past date rejected
15. `user.destroy` destroys that user's PATs
16. A PAT value passed to `User.find_by_api_key` returns nil (namespace disjointness)
17. A PAT without a valid user cannot be created — `user` nil → invalid, **and** a
    `user_id` pointing at a nonexistent row → invalid

## 8. Deferred work

Deferred by instruction:

- **Rate limiting** — explicitly out of scope.

Deferred as optional pillars not required by the core:

- **Scopes and granular endpoint control.** The integration seam exists and is recorded
  here for future work: `Role#allowed_to?(action, scope)` (`role.rb:204-210`, `:304-311`),
  `User#allowed_to?` threading `@oauth_scope` (`user.rb:770`, `:789`), and `User#admin?`
  (`user.rb:736-744`). A PAT scope would set the same ivar. No code now.
- **Audit logging.**
- **CORS.**

Deferred as scope decisions:

- `last_used_on` tracking, and the corresponding "last used" UI column.
- Configurable maximum token lifetime.
- Admin management of other users' PATs.
- REST API endpoints for PAT management — deliberately excluded, see §5.8.
- Migration of existing legacy keys to PATs; a `Setting` to disable legacy keys.
- Bulk cleanup of expired PAT rows (cf. `Token.destroy_expired`, which is itself invoked
  only from `lib/tasks/redmine.rake:39`, never automatically).
- `rake locales:update` backfill of the other 49 locale files.

Deferred as **unrelated legacy hardening** — each is a real improvement, but each changes
existing Redmine behaviour and therefore needs its own decision:

- Adding `'api'` to the `destroy_tokens` action list (`user.rb:962`) so legacy keys are
  revoked on password change, lock and 2FA enrolment.
- Adding `:key` to `config.filter_parameters` (`application.rb:68`) so legacy keys stop
  appearing in Rails request logs. Now purely a legacy concern, since PATs never travel
  in a URL.
- Enforcing `must_change_password?` on the legacy header/parameter vector (§5.7).
- Any change to `X-Redmine-Switch-User` semantics.

## 9. Verification strategy

### During implementation

- `bin/rails test test/unit/personal_access_token_test.rb`
- `bin/rails test test/integration/api_test/authentication_test.rb` — Existing legacy authentication test cases must continue to pass unchanged; 
this is the primary evidence that the legacy path is untouched
- `bin/rails test test/unit/token_test.rb test/unit/user_test.rb`
- `bin/rails test test/functional/my_controller_test.rb`
- `bin/rails test test/integration/api_test/disabled_rest_api_test.rb`

### Mandatory gates before completion

1. `bundle exec rubocop`
2. `bundle exec rake test` — full suite
3. `bundle exec rails db:migrate` from the stock 6.1.2 schema, then `bundle exec rails db:rollback`
   to demonstrate reversibility
4. Application boots after migration
5. Manual curl of the happy path via header and via Basic, plus manual confirmation that
   `?key=<pat>` is rejected
6. Manual confirmation that an existing legacy API key still authenticates

A migration failure is a release-blocking failure. No gate may be skipped silently; if one
cannot run for environment reasons, the exact command, error and evidence are reported
instead.

## 10. Trade-offs and risks

**1. Prefix-based dispatch is the security-critical hinge.** The whole "legacy is
untouched" claim rests on `pat_format?` partitioning the credential space correctly. The
mitigation is strong — the `token.rb:116` guard makes a `pat_`-prefixed string
unresolvable as a legacy token, so a dispatch bug fails closed. But the property is
implicit: if that guard were ever relaxed, or `pat_format?` loosened, the partition would
weaken silently. Mitigated by a strictly anchored regex (not `start_with?`) and by
acceptance test 16.

**2. Hashing forecloses recovery, and the reveal flow is the only chance.** Unlike
`reset_api_key`, which can re-read plaintext from the database indefinitely, a lost PAT is
gone. This is the correct security property but a genuine UX regression against the legacy
key, and it makes the render-don't-redirect requirement load-bearing: a later refactor
that "tidies" it into a redirect would either break the feature or push the secret into
flash. Mitigated by a comment at the call site and by acceptance test 12.

**3. Management protection depends on an absence, and sudo mode is off by default.**
"A PAT cannot mint a PAT" is enforced by *not* listing the actions in `accept_api_auth` —
a negative invariant, invisible at the point where it protects, and silently destroyed by
anyone who later adds the declaration for convenience. Compounding this,
`require_sudo_mode` is a no-op in a default install, so the real guard is the session
requirement alone. This is no weaker than `reset_api_key` today, but weaker than it looks
on paper. Acceptance test 10 exists specifically to fail loudly if the absence is ever
filled in.

## Execution gate

Creating this document is step 1 and is complete. **Implementation of §6 is blocked
pending separate, explicit human approval**, per `CLAUDE.md`: "Do not modify application
code before the implementation plan is explicitly approved by the human." Approval of a
plan document is not the same act as approval to begin implementing it.
