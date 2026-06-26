# Session Handoff: Wave T2 — automation tools (2026-06-26)

> **Purpose**: Turn-resume handoff for the next LLM, covering Wave T2 (`automation/get_lane`, `automation/set_curve`, `automation/set_mode`). This file is a companion to `SESSION_2026-06-26_T1_EXPORT.md` and `SESSION_2026-06-26_T3_SSE.md` from the same chat session. Read the master handoff (`README.md`) for the full project picture. Start here if you are resuming work on Ardour automation tooling.

---

## 1. 何をしたか（1 段落）

2026-06-26 の同一チャットセッション内（T1: `session/export_audio`、T3: SSE `GET /events` に続く第3ターン）で、マスターハンドオフ §7 T2「オートメーション曲線編集ツール群 — ミックスの本丸」の MVP を実装した。`libs/surfaces/mcp_http/mcp_http_server.cc` に 347 行追加・`tools_json.inc` に 93 行追加（合計 440 行、1 行変更）。route 標準パラメータ 5 種（gain / pan / mute / solo / rec_enable）に対して `automation/get_lane`（点列読み出し）・`automation/set_curve`（点列一括書き込み、replace mode、reversible command ラップ）・`automation/set_mode`（AutoState 変更）を実装した。ビルドは errors=0 / warnings=2（iterations=2）で成功し、dylib string table と symbol probe で 3 ツールの両形式（slash / underscore）と 4 ハンドラシンボルを確認した。コミット `ee8ffb10fd177a9e09fb000bf0a8bf75c4d72b8b` として `feature/mcp-fresh-macos` に push 済み。これにより同セッションで T1 + T3 + T2 がすべて landing し、マスターハンドオフが「致命的欠落」と指摘した 3 軸（納品 / 知覚 / ミックス時間軸）が一挙に閉じた。

---

## 2. 変更ファイル（git show --stat）

```
commit ee8ffb10fd177a9e09fb000bf0a8bf75c4d72b8b
Author: masatomoota <129290880+masatomoota@users.noreply.github.com>
Date:   Fri Jun 26 13:49:07 2026 +0900

    mcp_http: add automation/{get_lane,set_curve,set_mode} (T2 MVP)

    Implements the final critical "100%" gap from master handoff §7 T2:
    automation curve read/write/state-mode tools for Route-level standard
    parameters (gain, pan, mute, solo, rec_enable). MVP scope is "replace"
    mode only — clear the existing AutomationList then add the supplied
    [(time_sec, value)] points — wrapped in begin/commit_reversible_command
    so each set_curve appears as ONE Undo entry.

    automation/get_lane returns the current point list as
    {time_sec, time_samples, value} array plus automation_state and
    ParameterDescriptor bounds. automation/set_curve replaces. automation/
    set_mode toggles AutoState (off/play/touch/write/latch).

    Future work: plugin parameters (PluginAutomation), MIDI controllers,
    "merge" mode, guard-point control, per-set notifications/automation
    SSE event. Tool count rises from 97 to 100.

    Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>

 libs/surfaces/mcp_http/mcp_http_server.cc | 348 +++++++++++++++++++++++++++++-
 libs/surfaces/mcp_http/tools_json.inc     |  93 ++++++++
 2 files changed, 440 insertions(+), 1 deletion(-)
```

---

## 3. ツールスペック verbatim（tools_json.inc より）

### 3.1 automation_get_lane

```json
{
  "name": "automation_get_lane",
  "title": "Get Automation Lane",
  "description": "Return all control points and current mode for an automation lane on a route. Supported parameters: gain, pan, mute, solo, rec_enable.",
  "inputSchema": {
    "type": "object",
    "properties": {
      "id": {
        "type": "string",
        "description": "Route MCP id (PBD::ID as decimal string)"
      },
      "parameter": {
        "type": "string",
        "enum": ["gain", "pan", "mute", "solo", "rec_enable"],
        "description": "Automation parameter name"
      }
    },
    "required": ["id", "parameter"],
    "additionalProperties": false
  }
}
```

**MCP tool name**: `automation/get_lane` または `automation_get_lane`（`canonical_tool_name` が両形を受理）

