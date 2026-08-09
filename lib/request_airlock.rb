# frozen_string_literal: true

require "digest"
require "openssl"
require "securerandom"
require "cgi"

# 外部入力を「材料」へ変換するだけの気密室。
# ここを通った後のものは、命令ではなく観測でしかない。
# 変更不能（Creature からは触れない）。
module RequestAirlock
  MAX_PATH = Config::MAX_PATH_CHARS
  MAX_DISPLAY = Config::MAX_DISPLAY_PATH_CHARS
  CONTROL_CHARS = /[\u0000-\u001F\u007F]/

  # path の family 判定。raw path を LLM へ渡さず、この既知 family へ圧縮する。
  FOREIGN_BODY = %r{\A/(wp-admin|wp-login|wp-content|wp-includes|xmlrpc\.php|wordpress|administrator|phpmyadmin|cgi-bin|typo3|drupal)}i
  SECRET_PROBE = %r{(\A/\.(env|git|aws|ssh|htpasswd|DS_Store)|/\.env|credentials|id_rsa|\.pem\z|secrets?\.(ya?ml|json)\z|/config\.json\z|/backup)}i
  EXTENSION_PROBE = %r{\.(php|asp|aspx|jsp|cgi|sql|bak|old|zip|tar|gz|log|ini|conf|dll|exe)\z}i
  ASSET_LIKE = %r{\.(css|js|png|jpe?g|gif|svg|ico|woff2?|ttf|map|webp|avif)\z}i
  WELL_KNOWN = %r{\A/(\.well-known/|robots\.txt|sitemap\.xml|favicon\.ico|ads\.txt|security\.txt)}i
  QUESTION_LIKE = %r{\A/[a-z]+([-_][a-z]+){1,5}\z}i
  CLAIMED_BOT = /(googlebot|bingbot|gptbot|claudebot|anthropic|perplexity|ccbot|applebot|yandex|baiduspider|duckduckbot|semrush|ahrefs|facebookexternalhit|slurp|oai-searchbot)/i

  @salt_day = nil
  @salt = nil
  @salt_mutex = Mutex.new

  module_function

  # 日替わり salt。IP は保存せず、この短命な鍵でしか束ねない。
  # 日が変われば昨日の bucket とは繋がらなくなる（意図的な健忘）。
  def daily_salt
    today = Clock.jst_date_string
    @salt_mutex.synchronize do
      if @salt_day != today
        @salt_day = today
        @salt = SecureRandom.bytes(32)
      end
      @salt
    end
  end

  def observe(request)
    raw_path = request.path_info.to_s
    normalized = normalize_path(raw_path)
    family = classify(normalized)
    display = displayable?(normalized, family) ? normalized : nil
    ua = request.user_agent.to_s

    {
      "id" => event_id,
      "at" => Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ"),
      "kind" => kind_for(request, normalized),
      "path_key" => path_key(normalized),
      "safe_display_path" => display,
      "family" => family,
      "method" => request.request_method,
      "visitor_bucket" => visitor_bucket(request),
      "claimed_identity" => claimed_identity(ua),
      "behavior" => nil, # Observer.record が履歴から埋める
      "generation" => Body.generation,
      "body_id" => Body.id,
      "raw_discarded" => true
    }
  end

  # 例外も観測である。message は正規化してから残す。
  def observe_exception(error, method_name)
    {
      "id" => event_id,
      "at" => Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ"),
      "kind" => "exception",
      "error_class" => error.class.name,
      "message" => normalize_message(error.message),
      "in_method" => method_name.to_s,
      "generation" => Body.generation,
      "body_id" => Body.id
    }
  end

  def event_id
    "#{Time.now.utc.strftime('%Y%m%dT%H%M%S')}-#{SecureRandom.hex(6)}"
  end

  # percent decode は一度だけ。二重デコードは攻撃面を増やすだけで、
  # 観測の解像度を上げない。
  def normalize_path(raw)
    s = raw.dup
    s = CGI.unescape(s) rescue s
    s = s.encode("UTF-8", invalid: :replace, undef: :replace, replace: "�")
    s = s.gsub(CONTROL_CHARS, "")     # 制御文字・改行を除去
    s = s.gsub(%r{/+}, "/")                      # 連続 slash を畳む
    s = "/#{s}" unless s.start_with?("/")
    s = s.sub(%r{(.)/\z}, '\1')                  # 末尾 slash（root 以外）
    s = s[0, MAX_PATH]
    s.empty? ? "/" : s
  end

  def path_key(normalized)
    "sha256:#{Digest::SHA256.hexdigest(normalized)}"
  end

  def kind_for(request, normalized)
    return "method_refusal" unless Config::ALLOWED_METHODS.include?(request.request_method)
    return "presence" if normalized == "/"

    "absence"
  end

  def classify(path)
    return "self" if path == "/"
    return "well_known" if path =~ WELL_KNOWN
    return "secret_probe" if path =~ SECRET_PROBE
    return "foreign_body" if path =~ FOREIGN_BODY
    return "extension_probe" if path =~ EXTENSION_PROBE
    return "asset" if path =~ ASSET_LIKE
    return "opaque" if high_entropy?(path) || path.length > MAX_DISPLAY
    return "question" if path =~ QUESTION_LIKE
    return "imagined_place" if path =~ %r{\A/[a-z][a-z0-9\-_/]{0,40}\z}i

    "unknown"
  end

  # 表示してよいのは、短くて、秘密らしくなくて、読める path だけ。
  def displayable?(path, family)
    return false if %w[secret_probe opaque].include?(family)
    return false if path.length > MAX_DISPLAY
    return false if high_entropy?(path)

    path.match?(%r{\A[ -~]+\z}) && !path.include?("�")
  end

  # base64 や token のような path を「読めた」ことにしない。
  def high_entropy?(path)
    body = path.delete("/")
    return false if body.length < 16

    alphabet = body.chars.uniq.length
    digits = body.count("0-9").to_f / body.length
    long_token = body.match?(/[A-Za-z0-9+\/=_-]{24,}/)
    long_token && (alphabet.to_f / body.length > 0.55 || digits > 0.3)
  end

  # IP は保存しない。日替わり salt の HMAC を短く切って
  # source diversity だけを推定する。
  def visitor_bucket(request)
    material = [
      request.env["HTTP_FLY_CLIENT_IP"] || request.env["HTTP_CF_CONNECTING_IP"] || request.ip.to_s,
      request.user_agent.to_s[0, 120]
    ].join("\n")
    digest = OpenSSL::HMAC.hexdigest("SHA256", daily_salt, material)
    "daily-hmac:#{digest[0, 16]}"
  end

  # 名乗りは記録するが、権限にも特別扱いにも使わない。逆引き検証もしない。
  def claimed_identity(user_agent)
    m = user_agent.match(CLAIMED_BOT)
    return "claimed:#{m[1].downcase}" if m
    return "none" if user_agent.strip.empty?

    "unverified"
  end

  # 公開ページに実 path や backtrace を出さないため、message を縮約する。
  def normalize_message(message)
    message.to_s
           .gsub(%r{/[^\s:]*/}, "…/")
           .gsub(/0x[0-9a-f]+/i, "0x…")
           .gsub(/\d{3,}/, "N")
           .gsub(CONTROL_CHARS, " ")[0, 160]
  end
end
