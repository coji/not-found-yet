# frozen_string_literal: true

require "securerandom"

# 身体の識別。PID だけでは再起動を識別しないので、cold start ごとに
# 新しい UUID を作り、メモリだけに置く。Fly の suspend / resume では
# memory snapshot が復元されるため、同じ body_id の「睡眠」になる。
module Body
  ID = SecureRandom.uuid
  BOOTED_AT = Time.now.utc
  PID = Process.pid

  @mode = nil
  @mode_reason = nil
  @previous_id = nil

  module_function

  def id = ID
  def short_id = ID.delete("-")[0, 4].upcase
  def pid = PID
  def booted_at = BOOTED_AT
  def uptime_sec = (Time.now.utc - BOOTED_AT).to_i

  def generation = EvolutionJournal.current_generation

  def previous_id = @previous_id

  def previous_id=(value)
    @previous_id = value
  end

  # 起動時は Config の EVOLUTION_MODE。replay 中の破損などで
  # 実行中に fossil へ落とすことはできるが、fossil から alive へは戻せない。
  def mode
    @mode ||= Config.evolution_mode
  end

  def alive? = mode == "alive"
  def fossil? = !alive?

  def fossilize!(reason)
    @mode = "fossil"
    @mode_reason = reason
  end

  def mode_reason = @mode_reason

  # cold start か、suspend からの復帰かを自己記述に使う。
  def inherited_alterations? = !@previous_id.nil? && @previous_id != ID

  # 前の身体の名前を引き継ぎ、今の身体の名前を置いていく。
  # suspend / resume ではこの経路を通らないので、同じ身体のままになる。
  def begin_life!
    @previous_id = (Store.state_read("body", {}) || {})["id"]
    Store.state_update("body") do |_|
      { "id" => ID, "booted_at" => Clock.iso(BOOTED_AT), "pid" => PID }
    end
    self
  end
end
