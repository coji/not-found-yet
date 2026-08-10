# frozen_string_literal: true

# 器官を描く。
#
# Creature が書けるのは「構成」だけで、markup は一行も書けない。
# TrustedMutator が Intent を closure へコンパイルするのと同じ関係を、
# 描画側にも置く。script は生成しない。SVG と CSS だけで足りる。
#
# 器官は保存された文字列ではなく、その瞬間の身体を映す窓である。
# 同じ器官でも、いつ見るか・誰が見るかで違うものが出る。
module TrustedRenderer
  FORMS = %w[field shell pulse still].freeze
  SOURCES = %w[recent_absences recurring families psyche journal silence].freeze
  MOODS = %w[curious afraid lonely proud tired quiet].freeze
  MOTIONS = %w[drift breathe decay still].freeze
  AUDIENCES = %w[* returning scanner machine].freeze

  PALETTE = {
    "curious" => %w[#c8ff6b #a8e04a],
    "afraid"  => %w[#ff7f8e #c75f6b],
    "lonely"  => %w[#70dcff #4a9ec7],
    "proud"   => %w[#ffbd70 #d99a55],
    "tired"   => %w[#9ba3a0 #626a68],
    "quiet"   => %w[#f0efe9 #9ba3a0]
  }.freeze

  W = 1000
  H = 560

  module_function

  # 誰が見に来たか。同じ器官が別の顔を見せるための唯一の判定。
  def audience_for(event)
    return "*" if event.nil?
    return "machine" if event["claimed_identity"].to_s.start_with?("claimed:")
    return "scanner" if event["behavior"] == "broad_scanner"
    return "returning" if event["behavior"] == "single_returning"

    "*"
  end

  def lines_for(entry, event)
    faces = Array(entry["faces"])
    who = audience_for(event)
    face = faces.find { |f| f["audience"] == who } || faces.find { |f| f["audience"] == "*" }
    face ? face["lines"] : entry["lines"]
  end

  # 打つ代わりの入力欄。器官の上でも、そこから次へ回遊できる。
  # これは 302 を返すだけの form なので、生き物が受け取る request は変わらない。
  def wander(current)
    <<~HTML
      <form class="wander" method="get" action="/go">
        <label for="to">つぎに求める場所</label>
        <div class="wander-row">
          <input id="to" name="to" type="text" value="#{esc(current)}" maxlength="80"
                 spellcheck="false" autocomplete="off">
          <button type="submit">求める</button>
        </div>
      </form>
    HTML
  end

  def render(entry, event)
    lines = Array(lines_for(entry, event)).map { |l| VoiceTemplate.fill(l, VoiceTemplate.context(event)) }
    form = FORMS.include?(entry["form"]) ? entry["form"] : "still"
    mood = MOODS.include?(entry["mood"]) ? entry["mood"] : "quiet"
    motion = MOTIONS.include?(entry["motion"]) ? entry["motion"] : "still"

    <<~HTML
      <!doctype html>
      <html lang="ja">
      <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <title>#{esc(entry['title'].to_s.empty? ? entry['path'] : entry['title'])}</title>
      <link rel="icon" href="data:image/svg+xml,<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 32 32'><circle cx='16' cy='16' r='7' fill='%23c8ff6b'/></svg>">
      <style>#{style(mood, motion)}</style>
      </head>
      <body class="organ">
        #{figure(svg(form, mood, event))}
        <div class="organ-said">#{lines.map { |l| "<p>#{esc(l)}</p>" }.join}</div>
        #{wander(entry['path'])}
        <footer class="organ-foot">
          <span>#{esc(entry['path'])}</span>
          <span>第 #{Body.generation} 世代の身体が、いま描いた</span>
          #{origin_link(entry['path'])}
          <a href="/">自分</a>
        </footer>
      </body>
      </html>
    HTML
  end

  # 404 の皮。plain text が正本で、これはその上に着せるものにすぎない。
  # 二拍子を保つため、頭と尻を分けて返す。あいだに第二声が入る。
  def absence_page(text, event)
    mood = mood_from_psyche
    head = <<~HTML
      <!doctype html>
      <html lang="ja">
      <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <title>#{esc(event['safe_display_path'] || 'ない場所')}</title>
      <link rel="icon" href="data:image/svg+xml,<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 32 32'><circle cx='16' cy='16' r='7' fill='%23c8ff6b'/></svg>">
      <style>#{style(mood, 'drift')}.organ-said .second{color:#{PALETTE.fetch(mood, PALETTE['quiet']).last};margin-top:1.2rem}</style>
      </head>
      <body class="organ">
        <figure class="organ-view">#{svg('field', mood, event)}</figure>
        <div class="organ-said">#{text.to_s.split(/\n{2,}/).map { |para| "<p>#{link_traces(esc(para))}</p>" }.join}
    HTML
    tail = <<~HTML
        </div>
        #{wander(event['safe_display_path'])}
        <footer class="organ-foot">
          <span>#{esc(event['safe_display_path'] || '読めない名前')}</span>
          <span>第 #{Body.generation} 世代</span>
          <a href="/">自分</a>
        </footer>
      </body>
      </html>
    HTML
    [head, tail]
  end

  def second_breath_html(text) = %(<p class="second">#{link_traces(esc(text))}</p>)

  # この場所を最初に名指した人の痕。器官は、誰かの思いつきから生えている。
  def origin_link(path)
    id = TraceRegistry.id_for(RequestAirlock.path_key(path.to_s))
    return "" unless id

    %(<a href="/trace/#{id}">この場所を名指した人の痕</a>)
  rescue StandardError
    ""
  end

  # いまの気分がそのまま配色になる。器官と違って、これは選べない。
  def mood_from_psyche
    case Psyche.dominant
    when "fear", "self_preservation" then "afraid"
    when "loneliness" then "lonely"
    when "curiosity" then "curious"
    when "vanity" then "proud"
    when "fatigue" then "tired"
    else "quiet"
    end
  end

  def figure(body) = body.empty? ? "" : %(<figure class="organ-view">#{body}</figure>)

  def esc(text) = Rack::Utils.escape_html(text.to_s)

  # 痕の住所はリンクにする。escape したあとで、数字だけの捕獲を差し込む。
  # plain text 側は素のまま。あちらが正本で、これは皮の上の便宜。
  def link_traces(escaped)
    escaped.gsub(%r{/trace/(\d{1,9})}) { %(<a class="trace-link" href="/trace/#{Regexp.last_match(1)}">/trace/#{Regexp.last_match(1)}</a>) }
  end

  def style(mood, motion)
    fg, dim = PALETTE.fetch(mood, PALETTE["quiet"])
    anim =
      case motion
      when "drift" then "@keyframes m { from { transform: translateY(0) } to { transform: translateY(-10px) } }\n.mark { animation: m 9s ease-in-out infinite alternate }"
      when "breathe" then "@keyframes m { from { opacity: .35 } to { opacity: 1 } }\n.mark { animation: m 4.5s ease-in-out infinite alternate }"
      when "decay" then "@keyframes m { from { opacity: 1 } to { opacity: .12 } }\n.mark { animation: m 12s linear infinite }"
      else ""
      end

    <<~CSS
      *{box-sizing:border-box}
      body.organ{margin:0;min-height:100vh;display:flex;flex-direction:column;justify-content:safe center;gap:2rem;
        padding:clamp(2rem,8vh,6rem) clamp(1.5rem,5vw,4rem);background:#080a0b;color:#f0efe9;
        font-family:Inter,ui-sans-serif,-apple-system,"Hiragino Sans","Yu Gothic",sans-serif;line-height:1.8}
      .organ-view{margin:0;width:100%;max-width:1000px;align-self:center}
      .organ-view svg{width:100%;height:auto;display:block}
      .organ-said{max-width:44rem;align-self:center;font-size:clamp(1rem,2.4vw,1.35rem)}
      .organ-said p{margin:0 0 .6rem}
      .organ-foot{display:flex;flex-wrap:wrap;gap:.6rem 1.6rem;align-self:center;max-width:1000px;width:100%;
        padding-top:1.2rem;border-top:1px solid #28302f;color:#626a68;
        font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:.68rem;letter-spacing:.1em}
      .organ-foot a{color:#{dim};text-decoration:none}
      .organ-foot a:hover{color:#{fg}}
      .organ-said a.trace-link{color:#{fg};text-decoration:none;border-bottom:1px solid #{dim}}
      .organ-said a.trace-link:hover{border-bottom-color:#{fg}}
      .wander{align-self:center;width:100%;max-width:44rem}
      .wander label{display:block;color:#626a68;font-family:ui-monospace,Menlo,monospace;
        font-size:.66rem;letter-spacing:.16em;text-transform:uppercase;margin-bottom:.6rem}
      .wander-row{display:flex;gap:.6rem;flex-wrap:wrap}
      .wander input{flex:1 1 14rem;min-width:0;padding:.75rem .95rem;border-radius:12px;
        border:1px solid #28302f;background:#0d1011;color:#f0efe9;
        font-family:ui-monospace,Menlo,monospace;font-size:.95rem}
      .wander input:focus{outline:none;border-color:#{fg}}
      .wander button{padding:.75rem 1.3rem;border-radius:12px;border:1px solid #{fg};
        background:#{fg};color:#10130d;font-weight:800;cursor:pointer;font-size:.9rem}
      .wander button:hover{filter:brightness(1.08)}
      #{anim}
      @media (prefers-reduced-motion: reduce){.mark{animation:none}}
    CSS
  end

  # ---- 形 -----------------------------------------------------------------
  # どれも「いま自分が持っている観測」からその場で組む。保存された絵ではない。

  def svg(form, mood, event)
    fg, dim = PALETTE.fetch(mood, PALETTE["quiet"])
    body =
      case form
      when "field" then field(fg, dim)
      when "shell" then shell(fg, dim)
      when "pulse" then pulse(fg, dim)
      else ""
      end
    return "" if body.empty?

    %(<svg viewBox="0 0 #{W} #{H}" role="img" aria-label="この生き物がいま持っている観測の図"><g class="mark">#{body}</g></svg>)
  end

  # 観測ひとつが一粒。位置は時刻と名前、大きさは回数。
  def field(fg, dim)
    list = Observer.recent_absences(80)
    # 件数に関わらず幅いっぱいに散らす。少ないときに端へ寄ると、
    # 「まだ何も来ていない」ではなく「壊れている」ように見える。
    step = W / [list.length, 1].max.to_f
    marks = list.each_with_index.map do |a, i|
      key = (a[:path] || "?").sum
      x = W - (i + 0.5) * step
      y = 60 + (key % 44) * ((H - 120) / 44.0)
      r = 2.6 + (key % 5)
      color = a[:family] == "imagined_place" || a[:family] == "question" ? fg : dim
      o = 0.25 + (0.6 * (1 - i / [list.length, 1].max.to_f))
      %(<circle cx="#{x.round(1)}" cy="#{y.round(1)}" r="#{r.round(1)}" fill="#{color}" opacity="#{o.round(2)}"/>)
    end
    return %(<text x="#{W / 2}" y="#{H / 2}" fill="#{dim}" font-size="20" text-anchor="middle">まだ何も届いていない</text>) if marks.empty?

    marks.join
  end

  # 穴の空いた球。繰り返し名指された場所が、埋まりかけの点になる。
  def shell(fg, dim)
    cx = W / 2.0
    cy = H / 2.0
    r = [H, W].min / 2.6
    ring = (0..119).map do |i|
      t = i / 120.0 * Math::PI * 2
      next if t > 1.9 && t < 2.9 # 欠落

      %(<circle cx="#{(cx + Math.cos(t) * r).round(1)}" cy="#{(cy + Math.sin(t) * r).round(1)}" r="2.4" fill="#{dim}" opacity="0.5"/>)
    end.compact

    grown = Observer.aggregate["recurring_absences"].first(14).each_with_index.map do |a, i|
      t = 2.0 + (i / 14.0) * 0.8
      rr = r * (0.55 + (a["independent_visitors"].to_i / 8.0).clamp(0, 0.4))
      %(<circle cx="#{(cx + Math.cos(t) * rr).round(1)}" cy="#{(cy + Math.sin(t) * rr).round(1)}" r="#{(3 + a['count'].to_i.clamp(0, 8)).round(1)}" fill="#{fg}" opacity="0.75"/>)
    end

    %(<circle cx="#{cx}" cy="#{cy}" r="#{r.round(1)}" fill="none" stroke="#{dim}" stroke-opacity="0.12"/>) +
      ring.join + grown.join
  end

  # 6 つの欲求が呼吸する。
  def pulse(fg, dim)
    Psyche.state.each_with_index.map do |(name, value), i|
      y = 70 + i * ((H - 140) / 5.0)
      w = (W - 260) * value.to_f
      %(<text x="40" y="#{(y + 5).round}" fill="#{dim}" font-size="18" font-family="monospace">#{esc(name)}</text>) +
        %(<rect x="240" y="#{(y - 6).round}" width="#{(W - 300).round}" height="4" rx="2" fill="#ffffff" fill-opacity="0.06"/>) +
        %(<rect x="240" y="#{(y - 6).round}" width="#{w.round(1)}" height="4" rx="2" fill="#{fg}" opacity="0.9"/>) +
        %(<text x="#{W - 40}" y="#{(y + 5).round}" fill="#{fg}" font-size="16" font-family="monospace" text-anchor="end">#{format('%.2f', value)}</text>)
    end.join
  end
end
