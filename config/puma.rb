# frozen_string_literal: true

# ひとつの身体。ひとつのプロセス。
# worker を増やすと「同じ PID のまま変わる」が成立しなくなるので、single mode 固定。
port ENV.fetch("PORT", "8080")
environment ENV.fetch("RACK_ENV", "production")

threads Integer(ENV.fetch("PUMA_MIN_THREADS", "1")), Integer(ENV.fetch("PUMA_MAX_THREADS", "8"))
workers 0

preload_app! false
