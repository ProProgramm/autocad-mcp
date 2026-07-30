"""Cross-check the Python dispatch calls against the LISP command registry.

The two sides are separate languages in separate files, so a renamed or
forgotten command is invisible until a call fails at runtime against a live
AutoCAD — which is exactly where it is most expensive to find. The registry
makes both sides greppable, so this is checkable statically.
"""

import re
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parent.parent
LISP_DIR = REPO / "lisp-code"
FILE_IPC = REPO / "src" / "autocad_mcp" / "backends" / "file_ipc.py"

# Commands registered but never dispatched from Python are fine — they can be
# called through execute_lisp or by hand. The reverse is a bug.
DISPATCH_CALL = re.compile(r'_dispatch\(\s*"([a-z0-9\-]+)"')
REGISTRATION = re.compile(r'\(mcp-register\s+"([a-z0-9\-]+)"\s+\'([a-zA-Z0-9\-]+)\)')
DEFUN = re.compile(r"^\(defun\s+(\S+)", re.M)


def lisp_sources():
    return sorted(LISP_DIR.glob("mcp_*.lsp"))


def registrations():
    """name -> (handler, module) for every registered command."""
    out = {}
    for path in lisp_sources():
        for name, handler in REGISTRATION.findall(path.read_text(encoding="utf-8")):
            out[name] = (handler, path.name)
    return out


def defined_functions():
    out = {}
    for path in lisp_sources():
        for name in DEFUN.findall(path.read_text(encoding="utf-8")):
            out[name] = path.name
    return out


def test_every_dispatched_command_is_registered():
    dispatched = set(DISPATCH_CALL.findall(FILE_IPC.read_text(encoding="utf-8")))
    assert dispatched, "no _dispatch calls found — did the backend move?"
    missing = sorted(dispatched - set(registrations()))
    assert not missing, f"dispatched from Python but not registered in LISP: {missing}"


def test_every_registration_points_at_a_defined_function():
    defined = defined_functions()
    dangling = sorted(
        (name, handler, module)
        for name, (handler, module) in registrations().items()
        if handler not in defined
    )
    assert not dangling, f"registered handlers with no defun: {dangling}"


def test_every_handler_takes_exactly_one_argument():
    """The registry applies handlers uniformly with a single params argument,
    so a zero-arg or two-arg handler would fail only when that command runs."""
    bad = []
    for path in lisp_sources():
        for m in re.finditer(r"^\(defun\s+(mcp-cmd-\S+)\s+\(([^)]*)\)", path.read_text(encoding="utf-8"), re.M):
            name, arglist = m.group(1), m.group(2)
            positional = arglist.split("/")[0].split()
            if len(positional) != 1:
                bad.append((name, path.name, positional))
    assert not bad, f"handlers whose arity is not 1: {bad}"


def test_no_command_is_registered_twice():
    seen = {}
    dupes = []
    for path in lisp_sources():
        for name, _ in REGISTRATION.findall(path.read_text(encoding="utf-8")):
            if name in seen:
                dupes.append((name, seen[name], path.name))
            seen[name] = path.name
    assert not dupes, f"commands registered in more than one module: {dupes}"


def test_core_defines_the_registry_before_modules_use_it():
    """Every module calls mcp-register at load time, so core must be first in
    the loader's module list or the whole load fails."""
    loader = (LISP_DIR / "mcp_dispatch.lsp").read_text(encoding="utf-8")
    listed = re.findall(r'"(mcp_[a-z]+\.lsp)"', loader)
    assert listed[0] == "mcp_core.lsp", f"core must load first, got {listed[:3]}"


@pytest.mark.parametrize("path", lisp_sources(), ids=lambda p: p.name)
def test_parens_balance(path):
    """A module with unbalanced parens fails to load, silently removing its
    commands. Cheap to check, and there is no LISP test runner."""
    src = path.read_text(encoding="utf-8")
    depth = 0
    instr = incom = esc = False
    for ch in src:
        if ch == "\n":
            incom = False
            continue
        if incom:
            continue
        if instr:
            if esc:
                esc = False
            elif ch == "\\":
                esc = True
            elif ch == '"':
                instr = False
            continue
        if ch == ";":
            incom = True
        elif ch == '"':
            instr = True
        elif ch == "(":
            depth += 1
        elif ch == ")":
            depth -= 1
            assert depth >= 0, f"{path.name}: unbalanced closing paren"
    assert depth == 0, f"{path.name}: {depth} unclosed paren(s)"
    assert not instr, f"{path.name}: unterminated string"
