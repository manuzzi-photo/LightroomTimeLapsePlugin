--[[----------------------------------------------------------------------------
DiagnosticsMenuItem.lua — "Timelapse Diagnostics..." (Fase 0 spike).

Writes a report that answers the open questions of the project:
 1. Is ffmpeg reachable, and what does LrTasks.execute return?
 2. Does requestJpegThumbnail deliver usable preview frames, and how fast?
 3. What do the HDR develop settings look like on a selected photo?
 4. Which export formats does LrExportSession really accept (AVIF/JXL probes),
    and do undocumented HDR keys have any effect?

The report is saved next to the user's documents and revealed in the file
browser at the end. See also ExportSettingsDumpFilter.lua for the export
settings dump taken during a manual export with HDR enabled.
------------------------------------------------------------------------------]]

local LrApplication = import 'LrApplication'
local LrDialogs = import 'LrDialogs'
local LrExportSession = import 'LrExportSession'
local LrFileUtils = import 'LrFileUtils'
local LrFunctionContext = import 'LrFunctionContext'
local LrPathUtils = import 'LrPathUtils'
local LrShell = import 'LrShell'
local LrSystemInfo = import 'LrSystemInfo'
local LrTasks = import 'LrTasks'

local FFmpegCommand = require 'FFmpegCommand'
local FFmpegLocator = require 'FFmpegLocator'
local Platform = require 'Platform'
local Version = require 'Version'
local Log = require 'Log'

--------------------------------------------------------------------------------

