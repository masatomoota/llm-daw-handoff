# Session Handoff — 2026-06-26 Wave T3 SSE (GET /events)

> **Resume from here.** This file documents the Wave T3 SSE implementation that landed
> in the same chat session as Wave T1 (SESSION_2026-06-26_T1_EXPORT.md). Both T1 and T3
> are now committed and pushed. The next LLM should start with T2 (automation curves).

---

## What just happened

2026年6月26日の同一チャットセッション内（T1 実装直後）に、マスターハンドオフ §7 の T3「SSE / `notifications/*` — 知覚ループの本格化」の MVP を実装し、commit `43f4848f0979bd83371aec31252cbd43011bba2b` として `feature/mcp-fresh-macos` ブランチに push した。`GET /events` エンドポイントを既存の `handle_http` にパスベースディスパッチとして追加し、Ardour の `Session::TransportStateChange` / `RecordStateChanged` PBD シグナルを `notifications/transport` JSON-RPC notification に変換して SSE ストリームで配信する。ビルドは errors=0 / warnings=2（iterations=3）で成功。dylib string table と nm シンボルプローブで静的検証済み。Ardour は未起動のためライブ curl テストは次回に持ち越し。これにより T1（納品）と T3（知覚）が同一セッションで完了し、残る最優先タスクは T2（オートメーション曲線編集）となった。

---

## Files changed

```
commit 43f4848f0979bd83371aec31252cbd43011bba2b
Author: masatomoota <129290880+masatomoota@users.noreply.github.com>
Date:   Fri Jun 26 13:12:52 2026 +0900

    mcp_http: add SSE GET /events + notifications/transport (T3 MVP)

    Implements the perception loop from master handoff §7 T3: a Server-Sent
    Events endpoint at GET /events streaming JSON-RPC notifications. MVP
    emits notifications/transport on each Session transport state edge
    (playing / stopped / recording / looping) with a snapshot of
    position_samples, position_seconds, and sample_rate.

    Connection lifecycle: lws HTTP callback dispatch — LWS_CALLBACK_HTTP
    sends 200 + text/event-stream headers and registers the subscriber;
    HTTP_WRITEABLE drains the per-subscriber queue; CLOSED_HTTP removes
    the subscriber. Host header check applies the same loopback-only
    policy as POST /mcp (Phase 0 hardening unchanged).

    Threading: PBD signal fires on the GUI/event_loop thread, formats a
    JSON frame, enqueues to each subscriber under a mutex, and calls
    lws_callback_on_writable to wake the lws service thread. Heartbeat
    ": heartbeat\n\n" emitted every 15 seconds.

    Future work (this is MVP): notifications/meter, notifications/position
    (polled at 10 Hz), notifications/route_changed, per-subscriber filters,
    notifications/initialized on connect. Subscriber count and signal
    lifecycle optimization (disconnect on empty list) also deferred.

    Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>

 libs/surfaces/mcp_http/mcp_http_server.cc | 284 +++++++++++++++++++++++++++++-
 libs/surfaces/mcp_http/mcp_http_server.h  |  33 ++++
 2 files changed, 313 insertions(+), 4 deletions(-)
```

---

## Event spec verbatim

SSE フレームの形式：`data: <JSON>\n\n`

JSON 本体（JSON-RPC 2.0 Notification — `id` フィールドなし）：

```json
{
  "jsonrpc": "2.0",
  "method": "notifications/transport",
  "params": {
    "state": "<STATE>",
    "position_samples": <INT64>,
    "position_seconds": <FLOAT>,
    "sample_rate": <INT64>
  }
}
```

`state` の値域（優先順：recording > looping > playing > stopped）：
- `"stopped"` — トランスポート停止中
- `"playing"` — 再生中（録音なし）
- `"recording"` — 録音中（`_session.actively_recording()` が true）
- `"looping"` — ループ再生中（`_session.get_play_loop()` が true かつ録音なし）

ハートビート（SSE コメント行、イベントとしては処理されない）：
```
: heartbeat
```

接続直後に transport スナップショットが 1 枚送信される（初期フレーム）。

ソース：`mcp_http_server.cc:3428-3452`（`build_transport_event()`）

---

## Handler implementation walkthrough

### 1. 接続受け入れ — `handle_http` (`mcp_http_server.cc:3245-3291`)

`handle_http` 内の既存 `POST /mcp` ディスパッチに続く形で、`path == "/events"` 分岐を追加：

