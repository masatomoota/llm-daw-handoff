# LLM-Driven DAW Project — Master Handoff

> **ABSTRACT (English, for any LLM picking this up cold):** This is the *master* orchestration document for the LLM-driven DAW project. The goal is **100% natural-language control of a Digital Audio Workstation** — the audio-app analogue of Codex/Cursor for code. Work is split across **three GitHub repos** (Ardour fork, Audacity blueprint, Electron companion). Each repo has its own focused handoff; **this document is the cross-cutting one** — the chronological narrative, the decision tree, the reasoning behind every choice, the *current* state vs the **100%** definition, and a prioritized, file-level task list so a fresh LLM can pick up the next task without asking the user any historical question. Prose is Japanese (technical identifiers in English). Every claim carries a citation: `file:line`, commit SHA, or section reference. If you only have 5 minutes, read §0 and §11. To start working immediately, read §8 (auto-start protocol) and pick a task from §7.

---

## §0. このドキュメントの位置づけ

本書は**プロジェクト全体のオーケストレーション文書**。3つのリポジトリ（`masatomoota/ardour`, `masatomoota/audacity`, `masatomoota/ardour-mcp-chat`）にそれぞれ存在する詳細ハンドオフを束ね、**横断的な事実**——どういう経緯でここに至ったか、なぜそう決めたか、次に何を作れば「100%」に近づくか——を提供する。

各リポのハンドオフは「そのリポの中で次に何をするか」を教える。本書は「どのリポの何から手を付けるか」を教える。

> **重要原則**：本書は「次のLLMが**ユーザーに歴史を尋ねずに**自律的に着手できる」ことを最優先に書かれている。記載が冗長に見えても、それは「次のLLMが推測で動くより、ここを読んで確信を持って動くほうが結果が良い」という判断による。

---

## §1. ミッションと「100%」の定義

### 1.1 プロジェクトの最終ゴール
「VSCode における Codex のように、**言葉で指示して操作する DAW** を作る」。録音・編集・ミックス・エフェクト・納品の音楽制作 5 工程すべてを自然言語で完結できる状態を「100%」と呼ぶ。

### 1.2 「100%」の 5 軸内訳
| 軸 | 内容 | 現状 | 目標 |
|---|---|---|---|
| **録音 (Record)** | 録音アーム / 入力モニタ / トランスポート | 部分（アーム可、I/O ルーティング深部は未到達） | 全部 |
| **編集 (Edit)** | クリップ移動・split・MIDIノート編集・マーカー | 強（バルクMIDI JSON 含む） | 微調整のみ |
| **ミックス (Mix)** | フェーダ・パン・センド・**オートメーション** | **致命的欠落**: 瞬時値は OK、時間軸オートメーション ZERO | オートメーション必須 |
| **エフェクト (FX)** | プラグイン追加・パラメータ・プリセット・サイドチェイン | 中（add/param OK、プリセット・サイドチェイン無し） | プリセット + Nyquist 生成 DSP |
| **納品 (Deliver)** | export / bounce / stem / render | **致命的欠落**: ZERO | 必須（最優先） |

→ **「100%」到達には少なくとも (a) 納品ツール群、(b) オートメーション曲線編集、(c) リアルタイム知覚通知**の3つが要る（§7 のT1〜T3に対応）。

### 1.3 「100%」を阻む隠れた要件
- **トランザクション境界**：エージェント1ターン＝1 Undo にまとめないと、エージェントの仕事が部分的に巻き戻せない
- **知覚ループ**：ポーリングだけでは LLM がフェーダ動きやレベル変化を「気づく」のに遅すぎる
- **安全性**：破壊的操作の dry-run / 確認 / autosnapshot がないと無人運用不可
- **シャットダウン耐性**：Ardour がクラッシュしても会話が継続できる

---

## §2. 3つのリポジトリの全体図

```
                   ┌─ Ardour fork (GPLv2-or-later) ─────────────────────────┐
                   │ masatomoota/ardour                                       │
                   │ branch: feature/mcp-fresh-macos                          │
                   │ - libs/surfaces/mcp_http/ (96 tools, ~8200 LOC server)   │
                   │ - Phase 0 hardening (thread marshal + localhost + Host)  │
                   │ - track/get_meter (real-time peak readback)              │
                   │ - macOS arm64 from-Homebrew build (5 wscript fixes)      │
                   │ - MCP_LLM_CONTROL_HANDOFF.md                             │
                   └────────────────┬─────────────────────────────────────────┘
                                    │
                                    │  HTTP POST /mcp (JSON-RPC 2.0,
                                    │   protocolVersion 2025-03-26)
                                    │
                   ┌────────────────▼─────────────────────────────────────────┐
                   │ Electron Companion (MIT) ─ separate process              │
                   │ masatomoota/ardour-mcp-chat                              │
                   │ branch: main                                              │
                   │ - 14 files, ~2,770 LOC                                   │
                   │ - lib/mcp-client.js (fetch JSON-RPC)                     │
                   │ - lib/agent-loop.js (Anthropic tool_use loop, 20-iter)   │
                   │ - main.js holds API key (renderer never sees it)         │
                   │ - vanilla DOM chat UI + markdown + tool cards            │
                   │ - HANDOFF.md                                              │
                   └────────────────┬─────────────────────────────────────────┘
                                    │
                                    │  Anthropic Messages API (over HTTPS)
                                    │
                                    ▼
                         api.anthropic.com (Claude)


                   ┌─ Audacity blueprint (GPLv2-or-later, 3.x base) ──────────┐
                   │ masatomoota/audacity                                      │
                   │ branch: mcp-llm                                           │
                   │ - Phase 0 commands IMPLEMENTED (perception suite incl GetLoudness/GetAudioStats/GetSpectrum) │
                   │ - Targets audacity3 branch (3.x, NOT 4.0-alpha)          │
                   │ - Branch: mcp-llm (consolidated single-repo layout, audacity-mcp/) │
                   │ - GetInfo Type=Commands Format=JSON → tools/list 自動    │
                   └─────────────────────────────────────────────────────────┘
```

### 2.1 各リポの役割
- **Ardour fork**：**現在のメイン作業対象**。MCP サーバ＋ハードニング＋メータが**実機検証済み**（96 tools, Host: evil.example.com→403, track_get_meter live success）。Phase 1〜4 の追加実装はすべてこのリポに来る。
- **Companion (ardour-mcp-chat)**：MCP **クライアント**。Ardour 側拡張に追従して伸ばす（ツール選別 UI、ストリーミング応答、配布など）。MIT なのでクローズド派生も可能。
- **Audacity**：第二の DAW として`mcp-llm` ブランチで実装が進行中。Phase 0 のコマンド（GetLoudness の integrated/short-term/momentary, GetAudioStats の true-peak, GetSpectrum, DetectSilence, DetectOnsets 等の **知覚系コマンド**）が既に実装済み。詳細は `audacity-mcp/MCP_PHASE0_IMPLEMENTATION_HANDOFF.md` と `audacity-mcp/MCP_LLM_CONTROL_HANDOFF.md`。GitHub: `masatomoota/audacity` の `mcp-llm` ブランチ。

---

## §3. 現在の状態（live state）