local report = {}
local function line(fmt, ...)
	local text = select('#', ...) > 0 and string.format(fmt, ...) or fmt
	report[#report + 1] = text
	Log:info('[diag] ' .. text)
end

local function section(title)
	line('')
	line('==== %s ====', title)
end

local function fileSize(path)
	local ok, attrs = pcall(LrFileUtils.fileAttributes, path)
	if ok and attrs and attrs.fileSize then return attrs.fileSize end
	return -1
end

-- Renders one photo with the given extra export settings; reports the outcome.
local function exportProbe(label, photo, destDir, extraSettings)
	local settings = {
		LR_export_destinationType = 'specificFolder',
		LR_export_destinationPathPrefix = destDir,
		LR_export_useSubfolder = false,
		LR_collisionHandling = 'rename',
		LR_renamingTokensOn = false,
		LR_size_doConstrain = true,
		LR_size_resizeType = 'wh',
		LR_size_units = 'pixels',
		LR_size_maxWidth = 640,
		LR_size_maxHeight = 640,
		LR_format = 'JPEG',
		LR_jpeg_quality = 0.9,
		LR_export_colorSpace = 'sRGB',
		LR_minimizeEmbeddedMetadata = true,
		LR_useWatermark = false,
	}
	for k, v in pairs(extraSettings) do
		settings[k] = v
	end

	local ok, err = LrTasks.pcall(function()
		local session = LrExportSession {
			photosToExport = { photo },
			exportSettings = settings,
		}
		for _, rendition in session:renditions() do
			local success, pathOrMessage = rendition:waitForRender()
			if success and pathOrMessage then
				line('%s: OK -> %s (%d bytes)', label, pathOrMessage, fileSize(pathOrMessage))
				if not Platform.isWindows then
					-- sips reports pixel size and the embedded ICC profile:
					-- a PQ/HLG profile here would prove HDR output works.
					local out = LrPathUtils.child(destDir, 'sips_out.txt')
					Platform.execute('sips -g pixelWidth -g pixelHeight -g space -g profile '
						.. Platform.quote(pathOrMessage) .. ' > ' .. Platform.quote(out) .. ' 2>&1')
					local info = Platform.readFile(out)
					if info then
						line('%s: sips -> %s', label, (info:gsub('%s+', ' ')))
					end
					LrFileUtils.delete(out)
				end
			else
				line('%s: RENDER FAILED -> %s', label, tostring(pathOrMessage))
			end
		end
	end)
	if not ok then
		line('%s: ERROR -> %s', label, tostring(err))
	end
end

--------------------------------------------------------------------------------

LrTasks.startAsyncTask(function()
	LrFunctionContext.callWithContext('TimelapseDiagnostics', function()
		report = {}
		line('Timelapse Creator %s diagnostics — %s', Version.display, os.date())

		section('Environment')
		line('Plugin version: %s', Version.display)
		line('Lightroom: %s', LrApplication.versionString())
		local okSys, sysInfo = pcall(LrSystemInfo.summaryString)
		if okSys then line('System: %s', sysInfo) end
		line('Platform: %s', Platform.isWindows and 'Windows' or 'macOS')

		section('ffmpeg detection')
		local ffmpegPath, ffmpegVersion, ffmpegSufficient = FFmpegLocator.locate()
		if ffmpegPath then
			line('Found: %s (version %s, minimum %s: %s)', ffmpegPath, ffmpegVersion,
				FFmpegCommand.MIN_FFMPEG_VERSION, ffmpegSufficient and 'OK' or 'TOO OLD')
		else
			line('NOT FOUND. Install ffmpeg (macOS: brew install ffmpeg) or set the path in Plug-in Manager.')
		end

		section('LrTasks.execute semantics')
		local status = LrTasks.execute(Platform.isWindows and 'exit /b 7' or 'exit 7')
		line('execute("exit 7") returned: %s (0 means success; non-zero encodings differ per OS)', tostring(status))
		status = LrTasks.execute(Platform.isWindows and 'cd .' or 'true')
		line('execute(success command) returned: %s', tostring(status))

		-- Photo-dependent probes.
		local catalog = LrApplication.activeCatalog()
		local photos = catalog:getTargetPhotos()
		if photos and #photos > 0 then
			local photo = photos[1]

			section('Selected photo')
			line('Path: %s', tostring(photo:getRawMetadata('path')))
			line('fileFormat: %s', tostring(photo:getRawMetadata('fileFormat')))
			local dims = photo:getRawMetadata('croppedDimensions')
			if dims then line('croppedDimensions: %sx%s', tostring(dims.width), tostring(dims.height)) end

			section('HDR develop settings (SDK >= 13)')
			local okDs, ds = pcall(photo.getDevelopSettings, photo)
			if okDs and type(ds) == 'table' then
				line('HDREditMode: %s', tostring(ds.HDREditMode))
				line('HDRMaxValue: %s', tostring(ds.HDRMaxValue))
				line('SDRBrightness: %s', tostring(ds.SDRBrightness))
			else
				line('getDevelopSettings failed: %s', tostring(ds))
			end

			section('requestJpegThumbnail (preview pipeline)')
			local started = os.clock()
			local data, finished
			photo:requestJpegThumbnail(854, 480, function(jpeg, _)
				data = jpeg
				finished = true
			end)
			local waited = 0
			while not finished and waited < 15 do
				LrTasks.sleep(0.05)
				waited = waited + 0.05
			end
			if type(data) == 'string' and #data > 0 then
				line('OK: %d bytes in %.2f s', #data, os.clock() - started)
			else
				line('FAILED or timed out after %.0f s (data type: %s)', waited, type(data))
			end

			section('Export format probes (undocumented HDR keys)')
			local destDir = LrPathUtils.child(
				LrPathUtils.getStandardFilePath('temp'),
				string.format('TimelapseCreator_diag_%d', os.time()))
			LrFileUtils.createAllDirectories(destDir)
			line('Probe folder (inspect files manually, e.g. with exiftool): %s', destDir)

			exportProbe('JPEG baseline', photo, destDir, {})
			exportProbe('TIFF 16-bit', photo, destDir, {
				LR_format = 'TIFF', LR_export_bitDepth = 16,
				LR_export_colorSpace = 'ProPhotoRGB', LR_jpeg_quality = nil,
			})
			exportProbe('AVIF (undocumented)', photo, destDir, { LR_format = 'AVIF' })
			exportProbe('JXL (undocumented)', photo, destDir, { LR_format = 'JXL' })
			exportProbe('TIFF 16-bit + LR_export_HDR=true (speculative)', photo, destDir, {
				LR_format = 'TIFF', LR_export_bitDepth = 16,
				LR_export_colorSpace = 'ProPhotoRGB', LR_export_HDR = true,
			})
			exportProbe('JPEG + LR_export_HDR=true (speculative)', photo, destDir, {
				LR_export_HDR = true,
			})

			section('Next HDR step')
			line('Add the post-process action "Timelapse: dump export settings" in the Export')
			line('dialog, export one photo with HDR output ENABLED and one with it disabled,')
			line('and diff the two dump files to find the real HDR keys.')
		else
			line('')
			line('NOTE: select a photo before running the diagnostics to probe HDR, thumbnails and export formats.')
		end

		-- Write and reveal the report.
		local reportPath = LrPathUtils.child(
			LrPathUtils.getStandardFilePath('temp'),
			string.format('TimelapseCreator_diagnostics_%s.txt', os.date('%Y%m%d_%H%M%S')))
		local f = io.open(reportPath, 'w')
		if f then
			f:write(table.concat(report, '\n'))
			f:close()
			LrShell.revealInShell(reportPath)
		else
			LrDialogs.message('Timelapse Diagnostics', table.concat(report, '\n'), 'info')
		end
	end)
end, 'TimelapseCreator diagnostics')
