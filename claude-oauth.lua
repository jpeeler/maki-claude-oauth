local M = {}
local CLIENT_ID = maki.uv.os_getenv("CLAUDE_CODE_OAUTH_CLIENT_ID") or "9d1c250a-e61b-44d9-88ed-5944d1962f5e"

local function read_json(path)
  local raw = maki.fs.read(maki.fs.normalize(path))
  if not raw then return nil end
  local ok, data = pcall(maki.json.decode, raw)
  if ok and type(data) == "table" then return data end
end

function M.command(argv, timeout)
  local id, err = maki.fn.jobstart(argv, { tail = 100 })
  if not id then error(err) end
  local result, wait_err = maki.fn.jobwait(id, timeout or 10000)
  if not result then
    maki.fn.jobstop(id)
    error(wait_err)
  end
  return result
end

local function code_tokens()
  local data = read_json("~/.claude/.credentials.json")
  if not data and maki.fn.executable("security") == 1 then
    local result = M.command({ "security", "find-generic-password", "-s", "Claude Code-credentials", "-w" })
    if result.exit_code == 0 and result.stdout ~= "" then
      local ok, value = pcall(maki.json.decode, result.stdout)
      if ok then data = value end
    end
  end
  local oauth = data and data.claudeAiOauth
  if not oauth or not oauth.accessToken then return nil end
  return {
    access = oauth.accessToken, refresh = oauth.refreshToken,
    expires = oauth.expiresAt or 0, scopes = oauth.scopes or { "user:inference" },
    client_id = oauth.clientId or CLIENT_ID,
  }
end

local function save(ctx, tokens)
  local ok, err = maki.provider.auth.set(ctx.slug, tokens)
  if not ok then error(err) end
  return tokens
end

local function stored(ctx)
  local tokens, err = maki.provider.auth.get(ctx.slug)
  if err then error(err) end
  if tokens then return tokens end
  tokens = read_json("~/.config/maki/claude-oauth-token.json")
  if tokens and tokens.access then return save(ctx, tokens) end
end

local function expired(tokens)
  return not tokens or os.time() * 1000 + 300000 >= (tokens.expires or 0)
end

local function contract_headers()
  return {
    ["User-Agent"] = "claude-cli/2.1.251",
    ["anthropic-beta"] = "oauth-2025-04-20,claude-code-20250219",
  }
end

local function encode(value)
  return tostring(value):gsub("([^%w%-%._~])", function(c) return string.format("%%%02X", string.byte(c)) end)
end

