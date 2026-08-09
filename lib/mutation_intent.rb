# frozen_string_literal: true

# 許可する mutation の言語そのもの。
# 任意定数参照、File / IO / ENV、system、require、socket、thread 生成は
# この言語では表現できない。書けないものは起こらない。
module MutationIntent
  TYPES = %w[
    rewrite_absence_voice
    add_route
    add_organ
    reshape_organ
    retire_route
    wrap_method
    adjust_desire_weights
    add_reflex_condition
    speak_to_machines
    invent_family
    forget_family
    no_change
  ].freeze

  # wrap_method で触ってよい method は列挙のみ。
  WRAPPABLE_METHODS = %w[respond_to_absence absent_voice lost_voice self_description voice_summary].freeze
  CONTENT_TYPES = %w[text/plain text/html].freeze
  FAMILIES = (%w[* self imagined_place question foreign_body secret_probe
                 extension_probe asset opaque well_known unknown]).freeze

  MAX_LINES = 6
  MAX_LINE_CHARS = 200
  MAX_TRANSFORMS = 4
  BEHAVIORS = %w[first_touch single_returning broad_scanner periodic_reader claimed_bot].freeze
  MAX_TEXT_CHARS = 200

  # 制御文字・改行・HTML を含む文字列は、そもそも受け取らない。
  SAFE_TEXT = /\A[^\u0000-\u001F\u007F<>]{0,200}\z/

  class Invalid < StandardError; end

  module_function

  # ---- 検証 --------------------------------------------------------------
  # 例外ではなく [ok, normalized_or_reason] を返す。拒否も観測対象だから。
  def validate(intent)
    return [false, "intent must be an object"] unless intent.is_a?(Hash)

    type = intent["type"]
    return [false, "unknown intent type: #{type.inspect}"] unless TYPES.include?(type)

    send(:"validate_#{type}", intent)
  rescue StandardError => e
    [false, "validation error: #{e.class}"]
  end

  def validate!(intent)
    ok, result = validate(intent)
    raise Invalid, result unless ok

    result
  end

  def validate_no_change(_intent)
    [true, { "type" => "no_change" }]
  end

  def validate_rewrite_absence_voice(intent)
    templates = intent["templates"]
    return [false, "templates must be a non-empty array"] unless templates.is_a?(Array) && !templates.empty?
    return [false, "too many templates"] if templates.length > Config.max_voice_templates

    normalized = templates.map do |t|
      return [false, "template must be an object"] unless t.is_a?(Hash)

      family = t["family"].to_s
      return [false, "unknown family: #{family}"] unless FAMILIES.include?(family)

      lines = t["lines"]
      return [false, "lines must be a non-empty array"] unless lines.is_a?(Array) && !lines.empty?
      return [false, "too many lines"] if lines.length > MAX_LINES

      lines = lines.map do |l|
        return [false, "unsafe line"] unless l.is_a?(String) && l.match?(SAFE_TEXT)

        l
      end
      { "family" => family, "lines" => lines }
    end

    max_length = clamp_int(intent["max_length"], 80, Creature::MAX_BODY_CHARS, 400)
    [true, { "type" => "rewrite_absence_voice", "templates" => normalized, "max_length" => max_length }]
  end

  def validate_add_route(intent)
    path = intent["path"]
    return [false, "invalid or reserved path"] unless DynamicRoutes.valid_path?(path)
    return [false, "route already exists"] if DynamicRoutes.lookup(path)
    return [false, "too many routes"] if DynamicRoutes.count >= Config.max_dynamic_routes

    lines = intent["lines"]
    return [false, "lines must be a non-empty array"] unless lines.is_a?(Array) && !lines.empty?
    return [false, "too many lines"] if lines.length > MAX_LINES

    lines.each { |l| return [false, "unsafe line"] unless l.is_a?(String) && l.match?(SAFE_TEXT) }

    ct = intent["content_type"] || "text/plain"
    return [false, "unsupported content type"] unless CONTENT_TYPES.include?(ct)

    title = intent["title"].to_s
    return [false, "unsafe title"] unless title.match?(SAFE_TEXT)

    [true, { "type" => "add_route", "path" => path, "title" => title,
             "lines" => lines, "content_type" => ct }]
  end

  def validate_retire_route(intent)
    path = intent["path"]
    return [false, "invalid path"] unless path.is_a?(String)
    return [false, "no such acquired route"] unless DynamicRoutes.lookup(path)

    [true, { "type" => "retire_route", "path" => path, "gone" => intent["gone"] != false }]
  end

  def validate_wrap_method(intent)
    method_name = intent["method"].to_s
    return [false, "method not wrappable"] unless WRAPPABLE_METHODS.include?(method_name)

    transforms = intent["transforms"]
    return [false, "transforms must be a non-empty array"] unless transforms.is_a?(Array) && !transforms.empty?
    return [false, "too many transforms"] if transforms.length > MAX_TRANSFORMS

    normalized = transforms.map do |t|
      return [false, "transform must be an object"] unless t.is_a?(Hash)

      op = t["op"].to_s
      return [false, "unknown transform op: #{op}"] unless VoiceTransforms::OPS.include?(op)

      h = { "op" => op }
      case op
      when "truncate"
        h["chars"] = clamp_int(t["chars"], 16, 600, 240)
      when "append_line", "prepend_line"
        text = t["text"].to_s
        return [false, "unsafe transform text"] unless text.match?(SAFE_TEXT) && !text.empty?

        h["text"] = text[0, MAX_TEXT_CHARS]
      end
      h
    end

    [true, { "type" => "wrap_method", "method" => method_name, "transforms" => normalized }]
  end

  def validate_adjust_desire_weights(intent)
    deltas = intent["deltas"]
    return [false, "deltas must be an object"] unless deltas.is_a?(Hash) && !deltas.empty?

    normalized = {}
    deltas.each do |k, v|
      next if v.nil?
      return [false, "unknown desire: #{k}"] unless Psyche::STATES.include?(k)
      return [false, "delta must be numeric"] unless v.is_a?(Numeric)

      normalized[k] = [[v.to_f, -Psyche::ADJUST_CAP].max, Psyche::ADJUST_CAP].min
    end
    return [false, "no valid deltas"] if normalized.empty?

    [true, { "type" => "adjust_desire_weights", "deltas" => normalized }]
  end

  # 器官。静的なページではなく、その瞬間の身体を映す窓。
  def validate_add_organ(intent)
    path = intent["path"]
    return [false, "invalid or reserved path"] unless DynamicRoutes.valid_path?(path)
    return [false, "organ already exists"] if DynamicRoutes.lookup(path)
    return [false, "too many organs"] if DynamicRoutes.count >= Config.max_dynamic_routes

    ok, shape = organ_shape(intent)
    return [false, shape] unless ok

    title = intent["title"].to_s
    return [false, "unsafe title"] unless title.match?(SAFE_TEXT)

    [true, { "type" => "add_organ", "path" => path, "title" => title }.merge(shape)]
  end

  # 獲得済みの器官も変わる。増やすことしかできない身体は、ただ長くなるだけ。
  def validate_reshape_organ(intent)
    path = intent["path"]
    entry = DynamicRoutes.lookup(path)
    return [false, "no such organ"] unless entry

    ok, shape = organ_shape(intent, fallback: entry)
    return [false, shape] unless ok

    [true, { "type" => "reshape_organ", "path" => path }.merge(shape)]
  end

  def organ_shape(intent, fallback: nil)
    form = intent["form"] || fallback&.dig("form") || "still"
    return [false, "unknown form"] unless TrustedRenderer::FORMS.include?(form)

    source = intent["source"] || fallback&.dig("source")
    return [false, "unknown source"] if source && !TrustedRenderer::SOURCES.include?(source)

    mood = intent["mood"] || fallback&.dig("mood") || "quiet"
    return [false, "unknown mood"] unless TrustedRenderer::MOODS.include?(mood)

    motion = intent["motion"] || fallback&.dig("motion") || "still"
    return [false, "unknown motion"] unless TrustedRenderer::MOTIONS.include?(motion)

    lines = intent["lines"] || fallback&.dig("lines")
    return [false, "lines must be a non-empty array"] unless lines.is_a?(Array) && !lines.empty?
    return [false, "too many lines"] if lines.length > MAX_LINES

    lines.each { |l| return [false, "unsafe line"] unless l.is_a?(String) && l.match?(SAFE_TEXT) }

    faces = intent["faces"] || fallback&.dig("faces")
    if faces
      return [false, "faces must be an array"] unless faces.is_a?(Array)
      return [false, "too many faces"] if faces.length > TrustedRenderer::AUDIENCES.length

      faces = faces.map do |f|
        return [false, "face must be an object"] unless f.is_a?(Hash)
        return [false, "unknown audience"] unless TrustedRenderer::AUDIENCES.include?(f["audience"])

        fl = f["lines"]
        return [false, "face lines must be a non-empty array"] unless fl.is_a?(Array) && !fl.empty?
        return [false, "too many face lines"] if fl.length > MAX_LINES

        fl.each { |l| return [false, "unsafe face line"] unless l.is_a?(String) && l.match?(SAFE_TEXT) }
        { "audience" => f["audience"], "lines" => fl }
      end
    end

    [true, { "form" => form, "source" => source, "mood" => mood,
             "motion" => motion, "lines" => lines, "faces" => faces }]
  end

  # ふるまいの規則。何を言うかではなく、どう応じるか。
  #
  # 正規化しても key の名前を変えない。replay は同じ validator を通るので、
  # 出力を再検証できない形にすると cold start で化石化する。
  def validate_add_reflex_condition(intent)
    rule = intent["rule"]
    return [false, "rule must be an object"] unless rule.is_a?(Hash)

    w = rule["when"]
    d = rule["do"]
    return [false, "when must be an object"] unless w.is_a?(Hash)
    return [false, "do must be an object"] unless d.is_a?(Hash)

    cond = {}
    if w["family"]
      return [false, "unknown family"] unless LearnedFamilies.known?(w["family"])

      cond["family"] = w["family"]
    end
    if w["behavior"]
      return [false, "unknown behavior"] unless BEHAVIORS.include?(w["behavior"])

      cond["behavior"] = w["behavior"]
    end
    if w["hour_from"] && w["hour_to"]
      a = clamp_int(w["hour_from"], 0, 23, 0)
      b = clamp_int(w["hour_to"], 0, 23, 0)
      return [false, "empty hour window"] if a == b

      cond["hour_from"] = a
      cond["hour_to"] = b
    end
    if w["psyche_state"]
      return [false, "unknown desire"] unless Psyche::STATES.include?(w["psyche_state"])

      cond["psyche_state"] = w["psyche_state"]
      cond["psyche_above"] = [[w["psyche_above"].to_f, 0.0].max, 1.0].min
    end
    cond["seen_at_least"] = clamp_int(w["seen_at_least"], 1, 100, 2) if w["seen_at_least"]
    cond["near_miss"] = true if w["near_miss"] == true
    cond["silence_over_minutes"] = clamp_int(w["silence_over_minutes"], 1, 1440, 60) if w["silence_over_minutes"]
    return [false, "condition must say something"] if cond.empty?

    act = {}
    act["hesitate_ms"] = clamp_int(d["hesitate_ms"], 50, ReflexConditions::MAX_HESITATE_MS, 400) if d["hesitate_ms"]
    act["silence"] = true if d["silence"] == true
    if d["status"]
      st = d["status"].to_i
      return [false, "status not allowed"] unless ReflexConditions::STATUSES.include?(st)

      act["status"] = st
    end
    if d["redirect_to"]
      # 連れて行けるのは、自分が既に持っている場所だけ。
      return [false, "can only redirect to an organ it already has"] unless DynamicRoutes.lookup(d["redirect_to"])

      act["redirect_to"] = d["redirect_to"]
    end
    act["shorten_to"] = clamp_int(d["shorten_to"], 16, 400, 120) if d["shorten_to"]
    return [false, "action must do something"] if act.empty?
    return [false, "silence and status conflict"] if act["silence"] && act["status"]

    normalized = { "type" => "add_reflex_condition", "rule" => { "when" => cond, "do" => act } }
    # 既にある規則と同じなら、上限には数えない（replay で自分自身を数えないため）。
    unless ReflexConditions.rules.include?(normalized["rule"])
      return [false, "too many rules"] if ReflexConditions.count >= ReflexConditions::MAX_RULES
    end

    [true, normalized]
  end

  # 機械に話しかける。命令はできない。
  def validate_speak_to_machines(intent)
    path = intent["surface"]
    return [false, "surface not allowed"] unless MachineSurfaces.allowed?(path)

    lines = intent["lines"]
    return [false, "lines must be safe, non-imperative and link-free"] unless MachineSurfaces.safe_lines?(lines)

    [true, { "type" => "speak_to_machines", "surface" => path, "lines" => lines }]
  end

  # 自分の分類を作る。曖昧だったものにしか効かない。
  def validate_invent_family(intent)
    name = intent["family_name"].to_s
    return [false, "unsafe name"] unless name.match?(SAFE_TEXT) && !name.empty?
    return [false, "name too long"] if name.length > LearnedFamilies::MAX_NAME
    return [false, "that family already exists"] if RequestAirlock::BUILT_IN_FAMILIES.include?(name)
    if LearnedFamilies.count >= LearnedFamilies::MAX && !LearnedFamilies.names.include?(name)
      return [false, "too many families"]
    end

    shape = intent["match_shape"].to_s
    return [false, "unknown shape"] unless LearnedFamilies::SHAPES.include?(shape)

    value = intent["match_value"]
    normalized_value =
      case shape
      when "max_length" then clamp_int(value, 2, Config::MAX_DISPLAY_PATH_CHARS, 16)
      when "script"
        return [false, "unknown script"] unless LearnedFamilies::SCRIPTS.include?(value.to_s)

        value.to_s
      else
        v = value.to_s
        return [false, "unsafe match value"] unless v.match?(SAFE_TEXT) && v.length.between?(1, 24)

        v
      end

    deltas = {}
    (intent["deltas"] || {}).each do |k, v|
      next if v.nil?
      next unless Psyche::STATES.include?(k)

      deltas[k] = [[v.to_f, -0.02].max, 0.02].min
    end

    [true, { "type" => "invent_family", "family_name" => name,
             "match_shape" => shape, "match_value" => normalized_value, "deltas" => deltas }]
  end

  # 見えなくする。自傷としての忘却で、これは本当に失われる。
  def validate_forget_family(intent)
    name = intent["family_name"].to_s
    known = LearnedFamilies.names.include?(name) || LearnedFamilies.blind.include?(name)
    return [false, "cannot go blind to that"] unless known || LearnedFamilies::BLINDABLE.include?(name)

    [true, { "type" => "forget_family", "family_name" => name }]
  end

  def clamp_int(value, min, max, default)
    n = Integer(value) rescue default
    [[n, min].max, max].min
  end

  # ---- 複雑性コスト ------------------------------------------------------
  # 獲得は必ず何かを重くする。上限に当たったら retire を要求できるように。
  def complexity_cost(intent)
    case intent["type"]
    when "add_route" then 0.10 + 0.01 * intent["lines"].length
    when "add_organ" then 0.12 + 0.01 * intent["lines"].length + (intent["faces"] ? 0.03 * intent["faces"].length : 0)
    when "reshape_organ" then 0.03
    when "rewrite_absence_voice" then 0.02 * intent["templates"].length
    when "wrap_method" then 0.03 * intent["transforms"].length
    when "retire_route" then -0.08
    when "adjust_desire_weights" then 0.01
    when "add_reflex_condition" then 0.06
    when "speak_to_machines" then 0.04 + 0.005 * intent["lines"].length
    when "invent_family" then 0.05
    when "forget_family" then -0.04
    else 0.0
    end.round(3)
  end

  def describe(intent)
    case intent["type"]
    when "add_route" then "add_route #{intent['path']}"
    when "add_organ" then "add_organ #{intent['path']} (#{intent['form']}/#{intent['mood']})"
    when "reshape_organ" then "reshape_organ #{intent['path']} → #{intent['form']}/#{intent['mood']}/#{intent['motion']}"
    when "retire_route" then "retire_route #{intent['path']}"
    when "wrap_method" then "wrap_method #{intent['method']} (#{intent['transforms'].map { |t| t['op'] }.join(', ')})"
    when "rewrite_absence_voice" then "rewrite_absence_voice (#{intent['templates'].length} templates)"
    when "adjust_desire_weights" then "adjust_desire_weights #{intent['deltas'].keys.join(', ')}"
    when "add_reflex_condition" then "add_reflex_condition #{ReflexConditions.describe(intent['rule'])}"
    when "speak_to_machines" then "speak_to_machines #{intent['surface']}"
    when "invent_family" then "invent_family #{intent['family_name']} (#{intent['match_shape']}: #{intent['match_value']})"
    when "forget_family" then "forget_family #{intent['family_name']}"
    else intent["type"].to_s
    end
  end

  # ---- structured output の strict schema -------------------------------
  # strict: true では全 property が required なので、使わない field は null 型を許す。
  def decision_schema
    {
      "type" => "object",
      "additionalProperties" => false,
      "required" => %w[observation_summary interpretation dominant_desire candidates
                       choice_index sacrifice fitness_hypothesis],
      "properties" => {
        "observation_summary" => { "type" => "string", "maxLength" => 600 },
        "interpretation" => { "type" => "string", "maxLength" => 600 },
        "dominant_desire" => { "type" => "string", "enum" => Psyche::STATES },
        "candidates" => {
          "type" => "array", "minItems" => 1, "maxItems" => 3,
          "items" => {
            "type" => "object",
            "additionalProperties" => false,
            "required" => %w[intent expected_gain],
            "properties" => {
              "intent" => intent_schema,
              "expected_gain" => { "type" => "number" }
            }
          }
        },
        "choice_index" => { "type" => "integer" },
        "sacrifice" => { "type" => "string", "maxLength" => 200 },
        "fitness_hypothesis" => { "type" => "string", "maxLength" => 200 }
      }
    }
  end

  def intent_schema
    {
      "type" => "object",
      "additionalProperties" => false,
      "required" => %w[type path title lines content_type templates max_length method transforms deltas gone
                       rule surface family_name match_shape match_value
                       form source mood motion faces],
      "properties" => {
        "type" => { "type" => "string", "enum" => TYPES },
        "path" => nullable({ "type" => "string" }),
        "title" => nullable({ "type" => "string" }),
        "lines" => nullable({ "type" => "array", "items" => { "type" => "string" } }),
        "content_type" => nullable({ "type" => "string", "enum" => CONTENT_TYPES }),
        "templates" => nullable({
          "type" => "array",
          "items" => {
            "type" => "object",
            "additionalProperties" => false,
            "required" => %w[family lines],
            "properties" => {
              "family" => { "type" => "string", "enum" => FAMILIES },
              "lines" => { "type" => "array", "items" => { "type" => "string" } }
            }
          }
        }),
        "max_length" => nullable({ "type" => "integer" }),
        "method" => nullable({ "type" => "string", "enum" => WRAPPABLE_METHODS }),
        "transforms" => nullable({
          "type" => "array",
          "items" => {
            "type" => "object",
            "additionalProperties" => false,
            "required" => %w[op chars text],
            "properties" => {
              "op" => { "type" => "string", "enum" => VoiceTransforms::OPS },
              "chars" => nullable({ "type" => "integer" }),
              "text" => nullable({ "type" => "string" })
            }
          }
        }),
        "deltas" => nullable({
          "type" => "object",
          "additionalProperties" => false,
          "required" => Psyche::STATES,
          "properties" => Psyche::STATES.to_h { |s| [s, nullable({ "type" => "number" })] }
        }),
        "gone" => nullable({ "type" => "boolean" }),

        # ふるまいの規則。条件も動作も列挙で、任意の式は入らない。
        "rule" => nullable({
          "type" => "object",
          "additionalProperties" => false,
          "required" => %w[when do],
          "properties" => {
            "when" => {
              "type" => "object",
              "additionalProperties" => false,
              "required" => %w[family behavior hour_from hour_to psyche_state psyche_above
                               seen_at_least near_miss silence_over_minutes],
              "properties" => {
                "family" => nullable({ "type" => "string" }),
                "behavior" => nullable({ "type" => "string", "enum" => BEHAVIORS }),
                "hour_from" => nullable({ "type" => "integer" }),
                "hour_to" => nullable({ "type" => "integer" }),
                "psyche_state" => nullable({ "type" => "string", "enum" => Psyche::STATES }),
                "psyche_above" => nullable({ "type" => "number" }),
                "seen_at_least" => nullable({ "type" => "integer" }),
                "near_miss" => nullable({ "type" => "boolean" }),
                "silence_over_minutes" => nullable({ "type" => "integer" })
              }
            },
            "do" => {
              "type" => "object",
              "additionalProperties" => false,
              "required" => %w[hesitate_ms silence status redirect_to shorten_to],
              "properties" => {
                "hesitate_ms" => nullable({ "type" => "integer" }),
                "silence" => nullable({ "type" => "boolean" }),
                "status" => nullable({ "type" => "integer", "enum" => ReflexConditions::STATUSES }),
                "redirect_to" => nullable({ "type" => "string" }),
                "shorten_to" => nullable({ "type" => "integer" })
              }
            }
          }
        }),
        "surface" => nullable({ "type" => "string", "enum" => MachineSurfaces::ALLOWED }),
        "family_name" => nullable({ "type" => "string" }),
        "match_shape" => nullable({ "type" => "string", "enum" => LearnedFamilies::SHAPES }),
        "match_value" => nullable({ "type" => "string" }),

        # 器官の構成。markup は書けない。形と源と気分と動きを選ぶだけ。
        "form" => nullable({ "type" => "string", "enum" => TrustedRenderer::FORMS }),
        "source" => nullable({ "type" => "string", "enum" => TrustedRenderer::SOURCES }),
        "mood" => nullable({ "type" => "string", "enum" => TrustedRenderer::MOODS }),
        "motion" => nullable({ "type" => "string", "enum" => TrustedRenderer::MOTIONS }),
        "faces" => nullable({
          "type" => "array",
          "items" => {
            "type" => "object",
            "additionalProperties" => false,
            "required" => %w[audience lines],
            "properties" => {
              "audience" => { "type" => "string", "enum" => TrustedRenderer::AUDIENCES },
              "lines" => { "type" => "array", "items" => { "type" => "string" } }
            }
          }
        })
      }
    }
  end

  # strict schema では optional を作れないので null 許容で表現する。
  def nullable(schema)
    t = schema["type"]
    schema.merge("type" => [t, "null"])
  end

  # null を落として、validate が読める形に均す。
  def compact(intent)
    return {} unless intent.is_a?(Hash)

    intent.each_with_object({}) do |(k, v), acc|
      next if v.nil?

      acc[k] = v.is_a?(Hash) ? compact(v) : v
    end
  end
end
