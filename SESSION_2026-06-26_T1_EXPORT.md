# セッションハンドオフ — 2026-06-26 / Wave T1: session/export_audio

> **用途**: このファイルは次の LLM が本セッションの作業を継続するために必要な情報を「グレインレベル」で記録したターン再開用ドキュメント。これを読んだ LLM はユーザーに歴史を尋ねることなく即座に着手できる。

---

## 1. What just happened（1 段落サマリ）

2026-06-26 のセッションで、Ardour MCP サーフェスにマスターハンドオフ（`masatomoota/llm-daw-handoff`）§7 の最優先タスク T1「`session/export_audio`」を実装した。具体的には `libs/surfaces/mcp_http/mcp_http_server.cc` に 303 行の追加（`handle_session_export_audio_tool()` 実装 + `dispatch_session_tool_call()` への分岐）、`tools_json.inc` に 45 行（スキーマ定義）、`wscript` に 1 行変更（`SNDFILE` 依存追加）を行い、ブランチ `feature/mcp-fresh-macos` の `masatomoota/ardour` fork に push した。ビルドは errors=0 / warnings=8 で成功し、生成された dylib の string table で `session/export_audio`（count=1）と `session_export_audio`（count=1）の存在を確認した。Ardour は起動していなかったため live curl テストは未実施。ツール数は 96 → 97 になった。ハンドオフ文書（本ファイル、`README.md`、`ardour/MCP_LLM_CONTROL_HANDOFF.md`）もこのセッションで更新された。

---

## 2. Files changed（git show --stat 19853971f07f6f81413b55a298487e5574efa98c）

```
commit 19853971f07f6f81413b55a298487e5574efa98c
Author: masatomoota <129290880+masatomoota@users.noreply.github.com>
Date:   Fri Jun 26 10:52:10 2026 +0900

    mcp_http: add session/export_audio — open the delivery port (T1)

    Implements the highest-priority gap from the master handoff (§7 T1): a
    blocking MCP tool that exports the current Ardour session's master bus
    to a WAV file via Session::start_audio_export, awaited on the event_loop
    thread until export_status()->running goes false. MVP supports WAV /
    PCM_16|24|FLOAT, mono/stereo, arbitrary start/length and absolute path.

    Future work: FLAC / MP3 formats, async completion via SSE notifications,
    per-stem export. Tool count rises from 96 to 97.

    Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>

 libs/surfaces/mcp_http/mcp_http_server.cc | 303 +++++++++++++++++++++++++++
 libs/surfaces/mcp_http/tools_json.inc     |  45 ++++
 libs/surfaces/mcp_http/wscript            |   2 +-
 3 files changed, 349 insertions(+), 1 deletion(-)
```

全ての変更ファイルは `/Volumes/work-ssd-4TB-USB4/_Git_Repository/ardour-mcp/ardour/` 以下。

---

## 3. Tool spec（tools_json.inc の新エントリ、verbatim、行 142–186）

```json
{
  "name": "session_export_audio",
  "title": "Export Audio",
  "description": "Export the session master bus to an audio file and return metadata about the exported file. For the MVP only WAV (PCM) output is supported; FLAC, AIFF, and MP3 support may be added in a future release. The export runs in freewheel (offline) mode and blocks until complete. The caller must supply an absolute path for the output file; the parent directory must already exist. format defaults to \"wav\". sample_rate defaults to the session's nominal sample rate. sample_format may be \"PCM_16\" (default), \"PCM_24\", or \"FLOAT\". start_sec and length_sec define the export range in seconds; omit both to export the entire session. channels may be \"stereo\" (default) or \"mono\" (sums L+R from the master bus).",
  "inputSchema": {
    "type": "object",
    "properties": {
      "path": {
        "type": "string",
        "description": "Absolute filesystem path for the output file (e.g. /home/user/export/mix.wav). The parent directory must exist."
      },
      "format": {
        "type": "string",
        "enum": ["wav"],
        "description": "Output file format. Only \"wav\" is supported in the MVP."
      },
      "sample_rate": {
        "type": "number",
        "description": "Sample rate in Hz (e.g. 44100, 48000). Defaults to the session nominal sample rate."
      },
      "sample_format": {
        "type": "string",
        "enum": ["PCM_16", "PCM_24", "FLOAT"],
        "description": "PCM bit depth or float. Defaults to \"PCM_16\"."
      },
      "start_sec": {
        "type": "number",
        "minimum": 0,
        "description": "Export range start, in seconds from the session origin. Defaults to 0."
      },
      "length_sec": {
        "type": "number",
        "exclusiveMinimum": 0,
        "description": "Export range length in seconds. Defaults to the full session length."
      },
      "channels": {
        "type": "string",
        "enum": ["stereo", "mono"],
        "description": "\"stereo\" exports L+R from the master bus. \"mono\" sums them."
      }
    },
    "required": ["path"],
    "additionalProperties": false
  }
}
```

