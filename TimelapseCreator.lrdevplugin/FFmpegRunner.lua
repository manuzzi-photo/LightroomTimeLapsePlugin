--[[----------------------------------------------------------------------------
FFmpegRunner.lua — executes the ffmpeg command built by FFmpegCommand.

macOS/Linux: ffmpeg is launched in the background via `exec` (so the PID we
capture is ffmpeg's own, not an intermediate shell) so the encode can be
interrupted through the progress scope's cancel button. A companion task
polls ffmpeg's -progress output both to report progress and to detect
cancellation or completion. There is no captured process exit code (exec
replaces the wrapper shell before it could report one), so success is
determined by two independent signals: ffmpeg's own "progress=end" marker in
the -progress output, and the output file actually existing with content.

Windows: falls back to the old blocking, non-cancelable execution — PID-based
cancellation relies on POSIX `kill`, not implemented for Windows yet.
------------------------------------------------------------------------------]]

local LrTasks = import 'LrTasks'
local LrFileUtils = import 'LrFileUtils'

local Platform = require 'Platform'
local FFmpegCommand = require 'FFmpegCommand'
local Log = require 'Log'

local FFmpegRunner = {}

local POLL_INTERVAL = 0.3
local KILL_GRACE_PERIOD = 4.0 -- seconds to wait after SIGINT before SIGKILL (slow presets can take a few seconds to flush)
local PID_WAIT_TIMEOUT = 5.0  -- seconds to wait for the background PID file

-- Returns the last `maxBytes` of the log file (for error messages).
function FFmpegRunner.logTail(path, maxBytes)
	local content = Platform.readFile(path)
	if not content then return '' end
	if #content > maxBytes then
		content = content:sub(-maxBytes)
	end
	return content
end

local function isProcessAlive(pid)
	return Platform.execute('kill -0 ' .. pid .. ' 2>' .. Platform.nullDevice()) == 0
end

local function killProcess(pid)
	Platform.execute('kill -INT ' .. pid .. ' 2>' .. Platform.nullDevice())
	local waited = 0
	while isProcessAlive(pid) and waited < KILL_GRACE_PERIOD do
		LrTasks.sleep(0.1)
		waited = waited + 0.1
	end
	if isProcessAlive(pid) then
		Platform.execute('kill -9 ' .. pid .. ' 2>' .. Platform.nullDevice())
	end
end

local function outputHasContent(path)
	if not LrFileUtils.exists(path) then return false end
	local ok, attrs = pcall(LrFileUtils.fileAttributes, path)
	return ok and attrs and attrs.fileSize and attrs.fileSize > 0
end

local function updateProgressFromContent(content, runCfg)
	if not (runCfg.progressScope and runCfg.totalFrames and runCfg.totalFrames > 0) then return end
	local lastFrame
	for f in content:gmatch('frame=(%d+)') do lastFrame = f end
	if lastFrame then
		local done = math.min(tonumber(lastFrame), runCfg.totalFrames)
		runCfg.progressScope:setPortionComplete(done, runCfg.totalFrames)
	end
end

-- Blocking, non-cancelable fallback (Windows only).
local function runBlocking(full, runCfg)
	local finished = false
	if runCfg.progressFile and runCfg.progressScope and runCfg.totalFrames
		and runCfg.totalFrames > 0 then
		LrTasks.startAsyncTask(function()
			while not finished do
				local content = Platform.readFile(runCfg.progressFile)
				if content then updateProgressFromContent(content, runCfg) end
				LrTasks.sleep(0.5)
			end
		end, 'TimelapseCreator ffmpeg progress poller')
	end

	local status = Platform.execute(full)
	finished = true
	return status == 0, status
end

-- opts: FFmpegCommand options (see FFmpegCommand.buildArgs), plus outputPath
--       (used to verify/clean up the result) and progressFile (required for
--       cancellation support — without it, the encode cannot be canceled).
-- runCfg:
--   logFile        (string)  receives ffmpeg's stderr/stdout
--   progressScope  (LrProgressScope|nil)  call :setCancelable(true) to allow
--                  the user to interrupt the encode
--   totalFrames    (number|nil)
--
-- Returns outcome, status, detail:
--   'ok', 0, nil              on success
--   'failed', status, tail    on ffmpeg failure (tail is the log tail, may be nil)
--   'canceled', nil, nil      if the user canceled via progressScope
function FFmpegRunner.run(opts, runCfg)
	local cmd = FFmpegCommand.buildCommand(opts, Platform.isWindows)
	local redirected = cmd .. ' > ' .. Platform.quote(runCfg.logFile) .. ' 2>&1'

	if Platform.isWindows then
		local ok, status = runBlocking(redirected, runCfg)
		if ok then return 'ok', 0, nil end
		return 'failed', status, FFmpegRunner.logTail(runCfg.logFile, 2000)
	end

	local pidFile = runCfg.logFile .. '.pid'
	LrFileUtils.delete(pidFile)
	-- `exec` replaces the backgrounded subshell's process image with ffmpeg
	-- itself, so `$!` captures ffmpeg's real PID rather than the shell's.
	local wrapped = 'exec ' .. redirected .. ' & echo $! > ' .. Platform.quote(pidFile)
	Log:info('Running ffmpeg (background): ' .. wrapped)
	Platform.execute(wrapped)

	local pid
	local waited = 0
	while not pid and waited < PID_WAIT_TIMEOUT do
		local content = Platform.readFile(pidFile)
		pid = content and tonumber(content:match('%d+'))
		if not pid then
			LrTasks.sleep(0.05)
			waited = waited + 0.05
		end
	end
	LrFileUtils.delete(pidFile)
	if not pid then
		return 'failed', nil, 'Could not start ffmpeg: no process ID was captured.'
	end

	local canceled = false
	local sawProgressEnd = false
	while true do
		if runCfg.progressScope and runCfg.progressScope:isCanceled() then
			canceled = true
			killProcess(pid)
			break
		end

		if opts.progressFile then
			local content = Platform.readFile(opts.progressFile)
			if content then
				updateProgressFromContent(content, runCfg)
				if content:find('progress=end', 1, true) then
					sawProgressEnd = true
				end
			end
		end

		if sawProgressEnd or not isProcessAlive(pid) then
			break
		end
		LrTasks.sleep(POLL_INTERVAL)
	end

	if canceled then
		if opts.outputPath then LrFileUtils.delete(opts.outputPath) end
		return 'canceled', nil, nil
	end

	-- The process may have written its last progress line right as it
	-- exited; re-read once more before deciding. Callers that don't pass a
	-- progressFile (e.g. the quick preview encode) skip this requirement
	-- entirely and rely only on the output file check below.
	local requireProgressEnd = (opts.progressFile ~= nil)
	if requireProgressEnd and not sawProgressEnd then
		local content = Platform.readFile(opts.progressFile)
		if content and content:find('progress=end', 1, true) then
			sawProgressEnd = true
		end
	end

	if (sawProgressEnd or not requireProgressEnd) and outputHasContent(opts.outputPath) then
		return 'ok', 0, nil
	end

	local tail = FFmpegRunner.logTail(runCfg.logFile, 2000)
	Log:error('ffmpeg failed (process ended without a clean completion)\n' .. tail)
	return 'failed', nil, tail
end

return FFmpegRunner
