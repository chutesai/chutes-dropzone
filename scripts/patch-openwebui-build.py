#!/usr/bin/env python3

from pathlib import Path
import re
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


def auth_gate_script(subpath: str) -> str:
    auth_path = with_subpath("/auth", subpath)
    chat_auth_path = with_subpath("/chat/auth", subpath)
    account_summary_path = with_subpath("/api/v1/dropzone/account-summary", subpath)
    oauth_prefix = with_subpath("/oauth/oidc/", subpath)

    return f"""
		<script>
			(() => {{
				if (window.__DROPZONE_AUTH_GATE__) return;

				const AUTH_PATH = "{auth_path}";
				const CHAT_AUTH_PATH = "{chat_auth_path}";
				const ACCOUNT_SUMMARY_URL = "{account_summary_path}";
				const OAUTH_PREFIX = "{oauth_prefix}";
				const path = window.location.pathname || "/";

				function isAuthRoute(currentPath) {{
					return (
						currentPath === AUTH_PATH ||
						currentPath === `${{AUTH_PATH}}/` ||
						currentPath === CHAT_AUTH_PATH ||
						currentPath === `${{CHAT_AUTH_PATH}}/` ||
						currentPath.indexOf(OAUTH_PREFIX) === 0
					);
				}}

				function stripWrappedCookieValue(value) {{
					let text = String(value || "").trim();
					if (!text) return "";

					while (text.length >= 2 && text.charAt(0) === '"' && text.charAt(text.length - 1) === '"') {{
						text = text.slice(1, -1).trim();
					}}

					return text
						.replace(/\\\\\\//g, "/")
						.replace(/\\\\"/g, '"')
						.replace(/\\\\\\\\/g, "\\\\");
				}}

				function readCookie(name) {{
					const prefix = `${{name}}=`;
					const cookies = document.cookie ? document.cookie.split(";") : [];

					for (let index = 0; index < cookies.length; index += 1) {{
						const cookie = cookies[index].trim();
						if (cookie.indexOf(prefix) === 0) {{
							return stripWrappedCookieValue(decodeURIComponent(cookie.slice(prefix.length)));
						}}
					}}

					return "";
				}}

				function syncFrontendToken() {{
					const token = readCookie("token");
					if (!token) return;

					try {{
						if (window.localStorage && window.localStorage.getItem("token") !== token) {{
							window.localStorage.setItem("token", token);
						}}
					}} catch (error) {{
						// Ignore localStorage failures; the server-side auth gate still protects the app.
					}}
				}}

				function currentTarget() {{
					return (window.location.pathname || "/") + (window.location.search || "") + (window.location.hash || "");
				}}

				function redirectToAuth() {{
					window.location.replace(`${{AUTH_PATH}}?redirect=${{encodeURIComponent(currentTarget())}}`);
					return new Promise(() => {{}});
				}}

				syncFrontendToken();

				if (isAuthRoute(path)) {{
					window.__DROPZONE_AUTH_GATE__ = Promise.resolve();
					return;
				}}

				window.__DROPZONE_AUTH_GATE__ = window
					.fetch(ACCOUNT_SUMMARY_URL, {{
						cache: "no-store",
						credentials: "include",
						headers: {{ Accept: "application/json" }},
					}})
					.then((response) => {{
						if (response.ok) return;
						return redirectToAuth();
					}})
					.catch(() => {{}});
			}})();
		</script>""".lstrip("\n")


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


def patch_index_html(text: str, subpath: str) -> str:
    script = auth_gate_script(subpath)

    if "window.__DROPZONE_AUTH_GATE__" not in text:
        head_anchor = "\t\t<script>\n\t\t\tfunction resizeIframe(obj) {\n"
        if head_anchor in text:
            text = text.replace(head_anchor, script + "\n\n" + head_anchor, 1)
        else:
            title_anchor = "\t\t<title>"
            if title_anchor not in text:
                raise SystemExit("missing expected head anchor for auth gate injection")
            text = text.replace(title_anchor, script + "\n\n" + title_anchor, 1)

    startup_pattern = re.compile(
        r'Promise\.all\(\[\s*import\((?P<first>[^)]*)\),\s*import\((?P<second>[^)]*)\)\s*\]\)\.then\(\(\[kit, app\]\) => \{\s*kit\.start\(app, element\);\s*\}\);',
        re.MULTILINE,
    )
    startup_replacement = (
        "Promise.all([\n"
        "\t\t\t\t\t\twindow.__DROPZONE_AUTH_GATE__ || Promise.resolve(),\n"
        "\t\t\t\t\t\timport(\\g<first>),\n"
        "\t\t\t\t\t\timport(\\g<second>)\n"
        "\t\t\t\t\t]).then(([_, kit, app]) => {\n"
        "\t\t\t\t\t\tkit.start(app, element);\n"
        "\t\t\t\t\t});"
    )
    patched = startup_pattern.sub(startup_replacement, text, count=1)
    if patched == text and "window.__DROPZONE_AUTH_GATE__ || Promise.resolve()" not in text:
        raise SystemExit("missing expected Svelte startup block for auth gate patch")

    return patched


def main() -> int:
    if len(sys.argv) not in {2, 3}:
        raise SystemExit("usage: patch-openwebui-build.py <index.html> [subpath]")

    index_path = Path(sys.argv[1])
    subpath = normalize_subpath(sys.argv[2] if len(sys.argv) == 3 else None)

    html = index_path.read_text(encoding="utf-8")
    html = patch_text(html, subpath)
    html = patch_index_html(html, subpath)
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
