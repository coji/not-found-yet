# frozen_string_literal: true

require "tmpdir"
require "fileutils"

ENV["DATA_DIR"] = Dir.mktmpdir("creature-test-")
ENV["GAZE_ENABLED"] = "false"
ENV["DREAM_ENABLED"] = "false"
ENV["EVOLUTION_MODE"] = "alive"
ENV["TZ"] = "Asia/Tokyo"

require "minitest/autorun"
require "rack/test"
require_relative "../app"

App.wake!

module CreatureTest
  CREATURE_SOURCE = File.expand_path("../lib/creature.rb", __dir__)

  # 「同じ生存期間の中の変化」と「cold start」を区別してテストする。
  # ここでは Creature クラスを読み直すことで、新しいプロセスを模す。
  def simulate_cold_start!
    TrustedMutator::RollbackRegistry.reset!
    Creature.patched_methods.clear
    Creature.remove_method(:voice_templates) if Creature.method_defined?(:voice_templates)
    reload_creature_source!
    Creature.current = nil
    # 本番の cold start は state.json から読み直す。ここも同じにしないと、
    # 前のテストの疲労や恐れがメモリに残って別のテストを揺らす。
    Psyche.load!
    Observer.reset!
    Fitness.reset!
    AttentionScheduler.reset!
    # 新しいプロセスでは、メモリ上の会話も痕の索引も空から始まる。
    Conversation.reset!
    TraceRegistry.reset!
    Body.begin_life!
    Replay.run!
  end

  # 定数の再定義警告は、ここでは「新しいプロセス」の演出にすぎない。
  def reload_creature_source!
    verbose = $VERBOSE
    $VERBOSE = nil
    load CREATURE_SOURCE
  ensure
    $VERBOSE = verbose
  end

  def clean_slate!
    FileUtils.rm_rf(Dir.glob(File.join(Config.data_dir, "*")))
    Config.ensure_dirs!
    EvolutionJournal.reset!
    simulate_cold_start!
  end

  def event_for(path, family: nil, behavior: "first_touch")
    {
      "id" => "test", "at" => Clock.iso, "kind" => "absence",
      "path_key" => RequestAirlock.path_key(path),
      "safe_display_path" => path,
      "family" => family || RequestAirlock.classify(path),
      "method" => "GET", "visitor_bucket" => "daily-hmac:test",
      "claimed_identity" => "none", "behavior" => behavior,
      "generation" => Body.generation, "body_id" => Body.id, "raw_discarded" => true
    }
  end

  # 判断そのものは LLM 抜きで固定 fixture として与える。
  def decision_for(intent, desire: "curiosity")
    {
      "observation_summary" => "fixture",
      "interpretation" => "fixture interpretation",
      "dominant_desire" => desire,
      "candidates" => [{ "intent" => intent, "expected_gain" => 0.5 }],
      "choice_index" => 0,
      "intent" => intent,
      "sacrifice" => "none",
      "fitness_hypothesis" => "none",
      "prompt_version" => "test"
    }
  end

  def apply_intent(intent)
    result = TrustedMutator.apply(intent, source: :dream)
    EvolutionJournal.append(
      decision: decision_for(intent), result: result,
      cost: { "complexity" => MutationIntent.complexity_cost(result.intent || intent), "attention_usd" => 0.0 }
    )
    result
  end
end
