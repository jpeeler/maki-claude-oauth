local GLOBAL_INSTRUCTIONS = [[
- 1) Jeff does not want AI-introduced comments in the code, unless instructions specifically ask for it. If comments do get added, remove and resubmit. Rationale for the change belongs in the commit message (or PR), not inline. Pre-existing comments are fine, just don't add net-new ones.
- 2) Any time there is a sandbox denial, pause instead of trying to work around the error and wait for permissions. Jeff will likely restart with missing permissions added to whatever is lacking.
- 3) Do not do git pushes without permission.
- 4) When making corrections to current work in a branch, ask whether to use `git history fixup` or to commit on top.
- 5) When responding to Github comments on behalf of Jeff (only do so with permission), prefix every response with '🤖'.
- 6) Unless there's a good reason to not pull in additional testing dependencies, ginkgo should be used for all Go tests.
- 7) Do not append "Bumble Confidential. For Internal Use Only." to correspondence on my behalf (GitHub comments, PR replies, messages) or to any content intended for public posting, where it would leak affiliation.
- 8) If modifying a PR description on Github and there is a divider at the top, then leave that as protected text that only Jeff can edit. You may edit anything below that line.
]]

maki.api.register_prompt_hint({
  slot = "conventions",
  content = GLOBAL_INSTRUCTIONS,
})

local nono_span = { "[NONO]", "error" }
local spend_span = nil
local net_blocked = false

local function render_status_hint()
  local spans = { nono_span, { " ", "" } }
  if spend_span then
    spans[#spans + 1] = spend_span
    spans[#spans + 1] = { " ", "" }
  end
  maki.ui.set_status_hint(spans)
end

local function nono_status_hint()
  local cap_file = maki.uv.os_getenv("NONO_CAP_FILE")
  net_blocked = false
  if not cap_file or cap_file == "" then
    nono_span = { "[NONO]", "error" }
    render_status_hint()
    return
  end

  local label = "[NONO]"
  local raw = maki.fs.read(cap_file)
  if raw then
    local caps = maki.json.decode(raw)
    if type(caps) == "table" and caps.net_blocked then
      label = "nono, no net"
      net_blocked = true
    end
  end

  nono_span = { label, "success" }
  render_status_hint()
end

nono_status_hint()

maki.api.create_autocmd({ "SessionReset", "SessionFocusChanged" }, {
  callback = nono_status_hint,
})

-- Bumble Confidential. For Internal Use Only.
local spend = require("claude-spend")
local SPEND_STATE = spend.STATE_FILE
local SPEND_POLL_SECS = 30
local WARN_STYLE = maki.ui.theme_color("warning") and "warning" or "error"

local function spend_style(report)
  if report.stale then
    return "dim"
  elseif report.severity == "critical" or (report.pct or 0) >= 90 then
    return "error"
  elseif report.severity == "warning" or (report.pct or 0) >= 75 then
    return WARN_STYLE
  end
  return "dim"
end

local function spend_age(secs)
  if type(secs) ~= "number" or secs < 0 then
    return nil
  elseif secs < 60 then
    return string.format("%ds", math.floor(secs))
  elseif secs < 3600 then
    return string.format("%dm", math.floor(secs / 60))
  elseif secs < 86400 then
    return string.format("%dh", math.floor(secs / 3600))
  end
  return string.format("%dd", math.floor(secs / 86400))
end

local function read_spend_state()
  local raw = maki.fs.read(SPEND_STATE)
  if not raw then
    return nil
  end
  local ok, state = pcall(maki.json.decode, raw)
  if not ok or type(state) ~= "table" then
    return nil
  end
  return state
end

local function render_spend(report)
  if not report.used then
    spend_span = { string.format("[spend: %s]", report.error or "?"), "dim" }
    render_status_hint()
    return
  end

  local text = string.format("$%.2f", report.used)
  if report.pct then
    text = string.format("%s (%d%%)", text, report.pct)
  end
  if report.stale then
    text = "~" .. text
  end
  local age = spend_age(report.age)
  if age then
    text = text .. " " .. age .. " ago"
  end

  spend_span = { text, spend_style(report) }
  render_status_hint()
end

local function render_spend_state(state)
  if not state then
    return
  end
  local last = state.last
  if type(last) ~= "table" or last.used == nil then
    if state.last_error then
      render_spend({ error = state.last_error })
    end
    return
  end
  local report = {}
  for k, v in pairs(last) do
    report[k] = v
  end
  if type(state.last_at) == "number" then
    report.age = math.max(0, os.time() - state.last_at)
  end
  if state.last_error then
    report.stale = true
    report.error = state.last_error
  end
  render_spend(report)
end

local spend_fetching = false

local function refresh_spend()
  local state = read_spend_state()
  render_spend_state(state)
  if spend_fetching or net_blocked then
    return
  end
  if os.time() < ((state and state.next_at) or 0) then
    return
  end
  spend_fetching = true
  maki.async.spawn(function()
    local ok, err = pcall(spend.fetch)
    spend_fetching = false
    if not ok then
      maki.log.warn("claude-spend: " .. tostring(err))
    end
    render_spend_state(read_spend_state())
  end)
end

maki.async.spawn(function()
  while true do
    refresh_spend()
    maki.async.sleep(SPEND_POLL_SECS * 1000)
  end
end)

maki.api.create_autocmd("TurnEnd", { callback = refresh_spend })

local function require_with_renamed_commands(module, renames)
  local original = maki.api.register_command
  maki.api.register_command = function(spec)
    local from = spec.name
    if from and from:sub(1, 1) ~= "/" then
      from = "/" .. from
    end
    local to = renames[from]
    if to then
      spec.name = to
    end
    return original(spec)
  end
  local ok, err = pcall(require, module)
  maki.api.register_command = original
  if not ok then
    error(err, 0)
  end
end

require_with_renamed_commands("review", { ["/review"] = "/diff" })

require("claude-oauth")

require("program-status").setup()
