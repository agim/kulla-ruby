module Kulla
  # Restarts the worker thread in forked children (Puma cluster workers, etc.) as soon as they
  # are forked, so heartbeats start even before a worker handles its first request.
  # Client#ensure_worker also checks the pid, which covers forks this hook doesn't see.
  module ForkHook
    def _fork
      pid = super
      Kulla.after_fork if pid.zero?
      pid
    end
  end
end

Process.singleton_class.prepend(Kulla::ForkHook) if Process.respond_to?(:_fork)
