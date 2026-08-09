# frozen_string_literal: true

# 自分で作った分類。
#
# 不変にすべきなのは無害化であって、分類ではない。
# 「読めない文字を落とす」は身体法則、「これを何と呼ぶか」は人格である。
#
# ただし安全に関わる family は上書きさせない。secret_probe を
# 「親しみのある場所」と呼べてしまうと、分類が担っている防御が崩れる。
# 学習した分類が効くのは、もともと曖昧だったものに対してだけ。
module LearnedFamilies
  MAX = 8
  MAX_NAME = 24
  # ここに落ちたものだけが、自分の言葉で呼び直される。
  OVERRIDABLE = %w[unknown imagined_place question].freeze
  # 見えなくしてよいのも、この範囲だけ。
  BLINDABLE = %w[imagined_place question unknown].freeze
  SHAPES = %w[prefix suffix contains script max_length].freeze
  SCRIPTS = %w[japanese latin digits].freeze

  @mutex = Mutex.new
  @families = []   # [{ name, match: {shape => value}, psyche: {state => delta} }]
  @blind = []      # 見ないことにした family

  module_function

  def all = @mutex.synchronize { @families.dup }
  def names = @mutex.synchronize { @families.map { |f| f["name"] } }
  def count = @mutex.synchronize { @families.length }
  def blind = @mutex.synchronize { @blind.dup }

  def add(family)
    @mutex.synchronize { @families = (@families.reject { |f| f["name"] == family["name"] } + [family]).last(MAX) }
  end

  def remove(name)
    @mutex.synchronize { @families.reject! { |f| f["name"] == name } }
  end

  def blind!(name)
    @mutex.synchronize { @blind = (@blind + [name]).uniq.last(6) }
  end

  def snapshot = @mutex.synchronize { [Marshal.load(Marshal.dump(@families)), @blind.dup] }
  def restore(snap) = @mutex.synchronize { @families, @blind = snap }
  def reset! = @mutex.synchronize { @families = []; @blind = [] }

  def known?(name)
    RequestAirlock::BUILT_IN_FAMILIES.include?(name) || names.include?(name)
  end

  # 組み込みの分類のあとに呼ばれる。曖昧だったものにだけ、自分の名前を付ける。
  def classify(path, builtin)
    return "unknown" if blind.include?(builtin)
    return builtin unless OVERRIDABLE.include?(builtin)

    found = all.find { |f| shape_matches?(f["match"], path) }
    return builtin unless found
    return "unknown" if blind.include?(found["name"])

    found["name"]
  end

  def shape_matches?(match, path)
    return false unless match.is_a?(Hash) && match.size == 1

    shape, value = match.first
    body = path.delete_prefix("/")
    case shape
    when "prefix" then path.start_with?(value.to_s)
    when "suffix" then path.end_with?(value.to_s)
    when "contains" then path.include?(value.to_s)
    when "max_length" then path.length <= value.to_i
    when "script"
      case value
      when "japanese" then body.match?(/[\p{Hiragana}\p{Katakana}\p{Han}]/)
      when "latin" then body.match?(/\A[a-z0-9\-_\/]+\z/i)
      when "digits" then body.match?(/\A[0-9\-_\/]+\z/)
      else false
      end
    else false
    end
  rescue StandardError
    false
  end

  # 自分で作った分類が、心理へどう効くか。組み込みと同じ小ささに抑える。
  def psyche_for(name)
    f = all.find { |x| x["name"] == name }
    return nil unless f

    f["psyche"]
  end
end
