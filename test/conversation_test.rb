# frozen_string_literal: true

require_relative "test_helper"

class ConversationTest < Minitest::Test
  include Rack::Test::Methods
  include CreatureTest

  def app = App

  def setup
    clean_slate!
    TraceRegistry.reset!
    Conversation.reset!
  end

  # 訊くかどうかは気分次第なので、テストでは必ず訊かせる。
  def always_ask!(text = "そこには何があるべきだと思う。")
    Creature.define_method(:question_for) { |_event| text }
  end

  def test_it_can_end_an_absence_with_a_question
    always_ask!
    get "/garden"

    assert_includes last_response.body, "そこには何があるべきだと思う。"
    assert_equal 1, Conversation.pending_count
  ensure
    reload_creature_source!
  end

  # 答えはフォームではなく、次にアドレスバーへ打たれる名前で返ってくる。
  def test_the_next_name_you_type_becomes_the_answer
    always_ask!
    get "/garden"
    reload_creature_source! # 二度目は訊かない
    get "/roses"

    assert_includes last_response.body, "「/roses」と言ったね。"
    assert_includes last_response.body, "/garden について、それを憶えておく。"
    assert_equal 0, Conversation.pending_count
  end

  def test_an_answer_is_a_stronger_observation_than_a_knock
    always_ask!
    get "/garden"
    reload_creature_source!
    # 直前のノックで飽和窓を使い切っているので、測る前に窓を空ける。
    Psyche.instance_variable_set(:@window_delta, Hash.new(0.0))
    before = Psyche["curiosity"]

    get "/roses"

    answers = Observer.answers
    assert_equal 1, answers.length
    assert_equal "/garden", answers.first["asked_about"]
    assert_equal "/roses", answers.first["answer"]
    assert_operator Psyche["curiosity"], :>, before
  end

  # 同じ名前をもう一度言うのは、答えではなく繰り返し。
  def test_repeating_the_same_name_is_not_an_answer
    always_ask!
    get "/garden"
    reload_creature_source!
    get "/garden"

    refute_includes last_response.body, "と言ったね"
    assert_empty Observer.answers
  end

  def test_a_question_expires
    always_ask!
    get "/garden"
    reload_creature_source!

    # TTL を越えた問いは、もう答えを待っていない。
    Conversation.instance_variable_get(:@pending).each_value { |p| p[:at] = Clock.now - Conversation::TTL - 1 }
    get "/roses"

    refute_includes last_response.body, "と言ったね"
    assert_empty Observer.answers
  end

  # 会話は別人には引き継がれない。問うた相手の答えだけを聞く。
  def test_someone_else_cannot_answer_for_you
    always_ask!
    get "/garden"
    reload_creature_source!
    get "/roses", nil, "REMOTE_ADDR" => "203.0.113.77", "HTTP_USER_AGENT" => "another/1"

    refute_includes last_response.body, "と言ったね"
    assert_empty Observer.answers
  end

  def test_the_creature_stays_quiet_when_it_is_afraid
    Psyche.adjust!("fear" => 0.6)
    12.times { |i| get "/probe-#{i}" }

    refute_includes last_response.body, "答えとして受け取る"
  end

  # ---- 観測の拡充 --------------------------------------------------------

  def test_it_remembers_what_you_asked_just_before
    get "/about"
    get "/who-are-you"

    pairs = Observer.sequences
    assert_equal ["/about → /who-are-you", 1], pairs.first
  end

  # 届きかけた手は、新しい欠落ではない。
  def test_a_near_miss_is_seen_as_a_slip_not_a_new_absence
    apply_intent("type" => "add_route", "path" => "/garden", "title" => "g",
                 "lines" => ["here"], "content_type" => "text/plain")
    get "/gardne"

    near = Observer.recent_absences.first
    refute_nil near
    assert_equal({ "path" => "/garden", "distance" => 2 }, Observer.near_miss("/gardne"))
  end
end
