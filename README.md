# Quick LaTeX

LaTeX の数式・テキストを、余白を詰めたベクター画像（PDF）にして、クリップボード（PDF + PNG）へ即コピーする小さな macOS アプリです。
プレビューは入力に合わせてリアルタイム更新されます（TeX 実行は約 0.3 秒）。

## 必要なもの

- macOS 14 以降 / Swift（Xcode）
- TeX Live（`uplatex` と `dvipdfmx`）。自動検出の順序: `/Library/TeX/texbin` → `/usr/local/texlive/<最新年>/bin/*` → `/usr/local/bin` → `/opt/homebrew/bin` → ログインシェルの `command -v uplatex`。見つからない場合は歯車メニューで TeX bin のパスを指定します。
- 任意: `pdftocairo`（poppler。SVG 出力が高速で日本語もパスのまま出力されます）、`dvisvgm`

## ビルドとインストール

```fish
./build.sh            # build/QuickLaTeX.app を作成（ad-hoc 署名）
./build.sh install    # さらに ~/Applications へコピー
open build/QuickLaTeX.app
```

### 別の Mac に入れる

各マシンでソースからビルドします（そのマシンの CPU 向けにビルドされ、Gatekeeper にも引っかかりません）。

事前に必要なもの:

- TeX Live（MacTeX など）
- Swift: `xcode-select --install`（Command Line Tools）または Xcode
- VS Code 拡張も入れる場合: Node.js（`npx` を使用）と、VS Code の `code` コマンド（コマンドパレット →「Shell Command: Install 'code' command in PATH」）

```fish
git clone https://github.com/mioupa/quick_latex.git
cd quick_latex
./build.sh install    # アプリを ~/Applications へ
./build.sh vscode     # VS Code 拡張をインストール（不要なら省略）
open ~/Applications/QuickLaTeX.app
```

更新するときは `git pull` してから同じコマンドを再実行します。プリアンブル（`~/Library/Application Support/QuickLaTeX/preamble.tex`）はマシンごとの設定なので、揃えたい場合はこのファイルをコピーしてください。

## 使い方

| 操作 | キー |
| --- | --- |
| どこからでもウィンドウを呼び出して入力欄にフォーカス | ⌃⌥L（グローバル。アクセシビリティ権限は不要） |
| 画像をコピー（PDF + PNG） | ⌘↩ |
| SVG をコピー | ⇧⌘C |
| プリアンブル編集 | ⌘, |
| アプリを隠す（直前のアプリへ戻る） | Esc（入力欄内） / ⌘H |
| ウィンドウを閉じる（アプリは常駐） | ⌘W |

- モード: **数式**（`$\displaystyle ... $`）/ **インライン**（`$ ... $`）/ **テキスト**（16cm 幅の段落、入力はそのまま TeX に渡します）。
- **数式モードの自動判定**（コメント `%` は無視し、`{}` や環境の外側＝最上位だけを見ます）:
  - `\[ … \]`、`$$ … $$`、`align` / `equation` / `gather` / `multline` / `flalign` / `alignat` / `eqnarray` / `empheq` / `subequations` が最上位にあれば（先頭でなくても）、その入力をそのまま段落として組みます。
  - 環境なしで最上位に `&` があれば `align*`、`\\` だけなら `gather*` で自動的に囲みます（`\&` は対象外、`pmatrix` / `cases` / `aligned` / `{ }` の中の `&` `\\` も対象外）。
  - **数式モードでは式番号は付きません**（`align` → `align*` のように最上位の番号付き環境は星付きに置き換え、`empheq` の `{align}` も `{align*}` にします。`\tag{}` は有効）。番号が欲しいときは **テキストモード** を使ってください（入力はそのまま、番号も付きます）。
  - インラインモードでも、上のどれかを検出したら数式モードと同じ扱いになります。
