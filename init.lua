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

local spend = require("claude-spend")
local go_spend = require("go-spend")
local SPEND_POLL_SECS = 30
local WARN_STYLE = maki.ui.theme_color("warning") and "warning" or "error"

local SOURCES = {
  claude = { state_file = spend.STATE_FILE, fetch = spend.fetch },
  go = { state_file = go_spend.STATE_FILE, fetch = go_spend.fetch },
}
local WINDOW_LABELS = { rolling = "5h", weekly = "wk", monthly = "mo" }

local function spend_source()
  local ok, model = pcall(maki.model.get)
  if not ok or type(model) ~= "table" then
    return nil
  end
  local provider = string.lower(model.provider or "")
  local spec = string.lower(model.spec or "")
  if provider == "anthropic" or spec:find("claude", 1, true) then
    return "claude"
  elseif provider:find("opencode", 1, true) or spec:find("opencode", 1, true) then
    return "go"
  end
  return nil
end

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

local function read_spend_state(path)
  local raw = maki.fs.read(path)
  if not raw then
    return nil
  end
  local ok, state = pcall(maki.json.decode, raw)
  if not ok or type(state) ~= "table" then
    return nil
  end
  return state
end

local function spend_has_data(kind, last)
  if type(last) ~= "table" then
    return false
  elseif kind == "claude" then
    return last.used ~= nil
  end
  return last.pct ~= nil
end

local function render_spend(kind, report)
  if not spend_has_data(kind, report) then
    spend_span = { string.format("[spend: %s]", report and report.error or "?"), "dim" }
    render_status_hint()
    return
  end

  local text
  if kind == "go" then
    text = string.format("%s %d%%/%s", kind, report.pct, WINDOW_LABELS[report.win] or "?")
    if report.severity and report.severity ~= "normal" then
      text = text .. " " .. report.severity
    end
    local resets = spend_age(report.resets_in)
    if resets then
      text = text .. " resets " .. resets
    end
  else
    text = string.format("$%.2f", report.used)
    if report.pct then
      text = string.format("%s (%d%%)", text, report.pct)
    end
  end
  if report.stale then
    text = "~" .. text
  end
  if kind == "claude" then
    local age = spend_age(report.age)
    if age then
      text = text .. " " .. age .. " ago"
    end
  end

  spend_span = { text, spend_style(report) }
  render_status_hint()
end

local function render_spend_state(kind, state)
  if not state then
    return
  end
  local last = state.last
  if not spend_has_data(kind, last) then
    if state.last_error then
      render_spend(kind, { error = state.last_error })
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
  render_spend(kind, report)
end

local spend_fetching = false

local function refresh_spend()
  local kind = spend_source()
  if not kind then
    if spend_span then
      spend_span = nil
      render_status_hint()
    end
    return
  end
  local src = SOURCES[kind]
  local state = read_spend_state(src.state_file)
  render_spend_state(kind, state)
  if spend_fetching or net_blocked then
    return
  end
  if os.time() < ((state and state.next_at) or 0) then
    return
  end
  spend_fetching = true
  maki.async.spawn(function()
    local ok, err = pcall(src.fetch)
    spend_fetching = false
    if not ok then
      maki.log.warn("spend: " .. tostring(err))
    end
    render_spend_state(kind, read_spend_state(src.state_file))
  end)
end

maki.async.spawn(function()
  while true do
    refresh_spend()
    maki.async.sleep(SPEND_POLL_SECS * 1000)
  end
end)

maki.api.create_autocmd({ "TurnEnd", "ModelChanged", "SessionFocusChanged" }, {
  callback = refresh_spend,
})

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