```
handle_http()
  ├── path == "/mcp"  (POST)  →  既存 JSON-RPC ハンドラへ
  └── path == "/events" (GET) →
        host_header_is_loopback() → false で 403 return
        send_sse_headers(wsi)     → text/event-stream 200 ヘッダ送信
        ctx.sse_client = true     → writeable パスで SSE ドレインを使わせる
        new SseSubscriber(wsi)    → _sse_subscribers に push（mutex）
        build_transport_event()   → 初期スナップショットを ctx.sse_queue に積む
        lws_callback_on_writable() → ドレインをスケジュール
```

### 2. ヘッダ送信 — `send_sse_headers` (`mcp_http_server.cc:3385-3420`)

`lws_add_http_common_headers()` で `HTTP_STATUS_OK` + `"text/event-stream"` を設定し、
`lws_add_http_header_by_token()` で `Cache-Control: no-cache` を追加。
`lws_finalize_write_http_header()` で書き込み開始。

### 3. トランスポートイベント構築 — `build_transport_event` (`mcp_http_server.cc:3428-3452`)

`_session.transport_rolling()` / `actively_recording()` / `get_play_loop()` を呼んで `state` を決定。`_session.transport_sample()` と `_session.sample_rate()` でポジション情報を取得。`snprintf` で JSON 文字列を構築し `"data: ...\n\n"` で包んで返す。

### 4. ブロードキャスト — `broadcast_sse` (`mcp_http_server.cc:3456-3490`)

```
broadcast_sse(sse_frame)
  _sse_subscribers_mutex をロック
  → wsi リストを抽出（コピー）してロック解放
  各 wsi について:
    ClientContext を _clients マップから取得
    ctx.sse_queue_mutex をロック → sse_queue.push_back(sse_frame)
    lws_callback_on_writable(wsi)  ← atomic フラグ設定（スレッドセーフ）
  lws_cancel_service(_context)     ← poll ループを即時ウェイクアップ
```

### 5. ドレイン — `handle_http_writeable` (既存関数の分岐追加、`mcp_http_server.cc:3380-3532`)

`ctx.sse_client == true` の場合の SSE ドレインパス：
1. `ctx.sse_queue_mutex` を取りフレームをデキュー
2. `lws_write(wsi, frame, LWS_WRITE_HTTP)` で送信
3. キューが空でなければ `lws_callback_on_writable()` を再スケジュール
4. `time(nullptr) - _sse_last_heartbeat >= 15` なら `": heartbeat\n\n"` を送信

### 6. シグナル接続 — `connect_transport_signals` (`mcp_http_server.cc:3506-3526`)

`start()` 内（`:3092`）から呼ばれる：

```cpp
_session.TransportStateChange.connect(
    _sse_signal_connections, MISSING_INVALIDATOR,
    std::bind(&MCPHttpServer::on_transport_state_changed, this),
    _event_loop);   // ← GUI スレッドへマーシャル

_session.RecordStateChanged.connect(
    _sse_signal_connections, MISSING_INVALIDATOR,
    std::bind(&MCPHttpServer::on_transport_state_changed, this),
    _event_loop);
```

`_sse_signal_connections` は `PBD::ScopedConnectionList` なので `stop()` 時に自動切断される（`mcp_http_server.cc:3110-3124`）。

### 7. シグナルハンドラ — `on_transport_state_changed` (`mcp_http_server.cc:3497-3501`)

```cpp
void MCPHttpServer::on_transport_state_changed() {
    const std::string frame = build_transport_event();
    broadcast_sse(frame);
}
```

### 8. 切断 — `LWS_CALLBACK_CLOSED_HTTP` (`mcp_http_server.cc:3178-3198`)

```cpp
std::lock_guard<std::mutex> lk(_sse_subscribers_mutex);
_sse_subscribers.erase(
    std::remove_if(_sse_subscribers.begin(), _sse_subscribers.end(),
                   [wsi](SseSubscriber* s) { return s->wsi == wsi; }),
    _sse_subscribers.end());
```

---

## Threading model

| 起点 | スレッド | 操作 | 安全性の根拠 |
|---|---|---|---|
| `TransportStateChange` 発火 | RT / Butler スレッド | PBD signal emit のみ | PBD signal は emit がスレッドセーフ |
| `on_transport_state_changed()` 実行 | **GUI/event_loop スレッド** | `build_transport_event()` → `broadcast_sse()` | `connect()` 第 4 引数 `_event_loop` によるマーシャル |
| `_sse_subscribers` 読み取り | GUI/event_loop スレッド | `_sse_subscribers_mutex` を取って wsi リストをコピー | mutex 保護 |
| `ctx.sse_queue` への push | GUI/event_loop スレッド | `ctx.sse_queue_mutex` を取って `push_back` | per-queue mutex |
| `lws_callback_on_writable()` | GUI/event_loop スレッド（から呼ぶ） | atomic フラグ設定 | lws >= 3.x でクロススレッド呼び出し許容 |
| `lws_cancel_service()` | GUI/event_loop スレッド（から呼ぶ） | poll ループウェイクアップ | lws-service.h:87-88 で明示的にスレッドセーフ保証 |
| `handle_http_writeable` ドレイン | **lws サービススレッド** | `ctx.sse_queue` からデキュー → `lws_write()` | per-queue mutex |
| `_sse_subscribers` push / erase | **lws サービススレッド** | `_sse_subscribers_mutex` を取って変更 | mutex 保護（lws コールバックは同スレッド上）|