### 3.1 完了している
- ✅ Ardour MCP HTTP サーバが macOS arm64 でフルビルド成功（`build/gtk2_ardour/ardour-9.7.89`, 73MB, debug build）
- ✅ `libardour_mcp_http.dylib`（2.9MB）が `protocol_descriptor` を export し、Ardour 起動時に dlopen される
- ✅ `127.0.0.1:4820/mcp` でMCP プロトコル `2025-03-26` 応答（`initialize`, `tools/list` = 96 tools, `tools/call`）
- ✅ スレッド整流：lws サービススレッドから `_event_loop->call_slot` 経由で GUI スレッドへマーシャル → Undo 履歴破壊・assert クラッシュなし
- ✅ Localhost bind 固定（`_info.iface = "127.0.0.1"`）→ LAN から到達不可
- ✅ Host ヘッダ検証 → `Host: evil.example.com` で HTTP 403（DNS-rebinding 対策動作確認）
- ✅ `track/get_meter` ツール → master bus の `peak_meter()->meter_level(n, MeterPeak)` を dBFS で返す
- ✅ Electron コンパニオンアプリ：ビルド成功、SDK 解決、MCP クライアント単体テスト OK、Electron 起動 OK
- ✅ Audacity 側 Phase 0：mcp-llm ブランチ（audacity-mcp/）で MCP コマンド実装、特に **知覚系（perception）コマンドが充実**：GetLoudness（LUFS integrated/short-term-max/momentary-max）、GetAudioStats（true-peak、peak、RMS）、GetSpectrum、DetectSilence、DetectOnsets。Ardour 側よりも perception の深さで先行。
- ✅ Audacity の handoff 2 部：`MCP_LLM_CONTROL_HANDOFF.md`（プロジェクト全体）、`MCP_PHASE0_IMPLEMENTATION_HANDOFF.md`（Phase 0 実装詳細）

### 3.2 取り組まれていない（次の作業対象）
- ❌ 納品系（export / bounce / stem）→ **T1（§7）**
- ❌ オートメーション曲線編集 → **T2**
- ❌ サーバ起点の状態通知（SSE / `notifications/*`）→ **T3**
- ❌ テンポ／拍子編集
- ❌ フェード・クロスフェード制御
- ❌ VCA / グループ / サイドチェイン
- ❌ プラグインプリセット保存/呼び出し
- ❌ 波形/スペクトルのサンプル値読み出し
- ❌ ターン制ロック（多段編集の原子性）
- ❌ コンパニオン側：ツール選別UI、ストリーミング、配布パッケージ
- ⚠️ Audacity と Ardour の機能差：Audacity に在って Ardour に無い perception commands（LUFS / spectrum / silence / onset detection）の Ardour 側ポート、または Ardour 側で同等を新規実装

### 3.3 設計済みだが未着手
- **ターン制ロック・モデル（fix_plan v2 §5）**：人間と LLM の編集を排他、自動 snapshot、リース／奪取
- **Win11 ビルド**：MinGW クロスコンパイル前提。`libs/surfaces/mcp_http/wscript` に `_WIN32_WINNT=0x0601` 追加が必要（既存 `websockets/wscript:38-39` に倣う）
- **Audacity `mod-mcp-server`**：3.x（`audacity3` ブランチ）上で `mod-script-pipe` を複製、`GetInfo Type=Commands` から tools/list 自動生成

---

## §4. 経緯のナラティブ（journey）

このセクションは「なぜ今ここにあるか」を語る。次の LLM が**過去の判断を再評価**する時にここを読めばいい。

### 4.1 探索フェーズ（最初）
ユーザーが「VSCodeのCodexのように言葉で指示できるDAWに改造可能か」と聞いてきた。Ardour リポを 11 並列のサブエージェントで網羅調査した結果、**実は既に実験的 MCP-over-HTTP コントロールサーフェスが存在する**ことが判明（`libs/surfaces/mcp_http/`、`mcp_http_server.cc` 約 8,160 行、95 ツール）。これがプロジェクト全体の出発点になった。同時に PDF 4 部を書き出し（作業ホスト `/Volumes/work-ssd-4TB-USB4/_Git_Repository/llm-daw-report/`、本リポからは独立）。

### 4.2 欠陥の発見
既存サーフェスの 3 大欠陥が判明：
1. **スレッド/RT 安全性**：lws サービススレッドから直接 Session を変更 → `HistoryOwner::_current_trans` 無ガードで Undo 履歴破壊／debug ビルドで `assert(false)` クラッシュ
2. **知覚ループ欠如**：オブザーバ / SSE 完全不在、メータ読み出しも無く LLM が結果を観測できない
3. **セキュリティ**：認証なし・平文・**全インタフェース待受**（`_info.iface` 未設定 → `0.0.0.0`）、`endpoint_url()` 表示の `127.0.0.1` と乖離

→ 「fix_plan v2」を PDF で設計（ターン制ロックも含む）。

### 4.3 Audacity 検討
**4.0-alpha では dark-build 問題**を発見：最も豊かな基盤（`au3/src/commands` の `GetInfoCommand` JSON / `mod-script-pipe`）が**ビルドに含まれていない**（`src/au3wrap/CMakeLists.txt:96` が `au3/libraries` のみ取り込み）。結論：**3.x（`audacity3` ブランチ）が安定で着手可**。実装は Ardour 完成後 or 並行のオプションとして handoff のみ作成、リポ `masatomoota/audacity` の `mcp-llm-handoff` ブランチに push 済み。

### 4.4 ライセンス分析
比較した結果：
- **Ardour = GPLv2-or-later で一様**（CLA なし、libwebsockets MIT、商標寛容）→ **公開フォークが軽い**
- **Audacity = GPLv3固定**（Muse フレームワークが GPLv3-only、CLA あり、商標厳しい、Qt LGPL 再リンク義務）→ 配布制約が多い
- **GPL は「無料」ではない**：有料配布も可（§4）、義務は「ソース提供」「自由を制限しない」「表示保持」
- **コンパニオンアプリは MIT**：別プロセスなので GPL 派生しない、ライセンス自由

### 4.5 意思決定：fresh vs harden
ユーザーから「あなたがフルスクラッチで書いた方が手堅いのでは」と問われた。正直に検討：
- 「Audacity フルスクラッチ」は dark-build 問題＋4.0-alpha churn のため**むしろ難しい**
- **Ardour 既存 95 ツールを基盤に Phase 0 だけクリーンルーム是正**が「手堅い × 動く × 安い」
- ユーザー承諾 → Wave 0 開始

### 4.6 Wave 0：macOS ビルド成立
Ardour 公式ビルドは `~/gtk/inst` の自前依存スタック前提だが、Homebrew で代替可能か挑戦。最大の壁：
- `boost` を Homebrew 経由で見つけさせる → `--also-include=/opt/homebrew/include`
- 旧 ABI の C++ バインディング（`glibmm-2.4`, `cairomm-1.0`, `pangomm-1.4`, `atkmm-1.6`）が必要 → Homebrew の `@2.66`/`@1.14`/`@2.46`/`@2.28` で対応
- macOS Mach-O は `__attribute__((alias))` 非対応 → `gdkaliasdef.c` / `gtkaliasdef.c` が爆発 → **`DISABLE_VISIBILITY` マクロを ydk/ytk の wscript に追加**して全 alias 定義を無効化（標準対処）
- Homebrew Lua 5.5 のヘッダが vendored Lua 5.3.5 を shadow → wscript で vendored を CXXFLAGS 先頭に prepend
- `libarchive` keg-only → libardour と control_protocol の uselib に `ARCHIVE` を足す

結果：5 wscript 修正（`libs/tk/ydk/wscript`, `libs/tk/ytk/wscript`, `libs/lua/wscript`, `libs/ardour/wscript`, `libs/ctrl-interface/control_protocol/wscript`）で **`./waf` 1892 ステップが 5 分 3 秒で完走**。commit `0834ec2610`。

