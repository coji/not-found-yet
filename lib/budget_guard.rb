# frozen_string_literal: true

# 一日約 1 ドルの注意力。
# アプリ側は JST 暦日の soft budget を、Cloudflare AI Gateway 側は
# rolling 24h の spend limit を担当する。二重化して、どちらか片方が
# 崩れても暴走しないようにする。変更不能。
module BudgetGuard
  class Exhausted < StandardError
    attr_reader :reason

    def initialize(reason)
      @reason = reason
      super("attention exhausted: #{reason}")
    end
  end

  Reservation = Struct.new(:id, :kind, :usd, :day, keyword_init: true)

  @mutex = Mutex.new

  module_function

  def day_path(day = Clock.jst_date_string)
    File.join(Config.budget_dir, "#{day}.json")
  end

  def blank_day(day)
    {
      "day" => day,
      "spent_usd" => 0.0,
      "reserved_usd" => 0.0,
      "calls" => 0,
      "gaze_calls" => 0,
      "dream_calls" => 0,
      "reservations" => {},
      "exhausted_events" => 0,
      "last_call_at" => nil,
      "last_gaze_at" => nil,
      "last_dream_at" => nil,
      "gateway_429_at" => nil
    }
  end

  def read(day = Clock.jst_date_string)
    Store.read_json(day_path(day), nil) || blank_day(day)
  end

  def update(day = Clock.jst_date_string)
    @mutex.synchronize do
      Store.with_file_lock("budget.lock") do
        state = Store.read_json(day_path(day), nil) || blank_day(day)
        result = yield(state)
        Store.write_json!(day_path(day), state)
        result
      end
    end
  end

  # 呼出前に「最悪費用」を予約する。楽観的な見積りはしない。
  def worst_case_usd(kind)
    input, output = case kind
                    when :gaze then [Config.gaze_max_input_tokens, Config.gaze_max_output_tokens]
                    else [Config.dream_max_input_tokens, Config.dream_max_output_tokens]
                    end
    ((input / 1_000_000.0) * Config.price_input_per_mtok +
      (output / 1_000_000.0) * Config.price_output_per_mtok).round(6)
  end

  def actual_usd(usage)
    return nil if usage.nil?

    input = usage["input_tokens"].to_i
    cached = usage.dig("input_tokens_details", "cached_tokens").to_i
    output = usage["output_tokens"].to_i
    uncached = [input - cached, 0].max
    ((uncached / 1_000_000.0) * Config.price_input_per_mtok +
      (cached / 1_000_000.0) * Config.price_cached_input_per_mtok +
      (output / 1_000_000.0) * Config.price_output_per_mtok).round(6)
  end

  # 予約できたら Reservation、できなければ Exhausted。
  def reserve!(kind)
    raise Exhausted, "fossil" if Body.fossil?

    day = Clock.jst_date_string
    cost = worst_case_usd(kind)

    update(day) do |state|
      if state["gateway_429_at"]
        state["exhausted_events"] += 1
        raise Exhausted, "gateway_429"
      end
      if state["calls"].to_i >= Config.max_calls_per_day
        state["exhausted_events"] += 1
        raise Exhausted, "max_calls_per_day"
      end
      kind_cap = kind == :gaze ? Config.gaze_max_calls_per_day : Config.dream_max_calls_per_day
      if state["#{kind}_calls"].to_i >= kind_cap
        state["exhausted_events"] += 1
        raise Exhausted, "max_#{kind}_calls_per_day"
      end
      committed = state["spent_usd"].to_f + state["reserved_usd"].to_f
      if committed + cost > Config.daily_soft_limit_usd
        state["exhausted_events"] += 1
        raise Exhausted, "daily_soft_limit"
      end

      id = "#{kind}-#{Clock.now.to_i}-#{rand(1 << 24)}"
      state["reserved_usd"] = (state["reserved_usd"].to_f + cost).round(6)
      state["reservations"][id] = { "kind" => kind.to_s, "usd" => cost, "at" => Clock.iso }
      Reservation.new(id: id, kind: kind, usd: cost, day: day)
    end
  end

  # 成功時は usage から実費へ精算する。
  # usage 不明・timeout・transport error のときは予約を返却しない。
  # 「わからない出費」を無かったことにしない、という規則。
  def settle!(reservation, usage: nil, failed: false)
    return if reservation.nil?

    charged = failed ? reservation.usd : (actual_usd(usage) || reservation.usd)
    update(reservation.day) do |state|
      held = state["reservations"].delete(reservation.id)
      state["reserved_usd"] = [(state["reserved_usd"].to_f - (held ? held["usd"].to_f : reservation.usd)), 0.0].max.round(6)
      state["spent_usd"] = (state["spent_usd"].to_f + charged).round(6)
      state["calls"] = state["calls"].to_i + 1
      state["#{reservation.kind}_calls"] = state["#{reservation.kind}_calls"].to_i + 1
      state["last_call_at"] = Clock.iso
      state["last_#{reservation.kind}_at"] = Clock.iso
      charged
    end
    Psyche.observe_attention!(charged)
    charged
  end

  # 呼出そのものが起きなかったときだけ、予約を丸ごと返す。
  # 「呼んだが結果が分からない」場合には使わない。
  def release!(reservation)
    return if reservation.nil?

    update(reservation.day) do |state|
      held = state["reservations"].delete(reservation.id)
      state["reserved_usd"] = [(state["reserved_usd"].to_f - (held ? held["usd"].to_f : reservation.usd)), 0.0].max.round(6)
      0.0
    end
  end

  # 429 はその日の思考終了。安い model へは落とさない。
  def mark_gateway_429!
    update { |state| state["gateway_429_at"] = Clock.iso }
  end

  # 考えなかったことも記録に値する。
  def record_exhausted!(reason)
    update { |state| state["exhausted_events"] = state["exhausted_events"].to_i + 1 }
    ObservationLog.note("attention_exhausted", "reason" => reason.to_s, "remaining_usd" => remaining_usd)
    reason
  end

  def remaining_usd
    s = read
    [(Config.daily_soft_limit_usd - s["spent_usd"].to_f - s["reserved_usd"].to_f), 0.0].max.round(4)
  end

  def thinking_stopped? = !read["gateway_429_at"].nil?

  def last_at(kind)
    Clock.parse(read["last_#{kind}_at"])
  end

  def snapshot
    s = read
    {
      day: s["day"],
      spent_usd: s["spent_usd"].to_f.round(4),
      reserved_usd: s["reserved_usd"].to_f.round(4),
      remaining_usd: remaining_usd,
      soft_limit_usd: Config.daily_soft_limit_usd,
      calls: s["calls"].to_i,
      gaze_calls: s["gaze_calls"].to_i,
      dream_calls: s["dream_calls"].to_i,
      gaze_left: [Config.gaze_max_calls_per_day - s["gaze_calls"].to_i, 0].max,
      dream_left: [Config.dream_max_calls_per_day - s["dream_calls"].to_i, 0].max,
      exhausted_events: s["exhausted_events"].to_i,
      thinking_stopped: !s["gateway_429_at"].nil?
    }
  end
end
