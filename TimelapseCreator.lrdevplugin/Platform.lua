--[[----------------------------------------------------------------------------
Platform.lua — OS abstraction (macOS today, Windows-ready).
Everything that depends on the host platform (shell quoting, well-known
ffmpeg locations, opening files) goes through this module.
------------------------------------------------------------------------------]]

local LrTasks = import 'LrTasks'

local FFmpegCommand = require 'FFmpegCommand'

local Platform = {}

-- WIN_ENV / MAC_ENV are globals provided by the Lightroom runtime.
Platform.isWindows = (WIN_ENV == true)

function Platform.quote(s)
	return FFmpegCommand.shellQuote(s, Platform.isWindows)
end

-- On Windows, cmd.exe strips the outer quotes of the command line, so the
-- whole command must be wrapped in an extra pair.
function Platform.wrapCommand(cmd)
	if Platform.isWindows then
		return '"' .. cmd .. '"'
	end
	return cmd
end

-- Runs a shell command, blocking only the calling task.
-- Returns the raw status from LrTasks.execute (0 means success).
function Platform.execute(cmd)
	return LrTasks.execute(Platform.wrapCommand(cmd))
end

-- Opens a file with the OS default application (e.g. the video player).
function Platform.openFile(path)
	if Platform.isWindows then
		return Platform.execute('start "" ' .. Platform.quote(path))
	end
	return Platform.execute('open ' .. Platform.quote(path))
end

function Platform.nullDevice()
	return Platform.isWindows and 'NUL' or '/dev/null'
end

-- Well-known ffmpeg install locations, probed in order.
function Platform.ffmpegCandidates()
	if Platform.isWindows then
		local programFiles = os.getenv('ProgramFiles') or 'C:\\Program Files'
		return {
			programFiles .. '\\ffmpeg\\bin\\ffmpeg.exe',
			'C:\\ffmpeg\\bin\\ffmpeg.exe',
		}
	end
	return {
		'/opt/homebrew/bin/ffmpeg', -- Homebrew on Apple Silicon
		'/usr/local/bin/ffmpeg',    -- Homebrew on Intel / manual installs
		'/usr/bin/ffmpeg',
	}
end

-- Shell command that prints the ffmpeg path found in PATH, if any.
function Platform.whichFFmpegCommand()
	return Platform.isWindows and 'where ffmpeg' or 'command -v ffmpeg'
end

-- Reads a whole file; returns its content or nil.
function Platform.readFile(path)
	local f = io.open(path, 'rb')
	if not f then return nil end
	local content = f:read('*a')
	f:close()
	return content
end

return Platform