**Response (structuredContent)**:
```json
{
  "routeId": "<string>",
  "parameter": "<string>",
  "automationState": "off|play|touch|write|latch",
  "sampleRate": 48000,
  "pointCount": 3,
  "lower": 0.0,
  "upper": 2.0,
  "points": [
    { "timeSec": 0.0, "timeSamples": 0, "value": 1.0 },
    { "timeSec": 4.0, "timeSamples": 192000, "value": 0.5 }
  ]
}
```

### 3.2 automation_set_curve

```json
{
  "name": "automation_set_curve",
  "title": "Set Automation Curve",
  "description": "Replace all control points on an automation lane with the provided list (mode=replace). Points are specified as seconds from session start plus a parameter value in internal units (gain: 0.0-2.0 linear, pan: 0.0-1.0, mute/solo/rec_enable: 0.0 or 1.0). The operation is undoable as a single step.",
  "inputSchema": {
    "type": "object",
    "properties": {
      "id": { "type": "string", "description": "Route MCP id" },
      "parameter": {
        "type": "string",
        "enum": ["gain", "pan", "mute", "solo", "rec_enable"]
      },
      "points": {
        "type": "array",
        "description": "Control points in ascending time order. May be empty to clear the lane.",
        "items": {
          "type": "object",
          "properties": {
            "timeSec": { "type": "number", "minimum": 0 },
            "value": { "type": "number" }
          },
          "required": ["timeSec", "value"],
          "additionalProperties": false
        }
      },
      "mode": {
        "type": "string",
        "enum": ["replace"],
        "description": "Edit mode. Only 'replace' (clear then add) is supported in this version."
      }
    },
    "required": ["id", "parameter", "points"],
    "additionalProperties": false
  }
}
```

**Response (structuredContent)**:
```json
{
  "routeId": "<string>",
  "parameter": "<string>",
  "mode": "replace",
  "pointsSet": 3,
  "previousPointCount": 0
}
```

### 3.3 automation_set_mode

```json
{
  "name": "automation_set_mode",
  "title": "Set Automation Mode",
  "description": "Set the automation playback/record mode for a parameter on a route. Use 'play' (or 'read') to play back recorded automation, 'write' to record all moves, 'touch' to record only while touching, 'latch' to latch written values, 'off' to disable automation.",
  "inputSchema": {
    "type": "object",
    "properties": {
      "id": { "type": "string" },
      "parameter": {
        "type": "string",
        "enum": ["gain", "pan", "mute", "solo", "rec_enable"]
      },
      "mode": {
        "type": "string",
        "enum": ["off", "play", "read", "touch", "write", "latch"],
        "description": "Automation mode. 'read' is accepted as an alias for 'play'."
      }
    },
    "required": ["id", "parameter", "mode"],
    "additionalProperties": false
  }
}
```

**Response (structuredContent)**:
```json
{
  "routeId": "<string>",
  "parameter": "<string>",
  "automationState": "play",
  "previousState": "off"
}
```

---

## 4. ハンドラ実装ウォークスルー（file:line 引用）

すべてのハンドラは `mcp_http_server.cc` に新規追加されたブロック内に存在する。コミット `ee8ffb10fd177a9e09fb000bf0a8bf75c4d72b8b` の差分 `+` 行番号で参照する。

### 4.1 ヘルパ関数群

**`resolve_automation_parameter(name, err)` — diff+8〜+19**

パラメータ名文字列（`"gain"`, `"pan"`, `"mute"`, `"solo"`, `"rec_enable"`）を `Evoral::Parameter` に変換する。未知名は `Evoral::Parameter(NullAutomation, 0, 0)` を返し `err` に説明文字列をセットする（fail-closed）。

```
GainAutomation       (type 0x01) - gain_control()
PanAzimuthAutomation (type 0x0D) - pan_azimuth_control()
MuteAutomation       (type 0x06) - mute_control()
SoloAutomation       (type 0x07) - solo_control()
RecEnableAutomation  (type 0x08) - (Track only) rec_enable_control()
```

**`get_route_automation_control(route, param)` — diff+21〜+47**

`Evoral::Parameter` type で switch し、対応する `AutomationControl` を返す。`PanAzimuthAutomation` は mono ルートで `nullptr`（panner 不在）、`RecEnableAutomation` は bus では `nullptr`（Track にキャスト失敗）。どちらの場合も `-32602 "Parameter not available on this route"` エラーを返す。

**`auto_state_to_mcp_string(s)` / `mcp_string_to_auto_state(s, out, err)` — diff+49〜+76**

