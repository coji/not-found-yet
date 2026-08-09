# frozen_string_literal: true

# 夢を見た瞬間だけが記録に残ると、「何も起きなかった時間」が消える。
# Journal が判断の記録なら、こちらは到来そのものの記録。
# Airlock を通った後の event だけを 1 行 1 件で追記する。変更不能。
#
# 公開はしない。取り出しは fly ssh 経由だけ（公開 HTTP に窓を作らない）。
module ObservationLog
  MAX_BYTES_PER_DAY = 8 * 1024 * 1024
  KEEP_DAYS = 30

  @mutex = Mutex.new
  @handle = nil
  @day = nil
  @bytes = 0
  @truncated = false

  module_function

  def dir = Config.observation_log_dir
  def path_for(day) = File.join(dir, "#{day}.ndjson")

  # ひとつのストリームに、起きたことを種別付きで流す。
  # kind は observation なら absence / presence / exception / method_refusal、
  # それ以外は boot / gaze / dream / attention_exhausted / gateway_429 / log_truncated。

  # 到来した観測。ObservationEvent は既に kind と at を持っているので、そのまま流す。
  # reflex の経路に乗るため fsync はしない。
  def record(event)
    write(event)
  end

  # 判断の外側で起きたこと。
  def note(kind, payload = {})
    write({ "kind" => kind }.merge(payload.is_a?(Hash) ? payload : { "value" => payload }))
  end

  def write(record)
    return unless Config.observation_log?

    # 既に at / kind を持つ record（ObservationEvent）はそれを優先する。
    line = JSON.generate({
      "at" => Clock.iso,
      "body_id" => Body.id,
      "generation" => Body.generation
    }.merge(record))

    @mutex.synchronize do
      handle = open_for_today
      return if handle.nil?

      # 一日の上限に当たったら、当たったことだけを一度記録して黙る。
      # 記録のために身体を殺さない。
      if @bytes >= MAX_BYTES_PER_DAY
        unless @truncated
          @truncated = true
          handle.puts(JSON.generate("at" => Clock.iso, "kind" => "log_truncated",
                                    "reason" => "daily cap #{MAX_BYTES_PER_DAY} bytes reached"))
        end
        return
      end

      handle.puts(line)
      @bytes += line.bytesize + 1
    end
  rescue StandardError
    # 記録できないこと自体は致命ではない。身体は答え続ける。
    nil
  end

  def open_for_today
    today = Clock.jst_date_string
    return @handle if @handle && @day == today && !@handle.closed?

    @handle&.close
    FileUtils.mkdir_p(dir)
    path = path_for(today)
    @bytes = File.exist?(path) ? File.size(path) : 0
    @truncated = false
    @day = today
    @handle = File.open(path, "a")
    @handle.sync = true # buffer に溜めない。落ちたときに直前が消えるのが一番惜しい
    sweep_old!
    @handle
  rescue StandardError
    @handle = nil
  end

  # 記憶は有限。古い日から捨てる。
  def sweep_old!
    cutoff = Clock.now - (KEEP_DAYS * 24 * 60 * 60)
    Dir.glob(File.join(dir, "*.ndjson")).each do |f|
      day = Clock.parse("#{File.basename(f, '.ndjson')}T00:00:00Z")
      File.delete(f) if day && day < cutoff
    end
  rescue StandardError
    nil
  end

  def close!
    @mutex.synchronize do
      @handle&.close
      @handle = nil
      @day = nil
    end
  end

  def days
    Dir.glob(File.join(dir, "*.ndjson")).sort.map { |f| File.basename(f, ".ndjson") }
  end

  def size_bytes
    Dir.glob(File.join(dir, "*.ndjson")).sum { |f| File.size(f) }
  end
end
