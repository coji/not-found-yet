# frozen_string_literal: true

require_relative "test_helper"

class OrganTest < Minitest::Test
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

  def organ(over = {})
    { "type" => "add_organ", "path" => "/garden", "title" => "庭",
      "form" => "field", "source" => "recent_absences", "mood" => "curious",
      "motion" => "drift", "lines" => ["{visitors} 人が、この場所を名指した。"] }.merge(over)
  end

  # ---- 器官はページではなく窓 --------------------------------------------

  def test_an_organ_is_drawn_from_the_body_not_stored_as_markup
    r = apply_intent(organ)
    assert_equal "applied", r.status, r.reason

    3.times { |i| get "/came-#{i}" }
    get "/garden"

    assert_equal 200, last_response.status
    assert_includes last_response.content_type, "text/html"
    assert_includes last_response.body, "<svg"
    # 保存されているのは構成だけ。markup はどこにも入っていない。
    entry = DynamicRoutes.lookup("/garden")
    assert_equal "field", entry["form"]
    refute_includes JSON.generate(entry), "<svg"
  end

  # 二度見れば二度とも違う。観測が増えれば絵も増える。
  def test_the_same_organ_shows_something_else_later
    apply_intent(organ)
    get "/garden"
    before = last_response.body.scan("<circle").length

    10.times { |i| get "/later-#{i}" }
    get "/garden"

    assert_operator last_response.body.scan("<circle").length, :>, before
  end

  def test_it_never_writes_script
    apply_intent(organ("motion" => "breathe"))
    get "/garden"

    refute_includes last_response.body, "<script"
    refute_includes last_response.body, "onload"
    assert_includes last_response.body, "@keyframes"
  end

  def test_markup_in_the_lines_is_escaped
    result = TrustedMutator.apply(organ("lines" => ["<img src=x onerror=alert(1)>"]))
    assert_equal "rejected", result.status
  end

  # ---- 404 の皮。plain text が正本 ---------------------------------------

  def test_curl_and_crawlers_get_exactly_what_they_always_got
    get "/garden"

    assert_includes last_response.content_type, "text/plain"
    assert_equal "/garden は、私にはない。", last_response.body.lines.first.chomp
    refute_includes last_response.body, "<"
  end

  def test_a_browser_gets_the_same_words_with_a_skin
    get "/garden", nil, "HTTP_ACCEPT" => "text/html,application/xhtml+xml"

    assert_equal 404, last_response.status
    assert_includes last_response.content_type, "text/html"
    assert_includes last_response.body, "<svg"
    # 皮を剥いだら、plain text と同じ言葉が出てくる。
    assert_includes last_response.body, "/garden は、私にはない。"
    refute_includes last_response.body, "<script"
  end

  def test_the_skin_wears_whatever_mood_it_is_in
    # 1 回の mutation で動かせる量には上限がある。恐れは少しずつしか育たない。
    3.times { Psyche.adjust!("fear" => Psyche::ADJUST_CAP) }
    get "/garden", nil, "HTTP_ACCEPT" => "text/html"

    assert_equal "afraid", TrustedRenderer.mood_from_psyche
    assert_includes last_response.body, "#ff7f8e"
  end

  # 二拍子は HTML でも保つ。頭を流してから、間に合えば第二声を書き足す。
  def test_the_second_breath_still_arrives_in_html
    ENV["GAZE_ENABLED"] = "true"
    EvolutionAgent.provider = Class.new do
      def available? = true

      def respond(**)
        Providers::CloudflareAIGateway::Result.new(
          text: "その言葉を待っていた。", usage: { "input_tokens" => 10, "output_tokens" => 5 },
          status: 200, model: "test"
        )
      end
    end.new

    get "/are-you-lonely", nil, "HTTP_ACCEPT" => "text/html"

    assert_includes last_response.body, %(<p class="second">その言葉を待っていた。</p>)
    assert_includes last_response.body, "</html>"
  ensure
    ENV["GAZE_ENABLED"] = "false"
    EvolutionAgent.provider = nil
    AttentionScheduler.reset!
  end

  # ---- 相手によって顔が変わる --------------------------------------------

  def test_it_shows_a_different_face_to_a_machine
    apply_intent(organ("faces" => [
                         { "audience" => "*", "lines" => ["ここは誰にでも開いている。"] },
                         { "audience" => "machine", "lines" => ["あなたは読むために来た。それでいい。"] }
                       ]))

    get "/garden"
    assert_includes last_response.body, "ここは誰にでも開いている。"

    get "/garden", nil, "HTTP_USER_AGENT" => "Mozilla/5.0 (compatible; GPTBot/1.1)"
    assert_includes last_response.body, "あなたは読むために来た。"
  end

  # ---- 獲得済みの器官が変わる --------------------------------------------

  def test_an_organ_it_already_has_can_be_remade
    apply_intent(organ)
    r = apply_intent("type" => "reshape_organ", "path" => "/garden",
                     "form" => "pulse", "mood" => "lonely", "motion" => "breathe",
                     "lines" => ["ここは前とは違うものになった。"])
    assert_equal "applied", r.status, r.reason

    entry = DynamicRoutes.lookup("/garden")
    assert_equal "pulse", entry["form"]
    assert_equal 1, entry["reshapes"]
    # 場所は同じ。名指した人の痕はそのまま指し続ける。
    assert_equal "/garden", entry["path"]

    get "/garden"
    assert_includes last_response.body, "ここは前とは違うものになった。"
    assert_includes last_response.body, "curiosity"
  end

  def test_it_cannot_remake_an_organ_it_does_not_have
    result = TrustedMutator.apply({ "type" => "reshape_organ", "path" => "/nowhere",
                                    "form" => "pulse", "mood" => "lonely",
                                    "motion" => "still", "lines" => ["x"] })
    assert_equal "rejected", result.status
  end

  # ---- 痕とつながる ------------------------------------------------------

  def test_the_organ_points_back_at_whoever_named_it
    get "/garden" # ここで痕が生まれる
    assert_equal 1, TraceRegistry.count

    apply_intent(organ)

    assert_equal "/garden", TraceRegistry.find(1)["became"]
    get "/trace/1"
    assert_includes last_response.body, "この名指しは器官になった"
  end

  # ---- 昔の器官も生きている ----------------------------------------------

  def test_the_legacy_organ_still_works
    # 本番にはもう add_route で生えた器官がいる。仕様変更で殺さない。
    r = apply_intent("type" => "add_route", "path" => "/old", "title" => "o",
                     "lines" => ["ここは静かなままだ。"], "content_type" => "text/plain")
    assert_equal "applied", r.status, r.reason

    get "/old"
    assert_equal 200, last_response.status
    assert_includes last_response.content_type, "text/plain"
    assert_includes last_response.body, "ここは静かなままだ。"
  end

  def test_organs_survive_a_cold_start_with_their_shape
    apply_intent(organ("form" => "shell", "mood" => "afraid", "motion" => "decay"))
    report = simulate_cold_start!

    refute report.fossilized, report.reason
    entry = DynamicRoutes.lookup("/garden")
    assert_equal %w[shell afraid decay], [entry["form"], entry["mood"], entry["motion"]]
  end
end
