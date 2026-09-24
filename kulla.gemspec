require_relative "lib/kulla/version"

Gem::Specification.new do |spec|
  spec.name = "kulla"
  spec.version = Kulla::VERSION
  spec.authors = [ "Kulla contributors" ]
  spec.summary = "Ruby/Rails SDK for Kulla, a self-hosted telemetry hub"
  spec.description = "Sends requests, errors, jobs, mail, security, deploy, heartbeat, visit and custom events " \
                     "from Rails apps to Kulla, and syncs Kulla's shared signals (bounced emails, banned IPs). " \
                     "Buffered, batched, gzip NDJSON; never raises into the host app."
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2"

  spec.metadata["rubygems_mfa_required"] = "true"

  spec.files = Dir["lib/**/*.rb", "README.md", "LICENSE", "kulla.gemspec"]
  spec.require_paths = [ "lib" ]
end