**MCP ツール名**：`session/export_audio` または `session_export_audio`（サーバの `canonical_tool_name` が両形を受理する）。

**outputSchema**：MVP では付与していない（`session_export_audio` エントリに `outputSchema` フィールドなし）。将来追加する際は `{ "type": "object", "required": ["path","bytes","sampleRate","channels","durationSec","format"], "properties": { ... } }` を追記。

---

## 4. Handler implementation walkthrough

ハンドラ本体：`libs/surfaces/mcp_http/mcp_http_server.cc:4298-4575`（`static std::string handle_session_export_audio_tool()`）

### 4.1 引数解析・検証（行 4302–4402）

| 引数 | デフォルト | 検証 |
|---|---|---|
| `path` | 必須 | 空チェック・NUL バイトチェック・`~` 展開・`Glib::path_is_absolute()` 確認・親ディレクトリ存在確認 |
| `format` | `"wav"` | MVP は `"wav"` のみ、それ以外は JSON-RPC error -32602 |
| `sample_rate` | セッションの nominal rate | 1〜384000 かつ `ExportFormatBase::SampleRate` 列挙値（22050/24000/44100/48000/88200/96000/176400/192000）のみ受理 |
| `sample_format` | `"PCM_16"` | `SF_16`/`SF_24`/`SF_Float` の 3 値のみ |
| `start_sec` | `0.0` | `>= 0` |
| `length_sec` | セッション全長 | `> 0` かつ range_end > range_start |
| `channels` | `"stereo"` | `"stereo"` または `"mono"` のみ |

### 4.2 マスターバス確認（行 4405–4419）

```cpp
std::shared_ptr<Route> master = session.master_out();      // ← Session::master_out()
IO* master_io = master->output().get();                    // ← Route::output()
if (master_io->n_ports().n_audio() == 0) ...              // ← no audio ports → error
const std::shared_ptr<ExportStatus> status = session.get_export_status();
if (status->running()) ...                                 // ← 二重起動防止
```

### 4.3 ExportFormatSpecification 構築（行 4431–4458）

```cpp
ExportFormatSpecPtr spec = handler->add_format();
std::shared_ptr<ExportFormatTaggedLinear> wav_fmt =
    std::make_shared<ExportFormatTaggedLinear>("WAV", ExportFormatBase::F_WAV);
wav_fmt->add_sample_format(ExportFormatBase::SF_16);  // ... SF_U8, SF_24, SF_32, SF_Float, SF_Double
wav_fmt->set_default_sample_format(ExportFormatBase::SF_16);
wav_fmt->set_extension("wav");
spec->set_format(wav_fmt);  // ← これが _has_sample_format=true をセット（重要）
spec->set_sample_rate(export_sr);
spec->set_sample_format(export_sf);
spec->set_dither_type(export_sf == SF_16 ? D_Shaped : D_None);
spec->set_name("MCP WAV Export");
spec->set_analyse(false);  // loudness 解析スキップ
```

**重要**：`spec->set_format(wav_fmt)` を呼ばないと私有フラグ `_has_sample_format` が false のままになり、export graph builder が `SF_None(0)` を libsndfile に渡してファイルオープンが無音のまま失敗する。`ExportFormatManager::add_format()` の既存実装（`export_format_manager.cc:161-171`）と同型で構築すること。

### 4.4 ExportFilename 構築（行 4466–4483）

```cpp
ExportFilenamePtr fn = handler->add_filename();
// strip trailing .wav from basename
fn->set_label(basename);     // 副作用: include_label=false になる
fn->include_label = true;    // 上書きして true に戻す（重要な quirk）
fn->include_session  = false;
fn->include_timespan = false;
fn->include_revision = false;
fn->include_date     = false;
fn->include_time     = false;
fn->set_folder(parent_dir);
```

### 4.5 ExportTimespan 構築（行 4486–4491）

```cpp
ExportTimespanPtr ts = handler->add_timespan();
ts->set_name("session");
ts->set_range_id("session");
ts->set_range(range_start, range_end);  // サンプル単位
ts->set_realtime(false);  // freewheel / offline mode
fn->set_timespan(ts);
```

### 4.6 ExportChannelConfiguration 構築（行 4497–4512）

