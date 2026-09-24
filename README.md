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

## Configure (optional)

```ruby
# config/initializers/kulla.rb
Kulla.configure do |c|
  c.endpoint = "https://kulla.example.com"    # ENV["KULLA_URL"], required
  c.token = "kla_..."                         # credentials kulla.token or ENV["KULLA_TOKEN"]; optional (see above)
  c.enroll = true                             # default: no token and Rails.env.production?
  c.app_name = "Shop"                         # ENV["KULLA_APP_NAME"]; default: the Rails app module
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
| `request` | `process_action.action_controller`: route template, status, durations, controller/action, IP, UA. Skips `/up`, `/assets`, Active Storage, `/cable`. |
| `error` | `Rails.error` (everything Rails reports, handled or not): class, message, 50 backtrace frames, context. |
| `job` | `perform.active_job`: class, queue, duration, result, attempts. |
| `mail` | `deliver.action_mailer`: mailer, message id, first recipient. |
| `security` | Rack::Attack blocklist/throttle/track notifications. |
| `deploy` | Once per server boot: revision, Ruby/Rails/gem versions, env var **names**, pending migrations. |
| `heartbeat` | Every 60 s: RSS, threads, DB pool, Solid Queue counts, Puma stats, disk, load. |
| `visit` | `kulla_beacon_tag` (see below). |
| anything | `Rails.event.notify` structured events (Rails 8.1). |

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

```erb
<%# app/views/layouts/application.html.erb %>
<%= kulla_beacon_tag %>
```

An inline script (with your CSP nonce) posts page, referrer, viewport, device and Web Vitals to your
app's own `/kulla/visit`, handled by `Kulla::VisitEndpoint` middleware. The token never reaches the
browser. No cookies: the visitor id is a daily-rotating hash of IP, user agent and `secret_key_base`.
Turbo navigations count as visits.

## Development

```sh
bundle install
bundle exec rake test   # core suite, then the Railtie suite in its own process
```
