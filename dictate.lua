-- dictate.lua — local push-to-talk dictation (see SPEC.md)
-- Hold the PTT key (default: fn/Globe) to record; release to transcribe via a
-- local whisper-server and paste the result into the frontmost app.
-- The menu bar icon is also the mic selector: pick a fixed device, or
-- "Auto — follow focused screen" with per-screen mic assignments.

local config = dofile(os.getenv("HOME") .. "/.dictate/config.lua")

local WAV = os.getenv("HOME") .. "/.dictate/tmp/rec.wav"
local SERVER_URL = string.format("http://127.0.0.1:%d/inference", config.server_port)

-- flagsChanged keycodes for modifier keys usable alone as push-to-talk.
-- This table is the full set of supported hotkeys.
local PTT_KEYS = {
  fn        = { keycode = 63, flag = "fn"   },
  rightalt  = { keycode = 61, flag = "alt"  },
  rightcmd  = { keycode = 54, flag = "cmd"  },
  rightctrl = { keycode = 62, flag = "ctrl" },
}
local ptt = PTT_KEYS[config.hotkey] or PTT_KEYS.fn

-- ---------------------------------------------------------------- logging

local function log(msg)
  local f = io.open(config.log_file, "a")
  if f then
    f:write(os.date("%Y-%m-%d %H:%M:%S ") .. msg .. "\n")
    f:close()
  end
end

-- ---------------------------------------------------------------- settings
-- config.lua holds hand-edited defaults; menu choices persist via hs.settings
-- and take precedence.

local function getSetting(key, default)
  local v = hs.settings.get("dictate." .. key)
  if v == nil then return default end
  return v
end
local function setSetting(key, value)
  hs.settings.set("dictate." .. key, value)
end

local micMode    = getSetting("mic_mode", config.mic_mode)   -- "auto" | "fixed"
local fixedLabel = getSetting("fixed_device", nil)           -- device label, nil = config default
local screenMap  = getSetting("screen_map", {})              -- screen UUID -> device label

-- ---------------------------------------------------------------- devices
-- avfoundation's -audio_device_index is a GLOBAL index and overrides any name
-- in -i (verified). Indices reshuffle when devices come and go, so devices are
-- identified by label ("name" or "name (k)" for duplicates) and resolved to
-- the current global index from a cached enumeration at key-down. The cache is
-- refreshed by the audiodevice watcher and on menu open — never at key-down,
-- which would delay capture.

local deviceCache = {}   -- array of { name, globalIndex, label }
local warnedMissing = {}
local enumerating = false

local function parseDeviceList(stderr)
  local devs, inAudio = {}, false
  for line in stderr:gmatch("[^\n]+") do
    if line:find("AVFoundation audio devices:", 1, true) then
      inAudio = true
    elseif line:find("AVFoundation video devices:", 1, true) then
      inAudio = false
    elseif inAudio then
      local idx, name = line:match("%[(%d+)%]%s+(.+)$")
      if idx then table.insert(devs, { name = name, globalIndex = tonumber(idx) }) end
    end
  end
  local counts, seen = {}, {}
  for _, d in ipairs(devs) do counts[d.name] = (counts[d.name] or 0) + 1 end
  for _, d in ipairs(devs) do
    seen[d.name] = (seen[d.name] or 0) + 1
    d.label = (counts[d.name] > 1) and string.format("%s (%d)", d.name, seen[d.name]) or d.name
  end
  return devs
end

local function refreshDevices()
  if enumerating then return end
  enumerating = true
  local t = hs.task.new(config.ffmpeg_bin, function(_, _, stderr)
    enumerating = false
    local devs = parseDeviceList(stderr or "")
    if #devs > 0 then
      deviceCache = devs
      warnedMissing = {}
    end
  end, { "-hide_banner", "-f", "avfoundation", "-list_devices", "true", "-i", "" })
  t:start()
end

local function findByLabel(label)
  for _, d in ipairs(deviceCache) do if d.label == label then return d end end
end
local function findByName(name)
  for _, d in ipairs(deviceCache) do if d.name == name then return d end end
end

local function warnMissing(label)
  if not warnedMissing[label] then
    warnedMissing[label] = true
    hs.alert.show("Dictation: mic “" .. label .. "” not found — using fallback")
    log("mic missing: " .. label)
  end
end

