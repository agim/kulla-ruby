# kulla (Ruby SDK)

Sends telemetry from a Rails 8.x app to Kulla and keeps a copy of Kulla's signals. No runtime
dependencies beyond the Ruby stdlib; the Rails integration is a Railtie that loads only when Rails is
present. It never raises into your app: if Kulla is down you lose data, not uptime.

## Install

```ruby
# Gemfile
gem "kulla", github: "agim/kulla-ruby"

# config/initializers/kulla.rb
Kulla.configure { |c| c.endpoint = "https://kulla.example.com" }   # or ENV["KULLA_URL"]
```

That is all. Deploy, then approve the app in Kulla (see below).

### Joining without a token

A Rails app in production with no token asks Kulla to join on its own, and gets a token only after the
Kulla owner approves it:

1. The app derives an install key from its `secret_key_base` (`kli_…`, stable across deploys, never
   stored or logged) and sends it with the app name, host and environment to `POST /api/v1/enroll`, the
   only endpoint that takes no token. The install key only proves which install is asking; it is never
   accepted as a token.
2. The app shows up in Kulla under **Apps, Waiting for approval**. Until the owner approves it, Kulla
   answers "pending" and no token exists. The app checks back every minute and sends nothing else;
   events wait in the buffer (the oldest are dropped past `buffer_size`).
3. On approval Kulla issues a token and returns it only to requests carrying the same install key. The
   SDK keeps it in memory and uses it for every other call; after a restart it picks it up again.
4. If the token is revoked or the app removed in Kulla, the app asks to join again. Rejected apps check
   back hourly.

If the app's `secret_key_base` changes, it asks to join again. To skip joining, give it a token instead
(`kulla.token` in credentials or `KULLA_TOKEN`), or set `c.enroll = false`.

### Long-running rake tasks and custom daemons

Web servers and job processes (Solid Queue, Sidekiq, GoodJob) report on their own. Rake tasks, the console
and one-off commands (`rails runner`, scripts) don't. For a process that runs for a long time but isn't
a server, for example a monitor started as a rake task under systemd, start the SDK yourself once the
app has loaded:

```ruby
task call_monitor: :environment do
  Kulla.start!
  CallMonitor.run   # requests, errors, jobs and heartbeats from this process now reach Kulla
end
```

`Kulla.start!` does nothing (and returns false) when the SDK is off. It uses the app's token, or joins with
the same install key as the app's other processes, so an app you already approved needs no new approval.

## Configure (optional)

```ruby
# config/initializers/kulla.rb
Kulla.configure do |c|
  c.endpoint = "https://kulla.example.com"    # ENV["KULLA_URL"], required
  c.token = "kla_..."                         # credentials kulla.token or ENV["KULLA_TOKEN"]; optional (see above)
  c.enroll = true                             # default: no token and Rails.env.production?
  c.site = "shop.example.com"                 # ENV["KULLA_SITE"]; default: the host Rails builds URLs with
  c.app_name = "shop.example.com"             # ENV["KULLA_APP_NAME"]; default: the site, else the Rails app module
  c.release = ENV["GIT_SHA"]                  # KULLA_RELEASE, REVISION, GIT_SHA, REVISION file, git
  c.enabled = Rails.env.production?           # default: endpoint and token (or enrollment) present, env != test
  c.flush_interval = 5                        # seconds
  c.batch_size = 500
  c.buffer_size = 10_000                      # oldest events are dropped (and counted) beyond this
  c.timeout = 2                               # seconds, per HTTP request
  c.filter_parameters += [ :iban ]            # defaults to Rails.application.config.filter_parameters
  c.capture = { heartbeat: false }            # requests errors jobs mail security events deploy heartbeat visits
  c.suppress_bad_emails = true                # opt-in, see "Signals" (default false)
  c.block_signal_ips = true                   # opt-in, see "Signals" (default false)
end
```

## What's captured