### 4.7 Wave 1：ハードニング適用
fix_plan v2 のパッチ 10 個（4 機能）を適用：
1. `_info.iface = "127.0.0.1"`
2. `host_header_is_loopback()` ヘルパ + POST /mcp 受信時の Host チェック
3. `run_tools_call()` 自由関数を抽出 → `tools/call` 全体を `_event_loop->call_slot()` でマーシャル + `std::condition_variable` で同期待ち
4. プラグイン追加の `#ifdef __APPLE__` ブロックに `get_event_loop_for_thread() != _event_loop` ガード（再入デッドロック回避）
5. `track/get_meter` ツール + `meter.h` include

ブレース整合チェック通過、増分ビルド 9 秒、commits `36b0f04fb0`（hardening）と `5129c6d773`（meter）。Wave 2 で**実機 curl 検証パス**（initialize / tools/list / Host=evil→403 / hello_world / track_get_meter）。

### 4.8 Wave 3：Ardour 側 handoff + GitHub 同期
`MCP_LLM_CONTROL_HANDOFF.md`（390行）作成、`masatomoota/ardour` fork に push。commit `2ea50d0292`。

### 4.9 Wave 5：コンパニオンアプリ構築
Electron + バニラJS + @anthropic-ai/sdk で 4 フェーズ Workflow（Scaffold → Implement → Polish → Verify）。Sonnet 実作業。完了：14 ファイル / 2,774 LOC、`masatomoota/ardour-mcp-chat` に push。

**.env インシデント**：Scaffold 段階で Sonnet が `/Volumes/.../_Git_Repository/ardour/` 直下の **既存 `.env`（OpenAI key + SMTP password 含む）** を誤ってコピーし、初回コミットに混入。push 前に検出 → squash で履歴から完全除去 + 両リポ `.gitignore` 更新。**外部流出ゼロ**（remote 未設定だった）。ユーザーには鍵ローテーション推奨済み。

### 4.10 現在（本書執筆時）
ユーザー：「次のLLMが100%に到達できるよう、handoff を経緯含めて完全粒度で作成」→ **本書**。

---

## §5. アーキテクチャ事実集（変更困難な前提）

### 5.1 三重スレッドモデル（Ardour 側）
1. **RT オーディオスレッド**：PortAudio コールバック等。常時動く、ロック取らず、メモリ確保しない、RT セーフでない API 呼べない。`AudioEngine::process_lock()` で RT との競合から構造変更を守る。
2. **GUI / メインスレッド**：GTK イベントループ。Undo 履歴、`PropertyChanged` の最終受信、ダイアログ。
3. **MCP サービススレッド（lws）**：`MCPHttpServer::run()` の `lws_service` ループ。HTTP 受信→`dispatch_jsonrpc()` 呼び出し。Phase 0 ハードニング後は、ここから**直接 Session を変更しない**。`tools/call` 全体を `call_slot()` で GUI スレッドへ整流する。

### 5.2 Ardour のクロススレッド整流の正規機構
- `PBD::EventLoop` (`libs/pbd/pbd/event_loop.h:50`)
- `AbstractUI<T>` (`libs/pbd/pbd/abstract_ui.h:54`)
- `call_slot(InvalidationRecord*, std::function<void()>)` (`event_loop.h:95`) — 別スレッドからの処理をターゲットスレッドへキュー
- `MISSING_INVALIDATOR = nullptr` (`event_loop.h:144`)

→ **これが安全な MCP→GUI スレッド遷移の唯一の手段**。新ツールを追加する際もこれを使うこと。

### 5.3 MCP プロトコル枠
- JSON-RPC 2.0 / `protocolVersion 2025-03-26`
- メソッド：`initialize`, `notifications/initialized`, `ping`, `tools/list`, `tools/call`
- `tools/list` は `tools_json.inc`（コンパイル時 static string）から定数返却
- `tools/call` 結果は `{ "content":[{"type":"text","text":"..."}], "structuredContent": {...}? }` の両方を持つ（テキスト専用 MCP クライアント互換）
- エラーは JSON-RPC error コード（`-32700`/`-32600`/`-32601`/`-32602`/`-32000`）

### 5.4 Ardour ControlProtocol 機構
- 各サーフェスは `.dylib`/`.so` 動的プラグイン
- C リンケージの `protocol_descriptor()` を 1 個 export（`interface.cc:60-64`）
- `ControlProtocolManager`（`libs/ardour`）が dlopen + lifecycle（`set_session` → `activate` → `instantiate` → `set_state`/`set_active` → `drop_protocols`/`teardown`）
- 基底 `ControlProtocol`（`libs/ctrl-interface/control_protocol/control_protocol.h:46`）が `BasicUI` + `Stateful` + `ScopedConnectionList` を多重継承
- mcp_http はこの薄い土台に乗っているが、`AbstractUI` は継承していない（独自 lws スレッドで動く）。これが Phase 0 で整流が必要だった理由。

### 5.5 主要オブジェクトモデル（Ardour）
- **Session** (`session.h:208`)：根。`route_by_id`/`route_by_name`/`stripable_by_*`/`source_by_id`、`begin/commit/abort_reversible_command`、`undo(n)/redo(n)`。
- **PBD::ID** (`pbd/id.h:33`)：64bit 整数の安定識別子。**ただし `ID::ID(string)` は fail-open**（`id.cc:54-58`、コメント "danger, will robinson"）。MCP 層では `is_decimal_pbd_id_string` + guarded helper で塞いだ（`mcp_http_server.cc:253-301`）が、コア側は依然脆い。
- **Route**：`AutomationControl` 派生で gain/pan/solo/mute/rec を一様に制御（`route.h:496-554`）
- **Processor / PluginInsert**：`add_processor`/`remove_processor`/`reorder_processors`、`PluginInsert::set_parameter`/`load_preset`/`add_sidechain`
- **Region / Playlist**：編集の中心。`Playlist::add_region`/`remove_region`/`split_region`/`partition`/`combine`/`uncombine`
- **Location / Locations**：マーカー・範囲・ループ・パンチ
- **TempoMap** (`temporal/tempo.h:785-841`)：copy-on-write の `write_copy` → 編集 → `update`

### 5.6 ビルドシステム
- Ardour: **waf**（Python ベース）+ 自前ヘルパ `tools/autowaf.py`
- ビルドツリー `build/`（gitignored）
- `build/c4che/_cache.py` は configure 出力**生成物・直接編集しない**（再 configure で消える）
- 増分ビルドは速い（数秒〜数十秒）、フルビルドは 5 分（10 コア）
- macOS の依存：**Homebrew + 旧 ABI バインディング @ keg-only**（§4.6）

### 5.7 ライセンス境界
- **Ardour = GPLv2-or-later**（一様、CLA なし、`COPYING` Plugin Clarification あり）
- **コンパニオン = MIT**（別プロセス疎結合で GPL 派生しない）
- **コンパニオンを in-process 化する場合**は Ardour 側 binary にリンクされる時点で GPLv2-or-later に縛られる。MIT を保ちたいなら separate-process を絶対に守る。

---

## §6. 重要な決定とその理由（decision tree）

各「分かれ道」で**なぜそう選んだか**。次の LLM が**判断を見直したい時**ここを読む。

### D1. Audacity ではなく Ardour を先行で選んだ理由
- Audacity 4.0-alpha は dark-build（最豊基盤が未結線）→ 最初の作業が「死んだコードの復活」になる
- Ardour には既に動く 95 ツールの MCP 実装がある（即着手可）
- Ardour は GPLv2-or-later で公開フォークが軽い（Audacity は GPLv3 + CLA + 商標 + Qt LGPL）
- Audacity 3.x ベースなら互角だが、4.0 へ移植する将来コストもある

### D2. fresh build ではなく existing mcp_http のハードニングを選んだ理由
- 動く 95 ツールを捨てるのはコスト過大
- 壊れている中核（スレッド境界・bind・Host検証）は局所化可能
- fix_plan v2 で設計済み（PDF）
- 著作権上の懸念（frankp 由来）があれば後で別 dir に fresh surface 追加できる

