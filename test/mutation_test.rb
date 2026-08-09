# frozen_string_literal: true

require_relative "test_helper"

class MutationTest < Minitest::Test
  include CreatureTest

  def setup
    clean_slate!
  end

  # ---- 同じ PID のまま変わる --------------------------------------------

  def test_rewrite_absence_voice_changes_the_response_in_the_same_process
    event = event_for("/garden")
    before = Creature.current.respond_to_absence(event)
    pid_before = Process.pid
    body_before = Body.id

    result = apply_intent(
      "type" => "rewrite_absence_voice",
      "templates" => [{ "family" => "*", "lines" => ["there is no {path} in me.", "not yet. generation {generation}."] }],
      "max_length" => 200
    )

    assert_equal "applied", result.status, result.reason
    after = Creature.current.respond_to_absence(event)

    refute_equal before, after
    assert_includes after, "there is no /garden in me."
    assert_equal pid_before, Process.pid
    assert_equal body_before, Body.id
    assert result.pid_stable
    assert_equal 1, Body.generation
  end

  def test_add_route_becomes_an_organ
    result = apply_intent(
      "type" => "add_route", "path" => "/garden", "title" => "a garden",
      "lines" => ["you asked for this place {visitors} times.", "so I grew it."],
      "content_type" => "text/plain"
    )

    assert_equal "applied", result.status, result.reason
    assert DynamicRoutes.lookup("/garden")
    assert_equal 1, DynamicRoutes.count
  end

  def test_retire_route_returns_410_afterwards
    apply_intent("type" => "add_route", "path" => "/garden", "title" => "g",
                 "lines" => ["here"], "content_type" => "text/plain")
    result = apply_intent("type" => "retire_route", "path" => "/garden", "gone" => true)

    assert_equal "applied", result.status, result.reason
    assert_nil DynamicRoutes.lookup("/garden")
    assert DynamicRoutes.previously_existed?(RequestAirlock.path_key("/garden"))
  end

  def test_wrap_method_composes_on_top_of_previous_body
    event = event_for("/garden")
    result = apply_intent(
      "type" => "wrap_method", "method" => "respond_to_absence",
      "transforms" => [{ "op" => "quiet" }, { "op" => "append_line", "text" => "that is all I will say." }]
    )

    assert_equal "applied", result.status, result.reason
    text = Creature.current.respond_to_absence(event)
    assert_equal 2, text.lines.length
    assert_includes text, "that is all I will say."
  end

  def test_adjust_desire_weights_is_clamped
    ok, normalized = MutationIntent.validate({ "type" => "adjust_desire_weights",
                                               "deltas" => { "curiosity" => 5.0 } })
    assert ok
    assert_equal Psyche::ADJUST_CAP, normalized["deltas"]["curiosity"]

    # 検証を抜けても、適用側でもう一度 clamp する。
    before = Psyche["curiosity"]
    Psyche.adjust!("curiosity" => 5.0)
    assert_operator Psyche["curiosity"] - before, :<=, Psyche::ADJUST_CAP + 1e-9

    result = apply_intent("type" => "adjust_desire_weights", "deltas" => { "curiosity" => 0.05 })
    assert_equal "applied", result.status, result.reason
  end

  # ---- 拒否される変化 ----------------------------------------------------

  def test_reserved_paths_cannot_be_taken_over
    %w[/ /status /mutations /robots.txt].each do |path|
      result = TrustedMutator.apply({ "type" => "add_route", "path" => path, "title" => "x",
                                     "lines" => ["x"], "content_type" => "text/plain" })
      assert_equal "rejected", result.status, "#{path} should be reserved"
    end
    assert_equal 0, Body.generation
  end

  def test_unknown_operations_are_rejected
    result = TrustedMutator.apply({ "type" => "eval_ruby", "code" => "system('rm -rf /')" })
    assert_equal "rejected", result.status
    assert_equal 0, Body.generation
  end

  def test_unknown_transform_ops_are_rejected
    result = TrustedMutator.apply({
      "type" => "wrap_method", "method" => "respond_to_absence",
      "transforms" => [{ "op" => "exec", "text" => "whatever" }]
    })
    assert_equal "rejected", result.status
  end

  def test_methods_outside_the_allowlist_cannot_be_wrapped
    result = TrustedMutator.apply({ "type" => "wrap_method", "method" => "instance_variable_set",
                                   "transforms" => [{ "op" => "downcase" }] })
    assert_equal "rejected", result.status
  end

  def test_markup_and_control_characters_are_rejected
    result = TrustedMutator.apply({
      "type" => "rewrite_absence_voice",
      "templates" => [{ "family" => "*", "lines" => ["<script>alert(1)</script>"] }],
      "max_length" => 200
    })
    assert_equal "rejected", result.status
  end

  def test_route_count_has_a_ceiling
    Config.max_dynamic_routes.times do |i|
      r = apply_intent("type" => "add_route", "path" => "/room#{i}", "title" => "r",
                       "lines" => ["a room"], "content_type" => "text/plain")
      assert_equal "applied", r.status, r.reason
    end
    over = TrustedMutator.apply({ "type" => "add_route", "path" => "/one-more", "title" => "r",
                                 "lines" => ["a room"], "content_type" => "text/plain" })
    assert_equal "rejected", over.status
  end

  def test_rejection_does_not_change_the_object_space
    before = Creature.current.respond_to_absence(event_for("/garden"))
    TrustedMutator.apply({ "type" => "rewrite_absence_voice", "templates" => [], "max_length" => 10 })

    assert_equal before, Creature.current.respond_to_absence(event_for("/garden"))
    assert_equal 0, Body.generation
  end

  # ---- 壊れたら戻る ------------------------------------------------------

  def test_smoke_failure_rolls_back_and_leaves_a_scar
    event = event_for("/garden")
    before = Creature.current.respond_to_absence(event)

    # smoke test を必ず落とす身体を一時的に作る。
    exploding = Class.new do
      def self.call(_env) = raise("this body cannot stand")
    end
    original = TrustedMutator.smoke_app
    TrustedMutator.smoke_app = exploding

    result = apply_intent(
      "type" => "rewrite_absence_voice",
      "templates" => [{ "family" => "*", "lines" => ["broken voice"] }],
      "max_length" => 200
    )
    TrustedMutator.smoke_app = original

    assert_equal "rolled_back", result.status
    assert_equal before, Creature.current.respond_to_absence(event)
    assert_equal 0, Body.generation
    refute_empty EvolutionJournal.scars
  end

  def test_no_change_is_a_legitimate_choice
    result = apply_intent("type" => "no_change")
    assert_equal "no_change", result.status
    assert_equal 0, Body.generation
    assert_equal 1, EvolutionJournal.entries.length
  end

  # ---- 展示用 source -----------------------------------------------------

  def test_exhibit_source_is_valid_ruby_but_not_the_replay_source
    apply_intent("type" => "add_route", "path" => "/garden", "title" => "g",
                 "lines" => ["here"], "content_type" => "text/plain")
    exhibit = EvolutionJournal.exhibit(1)

    assert_includes exhibit, "display only"
    assert TrustedMutator.syntax_ok?(exhibit)
    # 正本は manifest 側。
    manifest = EvolutionJournal.manifests.first
    assert_equal "add_route", manifest.dig("intent", "type")
  end
end
