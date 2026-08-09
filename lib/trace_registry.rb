# frozen_string_literal: true

# 痕。
#
# 意味のある不在が「はじめて名指された」ときにだけ生まれ、住所を持つ。
# 訪問者はその住所を持ち帰れる。誰が名付けたかは記録しない。
# 記録するのは人ではなく、出来事のほうである。
#
# 痕は時間とともに薄れる。誰も戻ってこなければ言葉を忘れる。
# ただし path_key は残すので、もう一度同じ名前で呼ばれれば思い出す。
# 忘れたが、聞けば分かる。
module TraceRegistry
  SHARP_DAYS = 7          # ここまでは鮮明
  FADING_DAYS = 21        # ここを越えると言葉を失う
  MAX_TRACES = 5_000      # 記憶は有限

  @mutex = Mutex.new
  @by_key = {}            # path_key => id
  @loaded = false

  module_function

  def dir = Config.trace_dir
  def path_for(id) = Store.sequence_path(dir, id, ".json")

  def load!
    @mutex.synchronize do
      @by_key = {}
      Dir.glob(File.join(dir, "*.json")).sort.each do |f|
        t = Store.read_json(f)
        @by_key[t["path_key"]] = t["id"] if t.is_a?(Hash) && t["path_key"]
      end
      @loaded = true
    end
    self
  end

  def count
    load! unless @loaded
    @mutex.synchronize { @by_key.size }
  end

  def find(id)
    return nil unless id.is_a?(Integer) && id.positive?

    Store.read_json(path_for(id))
  end

  def id_for(path_key)
    load! unless @loaded
    @mutex.synchronize { @by_key[path_key] }
  end

  # 印がつくのは「名指し」だけ。探索は名指しではない。
  # /wp-admin を叩く手は場所を想像していないので、痕は残らない。
  # もらえる条件が「最初に名指した一人であること」だから、意味が出る。
  NAMING = %w[imagined_place question unknown].freeze

  def mark?(event)
    return false unless Config.traces?
    return false unless event["kind"] == "absence"
    return false unless NAMING.include?(event["family"])
    return false unless Observer.meaningful?(event)
    return false if event["safe_display_path"].nil?
    return false if count >= MAX_TRACES

    id_for(event["path_key"]).nil?
  end

  # 返り値は [trace, :minted | :joined | :revived]
  def touch!(event)
    return nil unless Config.traces?

    existing = id_for(event["path_key"])
    return mint!(event) if existing.nil? && mark?(event)
    return nil if existing.nil?

    join!(existing, event)
  end

  def mint!(event)
    id = nil
    @mutex.synchronize do
      id = Store.next_sequence(dir, ".json")
      trace = {
        "id" => id,
        "at" => Clock.iso,
        "path_key" => event["path_key"],
        "name" => event["safe_display_path"],
        "family" => event["family"],
        "hour_jst" => Clock.hour_jst,
        "asks" => 1,
        "askers" => 1,
        "buckets" => [event["visitor_bucket"]],
        "last_asked_at" => Clock.iso,
        "visits" => 0,
        "last_visited_at" => nil,
        "became" => nil,
        "forgotten_at" => nil,
        "revivals" => 0,
        "generation" => Body.generation
      }
      Store.write_json!(path_for(id), trace)
      @by_key[event["path_key"]] = id
    end
    [find(id), :minted]
  end

  # 2 人目以降。先人の痕へ合流する。
  def join!(id, event)
    result = :joined
    trace = update(id) do |t|
      t["asks"] = t["asks"].to_i + 1
      t["last_asked_at"] = Clock.iso
      buckets = Array(t["buckets"])
      unless buckets.include?(event["visitor_bucket"])
        buckets = (buckets + [event["visitor_bucket"]]).last(64)
        t["askers"] = t["askers"].to_i + 1
      end
      t["buckets"] = buckets

      # 忘れていた言葉を、もう一度言われて思い出す。
      if t["forgotten_at"] && event["safe_display_path"]
        t["name"] = event["safe_display_path"]
        t["forgotten_at"] = nil
        t["revivals"] = t["revivals"].to_i + 1
        result = :revived
      end
      t
    end
    trace ? [trace, result] : nil
  end

  # 痕そのものを見に来ることも、注意を注ぐことである。
  def visited!(id)
    update(id) do |t|
      t["visits"] = t["visits"].to_i + 1
      t["last_visited_at"] = Clock.iso
      t
    end
  end

  # 器官になったら、その痕に由来を書き戻す。
  def became_organ!(path, organ_path)
    id = id_for(RequestAirlock.path_key(path))
    return nil unless id

    update(id) { |t| t.merge("became" => organ_path, "became_at" => Clock.iso) }
  end

  def update(id)
    path = path_for(id)
    Store.with_file_lock("trace-#{id}.lock") do
      t = Store.read_json(path)
      next nil unless t

      Store.write_json!(path, yield(t))
    end
  rescue StandardError
    nil
  end

  # 誰も戻ってこない痕は薄れる。最後に注意が注がれてからの日数で決まる。
  def days_since_attention(trace)
    last = [Clock.parse(trace["last_asked_at"]), Clock.parse(trace["last_visited_at"])].compact.max
    return Float::INFINITY unless last

    (Clock.now - last) / 86_400.0
  end

  def weather(trace)
    return :forgotten if trace["forgotten_at"]

    d = days_since_attention(trace)
    return :sharp if d < SHARP_DAYS
    return :fading if d < FADING_DAYS

    :forgotten
  end

  # 風化を実際に紙へ書き込む。ここではじめて言葉が失われる。
  def weather!(trace)
    return trace if trace["forgotten_at"]
    return trace unless weather(trace) == :forgotten

    update(trace["id"]) { |t| t.merge("name" => nil, "forgotten_at" => Clock.iso) } || trace
  end

  # 起動と tick から呼ぶ掃除。読むときだけ風化させると、
  # 誰も見に来ない痕が永遠に鮮明なままになってしまう。
  def sweep!
    return 0 unless Config.traces?

    faded = 0
    Dir.glob(File.join(dir, "*.json")).each do |f|
      t = Store.read_json(f)
      next unless t.is_a?(Hash)
      next if t["forgotten_at"]
      next unless weather(t) == :forgotten

      weather!(t)
      faded += 1
    end
    faded
  rescue StandardError
    0
  end

  def recent(limit = 12)
    Dir.glob(File.join(dir, "*.json")).sort.reverse.first(limit).filter_map { |f| Store.read_json(f) }
  end

  def reset!
    @mutex.synchronize do
      @by_key = {}
      @loaded = true
    end
  end
end
