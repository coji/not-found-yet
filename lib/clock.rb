# frozen_string_literal: true

# JST 暦日と単調時計。Fly の suspend 中は timer が進まないので、
# 経過時間は必ず「今」を基準に計算し直す。
module Clock
  JST = "+09:00"

  module_function

  def now = Time.now.utc

  def jst_date_string(t = now)
    t.getlocal(JST).strftime("%Y-%m-%d")
  end

  def iso(t = now)
    t.utc.strftime("%Y-%m-%dT%H:%M:%SZ")
  end

  def parse(str)
    return nil if str.nil? || str.to_s.empty?

    Time.parse(str).utc
  rescue ArgumentError
    nil
  end

  # 経過秒。suspend を挟んでも wall clock で測る。
  def since(str_or_time)
    t = str_or_time.is_a?(Time) ? str_or_time : parse(str_or_time)
    return Float::INFINITY if t.nil?

    now - t
  end
end

require "time"
