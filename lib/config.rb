# frozen_string_literal: true

# 変更不能な身体法則のうち、値として外に出せるもの。
# ここに書かれた上限は Creature 自身からは変更できない（mutation の対象外）。
module Config
  module_function

  def env(key, default)
    v = ENV[key]
    v.nil? || v.strip.empty? ? default : v
  end

  def int(key, default)  = Integer(env(key, default.to_s))
  def float(key, default) = Float(env(key, default.to_s))
  def bool(key, default)  = %w[1 true yes on].include?(env(key, default ? "true" : "false").downcase)

  # --- 身体 ---------------------------------------------------------------
  def data_dir      = env("DATA_DIR", File.expand_path("../data", __dir__))
  def journal_dir   = env("JOURNAL_DIR", File.join(data_dir, "journal"))
  def mutation_dir  = env("MUTATION_DIR", File.join(data_dir, "mutations"))
  def exhibit_dir   = env("EXHIBIT_DIR", File.join(data_dir, "exhibits"))
  def budget_dir    = env("BUDGET_DIR", File.join(data_dir, "budget"))
  def tombstone_dir = env("TOMBSTONE_DIR", File.join(data_dir, "tombstones"))
  def lock_dir      = env("LOCK_DIR", File.join(data_dir, "locks"))
  def state_path    = File.join(data_dir, "state.json")

  # 到来そのものの記録。判断（journal）とは別に残す。
  def observation_log_dir = env("OBSERVATION_LOG_DIR", File.join(data_dir, "observations"))
  def observation_log? = bool("OBSERVATION_LOG", true)

  # alive: 観測・反射・注視・夢・mutation をすべて行う
  # fossil: 既存の応答と Journal は公開したまま、LLM 呼出と新しい mutation を止める
  def evolution_mode = env("EVOLUTION_MODE", "alive").downcase
  def alive?  = evolution_mode == "alive"
  def fossil? = !alive?

  def timezone = env("TZ", "Asia/Tokyo")

  # 空なら Host を制限しない。ひとつの URL に定住させたいときだけ指定する。
  def permitted_hosts
    env("PERMITTED_HOSTS", "").split(",").map(&:strip).reject(&:empty?)
  end

  # --- 入力面 -------------------------------------------------------------
  MAX_PATH_CHARS = 96
  MAX_DISPLAY_PATH_CHARS = 64
  ALLOWED_METHODS = %w[GET HEAD].freeze

  # --- Attention ----------------------------------------------------------
  def gaze_enabled?       = bool("GAZE_ENABLED", false) # 初期 PoC では無効
  def dream_enabled?      = bool("DREAM_ENABLED", true)
  def gaze_cooldown_sec   = int("GAZE_COOLDOWN_SEC", 45 * 60)
  def dream_interval_sec  = int("DREAM_MIN_INTERVAL_SEC", 90 * 60)
  def gaze_min_score      = float("GAZE_MIN_SCORE", 0.50)
  def dream_min_events    = int("DREAM_MIN_NEW_EVENTS", 12)

  # --- LLM / 予算 ---------------------------------------------------------
  def llm_model              = env("LLM_MODEL", "openai/gpt-5.6-luna")
  def daily_soft_limit_usd   = float("LLM_DAILY_SOFT_LIMIT_USD", 0.60)
  def max_calls_per_day      = int("LLM_MAX_CALLS_PER_DAY", 12)
  def gaze_max_calls_per_day = int("LLM_GAZE_MAX_CALLS_PER_DAY", 4)
  def dream_max_calls_per_day = int("LLM_DREAM_MAX_CALLS_PER_DAY", 8)
  def gaze_max_input_tokens  = int("LLM_GAZE_MAX_INPUT_TOKENS", 4_000)
  def gaze_max_output_tokens = int("LLM_GAZE_MAX_OUTPUT_TOKENS", 512)
  def dream_max_input_tokens = int("LLM_DREAM_MAX_INPUT_TOKENS", 20_000)
  def dream_max_output_tokens = int("LLM_DREAM_MAX_OUTPUT_TOKENS", 4_096)
  def reasoning_effort       = env("LLM_REASONING_EFFORT", "low")
  def gaze_timeout_ms        = int("LLM_GAZE_TIMEOUT_MS", 8_000)
  def dream_timeout_ms       = int("LLM_DREAM_TIMEOUT_MS", 30_000)

  # 予算計算は uncached 価格で保守的に行う（$ / 1M tokens）。
  def price_input_per_mtok  = float("LLM_PRICE_INPUT_PER_MTOK", 1.0)
  def price_output_per_mtok = float("LLM_PRICE_OUTPUT_PER_MTOK", 6.0)
  def price_cached_input_per_mtok = float("LLM_PRICE_CACHED_INPUT_PER_MTOK", 0.10)

  # --- Cloudflare AI Gateway ---------------------------------------------
  def cf_account_id = env("CF_ACCOUNT_ID", nil)
  def cf_api_token  = env("CF_API_TOKEN", nil)
  def cf_gateway_id = env("CF_GATEWAY_ID", "creature")
  def cf_base_url   = env("CF_API_BASE", "https://api.cloudflare.com/client/v4")
  def provider_configured? = !cf_account_id.to_s.empty? && !cf_api_token.to_s.empty?

  # --- 複雑性の上限（淘汰の圧力） ----------------------------------------
  def max_dynamic_routes  = int("MAX_DYNAMIC_ROUTES", 12)
  def max_voice_templates = int("MAX_VOICE_TEMPLATES", 8)
  def max_active_wraps    = int("MAX_ACTIVE_WRAPS", 6)

  def ensure_dirs!
    [data_dir, journal_dir, mutation_dir, exhibit_dir, budget_dir,
     tombstone_dir, lock_dir, observation_log_dir].each do |d|
      FileUtils.mkdir_p(d)
    end
  end
end
