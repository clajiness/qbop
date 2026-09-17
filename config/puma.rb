# SuckerPunch and UI notifications share one process. Each SSE body occupies a
# request thread; the eight-subscriber cap leaves eight threads for ordinary HTTP.
workers 0
threads 2, 16

# Long-lived streams must not prevent a container from stopping or restarting.
force_shutdown_after 5
# Puma may invoke lifecycle hooks inside a signal trap, where mutexes are unsafe.
before_restart { Thread.new { Framework::Events.shutdown } }
after_stopped { Thread.new { Framework::Events.shutdown } }