| Stream | From |
|---|---|
| `request` | `process_action.action_controller`: route template, status, durations, controller/action, IP, UA, bot flag, and per-request counts: `queries`, `cache_hits`, `cache_misses`, `http_calls`. Skips `/up`, `/assets`, Active Storage, `/cable`. |
| `error` | `Rails.error` (everything Rails reports, handled or not): class, message, 50 backtrace frames, context, filtered `params`, `user_id` (never an email), and `breadcrumbs`: the last 20 queries, HTTP calls, AI calls and warnings before it. |
| `job` | `perform.active_job`: class, queue, duration, result, attempts, `queue_wait_ms` (enqueued → started), query counts. |
| `query` | `kind: slow`: statements over `slow_query_ms` (default 500). `kind: n_plus_one`: the same SELECT at least `n_plus_one` times (default 10) in one request or job. SQL is normalized (every literal becomes `?`), so no values leave the app. |
| `http` | Outgoing HTTP through Net::HTTP (and Faraday's default adapter): host, method, path (no query string), status, duration, error class. |
| `llm` | RubyLLM completions: provider, model, input/output tokens, duration, `cost_usd` when the model's price is known. Prompts and replies are never sent. |
| `activity` | Inserts per table, sent every minute: signups, orders, messages… with no code. Internal tables (Solid Queue/Cache/Cable, sessions, schema) are skipped. |
| `log` | Warn, error and fatal log lines (at most `logs_per_minute`, default 60). |
| `mail` | `deliver.action_mailer`: mailer, message id, first recipient. |
| `security` | Rack::Attack blocklist/throttle/track notifications, Rails 8 `rate_limit` hits, and `Kulla.security` (below). |
| `csp` | Content-Security-Policy violation reports sent to `/kulla/csp` (below). |
| `deploy` | Once per server boot: revision, Ruby/Rails/gem versions, env var **names**, pending migrations, Solid Queue recurring tasks (so Kulla notices a scheduled job that didn't run). |
| `heartbeat` | Every 60 s: which process (`pid`, `role`: web/job/task, process name, boot time, SDK version), RSS, threads, DB pool, Solid Queue counts, Puma stats, disk, load. |
| `visit` | `kulla_beacon_tag` (see below). The same tag reports JavaScript errors and unhandled promise rejections as `error` events with `source: browser` (at most 5 per page). Visits carry `ip_prefix`, a /24 or /48 of the visitor's IP that Kulla turns into a country at ingest and never stores. |
| anything | `Rails.event.notify` structured events (Rails 8.1), and any ActiveSupport notification Kulla asks for by name. |

Kulla can switch each of these on or off, and change the thresholds, per app from its dashboard
(the manifest's `config`), without a new gem release or a deploy. A setting in your initializer
always wins over Kulla's.

### What never leaves the app

- **Keys:** credentials (authorization, cookie, password, secret, token…) are dropped, and your
  `filter_parameters` plus personal fields Rails misses (phone, address, signature, first/last/full name,
  date of birth, IBAN, card, passport…) are `[FILTERED]`. In error params any `*name` field is filtered too.
- **Content:** free text (log lines, error messages, breadcrumbs, params, extra events) has emails,
  token-like strings, `data:` URLs, query strings and long digit runs (cards, phone numbers) replaced.
  Browser paths (visits, JS errors, CSP) have token-like segments replaced (`/portal/:token`).
- **Remote extra events** (`notifications` from Kulla) can't name events that carry raw URLs, SQL, mail or
  params (`process_action`, `sql.active_record`, `*.action_mailer`, …), and drop `path`, `url`, `sql`,
  `subject`, recipients, `params`, `key` and similar fields. To refuse all of them: `c.notifications = []`.
- **Still yours to check:** log lines that print whole records or custom identifiers. Content scrubbing
  catches the common shapes, not everything. Add app-specific keys to `filter_parameters`.

### Invalid emails at signup

```ruby
# a syntax check plus "can this domain receive mail" (DNS MX, else A/AAAA), cached per domain for an hour
if Kulla.email_valid?(params[:email])
```

An address whose domain can't receive mail is reported to Kulla as an `email.invalid` signal, active at
once for every app, and an address Kulla already knows as invalid is refused without a lookup. A DNS
failure counts as valid, so resolver trouble never blocks a signup.

### Signal webhook (optional; polling stays)

In Kulla, App › Settings › Signal webhook takes `https://<your app>/kulla/signals`. That is the whole
setup: the gem mounts `/kulla/signals` and verifies Kulla's `X-Kulla-Signature` (HMAC-SHA256, 5-minute
tolerance) with a key derived from the app's token, which every process already holds; Kulla derives
the same key from the token's digest. Nothing is copied, and the key follows the token when it rotates.
On a valid delivery the gem syncs signals at once instead of at the next minute's poll.

### Security events and CSP reports

```ruby
# a failed login, a blocked signup, anything your app decides is a security event
Kulla.security("login_failed", ip: request.remote_ip, path: request.path)

# config/initializers/content_security_policy.rb
policy.report_uri "/kulla/csp"
```

Every event carries `env`, `host`, `release` and `ts`. Attributes are scrubbed with your
`filter_parameters`; keys that look like credentials (authorization, cookie, password, secret,
token) are removed.

## Custom events

```ruby
Rails.event.notify("user.signup", plan: "pro")         # Rails 8.1: becomes stream "user.signup"
Kulla.track("invoice.paid", { amount: 120 }, level: :info, message: "Invoice 42 paid")
Kulla.error(exception, { order_id: order.id })          # a handled error
Kulla.flush                                             # send now (e.g. at the end of a script)
```

Stream names are lowercased and anything outside `a-z0-9_.` becomes `_`. Rails' own structured
events (`action_controller.*`, `active_job.*`, ...) are ignored because Kulla already has them.

## Signals

Signals are facts one app learned that every app can use: a bounced or complaining email address,
an IP several apps banned, a disposable domain (Kulla's `docs/api.md`, "Signals").

The worker thread polls `GET /api/v1/signals` every 60 s (following `more`) and keeps an in-memory
copy of the active ones, per kind. It starts empty at boot and syncs from scratch, and only polls
when the manifest lists the `signals` endpoint (the token has `signals:read`).

```ruby
Kulla.signal?("email.bounced", user.email)       # true while the signal is active
Kulla.signal?("ip.blocked", request.remote_ip)
Kulla.report_signal("ip.blocked", request.remote_ip, reason: "wp-login scan", details: { path: "/wp-login.php" })
```

Email addresses never leave Kulla: email kinds are matched by the SHA-256 of the trimmed,
lowercased address against the signal's `subject_hash`. Other kinds compare the subject (IPs
normalized with `IPAddr`, domains lowercased). `expires_at` is honoured locally.
`Kulla.signal?` answers `false` until the first sync and whenever the SDK is disabled.

`Kulla.report_signal` queues a `POST /api/v1/signals` for the worker and returns at once (it needs
`signals:write`). Network errors, 429 and 5xx are retried on the next flush, up to three attempts;
other 4xx drop the report. Neither method raises.

### Opt-in integrations (Rails)

Both are off by default. Set them in `config/initializers/kulla.rb`; the Railtie reads them after
your initializers.

| Option | What it does |
|---|---|
| `c.suppress_bad_emails = true` | Registers an ActionMailer interceptor that removes To/Cc/Bcc recipients with an active `email.bounced` or `email.complaint` signal. If nobody is left, the delivery is cancelled (`message.perform_deliveries = false`). Both are logged with masked addresses. |
| `c.block_signal_ips = true` | Inserts `Kulla::SignalBlocker` right after `ActionDispatch::RemoteIp`; it answers `403` to IPs with an active `ip.blocked` signal. |

Apps that use `rack_attack_abuseipdb` with its `:kulla` provider don't need `block_signal_ips`: that
gem already pulls the `ip.blocked` signals into its blocklist (shared across processes through the
cache) and reports the IPs it blocks.

## Page visits

Nothing to add: `Kulla::BeaconInjector` middleware puts the beacon into every full HTML page (200,
`text/html`, GET, not a Turbo Frame/Stream or XHR response, not a streamed body), with your CSP nonce
when the page has one, once per page. Turn it off with `c.capture = { beacon: false }` (Kulla can also
turn it off per app), and use `<%= kulla_beacon_tag %>` in a layout if you prefer to place it yourself
(the two never double up: the script checks `window.__kulla`). Two things to know before approving a
site: the beacon is **on by default** from 0.5.1, so a site that must not measure visitors sets
`beacon: false` before it is approved; and a CSP with `script-src` and no nonce blocks the injected
script in the browser, so visits stay at zero while everything looks configured.

The script posts page, referrer, viewport, device, Web Vitals and JavaScript errors to your app's own
`/kulla/visit`, handled by `Kulla::VisitEndpoint`. The token never reaches the browser. No cookies: the
visitor id is a daily-rotating hash of IP, user agent and `secret_key_base`. Turbo navigations count as
visits.

## Development

```sh
bundle install
bundle exec rake test   # core suite, then the Railtie suite in its own process
```
