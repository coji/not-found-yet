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

  # ---- 住所は辿れる ------------------------------------------------------

  def test_the_address_is_clickable_in_the_skin
    get "/garden", nil, "HTTP_ACCEPT" => "text/html"

    assert_includes last_response.body, %(<a class="trace-link" href="/trace/1">/trace/1</a>)
  end

  # plain text は正本なので、素のまま。
  def test_the_plain_answer_keeps_the_bare_address
    get "/garden"

    assert_includes last_response.body, "この名指しに印をつけた。/trace/1"
    refute_includes last_response.body, "<a"
  end

  # 器官は誰かの思いつきから生えている。そこへ戻れる。
  def test_an_organ_points_back_to_the_person_who_named_it
    get "/garden"
    apply_intent("type" => "add_organ", "path" => "/garden", "title" => "庭",
                 "form" => "shell", "source" => "recurring", "mood" => "curious",
                 "motion" => "drift", "lines" => ["ここにある。"])

    get "/garden"
    assert_includes last_response.body, %(<a href="/trace/1">この場所を名指した人の痕</a>)

    # 痕からは器官へ。往復できる。
    get "/trace/1"
    assert_includes last_response.body, %(href="/garden")
  end

  def test_an_organ_nobody_named_has_nothing_to_point_at
    apply_intent("type" => "add_organ", "path" => "/unasked", "title" => "x",
                 "form" => "pulse", "source" => "psyche", "mood" => "quiet",
                 "motion" => "still", "lines" => ["誰も求めていない。"])
    get "/unasked"

    refute_includes last_response.body, "名指した人の痕"
  end

  # 痕のふりをした文字列を差し込まれても、リンクにはならない。
  def test_it_only_links_addresses_that_are_addresses
    apply_intent("type" => "rewrite_absence_voice",
                 "templates" => [{ "family" => "*", "lines" => ["/trace/abc /traceX/1 をどうぞ"] }],
                 "max_length" => 200)
    get "/nowhere", nil, "HTTP_ACCEPT" => "text/html"

    refute_includes last_response.body, "/trace/abc</a>"
    refute_includes last_response.body, "traceX/1</a>"
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
