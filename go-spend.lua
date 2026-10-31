local M = {}

M.STATE_FILE = maki.fs.joinpath(maki.env.config_dir(), "go-spend-state.json")
M.AUTH_FILE = maki.fs.joinpath(maki.env.state_dir(), "auth", "opencode-go.json")
local URL = "https://opencode.ai/zen/go/v1/usage"
local TIMEOUT = 20
local MIN_INTERVAL = 300
local BACKOFF_MAX = 3600
local WINDOWS = { "rolling", "weekly", "monthly" }

local function load_state()
  local raw = maki.fs.read(M.STATE_FILE)
  if not raw then return {} end
  local ok, state = pcall(maki.json.decode, raw)
  if not ok or type(state) ~= "table" then return {} end
  return state
end

local function save_state(state)
  local ok, err = pcall(maki.fs.atomic_write, M.STATE_FILE, maki.json.encode(state))
  if not ok then maki.log.warn("go-spend: saving state failed: " .. tostring(err)) end
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

local function status_severity(status)
  if type(status) ~= "string" or status == "ok" then return "normal" end
  local plain = status:gsub("[^%a]", ""):lower()
  if plain:find("rate", 1, true) or plain:find("block", 1, true) then return "critical" end
  return "warning"
end

local function resets_at_secs(iso)
  if type(iso) ~= "string" then return nil end
  local y, mo, d, h, mi, s = iso:match("^(%d%d%d%d)-(%d%d)-(%d%d)T(%d%d):(%d%d):(%d%d)")
  if not y then return nil end
  local frag = os.date("!*t", os.time())
  frag.year, frag.month, frag.day = tonumber(y), tonumber(mo), tonumber(d)
  frag.hour, frag.min, frag.sec, frag.isdst = tonumber(h), tonumber(mi), tonumber(s), false
  local tz = os.time(os.date("*t")) - os.time(os.date("!*t"))
  return os.time(frag) - tz
end

function M.fetch()
  local state = load_state()
  if os.time() < (state.next_at or 0) then return state end

  local raw = maki.fs.read(M.AUTH_FILE)
  if not raw then return fail(state, "auth") end
  local ok, stored = pcall(maki.json.decode, raw)
  if not ok or type(stored) ~= "table" or type(stored.api_key) ~= "string" then
    return fail(state, "auth")
  end

  local res, err = maki.net.request(URL, {
    headers = { Authorization = "Bearer " .. stored.api_key },
    timeout = TIMEOUT,
    retry = 0,
  })
  if not res then
    maki.log.warn("go-spend: request failed: " .. tostring(err))
    return state
  end

  if res.status == 429 then
    return fail(state, "ratelimit", tonumber(res.headers and res.headers["retry-after"]))
  end
  if res.status == 401 or res.status == 403 then return fail(state, "auth") end
  if res.status ~= 200 then return fail(state, "http") end

  local decoded, data = pcall(maki.json.decode, res.body)
  if not decoded or type(data) ~= "table" or type(data.usage) ~= "table" then
    return fail(state, "parse")
  end

  local usage = data.usage
  local chosen, upgrade = nil, nil
  for _, name in ipairs(WINDOWS) do
    local w = usage[name]
    if type(w) == "table" and type(w.percent) == "number" then
      if not chosen or w.percent > chosen.pct then
        chosen = { win = name, pct = w.percent, resets_in = resets_at_secs(w.resetsAt) }
      end
      local sev = status_severity(w.status)
      if sev == "critical" or (sev == "warning" and upgrade ~= "critical") then
        upgrade = sev
      end
    end
  end
  if not chosen then return fail(state, "nodata") end
  if upgrade == "critical" then
    for _, name in ipairs(WINDOWS) do
      local w = usage[name]
      if type(w) == "table" and status_severity(w.status) == "critical" then
        chosen = { win = name, pct = w.percent, resets_in = resets_at_secs(w.resetsAt) }
      end
    end
    chosen.severity = "critical"
  elseif upgrade then
    chosen.severity = "warning"
  else
    chosen.severity = "normal"
  end

  local now = os.time()
  state.last = chosen
  state.last_at = now
  state.backoff = 0
  state.next_at = now + MIN_INTERVAL
  state.last_error = nil
  save_state(state)
  return state
end

return M
