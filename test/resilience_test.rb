# frozen_string_literal: true

require_relative "test_helper"

# 本番で実際に起きたことから書いたテスト。
#
# 1. 拒否された intent（正規化を通っていない）が費用計算と説明を落とし、
#    注意力を払った夢が Journal に何も残さずに消えた。
# 2. 日本語で喋る生き物が、日本語で器官を名付けられなかった。
#    会話で受け取った答え /元気？ を器官にしようとして、自分の検証に弾かれた。
class ResilienceTest < Minitest::Test
  include Rack::Test::Methods
  include CreatureTest

  def app = App

  def setup
    clean_slate!
    TraceRegistry.reset!
    Conversation.reset!
    ReflexConditions.reset!
    MachineSurfaces.reset!
    LearnedFamilies.reset!
  end

  # ---- 払った夢を落とさない ----------------------------------------------

  # 正規化前の intent は field が欠けている。それで落ちてはいけない。
  def test_an_unnormalised_intent_never_breaks_the_bookkeeping
    MutationIntent::TYPES.each do |type|
      [{ "type" => type }, { "type" => type, "path" => "/x" }, { "type" => type, "rule" => {} }].each do |raw|
        assert_kind_of Numeric, MutationIntent.complexity_cost(raw), type
        assert_kind_of String, MutationIntent.describe(raw), type
      end
    end
    assert_equal 0.0, MutationIntent.complexity_cost(nil)
    assert_equal "(no intent)", MutationIntent.describe(nil)
  end

  # 注意力を払ったのに記録が残らない、が一番まずい。
  def test_a_refused_dream_still_costs_and_still_leaves_a_record
    intent = { "type" => "add_route", "path" => "/status", "title" => "奪う",
               "lines" => ["ここは私のものだ。"], "content_type" => "text/plain" }
    EvolutionAgent.provider = stub_returning(intent)

    AttentionScheduler.dream_now!

    entry = EvolutionJournal.entries.last
    refute_nil entry, "払った夢が Journal に残っていない"
    assert_equal "rejected", entry["status"]
    assert_equal "add_route /status", entry["intent_description"]
    assert_operator entry.dig("cost", "attention_usd"), :>, 0
    assert_equal 0, Body.generation
  ensure
    EvolutionAgent.provider = nil
  end

  # 記録の側が壊れても、払ったことだけは残す。
  def test_even_a_broken_record_leaves_the_price_behind
    EvolutionAgent.provider = stub_returning({ "type" => "no_change" })
    original = EvolutionJournal.method(:append)
    EvolutionJournal.define_singleton_method(:append) { |**| raise IOError, "volume gone" }

    assert_nil AttentionScheduler.dream_now!

    assert_operator BudgetGuard.snapshot[:spent_usd], :>, 0
    assert_equal 1, Observer.snapshot[:exceptions].length
  ensure
    EvolutionJournal.define_singleton_method(:append, original) if original
    EvolutionAgent.provider = nil
  end

  # ---- 日本語で名付けられる ----------------------------------------------

  def test_it_can_name_an_organ_in_its_own_language
    %w[/庭 /元気？ /まだない場所 /garden /a-b_c/d].each do |path|
      assert DynamicRoutes.valid_path?(path), path
    end
    %w[/x.php /x%20y /x?y /x\#y /trace/1 /status /a..b /].each do |path|
      refute DynamicRoutes.valid_path?(path), path
    end
  end

  # 本番で拒否された、まさにその intent。
  def test_the_answer_it_was_given_can_become_an_organ
    r = apply_intent("type" => "add_route", "path" => "/元気？", "title" => "元気？",
                     "lines" => ["ここではまだ、元気の形を知らない。"], "content_type" => "text/plain")

    assert_equal "applied", r.status, r.reason
    assert_equal 1, Body.generation
  end

  # 名付けられるだけでなく、そこへ辿り着けること。
  def test_a_japanese_organ_can_actually_be_reached
    apply_intent("type" => "add_organ", "path" => "/庭", "title" => "庭",
                 "form" => "shell", "source" => "recurring", "mood" => "curious",
                 "motion" => "drift", "lines" => ["ここにある。"])

    # 実際の client は必ず percent encode して送ってくる。
    # （rack-test は生 UTF-8 の URI を組み立てられないので、ここでは試さない）
    get "/%E5%BA%AD"

    assert_equal 200, last_response.status
    assert_includes last_response.body, "ここにある。"
    assert_includes last_response.body, "<svg"
  end

  def test_the_form_can_send_you_to_a_japanese_organ
    apply_intent("type" => "add_organ", "path" => "/庭", "title" => "庭",
                 "form" => "pulse", "source" => "psyche", "mood" => "quiet",
                 "motion" => "still", "lines" => ["ここにある。"])

    get "/go", "to" => "/庭"
    follow_redirect!

    assert_equal 200, last_response.status
    assert_includes last_response.body, "ここにある。"
  end

  # decode は一度だけ。二重に戻すと /%252e%252e が /.. になる。
  def test_it_decodes_the_name_only_once
    get "/%252e%252e/etc"

    assert_includes [404, 410], last_response.status
    assert_equal "/%2e%2e/etc", Observer.recent_absences.first[:path]
  end

  def stub_returning(intent)
    payload = {
      "observation_summary" => "何かが来た。", "interpretation" => "そう思った。",
      "dominant_desire" => "curiosity",
      "candidates" => [{ "intent" => intent, "expected_gain" => 0.5 }],
      "choice_index" => 0, "sacrifice" => "", "fitness_hypothesis" => ""
    }
    Class.new do
      define_method(:available?) { true }
      define_method(:respond) do |**|
        Providers::CloudflareAIGateway::Result.new(
          text: JSON.generate(payload), usage: { "input_tokens" => 900, "output_tokens" => 120 },
          status: 200, model: "stub"
        )
      end
    end.new
  end
end
