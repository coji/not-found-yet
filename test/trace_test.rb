# frozen_string_literal: true

require_relative "test_helper"

class TraceTest < Minitest::Test
  include Rack::Test::Methods
  include CreatureTest

  def app = App

  def setup
    clean_slate!
    TraceRegistry.reset!
    Conversation.reset!
  end

  def age!(trace, days)
    TraceRegistry.update(trace["id"]) do |t|
      t.merge("at" => Clock.iso(Clock.now - days * 86_400),
              "last_asked_at" => Clock.iso(Clock.now - days * 86_400),
              "last_visited_at" => nil)
    end
  end

  # ---- 印はもらえる条件がある --------------------------------------------

  def test_the_first_naming_of_a_place_gets_an_address
    get "/garden"

    assert_includes last_response.body, "/trace/1"
    assert_includes last_response.body, "この名指しに印をつけた。"

    trace = TraceRegistry.find(1)
    assert_equal "/garden", trace["name"]
    assert_equal 1, trace["askers"]
  end

  # スキャナーにも規約の探索にも痕は出ない。最初の一人であることが条件だから意味が出る。
  def test_noise_never_gets_a_mark
    %w[/wp-admin /.env /favicon.ico /robots.txt /shell.php /style.css].each { |p| get p }

    assert_equal 0, TraceRegistry.count
  end

  def test_later_askers_are_sent_to_the_first_persons_mark
    get "/garden"
    # REMOTE_ADDR は HTTP header ではなく env。別人として届かせる。
    get "/garden", nil, "REMOTE_ADDR" => "203.0.113.55", "HTTP_USER_AGENT" => "someone-else/1"

    assert_includes last_response.body, "あなたは 2 人目だ。最初の人の痕は /trace/1 にある。"
    assert_equal 1, TraceRegistry.count
  end

  def test_the_mark_is_a_page_you_can_come_back_to
    get "/garden"
    get "/trace/1"

    assert_equal 200, last_response.status
    assert_includes last_response.body, "/garden"
    assert_includes last_response.body, "この名前ではじめて私を呼んだ人がいる"
    assert_equal 1, TraceRegistry.find(1)["visits"]
  end

  def test_an_address_that_was_never_marked_is_just_an_absence
    get "/trace/9999"
    assert_equal 404, last_response.status
  end

  # ---- 風化と蘇生 --------------------------------------------------------

  def test_a_mark_no_one_returns_to_loses_its_word
    get "/garden"
    age!(TraceRegistry.find(1), 30)

    assert_equal :forgotten, TraceRegistry.weather(TraceRegistry.find(1))
    TraceRegistry.sweep!

    forgotten = TraceRegistry.find(1)
    assert_nil forgotten["name"]
    refute_nil forgotten["forgotten_at"]
    # path_key は残る。忘れてはいるが、聞けば分かる。
    assert_equal RequestAirlock.path_key("/garden"), forgotten["path_key"]

    get "/trace/1"
    assert_includes last_response.body, "言葉は忘れた"
    assert_includes last_response.body, "もう一度私に求めてほしい"
  end

  def test_saying_the_word_again_brings_it_back
    get "/garden"
    age!(TraceRegistry.find(1), 30)
    TraceRegistry.sweep!
    assert_nil TraceRegistry.find(1)["name"]

    get "/garden"

    revived = TraceRegistry.find(1)
    assert_equal "/garden", revived["name"]
    assert_nil revived["forgotten_at"]
    assert_equal 1, revived["revivals"]
    assert_includes last_response.body, "その言葉を、いま思い出した。/trace/1"
  end

  def test_visiting_the_mark_keeps_it_sharp
    get "/garden"
    age!(TraceRegistry.find(1), 12)
    assert_equal :fading, TraceRegistry.weather(TraceRegistry.find(1))

    get "/trace/1" # 見に来ること自体が注意を注ぐこと

    assert_equal :sharp, TraceRegistry.weather(TraceRegistry.find(1))
  end

  # ---- 痕は Creature に消せない ------------------------------------------

  def test_the_creature_cannot_take_the_address_away
    # 声を完全に書き換えても、約束の行は残る。
    apply_intent("type" => "rewrite_absence_voice",
                 "templates" => [{ "family" => "*", "lines" => ["何も言わない。"] }],
                 "max_length" => 100)
    get "/garden"

    assert_includes last_response.body, "何も言わない。"
    assert_includes last_response.body, "/trace/1"
  end

  def test_the_agent_cannot_claim_a_trace_address
    %w[/trace /trace/1 /traces/all].each do |path|
      refute DynamicRoutes.valid_path?(path), path
    end
  end
end
