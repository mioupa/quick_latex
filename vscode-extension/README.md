# Quick LaTeX（VS Code 拡張）

LaTeX の数式を、余白を詰めたベクター画像にして **クリップボード（PDF + PNG / SVG）へコピー**します。
エンジンは macOS アプリ「Quick LaTeX」の CLI を同梱しています（`bin/quicklatex`、Apple Silicon / macOS 専用）。
補完は LaTeX Workshop に任せています。

## 使い方

1. コマンドパレットで **Quick LaTeX: 開く**。`~/Library/Application Support/QuickLaTeX/scratch.tex` と、横にプレビューが開きます。
2. scratch.tex に数式を書くと保存しなくてもプレビューが更新されます（250ms デバウンス）。
3. **⌘↩**（scratch.tex 上・プレビュー上）で PDF + PNG をコピー、**⇧⌘↩** で SVG をコピー。

他の `.tex` / `.md` から:

| 操作 | 結果 |
| --- | --- |
| 選択して **⌘⌥↩** | 選択範囲を描画。`$…$` `\(…\)` はインライン、`$$…$$` `\[…\]` は数式（区切りは除去）、`\begin{align*}…\end{align*}` はそのまま |
| 選択せず **⌘⌥↩** | カーソル位置の数式（`\begin{align*}…`、`\[…\]`、`$$…$$`、`\(…\)`、同じ行の `$…$`）を探して描画。なければ警告 |

コマンド: 開く / 画像をコピー / SVGをコピー / プリアンブル編集（共有の `preamble.tex` を開きます）。

## 設定（ユーザー設定）

`quickLatex.mode`（display / inline / text）、`quickLatex.color`（RRGGBB）、`quickLatex.fontSize`（pt）、`quickLatex.padding`（pt）、`quickLatex.binaryPath`（空欄で同梱バイナリ）。
プレビュー上部のツールバーからも変更できます。

## 数式モードの挙動

数式モードでは番号は付きません（`align` などは自動で `align*` 相当）。`&` や `\\` を書けば自動で `align*` / `gather*` になります。
番号が欲しいときはテキストモードを使ってください。

## プリアンブル

アプリと共通の `~/Library/Application Support/QuickLaTeX/preamble.tex` を使います。保存するとプレビューが再描画されます。
エラーは scratch.tex / preamble.tex の該当行に診断（赤線）として出ます。

## LaTeX Workshop との関係

scratch.tex には `\documentclass` がなく、ワークスペース外にあるため、LaTeX Workshop のどのルートファイルにも属しません。
既定の設定（`latex.autoBuild.run` = `onFileChange`）では scratch.tex を保存しても自動ビルドは走りません（確認済み）。
`latex.autoBuild.run` を `onSave` にしている場合のみ、保存時に「現在のルートファイル」がビルドされることがあります。その場合は
`latex-workshop.latex.autoBuild.onSave.files.ignore` に `**/QuickLaTeX/scratch.tex` を追加してください。

## インストール

### ビルド済みの拡張を入れる（TeX Live と VS Code だけ）

Swift も Node.js も不要です（macOS 14 以降、Apple Silicon / Intel）。

```fish
curl -LO https://github.com/mioupa/quick_latex/releases/latest/download/quick-latex.vsix
code --install-extension quick-latex.vsix
```

その後 VS Code のウィンドウをリロード（「Developer: Reload Window」）します。
ブラウザで [Releases](https://github.com/mioupa/quick_latex/releases) から `.vsix` をダウンロードして「拡張機能: VSIX からのインストール…」で入れても構いません（同梱エンジンの隔離フラグは拡張が起動時に自分で外します）。

必要なもの: TeX Live（`uplatex` / `dvipdfmx`。MacTeX の `/Library/TeX/texbin` は自動検出）。補完用に LaTeX Workshop を推奨。
更新も同じコマンドを再実行します。

### ソースからビルドして入れる（リポジトリのルートで）

```fish
./build.sh vscode     # このマシン向けにビルドして vsix を作成し、そのままインストール
./build.sh release    # 配布用 universal vsix（build/quick-latex.vsix）を作成。Xcode 本体が必要、インストールはしない
```

アプリのビルド → バイナリを `bin/` へコピーして ad-hoc 署名 → vsix 作成 → `code --install-extension` まで行います（`release` は universal ビルドと vsix 作成のみ）。
インストール後は VS Code のウィンドウをリロード（「Developer: Reload Window」）してください。
