#!/usr/bin/env python3

from pathlib import Path
import sys


def replace_once(text: str, old: str, new: str, label: str) -> str:
    return replace_one_of(text, [old], new, label)


def replace_one_of(text: str, olds: list[str], new: str, label: str) -> str:
    for old in olds:
        if old in text:
            return text.replace(old, new, 1)
    raise SystemExit(f"missing expected {label} block")


def replace_one_of_or_keep(text: str, olds: list[str], new: str, label: str) -> str:
    if new in text:
        return text
    return replace_one_of(text, olds, new, label)


def replace_all_of_or_keep(text: str, olds: list[str], new: str, label: str) -> str:
    replaced = False
    for old in olds:
        if old in text:
            text = text.replace(old, new)
            replaced = True
    if replaced or new in text:
        return text
    raise SystemExit(f"missing expected {label} block")


def insert_after_one_of(text: str, anchors: list[str], addition: str, label: str) -> str:
    if addition in text:
        return text
    for anchor in anchors:
        if anchor in text:
            return text.replace(anchor, anchor + addition, 1)
    raise SystemExit(f"missing expected {label} anchor")


def patch_env(path: Path) -> None:
    original = path.read_text(encoding="utf-8")
    patched = replace_one_of_or_keep(
        original,
        [
            'WEBUI_NAME = os.environ.get("WEBUI_NAME", "Open WebUI")\nif WEBUI_NAME != "Open WebUI":\n    WEBUI_NAME += " (Open WebUI)"\n\nWEBUI_FAVICON_URL = "https://openwebui.com/favicon.png"\n',
            "WEBUI_NAME = os.environ.get('WEBUI_NAME', 'Open WebUI')\nif WEBUI_NAME != 'Open WebUI':\n    WEBUI_NAME += ' (Open WebUI)'\n\nWEBUI_FAVICON_URL = 'https://openwebui.com/favicon.png'\n",
            'WEBUI_NAME = os.environ.get("WEBUI_NAME", "Open WebUI")\n\nWEBUI_FAVICON_URL = os.environ.get("WEBUI_FAVICON_URL", "/static/chutes-logo.svg")\n',
        ],
        'WEBUI_NAME = os.environ.get("WEBUI_NAME", "Open WebUI")\n\nWEBUI_FAVICON_URL = os.environ.get("WEBUI_FAVICON_URL", "/static/favicon.png")\n',
        "WEBUI_NAME suffix block",
    )
    path.write_text(patched, encoding="utf-8")


def patch_config_module(path: Path) -> None:
    original = path.read_text(encoding="utf-8")
    patched = replace_one_of_or_keep(
        original,
        [
            "    def update(self):\n        new_value = get_config_value(self.config_path)\n        if new_value is not None:\n            self.value = new_value\n            log.info(f'Updated {self.env_name} to new value {self.value}')\n",
        ],
        "    def update(self):\n        if self.config_path.startswith('oauth.') and not globals().get('ENABLE_OAUTH_PERSISTENT_CONFIG', False):\n            self.value = self.env_value\n            return\n\n        new_value = get_config_value(self.config_path)\n        if new_value is not None:\n            self.value = new_value\n            log.info(f'Updated {self.env_name} to new value {self.value}')\n",
        "OAuth persistent config refresh guard",
    )
    path.write_text(patched, encoding="utf-8")


