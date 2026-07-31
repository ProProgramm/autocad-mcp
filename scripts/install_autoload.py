#!/usr/bin/env python
"""Install or remove the acaddoc.lsp auto-loader by hand.

The server does this at startup unless AUTOCAD_MCP_AUTOLOAD=0. This script is
for inspecting what would be written, and for backing it out.

    python scripts/install_autoload.py --dry-run
    python scripts/install_autoload.py
    python scripts/install_autoload.py --uninstall
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "src"))

from autocad_mcp import autoload  # noqa: E402
from autocad_mcp.config import IPC_ENCODING, LISP_DIR  # noqa: E402


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--uninstall", action="store_true", help="remove the managed block")
    ap.add_argument("--dry-run", action="store_true", help="show what would change")
    args = ap.parse_args()

    dirs = autoload.find_support_dirs()
    if not dirs:
        print("No AutoCAD roamable support folder found under %APPDATA%/Autodesk.")
        print("Nothing to do — the auto-loader has nowhere to go.")
        return 1

    print("Support folders found:")
    for d in dirs:
        print(f"  {d}")

    if args.dry_run:
        print(f"\nWould write this block into acaddoc.lsp in each folder:\n")
        print(autoload.render_block(LISP_DIR))
        print("Note: this adds the lisp-code folder to TRUSTEDPATHS, so any")
        print("LISP/ARX in it will load without a SECURELOAD warning.")
        return 0

    results = autoload.uninstall(IPC_ENCODING) if args.uninstall else autoload.install(LISP_DIR, IPC_ENCODING)
    print()
    for path, action in results:
        print(f"  {action:14} {path}")

    if not args.uninstall:
        print("\nRestart AutoCAD (or open a new drawing) for it to take effect.")
        print("The TRUSTEDPATHS entry is added the first time acaddoc.lsp runs.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
