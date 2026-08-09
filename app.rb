# frozen_string_literal: true

require "sinatra/base"
require "erb"
require "rack/utils"

require_relative "lib/config"
require_relative "lib/clock"
require_relative "lib/store"
require_relative "lib/body"
require_relative "lib/psyche"
require_relative "lib/request_airlock"
require_relative "lib/observer"
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
    # This is a creature, not a site. It has one url and a few organs.
    # Crawling is part of its ecology. Please be gentle with the absences.
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

    def duration(seconds)
      s = seconds.to_i
      return "#{s}s" if s < 60
      return "#{s / 60}m #{s % 60}s" if s < 3600

      "#{s / 3600}h #{(s % 3600) / 60}m"
    end

    def bar(value)
      filled = (value.to_f * 20).round
      "#{'█' * filled}#{'·' * (20 - filled)}"
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
    event = RequestAirlock.observe(request)
    Observer.record(event)
    content_type "text/plain", charset: "utf-8"
    halt 405, "I only listen. I do not take things in.\n"
  end

  after do
    if @started_at
      Fitness.sample_latency((Process.clock_gettime(Process::CLOCK_MONOTONIC) - @started_at) * 1000)
    end
    AttentionScheduler.tick!
  end

  # ---- Creature が持っている唯一の生得機能 -------------------------------
  get "/" do
    event = RequestAirlock.observe(request)
    Observer.record(event)
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

    event = RequestAirlock.observe(request)
    event["kind"] = "presence"
    event["family"] = "acquired"
    Observer.record(event)

    content_type entry["content_type"], charset: "utf-8"
    body_text = DynamicRoutes.render(entry, event)
    entry["content_type"] == "text/html" ? "<pre>#{h(body_text)}</pre>" : body_text
  end

  # ---- 404 / 410 の瞬間応答 ----------------------------------------------
  not_found do
    event = RequestAirlock.observe(request)
    Observer.record(event)

    status DynamicRoutes.previously_existed?(event["path_key"]) ? 410 : 404
    headers "Cache-Control" => "no-store"
    content_type "text/plain", charset: "utf-8"

    first_breath = begin
      Creature.current.respond_to_absence(event) # local, no LLM
    rescue StandardError => e
      # 壊れた声も観測である。500 を返すことで smoke test が気づける。
      Observer.record_exception(e, "Creature#respond_to_absence")
      status 500
      halt 500, "Something in me failed: #{e.class}.\n\nGeneration #{Body.generation} is still standing.\n"
    end

    if AttentionScheduler.gaze?(event)
      # 二拍子。第一声は即座に送る。第二声は間に合えば足す。
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
    "Something in me failed: #{e.class}.\n\nGeneration #{Body.generation} is still standing.\n"
  end

  # ---- 起動 ---------------------------------------------------------------
  def self.wake!
    Config.ensure_dirs!
    Psyche.load!
    DynamicRoutes.load!
    EvolutionJournal.load!
    TrustedMutator.smoke_app = self

    Body.begin_life!
    @replay_report = Replay.run!
    self
  end

  class << self
    attr_reader :replay_report
  end
end