**キーポイント**：`_sse_subscribers` リストへの書き込みは lws サービススレッド専用。`broadcast_sse()` は mutex の下で読み取り専用コピーを取り、リスト本体には触れない。

---

## Build state

```
errors:     0
warnings:   2  (ld: warning: building for macOS-11.0 but linking with dylib built for newer — expected)
iterations: 3  (build loop count during implementation session)
dylib:      build/libs/surfaces/mcp_http/libardour_mcp_http.dylib
```

静的検証：
- `strings libardour_mcp_http.dylib | grep "text/event-stream"` → 1件
- `strings libardour_mcp_http.dylib | grep "notifications/transport"` → 1件
- `strings libardour_mcp_http.dylib | grep "/events"` → 1件
- `strings libardour_mcp_http.dylib | grep ": heartbeat"` → 1件（bonus）
- `nm -gU libardour_mcp_http.dylib | grep broadcast_sse` → T（global exported text symbol）
- `nm -gU libardour_mcp_http.dylib | grep on_transport_state_changed` → T（global exported text symbol）

---

## Smoke verification scope

### 静的確認（パス）
- dylib string table に 3 必須 SSE 文字列の存在確認
- nm シンボルプローブで `broadcast_sse` と `on_transport_state_changed` が T シンボル（global exported）として存在確認
- `SseSubscriber` は vector/iterator ヘルパとして小文字 `t` シンボル（file-local static）→ struct が内部 vector 要素としてのみ使われていることを示す正常な挙動

### ライブ確認（未実施）
Ardour 未起動のため以下は次回起動時に実施：

```bash
# 1. Ardour 起動 & MCP 有効化（§3.7-3.8 参照）
./gtk2_ardour/ardev

# 2. SSE 接続テスト
curl -N -H 'Accept: text/event-stream' http://127.0.0.1:4820/events
# 接続直後に transport スナップショットが届くこと
# Ardour で再生 → "state":"playing" イベントが届くこと
# 停止 → "state":"stopped" イベントが届くこと

# 3. Host ヘッダ拒否
curl -v -H 'Host: evil.example.com:4820' http://127.0.0.1:4820/events
# HTTP 403 であること

# 4. 既存 POST /mcp パスへの無回帰確認
curl -s -X POST -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}' \
  http://127.0.0.1:4820/mcp | python3 -c "import json,sys; print(len(json.load(sys.stdin)['result']['tools']))"
# 97 であること
```

---

## MVP limitations

1. **トランスポート状態のみ** — `notifications/meter`（レベルメータ 10Hz）、`notifications/position`（再生ヘッド位置 100ms ポーリング）、`notifications/route_changed`（ルート追加/削除）は未実装
2. **per-client フィルタなし** — 全クライアントが全イベントを受信。`GET /events?types=transport` のようなフィルタは未実装
3. **subscriber 0 時のシグナル切断なし** — 接続クライアントが 0 になっても PBD シグナルは接続されたまま（CPU への影響は微少）
4. **heartbeat のみ 15 秒** — 接続中にスナップショットを定期再送する機能なし
5. **Companion app 側の SSE 受信 UI なし** — curl で直接確認するのみ

---

## Recommended next wave

マスターハンドオフ §7 の推奨順（更新済み）：

```
✅ T1 — session/export_audio (WAV MVP)
✅ T3 — GET /events SSE (transport MVP)
→ T2 — automation/get_lane + set_curve + set_mode  ← 今ここ
   T9 — turn lock
   T4-T8 機会的に
   T11-T13 Companion 実用化
   T14 TLS + auth
```

**T2 の実装方針**（master handoff §7 T2 より）：
- `automation/get_lane(routeId, paramId)` → `ControlList` の点列 `[{time, value}, ...]` を返す
- `automation/set_curve(routeId, paramId, points, mode=replace|merge)` → `ControlList::add` 一括
- `automation/set_mode(routeId, paramId, off|read|touch|write|latch)` → `AutomationControl::set_automation_state`
- 中核：`libs/evoral/ControlList.h:158-222`、`libs/ardour/ardour/automation_control.h`