`ARDOUR::AutoState` と MCP 文字列の双方向変換。`"read"` は `ARDOUR::Play` のエイリアスとして受理（Ardour 用語では `Play` モード = Read モード）。

### 4.2 `handle_automation_get_lane_tool()` — diff+78〜+157

1. `root.get<string>("params.arguments.id")` と `root.get<string>("params.arguments.parameter")` を取得
2. `route_by_mcp_id(session, route_id)` でルート取得（既存のフェイルクローズドヘルパ、`mcp_http_server.cc:253-301`）
3. `resolve_automation_parameter()` → `get_route_automation_control()`
4. `ctrl->alist()` で `shared_ptr<AutomationList>` 取得
5. `session.sample_rate()` で SR を取得
6. **`PBD::RWLock::ReaderLock lm(alist->lock())`** 下で `alist->events()` をイテレート
7. 各 `ControlEvent*` の `when.samples()` を `double(samps) / double(sr)` で秒換算して JSON 組み立て
8. `alist->automation_state()`・`alist->descriptor().lower`・`upper` を付与して返却

### 4.3 `handle_automation_set_curve_tool()` — diff+159〜+265

1. 引数解析（`id`, `parameter`, `mode`, `points`）。`mode != "replace"` は即 `-32602`
2. lookup chain（上記と同じ）
3. `root.get_child_optional("params.arguments.points")` で点列ノード取得
4. 各点の `"timeSec"` と `"value"` を `get_optional<double>` で取得
5. **seconds → samples 変換**: `samplepos_t samps = (samplepos_t)floor(timeSec * session.sample_rate())`
6. `Temporal::timepos_t(samps)` にラップして `ControlList::OrderedPoints` に push
7. **スナップショット**: `XMLNode& before = alist->get_state()`
8. **書き込み**: `alist->freeze()` → `alist->clear()` → `alist->editor_add_ordered(ops, false)` → `alist->thaw()`
9. **スナップショット**: `XMLNode& after = alist->get_state()`
10. **reversible command**:
    ```cpp
    session.begin_reversible_command("automation: set curve");
    session.add_command(new MementoCommand<AutomationList>(*alist.get(), &before, &after));
    session.commit_reversible_command();
    // 例外時: session.abort_reversible_command();
    ```
11. `session.set_dirty()`
12. 結果返却

### 4.4 `handle_automation_set_mode_tool()` — diff+267〜+326

1. 引数解析（`id`, `parameter`, `mode`）
2. lookup chain（`get_route_automation_control()` は適用可否確認のみ）
3. `mcp_string_to_auto_state(mode_str, new_state, mode_err)` で `AutoState` に変換
4. `route->set_parameter_automation_state(param, new_state)` を呼び出す（`automatable.h:104`）
5. **reversible command なし**（OSC surface `osc.cc:4509-4534` との一貫性）
6. 結果返却（`previousState` も含む）

### 4.5 `dispatch_automation_tool_call()` と `run_tools_call()` 統合 — diff+328〜+348

```cpp
static bool
dispatch_automation_tool_call(ARDOUR::Session& session,
                               const std::string& tool_name,
                               const pt::ptree& root,
                               const std::string& id,
                               std::string& response)
{
    if (tool_name == "automation/get_lane")  { response = handle_automation_get_lane_tool(session, root, id);  return true; }
    if (tool_name == "automation/set_curve") { response = handle_automation_set_curve_tool(session, root, id); return true; }
    if (tool_name == "automation/set_mode")  { response = handle_automation_set_mode_tool(session, root, id);  return true; }
    return false;
}
```

`run_tools_call()` の末尾（`dispatch_midi_region_tool_call()` の後、フォールスルーエラーの前）に以下を挿入：

```cpp
if (dispatch_automation_tool_call(session, tool_name, root, id, response)) {
    return response;
}
```

ディスパッチャは `"automation/get_lane"` 等の slash 形式で照合するが、`canonical_tool_name()` が呼び出し元で既に両形式を slash 形式に正規化しているため underscore 形式も正しく届く。

---

## 5. スレッドモデル

Wave 1 ハードニング以来の一貫したパターン：

