# Durable log collection (0.7)

Deploy Kulla's PostgreSQL collector before upgrading this SDK. Current endpoint,
app token and installation key settings remain valid. Update the consumer's
`Gemfile.lock` with `bundle update kulla --conservative`; a Git-pinned Gemfile must
also point at the new release/commit before Bundler can update it.

By default, captured request, job, error, mail, security, deploy and application
log records are written to a shared disk journal and uploaded every 15 minutes.
Uploads land on fixed slots aligned to the hour, shifted by a whole-minute offset
from the app's identity (endpoint, env and app name), so apps sharing a Kulla don't
all send at once: one app sends at :00, :15, :30 and :45, another at :01, :16, :31
and :46, and so on across minutes 0 to 14. A spool past 80% of `buffer_size` or
`spool_max_bytes` uploads before its slot (at most once a minute), so a busy app
sends early instead of dropping its oldest records.
INFO and higher application logs are captured without the old per-minute cap.
Heartbeat, browser visits and the query/cache/HTTP/LLM APM collectors default off.
Explicit local capture settings are retained. The collector's manifest disables
its retired APM captures; it does not replace credentials.

Set `KULLA_SPOOL_DIR` to a persistent local directory writable by the service user
if the application's filesystem is ephemeral. The default is
`~/.local/state/kulla/<endpoint/environment/application hash>`, outside the release
checkout. Mount that directory into containers and retain it across deployments.
Puma/Sidekiq processes using the same configuration share one journal. Files are
0600 and the directory 0700.

The spool is bounded (0.7.1). It keeps at most `buffer_size` pending records (10,000) and
`spool_max_bytes` of them (64 MB). Past either limit it drops the oldest tenth and writes one `log`
record saying how many were dropped, so a long outage costs the oldest logs, never the host's disk.
The journal file is compacted once its delivered or dropped part is larger than 1 MB and than the
pending part, so it stays under about twice the pending size. `rejected.ndjson` rotates to
`rejected.1.ndjson` at 1 MB.

Recording a log never waits on the disk: it is written and flushed to the OS on the calling thread, so
a process that crashes loses nothing, and the SDK's worker thread fsyncs the journal every 2 seconds and
at shutdown. A power loss can cost the last two seconds.

Every record has a stable UUID. Server acknowledgements advance the journal's
cursor only after validated acceptance. Ambiguous network failures replay the
same identities and Kulla deduplicates them per application. A malformed reply
keeps the batch pending. Permanently rejected records are fsynced to local
`rejected.ndjson` before the cursor advances. Do not delete spool contents to
recover a network error. Interrupted partial writes are retained separately for
inspection; complete earlier records remain available for delivery.

Shutdown leaves records durably queued instead of delaying process exit for an
upload. Restart resumes the shared journal and honors its existing interval;
overdue records are eligible immediately. Network failure retries are bounded
and pending batches remain on disk. `Kulla.flush` explicitly drains now, useful
for an operator verification after deploying the server and gem.

For unusual setups, configure `collection_interval` (seconds),
`collection_offset` (seconds past each slot, to pin an app's minute) and
`spool_directory` through `Kulla.configure`. `durable_buffer=false` retains the
legacy short-interval memory-buffer transport for compatibility; it does not
provide restart safety and is not the production default.
