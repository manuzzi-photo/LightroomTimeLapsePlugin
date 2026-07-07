--[[----------------------------------------------------------------------------
PreviewBuilder.lua — builds a fast low-resolution preview MP4.

Frames come from the catalog previews (photo:requestJpegThumbnail), not from
a full export, so the preview is ready in seconds. It reflects frame rate,
crop/letterbox and deflicker; it does not reflect final codec quality or HDR.
------------------------------------------------------------------------------]]

local LrTasks = import 'LrTasks'
local LrFileUtils = import 'LrFileUtils'
local LrPathUtils = import 'LrPathUtils'

local FFmpegCommand = require 'FFmpegCommand'
local FFmpegRunner = require 'FFmpegRunner'
local Log = require 'Log'

local PreviewBuilder = {}

local THUMBNAIL_TIMEOUT = 15 -- seconds per photo

-- Only one preview is ever "current"; the previous one's scratch folder
-- (frame JPEGs + preview.mp4, in the system temp directory) is no longer
-- needed once a new one is requested.
local lastPreviewDir = nil

-- Deletes the last preview's scratch folder, if any. Safe to call even
-- while the previous preview.mp4 is still open in the system video player
-- (deleting an open file just unlinks it; the player keeps playing).
-- Called before building a new preview, and when the creation dialog closes
-- (see TimelapseDialog.lua) and when Lightroom quits (see ShutdownApp.lua,
-- which instead wipes the whole temp root in case this was never reached).
function PreviewBuilder.cleanup()
	if lastPreviewDir and LrFileUtils.exists(lastPreviewDir) then
		LrFileUtils.delete(lastPreviewDir)
	end
	lastPreviewDir = nil
end

-- opts:
--   photos        (array of LrPhoto, sorted)
--   targetW/H     (number)  final video dimensions (for the aspect)
--   shortSide     (number)  480 or 240
--   fps           (number)
--   fit           ('crop'|'pad')
--   deflicker     (boolean), deflickerSize (number|nil)
--   ffmpegPath    (string)
--   tempRoot      (string)  existing directory for preview session folders
--   progressScope (LrProgressScope|nil)
--
-- Must be called from an async task.
-- Returns ok (boolean), outputPathOrMessage (string).
function PreviewBuilder.build(opts)
	PreviewBuilder.cleanup()

	local pw, ph = FFmpegCommand.previewDimensions(opts.targetW, opts.targetH, opts.shortSide)
	local dir = LrPathUtils.child(opts.tempRoot,
		string.format('preview_%d', os.time()))
	LrFileUtils.createAllDirectories(dir)
	lastPreviewDir = dir

	local count = 0
	for i = 1, #opts.photos do
		if opts.progressScope and opts.progressScope:isCanceled() then
			return false, 'canceled'
		end

		local photo = opts.photos[i]
		local jpegData, finished

		-- The request box matches the preview size: for crop mode ffmpeg may
		-- upscale slightly to cover the frame, which is fine for a preview.
		photo:requestJpegThumbnail(pw, ph, function(data, _)
			jpegData = data
			finished = true
		end)

		local waited = 0
		while not finished and waited < THUMBNAIL_TIMEOUT do
			LrTasks.sleep(0.05)
			waited = waited + 0.05
		end

		if type(jpegData) == 'string' and #jpegData > 0 then
			count = count + 1
			local path = LrPathUtils.child(dir, string.format('frame_%06d.jpg', count))
			local f = io.open(path, 'wb')
			if f then
				f:write(jpegData)
				f:close()
			end
		else
			Log:warn('Preview thumbnail unavailable for photo #' .. i)
		end

		if opts.progressScope then
			opts.progressScope:setPortionComplete(i, #opts.photos + 1)
		end
	end

	if count < 2 then
		return false, LOC "$$$/Timelapse/Preview/NoFrames=Could not read enough previews from the catalog."
	end

	local outputPath = LrPathUtils.child(dir, 'preview.mp4')
	local logFile = LrPathUtils.child(dir, 'ffmpeg.log')
	local outcome, _, tail = FFmpegRunner.run({
		ffmpegPath = opts.ffmpegPath,
		inputPattern = LrPathUtils.child(dir, 'frame_%06d.jpg'),
		fps = opts.fps,
		width = pw,
		height = ph,
		fit = opts.fit,
		codec = 'h264',
		crf = 28,
		encoderPreset = 'ultrafast',
		deflicker = opts.deflicker,
		deflickerSize = opts.deflickerSize,
		outputPath = outputPath,
	}, { logFile = logFile, progressScope = opts.progressScope })

	if outcome == 'canceled' then
		return false, 'canceled'
	end
	if outcome ~= 'ok' then
		return false, (tail and tail ~= '' and tail) or 'ffmpeg failed'
	end
	return true, outputPath
end

return PreviewBuilder
