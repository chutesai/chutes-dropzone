--
-- model_catalog.lua - Public model catalog passthrough with strict TEE filtering
--
-- The Chutes public /v1/models endpoint is intentionally queried without
-- end-user credentials. In strict e2ee-proxy mode we filter the catalog down to
-- confidential-compute models so UIs only present TEE-capable options.
--

local cjson = require("cjson.safe")
local http = require("resty.http")

local _M = {}

local MODELS_BASE = os.getenv("CHUTES_MODELS_BASE") or "https://llm.chutes.ai"
local allow_non_confidential = os.getenv("ALLOW_NON_CONFIDENTIAL") == "true"

local function set_proxy_headers()
    ngx.header["Access-Control-Allow-Origin"] = "*"
    ngx.header["Access-Control-Allow-Methods"] = "GET, HEAD, OPTIONS"
    ngx.header["Access-Control-Allow-Headers"] = "*"
    ngx.header["Access-Control-Expose-Headers"] = "*"
    ngx.header["Cache-Control"] = "no-store"
    ngx.header["X-Dropzone-Proxy"] = "e2ee-proxy"
    ngx.header["X-Dropzone-Model-Catalog"] =
        allow_non_confidential and "allow-non-tee" or "tee-only"
end

local function send_json(status, payload)
    local encoded = cjson.encode(payload or {})
    if not encoded then
        encoded = '{"error":{"message":"failed to encode model catalog response"}}'
    end

    ngx.status = status
    ngx.header["Content-Type"] = "application/json"
    set_proxy_headers()

    if ngx.req.get_method() == "HEAD" then
        return ngx.exit(status)
    end

    ngx.print(encoded)
    return ngx.exit(status)
end

function _M.handle()
    local method = ngx.req.get_method()
    if method ~= "GET" and method ~= "HEAD" then
        return send_json(405, {
            error = {
                message = "model catalog only supports GET and HEAD",
                type = "proxy_error",
            },
        })
    end

    local httpc = http.new()
    httpc:set_timeout(10000)

    local res, err = httpc:request_uri(MODELS_BASE .. "/v1/models", {
        method = "GET",
        headers = {
            ["Accept"] = "application/json",
        },
        ssl_verify = true,
    })

    if not res then
        return send_json(502, {
            error = {
                message = "model catalog request failed: " .. (err or "unknown"),
                type = "proxy_error",
            },
        })
    end

    set_proxy_headers()
    ngx.status = res.status
    ngx.header["Content-Type"] = res.headers["Content-Type"] or "application/json"

    if method == "HEAD" then
        return ngx.exit(res.status)
    end

    if res.status ~= 200 then
        ngx.print(res.body or "")
        return ngx.exit(res.status)
    end

    local payload = cjson.decode(res.body)
    if type(payload) ~= "table" then
        return send_json(502, {
            error = {
                message = "invalid model catalog response",
                type = "proxy_error",
            },
        })
    end

    if not allow_non_confidential and type(payload.data) == "table" then
        local filtered = {}
        for _, model in ipairs(payload.data) do
            if type(model) == "table" and model.confidential_compute == true then
                table.insert(filtered, model)
            end
        end
        payload.data = filtered
        if type(payload.total) == "number" then
            payload.total = #filtered
        end
    end

    local encoded = cjson.encode(payload)
    if not encoded then
        return send_json(502, {
            error = {
                message = "failed to encode filtered model catalog",
                type = "proxy_error",
            },
        })
    end

    ngx.print(encoded)
    return ngx.exit(res.status)
end

return _M