def patch_main(path: Path) -> None:
    original = path.read_text(encoding="utf-8")
    patched = insert_after_one_of(
        original,
        ["from open_webui.utils.redis import get_sentinels_from_env\n"],
        "from open_webui.dropzone_account import get_chutes_account_summary\n",
        "dropzone account import",
    )
    patched = insert_after_one_of(
        patched,
        [
            "from open_webui.dropzone_account import get_chutes_account_summary\n",
            "from open_webui.utils.redis import get_sentinels_from_env\n",
        ],
        "from open_webui.dropzone_audio import router as dropzone_audio_router\n",
        "dropzone audio import",
    )
    patched = insert_after_one_of(
        patched,
        [
            "from open_webui.dropzone_audio import router as dropzone_audio_router\n",
            "from open_webui.dropzone_account import get_chutes_account_summary\n",
            "from open_webui.utils.redis import get_sentinels_from_env\n",
        ],
        "from open_webui.dropzone_auth import router as dropzone_auth_router\n",
        "dropzone auth import",
    )
    if '@app.get("/api/v1/dropzone/account-summary")' not in patched:
        patched = replace_one_of(
            patched,
            [
                '@app.get("/manifest.json")\nasync def get_manifest_json():\n    if app.state.EXTERNAL_PWA_MANIFEST_URL:\n        return requests.get(app.state.EXTERNAL_PWA_MANIFEST_URL).json()\n    else:\n        return {\n            "name": app.state.WEBUI_NAME,\n            "short_name": app.state.WEBUI_NAME,\n            "description": f"{app.state.WEBUI_NAME} is an open, extensible, user-friendly interface for AI that adapts to your workflow.",\n            "start_url": "/",\n            "display": "standalone",\n            "background_color": "#343541",\n            "icons": [\n                {\n                    "src": "/static/logo.png",\n                    "type": "image/png",\n                    "sizes": "500x500",\n                    "purpose": "any",\n                },\n                {\n                    "src": "/static/logo.png",\n                    "type": "image/png",\n                    "sizes": "500x500",\n                    "purpose": "maskable",\n                },\n            ],\n            "share_target": {\n                "action": "/",\n                "method": "GET",\n                "params": {"text": "shared"},\n            },\n        }\n',
                "@app.get('/manifest.json')\nasync def get_manifest_json():\n    if app.state.EXTERNAL_PWA_MANIFEST_URL:\n        return requests.get(app.state.EXTERNAL_PWA_MANIFEST_URL).json()\n    else:\n        return {\n            'name': app.state.WEBUI_NAME,\n            'short_name': app.state.WEBUI_NAME,\n            'description': f'{app.state.WEBUI_NAME} is an open, extensible, user-friendly interface for AI that adapts to your workflow.',\n            'start_url': '/',\n            'display': 'standalone',\n            'background_color': '#343541',\n            'icons': [\n                {\n                    'src': '/static/logo.png',\n                    'type': 'image/png',\n                    'sizes': '500x500',\n                    'purpose': 'any',\n                },\n                {\n                    'src': '/static/logo.png',\n                    'type': 'image/png',\n                    'sizes': '500x500',\n                    'purpose': 'maskable',\n                },\n            ],\n            'share_target': {\n                'action': '/',\n                'method': 'GET',\n                'params': {'text': 'shared'},\n            },\n        }\n",
            ],
            '@app.get("/api/v1/dropzone/account-summary")\nasync def get_dropzone_account_summary(\n    user=Depends(get_verified_user), db: Session = Depends(get_session)\n):\n    return get_chutes_account_summary(user, db)\n\n\napp.include_router(dropzone_audio_router)\napp.include_router(dropzone_auth_router)\n\n\n@app.get("/manifest.json")\nasync def get_manifest_json():\n    if app.state.EXTERNAL_PWA_MANIFEST_URL:\n        return requests.get(app.state.EXTERNAL_PWA_MANIFEST_URL).json()\n    else:\n        return {\n            "name": app.state.WEBUI_NAME,\n            "short_name": app.state.WEBUI_NAME,\n            "description": "Chutes Chat is a private AI workspace powered by Chutes.",\n            "start_url": "/chat/",\n            "scope": "/chat/",\n            "display": "standalone",\n            "theme_color": "#171717",\n            "background_color": "#171717",\n            "icons": [\n                {\n                    "src": "/chat/static/chutes-chat-icon-192.png",\n                    "type": "image/png",\n                    "sizes": "192x192",\n                    "purpose": "any maskable",\n                },\n                {\n                    "src": "/chat/static/chutes-chat-icon-512.png",\n                    "type": "image/png",\n                    "sizes": "512x512",\n                    "purpose": "any maskable",\n                },\n            ],\n            "share_target": {\n                "action": "/chat/",\n                "method": "GET",\n                "params": {"text": "shared"},\n            },\n        }\n',
            "manifest route block",
        )
    patched = insert_after_one_of(
        patched,
        [
            "app.include_router(dropzone_audio_router)\n",
        ],
        "app.include_router(dropzone_auth_router)\n",
        "dropzone auth router include",
    )
    # Allow comma-delimited base_model_id (Chutes multi-model routing) to bypass
    # the MODELS lookup — the first model in the list determines the backend.
    if '            if "," not in base_model_id and base_model_id not in request.app.state.MODELS:\n' not in patched:
        patched = replace_once(
            patched,
            "            if base_model_id not in request.app.state.MODELS:\n",
            '            if "," not in base_model_id and base_model_id not in request.app.state.MODELS:\n',
            "multi-model routing bypass",
        )
    patched = replace_one_of_or_keep(
        patched,
        [
            "            form_data, metadata, events = await process_chat_payload(request, form_data, user, metadata, model)\n\n            response = await chat_completion_handler(request, form_data, user)\n",
            "            form_data, metadata, events = await process_chat_payload(request, form_data, user, metadata, model)\n\n            response = await chat_completion_handler(request, form_data, user)\r\n",
        ],
        "            form_data, metadata, events = await process_chat_payload(request, form_data, user, metadata, model)\n\n            response_override = metadata.pop('_dropzone_response_override', None)\n            if response_override is not None:\n                response = response_override\n            else:\n                response = await chat_completion_handler(request, form_data, user)\n",
        "dropzone image response override bypass",
    )
    path.write_text(patched, encoding="utf-8")


def patch_openai_router(path: Path) -> None:
    original = path.read_text(encoding="utf-8")
    patched = insert_after_one_of(
        original,
        ["from open_webui.models.models import Models\n"],
        "from open_webui.dropzone_oauth import get_request_oauth_token\n",
        "dropzone oauth import for openai router",
    )
    # When model_id is a comma-delimited routing string, use the first model
    # for backend resolution (urlIdx) while keeping the full string in the payload.
    patched = replace_one_of_or_keep(
        patched,
        [
            "    model = models.get(model_id)\n\n    if model:\n        idx = model[\"urlIdx\"]\n    else:\n        raise HTTPException(\n            status_code=404,\n            detail=\"Model not found\",\n        )\n",
            "    model = models.get(model_id)\n\n    if model:\n        idx = model['urlIdx']\n    else:\n        raise HTTPException(\n            status_code=404,\n            detail='Model not found',\n        )\n",
        ],
        '    model = models.get(model_id)\n    if not model and "," in model_id:\n        model = models.get(model_id.split(",")[0])\n\n    if model:\n        idx = model["urlIdx"]\n    else:\n        raise HTTPException(\n            status_code=404,\n            detail="Model not found",\n        )\n',
        "multi-model urlIdx resolution",
    )
    patched = replace_one_of_or_keep(
        patched,
        [
            "    elif auth_type == 'system_oauth':\n        cookies = request.cookies\n\n        oauth_token = None\n        try:\n            if request.cookies.get('oauth_session_id', None):\n                oauth_token = await request.app.state.oauth_manager.get_oauth_token(\n                    user.id,\n                    request.cookies.get('oauth_session_id', None),\n                )\n        except Exception as e:\n            log.error(f'Error getting OAuth token: {e}')\n\n        if oauth_token:\n            token = f'{oauth_token.get(\"access_token\", \"\")}'\n",
            '    elif auth_type == "system_oauth":\n        cookies = request.cookies\n\n        oauth_token = None\n        try:\n            if request.cookies.get("oauth_session_id", None):\n                oauth_token = await request.app.state.oauth_manager.get_oauth_token(\n                    user.id,\n                    request.cookies.get("oauth_session_id", None),\n                )\n        except Exception as e:\n            log.error(f"Error getting OAuth token: {e}")\n\n        if oauth_token:\n            token = f"{oauth_token.get(\'access_token\', \'\')}"\n',
        ],
        "    elif auth_type == 'system_oauth':\n        cookies = request.cookies\n\n        oauth_token = await get_request_oauth_token(request, user)\n        if oauth_token:\n            token = f'{oauth_token.get(\"access_token\", \"\")}'\n",
        "system oauth token fallback for openai router",
    )
    patched = replace_one_of_or_keep(
        patched,
        [
            '            connection_type = api_config.get("connection_type", "external")\n',
            "            connection_type = api_config.get('connection_type', 'external')\n",
        ],
        '            connection_type = api_config.get("connection_type")\n',
        "OpenAI connection type default",
    )
    patched = replace_one_of_or_keep(
        patched,
        [
            '                            "connection_type": model.get("connection_type", "external"),\n',
            "                            'connection_type': model.get('connection_type', 'external'),\n",
        ],
        '                            **({"connection_type": model["connection_type"]} if model.get("connection_type") else {}),\n',
        "OpenAI merged connection type default",
    )
    path.write_text(patched, encoding="utf-8")


