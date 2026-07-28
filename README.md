# claude-toolkit

個人用に作成した [Claude Code](https://claude.com/claude-code) のツールキット。
スキル・statusline など、Claude Code をカスタマイズする設定一式をまとめている。

特定プロジェクト向けの慣習（ブランチ運用・PR 規約など）を前提にした記述を含むため、
利用する際は自分の環境に合わせて調整すること。

## 構成

```
claude-toolkit/
├── skills/       # Claude Code スキル集
└── statusline/   # カスタム statusline（レートリミット表示付き）
```

## skills/

開発フロー（GitHub Issue 起点の実装、PR レビュー / 説明生成、日次レポート、
プロンプト改善）を補助する自作スキル。

| スキル | 概要 |
| --- | --- |
| `imp` | GitHub Issue を起点に、仕様の深掘り → Issue 整理 → 実装計画 → TDD 実装を進める。 |
| `pr-review` | プルリクエストを多角的な観点でレビューする。 |
| `pr-description` | PR の実装内容を分析し、フロントエンド開発者向けの使い方ガイドを含む説明文を生成・更新する。 |
| `daily-report` | マージ済み PR・オープン PR・メンバー別の着手推奨を一気通貫で表示する日次レポート。 |
| `empirical-prompt-tuning` | agent 向けテキスト指示を、バイアスを排した実行者に動かしてもらい両面で評価して反復改善する手法。 |

各スキルの詳細は `skills/<skill>/SKILL.md` を参照。

### インストール

Claude Code はグローバルスキルを `~/.claude/skills/` から読み込む。
使いたいスキルのディレクトリをそこに置く（シンボリックリンク推奨）。

```bash
git clone https://github.com/EnjoyKojima/claude-toolkit.git
cd claude-toolkit

# 例: imp と pr-review だけ使う
ln -s "$PWD/skills/imp"       ~/.claude/skills/imp
ln -s "$PWD/skills/pr-review" ~/.claude/skills/pr-review
```

シンボリックリンクにしておくと、リポを `git pull` するだけで最新版が反映される。

## statusline/

Claude Code のカスタム statusline。最大4行構成で以下を表示する。

```
🤖 Fable 5 │ 📊 42% │ ✏️  +120/-30 │ 🔀 feature/foo
⏱ 5h  ▰▰▰▱▱▱▱▱▱▱  32%  -18%  Resets 3pm (Asia/Tokyo) · in 1h23m
📅 7d  ▰▰▰▰▰▱▱▱▱▱  51%  +4%   Resets Jul 20 at 9am (Asia/Tokyo) · in 2d5h
✨ Fable  ▰▰▰▰▱▱▱▱▱▱  35%  -26%  Resets Jul 20 at 8am (Asia/Tokyo) · in 2d4h
```

- **1行目**: モデル名 / コンテキスト使用率 / 追加・削除行数 / gitブランチ
- **2〜3行目**: 5時間・7日間のレートリミット使用率（プログレスバー + ペース差分 + リセット時刻・残り時間）
- **4行目**: モデル別週次枠（Fable 等、アカウントに枠がある場合のみ表示）

ペース差分（`-18%` / `+4%`）は「ウィンドウの経過時間から見た本来の消費ペース」との差。
マイナス（緑）はペースより余裕あり、プラス（赤）はペース超過を意味する。

5h/7d のレートリミットは Haiku への極小リクエスト（`max_tokens: 1`、1トークン）の
レスポンスヘッダーから取得し、360秒キャッシュする。モデル別週次枠は OAuth usage API
から取得し、60秒キャッシュをバックグラウンド更新する（描画はブロックしない）。
認証は各自の Claude Code ログイン情報
（macOS Keychain / `~/.claude/.credentials.json`）を使う。

### インストール

依存: `jq`（macOS: `brew install jq`）

```bash
curl -fsSL https://raw.githubusercontent.com/EnjoyKojima/claude-toolkit/master/statusline/install.sh | bash
```

またはクローン済みなら:

```bash
bash statusline/install.sh
```

`~/.claude/statusline-command.sh` にスクリプトをコピーし、
`~/.claude/settings.json` に `statusLine` 設定をマージする（他の設定は保持）。
Claude Code を再起動すると反映される。

### カスタマイズ

環境変数で挙動を変えられる（`settings.json` の `command` に前置きして指定）。

| 環境変数 | 効果 |
| --- | --- |
| `STATUSLINE_TZ` | リセット時刻のタイムゾーン（デフォルト: `Asia/Tokyo`） |
| `RUNCAT_CLAUDE_OUT_FILE` | 設定すると [RunCat Neo](https://runcat.app/) 用のカスタムメトリクス JSON をそのパスに書き出す |

例:

```json
{
  "statusLine": {
    "type": "command",
    "command": "RUNCAT_CLAUDE_OUT_FILE=$HOME/.claude/runcat-usage.json bash ~/.claude/statusline-command.sh"
  }
}
```