```
[LLM client] --POST /mcp tools/call--> [lws service thread]
                                              |
                              EventLoop::call_slot(MISSING_INVALIDATOR, lambda)
                              condvar.wait(done)   <-- lws スレッドはここでブロック
                                              |
                              [GUI/event_loop thread]
                              run_tools_call()
                                |
                                dispatch_automation_tool_call()
                                |
                                handle_automation_{get_lane|set_curve|set_mode}_tool()
                                    |
                                    (set_curve のみ)
                                    session.begin_reversible_command("automation: set curve")
                                    alist->freeze/clear/editor_add_ordered/thaw
                                    session.add_command(MementoCommand<AutomationList>)
                                    session.commit_reversible_command()
                                    |
                                response string -----> condvar.notify_one()
                              |
                [lws thread resumes] --HTTP response-->
```

`begin/commit_reversible_command` は GUI スレッドから呼ばれるため `HistoryOwner::_current_trans` の無ガードアクセス問題を踏まない（Phase 0 ハードニングの恩恵）。

---

## 6. ビルド状態

| 項目 | 値 |
|---|---|
| errors | 0 |
| warnings | 2（macOS deployment target 不一致、既知・無害） |
| iterations | 2 |
| dylib パス | `build/libs/surfaces/mcp_http/libardour_mcp_http.dylib` |
| ツール数（dylib 確認） | 100（`"name": "` パターンで grep） |

---

## 7. スモーク検証スコープ

| 検証項目 | 手法 | 結果 |
|---|---|---|
| ビルド成功 | `grep "'build' finished successfully"` | ✅ |
| エラーゼロ | `grep -c 'error:'` | ✅ 0 件 |
| string table — slash 形式 3 種 | `strings dylib \| grep 'automation/'` | ✅ `automation/get_lane`, `automation/set_curve`, `automation/set_mode` 存在 |
| string table — underscore 形式 3 種 | `strings dylib \| grep 'automation_'` | ✅ いずれも存在（`canonical_tool_name` が emit する証拠） |
| シンボルプローブ | `nm -gU dylib \| grep` | ✅ `resolve_automation_parameter`(t), `handle_automation_get_lane_tool`(t), `handle_automation_set_mode_tool`(t), `handle_automation_set_curve_tool`(t) — 4 シンボル確認 |
| ツール数 100 | `strings dylib \| grep -c '"name": "'` | ✅ 100（スペースあり形式で正確にカウント） |
| ライブ curl テスト | Ardour 起動して実呼び出し | ⏳ 未実施（Ardour 未起動） |

ライブ検証は次回 Ardour 起動時に §3.9 のパターンで実施すること。

---

## 8. MVP の制限

1. **route 標準パラメータのみ（5 種）**: `gain`・`pan`（`PanAzimuthAutomation`）・`mute`・`solo`・`rec_enable`（Track のみ）。プラグイン固有パラメータ（`PluginAutomation`）と MIDI CC（`MidiCCAutomation`）は未対応。
2. **replace モードのみ**: `set_curve` は常にクリア→追加。`merge` モード（既存点と合成）は未実装（要求すると `-32602` エラー）。
3. **ガードポイント無効**: `editor_add_ordered(ops, with_guard=false)` でガードポイントを抑制。GUI 操作で付与されるガードポイントと混在しない（get_lane で余分な点が見えない）。将来 GUI 連携強化時に `true` に変更検討。
4. **モード変更の Undo なし**: `set_mode` は Undo 履歴に記録しない（OSC surface との一貫性）。
5. **notifications/automation なし**: `set_curve` / `set_mode` 後に SSE イベントを push しない。状態変化の知覚は次回 `get_lane` 呼び出しまで遅延する。
6. **pan は PanAzimuthAutomation のみ**: ステレオ幅（`PanWidthAutomation`）・フロントバック（`PanElevationAutomation`）等は未対応。
7. **rec_enable は Track のみ**: Bus・VCA は `get_route_automation_control()` が `nullptr` を返し `-32602` エラーになる（期待通りの動作）。

---

## 9. セッション累計サマリ

このチャットセッション（2026-06-26）で 3 つの Wave が landing した：

### 致命的欠落 Before → After

| 軸 (§1.2) | セッション開始時 | このセッション完了後 |
|---|---|---|
| **納品 (Deliver)** | 致命的欠落（export ZERO） | MVP: `session/export_audio` WAV ブロッキング（T1, `19853971f0`） |
| **知覚 (Perceive)** | 致命的欠落（観測手段 ZERO） | MVP: SSE `GET /events` + `notifications/transport`（T3, `43f4848f09`） |
| **ミックス時間軸 (Mix)** | 致命的欠落（時間軸オートメーション ZERO） | MVP: `automation/get_lane|set_curve|set_mode` route 標準 5 params（T2, `ee8ffb10fd`） |

