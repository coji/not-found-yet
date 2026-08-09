# frozen_string_literal: true

require_relative "test_helper"

# 打つ代わりの入力欄。
#
# 仕様の CORE THESIS は「フォームで命令するのではない」。ここで守っているのは、
# この form が 302 を返すだけで、生き物が受け取る request は
# アドレスバーに打たれたものと 1 バイトも変わらない、ということ。
class WanderTest < Minitest::Test
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

  # Location は percent encode されて返る。比較のために戻す。
  def location
    URI::DEFAULT_PARSER.unescape(URI.parse(last_response.headers["Location"].to_s).path)
         .force_encoding("UTF-8")
  end

  def location_host = URI.parse(last_response.headers["Location"].to_s).host

  # ---- 入力面は増えていない ----------------------------------------------

  def test_the_form_only_sends_you_where_you_could_have_typed
    get "/go", "to" => "/庭"

    assert_equal 302, last_response.status
    assert_equal "/庭", location
    # /go 自体は観測されない。名指しとして数えるのは、その先へ届いた request。
    assert_empty Observer.recent_absences
  end

  def test_what_arrives_is_indistinguishable_from_typing
    get "/go", "to" => "/garden"
    follow_redirect!

    assert_equal 404, last_response.status
    assert_includes last_response.body, "/garden は、私にはない。"
    assert_equal "/garden", Observer.recent_absences.first[:path]
  end

  def test_it_tidies_what_you_typed
    { "garden" => "/garden", "//deep//well//" => "/deep/well",
      " /spaced " => "/spaced", "/trailing/" => "/trailing" }.each do |input, expected|
      get "/go", "to" => input
      assert_equal expected, location, input
    end
  end

  # ---- 外へは出さない ----------------------------------------------------

  def test_it_is_not_an_open_redirect
    [
      "https://example.com/evil",
      "//example.com/evil",
      "http:/example.com",
      "javascript:alert(1)",
      "\\\\example.com",
      "/\\example.com",
      "https://example.com"
    ].each do |hostile|
      get "/go", "to" => hostile
      assert_equal 302, last_response.status, hostile
      # 行き先は必ず自分自身。
      # //example.com は「外の host」ではなく「/example.com という相対 path」に潰れる。
      assert_equal "example.org", location_host, hostile
      refute location.start_with?("//"), hostile
    end
  end

  def test_an_empty_name_just_sends_you_home
    get "/go", "to" => "   "
    assert_equal "/", location
  end

  def test_the_agent_cannot_claim_the_door
    refute DynamicRoutes.valid_path?("/go")
  end

  # ---- どこからでも次へ行ける --------------------------------------------

  def test_the_front_page_offers_the_field
    get "/"
    assert_includes last_response.body, %(action="/go")
    assert_includes last_response.body, "まだ無い場所の名前を、ひとつ"
  end

  # 生えた器官の上では、既定がいまいる場所になる。書き換えて次へ進める。
  def test_an_organ_defaults_the_field_to_where_you_are
    apply_intent("type" => "add_organ", "path" => "/garden", "title" => "庭",
                 "form" => "shell", "source" => "recurring", "mood" => "curious",
                 "motion" => "drift", "lines" => ["ここにある。"])
    get "/garden"

    assert_includes last_response.body, %(action="/go")
    assert_includes last_response.body, %(value="/garden")
  end

  def test_the_absence_page_lets_you_try_another_name
    get "/nowhere-yet", nil, "HTTP_ACCEPT" => "text/html"

    assert_includes last_response.body, %(action="/go")
    assert_includes last_response.body, %(value="/nowhere-yet")
  end

  # plain text の 404 は何も変わらない。form は皮の上にしか無い。
  def test_the_plain_answer_never_grows_a_form
    get "/nowhere-yet"

    assert_includes last_response.content_type, "text/plain"
    refute_includes last_response.body, "form"
    refute_includes last_response.body, "<"
  end

  def test_the_form_never_needs_script
    apply_intent("type" => "add_organ", "path" => "/garden", "title" => "庭",
                 "form" => "pulse", "source" => "psyche", "mood" => "lonely",
                 "motion" => "breathe", "lines" => ["ここにある。"])
    get "/garden"

    refute_includes last_response.body, "<script"
    refute_includes last_response.body, "onsubmit"
    assert_includes last_response.body, %(method="get")
  end
end