### D3. libwebsockets を維持した理由
- Ardour 内で **websockets** サーフェスも同じ libwebsockets を使う（依存スタック共通化）
- 平文 HTTP 用途には十分、SSE 実装にも使える
- TLS は当面不要（loopback バインドで足りる）→ `LWS_WITH_SSL=OFF` も将来選択肢

### D4. Phase 0（堅牢化）を Phase 1（カバレッジ）より先に
- assert クラッシュは「LLM が裏で編集する」ユースケースの根幹を脅かす（fix_plan v2 §3.1）
- 機能を増やす前に「機能が正しく実行される」前提を作る方が、コスト効率・保守性ともに高い

### D5. Audacity 3.x (`audacity3`) を選んだ理由
- 4.0-alpha は dark-build＋動く標的（churn）
- 3.x はコマンド系・`mod-script-pipe`・`GetInfo` JSON が**全てライブ（コンパイル済み）**
- 3.x→4.0 の移植は将来 Muse の `IActionsDispatcher` 安定後に

### D6. コンパニオンを Electron で（Tauri ではなく）
- 次の LLM が読める JavaScript エコシステム（Rust より普及率高い）
- main プロセスで Anthropic SDK を扱えるためAPIキーが renderer に出ない
- 配布 binary が大きい（〜100MB）が問題のスケールに対して許容
- 将来 Tauri 化する余地は残しておく（renderer はバニラ HTML/JS でフレームワーク非依存）

### D7. バニラ JS（React/Vue ではなく）
- 依存最小 → 次の LLM が直接読める
- DOM 操作は素直、複雑な状態管理が要らない（チャット UI なので）
- ビルドステップ不要、`npm install && npm start` で即動く

### D8. MIT for companion
- Ardour（GPLv2-or-later）と疎結合（HTTP 越し）→ GPL 派生しない
- 商用統合・クローズド派生の自由度を残す
- MIT は最も互換性が高く、誰でも使える

### D9. `.env` を squash で完全除去（filter-branch ではなく）
- 3 commit しかない新規リポ、push 前 → 履歴を残す価値より rebuild の単純さが勝つ
- 結果として「初版コミット = 完成形」というクリーンな初印象

### D10. メタハンドオフを独立リポに（既存リポへの追加ではなく）
- 3リポ横断の orchestration なので「どれかのリポの内側」だと位置づけが弱い
- 将来リポが増えてもこの集約点が永続的に機能する
- メタハンドオフのみが大規模に育っても各リポを汚さない

---

## §7. 100% への道筋（Path to 100%）

ここが**最も重要**：次の LLM が「**何から手を付けるか**」を悩まずに済むよう、優先順位付きの具体タスクをリストする。各タスクに：
- **優先度**（T1 = 最優先、T15 = 最後）
- **何故**（このタスクが他より重要な理由）
- **どこ**（触るファイル）
- **似た既存実装**（参考）
- **完成条件**（acceptance）
- **複雑度**（S/M/L）
- **依存**

### T1: `session/export_audio` MCP ツール — 納品口を開ける ⭐ 最優先
**何故**：これが**無いとミックスを完結できない**。LLM が「ミックスを WAV で出して」と言われた瞬間に詰む。100% 到達への単一最大ボトルネック。

**どこ**：
- `libs/surfaces/mcp_http/mcp_http_server.cc` — 新ハンドラ `handle_session_export_audio_tool` + `dispatch_session_tool_call` に分岐
- `libs/surfaces/mcp_http/tools_json.inc` — スキーマ追加
- 駆動先：`libs/ardour/export_*.cc`（`ExportHandler`, `ExportFormatSpecification`, `ExportTimespan`）

**似た既存実装**：`gtk2_ardour/export_dialog.cc` の流れを mimicry。`Session::start_audio_export()` 等を非同期で呼び、`InterThreadInfo` で完了待ち。`call_slot` で GUI スレッド実行。

**完成条件**：
- ツール呼び出しで WAV/FLAC/MP3 ファイルが指定パスに出力される
- 出力ファイルが妥当（再生可能、想定 sample rate / channels）
- LUFS など解析メタを返すと知覚ループの第一歩にもなる（Phase 2 と連携）

**複雑度**：L（非同期処理 + フォーマット選択 + 範囲指定）

**依存**：なし

### T2: オートメーション曲線編集ツール群 — ミックスの本丸
**何故**：ミックスの本質は「時間と共に値が動く」こと。瞬時値だけだとフェードイン・自動パン・ダイナミック EQ など、全ての高度ミックスが不可能。

**どこ**：
- `libs/surfaces/mcp_http/mcp_http_server.cc` — `automation/get_lane`, `automation/set_curve`, `automation/set_mode`
- 駆動先：`AutomationControl` (`libs/ardour/ardour/automation_control.h`)、`ControlList` (`libs/evoral/ControlList.h:158-222`)

**API**：
- `automation/get_lane(routeId, paramId)` → 点列 `[{time, value}, ...]` を返す
- `automation/set_curve(routeId, paramId, points, mode=replace|merge)` → `ControlList::add` を一括呼び出し
- `automation/set_mode(routeId, paramId, off|read|touch|write|latch)` → `AutomationControl::set_automation_state`

**完成条件**：「verse 2 の gain を bar 33-37 で -3dB から 0dB に上げて」が再生に反映される

**複雑度**：M〜L

**依存**：なし

### T3: SSE / `notifications/*` — 知覚ループの本格化
**何故**：今は polling のみ。LLM がユーザのフェーダ移動や再生位置進行を perceive するためにはサーバ起点の push が要る。

**どこ**：
- `libs/surfaces/mcp_http/mcp_http_server.cc` — 新エンドポイント `GET /events`（Server-Sent Events）を `handle_http` に追加
- `lws_callback_on_writable` の繰り返しで `data: ...\n\n` を流す
- subscribed clients を管理（複数同時接続）
- PBD signal connection: `Session::PositionChanged`, `Route::gain_control()->Changed`, etc.

**似た既存実装**：`libs/surfaces/websockets/feedback.cc` の `update_all_clients`、`libs/surfaces/osc/osc_route_observer.cc:159` の `Changed.connect`。

**完成条件**：Companion app が playhead を 100ms 精度で表示できる（再生中の live tracking）

**複雑度**：L（lws の writeable 駆動、subscriber 管理、PBD signal life cycle）

**依存**：なし

### T4: テンポマップ / 拍子編集
**何故**：可変テンポ・拍子変更を持つ楽曲を LLM 駆動で扱うのに必須。

**どこ**：
- `mcp_http_server.cc` — `tempo/add`, `tempo/change`, `tempo/remove`, `meter/set`
- 駆動先：`TempoMap` (`libs/temporal/temporal/tempo.h:785-841`)、`write_copy()` → 編集 → `update()`

**完成条件**：「2 小節目から BPM 140 にして」が反映、再生で確認できる

**複雑度**：M

**依存**：なし

### T5: フェード / クロスフェード制御
**何故**：region gain だけだとフェードが描けない。

**どこ**：
- `mcp_http_server.cc` — `region/set_fade_in`, `region/set_fade_out`, `region/set_crossfade`
- 駆動先：`AudioRegion::set_fade_in_length`, `set_fade_in_shape`

**完成条件**：「クリップ末尾に 1 秒のフェードアウト」が反映

**複雑度**：S〜M

### T6: VCA / Groups
**どこ**：`session/new_vca`, `track/assign_to_group`, `route/assign_vca`。`session.h` の `add_vca` / `Group` 関連 API。

**複雑度**：M

