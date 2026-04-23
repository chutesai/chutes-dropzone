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
    patched = replace_one_of_or_keep(
        patched,
        [
            "async def get_system_oauth_token(request, user):\n    oauth_token = None\n    try:\n        if request.cookies.get('oauth_session_id', None):\n            oauth_token = await request.app.state.oauth_manager.get_oauth_token(\n                user.id,\n                request.cookies.get('oauth_session_id', None),\n            )\n    except Exception as e:\n        log.error(f'Error getting OAuth token: {e}')\n    return oauth_token\n",
            'async def get_system_oauth_token(request, user):\n    oauth_token = None\n    try:\n        if request.cookies.get("oauth_session_id", None):\n            oauth_token = await request.app.state.oauth_manager.get_oauth_token(\n                user.id,\n                request.cookies.get("oauth_session_id", None),\n            )\n    except Exception as e:\n        log.error(f"Error getting OAuth token: {e}")\n    return oauth_token\n',
        ],
        "async def get_system_oauth_token(request, user):\n    return await get_request_oauth_token(request, user)\n",
        "system oauth token fallback for middleware",
    )
    patched = replace_all_of_or_keep(
        patched,
        [
            "            system_message_content = '<context>The requested image has been edited and created and is now being shown to the user. Let them know that it has been generated.</context>'\n",
            "            system_message_content = '<context>The requested image has been created by the system successfully and is now being shown to the user. Let the user know that the image they requested has been generated and is now shown in the chat.</context>'\n",
        ],
        "            metadata['_dropzone_response_override'] = {'choices': [{'message': {'content': ''}}]}\n",
        "dropzone image success override",
    )
    patched = replace_all_of_or_keep(
        patched,
        [
            "            system_message_content = f'<context>Image generation was attempted but failed. The system is currently unable to generate the image. Tell the user that the following error occurred: {error_message}</context>'\n",
            "            system_message_content = f'<context>Image generation was attempted but failed because of an error. The system is currently unable to generate the image. Tell the user that the following error occurred: {error_message}</context>'\n",
        ],
        "            metadata['_dropzone_response_override'] = {\n                'choices': [\n                    {\n                        'message': {\n                            'content': f'Image generation failed: {error_message or \"Unknown error\"}'\n                        }\n                    }\n                ]\n            }\n",
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
