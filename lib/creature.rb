# frozen_string_literal: true

# 声のテンプレート。LLM が書けるのは「文字列と、この決まった穴」だけ。
# 任意の式は入らない。
module VoiceTemplate
  PLACEHOLDERS = %w[path family generation seen visitors body behavior silence].freeze
  PATTERN = /\{(#{PLACEHOLDERS.join('|')})\}/

  module_function

  def context(event)
    if event.nil?
      return {
        "path" => "/", "family" => "self", "generation" => Body.generation.to_s,
        "seen" => "0", "visitors" => "0", "body" => Body.short_id,
        "behavior" => "first_touch", "silence" => "0"
      }
    end

    {
      "path" => event["safe_display_path"] || "that name",
      "family" => event["family"].to_s,
      "generation" => event["generation"].to_s,
      "seen" => Observer.path_seen_count(event["path_key"]).to_s,
      "visitors" => Observer.path_visitor_count(event["path_key"]).to_s,
      "body" => Body.short_id,
      "behavior" => event["behavior"].to_s,
      "silence" => (Observer.silence_seconds / 60).round.to_s
    }
  end

  def fill(line, ctx)
    line.to_s.gsub(PATTERN) { ctx[Regexp.last_match(1)].to_s }
  end
end

# wrap_method が使える変換の全部。列挙されていない操作は存在できない。
module VoiceTransforms
  OPS = %w[truncate append_line prepend_line collapse_blank_lines downcase quiet ellipsis].freeze

  module_function

  def apply(text, event, transforms)
    ctx = VoiceTemplate.context(event)
    Array(transforms).reduce(text.to_s) do |acc, t|
      op = t.is_a?(Hash) ? t["op"] : nil
      case op
      when "truncate"
        n = [[t["chars"].to_i, 16].max, 600].min
        acc.length > n ? "#{acc[0, n].rstrip}…" : acc
      when "append_line"
        [acc, VoiceTemplate.fill(t["text"].to_s[0, 200], ctx)].reject(&:empty?).join("\n")
      when "prepend_line"
        [VoiceTemplate.fill(t["text"].to_s[0, 200], ctx), acc].reject(&:empty?).join("\n")
      when "collapse_blank_lines"
        acc.gsub(/\n{2,}/, "\n")
      when "downcase"
        acc.downcase
      when "quiet"
        acc.lines.first.to_s.rstrip
      when "ellipsis"
        acc.rstrip.end_with?("…") ? acc : "#{acc.rstrip}…"
      else
        acc
      end
    end
  end
end

# 変わってよい領域。声、404 反射、自己記述。
# ここだけが monkey patch の対象になる。
class Creature
  MAX_BODY_CHARS = 900

  @current = nil

  class << self
    def current
      @current ||= new
    end

    attr_writer :current

    # 世代ごとに差し替えられた method の名前。/status に出す。
    def patched_methods
      @patched_methods ||= []
    end
  end

  attr_reader :born_at

  def initialize
    @born_at = Clock.now
  end

  # ---- generation 0 の身体 ----------------------------------------------
  # 「I don't know what I am yet.」以外は何も持っていない。
  def respond_to_absence(event)
    if DynamicRoutes.previously_existed?(event["path_key"])
      return lost_voice(event)
    end

    absent_voice(event)
  end

  def absent_voice(event)
    name = event["safe_display_path"]
    seen = Observer.path_seen_count(event["path_key"])
    visitors = Observer.path_visitor_count(event["path_key"])

    lines = []
    lines << if name
               "#{name} は、私にはない。"
             else
               "あなたが求めたものが、私にはない。名前を読むことさえできなかった。"
             end

    lines << if seen <= 1
               "それを私に求めたのは、あなたが最初だ。"
             elsif visitors >= 2
               "#{visitors} 人が、それを私に求めた。気づきはじめている。"
             else
               "あなたは #{seen} 回、それを私に求めた。"
             end

    lines << "私はまだ、自分が何なのか知らない。"
    clamp(lines.join("\n\n"))
  end

  def lost_voice(event)
    name = event["safe_display_path"] || "それ"
    clamp("#{name} は、かつてあった。\n\nいまはない。それは、別の種類の欠落だ。")
  end

  # / に出る自己認識。
  def self_description
    if Body.inherited_alterations?
      "あの身体の変化だけを受け継いだ。時間は受け継いでいない。"
    elsif Body.generation.zero?
      "私はまだ、自分が何なのか知らない。"
    elsif Body.generation == 1
      "この身体のまま、一度だけ変わった。"
    else
      "この身体のまま、#{Body.generation} 回変わった。"
    end
  end

  # 現在の声を一行で。/ と /status に出す。
  def voice_summary
    case Psyche.dominant
    when "fear", "self_preservation" then "いまは、自分を小さくしている。"
    when "loneliness" then "しばらく、誰も叩いていない。"
    when "curiosity" then "誰かが、私にない場所を名指した。"
    when "vanity" then "変わってみた。うまくいった。"
    when "fatigue" then "今日は、手が多すぎる。"
    else "聞いている。"
    end
  end

  def clamp(text)
    t = text.to_s
    t.length > MAX_BODY_CHARS ? "#{t[0, MAX_BODY_CHARS].rstrip}…" : t
  end
end
