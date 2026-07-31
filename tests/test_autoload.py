"""Tests for the acaddoc.lsp auto-loader.

This runs unattended on every server start and writes into AutoCAD's own
configuration directory, so the merge behaviour is the part that matters:
clobbering a user's existing acaddoc.lsp would break their startup routine with
no obvious cause.
"""

from pathlib import Path

from autocad_mcp import autoload

LISP_DIR = Path("C:/GitHubRepos/MCPTest/lisp-code")


def test_fresh_install_produces_just_the_block():
    result = autoload.apply_block(None, autoload.render_block(LISP_DIR))
    assert result.startswith(autoload.BEGIN)
    assert result.rstrip().endswith(autoload.END)


def test_existing_user_content_is_preserved():
    existing = '(princ "\\nmy own startup code")\n(setq MYVAR 42)\n'
    result = autoload.apply_block(existing, autoload.render_block(LISP_DIR))
    assert "my own startup code" in result
    assert "(setq MYVAR 42)" in result
    assert autoload.BEGIN in result


def test_reinstall_is_idempotent():
    block = autoload.render_block(LISP_DIR)
    once = autoload.apply_block(None, block)
    twice = autoload.apply_block(once, block)
    assert once == twice
    assert twice.count(autoload.BEGIN) == 1


def test_reinstall_after_path_change_replaces_the_old_block():
    old = autoload.apply_block(None, autoload.render_block(Path("C:/old/lisp-code")))
    new = autoload.apply_block(old, autoload.render_block(Path("C:/new/lisp-code")))
    assert new.count(autoload.BEGIN) == 1
    assert "C:/new/lisp-code" in new
    assert "C:/old/lisp-code" not in new


def test_reinstall_alongside_user_content_does_not_duplicate():
    existing = "(setq MYVAR 42)\n"
    block = autoload.render_block(LISP_DIR)
    once = autoload.apply_block(existing, block)
    twice = autoload.apply_block(once, block)
    assert twice.count(autoload.BEGIN) == 1
    assert "(setq MYVAR 42)" in twice


def test_strip_leaves_user_content():
    existing = "(setq MYVAR 42)\n"
    installed = autoload.apply_block(existing, autoload.render_block(LISP_DIR))
    stripped = autoload.strip_block(installed)
    assert "(setq MYVAR 42)" in stripped
    assert autoload.BEGIN not in stripped


def test_block_guards_the_load_against_a_moved_repo():
    """A stale path must not error on every drawing that opens."""
    block = autoload.render_block(LISP_DIR)
    assert "findfile" in block
    assert "(not c:mcp-dispatch)" in block


def test_block_declares_the_trusted_path():
    block = autoload.render_block(LISP_DIR)
    assert "TRUSTEDPATHS" in block
    # Backslash-escaped Windows path, since that is what AutoCAD stores.
    assert "lisp-code" in block


def test_generated_block_is_ascii_only():
    """The file is written in the system ANSI codepage, which varies by locale.
    A non-ASCII character could fail to encode, or round-trip differently --
    and a marker that does not round-trip breaks idempotent reinstall."""
    autoload.render_block(LISP_DIR).encode("ascii")
    (autoload.BEGIN + autoload.END).encode("ascii")


def test_install_writes_and_uninstall_removes(tmp_path, monkeypatch):
    support = tmp_path / "AutoCAD 2024" / "R24.3" / "deu" / "Support"
    support.mkdir(parents=True)
    monkeypatch.setattr(autoload, "find_support_dirs", lambda: [support])

    results = autoload.install(LISP_DIR)
    assert results == [(support / "acaddoc.lsp", "created")]
    assert autoload.BEGIN in (support / "acaddoc.lsp").read_text(encoding="cp1252")

    assert autoload.install(LISP_DIR) == [(support / "acaddoc.lsp", "unchanged")]

    results = autoload.uninstall()
    assert results == [(support / "acaddoc.lsp", "file removed")]
    assert not (support / "acaddoc.lsp").exists()


def test_uninstall_keeps_a_file_that_has_user_content(tmp_path, monkeypatch):
    support = tmp_path / "Support"
    support.mkdir(parents=True)
    target = support / "acaddoc.lsp"
    target.write_text("(setq MYVAR 42)\n", encoding="cp1252")
    monkeypatch.setattr(autoload, "find_support_dirs", lambda: [support])

    autoload.install(LISP_DIR)
    autoload.uninstall()

    assert target.exists()
    assert "(setq MYVAR 42)" in target.read_text(encoding="cp1252")
    assert autoload.BEGIN not in target.read_text(encoding="cp1252")


def test_unwritable_target_does_not_raise(tmp_path, monkeypatch):
    """One locked folder from an old AutoCAD install must not stop startup."""
    missing = tmp_path / "does-not-exist" / "Support"
    monkeypatch.setattr(autoload, "find_support_dirs", lambda: [missing])
    results = autoload.install(LISP_DIR)
    assert len(results) == 1
    assert results[0][1].startswith("failed")