-- Fallback chain: auto-assigned mic -> fixed selection -> config default ->
-- system default input -> first available.
local function resolveDevice()
  if micMode == "auto" then
    local win = hs.window.focusedWindow()
    local scr = (win and win:screen()) or hs.mouse.getCurrentScreen() or hs.screen.mainScreen()
    local uuid = scr and scr:getUUID()
    local label = uuid and screenMap[uuid]
    if label then
      local d = findByLabel(label)
      if d then return d, "auto:" .. (scr:name() or "?") end
      warnMissing(label)
    end
  end
  if fixedLabel then
    local d = findByLabel(fixedLabel)
    if d then return d, "fixed" end
    warnMissing(fixedLabel)
  end
  local d = findByName(config.audio_device.name)
  if d then return d, "config-default" end
  local sys = hs.audiodevice.defaultInputDevice()
  if sys then
    d = findByName(sys:name())
    if d then return d, "system-default" end
  end
  return deviceCache[1], "first-available"
end

-- ---------------------------------------------------------------- indicator + menu

local menubar = hs.menubar.new()
local pill = nil
local growTimer = nil

local function hidePill()
  if pill then pill:delete() pill = nil end
end

local function showPill(text)
  hidePill()
  local win = hs.window.focusedWindow()
  local scr = (win and win:screen()) or hs.mouse.getCurrentScreen() or hs.screen.mainScreen()
  local f = scr:fullFrame()
  local w, h = math.max(230, 140 + (#text * 8)), 36
  pill = hs.canvas.new({ x = f.x + (f.w - w) / 2, y = f.y + f.h - h - 28, w = w, h = h })
  pill[1] = { type = "rectangle", action = "fill",
              roundedRectRadii = { xRadius = 18, yRadius = 18 },
              fillColor = { red = 0.08, green = 0.08, blue = 0.08, alpha = 0.85 } }
  pill[2] = { type = "text", text = text, textAlignment = "center",
              textColor = { white = 1, alpha = 0.95 }, textSize = 15,
              frame = { x = 0, y = 7, w = w, h = h - 7 } }
  pill:level(hs.canvas.windowLevels.overlay)
  pill:behaviorAsLabels({ "canJoinAllSpaces", "stationary" })
  pill:show()
end

local function setPillText(text)
  if pill then pill[2].text = text end
end

local state = "idle" -- idle | recording | transcribing
local currentMicLabel = nil -- shown in the pill so each recording self-reports its mic

local function setState(s)
  state = s
  if s == "idle" then
    menubar:setTitle("🎤")
    hidePill()
  elseif s == "recording" then
    menubar:setTitle("🔴")
    showPill("⏳ " .. (currentMicLabel or "Mic") .. " starting…")
  elseif s == "transcribing" then
    menubar:setTitle("…")
    setPillText("✍️ Transcribing…")
  end
end

-- Screens sorted by x position, labeled "(left)"/"(right)" when there are two.
local function screensWithLabels()
  local screens = hs.screen.allScreens()
  table.sort(screens, function(a, b) return a:frame().x < b:frame().x end)
  local out = {}
  for i, s in ipairs(screens) do
    local pos = ""
    if #screens == 2 then
      pos = (i == 1) and " (left)" or " (right)"
    elseif #screens > 2 then
      pos = string.format(" (#%d from left)", i)
    end
    table.insert(out, { screen = s, title = (s:name() or "Display") .. pos })
  end
  return out
end

local function buildMenu()
  local items = {}
  table.insert(items, {
    title = "Auto — follow focused screen",
    checked = (micMode == "auto"),
    fn = function()
      micMode = "auto"
      setSetting("mic_mode", "auto")
    end,
  })
  table.insert(items, { title = "-" })
  for _, d in ipairs(deviceCache) do
    table.insert(items, {
      title = d.label,
      checked = (micMode == "fixed" and d.label == fixedLabel),
      fn = function()
        micMode = "fixed"
        fixedLabel = d.label
        setSetting("mic_mode", "fixed")
        setSetting("fixed_device", d.label)
        hs.alert.show("Dictation mic: " .. d.label)
      end,
    })
  end
  table.insert(items, { title = "-" })
  local assign = {}
  for _, entry in ipairs(screensWithLabels()) do
    local uuid = entry.screen:getUUID()
    local sub = {}
    for _, d in ipairs(deviceCache) do
      table.insert(sub, {
        title = d.label,
        checked = (screenMap[uuid] == d.label),
        fn = function()
          screenMap[uuid] = d.label
          setSetting("screen_map", screenMap)
          hs.alert.show(entry.title .. " → " .. d.label)
        end,
      })
    end
    table.insert(sub, { title = "-" })
    table.insert(sub, {
      title = "None",
      checked = (screenMap[uuid] == nil),
      fn = function()
        screenMap[uuid] = nil
        setSetting("screen_map", screenMap)
      end,
    })
    table.insert(assign, { title = entry.title, menu = sub })
  end
  table.insert(items, { title = "Assign screen mics", menu = assign })
  refreshDevices() -- so the next open reflects any device changes
  return items
end

-- ---------------------------------------------------------------- whisper-server

local serverTask = nil

local function startServer()
  if serverTask and serverTask:isRunning() then return end
  -- Clear any orphan from a previous Hammerspoon crash holding our port.
  hs.execute(string.format([[/usr/bin/pkill -f "whisper-server.*--port %d"]], config.server_port))
  serverTask = hs.task.new(config.server_bin, function(code, _, err)
    if code ~= 0 then log("whisper-server exited " .. tostring(code) .. ": " .. (err or "")) end
  end, {
    "-m", config.model_path,
    "--host", "127.0.0.1",
    "--port", tostring(config.server_port),
    "-t", "4",
    "-sns", -- suppress non-speech tokens
  })
  serverTask:start()
  log("whisper-server started on port " .. config.server_port)
end

local function stopServer()
  if serverTask and serverTask:isRunning() then serverTask:terminate() end
end

-- ---------------------------------------------------------------- text cleanup

local BLOCKLIST = {
  ["Thank you."] = true, ["Thanks for watching."] = true,
  ["you"] = true, ["Thank you for watching."] = true,
}

-- Case-insensitive Lua pattern for a filler word, e.g. "um" -> "[Uu][Mm]"
local function fillerPattern(word)
  return (word:gsub("%a", function(c) return "[" .. c:upper() .. c:lower() .. "]" end))
end
local FILLERS = { "um", "uhm", "uh", "er", "ah", "hmm" }

local function cleanText(raw)
  local lines = {}
  for line in raw:gmatch("[^\n]+") do
    -- drop whole-line [..] / (..) annotations like [BLANK_AUDIO], (silence)
    if not line:match("^%s*[%[%(][^%]%)]*[%]%)][%s%p]*$") then
      table.insert(lines, line)
    end
  end
  local s = table.concat(lines, " ")
  -- known artifacts that can appear inline
  s = s:gsub("%[BLANK_AUDIO%]", " "):gsub("%[Music%]", " "):gsub("%(silence%)", " ")
  -- filler words as standalone tokens only (%f frontiers = word boundaries),
  -- swallowing a trailing comma so "Hello, um, world" -> "Hello, world"
  for _, w in ipairs(FILLERS) do
    s = s:gsub("%f[%a]" .. fillerPattern(w) .. "%f[%A],?%s*", " ")
  end
  s = s:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
  s = s:gsub("^%l", string.upper)
  if s == "" or BLOCKLIST[s] then return nil end
  return s
end

-- ---------------------------------------------------------------- insertion

local function insertText(text)
  if config.paste_mode == "keystrokes" then
    hs.eventtap.keyStrokes(text)
    return
  end
  local saved = hs.pasteboard.readAllData(nil)
  hs.pasteboard.setContents(text)
  hs.eventtap.keyStroke({ "cmd" }, "v", 30000)
  -- restore the previous pasteboard (all types, so images survive) even on error
  hs.timer.doAfter(config.restore_delay_ms / 1000, function()
    pcall(function()
      if saved and next(saved) ~= nil then hs.pasteboard.writeAllData(nil, saved) end
    end)
  end)
end

-- ---------------------------------------------------------------- transcription

local function finishRun()
  os.remove(WAV) -- privacy: never leave audio on disk
  setState("idle")
end

local function failRun(alertMsg, detail)
  hs.alert.show("Dictation: " .. alertMsg)
  log(alertMsg .. (detail and (" | " .. detail) or ""))
  finishRun()
end

local function handleTranscript(raw)
  local text = cleanText(raw)
  if text then
    insertText(text)
  else
    log("empty/blocklisted transcript, nothing inserted")
  end
  finishRun()
end

local transcribe -- forward declaration (retry recursion)

local function transcribeCli(wav)
  local t = hs.task.new(config.cli_bin, function(code, out, err)
    if code == 0 then handleTranscript(out)
    else failRun("whisper-cli failed (" .. tostring(code) .. ")", err) end
  end, { "-m", config.model_path, "-f", wav, "--no-timestamps",
         "-l", config.language, "-t", "4" })
  t:start()
end

transcribe = function(wav, isRetry)
  setState("transcribing")
  if config.transcribe_mode == "cli" then return transcribeCli(wav) end
  local t = hs.task.new("/usr/bin/curl", function(code, out, err)
    if code == 0 then
      handleTranscript(out)
    elseif code == 7 and not isRetry then
      -- connection refused: server died or still warming up — restart, retry once
      log("server unreachable, restarting and retrying")
      startServer()
      hs.timer.doAfter(1.5, function() transcribe(wav, true) end)
    else
      failRun("transcription failed (curl exit " .. tostring(code) .. ")", err)
    end
  end, { "-s", "--max-time", "30", SERVER_URL,
         "-F", "file=@" .. wav,
         "-F", "response_format=text",
         "-F", "language=" .. config.language,
         "-F", "temperature=0.0" })
  t:start()
end

-- ---------------------------------------------------------------- recording

local recTask = nil
local holdStart = 0
local canceled = false

local function onRecordingDone(code, _, err)
  if growTimer then growTimer:stop() growTimer = nil end
  local heldFor = hs.timer.secondsSinceEpoch() - holdStart
  if canceled or heldFor < config.min_duration_s then
    finishRun() -- silent discard
    return
  end
  local attr = hs.fs.attributes(WAV)
  -- ffmpeg exits 255 on SIGINT even on success: judge by the WAV, not the code
  if attr and attr.size and attr.size > 44 then
    transcribe(WAV, false)
  else
    failRun("recording failed", "ffmpeg exit " .. tostring(code) .. " | " .. (err or ""):sub(-500))
  end
end

local function startRecording()
  if state ~= "idle" then return end
  local dev, how = resolveDevice()
  if not dev then
    hs.alert.show("Dictation: no microphone found")
    return
  end
  currentMicLabel = dev.label
  canceled = false
  holdStart = hs.timer.secondsSinceEpoch()
  os.remove(WAV)
  recTask = hs.task.new(config.ffmpeg_bin, onRecordingDone, {
    "-y", "-f", "avfoundation",
    "-audio_device_index", tostring(dev.globalIndex),
    "-i", ":", -- device comes from the index above; avfoundation ignores the name
    "-ar", "16000", "-ac", "1", "-acodec", "pcm_s16le",
    "-flush_packets", "1", -- write audio to disk immediately so the pill can report honestly
    "-t", tostring(config.max_duration_s),
    WAV,
  })
  recTask:start()
  setState("recording")
  log(string.format("recording via %s [%d] (%s)", dev.label, dev.globalIndex, how))
  -- flip the pill to "Listening" once audio bytes are actually flowing
  -- (the device takes ~0.3-0.7s to open; speaking before that is clipped)
  growTimer = hs.timer.doEvery(0.025, function()
    local a = hs.fs.attributes(WAV)
    if a and a.size and a.size > 1024 then
      setPillText("🎤 " .. (currentMicLabel or "Mic") .. " — listening…")
      if growTimer then growTimer:stop() growTimer = nil end
    end
  end)
end

local function stopRecording()
  if state ~= "recording" or canceled then return end
  if recTask and recTask:isRunning() then
    recTask:interrupt() -- SIGINT finalizes the WAV header; completion runs onRecordingDone
  end
end

local function cancelRecording()
  if state ~= "recording" or canceled then return end
  canceled = true
  if recTask and recTask:isRunning() then recTask:interrupt() end
end

-- ---------------------------------------------------------------- hotkey

local pttDown = false

local flagsTap = hs.eventtap.new({ hs.eventtap.event.types.flagsChanged }, function(e)
  if e:getKeyCode() ~= ptt.keycode then return false end
  local isDown = e:getFlags()[ptt.flag] == true
  if isDown and not pttDown then
    pttDown = true
    startRecording()
  elseif not isDown and pttDown then
    pttDown = false
    stopRecording()
  end
  return false
end)

-- Any regular key while PTT is held (fn+arrows, fn+delete, ...) cancels the
-- recording and passes through untouched.
local keyTap = hs.eventtap.new({ hs.eventtap.event.types.keyDown }, function(e)
  if state == "recording" then cancelRecording() end
  return false
end)

-- ---------------------------------------------------------------- init

os.remove(WAV) -- clear any leftover audio from a crash
refreshDevices()
hs.audiodevice.watcher.setCallback(function(event)
  if event == "dev#" then refreshDevices() end -- device list changed
end)
hs.audiodevice.watcher.start()
startServer()
menubar:setMenu(buildMenu)
flagsTap:start()
keyTap:start()
setState("idle")
hs.shutdownCallback = stopServer
log("dictate.lua loaded; hotkey=" .. config.hotkey .. "; mic_mode=" .. micMode)
hs.alert.show("Dictation ready — hold " .. config.hotkey .. " to talk")

-- keep references alive (Hammerspoon GC collects unanchored taps/menubars);
-- debug() dumps mic state for troubleshooting via `hs -c`.
return {
  flagsTap = flagsTap,
  keyTap = keyTap,
  menubar = menubar,
  debug = function()
    return hs.inspect({ mode = micMode, fixed = fixedLabel, map = screenMap, devices = deviceCache })
  end,
}
