# frozen_string_literal: true

# cold start の再構築。
# 書込み可能な .rb を eval しない。宣言的 JSON manifest だけを正本とし、
# 適用時と同じ validator を通す。破損があれば、そこから先には進まない。
module Replay
  Report = Struct.new(:applied, :skipped, :failed, :fossilized, :reason, keyword_init: true) do
    def to_h
      { applied: applied, skipped: skipped, failed: failed, fossilized: fossilized, reason: reason }
    end
  end

  module_function

  def manifest_paths
    Dir.glob(File.join(Config.mutation_dir, "*.json")).sort
  end

  def run!
    # cold start は空の身体から始まる。可変な registry を全部戻してから、
    # manifest の順に積み直す。ここを忘れると replay が二重に効く。
    EvolutionJournal.prepare_replay!
    DynamicRoutes.reset!
    DynamicRoutes.load!
    ReflexConditions.reset!
    MachineSurfaces.reset!
    LearnedFamilies.reset!
    applied = 0
    skipped = 0
    failed = 0
    prev_manifest = nil
    expected_generation = 1

    manifest_paths.each do |path|
      manifest = Store.read_json(path)
      unless manifest.is_a?(Hash)
        return fossilize!(applied, skipped, failed, "unreadable manifest #{File.basename(path)}")
      end

      # 欠番は「知らない過去がある」ということ。想像で埋めない。
      if manifest["generation"] != expected_generation
        return fossilize!(applied, skipped, failed,
                          "generation gap at #{File.basename(path)} (expected #{expected_generation})")
      end

      expected = prev_manifest ? Store.hash_of(prev_manifest) : nil
      if manifest["prev_hash"] != expected
        return fossilize!(applied, skipped, failed, "hash chain broken at generation #{manifest['generation']}")
      end

      result = TrustedMutator.apply(manifest["intent"], source: :replay,
                                    generation: manifest["generation"], skip_smoke: true)
      case result.status
      when "applied"
        applied += 1
      when "no_change"
        skipped += 1
      else
        return fossilize!(applied, skipped, failed + 1,
                          "generation #{manifest['generation']} no longer applies: #{result.reason}")
      end

      EvolutionJournal.adopt_manifest(manifest)
      prev_manifest = manifest
      expected_generation += 1
    end

    # 再構築後の身体が、そもそも立てるかどうかだけ確認する。
    smoke = TrustedMutator.smoke_test({ "type" => "no_change" })
    return fossilize!(applied, skipped, failed, "post-replay smoke failed: #{smoke['reason']}") if smoke["passed"] != true

    Report.new(applied: applied, skipped: skipped, failed: failed, fossilized: false, reason: nil)
  rescue StandardError => e
    fossilize!(applied || 0, skipped || 0, failed || 0, "replay raised #{e.class}")
  end

  # 壊れた地点以降は適用しない。生きているふりもしない。
  def fossilize!(applied, skipped, failed, reason)
    Body.fossilize!(reason)
    Report.new(applied: applied, skipped: skipped, failed: failed, fossilized: true, reason: reason)
  end
end
