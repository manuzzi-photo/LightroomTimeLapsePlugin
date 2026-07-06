--[[----------------------------------------------------------------------------
FFmpegRunner.lua — executes the ffmpeg command built by FFmpegCommand.

ffmpeg output goes to a log file (LrTasks.execute cannot capture stdout).
When a progress file, a progress scope and a total frame count are provided,
a companion task polls ffmpeg's -progress output and updates the scope.
Note: a running encode cannot be canceled from Lightroom in this version.
------------------------------------------------------------------------------]]

local LrTasks = import 'LrTasks'

local Platform = require 'Platform'
local FFmpegCommand = require 'FFmpegCommand'
local Log = require 'Log'

local FFmpegRunner = {}

-- Returns the last `maxBytes` of the log file (for error messages).
function FFmpegRunner.logTail(path, maxBytes)
	local content = Platform.readFile(path)
	if not content then return '' end
	if #content > maxBytes then
		content = content:sub(-maxBytes)
	end
	return content
end

-- opts: FFmpegCommand options (see FFmpegCommand.buildArgs).
-- runCfg:
--   logFile        (string)  receives ffmpeg's stderr/stdout
--   progressScope  (LrProgressScope|nil)
--   totalFrames    (number|nil)
-- Returns ok (boolean), status (number), errorTail (string|nil).
function FFmpegRunner.run(opts, runCfg)
	local cmd = FFmpegCommand.buildCommand(opts, Platform.isWindows)
	local full = cmd .. ' > ' .. Platform.quote(runCfg.logFile) .. ' 2>&1'
	Log:info('Running ffmpeg: ' .. full)

	local finished = false
	if opts.progressFile and runCfg.progressScope and runCfg.totalFrames
		and runCfg.totalFrames > 0 then
		LrTasks.startAsyncTask(function()
			while not finished do
				local content = Platform.readFile(opts.progressFile)
				if content then
					local lastFrame
					for f in content:gmatch('frame=(%d+)') do lastFrame = f end
					if lastFrame then
						local done = math.min(tonumber(lastFrame), runCfg.totalFrames)
						runCfg.progressScope:setPortionComplete(done, runCfg.totalFrames)
					end
				end
				LrTasks.sleep(0.5)
			end
		end, 'TimelapseCreator ffmpeg progress poller')
	end

	local status = Platform.execute(full)
	finished = true

	if status ~= 0 then
		local tail = FFmpegRunner.logTail(runCfg.logFile, 2000)
		Log:error('ffmpeg failed with status ' .. tostring(status) .. '\n' .. tail)
		return false, status, tail
	end
	return true, 0, nil
end

return FFmpegRunner
