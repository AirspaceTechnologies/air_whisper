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
  if not t:start() then enumerating = false end -- else a failed launch blocks refreshes forever
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

-- ---------------------------------------------------------------- indicator

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
local stateChangedAt = hs.timer.secondsSinceEpoch()
local currentMicLabel = nil -- shown in the pill so each recording self-reports its mic

local function setState(s)
  state = s
  stateChangedAt = hs.timer.secondsSinceEpoch()
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

-- forward declaration: safely() must be able to kill a live recorder, but
-- recTask is assigned in the recording section further down; without this
-- the reference inside safely would silently resolve to a nil global
local recTask

-- Wrap tap/task callbacks so a Lua error logs and resets to idle instead of
-- freezing the pipeline mid-state (a frozen "Listening…" pill is worse than a
-- dropped dictation).
local function safely(fn, where)
  return function(...)
    local ok, ret = pcall(fn, ...)
    if ok then return ret end
    log("LUA ERROR in " .. where .. ": " .. tostring(ret))
    hs.alert.show("Dictation error — see log")
    -- kill a live recorder BEFORE resetting state: setState("idle") disarms
    -- the stuck guard, and an orphaned ffmpeg would record to the -t cap and
    -- then paste minutes of ambient audio into whatever has focus
    pcall(function()
      if recTask and recTask:isRunning() then
        hs.execute("/bin/kill -9 " .. tostring(recTask:pid()))
      end
    end)
    pcall(os.remove, WAV)
    pcall(setState, "idle")
    return false
  end
end

-- ---------------------------------------------------------------- menu

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
  table.insert(items, { title = "-" })
  table.insert(items, { title = "Restart dictation", fn = function() hs.reload() end })
  refreshDevices() -- so the next open reflects any device changes
  return items
end

-- ---------------------------------------------------------------- whisper-server

local serverTask = nil
local serverReady = false -- set by probeServer once the HTTP endpoint answers

-- The server prints "listening at" to stdout, but stdout is FULLY BUFFERED
-- into a pipe (verified: 0 bytes arrive for 24s), so readiness can't be read
-- from the stream — poll the HTTP endpoint instead.
local function probeServer(attempt)
  local t = hs.task.new("/usr/bin/curl", function(code, out)
    if code == 0 and out == "200" then
      serverReady = true
      log("whisper-server ready")
    elseif attempt < 20 and serverTask and serverTask:isRunning() then
      hs.timer.doAfter(0.5, function() probeServer(attempt + 1) end)
    else
      log("whisper-server never became ready")
    end
  end, { "-s", "-o", "/dev/null", "-w", "%{http_code}", "--max-time", "2",
         string.format("http://127.0.0.1:%d/", config.server_port) })
  if not t:start() then log("readiness probe failed to launch") end
end

local function startServer()
  if serverTask and serverTask:isRunning() then return end
  -- Clear any orphan from a previous Hammerspoon crash holding our port.
  hs.execute(string.format([[/usr/bin/pkill -f "whisper-server.*--port %d"]], config.server_port))
  serverReady = false
  serverTask = hs.task.new(config.server_bin, function(code, _, err)
    serverReady = false
    if code ~= 0 then log("whisper-server exited " .. tostring(code) .. ": " .. (err or "")) end
  end, function(_, _, stderr)
    -- draining is load-bearing: hs.task only reads a long-lived task's output
    -- when a streaming callback is set — without one the 64KiB stderr pipe
    -- fills after ~170 requests and the server write-blocks forever.
    -- stderr (unlike stdout) arrives promptly, so bind failures surface here.
    if stderr and stderr:find("couldn't bind", 1, true) then
      hs.alert.show("Dictation: port " .. config.server_port .. " is in use — dictation disabled")
    end
    return true -- keep streaming
  end, {
    "-m", config.model_path,
    "--host", "127.0.0.1",
    "--port", tostring(config.server_port),
    "-t", "4",
    "-sns", -- suppress non-speech tokens
  })
  if serverTask:start() then
    log("whisper-server started on port " .. config.server_port)
    probeServer(1)
  else
    serverTask = nil
    log("whisper-server failed to launch: " .. tostring(config.server_bin))
  end
end

local function stopServer()
  if serverTask and serverTask:isRunning() then serverTask:terminate() end
end

-- ---------------------------------------------------------------- text cleanup