```cpp
ExportChannelConfigPtr chan_cfg = handler->add_channel_config();
chan_cfg->set_name(mono_mixdown ? "mono" : "stereo");
if (mono_mixdown) {
    PortExportChannel* ch = new PortExportChannel();
    for (uint32_t n = 0; n < n_master_ports; ++n) {
        ch->add_port(master_io->audio(n));  // L+R を 1 チャンネルに積む
    }
    chan_cfg->register_channel(ExportChannelPtr(ch));
} else {
    for (uint32_t n = 0; n < n_master_ports; ++n) {  // ポートごとに 1 チャンネル
        PortExportChannel* ch = new PortExportChannel();
        ch->add_port(master_io->audio(n));
        chan_cfg->register_channel(ExportChannelPtr(ch));
    }
}
```

### 4.7 Export 開始とイベントループポンプ（行 4516–4548）

```cpp
handler->add_export_config(ts, chan_cfg, spec, fn, BroadcastInfoPtr());
const int do_ret = handler->do_export();   // ← フリーホイール開始

const auto export_deadline = std::chrono::steady_clock::now() + std::chrono::minutes(10);
while (status->running()) {
    if (gtk_events_pending()) {
        gtk_main_iteration();   // ← オーディオスレッドからの post-back を処理
    } else {
        Glib::usleep(10000);    // 10 ms
    }
    if (std::chrono::steady_clock::now() >= export_deadline) {
        status->abort(true);
        // ... abort 完了まで同様にポンプ
        return jsonrpc_error(id, -32000, "Export timed out after 10 minutes");
    }
}
```

### 4.8 後処理と結果返却（行 4550–4574）

```cpp
if (status->aborted()) return jsonrpc_error(...);
status->finish(TRS_UI);  // フリーホイール停止、状態リセット

const std::string out_path = fn->get_path(spec);  // 実際の出力パス
struct stat st {}; ::stat(out_path.c_str(), &st);

// 結果 JSON: { path, bytes, sampleRate, channels, durationSec, format }
```

---

## 5. Threading model

`handle_session_export_audio_tool()` が実行されるスレッドは**GUI / イベントループスレッド**。経路は：

```
[lws service thread]
  └ dispatch_jsonrpc() → tools/call
    └ EventLoop::call_slot(MISSING_INVALIDATOR, lambda { run_tools_call() })
      └ condvar.wait() ← lws スレッドここでブロック

[GUI/event-loop thread]
  └ run_tools_call()
    └ dispatch_session_tool_call()
      └ handle_session_export_audio_tool()   ← ここが実行される
          ├ handler->do_export()
          └ while (status->running()) { gtk_main_iteration() }
              ← GTK イベントループをポンプして
                 オーディオスレッドからの freewheel コールバックを処理
```

**ブロッキングが MVP で OK な理由**：lws スレッドは `condvar.wait()` でどうせブロックしているため、GUI スレッドが 10 分まで専有されても MCP プロトコルの観点からは「遅いレスポンス」にすぎない。GUI の再描画は `gtk_main_iteration()` で継続する。T3（SSE）実装後は非同期版に切り替えることが推奨。

---

## 6. Build state

```
success=true, errors=0, warnings=8
```

warnings 8 件の内訳：macOS deployment target 不一致（Homebrew formula が新しい macOS SDK でビルドされているため）。Ardour per-repo ハンドオフ §6.2-3 に記録済みの既知・無害な警告。

dylib パス：
```
/Volumes/work-ssd-4TB-USB4/_Git_Repository/ardour-mcp/ardour/build/libs/surfaces/mcp_http/libardour_mcp_http.dylib
```

string table 確認コマンド（再確認時）：
```bash
DYLIB=/Volumes/work-ssd-4TB-USB4/_Git_Repository/ardour-mcp/ardour/build/libs/surfaces/mcp_http/libardour_mcp_http.dylib
strings "$DYLIB" | grep -c "session/export_audio"   # expect: 1
strings "$DYLIB" | grep -c "session_export_audio"   # expect: 1
```

---

## 7. Smoke verification

### 実施したこと

1. ビルドログから `errors:0` を確認（`grep -c 'error:' /tmp/ardour_build.log`）
2. dylib string table で `session/export_audio` と `session_export_audio` を確認（各 count=1）
3. dylib に `protocol_descriptor` がエクスポートされていることを確認（`nm -gU dylib | grep protocol_descriptor`）

### 実施していないこと（次回確認事項）

Ardour が起動していなかったため（curl exit code 7, connection refused on `127.0.0.1:4820`）、以下は未確認：

- `tools/list` で 97 ツールが返ること
- `session/export_audio` が `tools/list` の中に存在すること
- 実際に WAV ファイルが生成されること

### 次回の live 確認手順

