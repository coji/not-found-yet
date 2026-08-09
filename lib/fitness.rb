# frozen_string_literal: true

# smoke test を通ったことは「生きている」だけで、「適応した」ではない。
# 適用後の次の 30 meaningful encounters か、覚醒時間 60 分で簡易評価する。
# PoC 初版では記録のみ。自動 rollback は smoke failure だけ。
module Fitness
  ENCOUNTER_TARGET = 30
  AWAKE_WINDOW_SEC = 60 * 60
  LATENCY_SAMPLES = 200

  @mutex = Mutex.new
  @window = nil
  @latencies = []

  module_function

  def auto_rollback? = Config.bool("FITNESS_AUTO_ROLLBACK", false)
  def threshold = Config.float("FITNESS_ROLLBACK_THRESHOLD", 0.35)

  def sample_latency(ms)
    @mutex.synchronize do
      @latencies << ms
      @latencies.shift while @latencies.length > LATENCY_SAMPLES
    end
  end

  def average_latency
    @mutex.synchronize do
      return nil if @latencies.empty?

      (@latencies.sum / @latencies.length.to_f).round(2)
    end
  end

  def begin_window!(entry)
    latency_before = average_latency
    @mutex.synchronize do
      @window = {
        seq: entry["seq"],
        generation: entry["generation_after"],
        intent: entry["intent"],
        desire: entry["dominant_desire"],
        started_at: Clock.now,
        exceptions_before: Observer.exception_count,
        latency_before: latency_before,
        route_path: entry.dig("intent", "path")
      }
    end
    Observer.reset_fitness_counter!
  end

  def open? = !@mutex.synchronize { @window }.nil?

  def due?
    w = @mutex.synchronize { @window }
    return false if w.nil?

    Observer.meaningful_since_mutation >= ENCOUNTER_TARGET ||
      (Clock.now - w[:started_at]) >= AWAKE_WINDOW_SEC
  end

  # 遅延評価。閾値未満なら rollback 候補だが、Journal は消さない。
  def evaluate!
    w = @mutex.synchronize { @window }
    return nil if w.nil?

    encounters = [Observer.meaningful_since_mutation, 1].max
    exceptions = [Observer.exception_count - w[:exceptions_before], 0].max
    no_exception_rate = [1.0 - exceptions / encounters.to_f, 0.0].max

    returning_use = if w[:route_path]
                      key = RequestAirlock.path_key(w[:route_path])
                      [Observer.path_visitor_count(key) / 2.0, 1.0].min
                    else
                      0.5
                    end

    desire_alignment = Psyche.dominant == w[:desire] ? 1.0 : 0.5
    diversity = [Observer.snapshot[:families].keys.length / 5.0, 1.0].min
    complexity = w[:intent].is_a?(Hash) ? MutationIntent.complexity_cost(w[:intent]) : 0.0

    latency_now = average_latency
    latency_regression =
      if w[:latency_before] && latency_now && w[:latency_before] > 0
        [[(latency_now - w[:latency_before]) / w[:latency_before], 0.0].max, 1.0].min
      else
        0.0
      end

    score = (0.30 * no_exception_rate +
             0.20 * returning_use +
             0.20 * desire_alignment +
             0.15 * diversity -
             0.15 * complexity -
             0.20 * latency_regression).round(3)

    detail = {
      "no_exception_rate" => no_exception_rate.round(3),
      "returning_use_of_new_feature" => returning_use.round(3),
      "desire_alignment" => desire_alignment,
      "response_diversity" => diversity.round(3),
      "complexity_cost" => complexity,
      "latency_regression" => latency_regression.round(3),
      "encounters" => encounters,
      "window" => Observer.meaningful_since_mutation >= ENCOUNTER_TARGET ? "encounters" : "awake_time"
    }

    EvolutionJournal.record_fitness!(w[:seq], score, detail)

    if auto_rollback? && score < threshold
      TrustedMutator.rollback!(w[:generation])
      EvolutionJournal.record_fitness!(w[:seq], score, detail.merge("rolled_back_by_fitness" => true))
    end

    @mutex.synchronize { @window = nil }
    { "score" => score, "detail" => detail }
  end

  def reset!
    @mutex.synchronize do
      @window = nil
      @latencies = []
    end
  end
end
