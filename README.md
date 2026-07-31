# AutoCAD MCP Server

MCP server for AutoCAD LT automation and headless DXF generation.

Two backends, one API:

| Backend | Runtime | Requires AutoCAD? | Screenshot |
|---------|---------|-------------------|------------|
| **File IPC** | Windows Python | Yes — AutoCAD LT 2024+ (Windows) | Win32 PrintWindow |
| **ezdxf** | Any platform | No (headless) | matplotlib render |

The server exposes **9 consolidated tools** (`drawing`, `entity`, `layer`, `block`, `annotation`, `pid`, `view`, `system`, `execute_lisp`) over the MCP stdio transport. An MCP client (Claude Desktop, Claude Code, etc.) connects and drives AutoCAD through natural-language requests.

## Prerequisites (File IPC backend)

- **Windows 10/11** (the File IPC backend uses Win32 APIs for focus-free window messaging)
- **AutoCAD LT 2024 or newer** — AutoLISP support was added in LT 2024 for Windows. AutoCAD LT for Mac exists but does **not** support AutoLISP.
- **Python 3.10+** (Windows native — not WSL Python)
- **uv** package manager ([install guide](https://docs.astral.sh/uv/getting-started/installation/))

> The ezdxf headless backend works on any platform (Linux, macOS, WSL) for offline DXF generation without AutoCAD installed.

## Quick Start

### 1. Clone and install

```powershell
git clone https://github.com/puran-water/autocad-mcp.git
cd autocad-mcp
uv sync
```

### 2. Load the LISP dispatcher in AutoCAD

**This happens automatically.** On startup the server writes an `acaddoc.lsp`
into AutoCAD's per-user roamable support folder, which is on the support file
search path by default — so no OPTIONS dialog and no registry editing. Restart
AutoCAD once after first running the server and the dispatcher is loaded into
every drawing from then on.

This matters because AutoLISP definitions live in a per-document namespace: a
dispatcher loaded by hand exists only in the drawing that was open at the time,
so opening or switching drawings leaves the server silent until you reload.
`acaddoc.lsp` is read once per document, which is what makes it follow you.

The generated block also adds `<repo>/lisp-code` to `TRUSTEDPATHS`. Without it,
SECURELOAD raises a modal dialog when loading from an untrusted folder, and a
modal dialog blocks the IPC channel — the server hangs rather than fails.

> **This is a security relaxation.** Any `.lsp`, `.fas` or `.arx` in that folder
> will load without a SECURELOAD warning from then on. Set
> `AUTOCAD_MCP_AUTOLOAD=0` to leave AutoCAD's configuration untouched, and load
> the dispatcher by hand instead.

Inspect or reverse it:

```bash
python scripts/install_autoload.py --dry-run
```

```bash
python scripts/install_autoload.py --uninstall
```

The generated lines live inside a marked block, so an existing `acaddoc.lsp`
keeps whatever else it contains, reinstalling replaces the block rather than
appending a copy, and uninstalling removes only what was added.

**Manual alternative — APPLOAD:**

1. Type `APPLOAD` in the AutoCAD command line
2. Browse to `<repo>/lisp-code/mcp_dispatch.lsp`
3. Click **Load**
4. You should see `=== MCP Dispatch v3.3 loaded ===` and the registered command count

> `mcp_dispatch.lsp` is a loader that finds its modules with `findfile`. When
> loading it by absolute path from a folder that is not on the support file
> search path, set `(setq *mcp-lisp-dir* "C:/path/to/lisp-code/")` first, or it
> will report the modules as missing.

### 3. Configure your MCP client

Add to your MCP client configuration (e.g. Claude Desktop `claude_desktop_config.json`):

```json
{
  "mcpServers": {
    "autocad-mcp": {
      "command": "C:\\path\\to\\autocad-mcp\\.venv\\Scripts\\python.exe",
      "args": ["-m", "autocad_mcp"],
      "env": { "AUTOCAD_MCP_BACKEND": "auto" }
    }
  }
}
```

**Key points:**

- The `command` must point to the **Windows Python** inside the project venv (not WSL python).
- `AUTOCAD_MCP_BACKEND` can be `auto` (default — tries File IPC, falls back to ezdxf), `file_ipc` (requires AutoCAD), or `ezdxf` (headless only).

#### Running from WSL

If your MCP client runs in WSL (e.g. Claude Code), launch the server through `cmd.exe` so it runs as a native Windows process:

```json
{
  "mcpServers": {
    "autocad-mcp": {
      "type": "stdio",
      "command": "cmd.exe",
      "args": ["/d", "/s", "/c", "cd /d C:\\path\\to\\autocad-mcp && .venv\\Scripts\\python.exe -m autocad_mcp"],
      "env": { "AUTOCAD_MCP_BACKEND": "auto" }
    }
  }
}
```

### 4. Verify

From your MCP client, call:

```
system(operation="status")
```

You should see `backend: "file_ipc"` if AutoCAD is running, or `backend: "ezdxf"` for headless mode.

## Tools

### `drawing` — File/drawing management

| Operation | Description | File IPC | ezdxf |
|-----------|-------------|----------|-------|
| `create` | Reset to clean drawing (erase all + purge) | Yes | Yes |
| `open` | Open an existing drawing | Yes | Yes (DXF) |
| `info` | Get entity count and layers | Yes | Yes |
| `save` | Save current drawing (to path if given) | Yes | Yes |
| `save_as_dxf` | Export as DXF | Yes | Yes |
| `plot_pdf` | Plot to PDF | Yes | No |
| `purge` | Purge unused objects | Yes | Yes |
| `get_variables` | Get system variables by name | Yes | Yes |
| `undo` | Undo last operation | Yes | No |
| `redo` | Redo last undone operation | Yes | No |

### `entity` — Entity CRUD + modification

**Create:** `create_line`, `create_circle`, `create_polyline`, `create_rectangle`, `create_arc`, `create_ellipse`, `create_mtext`, `create_hatch`

**Read:** `list`, `count`, `get`

`list` is bounded. It returns at most `limit` entities (default 200) alongside
`total`, the number of matches, so a truncated result is never mistaken for a
complete one. Scope the query before running it on a large drawing:

| `data` field | Effect |
|---|---|
| `type` | `"INSERT"` or `"INSERT,TEXT"` — filter by DXF type |
| `bbox` | `[x1, y1, x2, y2]` — keep entities whose base point is inside the window (any two opposite corners) |
| `limit` | Max entities returned; `0` returns just the count |
| `offset` | Page through matches beyond the first `limit` |

`get` returns geometry for LINE, CIRCLE, ARC, ELLIPSE, POINT, TEXT/ATTDEF/ATTRIB,
MTEXT, INSERT, and LWPOLYLINE/POLYLINE. Angles come back in degrees, matching the
create/rotate operations. Vertex lists are capped at 200 with `vertices_truncated`
set.

**Modify:** `copy`, `move`, `rotate`, `scale`, `mirror`, `offset`\*, `array`, `fillet`\*, `chamfer`\*, `erase`

> \* `offset`, `fillet`, `chamfer` are File IPC only (not supported in ezdxf headless backend).

### `layer` — Layer management

`list`, `create`, `set_current`, `set_properties`, `freeze`, `thaw`, `lock`, `unlock`

### `block` — Block operations

| Operation | File IPC | ezdxf |
|-----------|----------|-------|
| `extract` | Yes | Yes |
| `list` | Yes | Yes |
| `insert` | Yes | Yes |
| `insert_with_attributes` | Yes | Yes |
| `get_attributes` | Yes | Yes |
| `update_attribute` | Yes | Yes |
| `define` | No | Yes |

`extract` bulk-reads blocks with their attributes in a single round trip. Use it
instead of looping `get_attributes`, which costs one dispatch per block — a few
hundred blocks turns into minutes of IPC. `data` accepts:

| Field | Effect |
|---|---|
| `layer` | Exact layer match |
| `name` | Case-insensitive substring of the block name, **resolved through dynamic-block instances** — an instance stored as `*U222` matches its real name `BS013` |
| `tags` | `["MNR","KM"]` to return only those attributes rather than all of them |
| `bbox` | `[x1, y1, x2, y2]` on the insertion point |
| `limit` / `offset` | Cap (default 100) and paging; `total` is always reported |

Cheap filters run before the expensive work — effective-name resolution costs an
ActiveX call and attribute reading walks sub-entities — so a scoped query stays
well inside the IPC timeout. Measured on a 4,539-block drawing: a layer-scoped
extract of 292 blocks with two tags takes ~0.3 s.

> Dynamic block name resolution needs ActiveX, which AutoCAD LT lacks. On LT the
> raw `*U###` name is returned instead.

### `annotation` — Text, dimensions, leaders

`create_text`, `create_dimension_linear`, `create_dimension_aligned`, `create_dimension_angular`, `create_dimension_radius`, `create_leader`

### `pid` — P&ID operations (CTO symbol library)

`setup_layers`, `insert_symbol`, `list_symbols`, `draw_process_line`, `connect_equipment`, `add_flow_arrow`, `add_equipment_tag`, `add_line_number`, `insert_valve`, `insert_instrument`, `insert_pump`, `insert_tank`

> **The P&ID module is not loaded by default.** It is a self-contained domain
> most users never touch, so it is commented out of the module list in
> `mcp_dispatch.lsp` — uncomment `"mcp_pid.lsp"` there to enable it. Without it,
> `pid` operations return an unknown-command error naming the cause.

> P&ID symbol insertion requires the [CAD Tools Online](https://www.cadtoolsonline.com/) (CTO) P&ID Symbol Library installed at `C:\PIDv4-CTO\`. The ezdxf backend has built-in CTO library support. For the File IPC backend, some P&ID operations require additional LISP helpers — see the P&ID section in the wiki for setup details.

### `view` — Viewport and screenshot

| Operation | Description |
|-----------|-------------|
| `zoom_extents` | Zoom to show all entities |
| `zoom_window` | Zoom to a specified window |
| `get_screenshot` | Capture current AutoCAD view as PNG |

Screenshots use `PrintWindow` (Win32) for the File IPC backend — works even when AutoCAD is minimized or in the background. The ezdxf backend renders via matplotlib.

### `system` — Server management

`status`, `health`, `get_backend`, `runtime`, `init`

Read-only. Annotated as such, so clients may auto-approve it.

### `execute_lisp` — Arbitrary AutoLISP

Runs any AutoLISP expression in the current drawing (File IPC only). Pass
`code: "(+ 1 2)"`. This is what makes the server extensible rather than a fixed
command set.

> It is a separate tool, not a `system` operation, because it can erase entities,
> write files, and change system variables. Keeping it out of the read-only tool
> means a client that auto-approves `system` does not thereby auto-approve
> arbitrary code execution.

## LISP module layout

The dispatcher is split by domain. `mcp_dispatch.lsp` is a loader that pulls in
the modules; loading it is still the single entry point, so existing APPLOAD and
`acaddoc.lsp` setups are unaffected.

| File | Contents |
|---|---|
| `mcp_core.lsp` | JSON helpers, the command registry, `c:mcp-dispatch` |
| `mcp_system.lsp` | `ping`, `execute-lisp` |
| `mcp_drawing.lsp` | drawing file management, undo/redo |
| `mcp_entity.lsp` | entity creation, query, modification |
| `mcp_layer.lsp` | layer management |
| `mcp_block.lsp` | block insertion, attributes, bulk extraction |
| `mcp_annotation.lsp` | text, dimensions, leaders |
| `mcp_view.lsp` | viewport control |
| `mcp_pid.lsp` | P&ID symbols — **not loaded by default** |

Commands register themselves at the bottom of their own module:

```lisp
(mcp-register "block-extract" 'mcp-cmd-block-extract)
```

There is no central dispatch table, so adding a command touches one file. The
registry is still a whitelist — only registered names dispatch, and caller input
is never evaluated. Every handler takes exactly one argument (the raw command
JSON) so the registry can invoke them uniformly; `tests/test_lisp_registry.py`
enforces that, checks that every command Python dispatches is registered, and
balances parens in each module.

Because modules are located with `findfile`, the `lisp-code` folder must be on
the Support File Search Path. `system(operation="commands")` reports what is
actually registered in the running drawing, and `system(operation="reload_lisp")`
re-loads the modules after an edit without restarting AutoCAD.

## Architecture

```
MCP Client (Claude)
    │  stdio (JSON-RPC)
    ▼
Python MCP Server (autocad_mcp)
    │
    ├── File IPC Backend ──► C:/temp/*.json ──► mcp_dispatch.lsp (AutoCAD LT)
    │   PostMessageW(WM_CHAR) to MDIClient — no focus steal
    │
    └── ezdxf Backend ──► in-memory DXF (headless, no AutoCAD needed)
```

The File IPC backend sends keystrokes to AutoCAD's MDIClient window via `PostMessageW(WM_CHAR)`, triggering the `(c:mcp-dispatch)` AutoLISP command. This approach does **not** steal window focus — you can continue working in other applications while automation runs.

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `AUTOCAD_MCP_BACKEND` | `auto` | Backend selection: `auto`, `file_ipc`, `ezdxf` |
| `AUTOCAD_MCP_IPC_DIR` | `C:/temp` | Directory for IPC command/result JSON files (must match on both Python and LISP sides) |
| `AUTOCAD_MCP_IPC_TIMEOUT` | `10.0` | IPC command timeout in seconds (1-300) |
| `AUTOCAD_MCP_ONLY_TEXT` | `false` | Disable screenshot capture (text feedback only) |
| `AUTOCAD_MCP_IPC_ENCODING` | `cp1252` | Codepage AutoLISP reads files in; must match AutoCAD's ANSI codepage or non-ASCII text is corrupted |
| `AUTOCAD_MCP_AUTOLOAD` | `1` | Write `acaddoc.lsp` into AutoCAD's support folder at startup and add `lisp-code` to `TRUSTEDPATHS`. Set to `0` to leave AutoCAD's configuration alone |

> **Note:** If you change `AUTOCAD_MCP_IPC_DIR`, you must also update the `*mcp-ipc-dir*` variable in `mcp_dispatch.lsp` to match.

## Development

```powershell
uv sync
uv run pytest tests/ -v
```

## AutoCAD LT AutoLISP Compatibility

AutoLISP was added to AutoCAD LT in the **2024 release (Windows only)**. AutoCAD LT for Mac does not support AutoLISP.

| Supported (LT 2024+ Windows) | Not Supported |
|-------------------------------|---------------|
| `.lsp` / `.fas` / `.vlx` / `.dcl` | VLIDE (Visual LISP IDE) |
| All `vl-*` utility functions | `vlax-*` (ActiveX/COM) |
| File I/O (`open`, `read-line`, etc.) | Express Tools |
| Entity access (`entget`, `entmod`, etc.) | 3D operations |
| Selection sets | AutoLISP on Mac |

The `mcp_dispatch.lsp` dispatcher is fully compatible with LT 2024+.

## What's New in v3.3

- **Self-installing auto-loader** — the server writes `acaddoc.lsp` into AutoCAD's per-user roamable support folder at startup, so the dispatcher loads into every drawing with no manual setup. That folder is on the support file search path by default, so nothing needs configuring; it is a plain file write, so it works on LT too. The block also adds `lisp-code` to `TRUSTEDPATHS`, without which SECURELOAD's modal dialog would block the IPC channel. Disable with `AUTOCAD_MCP_AUTOLOAD=0`; inspect or reverse with `scripts/install_autoload.py`.
- **Modular LISP dispatcher** — commands live in per-domain modules and register themselves, replacing a single 1754-line file with a 260-line `cond`. See [LISP module layout](#lisp-module-layout).
- **Layer operations rewritten** — `create`, `set_properties`, `freeze`, `thaw`, `lock` and `unlock` edit the layer table record directly instead of driving `-LAYER`, whose prompt sequence desynced and left `layer_create` reporting an empty error while applying the wrong colour.
- **`system.commands` and `system.reload_lisp`** — inspect the command registry, and reload modules after an edit without restarting AutoCAD.

## What's New in v3.2

Fixes for working on large, real-world drawings. Verified against an
xref-assembled drawing with 11,271 entities and 4,169 layers.

- **Non-ASCII text is no longer corrupted on the way in** — commands were serialized with `json.dumps` defaults, so `ü` reached the LISP side as the six literal characters `ü`, which its JSON parser has no way to decode. A layer filter for `Weichenblöcke` matched nothing; created text carried visible escapes. Commands are now written in the ANSI codepage AutoLISP actually reads (`AUTOCAD_MCP_IPC_ENCODING`, default `cp1252`), as are `execute_lisp` temp files. Characters outside that codepage produce a clear error instead of silent corruption. Reading was already correct.
- **`annotation.create_text` works** — it drove the `_TEXT` command positionally, which desyncs whenever the current text style has a fixed height (the height prompt is skipped) and leaves the command open waiting for further lines. It failed with an empty error message for every input. Now uses `entmake`.
- **`block.extract`** — bulk-reads blocks with their attributes in one round trip, filtered by layer, block name, bbox and tag. The per-entity path costs a dispatch each, so building an attribute list from a few hundred blocks was a minutes-long loop; it is now a single ~0.3 s call. Block names are resolved through dynamic-block instances, without which a name filter silently misses every block whose parameters differ from its definition — on the test drawing that was most of them.
- **`block_insert_with_attributes` no longer drops attributes** (ezdxf backend) — `add_auto_attribs` fills ATTDEF templates declared in the block definition and neither raises nor adds anything for a block without them, so the fallback in the `except` branch never ran and the caller's data vanished silently.
- **Bounded `drawing.info` and `layer.list`** — `drawing.info` emitted every layer name: 330 KB on a 4,169-layer drawing, larger than most clients accept. It now reports `layer_count` with a 25-name sample. `layer.list` takes `filter` (case-insensitive substring), `limit` and `offset`, which is the only practical way to find a layer among thousands.

- **Bounded `entity.list`** — `limit` (default 200), `offset`, `type` and `bbox` filters, with `total` and `truncated` always reported. Previously the command walked the whole database and concatenated one JSON object per entity, which on a 10k-entity drawing exceeded both the IPC timeout and the client's token budget, with no signal that anything had been dropped.
- **`entity.get` covers real entity types** — ARC, ELLIPSE, POINT, TEXT/ATTDEF/ATTRIB, MTEXT, INSERT and LWPOLYLINE/POLYLINE in addition to LINE and CIRCLE. Block names, insertion points, text content and polyline vertices are now readable; before, everything but LINE and CIRCLE returned only type/handle/layer. Angles are converted to degrees so they round-trip through the create/rotate operations.
- **`execute_lisp` split out of `system`** — `system` was annotated `readOnlyHint: true` while containing arbitrary code execution, so a client honouring the annotation could auto-approve a call that erases the drawing. `execute_lisp` is now its own tool with `destructiveHint: true`; `system` is genuinely read-only.
- **`acaddoc.lsp` auto-load** — loads the dispatcher into every document namespace. Fixes the server going silent after `drawing.open` or any manual drawing switch, since an APPLOAD-loaded dispatcher exists only in the document that was open at the time.
- **Actionable timeout errors** — the timeout message now names the likely cause and the exact reload command instead of only the request id.

## What's New in v3.1

- **`execute_lisp`** — Run arbitrary AutoLISP code via temp file pattern. Turns the server from a fixed command set into an extensible automation platform.
- **Undo / Redo** — Single-step undo and redo via `drawing` tool.
- **Drawing open** — Open existing `.dwg` files programmatically (FILEDIA suppressed).
- **Drawing create** — Now resets current drawing (erase all + purge) instead of `_.NEW`, preserving the LISP dispatcher namespace.
- **Drawing save with path** — `save` with a `path` parameter uses SAVEAS; without path uses QSAVE.
- **`get_variables` fix** — Respects the `names` parameter; returns requested variables with proper type handling.
- **Polyline/leader fix** — Point arrays properly encoded via semicolon-delimited format.
- **ESC prefix** — Sends 2x ESC before each dispatch to cancel stale pending commands from prior timeouts.
- **UTF-8/cp1252 fallback** — Handles non-ASCII characters in LISP result files (AutoCAD writes Windows-1252).
- **Configurable IPC timeout** — `AUTOCAD_MCP_IPC_TIMEOUT` env var (1–300 seconds, default 10).
- **Thread-safe backend init** — `asyncio.Lock` prevents parallel initialization races.

## License

MIT
