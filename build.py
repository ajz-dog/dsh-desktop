#!/usr/bin/env python3
"""Build the distributable installer from the sources in src/.

The installer has to be a single self-contained file that can rebuild a whole
desktop build from nothing, so it embeds the launcher, the VBS entry point, the
uninstaller and the bundled README as PowerShell here-strings. This script is
what actually puts them there — run it after touching anything in src/.

    python build.py

Outputs:
    dist/dsh-desktop-setup.ps1   generated, UTF-8 with BOM, LF
    dist/dsh-desktop-setup.cmd   copied from src/setup.cmd, CRLF
"""

from __future__ import annotations

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent
SRC = ROOT / "src"
DIST = ROOT / "dist"

# Placeholder in src/setup.ps1 -> file whose contents replace it.
EMBEDS = {
    "@@DSH_LAUNCHER_MJS@@": SRC / "launcher.mjs",
    "@@DSH_WEB_VBS@@": SRC / "dsh-web.vbs",
    "@@DSH_UNINSTALL_PS1@@": SRC / "uninstall.ps1",
    "@@DSH_UNINSTALL_CMD@@": SRC / "uninstall.cmd",
    "@@DSH_DOC_MD@@": SRC / "desktop-README.md",
}


def read_source(path: Path) -> str:
    """Read a source file, stripping a BOM and the single trailing newline.

    Two traps this avoids, both of which have bitten this project:
      * `utf-8` keeps a BOM as a literal U+FEFF character, which then gets a
        *second* BOM written by the BOM-adding encoder at install time. A doubled
        BOM does not merely look wrong — PowerShell stops parsing the script.
      * PowerShell here-strings do not include the trailing newline, so the
        installer re-adds exactly one when it writes the file back.
    """
    text = path.read_text(encoding="utf-8-sig")
    return text[:-1] if text.endswith("\n") else text


def main() -> int:
    setup = (SRC / "setup.ps1").read_text(encoding="utf-8")

    for placeholder, path in EMBEDS.items():
        if not path.is_file():
            print(f"error: missing source {path.relative_to(ROOT)}", file=sys.stderr)
            return 1
        body = read_source(path)

        if setup.count(placeholder) != 1:
            print(
                f"error: {placeholder} appears {setup.count(placeholder)} times in src/setup.ps1",
                file=sys.stderr,
            )
            return 1
        # A here-string ends at a line starting with '@ — embedded content must
        # never contain one, or the generated script is silently truncated.
        conflict = [line for line in body.split("\n") if line.startswith("'@")]
        if conflict:
            print(f"error: {path.name} contains a here-string terminator: {conflict[:2]}", file=sys.stderr)
            return 1
        if body.startswith("\ufeff"):
            print(f"error: {path.name} still carries a BOM character", file=sys.stderr)
            return 1

        setup = setup.replace(placeholder, body)

    # Build-time guard for the bug that shipped once already: the installer kept
    # embedding the pre-config launcher, which ran `pnpm dsh web` inside the
    # install directory and died with pnpm's `Command "dsh" not found`. A stale
    # payload must fail the build, not reach a user.
    launcher = read_source(SRC / "launcher.mjs")
    for needle in ("readConfig", "cwd: REPO_DIR", "dsh-web.config.json"):
        if needle not in launcher:
            print(f"error: src/launcher.mjs lacks {needle!r} — refusing to build", file=sys.stderr)
            return 1

    DIST.mkdir(exist_ok=True)
    out_ps1 = DIST / "dsh-desktop-setup.ps1"
    # utf-8-sig so Windows PowerShell 5.1 reads the Chinese text as UTF-8;
    # newline='' keeps the LF endings the source uses.
    out_ps1.write_text(setup, encoding="utf-8-sig", newline="\n")

    cmd = read_source(SRC / "setup.cmd")
    out_cmd = DIST / "dsh-desktop-setup.cmd"
    out_cmd.write_text(cmd.replace("\n", "\r\n") + "\r\n", encoding="ascii", newline="")
    print(f"built {out_ps1.relative_to(ROOT)} ({out_ps1.stat().st_size} bytes)")
    print(f"built {out_cmd.relative_to(ROOT)} ({out_cmd.stat().st_size} bytes)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
