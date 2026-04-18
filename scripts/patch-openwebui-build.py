#!/usr/bin/env python3

from pathlib import Path
import sys


def normalize_subpath(raw: str | None) -> str:
    if raw is None:
        return ""

    text = raw.strip()
    if not text or text == "/":
        return ""

    return "/" + text.strip("/")


def with_subpath(path: str, subpath: str) -> str:
    return f"{subpath}{path}" if subpath else path


def patch_text(text: str, subpath: str) -> str:
    replacements = [
        (
            "logo.src = isDarkMode ? '/static/splash-dark.svg' : '/static/splash.svg';",
            f"logo.src = isDarkMode ? '{with_subpath('/static/splash-dark.svg', subpath)}' : '{with_subpath('/static/splash.svg', subpath)}';",
        ),
        (
            "logo.src = isDarkMode ? '/static/splash-dark.png' : '/static/splash.png';",
            f"logo.src = isDarkMode ? '{with_subpath('/static/splash-dark.svg', subpath)}' : '{with_subpath('/static/splash.svg', subpath)}';",
        ),
        ('src="/static/splash.png"', f'src="{with_subpath("/static/splash.svg", subpath)}"'),
        ('src="/static/splash.svg"', f'src="{with_subpath("/static/splash.svg", subpath)}"'),
    ]

    if subpath:
        replacements.extend(
            [
                ('href="/static/', f'href="{subpath}/static/'),
                ('src="/static/', f'src="{subpath}/static/'),
                ('href="/manifest.json"', f'href="{subpath}/manifest.json"'),
                ('href="/_app/', f'href="{subpath}/_app/'),
                ('import("/_app/', f'import("{subpath}/_app/'),
                ('base: ""', f'base: "{subpath}"'),
            ]
        )

    for old, new in replacements:
        text = text.replace(old, new)

    return text


def main() -> int:
    if len(sys.argv) not in {2, 3}:
        raise SystemExit("usage: patch-openwebui-build.py <index.html> [subpath]")

    index_path = Path(sys.argv[1])
    subpath = normalize_subpath(sys.argv[2] if len(sys.argv) == 3 else None)

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