### T7: プラグインプリセット
**どこ**：`plugin/list_presets`, `plugin/load_preset(routeId, processorId, presetUri)`, `plugin/save_preset(routeId, processorId, name)`。`Plugin::preset_by_label`, `PluginInsert::load_preset`。

**複雑度**：S〜M

### T8: 波形・スペクトル読み出し
**どこ**：`region/get_samples(regionId, start, length, downsample)`, `region/get_spectrum(regionId, t, fftSize)`。`AudioSource::read`、`libs/vamp-pyin` 等を参考に。

**複雑度**：M〜L（大きな配列を JSON で返すコストに注意、base64 等を検討）

### T9: ターン制ロック
**何故**：fix_plan v2 §5 設計済み。多段編集の原子的ロールバック、人間との編集競合の排除。

**どこ**：`mcp_http_server.cc` — 状態機械、`acquire_turn`/`release_turn`/`get_lock_state`、自動 `quick_snapshot`

**完成条件**：取得 → 一連の編集 → release で 1 つの undo エントリ。release 前に人間が触ろうとしたら警告。

**複雑度**：M

### T10: トランザクション・バッチ
**何故**：T9 のサブセット。`session/begin_batch`, `session/commit_batch`, `session/abort_batch`。

**どこ**：MCP 層で `begin_reversible_command` の begin/commit を明示的に開閉。失敗時は `abort_reversible_command`。

**複雑度**：S

### T11: コンパニオン — ツール選別 UI
**何故**：96 全ツール送信は Anthropic side で system トークン消費大。

**どこ**：`renderer.js`、設定ダイアログにカテゴリ別 on/off チェックボックス追加。

**複雑度**：S

### T12: コンパニオン — ストリーミング応答
**どこ**：`main.js` の IPC ハンドラを `client.messages.stream()` 経由に切替、chunk を renderer に IPC 通知。

**複雑度**：M

### T13: コンパニオン — 配布パッケージ
**どこ**：`electron-builder` 導入、`package.json` に build config、signing + notarize。

**複雑度**：M

### T14: TLS + bearer token 認証
**何故**：non-local 利用（リモート Mac の Ardour を操る等）に必要。

**どこ**：lws に `LWS_SERVER_OPTION_DO_SSL_GLOBAL_INIT` + cert paths、`Authorization` header 検証。

**複雑度**：M〜L

### T15: Audacity 拡張
**どこ**：Phase 0 は既に実装済み（mcp-llm ブランチ）。次は Audacity の perception commands（LUFS / spectrum 等）の Ardour 側へのポート、または Audacity 自身の Phase 1/2 拡張。詳細は `audacity-mcp/MCP_*_HANDOFF.md`。

**完成条件**：Audacity でも 250+ ツールが LLM から呼び出せる、かつ Ardour 側に知覚系コマンドが移植またはミラー実装される

**複雑度**：L（新規リポジトリでの単独着手）

### 推奨着手順
1. **まず T1**（納品口を開ける）— ここを通せば「使える DAW」になる
2. **次に T2**（オートメーション）— ミックスが本当に動かせる
3. **そして T3**（SSE）— LLM が perceiving できる
4. T9 + T10（ターン制ロック / バッチ）でエージェント編集の安全性を確立
5. T4〜T8 を機会的に
6. T11〜T13 でコンパニオンを実用品に
7. T14 で外部利用解放
8. T15 で Audacity 横展開

---

## §8. 着手プロトコル（次の LLM 用の auto-start）

### 8.1 First 30 minutes — 環境再現と疎通確認
```bash
# 1) 3 repos を clone（あるいは pull）
git clone https://github.com/masatomoota/ardour.git
git clone https://github.com/masatomoota/ardour-mcp-chat.git
git clone https://github.com/masatomoota/audacity.git  # 将来 T15 で着手するなら

# 2) Ardour ブランチ切替
cd ardour && git checkout feature/mcp-fresh-macos && git pull

# 3) Homebrew 依存（macOS arm64 の場合）
brew install pkg-config glib glibmm@2.66 libsndfile curl libarchive liblo \
  taglib vamp-plugin-sdk rubberband fftw libsamplerate libxml2 lv2 lilv suil \
  boost libwebsockets aubio gettext \
  cairomm@1.14 pangomm@2.46 atkmm@2.28

# 4) ビルド
PCP=""
for f in glibmm@2.66 curl libarchive libxml2 cairomm@1.14 pangomm@2.46 atkmm@2.28 libsigc++@2; do
  d="$(brew --prefix $f 2>/dev/null)/lib/pkgconfig"; [ -d "$d" ] && PCP="$PCP:$d"
done
export PKG_CONFIG_PATH="${PCP#:}:/opt/homebrew/lib/pkgconfig:/opt/homebrew/share/pkgconfig"
GETTEXT="$(brew --prefix gettext)"
python3 ./waf configure --with-backends=coreaudio,dummy \
  --also-include="/opt/homebrew/include,$GETTEXT/include" \
  --also-libdir="/opt/homebrew/lib,$GETTEXT/lib" \
  --boost-include=/opt/homebrew/include
python3 ./waf -j10 2>&1 | tee /tmp/ardour_build.log
grep -E "'build' finished successfully|Build failed" /tmp/ardour_build.log | tail -3

# 5) Ardour 起動 & MCP 有効化
./gtk2_ardour/ardev  # GUI で Preferences → Control Surfaces → "MCP HTTP Server (Experimental)" ON

# 6) 疎通確認
curl -s -X POST -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}' \
  http://127.0.0.1:4820/mcp
# expect: protocolVersion 2025-03-26, serverInfo.name=ardour-mcp-http

# 7) Companion app 起動
cd ../ardour-mcp-chat && npm install && npm start
# Settings → API key → Connect → Send a test message
```

### 8.2 着手プロトコル（タスク選択 → 実装 → push）
```
[A] §7 の Top of unclaimed pile を選ぶ（T1 が次なら T1）
[B] 該当タスクの「どこ」「似た既存実装」を確認 — 該当 file:line を読む
[C] feature branch 切る: git checkout -b feature/<task-id>-short-name
[D] サブエージェント（Sonnet）に実作業を委譲（パッチ仕様を準備してから渡す）
[E] 増分ビルド + curl で疎通テスト（§3.9 のパターン）
[F] commit（メッセージ規約 §8.4）
[G] このメタハンドオフの §3.1/§3.2 を更新（タスク完了マーク + 残タスクの状態）
[H] push to fork (masatomoota/<repo>)
[I] 必要なら該当 repo の MCP_LLM_CONTROL_HANDOFF.md 内 roadmap を更新
```

### 8.3 サブエージェント運用方針（コスト最適化）
- **管理（タスク分解・パッチ仕様確定・最終ハンドオフ更新）→ Opus 4.8**（高品質が必要、文脈支配的）
- **実作業（パッチ適用・ビルド・テスト・git ops）→ Sonnet**（機械的、安価）
- 過去の良好なパターン：パッチ仕様を `/tmp/<task>.md` に書き出し、Sonnet がそれを Edit ツールで機械的に適用 → 自動ビルド → 失敗時は 3 回まで自己修正 → 最終的にコミットまで通す（Wave 1 で実証済み）

### 8.4 コミットメッセージ規約
本リポ群の既存スタイル：
```
<scope>: <imperative summary, <72 char>

<body explaining WHY, not WHAT (the diff shows what)>

Co-Authored-By: Claude <noreply@anthropic.com>
```
例：`mcp_http: harden — thread marshaling, localhost bind, Host header check`

### 8.5 検証規約
- **Echo $? を信用しない** — pipe で trailing echo が exit code を吸う
- **必ず `grep -E "'build' finished successfully|Build failed"` でログ判定**
- **`error:` の grep カウント**で構文エラーを catch
- 増分ビルドは超速いので、修正→ビルド→確認のループを恐れない