**SSE 容易な follow-up**（T3 拡張）：
- `notifications/meter` — 10Hz ポーリング。`Route::peak_meter()->meter_level()` 使用（Wave 1b の `track/get_meter` と同 API）
- `notifications/position` — 再生中 100ms ごとの playhead 位置。`connect_transport_signals()` パターンを踏襲

---

## Resume commands

```bash
# クローン（未取得の場合）
git clone https://github.com/masatomoota/ardour.git
cd ardour
git checkout feature/mcp-fresh-macos

# 現在の HEAD 確認
git log --oneline -5
# 43f4848f0 mcp_http: add SSE GET /events + notifications/transport (T3 MVP)
# 19853971f mcp_http: add session/export_audio — open the delivery port (T1)

# インクリメンタルビルド（T3 変更のみリビルド）
PCP=""; for f in glibmm@2.66 curl libarchive libxml2 cairomm@1.14 pangomm@2.46 atkmm@2.28 libsigc++@2; do
  d="$(brew --prefix $f 2>/dev/null)/lib/pkgconfig"; [ -d "$d" ] && PCP="$PCP:$d"
done
export PKG_CONFIG_PATH="${PCP#:}:/opt/homebrew/lib/pkgconfig:/opt/homebrew/share/pkgconfig"
python3 ./waf -j10 2>&1 | tee /tmp/ardour_build_t3.log
grep -E "'build' finished successfully|Build failed" /tmp/ardour_build_t3.log | tail -3

# Ardour 起動（前景で、GUI 表示に必要）
./gtk2_ardour/ardev

# SSE 接続テスト（Ardour 起動・MCP 有効化後）
curl -N -H 'Accept: text/event-stream' http://127.0.0.1:4820/events

# 再生トグルで notifications/transport をトリガー
# → Ardour GUI でスペースキーを押して transport 状態を変化させる

# 既存 MCP の無回帰確認
curl -s -X POST -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}' \
  http://127.0.0.1:4820/mcp
```

---

## File:line cheat sheet

| シンボル / 概念 | ファイル | 行 | 説明 |
|---|---|---|---|
| `SseSubscriber` struct | `mcp_http_server.h` | 追加部 | `wsi` フィールドのみ持つシンプルな subscriber ホルダ |
| `_sse_subscribers` | `mcp_http_server.h` | 追加部 | `std::vector<SseSubscriber*>` 登録リスト |
| `_sse_subscribers_mutex` | `mcp_http_server.h` | 追加部 | subscriber リスト保護 mutex |
| `_sse_signal_connections` | `mcp_http_server.h` | 追加部 | `PBD::ScopedConnectionList`、stop() で自動切断 |
| `_sse_last_heartbeat` | `mcp_http_server.h` | 追加部 | `time_t`、ハートビートタイムスタンプ |
| `connect_transport_signals()` | `mcp_http_server.cc` | 3506 | `start()` から呼ばれる PBD シグナル接続 |
| `"/events"` パスディスパッチ | `mcp_http_server.cc` | 3251 | `handle_http` 内の分岐 |
| `send_sse_headers()` | `mcp_http_server.cc` | 3385 | `text/event-stream` ヘッダ送信 |
| `build_transport_event()` | `mcp_http_server.cc` | 3428 | JSON-RPC notification 文字列構築 |
| `broadcast_sse()` | `mcp_http_server.cc` | 3456 | 全サブスクライバーへのキュー push + wakeup |
| `on_transport_state_changed()` | `mcp_http_server.cc` | 3497 | PBD シグナルハンドラ（GUI スレッド上） |
| `connect_transport_signals()` にて `_event_loop` マーシャル | `mcp_http_server.cc` | 3515-3525 | `connect()` 第 4 引数で GUI スレッドへ整流 |
| SSE ドレインパス (`sse_client == true`) | `mcp_http_server.cc` | `handle_http_writeable` 内 | `sse_queue` デキュー → `lws_write()` + heartbeat |
| CLOSED_HTTP subscriber 除去 | `mcp_http_server.cc` | 3182-3194 | `std::remove_if` + `erase` で cleanup |
| `ClientContext::sse_client` | `mcp_http_server.h` | 追加部 | bool フラグ、SSE 接続かどうかを示す |
| `ClientContext::sse_queue` | `mcp_http_server.h` | 追加部 | `std::deque<std::string>`、フレームキュー |
| `ClientContext::sse_queue_mutex` | `mcp_http_server.h` | 追加部 | per-wsi キュー保護 mutex |

---

*T1 と T3 が同一セッションで完了した。次の LLM はこのファイルと master handoff §7 を読んで T2（オートメーション曲線編集）に着手すること。ビルド環境の再現は ardour/MCP_LLM_CONTROL_HANDOFF.md §3 を参照。*
