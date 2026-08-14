-- dictate.lua — local push-to-talk dictation (see SPEC.md)
-- Hold the PTT key (default: fn/Globe) to record; release to transcribe via a
-- local whisper-server and paste the result into the frontmost app.
-- The menu bar icon is also the mic selector: pick a fixed device, or
-- "Auto — follow focused screen" with per-screen mic assignments.

local config = dofile(os.getenv("HOME") .. "/.dictate/config.lua")

local WAV = os.getenv("HOME") .. "/.dictate/tmp/rec.wav"

-- flagsChanged keycodes for modifier keys usable alone as push-to-talk.
-- This table is the full set of supported hotkeys. rawMask is the
-- device-SPECIFIC flag bit (IOKit IOLLEvent.h NX_DEVICE*KEYMASK): the
-- aggregate flags ("alt") can't tell right Option's release from left Option
-- still being held, which would leave the mic recording.
local PTT_KEYS = {
  fn        = { keycode = 63, rawMask = 0x800000 }, -- NX_SECONDARYFNMASK (no L/R twin)
  rightalt  = { keycode = 61, rawMask = 0x40     }, -- NX_DEVICERALTKEYMASK
  rightcmd  = { keycode = 54, rawMask = 0x10     }, -- NX_DEVICERCMDKEYMASK
  rightctrl = { keycode = 62, rawMask = 0x2000   }, -- NX_DEVICERCTLKEYMASK
}
local ptt = PTT_KEYS[config.hotkey] -- validated below, after log() exists

-- ---------------------------------------------------------------- logging

local function log(msg)
  local f = io.open(config.log_file, "a")
  if f then
    f:write(os.date("%Y-%m-%d %H:%M:%S ") .. msg .. "\n")
    f:close()
  end
end

-- The ONLY way to SIGKILL a task's process: pid() returns 0 for a
-- never-started task and "kill -9 0" would take out Hammerspoon's whole
-- process group; capturing the pid once also avoids racing an exit into a
-- recycled pid. (Measured: pid() stays at the stale pid after exit, so the
-- isRunning gate is what keeps us off dead/recycled pids.)
local function killTask(task)
  if not task then return end
  local pid = task:pid()
  if task:isRunning() and pid and pid > 0 then
    hs.execute("/bin/kill -9 " .. tostring(pid))
  end
end

-- Fail CLOSED on an invalid hotkey: silently falling back to fn would arm the
-- microphone on a key the user never chose, while the ready alert displayed
-- the value they typed. No hotkey, no dictation, loud message.
if not ptt then
  local msg = 'Dictation disabled: invalid hotkey "' .. tostring(config.hotkey)
              .. '" in ~/.dictate/config.lua — valid: fn, rightalt, rightcmd, rightctrl'
  log(msg)
  hs.alert.show(msg, 6)
  return { disabled = true }
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

-- Device hot-plug detection WITHOUT owning the hs.audiodevice.watcher
-- singleton (setting its callback destroys any handler an existing config
-- registered — undetectably when theirs was set but not started). Poll a
-- cheap CoreAudio device signature (~0.04ms) and run the real ffmpeg
-- enumeration only when it changes.
local deviceSig = ""
local function deviceSignature()
  local ids = {}
  for _, d in ipairs(hs.audiodevice.allInputDevices()) do
    ids[#ids + 1] = d:uid() or d:name()
  end
  table.sort(ids)
  return table.concat(ids, "|")
end
-- Ordinal labels "(1)/(2)" reflect enumeration order, not physical identity,
-- and no cross-API identity exists (ffmpeg exposes no UIDs; CoreAudio and
-- AVFoundation demonstrably order devices differently). What IS observable is
-- the twin group's UID SET, so we detect a twin being REPLACED (sorted-set
-- compare: no false alerts from meaningless order changes). An order flip
-- among the same physical twins is provably undetectable in this stack —
-- calibration is the only ground truth, and the README says so.
local warnedCalibration = false

