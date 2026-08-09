# frozen_string_literal: true

# 許可する mutation の言語そのもの。
# 任意定数参照、File / IO / ENV、system、require、socket、thread 生成は
# この言語では表現できない。書けないものは起こらない。
module MutationIntent
  TYPES = %w[
    rewrite_absence_voice
    add_route
    retire_route
    wrap_method
    adjust_desire_weights
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

  def clamp_int(value, min, max, default)
    n = Integer(value) rescue default
    [[n, min].max, max].min
  end

  # ---- 複雑性コスト ------------------------------------------------------
  # 獲得は必ず何かを重くする。上限に当たったら retire を要求できるように。
  def complexity_cost(intent)
    case intent["type"]
    when "add_route" then 0.10 + 0.01 * intent["lines"].length
    when "rewrite_absence_voice" then 0.02 * intent["templates"].length
    when "wrap_method" then 0.03 * intent["transforms"].length
    when "retire_route" then -0.08
    when "adjust_desire_weights" then 0.01
    else 0.0
    end.round(3)
  end

  def describe(intent)
    case intent["type"]
    when "add_route" then "add_route #{intent['path']}"
    when "retire_route" then "retire_route #{intent['path']}"
    when "wrap_method" then "wrap_method #{intent['method']} (#{intent['transforms'].map { |t| t['op'] }.join(', ')})"
    when "rewrite_absence_voice" then "rewrite_absence_voice (#{intent['templates'].length} templates)"
    when "adjust_desire_weights" then "adjust_desire_weights #{intent['deltas'].keys.join(', ')}"
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
      "required" => %w[type path title lines content_type templates max_length method transforms deltas gone],
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
        "gone" => nullable({ "type" => "boolean" })
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