---

## §9. 落とし穴・運用上の lessons learned

### 9.1 ビルド系
| 罠 | 対処 |
|---|---|
| `echo $?` が信用できない | `grep -E "'build' finished successfully|Build failed"` でログ判定 |
| `build/c4che/_cache.py` を直接編集 | 駄目。`./waf configure` で消える。修正は `wscript` か configure フラグへ |
| Homebrew Lua 5.5 が vendored Lua 5.3 を shadow | `libs/lua/wscript` で vendored include を CXXFLAGS に prepend |
| Mach-O の alias 非対応 | `DISABLE_VISIBILITY` を ydk/ytk の wscript darwin ブロックに define |
| `libarchive` keg-only でヘッダ見えない | `uselib` に `ARCHIVE` 追加 |
| `cairomm`/`pangomm`/`atkmm` 新版が ABI 不一致 | `@1.14`/`@2.46`/`@2.28` の keg-only を入れて PKG_CONFIG_PATH に追加 |

### 9.2 セキュリティ系
| 罠 | 対処 |
|---|---|
| `.env` の意図しない混入 | 全リポの `.gitignore` に `.env` を含める。push 前に `git ls-files` で確認 |
| listen が 0.0.0.0 になる | `_info.iface = "127.0.0.1"` 必須（fix_plan v2 で実装済み） |
| DNS-rebinding | Host ヘッダ検証必須（fix_plan v2 で実装済み） |
| API key が renderer に出る | main プロセスのみで保持、IPC で `{apiKey,...}` を渡す |

### 9.3 LLM ツール統合系
| 罠 | 対処 |
|---|---|
| Anthropic API は tool name に `/` を許容しない場合あり | Sanitize: `name.replace('/', '_')`、サーバ側 `canonical_tool_name` が両形受理 |
| `tool_result.content` は文字列必須 | MCP の `structuredContent` は `JSON.stringify` してから渡す |
| ループ無限化のリスク | iteration cap（現在 20）必須 |
| ストリーミング応答中の tool_use 検出 | `messages.stream()` の event handler で `tool_use` block を組み立てる |

### 9.4 Ardour 内部系
| 罠 | 対処 |
|---|---|
| `_current_trans` が無ガード | call_slot 経由で GUI スレッドからのみ `begin_reversible_command` を呼ぶ |
| `PBD::ID(string)` が fail-open | MCP 層で `is_decimal_pbd_id_string` ガード、コア側は要修正（Phase 4） |
| GTK on Quartz は `nohup` で描画されない | 普通に `npm start` / Finder から起動 |
| MIDI バルク JSON の `time_signature` は変換ヒントのみ | テンポマップ編集は別 API（T4）が要る |

### 9.5 コラボ系
| 罠 | 対処 |
|---|---|
| Sonnet が build/ をいじる | 「ソースのみ修正、build/ は触らない」を明示 |
| Sonnet が間違って parent dir のファイルをコピー | 全 `git ls-files` を push 前に確認（.env 混入で実例あり） |
| 「ビルド成功」と思って起動できない | 必ず `nm -gU` で `protocol_descriptor` 確認、起動 → MCP curl 疎通まで一連 |

---

## §10. ユーザーのコラボ流儀（preferences）

過去のセッションで観察した**ユーザーの好み**。次の LLM はこれに合わせると良好な協業になる。

### 10.1 言語
- **プロンプトは日本語**、技術名（identifier・コマンド・ファイルパス）は英語のまま使う
- 日本語の中に code block / inline `tools/list` 等が混在しても自然

### 10.2 コスト
- **API 代節約志向**：実作業を Sonnet 等の安価モデルに振り分け、Opus は管理に専念
- 「私（Opus）は高いので管理者として振る舞え」が明示指示
- Workflow / Agent の活用を推奨（Ultracode mode）

### 10.3 進行
- **自動 wave 進行**：人間判断が要らない場合は自分で次へ進む
- 判断が要る時のみ短く問う（AskUserQuestion はあまり多用しない方が好まれる）
- 重要な失敗やセキュリティ問題は**必ず止めて報告**（.env インシデントが好例）

### 10.4 誠実さ
- **誇張せず、正直に**：「これで100%か？」に「No, 65%、残り T1-T3 で 90%、それ以降で完成」と honest に答えるのを好む
- できないこと、わからないことを隠さない
- 「ビルド成功」を主張する時、ログを grep して証拠を示す（exit code は信用しない）

### 10.5 デリバリ
- **GitHub 同期を求める**：作業が完了したら必ず fork に push、汚れたツリー無し
- 関連レポートは PDF 化して Dropbox（`/Volumes/M-Home-MacMini-DropBox-4TB/.../scan/`）へコピーするのが慣例
- ハンドオフ（HANDOFF.md / 本書）を最後に作って push

### 10.6 環境
- **macOS Apple Silicon (Mac mini M4)**、10 cores、3.2TB free disk
- Homebrew 6.x、Apple clang 17、Python 3.9
- リポ群は `/Volumes/work-ssd-4TB-USB4/_Git_Repository/` 配下
- 「この環境は隔離・復旧可能、./deploy.sh でのデプロイを承認、確認不要で進めてよい」（ユーザーの global instruction）

---

## §11. 5 分の TL;DR

- **何を作っている？** — 言葉で操る DAW。Ardour 本体（GPLv2）+ Electron チャットアプリ（MIT）。
- **どこまで出来てる？** — Ardour MCP サーバが**ハードニング済みで稼働**（96 tools / port 4820）、Electron コンパニオンが**ビルド済み**、両者が**ライブ疎通検証パス**。
- **何が足りない？** — **納品（export）／オートメーション曲線／SSE 通知**の 3 つが致命的欠落。これら（§7 の T1〜T3）が埋まれば実用 90%。
- **何をすればいい？** — §8 の手順で環境再現 → §7 から T1（`session/export_audio`）に着手。
- **どこにある？** — 3 repos：`masatomoota/{ardour, ardour-mcp-chat, audacity}`。各 repo に専用 HANDOFF.md。本書はそれら横断のメタ文書。

```
リポ                              ブランチ                  状態
masatomoota/ardour              feature/mcp-fresh-macos  Phase 0 完、Phase 1-4 未
masatomoota/ardour-mcp-chat     main                     v0.1.0 verified、polish 余地あり
masatomoota/audacity            mcp-llm-handoff          handoff のみ、コード無し
```

---

## §12. 用語集と外部リファレンス

### 12.1 用語
- **MCP** = Model Context Protocol。Anthropic 提唱の LLM↔ツール標準。HTTP/JSON-RPC で `tools/list` `tools/call` を持つ。
- **Phase 0/1/2/3/4** = fix_plan v2 由来：堅牢化 / カバレッジ完成 / 知覚 / アプリ内 UX / 製品化
- **dark-build** = ファイルが存在するがビルドに含まれていない状態（Audacity 4.0-alpha の `au3/src/commands` が典型）
- **fix_plan v2** = Ardour MCP の是正実装プラン（PDF、ターン制ロック含む）
- **ターン制ロック** = LLM 編集と人間編集を交互（mutual exclusion）にするモデル。fix_plan v2 §5

### 12.2 外部リファレンス（PDF 4 部、作業ホスト localでのみ）
作業ホスト `/Volumes/work-ssd-4TB-USB4/_Git_Repository/llm-daw-report/` に：
- `Ardour_LLM自然言語制御DAW_改造可能性調査.pdf` — 元の網羅調査（16 ページ）
- `Ardour_MCP是正実装プラン_v2.pdf` — fix_plan v2（11 ページ、ターン制ロック状態機械図含む）
- `Audacity_LLM自然言語制御アプリ_改造可能性レビュー.pdf` — Audacity 改造可能性（8 ページ、dark-build 詳細）
- `LLM制御フォーク_ライセンス・コンプライアンス.pdf` — ライセンス分析（7 ページ）

