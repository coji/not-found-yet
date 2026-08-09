# frozen_string_literal: true

require "sinatra/base"
require "erb"
require "rack/utils"
require "uri"

require_relative "lib/config"
require_relative "lib/clock"
require_relative "lib/store"
require_relative "lib/body"
require_relative "lib/psyche"
require_relative "lib/request_airlock"
require_relative "lib/observation_log"
require_relative "lib/observer"
require_relative "lib/trace_registry"
require_relative "lib/conversation"
require_relative "lib/learned_families"
require_relative "lib/reflex_conditions"
require_relative "lib/machine_surfaces"
require_relative "lib/trusted_renderer"
require_relative "lib/creature"
require_relative "lib/dynamic_routes"
require_relative "lib/mutation_intent"
require_relative "lib/fitness"
require_relative "lib/evolution_journal"
require_relative "lib/trusted_mutator"
require_relative "lib/providers/cloudflare_ai_gateway"
require_relative "lib/evolution_agent"
require_relative "lib/budget_guard"
require_relative "lib/attention_scheduler"
require_relative "lib/replay"

# ひとつの身体。ひとつの URL。
class App < Sinatra::Base
  ROBOTS = <<~TXT
    # これはサイトではなく、一匹の生き物です。
    # ひとつの URL と、訪問者がまちがえて与えた少しの器官しか持っていません。
    # 巡回はこの生き物の生態の一部です。欠落には、やさしく触れてください。
    User-agent: *
    Allow: /
    Crawl-delay: 5
  TXT

  configure do
    set :public_folder, File.expand_path("public", __dir__)
    set :views, File.expand_path("views", __dir__)
    set :static, true
    set :show_exceptions, false
    set :raise_errors, false
    set :dump_errors, false
    set :logging, false
    set :protection, except: %i[json_csrf]
    set :host_authorization, permitted_hosts: Config.permitted_hosts
    # 内部の route 解決の事情は外に出さない。
    set :x_cascade, false
    set :default_content_type, "text/html"
  end

  helpers do
    def h(text) = Rack::Utils.escape_html(text.to_s)

    # 企画書と同じ見出し。まだ分かっていない部分だけを輪郭で残す。
    # 文面は Creature が持っているので、その語が現れたときにだけ効く。
    HOLLOW = /(自分が何なのか|\bI\s+am\b)/i
    JAPANESE_TEXT = /[\p{Hiragana}\p{Katakana}\p{Han}]/

    def headline_tag(text)
      body = text.to_s.split(HOLLOW).map do |part|
        part.match?(/\A(自分が何なのか|I\s+am)\z/i) ? %(<span class="ghost">#{h(part)}</span>) : h(part)
      end.join
      # 日本語は欧文ほど詰められない。同じ tracking を当てると潰れる。
      %(<h1 class="#{text.to_s.match?(JAPANESE_TEXT) ? 'jp' : 'latin'}">#{body}</h1>)
    end

    # 内部の識別子は英語のまま（schema と journal の正本なので動かせない）。
    # 表示のときだけ日本語を当てる。知らない語はそのまま出す。
    LABELS = {
      "curiosity" => "好奇", "fear" => "恐れ", "loneliness" => "孤独",
      "vanity" => "虚栄", "fatigue" => "疲れ", "self_preservation" => "自己保存",

      "imagined_place" => "想像された場所", "question" => "問いかけ",
      "foreign_body" => "別種の身体", "secret_probe" => "内側への要求",
      "extension_probe" => "拡張子の探索", "asset" => "素材",
      "opaque" => "読めない名前", "well_known" => "規約の探索",
      "unknown" => "未分類", "self" => "自分", "acquired" => "獲得した機能",

      "first_touch" => "はじめて", "single_returning" => "戻ってきた",
      "broad_scanner" => "多くの扉を試す手", "periodic_reader" => "名乗らない読者",
      "claimed_bot" => "名乗る巡回者", "self_test" => "自己テスト",

      "total" => "全部", "absence" => "不在", "presence" => "在",
      "exception" => "例外", "method_refusal" => "拒んだ要求",

      "applied" => "適用", "rejected" => "拒否",
      "rolled_back" => "巻き戻し", "no_change" => "変えない",

      "alive" => "生きている", "fossil" => "化石"
    }.freeze

    def label(key) = LABELS.fetch(key.to_s, key.to_s)

    # 痕にまつわる文面。Creature の声ではなく、運用者が固定している約束。
    def trace_line(trace, how)
      addr = "/trace/#{trace['id']}"
      case how
      when :minted then "この名指しに印をつけた。#{addr}"
      when :revived then "その言葉を、いま思い出した。#{addr}"
      else
        askers = trace["askers"].to_i
        return nil if askers < 2

        "あなたは #{askers} 人目だ。最初の人の痕は #{addr} にある。"
      end
    end

    def answer_line(answer)
      about = answer["asked_about"]
      said = answer["answer"] || "読めない名前"
      return "「#{said}」と言ったね。それを憶えておく。" if about.nil?

      "「#{said}」と言ったね。\n#{about} について、それを憶えておく。"
    end

    # 外へは出さない。相対 path だけを通す。
    # //evil.com や https:// を素通しすると、ただの open redirect になる。
    def navigable_path(raw)
      s = raw.to_s.gsub(RequestAirlock::CONTROL_CHARS, "").strip
      return nil if s.empty?
      # scheme を持つものは、この生き物の中の場所ではない。
      return nil if s.match?(%r{\A[a-z][a-z0-9+.\-]*:}i)

      # backslash を slash に倒してから連続 slash を畳む。
      # これで //example.com も /\example.com も、ただの相対 path になる。
      s = s.tr("\\", "/")
      s = "/#{s}" unless s.start_with?("/")
      s = s.gsub(%r{/+}, "/")[0, Config::MAX_PATH_CHARS]
      s = s.sub(%r{(.)/\z}, '\1')
      return nil if s == "/" || s.empty?

      s
    end

    # 打つ代わりの入力欄。既定は「いまいる場所」。
    def wander_form(current = nil)
      value = h(current.to_s)
      <<~HTML
        <form class="wander" method="get" action="/go">
          <label for="to">まだ無い場所の名前を、ひとつ</label>
          <div class="wander-row">
            <input id="to" name="to" type="text" value="#{value}" maxlength="80"
                   spellcheck="false" autocomplete="off" placeholder="/庭">
            <button type="submit">求める</button>
          </div>
        </form>
      HTML
    end

    def duration(seconds)
      s = seconds.to_i
      return "#{s}s" if s < 60
      return "#{s / 60}m #{s % 60}s" if s < 3600

      "#{s / 3600}h #{(s % 3600) / 60}m"
    end

    # 観測の唯一の入口。自己テストは「誰かが来た」に数えない。
    # 数えてしまうと、mutation を試すたびに孤独が薄まり fitness の分母が動く。
    def observe!(kind: nil, family: nil)
      event = RequestAirlock.observe(request)
      event["kind"] = kind if kind
      event["family"] = family if family

      if request.env[TrustedMutator::SMOKE_ENV_KEY]
        event["kind"] = "self_test"
        event["behavior"] = "self_test"
        return event
      end

      Observer.record(event)
    end

  end

  # 骨格。ここは Creature からは触れない。
  before do
    @started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    headers "Cache-Control" => "no-store",
            "X-Content-Type-Options" => "nosniff",
            "Referrer-Policy" => "no-referrer"

    next if Config::ALLOWED_METHODS.include?(request.request_method)

    # request body は読まない。読まないことを、読まれる前に決めておく。
    observe!
    content_type "text/plain", charset: "utf-8"
    halt 405, "私は聞くだけだ。受け取りはしない。\n"
  end

  after do
    if @started_at
      Fitness.sample_latency((Process.clock_gettime(Process::CLOCK_MONOTONIC) - @started_at) * 1000)
    end
    AttentionScheduler.tick!
  end

  # ---- Creature が持っている唯一の生得機能 -------------------------------
  get "/" do
    observe!
    @creature = Creature.current
    erb :index
  end

  # ---- 作品外部の固定された観測窓 ----------------------------------------
  get "/status" do
    @observer = Observer.snapshot
    @budget = BudgetGuard.snapshot
    @attention = AttentionScheduler.snapshot
    erb :status
  end

  get "/mutations" do
    @entries = EvolutionJournal.entries.reverse
    @selected = params["seq"] ? EvolutionJournal.find(params["seq"].to_i) : nil
    @exhibit = @selected ? EvolutionJournal.exhibit(@selected["seq"]) : nil
    erb :mutations
  end

  # ---- アドレスバーの代わり ----------------------------------------------
  #
  # フォームで命令はしない。ここがやるのは 302 を返すことだけで、
  # 生き物が受け取るのは、アドレスバーに打たれたのと同じ GET になる。
  # 入力面は増えていない。打つ手間が減っているだけ。
  get "/go" do
    target = navigable_path(params["to"]) || "/"
    # Location は ASCII でなければならない。日本語の名前はここで percent encode する。
    redirect(URI::DEFAULT_PARSER.escape(target), 302)
  end

  # ---- 痕。訪問者が持ち帰れる住所 ----------------------------------------
  # 見に来ること自体が注意を注ぐことなので、風化が止まり、鮮明さが戻る。
  get %r{/trace/(\d{1,9})} do |id|
    @trace = TraceRegistry.find(id.to_i)
    halt 404 unless @trace

    @trace = TraceRegistry.weather!(@trace)
    @trace = TraceRegistry.visited!(@trace["id"]) || @trace
    @weather = TraceRegistry.weather(@trace)
    erb :trace
  end

  # ---- 機械に向けた面。この子が自分で生やしたときだけ立つ ----------------
  get %r{/(llms\.txt|ai\.txt|\.well-known/ai\.txt)} do |name|
    entry = MachineSurfaces.lookup("/#{name}")
    pass unless entry

    event = observe!(kind: "presence", family: "well_known")
    # 自己テストは訪問者ではない。機械の読取にも数えない。
    MachineSurfaces.read!("/#{name}", event) unless event["kind"] == "self_test"
    content_type "text/plain", charset: "utf-8"
    MachineSurfaces.render(entry)
  end

  get "/robots.txt" do
    content_type "text/plain", charset: "utf-8"
    ROBOTS
  end

  # ---- 獲得した機能のための proxy route ----------------------------------
  # route entry を出し入れするのではなく、registry の active flag で切り替える。
  # 失った機能は pass して not_found へ落ち、そこで 410 になる。
  # Mustermann が前後を anchor するので、ここでは \A / \z を書かない。
  get %r{/([a-z0-9][a-z0-9\-_/]{0,47})} do |slug|
    entry = DynamicRoutes.lookup("/#{slug}")
    pass unless entry

    event = observe!(kind: "presence", family: "acquired")

    # 器官は保存された文字列ではなく、いまの身体から描き直される。
    if entry["form"] && entry["form"] != "still"
      content_type "text/html", charset: "utf-8"
      TrustedRenderer.render(entry, event)
    else
      content_type entry["content_type"], charset: "utf-8"
      body_text = DynamicRoutes.render(entry, event)
      entry["content_type"] == "text/html" ? "<pre>#{h(body_text)}</pre>" : body_text
    end
  end

  # ---- 404 / 410 の瞬間応答 ----------------------------------------------
  not_found do
    event = observe!

    status DynamicRoutes.previously_existed?(event["path_key"]) ? 410 : 404
    headers "Cache-Control" => "no-store"
    content_type "text/plain", charset: "utf-8"

    voice = begin
      Creature.current.respond_to_absence(event) # local, no LLM
    rescue StandardError => e
      # 壊れた声も観測である。500 を返すことで smoke test が気づける。
      Observer.record_exception(e, "Creature#respond_to_absence")
      status 500
      halt 500, "私の中の何かが壊れた: #{e.class}\n\n第 #{Body.generation} 世代は、まだ立っている。\n"
    end

    # ---- ここから下は Creature が消せない層 --------------------------------
    # 痕の住所は訪問者への約束なので、声の書き換えでは失われない。
    parts = []
    bucket = event["visitor_bucket"]
    self_test = event["kind"] == "self_test"

    answered = begin
      self_test ? nil : Conversation.answer!(bucket, event)
    rescue StandardError
      nil
    end
    parts << answer_line(answered) if answered

    parts << voice

    trace, how = begin
      self_test ? nil : TraceRegistry.touch!(event)
    rescue StandardError
      nil
    end
    parts << trace_line(trace, how) if trace

    unless answered || self_test
      question = begin
        Creature.current.question_for(event)
      rescue StandardError
        nil
      end
      if question && Conversation.ask!(bucket, question, event)
        parts << question
      end
    end

    first_breath = parts.reject { |x| x.to_s.empty? }.join("\n\n")

    # 何を言うかではなく、どう応じるか。ここは Creature が獲得した規則を
    # 不変側が実行する。規則そのものは書けても、実行のしかたは書けない。
    act = ReflexConditions.decide(event) || {}
    MachineSurfaces.note_follow_up(event) unless self_test

    if act["hesitate_ms"]
      waited = ReflexConditions.hesitate!(act["hesitate_ms"])
      headers "X-Hesitated-Ms" => waited.to_s if waited.positive?
    end

    if act["redirect_to"] && DynamicRoutes.lookup(act["redirect_to"])
      # わざと誤解して、連れて行く。
      redirect(act["redirect_to"], 302)
    end

    if act["silence"]
      status 204
      headers.delete("Content-Type")
      halt 204
    end

    status act["status"] if act["status"]
    if act["shorten_to"] && first_breath.length > act["shorten_to"]
      first_breath = "#{first_breath[0, act['shorten_to']].rstrip}…"
    end

    # 相手によって皮を替える。plain text が正本で、HTML はその上に着るもの。
    # curl とクローラーには、いままでと 1 バイトも変わらないものが届く。
    wants_html = !self_test && request.accept.any? { |a| a.to_s.include?("text/html") }
    gazing = AttentionScheduler.gaze?(event)

    if wants_html
      content_type "text/html", charset: "utf-8"
      head, tail = TrustedRenderer.absence_page(first_breath, event)
      if gazing
        # HTML でも二拍子は保つ。頭を先に流し、間に合えば第二声を書き足す。
        stream do |out|
          out << head
          second = begin
            AttentionScheduler.gaze_for(event)
          rescue StandardError
            nil
          end
          out << TrustedRenderer.second_breath_html(second) if second
          out << tail
        end
      else
        head + tail
      end
    elsif gazing
      stream do |out|
        out << first_breath
        second = begin
          AttentionScheduler.gaze_for(event)
        rescue StandardError
          nil
        end
        out << "\n\n#{second}" if second
      end
    else
      first_breath
    end
  end

  error do
    e = env["sinatra.error"]
    Observer.record_exception(e, "request")
    content_type "text/plain", charset: "utf-8"
    status 500
    # class と正規化した message だけ。backtrace も実 path も出さない。
    "私の中の何かが壊れた: #{e.class}\n\n第 #{Body.generation} 世代は、まだ立っている。\n"
  end

  # ---- 起動 ---------------------------------------------------------------
  def self.wake!
    Config.ensure_dirs!
    Psyche.load!
    DynamicRoutes.load!
    EvolutionJournal.load!
    TraceRegistry.load!
    TrustedMutator.smoke_app = self

    Body.begin_life!
    @replay_report = Replay.run!

    # 身体が入れ替わったこと自体を、次に読む人のために残す。
    ObservationLog.note("boot",
                        "previous_body_id" => Body.previous_id,
                        "inherited" => Body.inherited_alterations?,
                        "mode" => Body.mode,
                        "pid" => Process.pid,
                        "replay" => @replay_report.to_h)
    self
  end

  class << self
    attr_reader :replay_report
  end
end
