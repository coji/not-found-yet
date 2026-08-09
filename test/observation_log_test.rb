# frozen_string_literal: true

require_relative "test_helper"

class ObservationLogTest < Minitest::Test
  include Rack::Test::Methods
  include CreatureTest

  def app = App

  def setup
    clean_slate!
    ObservationLog.close!
  end

  def lines(day = Clock.jst_date_string)
    path = ObservationLog.path_for(day)
    return [] unless File.exist?(path)

    File.readlines(path).map { |l| JSON.parse(l) }
  end

  # 観測は ObservationEvent 自身の kind（absence / presence …）のまま流れる。
  def test_every_arrival_is_written_as_one_json_line
    get "/garden"
    get "/garden"
    get "/wp-admin"

    absences = lines.select { |l| l["kind"] == "absence" }
    assert_equal 3, absences.length
    assert_equal %w[/garden /garden /wp-admin], absences.map { |o| o["safe_display_path"] }
    assert absences.all? { |o| o["body_id"] == Body.id }
    assert absences.all? { |o| o["raw_discarded"] }
  end

  def test_the_stream_carries_both_arrivals_and_decisions
    get "/"
    get "/garden"
    ObservationLog.note("dream", "status" => "applied", "intent" => "add_route /garden")

    kinds = lines.map { |l| l["kind"] }
    assert_includes kinds, "presence"
    assert_includes kinds, "absence"
    assert_includes kinds, "dream"
  end

  def test_the_log_never_holds_what_the_airlock_discarded
    get "/.env", nil, "HTTP_COOKIE" => "session=abc", "REMOTE_ADDR" => "203.0.113.9",
                      "HTTP_AUTHORIZATION" => "Bearer xyz"
    get "/secret?token=zzz"

    raw = File.read(ObservationLog.path_for(Clock.jst_date_string))
    refute_includes raw, "203.0.113.9"
    refute_includes raw, "session=abc"
    refute_includes raw, "Bearer"
    refute_includes raw, "token=zzz"
    refute_includes raw, ".env"
  end

  def test_boot_and_replay_are_recorded
    ObservationLog.note("boot", "replay" => { applied: 0 })
    boot = lines.find { |l| l["kind"] == "boot" }

    refute_nil boot
    assert_equal Body.id, boot["body_id"]
  end

  def test_decisions_and_refusals_share_the_same_stream
    BudgetGuard.mark_gateway_429!
    begin
      BudgetGuard.reserve!(:dream)
    rescue BudgetGuard::Exhausted => e
      BudgetGuard.record_exhausted!(e.reason)
    end

    exhausted = lines.find { |l| l["kind"] == "attention_exhausted" }
    refute_nil exhausted
    assert_equal "gateway_429", exhausted["reason"]
  end

  def test_the_log_survives_a_cold_start
    get "/garden"
    before = lines.length
    simulate_cold_start!
    get "/well"

    assert_operator lines.length, :>, before
    assert_equal %w[/garden /well], lines.select { |l| l["kind"] == "absence" }
                                         .map { |o| o["safe_display_path"] }
  end

  # 自己テストは訪問ではない。数えると mutation のたびに孤独が薄まってしまう。
  def test_self_tests_leave_no_trace
    get "/garden"
    before_lines = lines.length
    before_events = Observer.total_count
    before_loneliness = Psyche["loneliness"]

    result = TrustedMutator.smoke_test({ "type" => "no_change" })

    assert_equal true, result["passed"], result["reason"]
    assert_equal before_lines, lines.length
    assert_equal before_events, Observer.total_count
    assert_in_delta before_loneliness, Psyche["loneliness"], 1e-9
  end

  # ただし外から header で自己テストを騙ることはできない。
  def test_a_visitor_cannot_erase_their_own_footprint
    before = Observer.total_count
    get "/sneaky", nil, "HTTP_CREATURE_SMOKE" => "true", "HTTP_X_CREATURE_SMOKE" => "true"

    assert_operator Observer.total_count, :>, before
    assert_equal "/sneaky", lines.select { |l| l["kind"] == "absence" }.last["safe_display_path"]
  end

  # 記録のために身体を殺さない。上限に当たったら、当たったことだけ言って黙る。
  def test_a_flood_cannot_fill_the_volume
    get "/open-the-handle"
    ObservationLog.instance_variable_set(:@bytes, ObservationLog::MAX_BYTES_PER_DAY)
    ObservationLog.instance_variable_set(:@truncated, false)

    5.times { get "/flood" }

    assert_equal 1, lines.count { |l| l["kind"] == "log_truncated" }
    assert_equal 0, lines.count { |l| l["safe_display_path"] == "/flood" }
    assert_equal 404, last_response.status
  ensure
    ObservationLog.close!
  end

  def test_logging_can_be_switched_off_without_touching_the_body
    ENV["OBSERVATION_LOG"] = "false"
    ObservationLog.close!
    get "/garden"

    assert_equal 404, last_response.status
    assert_empty lines
  ensure
    ENV["OBSERVATION_LOG"] = "true"
    ObservationLog.close!
  end
end