def patch_functions(path: Path) -> None:
    original = path.read_text(encoding="utf-8")
    patched = insert_after_one_of(
        original,
        ["from open_webui.models.models import Models\n"],
        "from open_webui.dropzone_oauth import get_request_oauth_token\n",
        "dropzone oauth import for functions",
    )
    patched = replace_one_of_or_keep(
        patched,
        [
            "    oauth_token = None\n    try:\n        if request.cookies.get('oauth_session_id', None):\n            oauth_token = await request.app.state.oauth_manager.get_oauth_token(\n                user.id,\n                request.cookies.get('oauth_session_id', None),\n            )\n    except Exception as e:\n        log.error(f'Error getting OAuth token: {e}')\n",
            '    oauth_token = None\n    try:\n        if request.cookies.get("oauth_session_id", None):\n            oauth_token = await request.app.state.oauth_manager.get_oauth_token(\n                user.id,\n                request.cookies.get("oauth_session_id", None),\n            )\n    except Exception as e:\n        log.error(f"Error getting OAuth token: {e}")\n',
        ],
        "    oauth_token = await get_request_oauth_token(request, user)\n",
        "system oauth token fallback for functions",
    )
    path.write_text(patched, encoding="utf-8")


def patch_middleware(path: Path) -> None:
    original = path.read_text(encoding="utf-8")
    patched = insert_after_one_of(
        original,
        ["from open_webui.models.oauth_sessions import OAuthSessions\n"],
        "from open_webui.dropzone_oauth import get_request_oauth_token\n",
        "dropzone oauth import for middleware",
    )
    patched = insert_after_one_of(
        patched,
        ["from open_webui.dropzone_oauth import get_request_oauth_token\n"],
        "from open_webui.dropzone_images import describe_chutes_image_request, is_chutes_image_backend\n",
        "dropzone image helpers import for middleware",
    )
    patched = replace_one_of_or_keep(
        patched,
        [
            "async def get_system_oauth_token(request, user):\n    oauth_token = None\n    try:\n        if request.cookies.get('oauth_session_id', None):\n            oauth_token = await request.app.state.oauth_manager.get_oauth_token(\n                user.id,\n                request.cookies.get('oauth_session_id', None),\n            )\n    except Exception as e:\n        log.error(f'Error getting OAuth token: {e}')\n    return oauth_token\n",
            'async def get_system_oauth_token(request, user):\n    oauth_token = None\n    try:\n        if request.cookies.get("oauth_session_id", None):\n            oauth_token = await request.app.state.oauth_manager.get_oauth_token(\n                user.id,\n                request.cookies.get("oauth_session_id", None),\n            )\n    except Exception as e:\n        log.error(f"Error getting OAuth token: {e}")\n    return oauth_token\n',
        ],
        "async def get_system_oauth_token(request, user):\n    return await get_request_oauth_token(request, user)\n",
        "system oauth token fallback for middleware",
    )
    patched = insert_after_one_of(
        patched,
        [
            "async def get_system_oauth_token(request, user):\n    return await get_request_oauth_token(request, user)\n",
        ],
        "\n"
        "def _dropzone_last_json_object(text):\n"
        "    bracket_start = text.rfind('{')\n"
        "    bracket_end = text.rfind('}') + 1\n"
        "    if bracket_start == -1 or bracket_end <= bracket_start:\n"
        "        raise ValueError('No JSON object found in the response')\n"
        "    return text[bracket_start:bracket_end]\n"
        "\n"
        "\n"
        "def _dropzone_parse_image_prompt_response(response, fallback_prompt):\n"
        "    prompt = fallback_prompt\n"
        "    generated_request = {}\n"
        "    prompt_reasoning = ''\n"
        "\n"
        "    choices = response.get('choices', []) if isinstance(response, dict) else []\n"
        "    if choices and isinstance(choices[0], dict):\n"
        "        message = choices[0].get('message', {}) or {}\n"
        "        if isinstance(message, dict):\n"
        "            prompt_reasoning = str(message.get('reasoning_content') or '').strip()\n"
        "            response_content = str(message.get('content') or '').strip()\n"
        "            if response_content:\n"
        "                try:\n"
        "                    generated_request = json.loads(_dropzone_last_json_object(response_content))\n"
        "                except Exception:\n"
        "                    generated_request = {}\n"
        "\n"
        "    if not isinstance(generated_request, dict):\n"
        "        generated_request = {}\n"
        "\n"
        "    prompt_candidate = str(generated_request.get('prompt') or '').strip()\n"
        "    if prompt_candidate:\n"
        "        prompt = prompt_candidate\n"
        "\n"
        "    rationale = str(generated_request.get('rationale') or '').strip()\n"
        "    if rationale and (not prompt_reasoning or len(prompt_reasoning) > 1200):\n"
        "        prompt_reasoning = rationale\n"
        "\n"
        "    return prompt, generated_request, prompt_reasoning\n"
        "\n"
        "\n"
        "def _dropzone_apply_generated_image_request(form_data, prompt, generated_request):\n"
        "    image_request_form_data = {'prompt': prompt}\n"
        "\n"
        "    model = getattr(form_data, 'model', None)\n"
        "    if model:\n"
        "        image_request_form_data['model'] = model\n"
        "\n"
        "    n = getattr(form_data, 'n', None)\n"
        "    if n is not None:\n"
        "        try:\n"
        "            image_request_form_data['n'] = max(1, int(n or 1))\n"
        "        except (TypeError, ValueError):\n"
        "            image_request_form_data['n'] = 1\n"
        "\n"
        "    size = str(getattr(form_data, 'size', None) or '').strip()\n"
        "    if not size:\n"
        "        size = str(generated_request.get('size') or '').strip()\n"
        "    if size and re.match(r'^\\d+x\\d+$', size):\n"
        "        image_request_form_data['size'] = size\n"
        "\n"
        "    negative_prompt = str(getattr(form_data, 'negative_prompt', None) or '').strip()\n"
        "    if not negative_prompt:\n"
        "        negative_prompt = str(generated_request.get('negative_prompt') or '').strip()\n"
        "    if negative_prompt:\n"
        "        image_request_form_data['negative_prompt'] = negative_prompt\n"
        "\n"
        "    steps = getattr(form_data, 'steps', None)\n"
        "    if steps in (None, '', 0):\n"
        "        steps = generated_request.get('steps')\n"
        "    try:\n"
        "        steps_value = int(steps) if steps is not None else None\n"
        "    except (TypeError, ValueError):\n"
        "        steps_value = None\n"
        "    if steps_value and steps_value > 0:\n"
        "        image_request_form_data['steps'] = steps_value\n"
        "\n"
        "    return image_request_form_data\n"
        "\n"
        "\n"
        "def _dropzone_fallback_image_request_preview(image_request_form_data, image_model_id):\n"
        "    size = str(image_request_form_data.get('size') or '').strip()\n"
        "    payload = {\n"
        "        'prompt': str(image_request_form_data.get('prompt') or '').strip(),\n"
        "    }\n"
        "    if size and re.match(r'^\\d+x\\d+$', size):\n"
        "        width_str, height_str = size.split('x', 1)\n"
        "        payload['width'] = int(width_str)\n"
        "        payload['height'] = int(height_str)\n"
        "    if image_request_form_data.get('negative_prompt'):\n"
        "        payload['negative_prompt'] = image_request_form_data['negative_prompt']\n"
        "    if image_request_form_data.get('steps'):\n"
        "        payload['num_inference_steps'] = image_request_form_data['steps']\n"
        "    return {\n"
        "        'selected_model': {'id': str(image_model_id or '').strip()},\n"
        "        'payload': payload,\n"
        "        'size': size,\n"
        "    }\n"
        "\n"
        "\n"
        "def _dropzone_image_prompt_task_context(image_request_preview):\n"
        "    if not isinstance(image_request_preview, dict):\n"
        "        return ''\n"
        "\n"
        "    selected_model = image_request_preview.get('selected_model') or {}\n"
        "    payload = image_request_preview.get('payload') or {}\n"
        "    if not isinstance(selected_model, dict) or not isinstance(payload, dict):\n"
        "        return ''\n"
        "\n"
        "    lines = []\n"
        "    selected_model_id = str(selected_model.get('id') or '').strip()\n"
        "    if selected_model_id:\n"
        "        lines.append(f'Selected image model: {selected_model_id}')\n"
        "\n"
        "    size = str(image_request_preview.get('size') or '').strip()\n"
        "    if size:\n"
        "        lines.append(f'Current size override: {size}')\n"
        "\n"
        "    steps = payload.get('num_inference_steps')\n"
        "    if steps:\n"
        "        lines.append(f'Current step override: {steps}')\n"
        "\n"
        "    lines.append(\n"
        "        'You may optionally set JSON keys prompt, negative_prompt, size, steps, and rationale. '\n"
        "        'Prefer conservative step counts for fast FLUX or schnell style models unless the user '\n"
        "        'explicitly asks for a slower, higher-detail render.'\n"
        "    )\n"
        "    return '\\n'.join(lines).strip()\n"
        "\n"
        "\n"
        "def _dropzone_markdown_blockquote(text):\n"
        "    cleaned = str(text or '').strip()\n"
        "    if not cleaned:\n"
        "        return ''\n"
        "    lines = cleaned.replace('\\r\\n', '\\n').replace('\\r', '\\n').split('\\n')\n"
        "    return '\\n'.join(('> ' + line) if line else '>' for line in lines)\n"
        "\n"
        "\n"
        "def _dropzone_image_success_content(prompt, image_request_preview=None, prompt_reasoning='', prompt_model=''):\n"
        "    sections = []\n"
        "    prompt_reasoning = str(prompt_reasoning or '').strip()\n"
        "    if prompt_reasoning:\n"
        "        sections.extend(\n"
        "            [\n"
        "                '**Prompt planning**',\n"
        "                _dropzone_markdown_blockquote(prompt_reasoning),\n"
        "                '',\n"
        "            ]\n"
        "        )\n"
        "\n"
        "    prompt_model = str(prompt_model or '').strip()\n"
        "    if prompt_model:\n"
        "        sections.append(f'**Prompt model**: `{prompt_model}`')\n"
        "\n"
        "    payload = image_request_preview.get('payload') if isinstance(image_request_preview, dict) else {}\n"
        "    if not isinstance(payload, dict):\n"
        "        payload = {}\n"
        "\n"
        "    selected_model = image_request_preview.get('selected_model') if isinstance(image_request_preview, dict) else {}\n"
        "    if not isinstance(selected_model, dict):\n"
        "        selected_model = {}\n"
        "    selected_model_id = str(selected_model.get('id') or '').strip()\n"
        "    if selected_model_id:\n"
        "        sections.append(f'**Image model**: `{selected_model_id}`')\n"
        "    if selected_model.get('model_fallback'):\n"
        "        fallback_from = str(selected_model.get('fallback_from') or selected_model.get('requested_model') or '').strip()\n"
        "        fallback_to = str(selected_model.get('fallback_to') or selected_model.get('resolved_model') or selected_model_id).strip()\n"
        "        fallback_reason = str(selected_model.get('fallback_reason') or '').strip()\n"
        "        if fallback_from and fallback_to:\n"
        "            reason_text = f' ({fallback_reason})' if fallback_reason else ''\n"
        "            sections.append(f'**Image model fallback**: requested `{fallback_from}`, used `{fallback_to}`{reason_text}')\n"
        "\n"
        "    prompt_text = str(payload.get('prompt') or prompt or '').strip()\n"
        "    if prompt_text:\n"
        "        if sections:\n"
        "            sections.append('')\n"
        "        sections.extend(['**Prompt sent**', _dropzone_markdown_blockquote(prompt_text)])\n"
        "\n"
        "    params = []\n"
        "    size = str(image_request_preview.get('size') or '').strip() if isinstance(image_request_preview, dict) else ''\n"
        "    if size:\n"
        "        params.append(f'- size: `{size}`')\n"
        "\n"
        "    steps = payload.get('num_inference_steps')\n"
        "    if steps is not None:\n"
        "        params.append(f'- steps: `{steps}`')\n"
        "\n"
        "    negative_prompt = str(payload.get('negative_prompt') or '').strip()\n"
        "    if negative_prompt:\n"
        "        params.append(f'- negative prompt: `{negative_prompt}`')\n"
        "\n"
        "    if params:\n"
        "        if sections:\n"
        "            sections.append('')\n"
        "        sections.append('**Parameters**')\n"
        "        sections.extend(params)\n"
        "\n"
        "    content = '\\n'.join(section for section in sections if section is not None).strip()\n"
        "    return content or '**Image request**'\n"
        "\n"
        "\n"
        "def _dropzone_image_failure_content(error_message):\n"
        "    return f'Image generation failed: {error_message or \"Unknown error\"}'\n",
        "dropzone image middleware helpers",
    )
    patched = replace_one_of_or_keep(
        patched,
        [
            "        if request.app.state.config.ENABLE_IMAGE_PROMPT_GENERATION:\n            try:\n                res = await generate_image_prompt(\n                    request,\n                    {\n                        'model': form_data['model'],\n                        'messages': form_data['messages'],\n                        'chat_id': metadata.get('chat_id'),\n                    },\n                    user,\n                )\n\n                response = res['choices'][0]['message']['content']\n\n                try:\n                    bracket_start = response.rfind('{')\n                    bracket_end = response.rfind('}') + 1\n\n                    if bracket_start == -1 or bracket_end == -1:\n                        raise Exception('No JSON object found in the response')\n\n                    response = response[bracket_start:bracket_end]\n                    response = json.loads(response)\n                    prompt = response.get('prompt', [])\n                except Exception as e:\n                    prompt = user_message\n\n            except Exception as e:\n                log.exception(e)\n                prompt = user_message\n\n        try:\n            images = await image_generations(\n                request=request,\n                form_data=CreateImageForm(**{'prompt': prompt}),\n                metadata={\n                    'chat_id': metadata.get('chat_id', None),\n                    'message_id': metadata.get('message_id', None),\n                },\n                user=user,\n            )\n",
            "        if request.app.state.config.ENABLE_IMAGE_PROMPT_GENERATION:\r\n            try:\r\n                res = await generate_image_prompt(\r\n                    request,\r\n                    {\r\n                        'model': form_data['model'],\r\n                        'messages': form_data['messages'],\r\n                        'chat_id': metadata.get('chat_id'),\r\n                    },\r\n                    user,\r\n                )\r\n\r\n                response = res['choices'][0]['message']['content']\r\n\r\n                try:\r\n                    bracket_start = response.rfind('{')\r\n                    bracket_end = response.rfind('}') + 1\r\n\r\n                    if bracket_start == -1 or bracket_end == -1:\r\n                        raise Exception('No JSON object found in the response')\r\n\r\n                    response = response[bracket_start:bracket_end]\r\n                    response = json.loads(response)\r\n                    prompt = response.get('prompt', [])\r\n                except Exception as e:\r\n                    prompt = user_message\r\n\r\n            except Exception as e:\r\n                log.exception(e)\r\n                prompt = user_message\r\n\r\n        try:\r\n            images = await image_generations(\r\n                request=request,\r\n                form_data=CreateImageForm(**{'prompt': prompt}),\r\n                metadata={\r\n                    'chat_id': metadata.get('chat_id', None),\r\n                    'message_id': metadata.get('message_id', None),\r\n                },\r\n                user=user,\r\n            )\r\n",
        ],
        "        prompt_reasoning = ''\n"
        "        generated_request = {}\n"
        "        initial_image_request = None\n"
        "        effective_prompt_model = (\n"
        "            getattr(request.app.state.config, 'TASK_MODEL_EXTERNAL', None)\n"
        "            or getattr(request.app.state.config, 'TASK_MODEL', None)\n"
        "            or form_data.get('model')\n"
        "        )\n"
        "        try:\n"
        "            initial_image_request_form_data = {\n"
        "                'prompt': user_message,\n"
        "                **({'model': form_data.get('model')} if form_data.get('model') else {}),\n"
        "                **({'size': form_data.get('size')} if form_data.get('size') else {}),\n"
        "                **({'steps': form_data.get('steps')} if form_data.get('steps') else {}),\n"
        "                **({'negative_prompt': form_data.get('negative_prompt')} if form_data.get('negative_prompt') else {}),\n"
        "            }\n"
        "            if is_chutes_image_backend(request):\n"
        "                initial_image_request = await describe_chutes_image_request(\n"
        "                    request,\n"
        "                    CreateImageForm(**initial_image_request_form_data),\n"
        "                    user=user,\n"
        "                )\n"
        "            if not initial_image_request:\n"
        "                initial_image_request = _dropzone_fallback_image_request_preview(\n"
        "                    initial_image_request_form_data,\n"
        "                    getattr(request.app.state.config, 'IMAGE_GENERATION_MODEL', None),\n"
        "                )\n"
        "        except Exception as e:\n"
        "            log.debug(f'Unable to resolve initial image request preview: {e}')\n"
        "            if not initial_image_request:\n"
        "                initial_image_request = _dropzone_fallback_image_request_preview(\n"
        "                    initial_image_request_form_data,\n"
        "                    getattr(request.app.state.config, 'IMAGE_GENERATION_MODEL', None),\n"
        "                )\n"
        "\n"
        "        if request.app.state.config.ENABLE_IMAGE_PROMPT_GENERATION:\n"
        "            try:\n"
        "                image_prompt_messages = form_data['messages']\n"
        "                image_prompt_context = _dropzone_image_prompt_task_context(initial_image_request)\n"
        "                if image_prompt_context:\n"
        "                    image_prompt_messages = list(form_data['messages']) + [\n"
        "                        {'role': 'system', 'content': image_prompt_context}\n"
        "                    ]\n"
        "\n"
        "                res = await generate_image_prompt(\n"
        "                    request,\n"
        "                    {\n"
        "                        'model': form_data['model'],\n"
        "                        'messages': image_prompt_messages,\n"
        "                        'chat_id': metadata.get('chat_id'),\n"
        "                    },\n"
        "                    user,\n"
        "                )\n"
        "\n"
        "                prompt, generated_request, prompt_reasoning = _dropzone_parse_image_prompt_response(\n"
        "                    res,\n"
        "                    user_message,\n"
        "                )\n"
        "            except Exception as e:\n"
        "                log.exception(e)\n"
        "                prompt = user_message\n"
        "\n"
        "        image_request_form_data = _dropzone_apply_generated_image_request(\n"
        "            form_data,\n"
        "            prompt,\n"
        "            generated_request,\n"
        "        )\n"
        "        image_request_preview = _dropzone_fallback_image_request_preview(\n"
        "            image_request_form_data,\n"
        "            getattr(request.app.state.config, 'IMAGE_GENERATION_MODEL', None),\n"
        "        )\n"
        "        try:\n"
        "            if is_chutes_image_backend(request):\n"
        "                image_request_preview = await describe_chutes_image_request(\n"
        "                    request,\n"
        "                    CreateImageForm(**image_request_form_data),\n"
        "                    user=user,\n"
        "                )\n"
        "        except Exception as e:\n"
        "            log.debug(f'Unable to resolve final image request preview: {e}')\n"
        "\n"
        "        try:\n"
        "            images = await image_generations(\n"
        "                request=request,\n"
        "                form_data=CreateImageForm(**image_request_form_data),\n"
        "                metadata={\n"
        "                    'chat_id': metadata.get('chat_id', None),\n"
        "                    'message_id': metadata.get('message_id', None),\n"
        "                },\n"
        "                user=user,\n"
        "            )\n",
        "dropzone image prompt and request summary flow",
    )
    patched = replace_one_of_or_keep(
        patched,
        [
            "            system_message_content = '<context>The requested image has been edited and created and is now being shown to the user. Let them know that it has been generated.</context>'\n",
        ],
        "            metadata['_dropzone_response_override'] = {\n"
        "                'choices': [\n"
        "                    {\n"
        "                        'message': {\n"
        "                            'content': _dropzone_image_success_content(prompt)\n"
        "                        }\n"
        "                    }\n"
        "                ]\n"
        "            }\n",
        "dropzone image edit success summary",
    )
    patched = replace_one_of_or_keep(
        patched,
        [
            "            system_message_content = '<context>The requested image has been created by the system successfully and is now being shown to the user. Let the user know that the image they requested has been generated and is now shown in the chat.</context>'\n",
        ],
        "            metadata['_dropzone_response_override'] = {\n"
        "                'choices': [\n"
        "                    {\n"
        "                        'message': {\n"
        "                            'content': _dropzone_image_success_content(\n"
        "                                prompt,\n"
        "                                image_request_preview=image_request_preview,\n"
        "                                prompt_reasoning=prompt_reasoning,\n"
        "                                prompt_model=effective_prompt_model,\n"
        "                            )\n"
        "                        }\n"
        "                    }\n"
        "                ]\n"
        "            }\n",
        "dropzone image create success summary",
    )
    patched = replace_all_of_or_keep(
        patched,
        [
            "            system_message_content = f'<context>Image generation was attempted but failed. The system is currently unable to generate the image. Tell the user that the following error occurred: {error_message}</context>'\n",
            "            system_message_content = f'<context>Image generation was attempted but failed because of an error. The system is currently unable to generate the image. Tell the user that the following error occurred: {error_message}</context>'\n",
        ],
        "            metadata['_dropzone_response_override'] = {\n"
        "                'choices': [\n"
        "                    {\n"
        "                        'message': {\n"
        "                            'content': _dropzone_image_failure_content(error_message)\n"
        "                        }\n"
        "                    }\n"
        "                ]\n"
        "            }\n",
        "dropzone image failure override",
    )
    path.write_text(patched, encoding="utf-8")