→ **マスターハンドオフ §1.2 が "100%" の前提条件として挙げた 3 軸のすべてを同一セッションで閉じた。プロジェクトは「実用 90%+」に到達。**

### コミット履歴（feature/mcp-fresh-macos、このセッション分）

```
19853971f0  mcp_http: add session/export_audio — open the delivery port (T1)
a57ca28a40  docs: log Wave T1 in MCP handoff
43f4848f09  mcp_http: add SSE GET /events + notifications/transport (T3 MVP)
77c4e27daa  docs: log Wave T3 in MCP handoff
ee8ffb10fd  mcp_http: add automation/{get_lane,set_curve,set_mode} (T2 MVP)  ← 本コミット
```

---

## 10. 推奨次波

§7 の推奨着手順（T1 → T2 → T3）がすべて完了した。次の候補（master README.md §7 より抜粋）：

### T4: テンポ / 拍子編集（次優先）
- **ツール**: `tempo/add`, `tempo/change`, `tempo/remove`, `meter/set`
- **駆動先**: `TempoMap::write_copy()` → 編集 → `update()`（`libs/temporal/temporal/tempo.h:785-841`）
- **完成条件**: 「2 小節目から BPM 140 にして」が反映、再生で確認
- **複雑度**: M / 依存なし

### T5: フェード / クロスフェード制御
- **ツール**: `region/set_fade_in`, `region/set_fade_out`, `region/set_crossfade`
- **駆動先**: `AudioRegion::set_fade_in_length`, `set_fade_in_shape`
- **完成条件**: 「クリップ末尾に 1 秒フェードアウト」が反映
- **複雑度**: S〜M

### T9: ターン制ロック（エージェント安全性）
- **設計**: fix_plan v2 §5 で設計済み（作業ホスト PDF 参照）
- **ツール**: `acquire_turn`, `release_turn`, `get_lock_state`
- **完成条件**: 取得 → 一連の編集 → release で 1 undo エントリ
- **複雑度**: M

### T11: コンパニオン — ツール選別 UI（コスト最適化）
- **理由**: 100 tools になったため `tools/list` で毎回全スキーマを送ると system トークン消費が大
- **どこ**: `renderer.js` にカテゴリ別 on/off チェックボックス追加
- **複雑度**: S

ユーザーの優先度が「DAW 機能の深さ」なら T4/T5、「エージェント安全性」なら T9、「コスト最適化」なら T11 を先に進めることを推奨する。

---

## 11. resume コマンド

