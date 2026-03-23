#!/usr/bin/env python3
#
# Synchronize OpenWebUI upstream auth config and model ordering.
#
import argparse
import functools
import json
import os
import re
import urllib.request
from datetime import timedelta

from open_webui.internal.db import get_db
from open_webui.models.users import Users
from open_webui.utils.auth import create_token


TOKEN_RE = re.compile(r"[A-Za-z0-9.]+")
NUMBER_RE = re.compile(r"\d+(?:\.\d+)?")
ALPHA_PREFIX_RE = re.compile(r"^[A-Za-z]+")
ALPHA_RE = re.compile(r"[A-Za-z]+")
SIZE_SEGMENT_RE = re.compile(r"^(?:A)?\d+(?:\.\d+)?[KMB]$", re.IGNORECASE)
GENERIC_PREFIXES = {"a", "b", "m", "r", "v"}


def base_url() -> str:
    return os.environ.get("OPENWEBUI_SYNC_BASE_URL", "http://127.0.0.1:8080").rstrip("/")


def admin_email() -> str:
    return (
        os.environ.get("ADMIN_EMAIL")
        or os.environ.get("WEBUI_ADMIN_EMAIL")
        or os.environ.get("OPENWEBUI_ADMIN_EMAIL")
        or "admin@chutes.local"
    )


def lab_name(model_id: str) -> str:
    if "/" in model_id:
        return model_id.split("/", 1)[0]
    if ":" in model_id:
        return model_id.split(":", 1)[0]
    if "-" in model_id:
        return model_id.split("-", 1)[0]
    return model_id


def model_slug(model_id: str) -> str:
    if "/" in model_id:
        return model_id.split("/", 1)[1]
    if ":" in model_id:
        return model_id.split(":", 1)[1]
    return model_id


def is_tee_model(model_id: str) -> bool:
    upper_id = model_id.upper()
    return upper_id.endswith("-TEE") or "-TEE-" in upper_id


def parse_number(raw: str):
    if "." in raw:
        return float(raw)
    return int(raw.lstrip("0") or "0")


def compare_desc(left, right) -> int:
    for left_item, right_item in zip(left, right):
        if left_item == right_item:
            continue
        if isinstance(left_item, str) and isinstance(right_item, str):
            return -1 if left_item > right_item else 1
        if not isinstance(left_item, str) and not isinstance(right_item, str):
            return -1 if left_item > right_item else 1
        return -1 if not isinstance(left_item, str) else 1
    if len(left) != len(right):
        return -1 if len(left) > len(right) else 1
    return 0


@functools.lru_cache(maxsize=None)
def analyze_model(model_id: str) -> dict:
    slug = model_slug(model_id)
    family_parts = []
    release_markers = []
    version_markers = []
    fallback_tokens = []
    family_locked = False

    for segment in TOKEN_RE.findall(slug):
        if not segment:
            continue

        upper_segment = segment.upper()
        if upper_segment == "TEE":
            continue
        if SIZE_SEGMENT_RE.match(segment):
            fallback_tokens.extend(parse_number(raw) for raw in NUMBER_RE.findall(segment))
            continue

        prefix_match = ALPHA_PREFIX_RE.match(segment)
        prefix = prefix_match.group(0).lower() if prefix_match else ""
        if prefix and not family_locked:
            if not family_parts or prefix not in GENERIC_PREFIXES:
                family_parts.append(prefix)

        numeric_tokens = NUMBER_RE.findall(segment)
        if numeric_tokens:
            family_locked = True
            for raw in numeric_tokens:
                parsed = parse_number(raw)
                fallback_tokens.append(parsed)
                if raw.isdigit() and len(raw) >= 4:
                    release_markers.append(parsed)
                elif isinstance(parsed, int) and parsed >= 100:
                    release_markers.append(parsed)
                else:
                    version_markers.append(parsed)

            remainder = segment[prefix_match.end() :] if prefix_match else segment
            remainder = NUMBER_RE.sub(" ", remainder)
            fallback_tokens.extend(token.lower() for token in ALPHA_RE.findall(remainder))
            continue

        text_tokens = [token.lower() for token in ALPHA_RE.findall(segment) if token]
        if text_tokens:
            if not family_locked and not family_parts:
                family_parts.extend(text_tokens)
            fallback_tokens.extend(text_tokens)

    return {
        "model_id": model_id,
        "lab": lab_name(model_id).lower(),
        "tee_rank": 0 if is_tee_model(model_id) else 1,
        "family": tuple(family_parts) if family_parts else ("zzz",),
        "release_markers": tuple(release_markers),
        "version_markers": tuple(version_markers),
        "fallback_tokens": tuple(fallback_tokens) if fallback_tokens else (slug.lower(),),
    }