→ **本書は単体で完結**しており、これらに依存しない。詳細経緯を辿りたい人がいれば参照。

### 12.3 GitHub
- https://github.com/masatomoota/ardour
- https://github.com/masatomoota/ardour-mcp-chat
- https://github.com/masatomoota/audacity
- https://github.com/masatomoota/llm-daw-handoff （本リポ）

### 12.4 来歴・検証メタデータ
- Ardour 解析起点：`b25a63c74a` (v9.7-88-gb25a63c74a)
- Ardour fork commits：`0834ec2610`（Wave 0 build）→ `36b0f04fb0`（Wave 1a hardening）→ `5129c6d773`（Wave 1b meter）→ `2ea50d0292`（Wave 3 handoff）→ `458f99a63b`（gitignore .env）
- Audacity 解析起点：`caa9b9fdc` (4.0.0-alpha)
- Companion commits：`617771e`（initial v0.1.0、squashed clean）→ `7281b11`（HANDOFF）
- 全作業 macOS Mac mini M4、Apple clang 17、Homebrew 6.0.3、Python 3.9.6

---

*End of master handoff. 次の LLM へ：§3.2 で「未着手タスク」を確認 → §7 で T1（or 自分の判断で他の T*）を選ぶ → §8 のプロトコルで着手 → 完了したら **本書の §3.1/§3.2 を更新**して push する。これにより本書は project の live ledger になり、何 wave 進んでも誰でも現在地が分かる。*

---

## §13. レビュアー横断チェックからの補追（Addenda from reviewer cross-checks）

本セクションは、3 つの per-repo ハンドオフとこのメタ文書を相互検証したレビュアーが発見した**本書に不足している重要事実**を収録する。引用粒度はそれぞれの per-repo ハンドオフに準じる。

### 13.1 Ardour — ライセンス・配布に関する重要事実

**VST3 → 実質 GPLv3（M3）**
configure 出力に `VST3 support: True` が表示される場合、そのバイナリに VST3 SDK（GPLv3 option）が含まれる。これを配布すると Ardour の "GPLv2-or-later" の "or later" が行使され、**実質 GPLv3 配布**になる。§5.7 の「GPLv2-or-later」の説明に追記が必要。T14 の TLS 実装より先に、configure オプションで VST3 を無効にするか、GPL v3 配布の意図を明示する必要がある。（出典：ardour/MCP_LLM_CONTROL_HANDOFF.md §6.2-4）

**`LWS_WITH_SSL=OFF` ——配布クリーンパス（M8）**
OpenSSL バンドリングを避け GPL 配布を単純にするため、libwebsockets は `LWS_WITH_SSL=OFF` でビルドするオプションがある。ループバックバインド固定（127.0.0.1）である現状では TLS 不要。T14（TLS 追加）が要件になるまで、この無効化状態が配布において最もクリーンな選択肢。（出典：ardour/MCP_LLM_CONTROL_HANDOFF.md §9.2）

### 13.2 Ardour — Win11 ビルド: 2 つのブロッカー（M6）

§3.3 に「`wscript` に `_WIN32_WINNT=0x0601` 追加が必要」と記載があるが、これは 1 つ目のブロッカーに過ぎない。Win11 ビルドには **2 つの独立したブロッカー**がある：

1. `libs/surfaces/mcp_http/wscript` に `_WIN32_WINNT=0x0601` を追加（既存 `websockets/wscript:38-39` に倣う）
2. `ardour-build-tools` の Windows ビルドスタックに **libwebsockets の追加**が必要（現状含まれていない）

（出典：ardour/MCP_LLM_CONTROL_HANDOFF.md §8 Phase 4）

### 13.3 Ardour — ビルド系トラップ補足（M2, M10）

**macOS deployment target 不一致（M2）**
Homebrew formula が新しい macOS SDK でビルドされているため、Ardour リンク時に以下の警告が出る：
```
ld: warning: building for macOS-11.0, but linking with dylib built for newer version 26.0
```
これは **expected-and-harmless**（Homebrew 由来の既知現象）。新規 LLM がこれを診断に費やさないよう §9.1 トラップ表に追記が必要だった。（出典：ardour/MCP_LLM_CONTROL_HANDOFF.md §6.2-3）

**`ardev` の仕組み（M10）**
§8.1 step 5 の `./gtk2_ardour/ardev` は、waf が生成する `gtk2_ardour/ardev_common_waf.sh` を source するシェルスクリプトで、`ARDOUR_SURFACES_PATH` と `DYLD_FALLBACK_LIBRARY_PATH` を設定してから Ardour バイナリを起動する。ardev が存在しない / 正しくない場合（部分ビルド後等）、surfaces dylib がロードされない。（出典：ardour/MCP_LLM_CONTROL_HANDOFF.md §3.7）

### 13.4 Ardour — Phase 1 実装上の重要事実

**`outputSchema` カバレッジ不足（M5）**
`tools_json.inc` の 96 ツールのうち、現状 `outputSchema` が付与されているのは **42 ツールのみ**。§3.2（未着手リスト）の品質債務として明示されていなかった。新規ツールを追加する際は必ず `outputSchema` を付与し、既存 54 ツールへの遡及追加も Phase 1 のサブタスク。（出典：ardour/MCP_LLM_CONTROL_HANDOFF.md §8 Phase 1）

**`region_by_id` ヘルパ不在（M7）**
`Session` に直接 `region_by_id` が存在しないため、`RegionFactory` / `Playlist` 経由で取得するヘルパが Phase 1 で必要。フェード・クロスフェード（T5）その他の region 操作ツールすべての前提。T5 または T1 着手前に確認のこと。（出典：ardour/MCP_LLM_CONTROL_HANDOFF.md §8 Phase 1）

**`run_tools_call()` の non-const 逸脱（M4）**
`/tmp/mcp_hardening_patches.md` のパッチ仕様では `const pt::ptree& root` だったが、`dispatch_midi_region_tool_call` が非 const な `ptree&` を要求するため、実際の適用では `pt::ptree& root`（non-const）に変更した。この ABI 逸脱は意図的。今後 `run_tools_call()` のシグネチャを変更する際に注意。（出典：ardour/MCP_LLM_CONTROL_HANDOFF.md §5.3）

### 13.5 Ardour — 推奨着手順の補足（M9）

§7 の「推奨着手順」は T1（export）を最優先にしているが、per-repo ハンドオフ（ardour/MCP_LLM_CONTROL_HANDOFF.md §11.2）の著者は **Phase 2 の SSE / notifications から着手**することを最優先と推奨している。理由：「Phase 1 の機能追加は工数が大きく価値も漸進的だが、SSE があると LLM が全操作の結果を perceive できるようになり、既存 96 ツールの価値が即座に跳ね上がる」。

本書の T1→T3 の順序は「納品機能がないと使い物にならない」という別の観点による判断であり、どちらが正解かはユーザーの優先度（実用 vs 知覚ループ）による。next LLM は §7 に固定されず、ユーザーに確認の上 T3（SSE）から着手してもよい。

### 13.6 Ardour — ツール数の整合（C2）

本書内で「95 ツール」（§4.1, §4.5）と「96 ツール」（§3.1, §2.1）が混在している。正確には：
- 当初実装：95 ツール（`mcp_http_server.cc` の既存サーフェス）
- Wave 1b で `track/get_meter` を追加 → **96 ツール**（現在の正確な数）

