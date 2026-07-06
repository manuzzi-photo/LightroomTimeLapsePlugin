--[[----------------------------------------------------------------------------
FrameExporter.lua — renders the selected photos to a numbered image sequence
using LrExportSession, so that every frame carries the develop settings.

Rendered files are renamed to frame_000001.ext, frame_000002.ext, … in
selection order; the sequence stays contiguous even if some renditions fail.
------------------------------------------------------------------------------]]

local LrExportSession = import 'LrExportSession'
local LrFileUtils = import 'LrFileUtils'
local LrPathUtils = import 'LrPathUtils'

local Log = require 'Log'

local FrameExporter = {}

-- params:
--   photos         (array of LrPhoto, already sorted)
--   width, height  (number)  export box (fit-within), from computeExportSize
--   destDir        (string)  existing directory that receives the frames
--   format         ('JPEG'|'TIFF16')  TIFF16 is reserved for the HDR pipeline
--   quality        (number|nil) JPEG quality 0..1, default 0.95
--   progressScope  (LrProgressScope|nil)
--
-- Must be called from an async task.
-- Returns { pattern, count, framePaths, failures, canceled, ext }.
function FrameExporter.export(params)
	local settings = {
		LR_export_destinationType = 'specificFolder',
		LR_export_destinationPathPrefix = params.destDir,
		LR_export_useSubfolder = false,
		LR_collisionHandling = 'rename',
		LR_renamingTokensOn = false,
		LR_size_doConstrain = true,
		LR_size_resizeType = 'wh',
		LR_size_units = 'pixels',
		LR_size_maxWidth = params.width,
		LR_size_maxHeight = params.height,
		LR_size_doNotEnlarge = false,
		LR_size_resolution = 72,
		LR_size_resolutionUnits = 'inch',
		LR_outputSharpeningOn = false,
		LR_minimizeEmbeddedMetadata = true,
		LR_removeLocationMetadata = true,
		LR_includeVideoFiles = false,
		LR_useWatermark = false,
	}

	local ext
	if params.format == 'TIFF16' then
		settings.LR_format = 'TIFF'
		settings.LR_export_bitDepth = 16
		settings.LR_export_colorSpace = 'ProPhotoRGB'
		ext = 'tif'
	else
		settings.LR_format = 'JPEG'
		settings.LR_jpeg_quality = params.quality or 0.95
		settings.LR_export_colorSpace = 'sRGB'
		ext = 'jpg'
	end

	local session = LrExportSession {
		photosToExport = params.photos,
		exportSettings = settings,
	}

	local total = session:countRenditions()
	local framePaths, failures = {}, {}
	local sequence = 0
	local canceled = false

	for i, rendition in session:renditions { stopIfCanceled = true } do
		if params.progressScope and params.progressScope:isCanceled() then
			canceled = true
			break
		end

		local success, pathOrMessage = rendition:waitForRender()
		if success and pathOrMessage then
			sequence = sequence + 1
			local target = LrPathUtils.child(params.destDir,
				string.format('frame_%06d.%s', sequence, ext))
			if pathOrMessage ~= target then
				if LrFileUtils.exists(target) then
					LrFileUtils.delete(target)
				end
				LrFileUtils.move(pathOrMessage, target)
			end
			framePaths[#framePaths + 1] = target
		else
			failures[#failures + 1] = tostring(pathOrMessage or 'unknown render error')
			Log:warn('Rendition failed: ' .. tostring(pathOrMessage))
		end

		if params.progressScope then
			params.progressScope:setPortionComplete(i, total)
		end
	end

	return {
		pattern = LrPathUtils.child(params.destDir, 'frame_%06d.' .. ext),
		count = #framePaths,
		framePaths = framePaths,
		failures = failures,
		canceled = canceled,
		ext = ext,
	}
end

return FrameExporter
