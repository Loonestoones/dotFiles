#!/usr/bin/env python3
"""Fix compile_commands.json for STM32CubeIDE projects used with clangd.

Bear/compiledb often sets "directory" to the project root while CubeIDE make
runs from Debug/, so relative -I../ include paths resolve incorrectly for
clangd (e.g. main.h not found in Neovim).

Safe to run after every Bear/compiledb generation. STM32CubeIDE does not use
this file for building.

On Windows Neovim, do not symlink compile_commands.json from WSL; use the
.clangd file in this project (CompilationDatabase: Debug) instead.

Usage:
    python fix_compile_commands.py
    python fix_compile_commands.py path/to/Debug/compile_commands.json
"""

from __future__ import annotations

import json
import sys
from pathlib import Path


def _normalize_path_key(path: str | Path) -> str:
    """Comparable path key for Windows and POSIX (incl. WSL /mnt/c/...)."""
    text = str(path).replace("\\", "/").rstrip("/")
    if sys.platform != "win32" and len(text) >= 2 and text[1] == ":":
        drive = text[0].lower()
        rest = text[2:].lstrip("/")
        return f"/mnt/{drive}/{rest}".casefold()
    return text.casefold()


def _paths_equal(a: str | Path, b: Path) -> bool:
    return _normalize_path_key(a) == _normalize_path_key(b)


def _format_directory(debug_dir: Path, template: str) -> str:
    """Keep C:/ style when the JSON already uses Windows drive paths."""
    if len(template) >= 2 and template[1] == ":":
        posix = debug_dir.as_posix()
        if sys.platform != "win32" and posix.startswith("/mnt/") and len(posix) > 7 and posix[6] == "/":
            return f"{posix[5].upper()}:/{posix[7:]}"
        return posix
    return str(debug_dir)


def fix_entry_directory(entry: dict, debug_dir: Path, project_root: Path) -> bool:
    directory = entry.get("directory")
    if not directory:
        return False

    if _paths_equal(directory, debug_dir):
        return False

    if not _paths_equal(directory, project_root):
        return False

    command = entry.get("command", "")
    if "-I../" not in command:
        return False

    entry["directory"] = _format_directory(debug_dir, directory)
    return True


def fix_compile_commands(path: Path) -> int:
    if not path.is_file():
        print(f"error: file not found: {path}", file=sys.stderr)
        return 1

    if path.parent.name != "Debug":
        print(
            "warning: expected compile_commands.json inside a Debug/ folder",
            file=sys.stderr,
        )

    debug_dir = path.parent.resolve()
    project_root = debug_dir.parent.resolve()

    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        print(f"error: invalid JSON in {path}: {exc}", file=sys.stderr)
        return 1

    if not isinstance(data, list):
        print(f"error: expected a JSON array in {path}", file=sys.stderr)
        return 1

    fixed = sum(
        1
        for entry in data
        if isinstance(entry, dict) and fix_entry_directory(entry, debug_dir, project_root)
    )

    if fixed:
        path.write_text(
            json.dumps(data, indent=2, ensure_ascii=False) + "\n",
            encoding="utf-8",
        )
        print(f"Fixed {fixed} entr{'y' if fixed == 1 else 'ies'} in {path}")
    else:
        print(f"No changes needed in {path}")

    return 0


def main() -> int:
    if len(sys.argv) > 2:
        print(
            f"usage: {sys.argv[0]} [path/to/Debug/compile_commands.json]",
            file=sys.stderr,
        )
        return 1

    if len(sys.argv) == 2:
        target = Path(sys.argv[1])
    else:
        target = Path(__file__).resolve().parent / "Debug" / "compile_commands.json"

    return fix_compile_commands(target.resolve())


if __name__ == "__main__":
    raise SystemExit(main())