-- checked AFTER cleanText capitalizes the first letter, so entries must be
-- capitalized ("You", not just "you") to be reachable
local BLOCKLIST = {
  ["Thank you."] = true, ["Thanks for watching."] = true,
  ["you"] = true, ["You"] = true, ["Thank you for watching."] = true,
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
  if hs.pasteboard.setContents(text) then
    hs.eventtap.keyStroke({ "cmd" }, "v", 30000)
  else
    -- a clipboard manager can steal pasteboard ownership mid-write; pasting
    -- then would insert the user's OLD clipboard — type the text instead
    log("pasteboard setContents failed (ownership changed) — typing instead")
    hs.eventtap.keyStrokes(text)
  end
  -- restore the previous pasteboard (all types, so images survive) even on error
  hs.timer.doAfter(config.restore_delay_ms / 1000, function()
    pcall(function()
      if saved and next(saved) ~= nil then
        hs.pasteboard.writeAllData(nil, saved)
      else
        -- clipboard was empty before (readAllData returns {}): clear it
        -- rather than leaving the transcript behind
        hs.pasteboard.clearContents()
      end
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
  local t = hs.task.new(config.cli_bin, safely(function(code, out, err)
    if code == 0 then handleTranscript(out)
    else failRun("whisper-cli failed (" .. tostring(code) .. ")", err) end
  end, "cli-transcribe"), { "-m", config.model_path, "-f", wav, "--no-timestamps",
         "-l", config.language, "-t", "4" })
  if not t:start() then failRun("whisper-cli failed to launch", tostring(config.cli_bin)) end
end

transcribe = function(wav, isRetry)
  setState("transcribing")
  if config.transcribe_mode == "cli" then return transcribeCli(wav) end
  -- fail closed: never upload audio unless OUR server is alive and confirmed
  -- bound — whisper-server sets SO_REUSEPORT, so a squatter on the port can
  -- otherwise receive the recording and have its response pasted
  if not (serverTask and serverTask:isRunning() and serverReady) then
    if isRetry then
      return failRun("transcription server unavailable",
                     "still starting, or port " .. config.server_port .. " is in use")
    end
    log("server not ready, restarting and retrying")
    startServer()
    return hs.timer.doAfter(2.5, function() transcribe(wav, true) end)
  end
  local t = hs.task.new("/usr/bin/curl", safely(function(code, out, err)
    if code == 0 then
      handleTranscript(out)
    elseif (code == 7 or code == 28) and not isRetry then
      -- 7: connection refused (server died / warming up). 28: timeout — a
      -- wedged server keeps its port LISTENing so refused can never fire.
      log("server unreachable (curl exit " .. tostring(code) .. "), restarting and retrying")
      startServer()
      hs.timer.doAfter(1.5, function() transcribe(wav, true) end)
    else
      -- with --fail-with-body the server's error body arrives on stdout
      failRun("transcription failed (curl exit " .. tostring(code) .. ")",
              (out ~= nil and out ~= "" and out) or err)
    end
  end, "transcribe"), {
         -- --fail-with-body: HTTP >= 400 exits 22 instead of pasting the error
         -- body as a transcript; connection-refused stays exit 7 for the retry.
         -- token_timestamps=false: server default since v1.8.4 wraps segments at
         -- 60 chars on TOKEN boundaries, splitting words (whisper.cpp #3968);
         -- note max_len=0 is NOT a fix — the server maps 0 back to 60.
         "-s", "--fail-with-body", "--max-time", "30", SERVER_URL,
         "-F", "file=@" .. wav,
         "-F", "response_format=text",
         "-F", "token_timestamps=false",
         "-F", "language=" .. config.language,
         "-F", "temperature=0.0" })
  if not t:start() then failRun("curl failed to launch", "/usr/bin/curl") end
end

-- ---------------------------------------------------------------- recording

recTask = nil -- declared above safely(), which kills it on error recovery
local holdStart = 0
local canceled = false
local watchdog = nil
local pttDown = false
local flagsTap -- assigned in the hotkey section; the watchdog re-enables it

local function stopWatchdog()
  if watchdog then watchdog:stop() watchdog = nil end
end

local function onRecordingDone(code, _, err)
  if growTimer then growTimer:stop() growTimer = nil end
  stopWatchdog()
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

-- SIGINT finalizes the WAV header; completion runs onRecordingDone. A
-- write-blocked or device-stalled ffmpeg ignores catchable signals, so
-- escalate to SIGKILL after a grace period — losing one dictation beats
-- an invisible open mic.
local function interruptRecorder()
  if not (recTask and recTask:isRunning()) then return end
  recTask:interrupt()
  local t = recTask
  hs.timer.doAfter(3, function()
    if t:isRunning() then
      log("recorder ignored SIGINT for 3s — sending SIGKILL")
      hs.execute("/bin/kill -9 " .. tostring(t:pid()))
    end
  end)
end

local function stopRecording()
  if state ~= "recording" or canceled then return end
  interruptRecorder()
end

local function cancelRecording()
  if state ~= "recording" or canceled then return end
  canceled = true
  interruptRecorder()
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
  -- -nostats/-loglevel error: ffmpeg must NOT chatter on stderr. If Hammerspoon
  -- reloads mid-recording, nothing drains the pipe; once it fills, every
  -- write() blocks and the process becomes immune to SIGINT/SIGTERM while
  -- holding the mic open (observed: 40 min). Silence makes that impossible.
  recTask = hs.task.new(config.ffmpeg_bin, safely(onRecordingDone, "recording-done"), {
    "-nostats", "-loglevel", "error",
    "-y", "-f", "avfoundation",
    "-audio_device_index", tostring(dev.globalIndex),
    "-i", ":", -- device comes from the index above; avfoundation ignores the name
    "-ar", "16000", "-ac", "1", "-acodec", "pcm_s16le",
    "-flush_packets", "1", -- write audio to disk immediately so the pill can report honestly
    "-t", tostring(config.max_duration_s),
    WAV,
  })
  -- hs.task.new returns a valid object even for a bad path; only start()
  -- reports launch failure (false), and the callback never fires — without
  -- this guard the pipeline would sit in "recording" until the stuck guard
  if not recTask:start() then
    recTask = nil
    hs.alert.show("Dictation: recorder failed to start")
    log("ffmpeg failed to launch: " .. tostring(config.ffmpeg_bin))
    return -- stay idle
  end
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
  -- watchdog: a flagsChanged keyup can be lost (event tap disabled by a
  -- timeout, secure input, ...) which would leave the recording stuck until
  -- the -t cap. Poll the real modifier state and stop as if released.
  watchdog = hs.timer.doEvery(0.25, function()
    if state ~= "recording" then
      stopWatchdog()
      return
    end
    if flagsTap and not flagsTap:isEnabled() then
      log("watchdog: event tap was disabled, re-enabling")
      flagsTap:start()
    end
    if pttDown and not hs.eventtap.checkKeyboardModifiers()[ptt.flag] then
      log("watchdog: missed keyup, stopping recording")
      pttDown = false
      stopRecording()
    end
  end)
end

-- ---------------------------------------------------------------- hotkey

flagsTap = hs.eventtap.new({ hs.eventtap.event.types.flagsChanged }, safely(function(e)
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
end, "flags-tap"))

-- Any regular key while PTT is held (fn+arrows, fn+delete, ...) cancels the
-- recording and passes through untouched. The pttDown gate matters: state
-- stays "recording" for ~30ms after key-up (until ffmpeg's exit callback), and
-- a keystroke in that window must not discard the finished dictation.
local keyTap = hs.eventtap.new({ hs.eventtap.event.types.keyDown }, safely(function(e)
  if state == "recording" and pttDown then cancelRecording() end
  return false
end, "key-tap"))

-- Last-resort self-heal: if some failure mode we haven't met yet leaves the
-- pipeline in a non-idle state well past every legitimate bound (recording is
-- capped at max_duration_s, transcription at 30s), force it back to idle.
local stuckGuard = hs.timer.doEvery(15, function()
  local stuckFor = hs.timer.secondsSinceEpoch() - stateChangedAt
  if state ~= "idle" and stuckFor > config.max_duration_s + 45 then
    log(string.format("stuck-state guard: state=%s for %.0fs, forcing idle", state, stuckFor))
    hs.alert.show("Dictation reset (was stuck)")
    pcall(function()
      if recTask and recTask:isRunning() then
        hs.execute("/bin/kill -9 " .. tostring(recTask:pid()))
      end
    end)
    stopWatchdog()
    finishRun()
  end
end)

-- ---------------------------------------------------------------- init

-- SIGKILL stray recorders from a crash/reload: a write-blocked one ignores
-- everything milder (see the -nostats note in startRecording)
hs.execute('/usr/bin/pkill -9 -f "' .. WAV .. '"')
os.remove(WAV) -- clear any leftover audio from a crash
refreshDevices()
-- hs.audiodevice.watcher is a singleton with no callback getter, so composing
-- with an existing handler is impossible — at least make the takeover loud
if hs.audiodevice.watcher.isRunning() then
  log("WARNING: hs.audiodevice.watcher already active — dictate.lua is replacing its callback")
  hs.alert.show("Dictation: replaced an existing hs.audiodevice.watcher callback")
end
hs.audiodevice.watcher.setCallback(function(event)
  if event == "dev#" then refreshDevices() end -- device list changed
end)
hs.audiodevice.watcher.start()
startServer()
menubar:setMenu(buildMenu)
flagsTap:start()
keyTap:start()
setState("idle")
local priorShutdown = hs.shutdownCallback -- chain another module's handler, don't clobber it
hs.shutdownCallback = function()
  -- runs on quit AND on config reload: never abandon a live recorder — after
  -- a reload nothing drains its stderr pipe and no Lua state can reach it
  pcall(function()
    if recTask and recTask:isRunning() then
      hs.execute("/bin/kill -9 " .. tostring(recTask:pid()))
    end
  end)
  pcall(os.remove, WAV)
  pcall(stopServer)
  if type(priorShutdown) == "function" then pcall(priorShutdown) end
end
log("dictate.lua loaded; hotkey=" .. config.hotkey .. "; mic_mode=" .. micMode)
hs.alert.show("Dictation ready — hold " .. config.hotkey .. " to talk")

-- keep references alive (Hammerspoon GC collects unanchored taps/timers/menubars);
-- debug() dumps mic state for troubleshooting via `hs -c`.
return {
  flagsTap = flagsTap,
  keyTap = keyTap,
  menubar = menubar,
  stuckGuard = stuckGuard,
  debug = function()
    return hs.inspect({ mode = micMode, fixed = fixedLabel, map = screenMap,
                        state = state, serverReady = serverReady, devices = deviceCache })
  end,
}
