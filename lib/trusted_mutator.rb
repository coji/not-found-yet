# frozen_string_literal: true

require "rack"
require "rack/mock"

# LLM 出力を eval しない。Intent を Ruby closure へコンパイルし、
# 現在のプロセスへ define_method / registry 更新として適用する。
# 展示用の Ruby source は生成するが、それは実行正本ではない。
module TrustedMutator
  COMPILER_VERSION = "1"
  SMOKE_ENV_KEY = "creature.smoke"

  @mutex = Mutex.new
  @smoke_app = nil

  # 元 method と registry state を世代ごとに退避する。
  module RollbackRegistry
    @undo = Hash.new { |h, k| h[k] = [] }

    module_function

    def push(generation, &undo) = @undo[generation] << undo
    def undo!(generation)
      (@undo.delete(generation) || []).reverse_each do |u|
        begin
          u.call
        rescue StandardError
          nil
        end
      end
    end

    def forget(generation) = @undo.delete(generation)
    def reset! = @undo.clear
  end

  module_function

  def smoke_app=(app)
    @smoke_app = app
  end

  def smoke_app = @smoke_app

  Result = Struct.new(:status, :reason, :intent, :exhibit, :generation, :pid_stable, :smoke, keyword_init: true)

  # source: :dream（新しい判断）| :replay（cold start の再構築）
  def apply(raw_intent, source: :dream, generation: nil, skip_smoke: false)
    ok, normalized = MutationIntent.validate(raw_intent)
    unless ok
      return Result.new(status: "rejected", reason: normalized, intent: raw_intent,
                        exhibit: nil, generation: EvolutionJournal.current_generation,
                        pid_stable: true, smoke: nil)
    end

    if normalized["type"] == "no_change"
      return Result.new(status: "no_change", reason: nil, intent: normalized,
                        exhibit: exhibit_source(normalized), generation: EvolutionJournal.current_generation,
                        pid_stable: true, smoke: nil)
    end

    exhibit = exhibit_source(normalized)
    unless syntax_ok?(exhibit)
      return Result.new(status: "rejected", reason: "exhibit source failed syntax check",
                        intent: normalized, exhibit: exhibit,
                        generation: EvolutionJournal.current_generation, pid_stable: true, smoke: nil)
    end

    target_generation = generation || (EvolutionJournal.current_generation + 1)
    pid_before = Process.pid
    body_before = Body.id

    @mutex.synchronize do
      Store.with_file_lock("evolution.lock") do
        begin
          perform!(normalized, target_generation)
        rescue StandardError => e
          RollbackRegistry.undo!(target_generation)
          Observer.record_exception(e, "TrustedMutator#perform")
          return Result.new(status: "rolled_back", reason: "apply error: #{e.class}",
                            intent: normalized, exhibit: exhibit, generation: EvolutionJournal.current_generation,
                            pid_stable: pid_before == Process.pid, smoke: nil)
        end

        smoke = skip_smoke ? { "skipped" => true } : smoke_test(normalized)
        if !skip_smoke && smoke["passed"] != true
          RollbackRegistry.undo!(target_generation)
          return Result.new(status: "rolled_back", reason: smoke["reason"],
                            intent: normalized, exhibit: exhibit, generation: EvolutionJournal.current_generation,
                            pid_stable: pid_before == Process.pid, smoke: smoke)
        end

        RollbackRegistry.forget(target_generation) if source == :replay
        Result.new(status: "applied", reason: nil, intent: normalized, exhibit: exhibit,
                   generation: target_generation,
                   pid_stable: pid_before == Process.pid && body_before == Body.id,
                   smoke: smoke)
      end
    end
  end

  # 手動 rollback（fitness 評価や運用から呼ぶ）。
  def rollback!(generation)
    @mutex.synchronize { RollbackRegistry.undo!(generation) }
  end

  # ---- 実際に object space を触る唯一の場所 ------------------------------
  def perform!(intent, generation)
    case intent["type"]
    when "rewrite_absence_voice" then apply_voice(intent, generation)
    when "wrap_method" then apply_wrap(intent, generation)
    when "add_route" then apply_add_route(intent, generation)
    when "retire_route" then apply_retire_route(intent, generation)
    when "adjust_desire_weights" then apply_desire(intent, generation)
    else raise ArgumentError, "unreachable intent type"
    end
  end

  def apply_voice(intent, generation)
    previous = Creature.instance_method(:respond_to_absence)
    had_templates = Creature.method_defined?(:voice_templates)
    previous_templates = had_templates ? Creature.instance_method(:voice_templates) : nil
    RollbackRegistry.push(generation) do
      Creature.define_method(:respond_to_absence, previous)
      if previous_templates
        Creature.define_method(:voice_templates, previous_templates)
      elsif Creature.method_defined?(:voice_templates)
        Creature.remove_method(:voice_templates)
      end
      Creature.patched_methods.delete("respond_to_absence") unless previous_templates
    end

    templates = intent["templates"]
    max_length = intent["max_length"]

    Creature.define_method(:respond_to_absence) do |event|
      if DynamicRoutes.previously_existed?(event["path_key"])
        lost_voice(event)
      else
        template = templates.find { |t| t["family"] == event["family"] } ||
                   templates.find { |t| t["family"] == "*" }
        if template
          ctx = VoiceTemplate.context(event)
          text = template["lines"].map { |l| VoiceTemplate.fill(l, ctx) }.join("\n")
          text.length > max_length ? "#{text[0, max_length].rstrip}…" : text
        else
          # 語れない family は、以前の身体に任せる。
          previous.bind_call(self, event)
        end
      end
    end
    Creature.define_method(:voice_templates) { templates }
    Creature.patched_methods << "respond_to_absence" unless Creature.patched_methods.include?("respond_to_absence")
  end

  def apply_wrap(intent, generation)
    name = intent["method"].to_sym
    transforms = intent["transforms"]
    previous = Creature.instance_method(name)
    was_patched = Creature.patched_methods.include?(name.to_s)

    RollbackRegistry.push(generation) do
      Creature.define_method(name, previous)
      Creature.patched_methods.delete(name.to_s) unless was_patched
    end

    Creature.define_method(name) do |*args|
      base = previous.bind_call(self, *args)
      event = args.first.is_a?(Hash) ? args.first : nil
      VoiceTransforms.apply(base, event, transforms)
    end
    Creature.patched_methods << name.to_s unless was_patched
  end

  def apply_add_route(intent, generation)
    snapshot = DynamicRoutes.snapshot
    RollbackRegistry.push(generation) { DynamicRoutes.restore(snapshot) }
    DynamicRoutes.add(
      path: intent["path"], title: intent["title"], lines: intent["lines"],
      content_type: intent["content_type"], generation: generation
    )
  end

  def apply_retire_route(intent, generation)
    snapshot = DynamicRoutes.snapshot
    RollbackRegistry.push(generation) { DynamicRoutes.restore(snapshot) }
    DynamicRoutes.retire(intent["path"], gone: intent["gone"], generation: generation)
  end

  def apply_desire(intent, generation)
    applied = Psyche.adjust!(intent["deltas"])
    RollbackRegistry.push(generation) { Psyche.adjust!(applied.transform_values { |v| -v }) }
    applied
  end

  # ---- 検証 --------------------------------------------------------------

  # 展示用 source を構文チェックする。通らないものは applied にしない。
  def syntax_ok?(source)
    RubyVM::InstructionSequence.compile(source)
    true
  rescue SyntaxError, StandardError
    false
  end

  # 生きているかどうかだけを見る。適応したかどうかは fitness の仕事。
  def smoke_test(intent)
    app = smoke_app
    return { "passed" => true, "skipped" => "no app" } if app.nil?

    checks = [["/", 200], ["/status", 200], ["/mutations", 200], ["/__smoke__#{rand(1 << 20)}", [404, 410]]]
    checks << [intent["path"], 200] if intent["type"] == "add_route"

    mock = Rack::MockRequest.new(app)
    checks.each do |path, expected|
      # creature.smoke は HTTP_ 接頭辞を持たないので、外から header で偽装できない。
      # 自己テストを「訪問」として数えないための印。
      res = mock.get(path, SMOKE_ENV_KEY => true,
                           "HTTP_USER_AGENT" => "creature-smoke/1", "REMOTE_ADDR" => "127.0.0.1")
      allowed = Array(expected)
      unless allowed.include?(res.status)
        return { "passed" => false, "reason" => "#{path} returned #{res.status}, expected #{allowed.join('/')}" }
      end
      if res.body.to_s.length > 20_000
        return { "passed" => false, "reason" => "#{path} body too large" }
      end
    end
    { "passed" => true, "checks" => checks.length }
  rescue StandardError => e
    { "passed" => false, "reason" => "smoke raised #{e.class}" }
  end

  # ---- 展示用 Ruby source ------------------------------------------------
  # 人が読むためだけのもの。replay には決して使わない。
  def exhibit_source(intent)
    case intent["type"]
    when "rewrite_absence_voice"
      <<~RUBY
        # generation #{EvolutionJournal.current_generation + 1} · display only, never replayed
        previous = Creature.instance_method(:respond_to_absence)
        templates = #{pp_literal(intent['templates'])}
        max_length = #{intent['max_length']}

        Creature.define_method(:respond_to_absence) do |event|
          template = templates.find { |t| t["family"] == event["family"] } ||
                     templates.find { |t| t["family"] == "*" }
          next previous.bind_call(self, event) unless template

          ctx = VoiceTemplate.context(event)
          text = template["lines"].map { |l| VoiceTemplate.fill(l, ctx) }.join("\\n")
          text.length > max_length ? "\#{text[0, max_length].rstrip}…" : text
        end
      RUBY
    when "wrap_method"
      <<~RUBY
        previous = Creature.instance_method(:#{intent['method']})
        transforms = #{pp_literal(intent['transforms'])}

        Creature.define_method(:#{intent['method']}) do |*args|
          base = previous.bind_call(self, *args)
          VoiceTransforms.apply(base, args.first, transforms)
        end
      RUBY
    when "add_route"
      <<~RUBY
        DynamicRoutes.add(
          path: #{intent['path'].inspect},
          title: #{intent['title'].inspect},
          lines: #{pp_literal(intent['lines'])},
          content_type: #{intent['content_type'].inspect},
          generation: #{EvolutionJournal.current_generation + 1}
        )
      RUBY
    when "retire_route"
      "DynamicRoutes.retire(#{intent['path'].inspect}, gone: #{intent['gone']})\n"
    when "adjust_desire_weights"
      "Psyche.adjust!(#{pp_literal(intent['deltas'])})\n"
    else
      "# no_change: the body remembered without becoming anything else\n"
    end
  end

  # JSON 由来の値だけを Ruby literal へ。式は生成しない。
  def pp_literal(value)
    case value
    when Hash then "{ #{value.map { |k, v| "#{k.inspect} => #{pp_literal(v)}" }.join(', ')} }"
    when Array then "[#{value.map { |v| pp_literal(v) }.join(', ')}]"
    when String, Numeric, TrueClass, FalseClass, NilClass then value.inspect
    else value.to_s.inspect
    end
  end
end
