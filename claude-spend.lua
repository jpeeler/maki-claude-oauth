local oauth = require("claude-oauth")

local M = {}

M.STATE_FILE = maki.fs.joinpath(maki.env.config_dir(), "claude-spend-state.json")
local URL = "https://api.anthropic.com/api/oauth/usage"
local TIMEOUT = 20
local MIN_INTERVAL = 300
local BACKOFF_MAX = 3600

function M.load_state()
  local raw = maki.fs.read(M.STATE_FILE)
  if not raw then return {} end
  local ok, state = pcall(maki.json.decode, raw)
  if not ok or type(state) ~= "table" then return {} end
  return state
end

local function save_state(state)
  local ok, err = pcall(maki.fs.atomic_write, M.STATE_FILE, maki.json.encode(state))
  if not ok then maki.log.warn("claude-spend: saving state failed: " .. tostring(err)) end
end

local function fail(state, reason, retry_after)
  local backoff = math.min(math.max((state.backoff or 0) * 2, MIN_INTERVAL), BACKOFF_MAX)
  if retry_after then
    backoff = math.min(math.max(backoff, retry_after), BACKOFF_MAX)
  end
  state.backoff = backoff
  state.next_at = os.time() + backoff
  state.last_error = reason
  save_state(state)
  return state
end

local function money(part)
  if type(part) ~= "table" or part.amount_minor == nil then return nil end
  return part.amount_minor / (10 ^ (part.exponent or 2))
end

function M.fetch()
  local state = M.load_state()
  if os.time() < (state.next_at or 0) then return state end

  local ok, auth = pcall(oauth.auth, { slug = "claude-oauth" }, "resolve")
  if not ok then
    maki.log.warn("claude-spend: auth failed: " .. tostring(auth))
    return fail(state, "auth")
  end
  if not auth or type(auth.headers) ~= "table" then return fail(state, "auth") end

  local res, err = maki.net.request(URL, { headers = auth.headers, timeout = TIMEOUT, retry = 0 })
  if not res then
    maki.log.warn("claude-spend: request failed: " .. tostring(err))
    return state
  end

  if res.status == 429 then
    return fail(state, "ratelimit", tonumber(res.headers and res.headers["retry-after"]))
  end
  if res.status == 401 or res.status == 403 then return fail(state, "auth") end
  if res.status ~= 200 then return fail(state, "http") end

  local parsed, data = pcall(maki.json.decode, res.body)
  if not parsed or type(data) ~= "table" then return fail(state, "parse") end
  local spend = type(data.spend) == "table" and data.spend or {}

  local used = money(spend.used)
  if used == nil then return fail(state, "nodata") end

  local now = os.time()
  state.last = {
    used = used,
    limit = money(spend.limit),
    pct = spend.percent,
    severity = spend.severity or "normal",
    age = 0,
  }
  state.last_at = now
  state.backoff = 0
  state.next_at = now + MIN_INTERVAL
  state.last_error = nil
  save_state(state)
  return state
end

return M
