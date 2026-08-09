# frozen_string_literal: true

# Creature が「獲得した機能」だけを数える registry。
# Sinatra の catch-all が存在することと、機能を持っていることは別。
# route entry 自体を Sinatra から取り除くより、安定した proxy route と
# active flag を使う方が rollback しやすい。
module DynamicRoutes
  # Agent が上書きできない path。観測窓と運用者の領域。
  RESERVED = %w[/ /status /mutations /robots.txt /favicon.ico /app.css /health].freeze
  PATH_PATTERN = %r{\A/[a-z0-9][a-z0-9\-_/]{0,47}\z}
  MAX_LINES = 12
  MAX_LINE_CHARS = 200

  @mutex = Mutex.new
  @routes = {}      # path => entry
  @tombstones = {}  # path_key => { path, retired_at, gone }

  module_function

  def load!
    @mutex.synchronize do
      stored = Store.read_json(tombstone_path, {}) || {}
      @tombstones = stored.is_a?(Hash) ? stored : {}
    end
    self
  end

  def tombstone_path = File.join(Config.tombstone_dir, "routes.json")

  def valid_path?(path)
    return false unless path.is_a?(String)
    return false unless path.match?(PATH_PATTERN)
    return false if reserved?(path)
    return false if path.include?("//") || path.end_with?("/")

    true
  end

  def reserved?(path) = RESERVED.include?(path)

  def add(path:, title:, lines:, content_type:, generation:)
    entry = {
      "path" => path,
      "path_key" => RequestAirlock.path_key(path),
      "title" => title.to_s[0, 60],
      "lines" => Array(lines).first(MAX_LINES).map { |l| l.to_s[0, MAX_LINE_CHARS] },
      "content_type" => content_type,
      "generation" => generation,
      "active" => true,
      "created_at" => Clock.iso,
      "retired_at" => nil,
      "gone" => false
    }
    @mutex.synchronize { @routes[path] = entry }
    entry
  end

  # 失うことも変化である。gone なら 410、そうでなければただの 404 に戻る。
  def retire(path, gone: true, generation: nil)
    entry = @mutex.synchronize { @routes[path] }
    return nil unless entry

    @mutex.synchronize do
      entry["active"] = false
      entry["retired_at"] = Clock.iso
      entry["gone"] = gone
      entry["retired_generation"] = generation
      @tombstones[entry["path_key"]] = {
        "path" => path, "retired_at" => entry["retired_at"], "gone" => gone
      }
    end
    persist_tombstones!
    entry
  end

  def lookup(path)
    entry = @mutex.synchronize { @routes[path] }
    entry if entry && entry["active"]
  end

  # 「なかった」と「失った」を区別する。
  def previously_existed?(path_key)
    @mutex.synchronize do
      t = @tombstones[path_key]
      !t.nil? && t["gone"] == true
    end
  end

  def active = @mutex.synchronize { @routes.values.select { |r| r["active"] } }
  def all = @mutex.synchronize { @routes.values.dup }
  def count = active.length
  def lost = @mutex.synchronize { @routes.values.reject { |r| r["active"] } }

  def render(entry, event = nil)
    ctx = VoiceTemplate.context(event)
    entry["lines"].map { |l| VoiceTemplate.fill(l, ctx) }.join("\n")
  end

  # rollback 用。registry 全体を丸ごと戻す。
  def snapshot = @mutex.synchronize { Marshal.load(Marshal.dump(@routes)) }

  def restore(snapshot)
    @mutex.synchronize { @routes = snapshot }
  end

  def persist_tombstones!
    snapshot = @mutex.synchronize { @tombstones.dup }
    Store.write_json!(tombstone_path, snapshot)
  rescue StandardError
    nil
  end

  def reset!
    @mutex.synchronize do
      @routes = {}
      @tombstones = {}
    end
  end
end
