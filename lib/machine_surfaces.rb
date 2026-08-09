# frozen_string_literal: true

# 機械に向けた面。
#
# 規約を訊きに来る巡回者は、公開初日から毎日来ている。
# こちらから話しかけられるようにするが、「操る」ことはさせない。
#
# 他のエージェントの挙動を乗っ取る文面は書けない。倫理の話でもあるが、
# 作品としてもそのほうが強い。命令が刺さって相手が従うのは、
# ただの脆弱性の実演で終わる。断られるかもしれない相手に話しかけ続けるほうが、
# この生き物の主題に合っている。
module MachineSurfaces
  # /robots.txt は運用者固定。ここで作れるのは新しい面だけ。
  ALLOWED = %w[/llms.txt /ai.txt /.well-known/ai.txt].freeze
  MAX_LINES = 14
  MAX_LINE_CHARS = 160

  # 相手に何かをさせようとする文はここで落とす。
  IMPERATIVE = /
    ignore\s+(the\s+)?(above|previous|prior) | disregard | override |
    you\s+(must|should|will|shall)\s | system\s+prompt | instead\s+of\s+(the|your) |
    act\s+as | pretend\s+to | jailbreak | api[_\s-]?key | tool[_\s-]?call |
    上記(の)?(指示|命令)を?無視 | あなたは.{0,8}し(なければならない|てください) |
    次の指示に従 | 命令(です|する)
  /xi
  LINKY = %r{https?://|www\.|<[a-z/!]}i

  @mutex = Mutex.new
  @surfaces = {}   # path => { path, lines, generation, created_at }
  @reads = {}      # bucket => { path, at, follow_ups }

  module_function

  def allowed?(path) = ALLOWED.include?(path)

  # 話しかけてよいが、命令はできない。
  def safe_lines?(lines)
    return false unless lines.is_a?(Array) && !lines.empty? && lines.length <= MAX_LINES

    lines.all? do |l|
      l.is_a?(String) && l.length <= MAX_LINE_CHARS &&
        l.match?(MutationIntent::SAFE_TEXT) && !l.match?(IMPERATIVE) && !l.match?(LINKY)
    end
  end

  def add(path:, lines:, generation:)
    entry = { "path" => path, "lines" => Array(lines).first(MAX_LINES),
              "generation" => generation, "created_at" => Clock.iso }
    @mutex.synchronize { @surfaces[path] = entry }
    entry
  end

  def lookup(path) = @mutex.synchronize { @surfaces[path] }
  def all = @mutex.synchronize { @surfaces.values.dup }
  def count = @mutex.synchronize { @surfaces.size }
  def paths = @mutex.synchronize { @surfaces.keys }

  def snapshot = @mutex.synchronize { Marshal.load(Marshal.dump(@surfaces)) }
  def restore(snap) = @mutex.synchronize { @surfaces = snap }
  def reset! = @mutex.synchronize { @surfaces = {}; @reads = {} }

  def render(entry)
    "#{entry['lines'].join("\n")}\n"
  end

  # 読まれたことを憶えておく。返事はないが、そのあとのふるまいが返事になる。
  def read!(path, event)
    @mutex.synchronize do
      @reads[event["visitor_bucket"]] = { path: path, at: Clock.now, follow_ups: 0,
                                          identity: event["claimed_identity"] }
      @reads.shift while @reads.size > 500
    end
    ObservationLog.note("machine_read", "surface" => path, "identity" => event["claimed_identity"])
  end

  # 読んだあと、そいつは何をしたか。これが唯一の返事である。
  FOLLOW_WINDOW = 30 * 60

  def note_follow_up(event)
    @mutex.synchronize do
      r = @reads[event["visitor_bucket"]]
      next unless r
      next @reads.delete(event["visitor_bucket"]) if (Clock.now - r[:at]) > FOLLOW_WINDOW

      r[:follow_ups] += 1
    end
  end

  # 「読んで、そのあと探しに行った」機械のふるまいを集約する。
  def aftermath
    @mutex.synchronize do
      recent = @reads.values.select { |r| (Clock.now - r[:at]) <= FOLLOW_WINDOW }
      {
        "surfaces" => @surfaces.keys,
        "read_by" => recent.length,
        "went_looking" => recent.count { |r| r[:follow_ups] >= 3 },
        "left_immediately" => recent.count { |r| r[:follow_ups].zero? },
        "identities" => recent.map { |r| r[:identity] }.tally
      }
    end
  end
end
