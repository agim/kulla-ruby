require_relative "lib/kulla/version"

Gem::Specification.new do |spec|
  spec.name = "kulla"
  spec.version = Kulla::VERSION
  spec.authors = [ "Kulla contributors" ]
  spec.summary = "Durable Ruby/Rails log collector for Kulla"
  spec.description = "Collects requests, errors, jobs, mail, security, deploy, logs and custom events " \
                     "from Rails apps to Kulla, and syncs Kulla's shared signals (bounced emails, banned IPs). " \
                     "Durable disk buffering, fifteen-minute batches, gzip NDJSON; never raises into the host app."
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2"

  spec.metadata["rubygems_mfa_required"] = "true"

  spec.files = Dir["lib/**/*.rb", "docs/**/*.md", "README.md", "LICENSE", "kulla.gemspec"]
  spec.require_paths = [ "lib" ]
end
