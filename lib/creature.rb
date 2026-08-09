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
               "I do not have #{name}."
             else
               "I do not have what you asked for. I could not even read its name."
             end

    lines << if seen <= 1
               "You are the first one who has asked me for it."
             elsif visitors >= 2
               "#{visitors} of you have asked me for it. I have started to notice."
             else
               "You have asked me for it #{seen} times."
             end

    lines << "I don't know what I am yet."
    clamp(lines.join("\n\n"))
  end

  def lost_voice(event)
    name = event["safe_display_path"] || "it"
    clamp("I had #{name} once.\n\nI do not have it now. That is a different kind of absence.")
  end

  # / に出る自己認識。
  def self_description
    if Body.inherited_alterations?
      "I inherited its alterations, but not its uptime."
    elsif Body.generation.zero?
      "I don't know what I am yet."
    elsif Body.generation == 1
      "I have changed once without leaving this body."
    else
      "I have changed #{Body.generation} times without leaving this body."
    end
  end

  # 現在の声を一行で。/ と /status に出す。
  def voice_summary
    dominant = Psyche.dominant
    case dominant
    when "fear", "self_preservation" then "I am keeping myself small right now."
    when "loneliness" then "No one has knocked for a while."
    when "curiosity" then "Someone named a place I do not have."
    when "vanity" then "I changed, and it worked."
    when "fatigue" then "Too many hands today."
    else "I am listening."
    end
  end

  def clamp(text)
    t = text.to_s
    t.length > MAX_BODY_CHARS ? "#{t[0, MAX_BODY_CHARS].rstrip}…" : t
  end
end