def compare_models(left: dict, right: dict) -> int:
    left_id = left.get("id") or left.get("name") or ""
    right_id = right.get("id") or right.get("name") or ""
    left_meta = analyze_model(left_id)
    right_meta = analyze_model(right_id)

    if left_meta["tee_rank"] != right_meta["tee_rank"]:
        return -1 if left_meta["tee_rank"] < right_meta["tee_rank"] else 1
    if left_meta["lab"] != right_meta["lab"]:
        return -1 if left_meta["lab"] < right_meta["lab"] else 1
    if bool(left_meta["release_markers"]) != bool(right_meta["release_markers"]):
        return -1 if left_meta["release_markers"] else 1

    for key in ("release_markers", "version_markers"):
        comparison = compare_desc(left_meta[key], right_meta[key])
        if comparison:
            return comparison

    if left_meta["family"] != right_meta["family"]:
        return -1 if left_meta["family"] < right_meta["family"] else 1

    comparison = compare_desc(left_meta["fallback_tokens"], right_meta["fallback_tokens"])
    if comparison:
        return comparison

    if left_id.lower() != right_id.lower():
        return -1 if left_id.lower() > right_id.lower() else 1
    return 0


def request_json(method: str, path: str, token: str, payload=None):
    headers = {
        "Accept": "application/json",
        "Authorization": f"Bearer {token}",
    }
    data = None
    if payload is not None:
        headers["Content-Type"] = "application/json"
        data = json.dumps(payload).encode("utf-8")

    request = urllib.request.Request(
        f"{base_url()}{path}",
        data=data,
        headers=headers,
        method=method,
    )
    with urllib.request.urlopen(request, timeout=20) as response:
        return json.loads(response.read().decode("utf-8"))


def admin_token() -> str:
    with get_db() as db:
        admin_user = Users.get_user_by_email(admin_email(), db)

    if not admin_user or admin_user.role != "admin":
        raise SystemExit(f"could not locate OpenWebUI admin user for {admin_email()}")

    return create_token({"id": admin_user.id}, expires_delta=timedelta(minutes=10))


def sync_runtime(configure_openai_auth: bool) -> tuple[int, list[str], int]:
    token = admin_token()
    updates = []

    openai_config = request_json("GET", "/openai/config", token)
    api_urls = openai_config.get("OPENAI_API_BASE_URLS", [])
    desired_api_configs = {
        str(index): {"auth_type": "system_oauth"} for index in range(len(api_urls))
    }

    if configure_openai_auth and openai_config.get("OPENAI_API_CONFIGS") != desired_api_configs:
        openai_config["OPENAI_API_CONFIGS"] = desired_api_configs
        request_json("POST", "/openai/config/update", token, openai_config)
        updates.append("OPENAI_API_CONFIGS")

    models_payload = request_json("GET", "/api/models?refresh=true", token)
    models = models_payload.get("data", []) if isinstance(models_payload, dict) else []
    if not isinstance(models, list) or not models:
        raise SystemExit("OpenWebUI /api/models returned no models after runtime configuration")

    ordered_ids = []
    seen_ids = set()
    for model in sorted(models, key=functools.cmp_to_key(compare_models)):
        model_id = model.get("id") or model.get("name")
        if model_id and model_id not in seen_ids:
            seen_ids.add(model_id)
            ordered_ids.append(model_id)

    models_config = request_json("GET", "/api/v1/configs/models", token)
    if ordered_ids and models_config.get("MODEL_ORDER_LIST") != ordered_ids:
        models_config["MODEL_ORDER_LIST"] = ordered_ids
        request_json("POST", "/api/v1/configs/models", token, models_config)
        updates.append("MODEL_ORDER_LIST")

    return len(api_urls), updates, len(ordered_ids)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--configure-openai-auth",
        action="store_true",
        help="also enforce system_oauth on every configured OpenAI-compatible backend",
    )
    parser.add_argument(
        "--quiet-no-change",
        action="store_true",
        help="suppress output when no runtime changes were required",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    backend_count, updates, model_count = sync_runtime(args.configure_openai_auth)

    if updates or not args.quiet_no_change:
        if args.configure_openai_auth:
            print(
                f"configured OpenWebUI upstream auth for {backend_count} backend(s) via system_oauth"
            )
        print(f"computed TEE-first newest-first provider ordering for {model_count} model(s)")
        if updates:
            print(f"updated runtime config: {', '.join(updates)}")
        else:
            print("runtime config already matched desired OpenWebUI settings")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