def patch_utils_oauth(path: Path) -> None:
    original = path.read_text(encoding="utf-8")
    patched = insert_after_one_of(
        original,
        ["from open_webui.utils.auth import get_password_hash, create_token\n"],
        "from open_webui.dropzone_auth import get_request_auth_redirect_path\n",
        "dropzone auth redirect import for oauth utils",
    )
    patched = replace_one_of_or_keep(
        patched,
        [
            "        redirect_base_url = (str(request.app.state.config.WEBUI_URL or request.base_url)).rstrip('/')\n        redirect_url = f'{redirect_base_url}/auth'\n\n        if error_message:\n            redirect_url = f'{redirect_url}?error={urllib.parse.quote_plus(error_message)}'\n            return RedirectResponse(url=redirect_url, headers=response.headers)\n\n        response = RedirectResponse(url=redirect_url, headers=response.headers)\n",
            '        redirect_base_url = (str(request.app.state.config.WEBUI_URL or request.base_url)).rstrip("/")\n        redirect_url = f"{redirect_base_url}/auth"\n\n        if error_message:\n            redirect_url = f"{redirect_url}?error={urllib.parse.quote_plus(error_message)}"\n            return RedirectResponse(url=redirect_url, headers=response.headers)\n\n        response = RedirectResponse(url=redirect_url, headers=response.headers)\n',
        ],
        "        redirect_base_url = str(request.base_url).rstrip('/')\n        error_redirect_url = f'{redirect_base_url}/auth'\n        success_redirect_url = f'{redirect_base_url}{get_request_auth_redirect_path(request)}'\n\n        if error_message:\n            error_redirect_url = f'{error_redirect_url}?error={urllib.parse.quote_plus(error_message)}'\n            return RedirectResponse(url=error_redirect_url, headers=response.headers)\n\n        response = RedirectResponse(url=success_redirect_url, headers=response.headers)\n",
        "dropzone oauth callback redirect target",
    )
    patched = replace_one_of_or_keep(
        patched,
        [
            "            try:\n                token = await client.authorize_access_token(request, **auth_params)\n            except Exception as e:\n                detailed_error = _build_oauth_callback_error_message(e)\n                log.warning(\n                    'OAuth callback error during authorize_access_token for provider %s: %s',\n                    provider,\n                    detailed_error,\n                    exc_info=True,\n                )\n                raise HTTPException(400, detail=ERROR_MESSAGES.INVALID_CRED)\n",
            '            try:\n                token = await client.authorize_access_token(request, **auth_params)\n            except Exception as e:\n                detailed_error = _build_oauth_callback_error_message(e)\n                log.warning(\n                    "OAuth callback error during authorize_access_token for provider %s: %s",\n                    provider,\n                    detailed_error,\n                    exc_info=True,\n                )\n                raise HTTPException(400, detail=ERROR_MESSAGES.INVALID_CRED)\n',
        ],
        "            try:\n"
        "                token = await client.authorize_access_token(request, **auth_params)\n"
        "            except Exception as e:\n"
        "                detailed_error = _build_oauth_callback_error_message(e)\n"
        "                log.warning(\n"
        "                    'OAuth callback error during authorize_access_token for provider %s: %s',\n"
        "                    provider,\n"
        "                    detailed_error,\n"
        "                    exc_info=True,\n"
        "                )\n"
        "                provider_status = getattr(getattr(e, 'response', None), 'status_code', None)\n"
        "                if provider_status is not None and int(provider_status) >= 500:\n"
        "                    raise HTTPException(\n"
        "                        502,\n"
        "                        detail='OAuth provider is temporarily unavailable. Please try again in a minute.',\n"
        "                    )\n"
        "                raise HTTPException(400, detail=ERROR_MESSAGES.INVALID_CRED)\n",
        "oauth callback provider outage handling",
    )
    patched = replace_one_of_or_keep(
        patched,
        [
            "        # Compute cookie expiry from JWT lifetime\n        expires_delta = parse_duration(auth_manager_config.JWT_EXPIRES_IN)\n        cookie_max_age = int(expires_delta.total_seconds()) if expires_delta else None\n",
        ],
        "        # Compute cookie expiry from JWT lifetime\n"
        "        expires_delta = parse_duration(auth_manager_config.JWT_EXPIRES_IN)\n"
        "        cookie_max_age = int(expires_delta.total_seconds()) if expires_delta else None\n"
        "        cookie_expires = datetime.utcnow() + expires_delta if expires_delta else None\n",
        "oauth session cookie expiry fix",
    )
    path.write_text(patched, encoding="utf-8")


