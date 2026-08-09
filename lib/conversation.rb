# frozen_string_literal: true

# 404 で問い、次のリクエストを答えとして受け取る。
#
# フォームは作らない。入力面はアドレスバーだけ、という前提を最後まで押し切る。
# 同じ visitor bucket からの次の不在が、指定時間内なら「答え」になる。
#
# 会話状態は短命でよい。bucket 自体が日替わりで消えるので、
# ここで持つのはそれより短い記憶にする。永続化しない。
module Conversation
  TTL = 6 * 60          # 問いが有効な秒数
  MAX_PENDING = 500

  @mutex = Mutex.new
  @pending = {}         # bucket => { question:, path_key:, at: }

  module_function

  def enabled? = Config.conversation?

  # いま誰かに問いかけているか
  def waiting_for(bucket)
    @mutex.synchronize do
      p = @pending[bucket]
      next nil unless p
      next @pending.delete(bucket) && nil if (Clock.now - p[:at]) > TTL

      p
    end
  end

  def ask!(bucket, question, event)
    return nil unless enabled?

    @mutex.synchronize do
      prune!
      @pending[bucket] = { question: question, path_key: event["path_key"],
                           name: event["safe_display_path"], at: Clock.now }
    end
    question
  end

  # 次の不在が答えになる。答えたこと自体が、ふつうのノックより強い観測になる。
  def answer!(bucket, event)
    pending = waiting_for(bucket)
    return nil unless pending
    return nil if pending[:path_key] == event["path_key"] # 同じ名前をもう一度言うのは答えではない

    @mutex.synchronize { @pending.delete(bucket) }

    answer = {
      "kind" => "answer",
      "at" => Clock.iso,
      "asked_about" => pending[:name],
      "asked_about_key" => pending[:path_key],
      "question" => pending[:question],
      "answer" => event["safe_display_path"],
      "answer_key" => event["path_key"],
      "visitor_bucket" => bucket,
      "generation" => Body.generation,
      "body_id" => Body.id
    }
    Observer.record_answer(answer)
    ObservationLog.note("answer", answer)
    answer
  end

  def prune!
    return if @pending.size < MAX_PENDING

    cutoff = Clock.now - TTL
    @pending.delete_if { |_, v| v[:at] < cutoff }
    @pending.shift while @pending.size >= MAX_PENDING
  end

  def pending_count = @mutex.synchronize { @pending.size }

  def reset!
    @mutex.synchronize { @pending = {} }
  end
end