- 文字サイズは pt 指定（TeX の基準 10pt に対する倍率で拡縮。TeX は再実行しません）。余白は出力 pt 単位。
- プレビューはドラッグして他のアプリへ PDF として落とせます。
- プリアンブル（`\usepackage` など）は設定画面から編集できます。実体は共有ファイル `~/Library/Application Support/QuickLaTeX/preamble.tex` です（初回起動時に作成。以前 UserDefaults に保存していた内容は自動で移行）。他のエディタや VS Code で編集した場合も、アプリをアクティブにした時点で再読み込みして再コンパイルします。変更すると TeX フォーマットを再構築します（初回・変更直後のみ少し遅くなります）。
- 「コピー後にウィンドウを隠す」を有効にすると、コピー直後に直前のアプリへ ⌘V できます。

## コマンドライン

GUI を出さずに同じエンジンで書き出します（VS Code 拡張もこれを使います）。

```fish
set Q build/QuickLaTeX.app/Contents/MacOS/QuickLaTeX
$Q --render '\frac{a}{b}' --mode display --color D0021B --size 20 --padding 2 --out /tmp/eq.pdf --png /tmp/eq.png --svg /tmp/eq.svg --copy
$Q --source-file /tmp/eq.tex --json --png /tmp/eq.png
```

| オプション | 説明 |
| --- | --- |
| `--render <src>` / `--source-file <path>` | 入力（直接 / UTF-8 ファイル） |
| `--mode display\|inline\|text`、`--color RRGGBB`、`--size`、`--padding` | 描画設定 |
| `--preamble-file <path>` | プリアンブルを指定（省略時は共有の `preamble.tex`） |
| `--out` / `--png` / `--svg` | PDF / PNG / SVG の書き出し先 |
| `--copy` / `--copy-svg` | クリップボードへ（PDF+PNG / SVG。同時指定は不可） |
| `--json` | 結果を 1 行の JSON だけで標準出力へ（下記） |
| `--print-preamble-path` | 共有プリアンブルのパスを表示（なければ作成） |
| `--self-test` | 数式モードの判定ロジックのセルフテスト |

`--json` の出力:

```
{"ok":true,"seconds":0.29,"formatBuilt":false,"width":166.25,"height":52.0,"pdf":"/abs/out.pdf","png":null,"svg":null}
{"ok":false,"message":"Undefined control sequence.","context":"l.1 \\fracc{1}{2}","line":1,"region":"source"}
```

`line` は `region`（`source` または `preamble`）内の 1 始まりの行番号です。成功なら終了コード 0、TeX エラーは 1、引数エラーは 2。実行中の一時ディレクトリ（`job-cli-<pid>`）は終了時に削除されます。
複数のプロセス（アプリと CLI の同時実行など）が同時に TeX フォーマットを作っても壊れないよう、フォーマットは一時ディレクトリに作ってからリネームします。

## VS Code 拡張

`vscode-extension/` に拡張「Quick LaTeX」があります（エンジンの CLI を同梱）。補完は LaTeX Workshop に任せ、スクラッチファイルのライブプレビューと、選択範囲／カーソル位置の数式のコピーを行います。

```fish
./build.sh vscode    # アプリをビルド → バイナリを同梱して署名 → vsix を作成 → code --install-extension
```

インストール後は VS Code のウィンドウをリロードしてください。使い方は `vscode-extension/README.md` を参照。

## メモ・制限

- 日本語は uplatex の標準（原ノ味明朝）で動作します。`\text{日本語}` が使えます。
- SVG は `pdftocairo` があれば PDF から変換（日本語もパス化されます）。なければ `dvisvgm --no-fonts` にフォールバックしますが、約 1.5 秒かかり、日本語フォントは埋め込めません（日本語が欠けることがあります）。
- キャッシュは `~/Library/Caches/QuickLaTeX/` にあります（削除しても自動で再生成されます）。
- 設定は UserDefaults（`local.quicklatex`）に保存されます（プリアンブルだけは共有ファイル）。
- 署名は ad-hoc です。別のマシンへコピーした場合は初回に右クリックから開く必要があります。
