"""Backend detection and environment configuration."""

from __future__ import annotations

import os
import sys
import tempfile
from pathlib import Path

import structlog

log = structlog.get_logger()

# Paths
LISP_DIR = Path(__file__).resolve().parent.parent.parent / "lisp-code"


def _default_ipc_dir() -> Path:
    """A per-user directory for the command/result files.

    This used to be C:/temp. That is world-writable on a shared machine, so
    another user could plant or read command files — and since the directory has
    to be a trusted path for execute_lisp to load from it without lowering
    SECURELOAD, trusting C:/temp would mean trusting anything anyone drops there.
    LOCALAPPDATA is per-user and deliberately not roaming: these files are
    transient IPC, worthless on another machine.
    """
    # Deliberately one level deep: the LISP side creates this directory if it is
    # missing, and vl-mkdir makes a single level at a time.
    base = os.environ.get("LOCALAPPDATA")
    if base:
        return Path(base) / "autocad-mcp-ipc"
    return Path(tempfile.gettempdir()) / "autocad-mcp-ipc"


IPC_DIR = Path(os.environ.get("AUTOCAD_MCP_IPC_DIR") or _default_ipc_dir())

# Backend selection
BACKEND_DEFAULT = "auto"  # auto | file_ipc | ezdxf

# IPC timeout (seconds), clamped to [1, 300]
IPC_TIMEOUT = max(1.0, min(300.0, float(os.environ.get("AUTOCAD_MCP_IPC_TIMEOUT", "10.0"))))

# AutoCAD's AutoLISP file I/O reads and writes bytes in the system ANSI
# codepage, not UTF-8. Both sides of the IPC channel must agree on it or
# non-ASCII text (German umlauts, French accents) is corrupted in transit.
# Override for locales whose ANSI codepage is not Windows-1252.
IPC_ENCODING = os.environ.get("AUTOCAD_MCP_IPC_ENCODING", "cp1252")

# Write acaddoc.lsp into AutoCAD's roamable support folder at startup so the
# dispatcher loads into every drawing. This also adds lisp-code to TRUSTEDPATHS,
# without which SECURELOAD raises a modal dialog that blocks the IPC channel.
# Set to 0 to leave AutoCAD's configuration untouched.
AUTO_INSTALL_AUTOLOAD = os.environ.get("AUTOCAD_MCP_AUTOLOAD", "1").lower() not in (
    "0",
    "false",
    "no",
)

# Screenshot
ONLY_TEXT_FEEDBACK = os.environ.get("AUTOCAD_MCP_ONLY_TEXT", "").lower() in ("1", "true", "yes")

# Win32 availability
WIN32_AVAILABLE = sys.platform == "win32"


def _current_backend_env() -> str:
    """Read backend selection from env with normalization."""
    return os.environ.get("AUTOCAD_MCP_BACKEND", BACKEND_DEFAULT).strip().lower()


def _is_wsl() -> bool:
    """Detect WSL Linux runtime."""
    if os.environ.get("WSL_INTEROP"):
        return True
    try:
        return "microsoft" in os.uname().release.lower()
    except AttributeError:
        return False


def _write_debug_snapshot(backend_env: str):
    """Optionally write backend detection debug information.

    Set AUTOCAD_MCP_DEBUG_DETECT_FILE to enable.
    """
    debug_file = os.environ.get("AUTOCAD_MCP_DEBUG_DETECT_FILE", "").strip()
    if not debug_file:
        return

    try:
        debug_path = Path(debug_file)
        debug_path.parent.mkdir(parents=True, exist_ok=True)
        with debug_path.open("w", encoding="utf-8") as f:
            f.write(f"sys.platform={sys.platform}\n")
            f.write(f"WIN32_AVAILABLE={WIN32_AVAILABLE}\n")
            f.write(f"BACKEND_ENV={backend_env}\n")
            f.write(f"python={sys.executable}\n")
    except Exception:
        # Best-effort only; never fail backend detection due debug writes.
        pass


def detect_backend() -> str:
    """Return the backend name to use: 'file_ipc' or 'ezdxf'.

    Raises RuntimeError with actionable message if explicit backend fails.
    """
    backend_env = _current_backend_env()
    _write_debug_snapshot(backend_env)

    if backend_env == "ezdxf":
        return "ezdxf"

    if backend_env in ("auto", "file_ipc"):
        if WIN32_AVAILABLE:
            try:
                from autocad_mcp.backends.file_ipc import find_autocad_window

                hwnd = find_autocad_window()
                if hwnd:
                    log.info("autocad_window_found", hwnd=hwnd)
                    return "file_ipc"
                elif backend_env == "file_ipc":
                    raise RuntimeError(
                        "AUTOCAD_MCP_BACKEND=file_ipc but no AutoCAD window found. "
                        "Start AutoCAD LT and open a .dwg file."
                    )
            except ImportError:
                if backend_env == "file_ipc":
                    raise RuntimeError(
                        "AUTOCAD_MCP_BACKEND=file_ipc requires pywin32. "
                        "Install with: pip install pywin32"
                    )
                log.info("win32_deps_missing_fallback_ezdxf")
        elif backend_env == "file_ipc":
            raise RuntimeError(
                "AUTOCAD_MCP_BACKEND=file_ipc requires Windows. "
                "Use AUTOCAD_MCP_BACKEND=ezdxf for headless mode."
            )
        elif _is_wsl():
            log.info(
                "wsl_linux_python_fallback_ezdxf",
                platform=sys.platform,
                python=sys.executable,
                hint="Launch MCP with Windows python.exe for File IPC backend.",
            )

    log.info("using_ezdxf_backend")
    return "ezdxf"