```bash
# 1. Ardour 起動
cd /Volumes/work-ssd-4TB-USB4/_Git_Repository/ardour-mcp/ardour
./gtk2_ardour/ardev /path/to/some/session.ardour
# GUI で Preferences → Control Surfaces → "MCP HTTP Server (Experimental)" ON

# 2. tools/list で 97 ツールと session_export_audio の存在を確認
curl -s -X POST -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' \
  http://127.0.0.1:4820/mcp \
  | python3 -c "import json,sys; t=json.load(sys.stdin)['result']['tools']; \
    print('total:', len(t)); \
    print([x['name'] for x in t if 'export' in x['name'] or 'meter' in x['name']])"
# expect: total: 97, ['session_export_audio', 'track_get_meter'] (or similar)

# 3. session/export_audio を実際に呼び出す
mkdir -p /tmp/ardour_export_test
curl -s -X POST -H 'Content-Type: application/json' \
  -d '{
    "jsonrpc":"2.0","id":10,"method":"tools/call",
    "params":{
      "name":"session_export_audio",
      "arguments":{
        "path":"/tmp/ardour_export_test/mix.wav",
        "sample_rate":48000,
        "sample_format":"PCM_24",
        "channels":"stereo"
      }
    }
  }' \
  http://127.0.0.1:4820/mcp
# expect: {"result":{"content":[{"type":"text","text":"Audio exported to: /tmp/ardour_export_test/mix.wav"}],"structuredContent":{"path":"...","bytes":N,"sampleRate":48000,"channels":2,"durationSec":D,"format":"wav"}}}

# 4. 生成ファイルの確認
ls -la /tmp/ardour_export_test/mix.wav
file /tmp/ardour_export_test/mix.wav
# expect: RIFF (little-endian) data, WAVE audio, 24-bit stereo, 48000 Hz
```

---

## 8. Limitations of this MVP

| 制限 | 詳細 | 解消策 |
|---|---|---|
| **WAV 専用** | `ExportFormatTaggedLinear` の `F_WAV` のみ | `F_FLAC` 等を追加、`wscript` に flac Homebrew 依存 |
| **ブロッキング** | GUI スレッドが最大 10 分専有される | T3（SSE）後に非同期版へ切替 |
| **マスターバス固定** | ステム・個別トラックエクスポート不可 | `export_stems` ツールを別スキーマで追加 |
| **LUFS 解析なし** | `spec->set_analyse(false)` でスキップ | `true` にして `ExportStatus::loudness_report()` を結果に含める |
| **live curl 未実施** | Ardour 未起動のため static 確認のみ | 次回 Ardour 起動時に §7 の確認コマンドを実行 |

---

## 9. Recommended next wave

マスターハンドオフ（`README.md`）§7 より：

> **T2: オートメーション曲線編集ツール群 — ミックスの本丸**
> - `automation/get_lane(routeId, paramId)` → 点列返却
> - `automation/set_curve(routeId, paramId, points, mode=replace|merge)` → `ControlList::add` 一括呼び出し
> - `automation/set_mode(routeId, paramId, off|read|touch|write|latch)` → `AutomationControl::set_automation_state`
> - 複雑度：M〜L、依存：なし

> **T3: SSE / `notifications/*` — 知覚ループの本格化**
> - `GET /events` SSE エンドポイント（`handle_http` に追加）
> - `lws_callback_on_writable` で `data: ...\n\n` を流す
> - PBD signal connection: `Session::PositionChanged`, `Route::gain_control()->Changed` 等
> - 複雑度：L、依存：なし
> - T3 実装後、`session/export_audio` の非同期版（`do_export` 後すぐ返却 → `notifications/export_complete`）も実現できる

**トレードオフ**：T2 は「今すぐミックスが高度になる」即効性。T3 は「既存 97 ツール全ての効果を perceive できる」基盤投資。ユーザー判断で決める。per-repo ハンドオフ（`ardour/MCP_LLM_CONTROL_HANDOFF.md §11.2`）の著者は T3（SSE）先行を推奨。マスターハンドオフ §7 の推奨着手順は T2 → T3。

---

## 10. Resume commands