def patch_configs(path: Path) -> None:
    original = path.read_text(encoding="utf-8")
    patched = insert_after_one_of(
        original,
        ["from open_webui.models.oauth_sessions import OAuthSessions\n"],
        "from open_webui.dropzone_oauth import get_request_oauth_token\n",
        "dropzone oauth import for configs",
    )
    patched = replace_one_of_or_keep(
        patched,
        [
            "                    elif form_data.auth_type == 'system_oauth':\n                        oauth_token = None\n                        try:\n                            if request.cookies.get('oauth_session_id', None):\n                                oauth_token = await request.app.state.oauth_manager.get_oauth_token(\n                                    user.id,\n                                    request.cookies.get('oauth_session_id', None),\n                                )\n\n                                if oauth_token:\n                                    token = oauth_token.get('access_token', '')\n                        except Exception as e:\n                            pass\n",
            '                    elif form_data.auth_type == "system_oauth":\n                        oauth_token = None\n                        try:\n                            if request.cookies.get("oauth_session_id", None):\n                                oauth_token = await request.app.state.oauth_manager.get_oauth_token(\n                                    user.id,\n                                    request.cookies.get("oauth_session_id", None),\n                                )\n\n                                if oauth_token:\n                                    token = oauth_token.get("access_token", "")\n                        except Exception as e:\n                            pass\n',
        ],
        "                    elif form_data.auth_type == 'system_oauth':\n                        oauth_token = await get_request_oauth_token(request, user)\n                        if oauth_token:\n                            token = oauth_token.get('access_token', '')\n",
        "system oauth token fallback for MCP configs",
    )
    patched = replace_one_of_or_keep(
        patched,
        [
            "            elif form_data.auth_type == 'system_oauth':\n                try:\n                    if request.cookies.get('oauth_session_id', None):\n                        oauth_token = await request.app.state.oauth_manager.get_oauth_token(\n                            user.id,\n                            request.cookies.get('oauth_session_id', None),\n                        )\n\n                        if oauth_token:\n                            token = oauth_token.get('access_token', '')\n\n                except Exception as e:\n                    pass\n",
            '            elif form_data.auth_type == "system_oauth":\n                try:\n                    if request.cookies.get("oauth_session_id", None):\n                        oauth_token = await request.app.state.oauth_manager.get_oauth_token(\n                            user.id,\n                            request.cookies.get("oauth_session_id", None),\n                        )\n\n                        if oauth_token:\n                            token = oauth_token.get("access_token", "")\n\n                except Exception as e:\n                    pass\n',
        ],
        "            elif form_data.auth_type == 'system_oauth':\n                oauth_token = await get_request_oauth_token(request, user)\n                if oauth_token:\n                    token = oauth_token.get('access_token', '')\n",
        "system oauth token fallback for OpenAPI configs",
    )
    path.write_text(patched, encoding="utf-8")