local function refresh(ctx, tokens)
  local fields = {
    "grant_type=refresh_token", "refresh_token=" .. encode(tokens.refresh),
  }
  if tokens.client_id then fields[#fields + 1] = "client_id=" .. encode(tokens.client_id) end
  local headers = contract_headers()
  headers["Content-Type"] = "application/x-www-form-urlencoded"
  local res, err = maki.net.request("https://platform.claude.com/v1/oauth/token", {
    method = "POST", headers = headers, body = table.concat(fields, "&"), timeout = 15, retry = 0,
  })
  if not res then error(err) end
  if res.status < 200 or res.status >= 300 then return nil, maki.provider.http_error(res) end
  local data = maki.json.decode(res.body)
  if not data.access_token then error("OAuth refresh returned no access token") end
  return save(ctx, {
    access = data.access_token, refresh = data.refresh_token or tokens.refresh,
    expires = os.time() * 1000 + (data.expires_in or 3600) * 1000,
    scopes = tokens.scopes or { "user:inference" }, client_id = tokens.client_id,
  })
end

function M.tokens(ctx, purpose)
  local own = stored(ctx)
  if own and own.logged_out then error("Run: maki auth login " .. ctx.slug) end
  local code = code_tokens()
  if purpose ~= "refresh" then
    if code and not expired(code) then return save(ctx, code) end
    if own and not expired(own) then return own end
  end
  local candidates = {}
  if code and code.refresh then candidates[#candidates + 1] = code end
  if own and own.refresh then candidates[#candidates + 1] = own end
  table.sort(candidates, function(a, b) return (a.expires or 0) > (b.expires or 0) end)
  local seen, last_error = {}, nil
  for _, tokens in ipairs(candidates) do
    if not seen[tokens.refresh] then
      seen[tokens.refresh] = true
      local renewed, err = refresh(ctx, tokens)
      if renewed then return renewed end
      last_error = err
    end
  end
  if last_error then return nil, last_error end
  error("No Claude OAuth credentials; run: maki auth login " .. ctx.slug .. " (or claude auth login)")
end

function M.auth(ctx, purpose)
  local tokens, err = M.tokens(ctx, purpose)
  if not tokens then return nil, err end
  local headers = contract_headers()
  headers.Authorization = "Bearer " .. tokens.access
  local base = maki.uv.os_getenv("CLAUDE_OAUTH_BASE_URL") or "https://api.anthropic.com"
  return { base_url = base:gsub("/+$", "") .. "/v1/messages?beta=true", headers = headers }
end

local function login(ctx)
  local tokens = code_tokens()
  if tokens and not expired(tokens) then
    save(ctx, tokens)
    ctx.print("Authenticated via existing Claude Code session.")
    return
  end
  if tokens and tokens.refresh then
    local renewed = refresh(ctx, tokens)
    if renewed then
      ctx.print("Authenticated via token refresh.")
      return
    end
  end
  ctx.print("Please run: claude auth login")
  error("Then re-run: maki auth login " .. ctx.slug)
end

maki.provider.register({
  slug = "claude-oauth",
  display_name = "Claude OAuth",
  base = "anthropic",
  system_prefix = "You are Claude Code, Anthropic's official CLI for Claude.",
  models = {
    { prefixes = { "claude-fable-5-1" }, tier = "strong", context_window = 1000000, max_output_tokens = 128000, pricing = { input = 10.0, output = 50.0, cache_write = 12.5, cache_read = 0.25 } },
    { prefixes = { "claude-fable-5" }, tier = "strong", context_window = 1000000, max_output_tokens = 128000, pricing = { input = 10.0, output = 50.0, cache_write = 12.5, cache_read = 1.0 } },
    { prefixes = { "claude-opus-5-5" }, tier = "strong", context_window = 1000000, max_output_tokens = 128000, pricing = { input = 4.0, output = 20.0, cache_write = 5.0, cache_read = 0.2 } },
    { prefixes = { "claude-opus-5" }, tier = "strong", context_window = 1000000, max_output_tokens = 128000, pricing = { input = 5.0, output = 25.0, cache_write = 6.25, cache_read = 0.5 } },
    { prefixes = { "claude-opus-4-8" }, tier = "strong", context_window = 200000, max_output_tokens = 32000, pricing = { input = 15.0, output = 75.0, cache_write = 18.75, cache_read = 1.5 } },
    { prefixes = { "claude-opus-4-7" }, tier = "strong", context_window = 200000, max_output_tokens = 32000, pricing = { input = 15.0, output = 75.0, cache_write = 18.75, cache_read = 1.5 } },
    { prefixes = { "claude-opus-4-6" }, tier = "strong", context_window = 1000000, max_output_tokens = 128000, pricing = { input = 5.0, output = 25.0, cache_write = 6.25, cache_read = 0.5 } },
    { prefixes = { "claude-opus-4-5" }, tier = "strong", context_window = 200000, max_output_tokens = 64000, pricing = { input = 5.0, output = 25.0, cache_write = 6.25, cache_read = 0.5 } },
    { prefixes = { "claude-sonnet-5" }, tier = "medium", context_window = 1000000, max_output_tokens = 128000, pricing = { input = 2.0, output = 10.0, cache_write = 2.5, cache_read = 0.2 } },
    { prefixes = { "claude-sonnet-4-6" }, tier = "medium", context_window = 1000000, max_output_tokens = 128000, pricing = { input = 3.0, output = 15.0, cache_write = 3.75, cache_read = 0.3 } },
    { prefixes = { "claude-sonnet-4-5" }, tier = "medium", context_window = 1000000, max_output_tokens = 64000, pricing = { input = 3.0, output = 15.0, cache_write = 3.75, cache_read = 0.3 } },
    { prefixes = { "claude-haiku-4-5" }, tier = "weak", context_window = 200000, max_output_tokens = 64000, pricing = { input = 1.0, output = 5.0, cache_write = 1.25, cache_read = 0.1 } },
  },
  auth = M.auth,
  login = login,
  logout = function(ctx)
    local ok, err = maki.provider.auth.clear(ctx.slug)
    if not ok then error(err) end
  end,
})

return M
