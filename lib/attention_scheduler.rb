# frozen_string_literal: true

# reflex / gaze / dream を選び、BudgetGuard を通す。
# HTTP handler から Provider を直接呼ばない。唯一の入口がここ。
# 変更不能。
module AttentionScheduler
  @mutex = Mutex.new
  @dreaming = false
  @last_gaze_at = nil
  @last_dream_at = nil
  @last_tick_at = nil

  module_function

  # ---- Gaze --------------------------------------------------------------

  # 珍しい遭遇だけ、404 の第二声を短く生成する。mutation 権限はない。
  def gaze?(event)
    return false unless Config.gaze_enabled?
    return false unless Body.alive?
    return false unless event["kind"] == "absence"
    return false if BudgetGuard.thinking_stopped?
    return false if cooldown_active?
    return false unless EvolutionAgent.provider.available?

    score(event) >= Config.gaze_min_score
  end

  def score(event)
    s = 0.0
    s += 0.40 if Observer.first_seen?(event["path_key"])
    s += 0.20 if short_human_readable?(event["safe_display_path"])
    s += 0.20 if event["behavior"] == "single_returning"
    s += 0.20 if Observer.path_visitor_count(event["path_key"]) >= 2
    s -= 0.80 if event["behavior"] == "broad_scanner"
    s -= 0.50 if %w[extension_probe opaque secret_probe asset].include?(event["family"])
    s * fatigue_modifier
  end

  def short_human_readable?(path)
    return false if path.nil?

    path.length <= 24 && path.match?(%r{\A/[a-z]+([-_][a-z]+)*\z})
  end

  # 疲れているほど、注意力を使わなくなる。
  def fatigue_modifier
    [1.0 - Psyche["fatigue"] * 0.8, 0.2].max
  end

  def cooldown_active?
    last = @last_gaze_at || BudgetGuard.last_at(:gaze)
    return false if last.nil?

    (Clock.now - last) < Config.gaze_cooldown_sec
  end

  # 同一 bucket は一日 1 回まで。
  @gazed_buckets = {}

  def gaze_for(event)
    bucket = event["visitor_bucket"]
    today = Clock.jst_date_string
    @mutex.synchronize do
      @gazed_buckets = {} if @gazed_buckets[:day] != today
      @gazed_buckets[:day] = today
      return nil if @gazed_buckets[bucket]

      @gazed_buckets[bucket] = true
    end

    reservation = begin
      BudgetGuard.reserve!(:gaze)
    rescue BudgetGuard::Exhausted => e
      BudgetGuard.record_exhausted!(e.reason)
      return nil
    end

    # 同時 LLM 呼出は常に 1。取れなければ諦める（待たない）。
    Store.try_file_lock("llm.lock") do
      begin
        text, result = EvolutionAgent.gaze(event: event)
        charged = BudgetGuard.settle!(reservation, usage: result.usage)
        @mutex.synchronize { @last_gaze_at = Clock.now }
        ObservationLog.note("gaze", "path" => event["safe_display_path"], "family" => event["family"],
                                    "score" => score(event).round(3), "usd" => charged,
                                    "spoke" => !text.nil?)
        text
      rescue Providers::CloudflareAIGateway::Throttled
        BudgetGuard.mark_gateway_429!
        BudgetGuard.settle!(reservation, failed: true)
        ObservationLog.note("gateway_429", "purpose" => "gaze")
        nil
      rescue Providers::CloudflareAIGateway::Unavailable
        # 呼んでいないので、注意力は減らさない。
        BudgetGuard.release!(reservation)
        nil
      rescue StandardError => e
        BudgetGuard.settle!(reservation, failed: true)
        Observer.record_exception(e, "AttentionScheduler#gaze")
        nil
      end
    end
  end

  # ---- Dream -------------------------------------------------------------

  # Fly の suspend 中は timer が進まない。だから次の request で
  # 経過時間を計算し直して tick する。
  def tick!
    @mutex.synchronize do
      return if @last_tick_at && (Clock.now - @last_tick_at) < 20

      @last_tick_at = Clock.now
    end

    Psyche.decay!
    sweep_traces!
    silence = Observer.silence_seconds
    Psyche.observe_silence!(silence) if silence.finite?
    Fitness.evaluate! if Fitness.due?
    maybe_dream!
  rescue StandardError => e
    Observer.record_exception(e, "AttentionScheduler#tick")
  end

  # 読まれたときだけ風化させると、誰も見に来ない痕が永遠に鮮明なままになる。
  # 忘却は、見られていなくても進まなければ意味がない。
  @last_sweep_at = nil
  def sweep_traces!
    last = @mutex.synchronize { @last_sweep_at }
    return if last && (Clock.now - last) < 3600

    @mutex.synchronize { @last_sweep_at = Clock.now }
    faded = TraceRegistry.sweep!
    ObservationLog.note("traces_faded", "count" => faded) if faded.positive?
  end

  def dream?
    return false unless Config.dream_enabled?
    return false unless Body.alive?
    return false if BudgetGuard.thinking_stopped?
    return false if @dreaming
    return false unless EvolutionAgent.provider.available?
    return false if Observer.new_events_since_dream < Config.dream_min_events

    last = @last_dream_at || BudgetGuard.last_at(:dream)
    last.nil? || (Clock.now - last) >= Config.dream_interval_sec
  end

  # 夢は request の裏で見る。反射のレイテンシに乗せない。
  def maybe_dream!
    return unless dream?

    @mutex.synchronize do
      return if @dreaming

      @dreaming = true
    end

    Thread.new do
      Thread.current.name = "dream"
      begin
        dream_now!
      rescue StandardError => e
        Observer.record_exception(e, "AttentionScheduler#dream")
      ensure
        @mutex.synchronize { @dreaming = false }
      end
    end
  end

  def dream_now!
    reservation = begin
      BudgetGuard.reserve!(:dream)
    rescue BudgetGuard::Exhausted => e
      BudgetGuard.record_exhausted!(e.reason)
      return nil
    end

    Store.try_file_lock("llm.lock") do
      decision = nil
      spent = 0.0
      begin
        decision, result = EvolutionAgent.dream(reservation: reservation)
        spent = BudgetGuard.settle!(reservation, usage: result.usage).to_f
      rescue Providers::CloudflareAIGateway::Throttled
        BudgetGuard.mark_gateway_429!
        BudgetGuard.settle!(reservation, failed: true)
        ObservationLog.note("gateway_429", "purpose" => "dream")
        return nil
      rescue Providers::CloudflareAIGateway::Unavailable
        BudgetGuard.release!(reservation)
        return nil
      rescue StandardError => e
        BudgetGuard.settle!(reservation, failed: true)
        ObservationLog.note("dream_failed", "error" => e.class.name)
        Observer.record_exception(e, "AttentionScheduler#dream_call")
        return nil
      end

      Observer.reset_dream_counter!
      @mutex.synchronize { @last_dream_at = Clock.now }
      apply_decision(decision, spent)
    end
  end

  # 夢から覚めて、身体を触る唯一の経路。
  def apply_decision(decision, spent_usd)
    result = TrustedMutator.apply(decision["intent"], source: :dream)
    cost = {
      "complexity" => result.intent.is_a?(Hash) ? MutationIntent.complexity_cost(result.intent) : 0.0,
      "attention_usd" => spent_usd.round(6)
    }
    entry = EvolutionJournal.append(decision: decision, result: result, cost: cost, source: :dream)
    ObservationLog.note("dream", "seq" => entry["seq"], "status" => result.status,
                                 "intent" => entry["intent_description"], "reason" => result.reason,
                                 "desire" => decision["dominant_desire"], "cost" => cost)
    result
  end

  def snapshot
    {
      gaze_enabled: Config.gaze_enabled?,
      dream_enabled: Config.dream_enabled?,
      dreaming: @dreaming,
      last_gaze_at: @last_gaze_at,
      last_dream_at: @last_dream_at,
      new_events_since_dream: Observer.new_events_since_dream,
      fatigue_modifier: fatigue_modifier.round(3)
    }
  end

  def reset!
    @mutex.synchronize do
      @dreaming = false
      @last_gaze_at = nil
      @last_dream_at = nil
      @last_tick_at = nil
      @last_sweep_at = nil
      @gazed_buckets = {}
    end
  end
end
