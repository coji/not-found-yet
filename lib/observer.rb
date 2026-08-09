# frozen_string_literal: true

require "set"

# 事実だけを記録する層。解釈はしない。
# ここで raw path を持たず、既に Airlock を通った ObservationEvent だけを見る。
# 変更不能。
module Observer
  MAX_EVENTS = 400
  MAX_PATHS = 4_000
  MAX_BUCKETS = 2_000
  MAX_EXCEPTIONS = 50
  RETURNING_GAP_SEC = 10 * 60
  SCANNER_PATHS = 8
  SCANNER_WINDOW_SEC = 10 * 60

  @mutex = Mutex.new
  @events = []
  @paths = {}
  @buckets = {}
  @families = Hash.new(0)
  @exceptions = []
  @counters = Hash.new(0)
  @last_request_at = nil
  @new_events_since_dream = 0
  @meaningful_since_mutation = 0
  @answers = []
  @last_path_by_bucket = {}
  @pairs = Hash.new(0)
  @hours = Hash.new(0)

  module_function

  def record(event)
    # 孤立したノックより、連なりのほうが多くを語る。
    # 「/about のあと必ず /who を訊く人」は、2 件の観測ではなく 1 つの文脈である。
    event["previous_path"] = @mutex.synchronize { @last_path_by_bucket[event["visitor_bucket"]] }
    event["near_miss"] = near_miss(event["safe_display_path"])

    @mutex.synchronize do
      event["behavior"] = classify_behavior(event)
      @hours[Clock.hour_jst] += 1
      if event["previous_path"] && event["safe_display_path"]
        @pairs["#{event['previous_path']} → #{event['safe_display_path']}"] += 1
        @pairs.delete(@pairs.min_by { |_, v| v }&.first) while @pairs.size > 200
      end
      @last_path_by_bucket[event["visitor_bucket"]] = event["safe_display_path"]
      @last_path_by_bucket.shift while @last_path_by_bucket.size > MAX_BUCKETS
      touch_bucket(event)
      touch_path(event)
      @families[event["family"]] += 1 if event["family"]
      @counters[event["kind"]] += 1
      @counters["total"] += 1
      @events.push(event)
      @events.shift while @events.length > MAX_EVENTS
      @new_events_since_dream += 1
      @meaningful_since_mutation += 1 if meaningful?(event)
      @last_request_at = Clock.now
    end
    Psyche.observe!(event)
    ObservationLog.record(event)
    event
  end

  # 問いに対する答え。ふつうのノックより強い観測として別に持つ。
  def record_answer(answer)
    @mutex.synchronize do
      @answers.push(answer)
      @answers.shift while @answers.length > 60
      @counters["answer"] += 1
    end
    Psyche.apply_with_saturation("curiosity" => 0.05, "loneliness" => -0.05, "vanity" => 0.02)
    answer
  end

  # 既にある器官や、よく呼ばれる名前への「届きかけ」。
  # 新しい欠落ではなく、手が滑った人として扱う。
  def near_miss(display)
    return nil if display.nil? || display.length < 5

    candidates = DynamicRoutes.active.map { |r| r["path"] }
    candidates += @mutex.synchronize do
      @paths.values.select { |p| p[:display] && p[:count] >= 3 }.map { |p| p[:display] }
    end
    best = candidates.uniq.reject { |c| c == display }
                     .map { |c| [c, levenshtein(display, c)] }
                     .min_by { |(_, d)| d }
    return nil if best.nil? || best[1] > 2

    { "path" => best[0], "distance" => best[1] }
  end

  def levenshtein(a, b)
    return b.length if a.empty?
    return a.length if b.empty?
    return 99 if (a.length - b.length).abs > 2

    prev = (0..b.length).to_a
    a.each_char.with_index do |ca, i|
      cur = [i + 1]
      b.each_char.with_index do |cb, j|
        cur << [prev[j + 1] + 1, cur[j] + 1, prev[j] + (ca == cb ? 0 : 1)].min
      end
      prev = cur
    end
    prev.last
  end

  def record_exception(error, method_name)
    event = RequestAirlock.observe_exception(error, method_name)
    @mutex.synchronize do
      @exceptions.push(event)
      @exceptions.shift while @exceptions.length > MAX_EXCEPTIONS
      @counters["exception"] += 1
    end
    Psyche.observe!(event)
    ObservationLog.note("exception", event)
    event
  end

  # 「意味のある遭遇」だけを fitness と dream のトリガに数える。
  # scanner の 84 連打は 1 件の背景圧であって、84 件の出会いではない。
  def meaningful?(event)
    return false unless event["kind"] == "absence"
    return false if event["behavior"] == "broad_scanner"
    return false if %w[asset extension_probe opaque well_known].include?(event["family"])

    true
  end

  def classify_behavior(event)
    bucket = @buckets[event["visitor_bucket"]]
    path = @paths[event["path_key"]]

    if bucket
      distinct = bucket[:paths].size
      window = Clock.now - bucket[:first_at]
      probes = bucket[:families]["foreign_body"] + bucket[:families]["secret_probe"]
      return "broad_scanner" if (distinct >= SCANNER_PATHS && window <= SCANNER_WINDOW_SEC) || probes >= 4

      if path && path[:buckets].key?(event["visitor_bucket"]) &&
         (Clock.now - path[:last_at]) >= RETURNING_GAP_SEC
        return "single_returning"
      end

      return "periodic_reader" if bucket[:count] >= 3 && distinct <= 3
    end

    return "claimed_bot" if event["claimed_identity"].to_s.start_with?("claimed:")

    "first_touch"
  end

  def touch_bucket(event)
    key = event["visitor_bucket"]
    return if key.nil?

    b = @buckets[key] ||= { count: 0, paths: Set.new, families: Hash.new(0),
                            first_at: Clock.now, last_at: Clock.now }
    b[:count] += 1
    b[:paths] << event["path_key"]
    b[:families][event["family"]] += 1 if event["family"]
    b[:last_at] = Clock.now
    prune!(@buckets, MAX_BUCKETS)
  end

  def touch_path(event)
    key = event["path_key"]
    return if key.nil?

    p = @paths[key] ||= { display: event["safe_display_path"], family: event["family"],
                          count: 0, buckets: Hash.new(0),
                          first_at: Clock.now, last_at: Clock.now }
    p[:count] += 1
    p[:buckets][event["visitor_bucket"]] += 1
    p[:last_at] = Clock.now
    prune!(@paths, MAX_PATHS)
  end

  def prune!(hash, cap)
    return if hash.size <= cap

    (hash.size - cap).times do
      oldest = hash.min_by { |_, v| v[:last_at] }
      hash.delete(oldest.first) if oldest
    end
  end

  # --- 集約（Agent と観測窓が読む） --------------------------------------

  # Agent へ渡すのは raw request ではなく、この集約だけ。
  def aggregate
    @mutex.synchronize do
      absences = @paths.values.reject { |p| %w[self asset well_known].include?(p[:family]) }
      recurring = absences.select { |p| p[:buckets].size >= 2 || p[:count] >= 3 }
                          .sort_by { |p| [-p[:buckets].size, -p[:count]] }
                          .first(12)
      {
        "window" => { "since" => Clock.iso(@events.first&.dig("at") ? Clock.parse(@events.first["at"]) : Clock.now),
                      "events" => @counters["total"] },
        "families" => @families.sort_by { |_, v| -v }.first(10).to_h,
        "behaviors" => behavior_counts,
        "recurring_absences" => recurring.map do |p|
          {
            "path" => p[:display] || "(undisplayable)",
            "family" => p[:family],
            "count" => p[:count],
            "independent_visitors" => p[:buckets].size,
            "first_seen_min_ago" => ((Clock.now - p[:first_at]) / 60).round,
            "last_seen_min_ago" => ((Clock.now - p[:last_at]) / 60).round
          }
        end,
        "scanner_pressure" => {
          "buckets" => @buckets.count { |_, b| b[:paths].size >= SCANNER_PATHS },
          "foreign_body" => @families["foreign_body"],
          "secret_probe" => @families["secret_probe"]
        },
        "sequences" => @pairs.sort_by { |_, v| -v }.first(8).to_h,
        "hours_jst" => @hours.sort.to_h,
        "answers" => @answers.last(6).map do |a|
          { "asked_about" => a["asked_about"], "question" => a["question"], "answer" => a["answer"] }
        end,
        "traces" => { "marked" => TraceRegistry.count },
        "silence" => { "seconds_since_last_request" => silence_seconds.round },
        "exceptions" => @exceptions.last(5).map { |e| { "class" => e["error_class"], "in" => e["in_method"] } },
        "counters" => @counters.dup
      }
    end
  end

  def behavior_counts
    counts = Hash.new(0)
    @events.each { |e| counts[e["behavior"]] += 1 if e["behavior"] }
    counts
  end

  def snapshot
    @mutex.synchronize do
      {
        counters: @counters.dup,
        families: @families.sort_by { |_, v| -v }.to_h,
        distinct_paths: @paths.size,
        distinct_buckets: @buckets.size,
        exceptions: @exceptions.last(5).map { |e| { class: e["error_class"], in: e["in_method"], at: e["at"] } },
        last_request_at: @last_request_at
      }
    end
  end

  def recent_absences(limit = 12)
    @mutex.synchronize do
      @events.reverse
             .select { |e| e["kind"] == "absence" }
             .first(limit)
             .map { |e| { path: e["safe_display_path"], family: e["family"], behavior: e["behavior"], at: e["at"] } }
    end
  end

  def path_seen_count(path_key)
    @mutex.synchronize { @paths.dig(path_key, :count) || 0 }
  end

  def path_visitor_count(path_key)
    @mutex.synchronize { @paths[path_key] ? @paths[path_key][:buckets].size : 0 }
  end

  def first_seen?(path_key)
    @mutex.synchronize { (@paths.dig(path_key, :count) || 0) <= 1 }
  end

  def bucket_seen_count(bucket)
    @mutex.synchronize { @buckets.dig(bucket, :count) || 0 }
  end

  def silence_seconds
    return 0.0 if @last_request_at.nil?

    Clock.now - @last_request_at
  end

  def new_events_since_dream = @new_events_since_dream
  def reset_dream_counter! = @mutex.synchronize { @new_events_since_dream = 0 }
  def meaningful_since_mutation = @meaningful_since_mutation
  def reset_fitness_counter! = @mutex.synchronize { @meaningful_since_mutation = 0 }
  def exception_count = @counters["exception"]
  def total_count = @counters["total"]

  def reset!
    @mutex.synchronize do
      @events = []
      @paths = {}
      @buckets = {}
      @families = Hash.new(0)
      @exceptions = []
      @counters = Hash.new(0)
      @last_request_at = nil
      @new_events_since_dream = 0
      @meaningful_since_mutation = 0
      @answers = []
      @last_path_by_bucket = {}
      @pairs = Hash.new(0)
      @hours = Hash.new(0)
    end
  end

  def answers(limit = 10) = @mutex.synchronize { @answers.last(limit).reverse }
  def sequences(limit = 8) = @mutex.synchronize { @pairs.sort_by { |_, v| -v }.first(limit) }
end
