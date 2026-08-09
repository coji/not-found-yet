# frozen_string_literal: true

# ふるまいの規則。
#
# 何を言うかではなく、どう応じるかを変える。ためらう、黙る、読み替える。
# 反射が 3ms の生き物にとって、900ms の沈黙は雄弁である。
#
# 規則そのものは Creature が獲得するが、実行するのはここ（不変側）。
module ReflexConditions
  MAX_RULES = 6
  MAX_HESITATE_MS = 1_500
  STATUSES = [204, 402, 404, 410, 418, 429].freeze
  PREDICATES = %w[family behavior hour_between psyche_above seen_at_least near_miss silence_over_minutes].freeze
  ACTIONS = %w[hesitate silence status redirect shorten].freeze

  # ためらいは thread を占有する。scanner の burst で全部塞がると身体が止まる。
  # 同時にためらえるのは 2 本まで、と決めておく。
  MAX_CONCURRENT_HESITATIONS = 2

  @mutex = Mutex.new
  @rules = []
  @hesitating = 0

  module_function

  def rules = @mutex.synchronize { @rules.dup }
  def count = @mutex.synchronize { @rules.length }

  def replace(rules)
    @mutex.synchronize { @rules = Array(rules).first(MAX_RULES) }
  end

  def add(rule)
    @mutex.synchronize do
      @rules = (@rules + [rule]).last(MAX_RULES)
    end
  end

  def snapshot = @mutex.synchronize { Marshal.load(Marshal.dump(@rules)) }
  def restore(snap) = @mutex.synchronize { @rules = snap }
  def reset! = @mutex.synchronize { @rules = []; @hesitating = 0 }

  # 最初に当たった規則だけを効かせる。重ねると読めなくなる。
  def decide(event)
    rules.each do |rule|
      return rule["do"] if matches?(rule["when"], event)
    end
    nil
  end

  def matches?(cond, event)
    return false unless cond.is_a?(Hash)

    cond.all? do |key, value|
      case key
      when "family" then event["family"] == value
      when "behavior" then event["behavior"] == value
      when "hour_from"
        a = value.to_i
        b = cond["hour_to"].to_i
        h = Clock.hour_jst
        a <= b ? h >= a && h < b : h >= a || h < b # 夜をまたぐ窓
      when "hour_to" then true # hour_from と対で見る
      when "psyche_state" then Psyche[value.to_s] > cond["psyche_above"].to_f
      when "psyche_above" then true # psyche_state と対で見る
      when "seen_at_least" then Observer.path_seen_count(event["path_key"]) >= value.to_i
      when "near_miss" then !event["near_miss"].nil? == (value == true)
      when "silence_over_minutes" then Observer.silence_seconds >= value.to_i * 60
      else false
      end
    end
  rescue StandardError
    false
  end

  # ためらう。ただし身体を止めない範囲で。
  def hesitate!(ms)
    ms = [[ms.to_i, 0].max, MAX_HESITATE_MS].min
    return 0 if ms.zero?

    allowed = @mutex.synchronize do
      next false if @hesitating >= MAX_CONCURRENT_HESITATIONS

      @hesitating += 1
      true
    end
    return 0 unless allowed

    begin
      sleep(ms / 1000.0)
      ms
    ensure
      @mutex.synchronize { @hesitating -= 1 }
    end
  end

  def describe(rule)
    w = rule["when"].map { |k, v| v == true ? k : "#{k}=#{v}" }.join(" & ")
    d = rule["do"].map { |k, v| v == true ? k : "#{k}=#{v}" }.join(" ")
    "#{w} → #{d}"
  end
end
