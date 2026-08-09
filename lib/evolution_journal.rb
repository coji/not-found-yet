# frozen_string_literal: true

# 事実、解釈、選択、費用、適用結果、rollback、傷跡を追記保存する。
# ここは消さない。失敗も、拒否も、何もしなかった夜も残す。
module EvolutionJournal
  SCHEMA_VERSION = "1"

  @mutex = Mutex.new
  @entries = []          # メモリ上の索引（表示用）
  @manifests = []        # 適用済み mutation（replay の正本）
  @loaded = false

  module_function

  def journal_dir  = Config.journal_dir
  def mutation_dir = Config.mutation_dir
  def exhibit_dir  = Config.exhibit_dir

  def load!
    @mutex.synchronize do
      @entries = Dir.glob(File.join(journal_dir, "*.json")).sort.filter_map { |p| Store.read_json(p) }
      @manifests = Dir.glob(File.join(mutation_dir, "*.json")).sort.filter_map { |p| Store.read_json(p) }
      @loaded = true
    end
    self
  end

  def entries
    load! unless @loaded
    @mutex.synchronize { @entries.dup }
  end

  def manifests
    load! unless @loaded
    @mutex.synchronize { @manifests.dup }
  end

  # generation は「適用された mutation の数」。
  # 拒否や rollback では増えない。増えたということは、身体が変わったということ。
  def current_generation
    load! unless @loaded
    @mutex.synchronize { @manifests.length }
  end

  def next_seq = Store.next_sequence(journal_dir, ".json")

  # 一件の判断を、その結末ごと残す。
  def append(decision:, result:, cost:, source: :dream)
    load! unless @loaded
    seq = nil
    entry = nil

    @mutex.synchronize do
      seq = @entries.length + 1
      applied = result.status == "applied"
      prev = @entries.last

      entry = {
        "schema_version" => SCHEMA_VERSION,
        "seq" => seq,
        "at" => Clock.iso,
        "body_id" => Body.id,
        "body_short_id" => Body.short_id,
        "pid" => Process.pid,
        "source" => source.to_s,
        "generation_before" => @manifests.length,
        "generation_after" => applied ? @manifests.length + 1 : @manifests.length,
        "attempted_generation" => result.generation,
        "status" => result.status,
        "reason" => result.reason,
        "observation_summary" => decision["observation_summary"],
        "interpretation" => decision["interpretation"],
        "dominant_desire" => decision["dominant_desire"],
        "psyche" => Psyche.state,
        "intent" => result.intent,
        "intent_description" => result.intent.is_a?(Hash) ? MutationIntent.describe(result.intent) : nil,
        "candidates" => decision["candidates"],
        "choice_index" => decision["choice_index"],
        "sacrifice" => decision["sacrifice"],
        "fitness_hypothesis" => decision["fitness_hypothesis"],
        "cost" => cost,
        "smoke" => result.smoke,
        "pid_stable" => result.pid_stable,
        "prev_hash" => prev ? Store.hash_of(prev) : nil,
        "prompt_version" => decision["prompt_version"],
        "compiler_version" => TrustedMutator::COMPILER_VERSION
      }

      Store.write_json!(Store.sequence_path(journal_dir, seq, ".json"), entry)
      @entries << entry

      if result.exhibit
        File.write(Store.sequence_path(exhibit_dir, seq, ".rb"),
                   "# display only. never replayed.\n# seq #{seq} · status #{result.status}\n\n#{result.exhibit}")
      end

      if applied
        manifest = {
          "schema_version" => SCHEMA_VERSION,
          "generation" => @manifests.length + 1,
          "journal_seq" => seq,
          "at" => entry["at"],
          "intent" => result.intent,
          "compiler_version" => TrustedMutator::COMPILER_VERSION,
          "prev_hash" => @manifests.last ? Store.hash_of(@manifests.last) : nil,
          "result" => { "status" => "applied", "pid_stable" => result.pid_stable }
        }
        Store.write_json!(Store.sequence_path(mutation_dir, manifest["generation"], ".json"), manifest)
        @manifests << manifest
      end
    end

    Psyche.observe_mutation!(entry["status"].to_sym) if %w[applied rolled_back rejected].include?(entry["status"])
    Fitness.begin_window!(entry) if entry["status"] == "applied"
    entry
  end

  # replay 前。過去の記録は読むが、manifest は「まだ適用されていない」状態に戻す。
  # generation は再構築が進むにつれて増えていく。
  def prepare_replay!
    load!
    @mutex.synchronize { @manifests = [] }
    self
  end

  # replay 中に外から manifest を積む（ファイルは既にある）。
  def adopt_manifest(manifest)
    @mutex.synchronize { @manifests << manifest }
  end

  # 傷跡。消さずに、次の判断材料として渡す。
  def scars(limit = 5)
    entries.reverse
           .select { |e| %w[rolled_back rejected].include?(e["status"]) }
           .first(limit)
           .map do |e|
             { "at" => e["at"], "status" => e["status"], "reason" => e["reason"],
               "intent" => e["intent_description"] }
           end
  end

  def recent_summaries(limit = 7)
    entries.reverse.first(limit).map do |e|
      {
        "seq" => e["seq"], "status" => e["status"],
        "intent" => e["intent_description"],
        "desire" => e["dominant_desire"],
        "interpretation" => e["interpretation"].to_s[0, 140],
        "fitness" => e["fitness"]
      }
    end
  end

  def find(seq)
    entries.find { |e| e["seq"] == seq }
  end

  def exhibit(seq)
    path = Store.sequence_path(exhibit_dir, seq, ".rb")
    File.exist?(path) ? File.read(path) : nil
  end

  # fitness を後から書き戻す（遅延評価）。
  def record_fitness!(seq, score, detail)
    path = Store.sequence_path(journal_dir, seq, ".json")
    entry = Store.read_json(path)
    return nil unless entry

    entry["fitness"] = score
    entry["fitness_detail"] = detail
    entry["fitness_at"] = Clock.iso
    Store.write_json!(path, entry)
    @mutex.synchronize do
      idx = @entries.index { |e| e["seq"] == seq }
      @entries[idx] = entry if idx
    end
    entry
  end

  def total_spent_usd
    entries.sum { |e| e.dig("cost", "attention_usd").to_f }.round(4)
  end

  def reset!
    @mutex.synchronize do
      @entries = []
      @manifests = []
      @loaded = true
    end
  end
end
