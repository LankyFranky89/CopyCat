-- CopyCat: catch Lua errors, show them pre-selected in a small window for Ctrl+C.
local ADDON = ...
CopyCatDB = CopyCatDB or {}

local errors, index = {}, 0
local seen = {}
local inHandler = false

local f = CreateFrame("Frame", "CopyCatFrame", UIParent, "BackdropTemplate")
f:SetSize(380, 150)
f:SetPoint("TOP", 0, -120)
f:SetFrameStrata("DIALOG")
f:SetMovable(true); f:EnableMouse(true); f:SetClampedToScreen(true)
f:RegisterForDrag("LeftButton")
f:SetScript("OnDragStart", f.StartMoving)
f:SetScript("OnDragStop", function(s)
  s:StopMovingOrSizing()
  local p, _, rp, x, y = s:GetPoint()
  CopyCatDB.pos = { p, rp, x, y }
end)
if f.SetBackdrop then
  f:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8x8", edgeFile = "Interface\\Buttons\\WHITE8x8", edgeSize = 1 })
  f:SetBackdropColor(0.06, 0.06, 0.08, 0.94)
  f:SetBackdropBorderColor(0.8, 0.25, 0.25, 1)
end
f:Hide()

local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
title:SetPoint("TOPLEFT", 8, -6)

local hint = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
hint:SetPoint("BOTTOMLEFT", 8, 6)
hint:SetText("Ctrl+C to copy  ·  Esc to close")

local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
close:SetSize(20, 20); close:SetPoint("TOPRIGHT", 2, 2)

local function mkBtn(txt, x)
  local b = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
  b:SetSize(22, 16); b:SetText(txt); b:SetPoint("BOTTOMRIGHT", x, 4)
  return b
end
local nextB = mkBtn(">", -6)
local prevB = mkBtn("<", -30)

local scroll = CreateFrame("ScrollFrame", nil, f, "UIPanelScrollFrameTemplate")
scroll:SetPoint("TOPLEFT", 8, -20)
scroll:SetPoint("BOTTOMRIGHT", -26, 22)

local eb = CreateFrame("EditBox", nil, scroll)
eb:SetMultiLine(true); eb:SetAutoFocus(false)
eb:SetFontObject(ChatFontSmall or GameFontHighlightSmall)
eb:SetWidth(340)
eb:SetScript("OnEscapePressed", function() f:Hide() end)
-- keep text read-only: restore + reselect on any edit
eb:SetScript("OnTextChanged", function(s, user)
  if user and errors[index] then s:SetText(errors[index].full); s:HighlightText() end
end)
eb:SetScript("OnKeyDown", function(s, key)
  if key == "C" and IsControlKeyDown() then
    C_Timer.After(0.05, function() hint:SetText("|cff55ff55Copied!|r") end)
  end
end)
eb:SetScript("OnEditFocusGained", function(s) s:HighlightText() end)
scroll:SetScrollChild(eb)
tinsert(UISpecialFrames, "CopyCatFrame")

