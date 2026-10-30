local M = {}

local opts = {
  app = "maki",
  tty = "/dev/tty",
  tasks = true,
  max_msg_bytes = 200,
}

local ESC = "\27"
local ST = ESC .. "\\"

local tmux = false
local last_sent = {}
local write_failed = false

local sessions = {}
local outcomes = {}
local pending_tool = {}
local task_records = {}

local function sanitize_text(s)
  s = tostring(s or "")
  s = s:gsub("\194[\128-\159]", " "):gsub("[%c\127]", " ")
  s = s:gsub("^%s+", ""):gsub("%s+$", "")
  if #s > opts.max_msg_bytes then
    local cut = opts.max_msg_bytes
    while cut > 0 do
      local b = s:byte(cut + 1)
      if not b or b < 0x80 or b > 0xBF then
        break
      end
      cut -= 1
    end
    s = s:sub(1, cut)
  end
  return s
end

local function segment(s)
  s = tostring(s or ""):gsub("[^%w_%.%+%-]", "-")
  if #s > 32 then
    s = s:sub(1, 32)
  end
  if s == "" then
    return nil
  end
  return s
end

local function emit(fields)
  local parts = { "state=" .. fields.state }
  if fields.id then
    parts[#parts + 1] = "id=" .. fields.id
  end
  if fields.state ~= "clear" then
    if fields.kind then
      parts[#parts + 1] = "kind=" .. fields.kind
    end
    if fields.progress then
      parts[#parts + 1] = "progress=" .. tostring(math.clamp(math.floor(fields.progress), 0, 100))
    end
    if opts.app then
      parts[#parts + 1] = "app=" .. opts.app
    end
    for _, key in ipairs({ "title", "msg" }) do
      local text = fields[key] and sanitize_text(fields[key])
      if text and text ~= "" then
        parts[#parts + 1] = key .. "=" .. maki.base64.encode(text)
      end
    end
  end

  local body = table.concat(parts, ":")
  local key = fields.id or ""
  if last_sent[key] == body then
    return
  end

  local seq = ESC .. "]7501;" .. body .. ST
  if tmux then
    seq = ESC .. "Ptmux;" .. seq:gsub(ESC, ESC .. ESC) .. ST
  end

  local ok, err = maki.fs.append(opts.tty, seq)
  if not ok then
    if not write_failed then
      maki.log.warn("program-status: cannot write to " .. opts.tty .. ": " .. tostring(err))
      write_failed = true
    end
    return
  end
  write_failed = false

  if fields.state == "clear" then
    if fields.id then
      for k in pairs(last_sent) do
        if k == fields.id or k:sub(1, #fields.id + 1) == fields.id .. "/" then
          last_sent[k] = nil
        end
      end
    else
      last_sent = {}
    end
  else
    last_sent[key] = body
  end
end

local PRIORITY = { blocked = 5, working = 4, error = 3, done = 2, idle = 1 }

local function session_state(s)
  if s.status == "needs_input" then
    return "blocked"
  elseif s.status == "working" then
    return "working"
  end
  return outcomes[s.id] or "idle"
end

local function track(session_id)
  if not session_id then
    return nil
  end
  local s = sessions[session_id]
  if not s then
    s = { id = session_id, status = "idle" }
    sessions[session_id] = s
  end
  return s
end

local function set_focused(session_id)
  for id, s in pairs(sessions) do
    s.focused = id == session_id
  end
end

local function refresh_root()
  local best, best_state
  for _, s in pairs(sessions) do
    local st = session_state(s)
    local better = not best
      or PRIORITY[st] > PRIORITY[best_state]
      or (PRIORITY[st] == PRIORITY[best_state] and s.focused and not best.focused)
    if better then
      best, best_state = s, st
    end
  end

  if not best then
    emit({ state = "idle" })
    return
  end

  local fields = { state = best_state, msg = best.title }
  if best_state == "blocked" then
    fields.kind = pending_tool[best.id] == "question" and "question" or "permission"
  end
  emit(fields)
end

local TASK_STATES = { working = true, idle = true, done = true, error = true }

local function task_record_id(session_id, task_id)
  local sid, tid = segment(session_id), segment(task_id)
  if not sid or not tid then
    return nil
  end
  return sid .. "/" .. tid
end

local function clear_session(session_id)
  sessions[session_id] = nil
  outcomes[session_id] = nil
  pending_tool[session_id] = nil
  local sid = segment(session_id)
  if sid and task_records[sid] then
    task_records[sid] = nil
    emit({ state = "clear", id = sid })
  end
end

local function on(events, fn)
  maki.api.create_autocmd(events, {
    callback = function(ev)
      local ok, err = pcall(fn, ev.data or {}, ev)
      if not ok then
        maki.log.warn("program-status: " .. ev.event .. ": " .. tostring(err))
      end
    end,
  })
end

function M.setup(user_opts)
  for k, v in pairs(user_opts or {}) do
    opts[k] = v
  end
  if opts.app then
    opts.app = segment(opts.app)
  end
  if opts.tmux ~= nil then
    tmux = opts.tmux
  else
    local ok, val = pcall(maki.uv.os_getenv, "TMUX")
    tmux = ok and val ~= nil and val ~= ""
  end

  on("TurnStart", function(d)
    outcomes[d.session_id] = nil
    local s = track(d.session_id)
    if s then
      s.status = "working"
    end
    refresh_root()
  end)

  on("TurnEnd", function(d)
    if d.reason == "finished" or d.reason == "max_tokens" or d.reason == "max_turns" then
      outcomes[d.session_id] = "done"
    else
      outcomes[d.session_id] = nil
    end
    pending_tool[d.session_id] = nil
    refresh_root()
  end)

  on("TurnError", function(d)
    outcomes[d.session_id] = "error"
    pending_tool[d.session_id] = nil
    refresh_root()
  end)

  on("ToolStart", function(d)
    pending_tool[d.session_id] = d.tool
  end)

  on("ToolDone", function(d)
    if pending_tool[d.session_id] == d.tool then
      pending_tool[d.session_id] = nil
    end
  end)

  on("SessionStatusChanged", function(d)
    local s = track(d.session_id)
    if not s then
      return
    end
    s.status = d.status or s.status
    s.title = d.title or s.title
    if d.focused then
      set_focused(d.session_id)
    end
    refresh_root()
  end)

  on("SessionTitleChanged", function(d)
    local s = track(d.session_id)
    if not s then
      return
    end
    s.title = d.title or s.title
    if d.focused then
      set_focused(d.session_id)
    end
    refresh_root()
  end)

  on("SessionFocusChanged", function(d)
    track(d.session_id)
    set_focused(d.session_id)
    refresh_root()
  end)

  on("InputChanged", function(d)
    if d.cursor_only or not outcomes[d.session_id] then
      return
    end
    outcomes[d.session_id] = nil
    refresh_root()
  end)

  on("SessionReset", function(d)
    clear_session(d.session_id)
    refresh_root()
  end)

  on("SessionEnd", function(d)
    if d.reason == "shutdown" or d.reason == "completed" then
      emit({ state = "clear" })
      return
    end
    if d.reason == "reload" then
      return
    end
    clear_session(d.session_id)
    if d.reason ~= "reset" then
      refresh_root()
    end
  end)

  if opts.tasks then
    on("TaskStatusChanged", function(d)
      if not TASK_STATES[d.status] then
        return
      end
      local id = task_record_id(d.session_id, d.id)
      if not id then
        return
      end
      local sid = segment(d.session_id)
      task_records[sid] = true
      emit({ state = d.status, id = id, title = d.name })
    end)
  end
end

return M
