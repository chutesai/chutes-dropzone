--
-- e2ee_discovery.lua - Model resolution and nonce management
--
-- Mirrors the Python transport's DiscoveryManager:
--   - resolve_chute_id(model) -> chute_id
--   - get_nonce(chute_id)     -> instance_info, nonce
--
-- This local overlay intentionally resolves the mega-LLM /v1/models catalog
-- anonymously first. That endpoint is public in Chutes, and sending end-user
-- credentials there can fail for valid API-key and SSO-backed flows.
--

local http = require("resty.http")
local cjson = require("cjson.safe")

local _M = {}

local model_map = nil
local model_map_expires = 0
local MODEL_MAP_TTL = 300

local nonce_cache = {}

local API_BASE = "https://api.chutes.ai"
local MODELS_BASE = "https://llm.chutes.ai"

function _M.set_api_base(base)
    API_BASE = base
end

function _M.set_models_base(base)
    MODELS_BASE = base
end

local function is_uuid(s)
    if not s or #s ~= 36 then return false end
    return s:match("^%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$") ~= nil
end

local function request_model_list(headers)
    local httpc = http.new()
    httpc:set_timeout(10000)

    return httpc:request_uri(MODELS_BASE .. "/v1/models", {
        method = "GET",
        headers = headers,
        ssl_verify = true,
    })
end

local function decode_model_map(body)
    local data = cjson.decode(body)
    if not data or not data.data then
        return nil, "invalid model list response"
    end

    local map = {}
    for _, model in ipairs(data.data) do
        if model.id and model.chute_id then
            map[model.id] = {
                chute_id = model.chute_id,
                confidential = model.confidential_compute == true,
            }
        end
    end

    return map
end

local function fetch_model_map(api_key)
    local res, err = request_model_list(nil)

    if not res and api_key and api_key ~= "" then
        ngx.log(ngx.WARN, "public model list request failed, retrying authenticated request: ", err or "unknown")
        res, err = request_model_list({
            ["Authorization"] = "Bearer " .. api_key,
        })
    end

    if not res then
        return nil, "model list request failed: " .. (err or "unknown")
    end

    if res.status ~= 200 then
        return nil, "model list returned " .. res.status
    end

    return decode_model_map(res.body)
end

local allow_non_confidential = os.getenv("ALLOW_NON_CONFIDENTIAL") == "true"

local function check_confidential(model, entry)
    if not entry then return nil, "model '" .. model .. "' not found" end
    if not entry.confidential and not allow_non_confidential then
        return nil, "model '" .. model .. "' is not running in confidential compute (TEE). "
            .. "E2EE requires confidential compute to guarantee privacy. "
            .. "Set ALLOW_NON_CONFIDENTIAL=true to override."
    end
    return entry.chute_id
end

function _M.resolve_chute_id(model, api_key)
    if is_uuid(model) then
        return model
    end

    local now = ngx.now()

    if model_map and now < model_map_expires then
        local entry = model_map[model]
        if entry then
            return check_confidential(model, entry)
        end
    end

    local map, err = fetch_model_map(api_key)
    if not map then
        if model_map then
            local entry = model_map[model]
            if entry then
                return check_confidential(model, entry)
            end
        end
        return nil, "failed to resolve model '" .. model .. "': " .. (err or "unknown")
    end

    model_map = map
    model_map_expires = now + MODEL_MAP_TTL

    local entry = map[model]
    return check_confidential(model, entry)
end

local function fetch_instances(chute_id, api_key)
    local httpc = http.new()
    httpc:set_timeout(30000)

    local url = API_BASE .. "/e2e/instances/" .. chute_id
    local res, err = httpc:request_uri(url, {
        method = "GET",
        headers = {
            ["Authorization"] = "Bearer " .. api_key,
            ["Cache-Control"] = "no-cache, no-store",
        },
        ssl_verify = true,
    })

    if not res then
        return nil, "instance discovery failed: " .. (err or "unknown")
    end

    if res.status ~= 200 then
        return nil, "instance discovery returned " .. res.status .. ": " .. (res.body or "")
    end

    local data = cjson.decode(res.body)
    if not data or not data.instances then
        return nil, "invalid instance discovery response: " .. (res.body or ""):sub(1, 200)
    end

    local nonce_ttl = data.nonce_expires_in or 55
    local expires_at = ngx.now() + nonce_ttl

    local total_nonces = 0
    for _, inst in ipairs(data.instances) do
        if inst.nonces then
            total_nonces = total_nonces + #inst.nonces
            ngx.log(ngx.INFO, "  instance=", inst.instance_id,
                    " nonces=", #inst.nonces,
                    " first_nonce_prefix=", inst.nonces[1] and inst.nonces[1]:sub(1, 8) or "nil",
                    " pubkey_len=", inst.e2e_pubkey and #inst.e2e_pubkey or 0)
        end
    end
    ngx.log(ngx.INFO, "fetched ", #data.instances, " instances with ",
            total_nonces, " nonces (TTL=", nonce_ttl, "s) for chute ", chute_id)

    return {
        instances = data.instances,
        expires_at = expires_at,
    }
end

local function take_nonce(chute_id)
    local cached = nonce_cache[chute_id]
    if not cached then return nil end
    if ngx.now() >= cached.expires_at then
        nonce_cache[chute_id] = nil
        return nil
    end

    for _, inst in ipairs(cached.instances) do
        if inst.nonces and #inst.nonces > 0 then
            local nonce = table.remove(inst.nonces, 1)
            ngx.log(ngx.INFO, "take_nonce: instance=", inst.instance_id,
                    " nonce_prefix=", nonce:sub(1, 12),
                    " remaining=", #inst.nonces)
            return {
                instance_id = inst.instance_id,
                e2e_pubkey = inst.e2e_pubkey,
            }, nonce
        end
    end

    nonce_cache[chute_id] = nil
    return nil
end

function _M.invalidate_nonces(chute_id)
    nonce_cache[chute_id] = nil
end

function _M.get_nonce(chute_id, api_key)
    local inst, nonce = take_nonce(chute_id)
    if inst then
        return inst, nonce
    end

    local cached, err = fetch_instances(chute_id, api_key)
    if not cached then
        return nil, nil, err
    end

    nonce_cache[chute_id] = cached

    inst, nonce = take_nonce(chute_id)
    if not inst then
        return nil, nil, "no nonces available for chute " .. chute_id
    end

    return inst, nonce
end

return _M