```bash
# 1) リポ確認
cd /Volumes/work-ssd-4TB-USB4/_Git_Repository/ardour-mcp/ardour
git log --oneline feature/mcp-fresh-macos | head -10
# expect: ee8ffb10fd at HEAD

# 2) インクリメンタルビルド（変更がある場合）
PCP=""
for f in glibmm@2.66 curl libarchive libxml2 cairomm@1.14 pangomm@2.46 atkmm@2.28 libsigc++@2; do
  d="$(brew --prefix $f 2>/dev/null)/lib/pkgconfig"; [ -d "$d" ] && PCP="$PCP:$d"
done
export PKG_CONFIG_PATH="${PCP#:}:/opt/homebrew/lib/pkgconfig:/opt/homebrew/share/pkgconfig"
GETTEXT="$(brew --prefix gettext)"
python3 ./waf -j10 2>&1 | tee /tmp/ardour_build.log
grep -E "'build' finished successfully|Build failed" /tmp/ardour_build.log | tail -3

# 3) dylib 存在確認
ls -lh build/libs/surfaces/mcp_http/libardour_mcp_http.dylib

# 4) string table で 100 ツール確認
strings build/libs/surfaces/mcp_http/libardour_mcp_http.dylib | grep -c '"name": "'
# expect: 100

# 5) automation ツールの文字列確認
strings build/libs/surfaces/mcp_http/libardour_mcp_http.dylib | grep 'automation'
# expect: automation/get_lane, automation/set_curve, automation/set_mode (slash)
#         automation_get_lane, automation_set_curve, automation_set_mode (underscore)

# 6) Ardour 起動（ライブ検証時）
./gtk2_ardour/ardev
# GUI: Edit > Preferences > Control Surfaces > "MCP HTTP Server (Experimental)" ON

# 7) ライブ疎通確認
curl -s -X POST -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}' \
  http://127.0.0.1:4820/mcp

# 8) tools/list で 100 ツール確認
curl -s -X POST -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' \
  http://127.0.0.1:4820/mcp \
  | python3 -c "import json,sys; t=json.load(sys.stdin)['result']['tools']; print(len(t), [x['name'] for x in t if 'automation' in x['name']])"
# expect: 100 ['automation/get_lane', 'automation/set_curve', 'automation/set_mode']

# 9) get_lane 疎通テスト（<ROUTE_ID> を実際の route id に置換）
curl -s -X POST -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"automation/get_lane","arguments":{"id":"<ROUTE_ID>","parameter":"gain"}}}' \
  http://127.0.0.1:4820/mcp

# 10) set_curve テスト — gain を 0→4s で 1.0、4→8s で 0.5 にセット
curl -s -X POST -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"automation/set_curve","arguments":{"id":"<ROUTE_ID>","parameter":"gain","points":[{"timeSec":0.0,"value":1.0},{"timeSec":4.0,"value":0.5}]}}}' \
  http://127.0.0.1:4820/mcp

# 11) set_mode テスト — gain automation を play にセット
curl -s -X POST -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"automation/set_mode","arguments":{"id":"<ROUTE_ID>","parameter":"gain","mode":"play"}}}' \
  http://127.0.0.1:4820/mcp

# 12) SSE ストリームも同時確認（別ターミナルで）
curl -N -H 'Accept: text/event-stream' http://127.0.0.1:4820/events
```

---

## 12. file:line チートシート

| 関数 / 要素 | ファイル | 備考 |
|---|---|---|
| `resolve_automation_parameter(name, err)` | `libs/surfaces/mcp_http/mcp_http_server.cc` | diff +8〜+19、パラメータ名 → `Evoral::Parameter` |
| `get_route_automation_control(route, param)` | 同上 | diff +21〜+47、fail-closed lookup |
| `auto_state_to_mcp_string(s)` | 同上 | diff +49〜+61 |
| `mcp_string_to_auto_state(s, out, err)` | 同上 | diff +63〜+76、`"read"` = `"play"` alias |
| `handle_automation_get_lane_tool()` | 同上 | diff +78〜+157 |
| `handle_automation_set_curve_tool()` | 同上 | diff +159〜+265 |
| `handle_automation_set_mode_tool()` | 同上 | diff +267〜+326 |
| `dispatch_automation_tool_call()` | 同上 | diff +328〜+344 |
| `run_tools_call()` に dispatch 追加 | 同上 | diff +346〜+348 |
| tools_json.inc の 3 エントリ | `libs/surfaces/mcp_http/tools_json.inc` | diff +1〜+93 |
| `ControlList::editor_add_ordered` | `libs/evoral/ControlList.h` | 158-222 周辺 |
| `ControlList::EventList` / `events()` | `libs/evoral/ControlList.h` | 読み出し用イテレータ |
| `Automatable::set_parameter_automation_state` | `libs/ardour/ardour/automatable.h` | 104 |
| `AutoState` 列挙 (`Off/Play/Touch/Write/Latch`) | `libs/ardour/ardour/types.h` | automation_control.h 経由 |
| `AutomationControl::alist()` | `libs/ardour/ardour/automation_control.h` | → `shared_ptr<AutomationList>` |
| `MementoCommand<AutomationList>` | `libs/pbd/pbd/memento_command.h` | before/after XML でスナップショット |
| `route_by_mcp_id()` | `mcp_http_server.cc:253-301` | 既存フェイルクローズドヘルパ |
| `canonical_tool_name()` | `mcp_http_server.cc` | slash ↔ underscore 正規化 |
| `lws service thread → call_slot → event_loop` | `mcp_http_server.cc` | Wave 1 ハードニング以来のパターン |

---

*End of SESSION_2026-06-26_T2_AUTOMATION.md. 次の LLM へ：このセッション（T1+T3+T2）でマスターハンドオフの致命的欠落 3 軸がすべて閉じた。ライブ curl 検証（§11 step 6〜12）を先に実施し、次いで §10 の推奨次波から着手すること。*
