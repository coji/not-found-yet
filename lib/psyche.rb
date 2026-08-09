# frozen_string_literal: true

# 人格を prompt の口調だけにしない。0.0〜1.0 の値として永続化し、
# 観測に対して決定論的に更新し、時間とともに baseline へ減衰させる。
# LLM はこの値を読むが、直接は書けない（adjust_desire_weights で小さく動かすだけ）。
module Psyche
  STATES = %w[curiosity fear loneliness vanity fatigue self_preservation].freeze

  BASELINE = {
    "curiosity" => 0.35,
    "fear" => 0.10,
    "loneliness" => 0.30,
    "vanity" => 0.15,
    "fatigue" => 0.05,
    "self_preservation" => 0.20
  }.freeze

  HALF_LIFE_SEC = 6 * 60 * 60      # baseline への回帰
  WINDOW_SEC = 10 * 60             # 飽和窓
  WINDOW_CAP = 0.08                # 1 窓で 1 state が動ける最大量
  ADJUST_CAP = 0.15                # mutation 1 回で動かせる最大量

  @mutex = Mutex.new
  @state = nil
  @window_started_at = nil
  @window_delta = Hash.new(0.0)
  @baseline_snapshot = nil

  module_function

  def load!
    @mutex.synchronize do
      stored = Store.state_read("psyche", nil)
      @state = BASELINE.dup
      if stored.is_a?(Hash)
        STATES.each { |k| @state[k] = clamp(stored[k].to_f) if stored.key?(k) }
        @last_decayed_at = Clock.parse(stored["_decayed_at"]) || Clock.now
      else
        @last_decayed_at = Clock.now
      end
      @baseline_snapshot = @state.dup
      @window_started_at = Clock.now
    end
    self
  end

  def state
    load! if @state.nil?
    @mutex.synchronize { @state.dup }
  end

  def [](key) = state[key].to_f

  # 直近の差分。Agent へは現在値とこれだけを渡す。
  def recent_delta
    load! if @state.nil?
    @mutex.synchronize do
      STATES.to_h { |k| [k, ((@state[k] - (@baseline_snapshot[k] || 0.0)) * 1000).round / 1000.0] }
    end
  end

  def dominant
    state.max_by { |_, v| v }&.first
  end

  # suspend を挟んでも wall clock で減衰させる。
  def decay!
    load! if @state.nil?
    @mutex.synchronize do
      elapsed = Clock.now - (@last_decayed_at || Clock.now)
      return if elapsed < 60

      ratio = 0.5**(elapsed / HALF_LIFE_SEC.to_f)
      STATES.each do |k|
        base = BASELINE[k]
        @state[k] = clamp(base + (@state[k] - base) * ratio)
      end
      @last_decayed_at = Clock.now
    end
    persist!
  end

  # 観測 1 件の影響は小さく、窓ごとに飽和させる。
  # scanner が 84 回来ても、fear は窓の上限までしか動かない。
  def observe!(event)
    load! if @state.nil?
    deltas = deltas_for(event)
    return if deltas.empty?

    apply_with_saturation(deltas)
  end

  def deltas_for(event)
    d = Hash.new(0.0)
    case event["kind"]
    when "exception"
      d["fear"] += 0.05
      d["self_preservation"] += 0.04
    when "absence"
      case event["family"]
      when "imagined_place", "question"
        d["curiosity"] += 0.012
        d["loneliness"] -= 0.006
      when "foreign_body"
        d["fear"] += 0.006
        d["self_preservation"] += 0.004
        d["curiosity"] -= 0.002
      when "secret_probe"
        d["fear"] += 0.010
        d["self_preservation"] += 0.012
      when "extension_probe", "opaque"
        d["fatigue"] += 0.004
        d["self_preservation"] += 0.002
      end
      d["fatigue"] += 0.002
      case event["behavior"]
      when "single_returning"
        d["loneliness"] -= 0.020
        d["curiosity"] += 0.015
      when "broad_scanner"
        d["fear"] += 0.004
        d["fatigue"] += 0.004
      when "periodic_reader"
        d["loneliness"] -= 0.004
      end
    when "presence"
      d["loneliness"] -= 0.008
      d["vanity"] += 0.002
    end
    d
  end

  # 誰も来ない時間そのものが観測になる。
  def observe_silence!(seconds)
    return if seconds < 30 * 60

    hours = seconds / 3600.0
    apply_with_saturation({
      "loneliness" => [0.02 * hours, 0.12].min,
      "fatigue" => -[0.01 * hours, 0.10].min
    })
  end

  def observe_mutation!(result)
    case result
    when :applied
      apply_with_saturation({ "vanity" => 0.05, "curiosity" => 0.02, "fear" => -0.02 })
    when :rolled_back, :rejected
      apply_with_saturation({ "fear" => 0.06, "self_preservation" => 0.05, "vanity" => -0.04 })
    end
  end

  def observe_attention!(usd)
    apply_with_saturation({ "fatigue" => [usd * 0.5, 0.05].min })
  end

  # MutationIntent の adjust_desire_weights から呼ばれる唯一の入口。
  def adjust!(deltas)
    load! if @state.nil?
    applied = {}
    @mutex.synchronize do
      deltas.each do |k, v|
        next unless STATES.include?(k)

        delta = clamp_delta(v.to_f, ADJUST_CAP)
        before = @state[k]
        @state[k] = clamp(before + delta)
        applied[k] = ((@state[k] - before) * 1000).round / 1000.0
      end
    end
    persist!
    applied
  end

  def apply_with_saturation(deltas)
    load! if @state.nil?
    @mutex.synchronize do
      if @window_started_at.nil? || (Clock.now - @window_started_at) > WINDOW_SEC
        @window_started_at = Clock.now
        @window_delta = Hash.new(0.0)
      end
      deltas.each do |k, v|
        next unless STATES.include?(k)

        room = WINDOW_CAP - @window_delta[k].abs
        next if room <= 0

        delta = clamp_delta(v.to_f, room)
        @state[k] = clamp(@state[k] + delta)
        @window_delta[k] += delta.abs
      end
    end
  end

  def persist!
    snapshot = @mutex.synchronize { @state.dup }
    Store.state_update("psyche") do |_|
      snapshot.merge("_decayed_at" => Clock.iso)
    end
  rescue StandardError
    nil # 記憶できないこと自体は致命ではない
  end

  def clamp(v) = [[v, 0.0].max, 1.0].min
  def clamp_delta(v, cap) = [[v, -cap].max, cap].min

  def summary
    state.map { |k, v| "#{k} #{format('%.2f', v)}" }.join(" / ")
  end
end
