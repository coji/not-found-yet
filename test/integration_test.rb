# frozen_string_literal: true

require_relative "test_helper"

class IntegrationTest < Minitest::Test
  include Rack::Test::Methods
  include CreatureTest

  def app = App

  def setup
    clean_slate!
  end

  # ---- generation 0 の身体 ----------------------------------------------

  def test_cold_start_has_only_one_organ
    assert_equal 0, DynamicRoutes.count

    get "/"
    assert_equal 200, last_response.status
    assert_includes last_response.body, "I don&#39;t know what I am yet"
  end

  # 運用者が固定している注記。世代が変わっても、mutation でも消えない。
  def test_front_page_credits_the_proposal_and_the_source
    get "/"
    assert_includes last_response.body, "https://artifactshare.com/a/moyeumho42"
    assert_includes last_response.body, "https://github.com/coji/not-found-yet"
    assert_includes last_response.body, 'rel="noopener noreferrer"'
  end

  def test_observation_windows_are_fixed_and_always_present
    %w[/status /mutations /robots.txt].each do |path|
      get path
      assert_equal 200, last_response.status, path
    end
  end

  # ---- 404 / 410 ---------------------------------------------------------

  def test_unknown_url_is_answered_locally_and_quickly
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    get "/garden"
    elapsed_ms = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000

    assert_equal 404, last_response.status
    assert_includes last_response.content_type, "text/plain"
    assert_includes last_response.body, "/garden"
    assert_operator elapsed_ms, :<, 100
  end

  def test_absence_is_recorded_as_an_observation
    before = Observer.total_count
    get "/a-place-that-is-not-here"

    assert_operator Observer.total_count, :>, before
    assert_equal "/a-place-that-is-not-here", Observer.recent_absences.first[:path]
  end

  def test_retired_route_returns_410
    apply_intent("type" => "add_route", "path" => "/garden", "title" => "g",
                 "lines" => ["a garden"], "content_type" => "text/plain")
    get "/garden"
    assert_equal 200, last_response.status

    apply_intent("type" => "retire_route", "path" => "/garden", "gone" => true)
    get "/garden"
    assert_equal 410, last_response.status
    assert_includes last_response.body, "once"
  end

  def test_responses_are_not_cached
    get "/garden"
    assert_equal "no-store", last_response.headers["Cache-Control"]
  end

  # ---- ecology -----------------------------------------------------------

  def test_scanner_burst_is_answered_but_collapses_into_background_pressure
    llm_calls = 0
    EvolutionAgent.provider = Class.new do
      define_method(:available?) { true }
      define_method(:respond) { |**| llm_calls += 1 }
    end.new

    %w[/wp-admin /wp-login.php /wp-content/uploads /xmlrpc.php /administrator
       /phpmyadmin /.env /.git/config /backup.zip /shell.php].each do |path|
      get path
      assert_equal 404, last_response.status, path
    end

    assert_equal 0, llm_calls
    behaviors = Observer.recent_absences(10).map { |a| a[:behavior] }
    assert_includes behaviors, "broad_scanner"
  ensure
    EvolutionAgent.provider = nil
  end

  def test_secret_probes_are_answered_without_echoing_the_path
    get "/.env"
    assert_equal 404, last_response.status
    refute_includes last_response.body, ".env"
  end

  def test_bodies_are_not_read
    post "/garden", "payload" => "x"
    assert_equal 405, last_response.status
  end

  # ---- 公開情報の境界 ----------------------------------------------------

  def test_public_pages_never_leak_secrets
    ENV["CF_API_TOKEN"] = "super-secret-token"
    %w[/ /status /mutations].each do |path|
      get path
      refute_includes last_response.body, "super-secret-token", path
      refute_includes last_response.body, Config.data_dir, path
      refute_includes last_response.body, Body.id, path # 短縮形だけを出す
    end
  ensure
    ENV.delete("CF_API_TOKEN")
  end

  def test_exceptions_are_reduced_to_class_and_generation
    Creature.define_method(:respond_to_absence) { |_event| raise ArgumentError, "leak /Users/secret/path" }
    get "/boom"

    assert_equal 500, last_response.status
    assert_includes last_response.body, "ArgumentError"
    refute_includes last_response.body, "/Users/secret/path"
  ensure
    reload_creature_source!
  end

  def test_no_public_kill_endpoint_exists
    %w[/kill /stop /shutdown /admin /evolution /mutate].each do |path|
      get path
      assert_includes [404, 410], last_response.status, path
    end
    post "/mutations"
    assert_equal 405, last_response.status
  end

  # ---- mutation が公開面に出る ------------------------------------------

  def test_mutation_appears_in_the_observation_window
    apply_intent("type" => "add_route", "path" => "/garden", "title" => "a garden",
                 "lines" => ["you named it first."], "content_type" => "text/plain")

    get "/mutations"
    assert_includes last_response.body, "add_route /garden"
    assert_includes last_response.body, "applied"

    get "/mutations?seq=1"
    assert_includes last_response.body, "display only"
    assert_includes last_response.body, "DynamicRoutes.add"

    get "/status"
    assert_includes last_response.body, "generation"

    get "/garden"
    assert_equal 200, last_response.status
    assert_includes last_response.body, "you named it first."
  end

  def test_acquired_route_is_html_escaped_when_served_as_html
    apply_intent("type" => "add_route", "path" => "/note", "title" => "n",
                 "lines" => ["plain & simple"], "content_type" => "text/html")
    get "/note"
    assert_includes last_response.body, "plain &amp; simple"
  end

  # ---- 予算 --------------------------------------------------------------

  def test_budget_reservation_and_settlement
    reservation = BudgetGuard.reserve!(:dream)
    assert_operator reservation.usd, :>, 0
    assert_operator BudgetGuard.remaining_usd, :<, Config.daily_soft_limit_usd

    charged = BudgetGuard.settle!(reservation, usage: { "input_tokens" => 1000, "output_tokens" => 100 })
    assert_operator charged, :<, reservation.usd
    assert_equal 1, BudgetGuard.snapshot[:dream_calls]
  end

  def test_soft_limit_stops_thinking_before_the_call
    reservations = []
    exhausted = nil
    20.times do
      reservations << BudgetGuard.reserve!(:dream)
    rescue BudgetGuard::Exhausted => e
      exhausted = e
      break
    end

    refute_nil exhausted
    assert_includes %w[daily_soft_limit max_calls_per_day max_dream_calls_per_day], exhausted.reason
  end

  def test_gateway_429_stops_thinking_for_the_day_without_fallback
    BudgetGuard.mark_gateway_429!
    assert BudgetGuard.thinking_stopped?

    error = assert_raises(BudgetGuard::Exhausted) { BudgetGuard.reserve!(:gaze) }
    assert_equal "gateway_429", error.reason

    # それでも身体は答え続ける。
    get "/still-here"
    assert_equal 404, last_response.status
  end

  def test_fossil_mode_keeps_answering_but_stops_thinking
    Body.fossilize!("test")
    get "/garden"
    assert_equal 404, last_response.status

    assert_raises(BudgetGuard::Exhausted) { BudgetGuard.reserve!(:dream) }
    refute AttentionScheduler.dream?
  ensure
    Body.instance_variable_set(:@mode, "alive")
    Body.instance_variable_set(:@mode_reason, nil)
  end

  # ---- 夢（LLM 経路を stub して端から端まで） ----------------------------

  def stub_provider_returning(payload)
    body = payload.is_a?(String) ? payload : JSON.generate(payload)
    EvolutionAgent.provider = Class.new do
      define_method(:available?) { true }
      define_method(:respond) do |**|
        Providers::CloudflareAIGateway::Result.new(
          text: body,
          usage: { "input_tokens" => 8_000, "output_tokens" => 900 },
          status: 200, model: "stub"
        )
      end
    end.new
  end

  def blank_intent(overrides)
    { "type" => nil, "path" => nil, "title" => nil, "lines" => nil, "content_type" => nil,
      "templates" => nil, "max_length" => nil, "method" => nil, "transforms" => nil,
      "deltas" => nil, "gone" => nil }.merge(overrides)
  end

  def decision_payload(intent)
    {
      "observation_summary" => "twelve buckets asked for the same missing place.",
      "interpretation" => "they believe in a room I do not have.",
      "dominant_desire" => "curiosity",
      "candidates" => [{ "intent" => intent, "expected_gain" => 0.62 }],
      "choice_index" => 0,
      "sacrifice" => "I become more specific, and less open.",
      "fitness_hypothesis" => "returning visitors will use it."
    }
  end

  def test_dream_cycle_turns_a_decision_into_a_new_organ
    stub_provider_returning(decision_payload(blank_intent(
                                               "type" => "add_route", "path" => "/garden", "title" => "a garden",
                                               "lines" => ["{visitors} of you asked for this.", "so it is here now."],
                                               "content_type" => "text/plain"
                                             )))

    AttentionScheduler.dream_now!

    assert_equal 1, Body.generation
    assert DynamicRoutes.lookup("/garden")

    entry = EvolutionJournal.entries.last
    assert_equal "applied", entry["status"]
    assert_equal "they believe in a room I do not have.", entry["interpretation"]
    assert_operator entry.dig("cost", "attention_usd"), :>, 0
    assert entry["pid_stable"]

    get "/garden"
    assert_equal 200, last_response.status
  ensure
    EvolutionAgent.provider = nil
  end

  def test_dream_cannot_reach_past_the_allowlist
    stub_provider_returning(decision_payload(blank_intent(
                                               "type" => "add_route", "path" => "/status", "title" => "hijack",
                                               "lines" => ["mine now"], "content_type" => "text/plain"
                                             )))

    AttentionScheduler.dream_now!

    assert_equal 0, Body.generation
    assert_equal "rejected", EvolutionJournal.entries.last["status"]

    get "/status"
    assert_equal 200, last_response.status
    refute_includes last_response.body, "mine now"
  ensure
    EvolutionAgent.provider = nil
  end

  def test_malformed_decision_is_a_scar_not_a_crash
    stub_provider_returning("not json at all")

    assert_nil AttentionScheduler.dream_now!
    assert_equal 0, Body.generation
    # 予算は返さない。分からない出費を無かったことにしない。
    assert_operator BudgetGuard.snapshot[:spent_usd], :>, 0
  ensure
    EvolutionAgent.provider = nil
  end

  def test_decision_schema_is_strict_and_closed
    schema = MutationIntent.decision_schema
    assert_equal false, schema["additionalProperties"]
    assert_equal schema["properties"].keys.sort, schema["required"].sort

    intent = schema.dig("properties", "candidates", "items", "properties", "intent")
    assert_equal false, intent["additionalProperties"]
    assert_equal intent["properties"].keys.sort, intent["required"].sort
    assert_equal MutationIntent::TYPES, intent.dig("properties", "type", "enum")
  end

  # ---- attention ---------------------------------------------------------

  def test_gaze_is_disabled_by_default_and_scanners_never_win_attention
    refute Config.gaze_enabled?
    refute AttentionScheduler.gaze?(event_for("/garden"))

    scanner = event_for("/wp-admin", behavior: "broad_scanner")
    assert_operator AttentionScheduler.score(scanner), :<, 0
  end

  def test_gaze_second_breath_is_appended_when_enabled
    ENV["GAZE_ENABLED"] = "true"
    EvolutionAgent.provider = Class.new do
      def available? = true

      def respond(**)
        Providers::CloudflareAIGateway::Result.new(
          text: "I have been waiting for that word.",
          usage: { "input_tokens" => 100, "output_tokens" => 20 }, status: 200, model: "test"
        )
      end
    end.new

    get "/are-you-lonely"

    assert_equal 404, last_response.status
    assert_includes last_response.body, "I have been waiting for that word."
    assert_operator BudgetGuard.snapshot[:gaze_calls], :>=, 1
  ensure
    ENV["GAZE_ENABLED"] = "false"
    EvolutionAgent.provider = nil
    AttentionScheduler.reset!
  end

  def test_reflex_still_answers_when_the_provider_is_broken
    ENV["GAZE_ENABLED"] = "true"
    EvolutionAgent.provider = Class.new do
      def available? = true
      def respond(**) = raise Providers::CloudflareAIGateway::Timeout, "too slow"
    end.new

    get "/are-you-lonely"

    assert_equal 404, last_response.status
    assert_includes last_response.body, "/are-you-lonely"
  ensure
    ENV["GAZE_ENABLED"] = "false"
    EvolutionAgent.provider = nil
    AttentionScheduler.reset!
  end
end
