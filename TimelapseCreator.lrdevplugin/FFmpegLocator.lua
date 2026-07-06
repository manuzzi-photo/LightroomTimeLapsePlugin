--[[----------------------------------------------------------------------------
FFmpegLocator.lua — finds and validates the ffmpeg binary.
Search order: user preference → well-known locations → shell PATH lookup.
------------------------------------------------------------------------------]]

local LrFileUtils = import 'LrFileUtils'
local LrPathUtils = import 'LrPathUtils'
local LrPrefs = import 'LrPrefs'

local Platform = require 'Platform'
local Log = require 'Log'

local FFmpegLocator = {}

local function tempChild(name)
	return LrPathUtils.child(LrPathUtils.getStandardFilePath('temp'), name)
end

-- Runs `ffmpeg -version` and returns the version string (e.g. "8.0.1"),
-- or nil if the binary is missing or not runnable.
function FFmpegLocator.validate(path)
	if type(path) ~= 'string' or path == '' or not LrFileUtils.exists(path) then
		return nil
	end
	local out = tempChild('TimelapseCreator_ffmpeg_version.txt')
	Platform.execute(Platform.quote(path) .. ' -version > ' .. Platform.quote(out) .. ' 2>&1')
	local content = Platform.readFile(out) or ''
	LrFileUtils.delete(out)
	return content:match('ffmpeg version%s+(%S+)')
end

-- Returns path, version — or nil, nil when ffmpeg cannot be found.
function FFmpegLocator.locate()
	local prefs = LrPrefs.prefsForPlugin()

	if prefs.ffmpegPath and prefs.ffmpegPath ~= '' then
		local version = FFmpegLocator.validate(prefs.ffmpegPath)
		if version then
			return prefs.ffmpegPath, version
		end
		Log:warn('Saved ffmpeg path is no longer valid: ' .. tostring(prefs.ffmpegPath))
	end

	for _, candidate in ipairs(Platform.ffmpegCandidates()) do
		if LrFileUtils.exists(candidate) then
			local version = FFmpegLocator.validate(candidate)
			if version then
				return candidate, version
			end
		end
	end

	-- Last resort: ask the shell. Lightroom's environment may have a reduced
	-- PATH, so this can fail even when ffmpeg works in a terminal.
	local out = tempChild('TimelapseCreator_ffmpeg_which.txt')
	Platform.execute(Platform.whichFFmpegCommand()
		.. ' > ' .. Platform.quote(out) .. ' 2>' .. Platform.nullDevice())
	local content = Platform.readFile(out) or ''
	LrFileUtils.delete(out)
	local found = content:match('^%s*(.-)%s*[\r\n]') or content:match('^%s*(.-)%s*$')
	if found and found ~= '' then
		local version = FFmpegLocator.validate(found)
		if version then
			return found, version
		end
	end

	return nil, nil
end

function FFmpegLocator.saveUserPath(path)
	local prefs = LrPrefs.prefsForPlugin()
	prefs.ffmpegPath = path
end

return FFmpegLocator