local function sortedUidSet(s)
  local t = {}
  for u in s:gmatch("[^|]+") do t[#t + 1] = u end
  table.sort(t)
  return table.concat(t, "|")
end

-- The twin group under protection is the one the screen map was calibrated
-- for — derived from its labels ("Studio Display Microphone (2)" → base name)
-- rather than "any duplicated name", which would be nondeterministic if two
-- different duplicate groups ever coexist.
local function calibratedGroupName()
  for _, label in pairs(screenMap) do
    return (label:gsub("%s%(%d+%)$", ""))
  end
  return nil
end

local function currentTwinUidSet()
  local want = calibratedGroupName()
  if not want then return nil end
  local uids = {}
  for _, d in ipairs(hs.audiodevice.allInputDevices()) do
    if (d:name() or "?") == want then uids[#uids + 1] = d:uid() or "?" end
  end
  if #uids < 2 then return nil end -- twins absent right now (asleep/unplugged)
  table.sort(uids)
  return table.concat(uids, "|")
end

local function checkCalibrationIdentity()
  if warnedCalibration or micMode ~= "auto" or next(screenMap) == nil then return end
  local current = currentTwinUidSet()
  if not current then return end
  local stored = hs.settings.get("dictate.calibration_uids")
  if not stored or stored == "" then
    -- calibration predates UID tracking; the user has validated the current
    -- pairing by living with it, so adopt the present set as the baseline
    hs.settings.set("dictate.calibration_uids", current)
    log("calibration baseline captured retroactively: " .. current)
    return
  end
  if current ~= sortedUidSet(stored) then
    warnedCalibration = true
    hs.alert.show("Dictation: display mics changed since calibration — re-run calibrate.sh")
    log("calibration identity mismatch: stored=" .. stored .. " current=" .. current)
  end
end

local deviceWatch = hs.timer.doEvery(2, function()
  local sig = deviceSignature()
  if sig ~= deviceSig then
    deviceSig = sig
    refreshDevices()
    checkCalibrationIdentity()
  end
end)

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

-- forward declarations: safely() must be able to kill a live recorder and a
-- live CLI transcriber, but both are assigned in sections further down;
-- without these the references inside safely would silently resolve to nil
-- globals
local recTask
local cliTask

-- Disarm-then-kill for the CLI transcriber: nil FIRST so its identity-guarded
-- callback no-ops instead of pasting a stale transcript after a reset
local function disarmCliTask()
  local t = cliTask
  cliTask = nil
  killTask(t)
end

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
    pcall(killTask, recTask)
    pcall(disarmCliTask)
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
local serverReady = false -- set only after the HTTP probe AND ownership check pass
local serverPort = config.server_port -- actual bound port; re-picked per launch
local portRerolls = 0

local function serverUrl(path)
  return string.format("http://127.0.0.1:%d%s", serverPort, path)
end

local startServer -- forward declaration (restartServer/verifyOwnership recurse into it)

-- A dead or hung server must be REPLACED, not re-entered: startServer's
-- early-return sees a hung server as running, and isRunning() reads a stale
-- true ~60% of the time right after a kill — so drop the handle entirely.
local function restartServer()
  serverReady = false
  if serverTask then
    killTask(serverTask) -- SIGKILL: hung servers ignore SIGTERM
    serverTask = nil -- orphan the handle; its callbacks identity-check and no-op
  end
  startServer()
end

-- Readiness is proven in two identity-guarded steps: (1) the HTTP endpoint
-- answers, (2) lsof shows OUR pid as the port's only listener. The second
-- step matters because whisper-server sets SO_REUSEPORT: a rival server can
-- share the port, answer the probe, and receive the audio (verified — the
-- last binder takes all new connections).
local function verifyOwnership(owner)
  local t = hs.task.new("/usr/sbin/lsof", function(_, out)
    if serverTask ~= owner then return end -- stale chain from a replaced server
    local pids = {}
    for p in (out or ""):gmatch("p(%d+)") do pids[#pids + 1] = tonumber(p) end
    if #pids == 1 and pids[1] == owner:pid() then
      portRerolls = 0
      serverReady = true
      log(string.format("whisper-server ready on port %d (pid %d)", serverPort, pids[1]))
    elseif portRerolls < 3 then
      portRerolls = portRerolls + 1
      log(string.format("port %d ownership check failed (%d listeners) — re-rolling port",
                        serverPort, #pids))
      restartServer()
    else
      hs.alert.show("Dictation: no usable server port — dictation disabled")
      log("giving up after " .. portRerolls .. " port re-rolls")
    end
  end, { "-nP", "-iTCP:" .. serverPort, "-sTCP:LISTEN", "-Fp" })
  if not t:start() then log("ownership check failed to launch") end
end

-- The server prints "listening at" to stdout, but stdout is FULLY BUFFERED
-- into a pipe (verified: 0 bytes arrive for 24s), so readiness can't be read
-- from the stream — poll the HTTP endpoint until a wall-clock deadline
-- (cold starts have taken 7+s for Metal shader compilation).
local function probeServer(owner, deadline)
  if serverTask ~= owner or not owner:isRunning() then return end
  local t = hs.task.new("/usr/bin/curl", function(code, out)
    if serverTask ~= owner then return end
    if code == 0 and out == "200" then
      verifyOwnership(owner)
    elseif hs.timer.secondsSinceEpoch() < deadline then
      hs.timer.doAfter(0.5, function() probeServer(owner, deadline) end)
    else
      log("whisper-server never became ready on port " .. serverPort)
    end
  end, { "-q", "-s", "--noproxy", "*", -- proxy-immune, same as the upload
         "-o", "/dev/null", "-w", "%{http_code}", "--max-time", "2",
         serverUrl("/") })
  if not t:start() then log("readiness probe failed to launch") end
end

startServer = function()
  if serverTask and serverTask:isRunning() then return end
  -- SIGKILL orphans of OURS from a crash — matched by our model directory,
  -- any port, since ports are per-launch; write-blocked orphans ignore milder
  hs.execute([[/usr/bin/pkill -9 -f "whisper-server.*[.]dictate.*--port"]])
  serverReady = false
  -- fresh random port per launch: makes accidentally sharing a port with
  -- another whisper-server (SO_REUSEPORT) improbable instead of silent
  serverPort = config.server_port + math.random(1, 99)
  local thisTask -- declared BEFORE assignment so the callbacks capture THIS name
  thisTask = hs.task.new(config.server_bin, function(code, _, err)
    if serverTask ~= thisTask then return end -- stale callback from a replaced server
    serverReady = false
    if code ~= 0 then log("whisper-server exited " .. tostring(code) .. ": " .. (err or "")) end
  end, function(_, _, stderr)
    -- draining is load-bearing: hs.task only reads a long-lived task's output
    -- when a streaming callback is set — without one the 64KiB stderr pipe
    -- fills after ~170 requests and the server write-blocks forever.
    -- stderr (unlike stdout) arrives promptly, so bind failures surface here.
    if stderr and stderr:find("couldn't bind", 1, true) then
      hs.alert.show("Dictation: server couldn't bind port " .. serverPort
                    .. " — will pick another on the next dictation")
    end
    return true -- keep streaming
  end, {
    "-m", config.model_path,
    "--host", "127.0.0.1",
    "--port", tostring(serverPort),
    "-t", "4",
    "-sns", -- suppress non-speech tokens
  })
  serverTask = thisTask
  if thisTask:start() then
    log("whisper-server started on port " .. serverPort)
    probeServer(thisTask, hs.timer.secondsSinceEpoch() + 20)
  else
    serverTask = nil
    log("whisper-server failed to launch: " .. tostring(config.server_bin))
  end
end

local function stopServer()
  killTask(serverTask) -- SIGKILL: a hung server ignores SIGTERM
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
    local ours = hs.pasteboard.changeCount()
    hs.eventtap.keyStroke({ "cmd" }, "v", 30000)
    -- restore the previous pasteboard (all types, so images survive) — but
    -- only while it still holds OUR transcript: if anything copied since
    -- (changeCount moved), restoring would destroy that newer value
    hs.timer.doAfter(config.restore_delay_ms / 1000, function()
      pcall(function()
        if hs.pasteboard.changeCount() ~= ours then return end
        -- content check backs up changeCount: a writer landing in the
        -- microseconds before we sampled it would otherwise count as us
        if hs.pasteboard.getContents() ~= text then return end
        if saved and next(saved) ~= nil then
          hs.pasteboard.writeAllData(nil, saved)
        else
          -- clipboard was empty before (readAllData returns {}): clear it
          -- rather than leaving the transcript behind
          hs.pasteboard.clearContents()
        end
      end)
    end)
  else
    -- another owner took the pasteboard mid-write: their value is NEWER than
    -- our saved copy — type the text and leave the clipboard alone entirely
    log("pasteboard setContents failed (ownership changed) — typing instead")
    hs.eventtap.keyStrokes(text)
  end
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

-- Wait (bounded) for the server to become ready before uploading — a single
-- fixed-delay retry loses to slow cold starts; this covers them up to the
-- deadline and then fails closed. isRetry passes through unchanged so that
-- merely waiting on a cold start doesn't consume the one transport retry.
local function waitForReady(wav, deadline, isRetry)
  if serverReady and serverTask and serverTask:isRunning() then
    return transcribe(wav, isRetry)
  end
  if hs.timer.secondsSinceEpoch() >= deadline then
    if serverTask and serverTask:isRunning() and not serverReady then
      -- a server that blew its readiness deadline is presumed hung; leaving
      -- it running would make every future dictation re-probe the same
      -- dead-end process forever
      log("server missed readiness deadline — replacing it")
      restartServer()
    end
    return failRun("transcription server unavailable",
                   "not ready on port " .. serverPort)
  end
  hs.timer.doAfter(0.5, function() waitForReady(wav, deadline, isRetry) end)
end

local function transcribeCli(wav)
  local thisTask -- declared first so the callback captures THIS name
  thisTask = hs.task.new(config.cli_bin, safely(function(code, out, err)
    if cliTask ~= thisTask then return end -- superseded by a recovery reset
    cliTask = nil
    if code == 0 then handleTranscript(out)
    else failRun("whisper-cli failed (" .. tostring(code) .. ")", err) end
  end, "cli-transcribe"), { "-m", config.model_path, "-f", wav, "--no-timestamps",
         "-l", config.language, "-t", "4" })
  cliTask = thisTask
  if not thisTask:start() then
    cliTask = nil
    return failRun("whisper-cli failed to launch", tostring(config.cli_bin))
  end
  -- bounded: an unwedged run finishes in seconds; without a cap a wedged CLI
  -- would outlive the stuck guard's reset and paste stale text much later
  hs.timer.doAfter(90, function()
    if cliTask == thisTask and thisTask:isRunning() then
      log("whisper-cli timed out after 90s — killing")
      killTask(thisTask) -- callback still identity-matches and runs failRun
    end
  end)
end

transcribe = function(wav, isRetry)
  setState("transcribing")
  if config.transcribe_mode == "cli" then return transcribeCli(wav) end
  -- fail closed: never upload audio unless OUR server is alive and confirmed
  -- the sole owner of its port — whisper-server sets SO_REUSEPORT, so a rival
  -- server can otherwise receive the recording and have its response pasted
  if not (serverTask and serverTask:isRunning() and serverReady) then
    if isRetry then
      return failRun("transcription server unavailable",
                     "port " .. serverPort .. " not ready")
    end
    portRerolls = 0 -- fresh re-roll budget for this attempt
    if serverTask and serverTask:isRunning() then
      -- still starting: re-kick the (possibly expired) probe chain, don't kill it
      probeServer(serverTask, hs.timer.secondsSinceEpoch() + 15)
    else
      startServer()
    end
    return waitForReady(wav, hs.timer.secondsSinceEpoch() + 15, isRetry)
  end
  local t = hs.task.new("/usr/bin/curl", safely(function(code, out, err)
    if code == 0 then
      handleTranscript(out)
    elseif (code == 7 or code == 28) and not isRetry then
      -- 7: connection refused (server died). 28: timeout — a hung server
      -- keeps its port LISTENing so refused can never fire. Either way the
      -- old process is useless: force-replace it (plain startServer would
      -- no-op on a still-running-but-hung task).
      log("server unreachable (curl exit " .. tostring(code) .. "), force-restarting")
      restartServer()
      waitForReady(wav, hs.timer.secondsSinceEpoch() + 15, true)
    else
      -- with --fail-with-body the server's error body arrives on stdout
      failRun("transcription failed (curl exit " .. tostring(code) .. ")",
              (out ~= nil and out ~= "" and out) or err)
    end
  end, "transcribe"), {
         -- -q (MUST be first) skips ~/.curlrc and --noproxy "*" ignores proxy
         -- env vars: curl has no loopback exemption, so either could reroute
         -- the WAV through a proxy — verified live (privacy guarantee).
         -- --fail-with-body: HTTP >= 400 exits 22 instead of pasting the error
         -- body as a transcript; connection-refused stays exit 7 for the retry.
         -- token_timestamps=false: server default since v1.8.4 wraps segments at
         -- 60 chars on TOKEN boundaries, splitting words (whisper.cpp #3968);
         -- note max_len=0 is NOT a fix — the server maps 0 back to 60.
         "-q", "-s", "--noproxy", "*",
         "--fail-with-body", "--max-time", "30", serverUrl("/inference"),
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
      killTask(t)
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
    local raw = hs.eventtap.checkKeyboardModifiers(true)._raw or 0
    if pttDown and (raw & ptt.rawMask) == 0 then
      log("watchdog: missed keyup, stopping recording")
      pttDown = false
      stopRecording()
    end
  end)
end

-- ---------------------------------------------------------------- hotkey

flagsTap = hs.eventtap.new({ hs.eventtap.event.types.flagsChanged }, safely(function(e)
  if e:getKeyCode() ~= ptt.keycode then return false end
  local isDown = (e:getRawEventData().CGEventData.flags & ptt.rawMask) ~= 0
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
    pcall(killTask, recTask)
    pcall(disarmCliTask)
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
deviceSig = deviceSignature() -- baseline so the poll doesn't fire a redundant refresh
checkCalibrationIdentity()
startServer()
menubar:setMenu(buildMenu)
flagsTap:start()
keyTap:start()
setState("idle")
local priorShutdown = hs.shutdownCallback -- chain another module's handler, don't clobber it
hs.shutdownCallback = function()
  -- runs on quit AND on config reload: never abandon a live recorder or
  -- transcriber — after a reload nothing drains their pipes and no Lua state
  -- can reach them
  pcall(killTask, recTask)
  pcall(disarmCliTask)
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
  deviceWatch = deviceWatch,
  debug = function()
    return hs.inspect({ mode = micMode, fixed = fixedLabel, map = screenMap,
                        state = state, serverReady = serverReady,
                        serverPort = serverPort, devices = deviceCache })
  end,
}
