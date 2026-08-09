# frozen_string_literal: true

require "json"
require "fileutils"
require "digest"

# JSON の追記と atomic rename、そして volume 上の flock だけを担当する。
# 仕様書の推奨ファイル構成にはないが、Journal / BudgetGuard / Psyche が
# 同じ永続化規則を共有するために切り出した不可変インフラ。
module Store
  module_function

  def read_json(path, default = nil)
    return default unless File.exist?(path)

    JSON.parse(File.read(path, encoding: "UTF-8"))
  rescue JSON::ParserError, Errno::ENOENT
    default
  end

  # tmp へ書いて fsync してから rename する。途中で電源が落ちても
  # 「半分書けた JSON」を残さない。
  def write_json!(path, obj)
    FileUtils.mkdir_p(File.dirname(path))
    tmp = "#{path}.tmp.#{Process.pid}.#{rand(1 << 32)}"
    File.open(tmp, "wb") do |f|
      f.write(JSON.pretty_generate(obj))
      f.flush
      f.fsync
    end
    File.rename(tmp, path)
    obj
  ensure
    File.delete(tmp) if tmp && File.exist?(tmp)
  end

  def with_file_lock(name)
    FileUtils.mkdir_p(Config.lock_dir)
    path = File.join(Config.lock_dir, name)
    File.open(path, File::RDWR | File::CREAT, 0o644) do |f|
      f.flock(File::LOCK_EX)
      begin
        yield
      ensure
        f.flock(File::LOCK_UN)
      end
    end
  end

  # 排他が取れなければ即座に nil を返す（LLM 呼出の同時実行を 1 に保つ用）。
  def try_file_lock(name)
    FileUtils.mkdir_p(Config.lock_dir)
    path = File.join(Config.lock_dir, name)
    f = File.open(path, File::RDWR | File::CREAT, 0o644)
    unless f.flock(File::LOCK_EX | File::LOCK_NB)
      f.close
      return nil
    end
    begin
      yield
    ensure
      f.flock(File::LOCK_UN)
      f.close
    end
  end

  def next_sequence(dir, ext)
    FileUtils.mkdir_p(dir)
    last = Dir.glob(File.join(dir, "*#{ext}"))
             .map { |p| File.basename(p, ext).to_i }
             .max || 0
    last + 1
  end

  def sequence_path(dir, seq, ext)
    File.join(dir, format("%06d%s", seq, ext))
  end

  def hash_of(obj)
    "sha256:#{Digest::SHA256.hexdigest(JSON.generate(obj))}"
  end

  # state.json は複数の module が別々の key を持つ。
  # 読んで直して書くまでを lock で囲む。
  def state_read(key, default = nil)
    (read_json(Config.state_path, {}) || {}).fetch(key, default)
  end

  def state_update(key)
    with_file_lock("state.lock") do
      all = read_json(Config.state_path, {}) || {}
      all[key] = yield(all[key])
      write_json!(Config.state_path, all)
      all[key]
    end
  end
end