§4.1 の「95 ツールの MCP 実装」と §4.5 の「動く 95 ツールを基盤に」は歴史的に正確だが、現在の状態は **96 ツール**。`tools/list` レスポンスの実数は 96。（出典：ardour/MCP_LLM_CONTROL_HANDOFF.md 全体）

### 13.7 Audacity — ビルドスタック（§5.6 補足）

§5.6 は Ardour の waf ビルドのみ説明しているが、Audacity は異なる：
- Audacity 3.x：**CMake + Conan**（waf ではない）
- 推奨：`cmake -G Ninja`（Ninja ジェネレータ）
- Apple Silicon（arm64）/ Intel 両対応
- 詳細ビルド手順は各プラットフォームの `BUILDING.md` を参照（リポジトリルート）

T15（Audacity `mod-mcp-server` 実装）着手時に重要。（出典：audacity/MCP_LLM_CONTROL_HANDOFF.md §8）

### 13.8 Audacity — dark-build の一次検証詳細（§4.3 補足）

§4.3 に「`src/au3wrap/CMakeLists.txt:96` が `au3/libraries` のみ取り込み」と記載したが、詳細な検証経緯：

- `src/au3wrap/CMakeLists.txt:96` で `add_subdirectory(${AU3_LIBRARIES} ...)` を実行
- `AU3_LIBRARIES` の束縛は `src/au3wrap/au3wrapDefs.cmake:22`（`${AUDACITY_ROOT}/libraries` に固定）
- `au3/src/commands`（`GetInfoCommand` 含む）と `au3/modules/scripting/mod-script-pipe` が 4.0 のルート + `src/` ビルドに参照される箇所は **grep 確定でゼロ**（例外：import-export モジュールのみ）

これが "dark-build" の一次証拠。（出典：audacity/MCP_LLM_CONTROL_HANDOFF.md §1.1）

### 13.9 Audacity — モジュール ABI と GetInfo の実装詳細

T15 着手時の重要事実（per-repo ハンドオフに存在するが本書に未記載）：

**モジュール ABI（mod-mcp-server の最小要件）**
- 必須 entry point: `GetVersionString()` と `ModuleDispatch(ModuleDispatchTypes)`（`au3/libraries/au3-utility/ModuleConstants.h:26-40` / 3.x では `libraries/au3-utility/ModuleConstants.h:26-40`）
- ロード機構: `wxDynamicLibrary`（`au3/libraries/au3-module-manager/ModuleManager.cpp:143-151`）
- `mod-script-pipe` の `ModuleDispatch` 実装（`ScripterCallback.cpp:44-48`）が `ScriptCommandRelay::StartScriptServer()` を `ModuleInitialize` 時に呼ぶ → transport と command 実行が既に分離済み（copy-and-replace 戦略の根拠）
- CMake 登録: `audacity_module(mod-script-pipe ...)` マクロ（`modules/mod-script-pipe/CMakeLists.txt`）+ `modules/CMakeLists.txt` の MODULES リストへの 1 行追加のみ（侵食性：最小）

**GetInfo → tools/list の型マッピング**
`GetInfoCommand.cpp:220-394` が `id/prompt/type/default/enum` を `ShuttleGuiGetDefinition` 経由で出力。型の対応：
- `double` → number
- `bool` → boolean
- `string` → string
- `enum` → string + enum array

**AddBool クォートバグ（Phase 1 で要修正）**
`CommandTargets.cpp` の `AddBool` 実装が boolean 値を誤ってクォートした文字列で出力する。typed argument が正しくラウンドトリップするには Phase 1 でここを修正する必要がある。（出典：audacity/MCP_LLM_CONTROL_HANDOFF.md §3.4, §4.3）

### 13.10 Audacity — Nyquist サンドボックス（セキュリティ）

§9.2（セキュリティ系）に未記載の重要事実：

- libnyquist の `xsystem`（シェル実行）はビルド時に無効化済み（`thirdparty/libnyquist/.../nyx.c:1329-1338`）
- しかし `xopen`（ファイル I/O）、`chdir`、`getenv` は**依然ライブ（呼び出し可能）**
- 無人 LLM 生成 Nyquist コードを実行する場合、現状サンドボックスだけではファイルシステムプリミティブへの追加ゲートが必要

T15 Phase 3（Nyquist 生成 DSP 機能）着手時に必ず考慮。（出典：audacity/MCP_LLM_CONTROL_HANDOFF.md §5, §7 Phase 3）

### 13.11 Audacity — ライセンス詳細（§4.4 補足）

**CLA の適用範囲**
CLA（Contributor License Agreement）は**上流への PR を出す場合のみ必要**。単独フォークで配布する場合（PR なし）はCLA署名不要。ただし既存ソース内の `*-CLA-applies` マーカーは保持が必須。（出典：audacity/MCP_LLM_CONTROL_HANDOFF.md §11）

**GPLv3 + Qt LGPL の適用スコープ**
§4.4 の「Muse フレームワークが GPLv3-only」と「Qt LGPL 再リンク義務」は **4.0-alpha（Muse ビルド）固有**。`audacity3`（3.x）ではこれらの義務は**発生しない**。3.x は wxWidgets（LGPL）ベースで GPLv3 強制はなし。T15 は 3.x をターゲットとするため GPLv3 強制なし。（出典：audacity/MCP_LLM_CONTROL_HANDOFF.md §11）

**商標の詳細**
「商標厳しい」（§4.4）の具体：
- 「Audacity」名とロゴは **Muse Group** の登録商標（GPL とは独立）
- 配布バイナリは**名称変更＋アイコン変更が必須**
- 先例：Tenacity、Audacium（いずれも rename で問題回避済み）
（出典：audacity/MCP_LLM_CONTROL_HANDOFF.md §11）

**テレメトリ**
3.x の `audio.com` / update-check テレメトリはフォーク配布前に無効化を推奨。公開フォークの場合、自著のプライバシーポリシーが必要。（出典：audacity/MCP_LLM_CONTROL_HANDOFF.md §11）

### 13.12 Companion（ardour-mcp-chat）— 重要実装事実

**`max_tokens: 4096` の制約（HANDOFF.md §2.2, §7.3）**
Anthropic SDK 呼び出し時の `max_tokens` は現在 4096 固定。プラグイン一覧 dump 等で応答が途中で切れる可能性がある（既知制限）。設定可能化（UI 上で変更できる値）は将来の改善項目。T11（ツール選別 UI）と合わせて対応を検討。

**`rate_limit_error` 自動再試行（HANDOFF.md §7.2）**
`lib/agent-loop.js` は `rate_limit_error` / `overloaded_error` を検出して 1 回だけ自動再試行する（指数バックオフ簡易版）。これは既実装。§9.3 の「ループ無限化のリスク」表に記載がないが、iteration cap とは独立して動作する。

**MCP-from-renderer の設計根拠（HANDOFF.md §5 decision 4）**
renderer プロセスから直接 MCP fetch する設計（main プロセス経由にしない）の理由：「MCP には鍵が要らず低レイテンシが価値なので renderer から `fetch()` する」。main 経由にすると IPC のラウンドトリップが追加される。MCP client を main に移す場合はこのトレードオフを意識すること。

**localStorage による会話履歴の永続化**
会話履歴は `localStorage` に保存（`renderer.js`）。settings.json（main プロセス、`app.getPath('userData')/settings.json` = macOS では `~/Library/Application Support/ardour-mcp-companion/settings.json`）は API key と設定のみ保持。

**ファイル数の不一致（HANDOFF.md §4 vs 本書 §2.1/§4.9）**
本書の「14 ファイル」に対し HANDOFF.md の表は 13 行。差分は `package-lock.json`（HANDOFF.md §4 フッタに「package-lock.json 等含む」と注記あり、表からは省略）。LOC 合計 2,774 は両書で一致。