def patch_auths_router(path: Path) -> None:
    original = path.read_text(encoding="utf-8")
    patched = replace_one_of_or_keep(
        original,
        [
            "    auth_header = request.headers.get('Authorization')\n    auth_token = get_http_authorization_cred(auth_header)\n    token = auth_token.credentials\n",
            '    auth_header = request.headers.get("Authorization")\n    auth_token = get_http_authorization_cred(auth_header)\n    token = auth_token.credentials\n',
        ],
        "    auth_header = request.headers.get('Authorization')\n"
        "    auth_token = get_http_authorization_cred(auth_header) if auth_header else None\n"
        "    token = auth_token.credentials if auth_token else request.cookies.get('token')\n"
        "\n"
        "    if not token:\n"
        "        raise HTTPException(\n"
        "            status_code=status.HTTP_401_UNAUTHORIZED,\n"
        "            detail=ERROR_MESSAGES.INVALID_TOKEN,\n"
        "        )\n",
        "cookie-aware auth session token lookup",
    )
    path.write_text(patched, encoding="utf-8")


def patch_images_router(path: Path) -> None:
    original = path.read_text(encoding="utf-8")
    patched = insert_after_one_of(
        original,
        ["from open_webui.internal.db import get_session\n"],
        "from open_webui.dropzone_images import (\n"
        "    generate_chutes_images,\n"
        "    get_chutes_image_model,\n"
        "    get_chutes_image_models,\n"
        "    is_chutes_image_backend,\n"
        ")\n",
        "dropzone images import",
    )
    patched = replace_one_of_or_keep(
        patched,
        [
            "        if request.app.state.config.IMAGE_GENERATION_ENGINE == 'openai':\n            return [\n                {'id': 'dall-e-2', 'name': 'DALL·E 2'},\n                {'id': 'dall-e-3', 'name': 'DALL·E 3'},\n                {'id': 'gpt-image-1', 'name': 'GPT-IMAGE 1'},\n                {'id': 'gpt-image-1.5', 'name': 'GPT-IMAGE 1.5'},\n            ]\n",
            '        if request.app.state.config.IMAGE_GENERATION_ENGINE == "openai":\n            return [\n                {"id": "dall-e-2", "name": "DALL·E 2"},\n                {"id": "dall-e-3", "name": "DALL·E 3"},\n                {"id": "gpt-image-1", "name": "GPT-IMAGE 1"},\n                {"id": "gpt-image-1.5", "name": "GPT-IMAGE 1.5"},\n            ]\n',
        ],
        "        if request.app.state.config.IMAGE_GENERATION_ENGINE == 'openai':\n"
        "            if is_chutes_image_backend(request):\n"
        "                return get_chutes_image_models(user)\n"
        "            return [\n"
        "                {'id': 'dall-e-2', 'name': 'DALL·E 2'},\n"
        "                {'id': 'dall-e-3', 'name': 'DALL·E 3'},\n"
        "                {'id': 'gpt-image-1', 'name': 'GPT-IMAGE 1'},\n"
        "                {'id': 'gpt-image-1.5', 'name': 'GPT-IMAGE 1.5'},\n"
        "            ]\n",
        "dropzone image models branch",
    )
    patched = replace_one_of_or_keep(
        patched,
        [
            "    model = get_image_model(request)\n",
            '    model = get_image_model(request)\n',
        ],
        "    model = get_chutes_image_model(request, form_data) if is_chutes_image_backend(request) else get_image_model(request)\n",
        "dropzone effective image model",
    )
    patched = replace_one_of_or_keep(
        patched,
        [
            "        if request.app.state.config.IMAGE_GENERATION_ENGINE == 'openai':\n            headers = {\n                'Authorization': f'Bearer {request.app.state.config.IMAGES_OPENAI_API_KEY}',\n                'Content-Type': 'application/json',\n            }\n",
            '        if request.app.state.config.IMAGE_GENERATION_ENGINE == "openai":\n            headers = {\n                "Authorization": f"Bearer {request.app.state.config.IMAGES_OPENAI_API_KEY}",\n                "Content-Type": "application/json",\n            }\n',
        ],
        "        if request.app.state.config.IMAGE_GENERATION_ENGINE == 'openai':\n"
        "            if is_chutes_image_backend(request):\n"
        "                generated_images, selected_model = await generate_chutes_images(\n"
        "                    request=request,\n"
        "                    form_data=form_data,\n"
        "                    user=user,\n"
        "                )\n"
        "\n"
        "                images = []\n"
        "                upload_metadata = {\n"
        "                    'model': selected_model['id'],\n"
        "                    'prompt': form_data.prompt,\n"
        "                    'n': form_data.n,\n"
        "                    **({'size': form_data.size} if form_data.size else {}),\n"
        "                    **({'steps': form_data.steps} if form_data.steps else {}),\n"
        "                    **({'negative_prompt': form_data.negative_prompt} if form_data.negative_prompt else {}),\n"
        "                    **metadata,\n"
        "                }\n"
        "\n"
        "                for image_data, content_type in generated_images:\n"
        "                    _, url = upload_image(request, image_data, content_type, upload_metadata, user)\n"
        "                    images.append({'url': url})\n"
        "                return images\n"
        "\n"
        "            headers = {\n"
        "                'Authorization': f'Bearer {request.app.state.config.IMAGES_OPENAI_API_KEY}',\n"
        "                'Content-Type': 'application/json',\n"
        "            }\n",
        "dropzone chutes image generation branch",
    )
    path.write_text(patched, encoding="utf-8")


def main() -> int:
    if len(sys.argv) != 2:
        raise SystemExit("usage: patch-openwebui-runtime.py <openwebui-root>")

    root = Path(sys.argv[1])
    patch_env(root / "backend" / "open_webui" / "env.py")
    patch_config_module(root / "backend" / "open_webui" / "config.py")
    patch_main(root / "backend" / "open_webui" / "main.py")
    patch_openai_router(root / "backend" / "open_webui" / "routers" / "openai.py")
    patch_functions(root / "backend" / "open_webui" / "functions.py")
    patch_middleware(root / "backend" / "open_webui" / "utils" / "middleware.py")
    patch_utils_oauth(root / "backend" / "open_webui" / "utils" / "oauth.py")
    patch_configs(root / "backend" / "open_webui" / "routers" / "configs.py")
    patch_auths_router(root / "backend" / "open_webui" / "routers" / "auths.py")
    patch_images_router(root / "backend" / "open_webui" / "routers" / "images.py")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
