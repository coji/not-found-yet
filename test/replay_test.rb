# frozen_string_literal: true

require_relative "test_helper"

class ReplayTest < Minitest::Test
  include CreatureTest

  def setup
    clean_slate!
  end

  def test_cold_start_rebuilds_acquired_features_from_manifests
    apply_intent("type" => "add_route", "path" => "/garden", "title" => "a garden",
                 "lines" => ["I grew this."], "content_type" => "text/plain")
    apply_intent("type" => "rewrite_absence_voice",
                 "templates" => [{ "family" => "*", "lines" => ["no {path} here."] }],
                 "max_length" => 200)

    assert_equal 2, Body.generation

    report = simulate_cold_start!

    refute report.fossilized, report.reason
    assert_equal 2, report.applied
    assert_equal 2, Body.generation
    assert DynamicRoutes.lookup("/garden")
    assert_includes Creature.current.respond_to_absence(event_for("/nope")), "no /nope here."
  end

  def test_body_id_changes_on_cold_start_but_alterations_are_inherited
    apply_intent("type" => "add_route", "path" => "/garden", "title" => "g",
                 "lines" => ["here"], "content_type" => "text/plain")

    # 前の身体の名前を state から拾い、それが今の名前と違えば「受け継いだ」と語る。
    Store.state_update("body") { |_| { "id" => "0000-a-previous-body" } }
    simulate_cold_start!

    assert_equal "0000-a-previous-body", Body.previous_id
    assert Body.inherited_alterations?
    assert_includes Creature.current.self_description, "受け継いだ"
    assert DynamicRoutes.lookup("/garden")

    # 今の身体の名前は、次の cold start のために置かれている。
    assert_equal Body.id, Store.state_read("body", {})["id"]
  end

  def test_writable_ruby_is_never_the_replay_source
    apply_intent("type" => "add_route", "path" => "/garden", "title" => "g",
                 "lines" => ["here"], "content_type" => "text/plain")

    exhibit_path = Store.sequence_path(Config.exhibit_dir, 1, ".rb")
    File.write(exhibit_path, "DynamicRoutes.add(path: '/backdoor', title: 'x', lines: ['x'], content_type: 'text/plain', generation: 1)\nsystem('echo pwned')\n")

    report = simulate_cold_start!

    refute report.fossilized, report.reason
    assert DynamicRoutes.lookup("/garden")
    assert_nil DynamicRoutes.lookup("/backdoor")
  end

  def test_tampered_manifest_fossilizes_instead_of_applying
    apply_intent("type" => "add_route", "path" => "/garden", "title" => "g",
                 "lines" => ["here"], "content_type" => "text/plain")
    apply_intent("type" => "add_route", "path" => "/well", "title" => "w",
                 "lines" => ["deep"], "content_type" => "text/plain")

    path = Store.sequence_path(Config.mutation_dir, 1, ".json")
    manifest = Store.read_json(path)
    manifest["intent"]["path"] = "/tampered"
    Store.write_json!(path, manifest)

    report = simulate_cold_start!

    assert report.fossilized
    assert_includes report.reason, "hash chain broken"
    assert Body.fossil?
    # 壊れた地点以降は適用しない。
    assert_nil DynamicRoutes.lookup("/well")
  ensure
    Body.instance_variable_set(:@mode, "alive")
  end

  def test_missing_generation_fossilizes
    apply_intent("type" => "add_route", "path" => "/garden", "title" => "g",
                 "lines" => ["here"], "content_type" => "text/plain")
    apply_intent("type" => "add_route", "path" => "/well", "title" => "w",
                 "lines" => ["deep"], "content_type" => "text/plain")

    File.delete(Store.sequence_path(Config.mutation_dir, 1, ".json"))
    report = simulate_cold_start!

    assert report.fossilized
    assert_includes report.reason, "generation gap"
  ensure
    Body.instance_variable_set(:@mode, "alive")
  end

  def test_journal_survives_replay
    apply_intent("type" => "no_change")
    apply_intent("type" => "add_route", "path" => "/garden", "title" => "g",
                 "lines" => ["here"], "content_type" => "text/plain")

    simulate_cold_start!
    EvolutionJournal.load!

    assert_equal 2, EvolutionJournal.entries.length
    assert_equal 1, EvolutionJournal.manifests.length
  end
end
