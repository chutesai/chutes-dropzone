#!/usr/bin/env python3

from pathlib import Path
import sys


def replace_once(text: str, old: str, new: str, label: str) -> str:
    if old not in text:
        raise SystemExit(f"missing expected {label} block")
    return text.replace(old, new, 1)


def patch_env(path: Path) -> None:
    original = path.read_text(encoding="utf-8")
    patched = replace_once(
        original,
        'WEBUI_NAME = os.environ.get("WEBUI_NAME", "Open WebUI")\nif WEBUI_NAME != "Open WebUI":\n    WEBUI_NAME += " (Open WebUI)"\n\nWEBUI_FAVICON_URL = "https://openwebui.com/favicon.png"\n',
        'WEBUI_NAME = os.environ.get("WEBUI_NAME", "Open WebUI")\n\nWEBUI_FAVICON_URL = os.environ.get("WEBUI_FAVICON_URL", "/static/chutes-logo.svg")\n',
        "WEBUI_NAME suffix block",
    )
    path.write_text(patched, encoding="utf-8")


def patch_main(path: Path) -> None:
    original = path.read_text(encoding="utf-8")
    patched = replace_once(
        original,
        "from open_webui.utils.redis import get_sentinels_from_env\n",
        "from open_webui.utils.redis import get_sentinels_from_env\nfrom open_webui.dropzone_account import get_chutes_account_summary\n",
        "dropzone account import",
    )
    patched = replace_once(
        patched,
        '@app.get("/manifest.json")\nasync def get_manifest_json():\n    if app.state.EXTERNAL_PWA_MANIFEST_URL:\n        return requests.get(app.state.EXTERNAL_PWA_MANIFEST_URL).json()\n    else:\n        return {\n            "name": app.state.WEBUI_NAME,\n            "short_name": app.state.WEBUI_NAME,\n            "description": f"{app.state.WEBUI_NAME} is an open, extensible, user-friendly interface for AI that adapts to your workflow.",\n            "start_url": "/",\n            "display": "standalone",\n            "background_color": "#343541",\n            "icons": [\n                {\n                    "src": "/static/logo.png",\n                    "type": "image/png",\n                    "sizes": "500x500",\n                    "purpose": "any",\n                },\n                {\n                    "src": "/static/logo.png",\n                    "type": "image/png",\n                    "sizes": "500x500",\n                    "purpose": "maskable",\n                },\n            ],\n            "share_target": {\n                "action": "/",\n                "method": "GET",\n                "params": {"text": "shared"},\n            },\n        }\n',
        '@app.get("/api/v1/dropzone/account-summary")\nasync def get_dropzone_account_summary(\n    user=Depends(get_verified_user), db: Session = Depends(get_session)\n):\n    return get_chutes_account_summary(user, db)\n\n\n@app.get("/manifest.json")\nasync def get_manifest_json():\n    if app.state.EXTERNAL_PWA_MANIFEST_URL:\n        return requests.get(app.state.EXTERNAL_PWA_MANIFEST_URL).json()\n    else:\n        return {\n            "name": app.state.WEBUI_NAME,\n            "short_name": app.state.WEBUI_NAME,\n            "description": "Chutes Chat is a private AI workspace powered by Chutes.",\n            "start_url": "/chat/",\n            "scope": "/chat/",\n            "display": "standalone",\n            "theme_color": "#171717",\n            "background_color": "#171717",\n            "icons": [\n                {\n                    "src": "/chat/static/chutes-chat-icon-192.png",\n                    "type": "image/png",\n                    "sizes": "192x192",\n                    "purpose": "any maskable",\n                },\n                {\n                    "src": "/chat/static/chutes-chat-icon-512.png",\n                    "type": "image/png",\n                    "sizes": "512x512",\n                    "purpose": "any maskable",\n                },\n            ],\n            "share_target": {\n                "action": "/chat/",\n                "method": "GET",\n                "params": {"text": "shared"},\n            },\n        }\n',
        "manifest route block",
    )
    path.write_text(patched, encoding="utf-8")


def main() -> int:
    if len(sys.argv) != 2:
        raise SystemExit("usage: patch-openwebui-runtime.py <openwebui-root>")

    root = Path(sys.argv[1])
    patch_env(root / "backend" / "open_webui" / "env.py")
    patch_main(root / "backend" / "open_webui" / "main.py")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