local function show(i)
  local e = errors[i]; if not e then return end
  index = i
  title:SetText(("%s  %d/%d%s"):format(e.debug and "|cff55ccffCopyCat debug|r" or "|cffff5555CopyCat|r",
    i, #errors, e.count > 1 and ("  (x" .. e.count .. ")") or ""))
  hint:SetText("Ctrl+C to copy  ·  Esc to close")
  eb:SetText(e.full); eb:SetCursorPosition(0)
  f:Show()
  eb:SetFocus(); eb:HighlightText()
end
prevB:SetScript("OnClick", function() if index > 1 then show(index - 1) end end)
nextB:SetScript("OnClick", function() if index < #errors then show(index + 1) end end)

local function add(msg, stack, locals)
  msg = tostring(msg or "?")
  if seen[msg] then
    seen[msg].count = seen[msg].count + 1
    if f:IsShown() and errors[index] == seen[msg] then show(index) end
    return
  end
  local full = msg
  if stack and stack ~= "" then full = full .. "\n\nStack:\n" .. stack end
  if locals and locals ~= "" then full = full .. "\nLocals:\n" .. locals end
  full = ("[%s] %s"):format(date("%H:%M:%S"), full)
  local e = { msg = msg, full = full, count = 1 }
  seen[msg] = e
  tinsert(errors, e)
  if not (InCombatLockdown() and CopyCatDB.quietCombat) then show(#errors) end
end

local orig = geterrorhandler()
seterrorhandler(function(msg, ...)
  if not inHandler then
    inHandler = true
    pcall(function()
      local stack = debugstack and debugstack(3) or ""
      local locals = debuglocals and debuglocals(3) or ""
      add(msg, stack, locals)
    end)
    inHandler = false
  end
  if CopyCatDB.keepBlizzard and orig then return orig(msg, ...) end
end)

local ev = CreateFrame("Frame")
ev:RegisterEvent("ADDON_LOADED")
ev:RegisterEvent("ADDON_ACTION_BLOCKED")
ev:RegisterEvent("ADDON_ACTION_FORBIDDEN")
ev:RegisterEvent("PLAYER_REGEN_ENABLED")
ev:SetScript("OnEvent", function(_, event, a1, a2)
  if event == "ADDON_LOADED" and a1 == ADDON then
    local p = CopyCatDB.pos
    if p then f:ClearAllPoints(); f:SetPoint(p[1], UIParent, p[2], p[3], p[4]) end
  elseif event == "ADDON_ACTION_BLOCKED" or event == "ADDON_ACTION_FORBIDDEN" then
    add(("%s: %s tried to call %s"):format(event, tostring(a1), tostring(a2)), debugstack and debugstack(2) or "")
  elseif event == "PLAYER_REGEN_ENABLED" and CopyCatDB.quietCombat and #errors > 0 and not f:IsShown() then
    show(#errors)
  end
end)

------------------------------------------------------------------------
-- Debug command catcher: when you type a slash command with debug/dump/diag
-- in it (any addon), the chat lines it prints are collected into the window.
------------------------------------------------------------------------
local chatLog = {} -- { t = GetTime(), text = ... }, rolling
local capture -- active capture { lines = {}, cmd = ..., until = time }
local DEBUG_WORDS = { "debug", "dump", "diag", "icons" }

local function clean(t)
  t = tostring(t or "")
  t = t:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
  t = t:gsub("|H.-|h(.-)|h", "%1"):gsub("|T.-|t", ""):gsub("|A.-|a", "")
  return t
end

local function onChatLine(_, text)
  if text == nil then return end
  local line = clean(text)
  chatLog[#chatLog + 1] = { t = GetTime(), text = line }
  if #chatLog > 300 then table.remove(chatLog, 1) end
  if capture then capture.lines[#capture.lines + 1] = line end
end

local function finishCapture()
  local c = capture; capture = nil
  if not c or #c.lines == 0 then return end
  tinsert(errors, { debug = true, count = 1,
    full = ("[%s] %s\n\n%s"):format(date("%H:%M:%S"), c.cmd, table.concat(c.lines, "\n")) })
  show(#errors)
end

local function isDebugCmd(text)
  local cmd = text:lower():match("^%s*(/.+)")
  if not cmd or cmd:match("^/cc") then return end
  if CopyCatDB.debugCatch == false then return end
  for _, w in ipairs(DEBUG_WORDS) do if cmd:find(w, 1, true) then return true end end
end

local lastTyped = {}
local function hookEditBox(box)
  if not box or box.copyCatHooked then return end
  box.copyCatHooked = true
  box:HookScript("OnTextChanged", function(s) local t = s:GetText(); if t and t ~= "" then lastTyped[s] = t end end)
  box:HookScript("OnEnterPressed", function(s)
    local text = lastTyped[s] or ""; lastTyped[s] = nil
    if not isDebugCmd(text) then return end
    if QuestMatesCopyFrame and QuestMatesCopyFrame:IsShown() and text:lower():match("^%s*/qm") then return end
    -- lines the command printed this frame (GetTime is fixed within a frame)
    local now, lines = GetTime(), {}
    for i = #chatLog, 1, -1 do
      if chatLog[i].t < now then break end
      table.insert(lines, 1, chatLog[i].text)
    end
    -- and anything it prints over the next moment (delayed/timer output)
    capture = { cmd = text, lines = lines }
    C_Timer.After(0.6, finishCapture)
  end)
end

local function hookChatFrames()
  for i = 1, (NUM_CHAT_WINDOWS or 10) do
    local cf = _G["ChatFrame" .. i]
    if cf and not cf.copyCatHooked then
      cf.copyCatHooked = true
      hooksecurefunc(cf, "AddMessage", onChatLine)
    end
    hookEditBox(_G["ChatFrame" .. i .. "EditBox"])
  end
end
hookChatFrames()
C_Timer.After(1, hookChatFrames)

SLASH_COPYCAT1 = "/cc"
SlashCmdList.COPYCAT = function(m)
  m = (m or ""):lower()
  if m == "clear" then wipe(errors); wipe(seen); index = 0; f:Hide(); print("|cffff5555CopyCat|r cleared.")
  elseif m == "combat" then CopyCatDB.quietCombat = not CopyCatDB.quietCombat
    print("|cffff5555CopyCat|r wait until out of combat: " .. (CopyCatDB.quietCombat and "on" or "off"))
  elseif m == "blizz" then CopyCatDB.keepBlizzard = not CopyCatDB.keepBlizzard
    print("|cffff5555CopyCat|r Blizzard error popup too: " .. (CopyCatDB.keepBlizzard and "on" or "off"))
  elseif m == "test" then error("CopyCat test error")
  elseif m == "debug" then CopyCatDB.debugCatch = (CopyCatDB.debugCatch == false)
    print("|cffff5555CopyCat|r catch debug commands: " .. (CopyCatDB.debugCatch ~= false and "on" or "off"))
  elseif m:match("^chat") then
    local n = tonumber(m:match("(%d+)")) or 30
    local out = {}
    for i = math.max(1, #chatLog - n + 1), #chatLog do out[#out + 1] = chatLog[i].text end
    tinsert(errors, { debug = true, count = 1, full = ("[%s] last %d chat lines\n\n%s"):format(date("%H:%M:%S"), #out, table.concat(out, "\n")) })
    show(#errors)
  elseif #errors > 0 then show(index > 0 and index or #errors)
  else print("|cffff5555CopyCat|r no errors yet. /cc clear | combat | blizz | debug (catch debug commands on/off) | chat 30 (copy last chat lines) | test") end
end
