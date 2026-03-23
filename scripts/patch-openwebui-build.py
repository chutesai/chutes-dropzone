#!/usr/bin/env python3

from pathlib import Path
import sys


def patch_text(text: str, subpath: str) -> str:
    replacements = (
        ('href="/static/', f'href="{subpath}/static/'),
        ('src="/static/', f'src="{subpath}/static/'),
        ('href="/manifest.json"', f'href="{subpath}/manifest.json"'),
        ('href="/_app/', f'href="{subpath}/_app/'),
        ('import("/_app/', f'import("{subpath}/_app/'),
        ('base: ""', f'base: "{subpath}"'),
        (
            "logo.src = isDarkMode ? '/static/splash-dark.png' : '/static/splash.png';",
            f"logo.src = isDarkMode ? '{subpath}/static/splash-dark.png' : '{subpath}/static/splash.png';",
        ),
        ('src="/static/splash.png"', f'src="{subpath}/static/splash.png"'),
    )

    for old, new in replacements:
        text = text.replace(old, new)

    return text


def main() -> int:
    if len(sys.argv) != 3:
        raise SystemExit("usage: patch-openwebui-build.py <index.html> <subpath>")

    index_path = Path(sys.argv[1])
    subpath = sys.argv[2].rstrip("/") or "/chat"

    html = index_path.read_text(encoding="utf-8")
    html = patch_text(html, subpath)
    index_path.write_text(html, encoding="utf-8")

    immutable_dir = index_path.parent / "_app" / "immutable"
    if immutable_dir.is_dir():
        for asset_path in immutable_dir.rglob("*.js"):
            text = asset_path.read_text(encoding="utf-8")
            patched = patch_text(text, subpath)
            if patched != text:
                asset_path.write_text(patched, encoding="utf-8")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