```bash
# ---- 環境再構築 ----
cd /Volumes/work-ssd-4TB-USB4/_Git_Repository/ardour-mcp/ardour
git checkout feature/mcp-fresh-macos
git log --oneline | head -8  # 最新 commit が 19853971f0 であることを確認

# ---- Homebrew 依存（初回のみ）----
brew install pkg-config glib glibmm@2.66 libsndfile curl libarchive liblo \
  taglib vamp-plugin-sdk rubberband fftw libsamplerate libxml2 lv2 lilv suil \
  boost libwebsockets aubio gettext \
  cairomm@1.14 pangomm@2.46 atkmm@2.28

# ---- PKG_CONFIG_PATH 設定 ----
PCP=""
for f in glibmm@2.66 curl libarchive libxml2 cairomm@1.14 pangomm@2.46 atkmm@2.28 libsigc++@2; do
  d="$(brew --prefix $f 2>/dev/null)/lib/pkgconfig"; [ -d "$d" ] && PCP="$PCP:$d"
done
export PKG_CONFIG_PATH="${PCP#:}:/opt/homebrew/lib/pkgconfig:/opt/homebrew/share/pkgconfig"

# ---- Configure ----
GETTEXT="$(brew --prefix gettext)"
python3 ./waf configure --with-backends=coreaudio,dummy \
  --also-include="/opt/homebrew/include,$GETTEXT/include" \
  --also-libdir="/opt/homebrew/lib,$GETTEXT/lib" \
  --boost-include=/opt/homebrew/include

# ---- Incremental build（既にビルド済みなら数秒）----
python3 ./waf -j10 2>&1 | tee /tmp/ardour_build.log
grep -E "'build' finished successfully|Build failed" /tmp/ardour_build.log | tail -3
grep -c 'error:' /tmp/ardour_build.log  # → 0

# ---- Ardour 起動 ----
./gtk2_ardour/ardev /path/to/your/session.ardour
# GUI: Edit > Preferences > Control Surfaces > "MCP HTTP Server (Experimental)" ON

# ---- live 疎通確認 ----
curl -s -X POST -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}' \
  http://127.0.0.1:4820/mcp

# ---- session/export_audio テスト ----
mkdir -p /tmp/ardour_export_test
curl -s -X POST -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":10,"method":"tools/call","params":{"name":"session_export_audio","arguments":{"path":"/tmp/ardour_export_test/mix.wav","channels":"stereo"}}}' \
  http://127.0.0.1:4820/mcp
ls -la /tmp/ardour_export_test/mix.wav  # ファイルが存在すれば成功

# ---- 次波 T2 or T3 着手: 新ブランチを切る ----
git checkout -b feature/t2-automation    # T2 の場合
# または
git checkout -b feature/t3-sse          # T3 の場合
```

---

## 11. Where to find things（ファイル:行 チートシート）

| 何を探すか | ファイル | 行 |
|---|---|---|
| `handle_session_export_audio_tool()` 定義 | `libs/surfaces/mcp_http/mcp_http_server.cc` | 4298–4575 |
| `dispatch_session_tool_call()` の分岐 | `libs/surfaces/mcp_http/mcp_http_server.cc` | 4633–4635 |
| `run_tools_call()` — all dispatcher calls | `libs/surfaces/mcp_http/mcp_http_server.cc` | 8410–8430 付近 |
| `session_export_audio` スキーマ | `libs/surfaces/mcp_http/tools_json.inc` | 142–186 |
| `wscript` の `SNDFILE` uselib 追加 | `libs/surfaces/mcp_http/wscript` | 変更行（`SNDFILE` を追加した行） |
| `ExportFormatTaggedLinear` 既存参照実装 | `libs/ardour/export_format_manager.cc` | 161–171 |
| `ExportDialog::show_progress()` — GTK ポンプの参照実装 | `gtk2_ardour/export_dialog.cc` | 410–418 |
| `ExportChannelConfiguration` API | `libs/ardour/ardour/export_channel_configuration.h` | — |
| `ExportTimespan` API | `libs/ardour/ardour/export_timespan.h` | — |
| `ExportFormatSpecification` API | `libs/ardour/ardour/export_format_specification.h` | — |
| `ExportStatus::running()` / `finish()` / `abort()` | `libs/ardour/ardour/export_status.h` | — |
| `Session::get_export_handler()` | `libs/ardour/ardour/session.h` | — |
| `Session::master_out()` | `libs/ardour/ardour/session.h` | — |
| ハンドオフ：スレッドモデル詳細 | `ardour/MCP_LLM_CONTROL_HANDOFF.md` | §5.1–§5.2 |
| ハンドオフ：Wave T1 詳細 | `ardour/MCP_LLM_CONTROL_HANDOFF.md` | §13 |
| マスターハンドオフ：T2/T3 タスク仕様 | `handoff/README.md` | §7 (T2, T3) |

---

*End of session handoff. 次の LLM へ：上記 §10 の resume commands で環境を確認し、live テストを実施してから T2 または T3 に着手。不明点は `ardour/MCP_LLM_CONTROL_HANDOFF.md` §0 を参照。*
