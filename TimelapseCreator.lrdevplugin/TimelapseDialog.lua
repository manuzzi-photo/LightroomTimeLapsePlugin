--[[----------------------------------------------------------------------------
TimelapseDialog.lua — main options dialog and generation pipeline.

Flow: MenuItem.lua gathers/sorts the photos, then calls show(). On OK the
pipeline exports the frames with LrExportSession and encodes them with ffmpeg.
The Preview button builds a fast low-res MP4 from catalog previews and opens
it in the system player (LrView has no embedded video playback).
------------------------------------------------------------------------------]]

local LrView = import 'LrView'
local LrDialogs = import 'LrDialogs'
local LrBinding = import 'LrBinding'
local LrTasks = import 'LrTasks'
local LrPathUtils = import 'LrPathUtils'
local LrFileUtils = import 'LrFileUtils'
local LrPrefs = import 'LrPrefs'
local LrProgressScope = import 'LrProgressScope'
local LrShell = import 'LrShell'

local FFmpegCommand = require 'FFmpegCommand'
local FFmpegLocator = require 'FFmpegLocator'
local FFmpegRunner = require 'FFmpegRunner'
local FrameExporter = require 'FrameExporter'
local PreviewBuilder = require 'PreviewBuilder'
local Platform = require 'Platform'
local Log = require 'Log'

local TimelapseDialog = {}

local RESOLUTIONS = {
	{ value = '720p',  title = LOC "$$$/Timelapse/Res/720=720p (HD)",        w = 1280, h = 720 },
	{ value = '1080p', title = LOC "$$$/Timelapse/Res/1080=1080p (Full HD)", w = 1920, h = 1080 },
	{ value = '2160p', title = LOC "$$$/Timelapse/Res/2160=2160p (4K UHD)",  w = 3840, h = 2160 },
}

local FPS_VALUES = { 24, 25, 30, 60 }

--------------------------------------------------------------------------------

local function targetDims(props)
	local w, h = 1920, 1080
	for _, r in ipairs(RESOLUTIONS) do
		if r.value == props.resolution then
			w, h = r.w, r.h
			break
		end
	end
	if props.orientation == 'portrait' then
		return h, w
	end
	return w, h
end

local function effectiveFps(props)
	if props.fps == 'custom' then
		return tonumber(props.customFps) or 30
	end
	return tonumber(props.fps) or 30
end

local function sanitizeFileName(name)
	name = tostring(name or ''):gsub('[/\\:%*%?"<>|]', '-'):gsub('^%s+', ''):gsub('%s+$', '')
	if name == '' then
		name = 'timelapse_' .. os.date('%Y%m%d_%H%M%S')
	end
	if not name:lower():match('%.mp4$') then
		name = name .. '.mp4'
	end
	return name
end

local function tempRoot()
	local root = LrPathUtils.child(LrPathUtils.getStandardFilePath('temp'), 'TimelapseCreator')
	LrFileUtils.createAllDirectories(root)
	return root
end

local function defaultOutputFolder()
	local ok, path = pcall(LrPathUtils.getStandardFilePath, 'pictures')
	if ok and path then return path end
	return LrPathUtils.getStandardFilePath('home')
end

--------------------------------------------------------------------------------
-- Preferences (remembered between sessions)

local REMEMBERED = {
	'resolution', 'orientation', 'fit', 'fps', 'customFps', 'codec', 'qualityPreset',
	'deflicker', 'deflickerSize', 'previewRes', 'outputFolder',
}

local function loadPrefs(props)
	local prefs = LrPrefs.prefsForPlugin()
	for _, key in ipairs(REMEMBERED) do
		if prefs['ui_' .. key] ~= nil then
			props[key] = prefs['ui_' .. key]
		end
	end
end

local function savePrefs(props)
	local prefs = LrPrefs.prefsForPlugin()
	for _, key in ipairs(REMEMBERED) do
		prefs['ui_' .. key] = props[key]
	end
end

--------------------------------------------------------------------------------
-- Generation pipeline (runs after the dialog is confirmed)

local function runGeneration(props, photos, aspects)
	local targetW, targetH = targetDims(props)
	local outputPath = LrPathUtils.child(props.outputFolder, sanitizeFileName(props.fileName))

	if LrFileUtils.exists(outputPath) then
		local answer = LrDialogs.confirm(
			LOC "$$$/Timelapse/Overwrite/Title=The output file already exists",
			outputPath,
			LOC "$$$/Timelapse/Overwrite/Action=Overwrite",
			LOC "$$$/Timelapse/Cancel=Cancel")
		if answer ~= 'ok' then return end
	end

	local sessionDir = LrPathUtils.child(tempRoot(), string.format('session_%d', os.time()))
	LrFileUtils.createAllDirectories(sessionDir)

	-- Phase 1: render the frames with the develop settings applied.
	local exportW, exportH = FFmpegCommand.computeExportSize(targetW, targetH, aspects, props.fit)
	local exportScope = LrProgressScope {
		title = LOC("$$$/Timelapse/Progress/Export=Timelapse: exporting ^1 frames...", #photos),
	}
	exportScope:setCancelable(true)
	local result
	local exportOk, exportErr = LrTasks.pcall(function()
		result = FrameExporter.export {
			photos = photos,
			width = exportW,
			height = exportH,
			destDir = sessionDir,
			format = 'JPEG',
			progressScope = exportScope,
		}
	end)
	exportScope:done()

	if not exportOk then
		LrFileUtils.delete(sessionDir)
		LrDialogs.message(LOC "$$$/Timelapse/Error/ExportFailed=Frame export failed",
			tostring(exportErr), 'critical')
		return
	end
	if result.canceled then
		LrFileUtils.delete(sessionDir)
		return
	end
	if result.count < 2 then
		LrFileUtils.delete(sessionDir)
		LrDialogs.message(LOC "$$$/Timelapse/Error/NoFrames=Not enough frames were rendered",
			table.concat(result.failures, '\n'), 'critical')
		return
	end
	if #result.failures > 0 then
		Log:warn(#result.failures .. ' rendition(s) failed; continuing with ' .. result.count)
	end

	-- Phase 2: encode with ffmpeg.
	local quality = FFmpegCommand.resolveQualityPreset(props.qualityPreset, props.codec)
	local crf = tonumber(props.crf) or quality.crf
	local encoderPreset = props.encoderPreset or quality.preset

	local encodeScope = LrProgressScope {
		title = LOC("$$$/Timelapse/Progress/Encode=Timelapse: encoding ^1 frames with ffmpeg...", result.count),
	}
	local ok, status, tail = FFmpegRunner.run({
		ffmpegPath = props.ffmpegPath,
		inputPattern = result.pattern,
		fps = effectiveFps(props),
		width = targetW,
		height = targetH,
		fit = props.fit,
		codec = props.codec,
		crf = crf,
		encoderPreset = encoderPreset,
		keyintMin = tonumber(props.keyintMin),
		keyintMax = tonumber(props.keyintMax),
		maxBitrate = tonumber(props.maxBitrate),
		deflicker = props.deflicker,
		deflickerSize = tonumber(props.deflickerSize),
		progressFile = LrPathUtils.child(sessionDir, 'progress.txt'),
		outputPath = outputPath,
	}, {
		logFile = LrPathUtils.child(sessionDir, 'ffmpeg.log'),
		progressScope = encodeScope,
		totalFrames = result.count,
	})
	encodeScope:done()

	if not ok then
		-- Keep the session folder so the ffmpeg log can be inspected.
		LrDialogs.message(
			LOC "$$$/Timelapse/Error/EncodeFailed=ffmpeg could not encode the video",
			LOC("$$$/Timelapse/Error/EncodeFailedDetail=Exit status: ^1^nLog: ^2^n^n^3",
				tostring(status), LrPathUtils.child(sessionDir, 'ffmpeg.log'), tail or ''),
			'critical')
		return
	end

	LrFileUtils.delete(sessionDir)

	local seconds = result.count / effectiveFps(props)
	local answer = LrDialogs.confirm(
		LOC "$$$/Timelapse/Done/Title=Timelapse created",
		LOC("$$$/Timelapse/Done/Detail=^1^n^2 frames, ^3 seconds", outputPath,
			result.count, string.format('%.1f', seconds)),
		LOC "$$$/Timelapse/Done/Open=Open video",
		LOC "$$$/Timelapse/Done/Close=Close",
		LOC "$$$/Timelapse/Done/Reveal=Show in file browser")
	if answer == 'ok' then
		Platform.openFile(outputPath)
	elseif answer == 'other' then
		LrShell.revealInShell(outputPath)
	end
end

--------------------------------------------------------------------------------
-- Dialog

-- args: { photos, aspects, hdrInfo }
function TimelapseDialog.show(context, args)
	local f = LrView.osFactory()
	local bind = LrView.bind
	local photos = args.photos
	local props = LrBinding.makePropertyTable(context)

	-- Runs regardless of how the dialog is dismissed (Cancel, validation
	-- errors handled below, or a completed/failed generation).
	context:addCleanupHandler(function()
		PreviewBuilder.cleanup()
	end)

	-- Defaults (possibly overridden by saved preferences).
	props.resolution = '1080p'
	props.orientation = 'landscape'
	props.fit = 'crop'
	props.fps = 30
	props.customFps = 30
	props.codec = 'h264'
	props.qualityPreset = 'medium'
	props.showAdvanced = false
	props.deflicker = false
	props.deflickerSize = 5
	props.maxBitrate = 0
	props.previewRes = 480
	props.outputFolder = defaultOutputFolder()
	loadPrefs(props)
	props.fileName = 'timelapse_' .. os.date('%Y%m%d_%H%M%S')
	props.previewRunning = false

	-- ffmpeg detection. The path itself is now configured in Lightroom's
	-- Plug-in Manager (see PluginInfoProvider.lua); this dialog only shows
	-- a read-only status.
	local ffmpegPath, ffmpegVersion, ffmpegSufficient = FFmpegLocator.locate()
	props.ffmpegPath = ffmpegPath
	props.ffmpegVersionInsufficient = (ffmpegPath ~= nil and not ffmpegSufficient)
	if ffmpegPath then
		props.ffmpegStatus = LOC("$$$/Timelapse/FFmpeg/Found=ffmpeg ^1 — ^2", ffmpegVersion, ffmpegPath)
		props.ffmpegWarningText = LOC(
			"$$$/Timelapse/FFmpeg/TooOld=ffmpeg ^1 detected — version ^2 or newer is recommended; some features (e.g. deflicker) may not work.",
			ffmpegVersion, FFmpegCommand.MIN_FFMPEG_VERSION)
	else
		props.ffmpegStatus = LOC "$$$/Timelapse/FFmpeg/Missing=ffmpeg not found. Configure it in Lightroom's Plug-in Manager (File > Plug-in Manager > Timelapse Creator)."
		props.ffmpegWarningText = ''
	end

	-- Advanced fields follow the quality preset until edited by hand.
	local autoKeyint = {}
	local function applyQualityPreset()
		local q = FFmpegCommand.resolveQualityPreset(props.qualityPreset, props.codec)
		props.crf = q.crf
		props.encoderPreset = q.preset
	end
	local function applyKeyintDefaults()
		local fps = math.floor(effectiveFps(props) + 0.5)
		if props.keyintMin == nil or props.keyintMin == autoKeyint.min then
			props.keyintMin = fps
			autoKeyint.min = fps
		end
		if props.keyintMax == nil or props.keyintMax == autoKeyint.max then
			props.keyintMax = fps * 10
			autoKeyint.max = fps * 10
		end
	end
	applyQualityPreset()
	applyKeyintDefaults()

	local function updateSummary()
		local w, h = targetDims(props)
		local fps = effectiveFps(props)
		props.summaryText = LOC("$$$/Timelapse/Summary=^1 photos  ->  ^2 x ^3 @ ^4 fps  ->  ^5 seconds",
			#photos, w, h, fps, string.format('%.1f', #photos / fps))
	end
	updateSummary()

	props:addObserver('fps', function()
		updateSummary()
		applyKeyintDefaults()
	end)
	props:addObserver('customFps', function()
		if props.fps == 'custom' then
			updateSummary()
			applyKeyintDefaults()
		end
	end)
	props:addObserver('resolution', updateSummary)
	props:addObserver('orientation', updateSummary)
	props:addObserver('qualityPreset', applyQualityPreset)
	props:addObserver('codec', applyQualityPreset)

	local hdrText
	if args.hdrInfo.allHdr then
		hdrText = LOC("$$$/Timelapse/Hdr/All=All ^1 photos are HDR. HDR output is not available yet: run the diagnostics to probe your Lightroom version.", args.hdrInfo.total)
	else
		hdrText = LOC("$$$/Timelapse/Hdr/Some=HDR photos: ^1 of ^2 (HDR output requires all photos to be HDR).",
			args.hdrInfo.hdrCount, args.hdrInfo.total)
	end

	local fpsItems, resItems = {}, {}
	for _, v in ipairs(FPS_VALUES) do
		fpsItems[#fpsItems + 1] = { title = tostring(v) .. ' fps', value = v }
	end
	fpsItems[#fpsItems + 1] = { title = LOC "$$$/Timelapse/UI/FpsCustom=Custom...", value = 'custom' }
	for _, r in ipairs(RESOLUTIONS) do
		resItems[#resItems + 1] = { title = r.title, value = r.value }
	end

	-- Rebuilt on every presentation: the validation loop below may present
	-- the dialog more than once, and a view object should not be reused.
	local function buildContents()
	return f:column {
		bind_to_object = props,
		spacing = f:control_spacing(),
		fill_horizontal = 1,

		f:static_text { title = bind 'summaryText', font = '<system/bold>', fill_horizontal = 1 },
		f:static_text { title = hdrText, fill_horizontal = 1 },
		f:separator { fill_horizontal = 1 },

		f:row {
			spacing = f:label_spacing(),
			f:static_text { title = LOC "$$$/Timelapse/UI/Resolution=Format:", width = LrView.share 'label' },
			f:popup_menu { value = bind 'resolution', items = resItems },
			f:popup_menu {
				value = bind 'orientation',
				items = {
					{ title = LOC "$$$/Timelapse/UI/Landscape=Landscape", value = 'landscape' },
					{ title = LOC "$$$/Timelapse/UI/Portrait=Portrait",  value = 'portrait' },
				},
			},
			f:popup_menu {
				value = bind 'fit',
				items = {
					{ title = LOC "$$$/Timelapse/UI/Crop=Fill (center crop)",     value = 'crop' },
					{ title = LOC "$$$/Timelapse/UI/Pad=Fit (black bars)", value = 'pad' },
				},
			},
		},

		f:row {
			spacing = f:label_spacing(),
			f:static_text { title = LOC "$$$/Timelapse/UI/Speed=Frame rate:", width = LrView.share 'label' },
			f:popup_menu { value = bind 'fps', items = fpsItems },
			f:edit_field {
				value = bind 'customFps',
				min = 1, max = 240, precision = 3, width_in_digits = 7,
				visible = LrView.bind {
					keys = { 'fps' },
					operation = function(_, values, fromTable)
						if fromTable then return values.fps == 'custom' end
						return LrBinding.kUnsupportedDirection
					end,
				},
			},
			f:static_text { title = LOC "$$$/Timelapse/UI/SpeedNote=1 photo = 1 frame" },
		},

		f:row {
			spacing = f:label_spacing(),
			f:static_text { title = LOC "$$$/Timelapse/UI/Codec=Codec:", width = LrView.share 'label' },
			f:popup_menu {
				value = bind 'codec',
				items = {
					{ title = 'H.264 (AVC)',  value = 'h264' },
					{ title = 'H.265 (HEVC)', value = 'h265' },
				},
			},
			f:static_text { title = LOC "$$$/Timelapse/UI/Quality=Quality:" },
			f:popup_menu {
				value = bind 'qualityPreset',
				items = {
					{ title = LOC "$$$/Timelapse/UI/QualityHigh=High",     value = 'high' },
					{ title = LOC "$$$/Timelapse/UI/QualityMedium=Medium", value = 'medium' },
					{ title = LOC "$$$/Timelapse/UI/QualityLow=Low",       value = 'low' },
				},
			},
		},

		f:row {
			spacing = f:label_spacing(),
			f:static_text { title = LOC "$$$/Timelapse/UI/Options=Options:", width = LrView.share 'label' },
			f:checkbox { title = LOC "$$$/Timelapse/UI/Deflicker=Deflicker", value = bind 'deflicker' },
			f:static_text { title = LOC "$$$/Timelapse/UI/DeflickerSize=window:", enabled = bind 'deflicker' },
			f:edit_field {
				value = bind 'deflickerSize', enabled = bind 'deflicker',
				min = 2, max = 129, precision = 0, width_in_digits = 4,
			},
			f:checkbox { title = LOC "$$$/Timelapse/UI/Advanced=Advanced settings", value = bind 'showAdvanced' },
		},

		f:column {
			visible = bind 'showAdvanced',
			spacing = f:control_spacing(),
			fill_horizontal = 1,
			f:row {
				spacing = f:label_spacing(),
				f:static_text { title = LOC "$$$/Timelapse/UI/Crf=CRF:", width = LrView.share 'label' },
				f:edit_field { value = bind 'crf', min = 0, max = 51, precision = 0, width_in_digits = 4 },
				f:static_text { title = LOC "$$$/Timelapse/UI/EncoderPreset=Encoder preset:" },
				f:popup_menu {
					value = bind 'encoderPreset',
					items = {
						{ title = 'ultrafast', value = 'ultrafast' },
						{ title = 'fast',      value = 'fast' },
						{ title = 'medium',    value = 'medium' },
						{ title = 'slow',      value = 'slow' },
						{ title = 'veryslow',  value = 'veryslow' },
					},
				},
			},
			f:row {
				spacing = f:label_spacing(),
				f:static_text { title = LOC "$$$/Timelapse/UI/Keyframes=Keyframes:", width = LrView.share 'label' },
				f:static_text { title = LOC "$$$/Timelapse/UI/KeyintMin=min interval:" },
				f:edit_field { value = bind 'keyintMin', min = 1, max = 9999, precision = 0, width_in_digits = 5 },
				f:static_text { title = LOC "$$$/Timelapse/UI/KeyintMax=max interval:" },
				f:edit_field { value = bind 'keyintMax', min = 1, max = 9999, precision = 0, width_in_digits = 5 },
				f:static_text { title = LOC "$$$/Timelapse/UI/KeyintUnit=frames" },
			},
			f:row {
				spacing = f:label_spacing(),
				f:static_text { title = LOC "$$$/Timelapse/UI/MaxBitrate=Max bitrate:", width = LrView.share 'label' },
				f:edit_field { value = bind 'maxBitrate', min = 0, max = 200000, precision = 0, width_in_digits = 7 },
				f:static_text { title = LOC "$$$/Timelapse/UI/MaxBitrateUnit=kbit/s (0 = unlimited)" },
			},
		},

		f:separator { fill_horizontal = 1 },

		f:row {
			spacing = f:label_spacing(),
			f:static_text { title = LOC "$$$/Timelapse/UI/Output=Save to:", width = LrView.share 'label' },
			f:static_text { title = bind 'outputFolder', truncation = 'middle', width_in_chars = 30 },
			f:push_button {
				title = LOC "$$$/Timelapse/UI/Choose=Choose...",
				action = function()
					local folders = LrDialogs.runOpenPanel {
						title = LOC "$$$/Timelapse/UI/ChooseFolder=Choose the output folder",
						canChooseFiles = false,
						canChooseDirectories = true,
						canCreateDirectories = true,
						allowsMultipleSelection = false,
					}
					if folders and folders[1] then
						props.outputFolder = folders[1]
					end
				end,
			},
			f:edit_field { value = bind 'fileName', width_in_chars = 20 },
		},

		f:row {
			spacing = f:label_spacing(),
			f:static_text { title = LOC "$$$/Timelapse/UI/Preview=Preview:", width = LrView.share 'label' },
			f:popup_menu {
				value = bind 'previewRes',
				items = {
					{ title = '480p', value = 480 },
					{ title = '240p', value = 240 },
				},
			},
			f:push_button {
				title = LOC "$$$/Timelapse/UI/BuildPreview=Build preview",
				enabled = LrBinding.negativeOfKey('previewRunning'),
				action = function()
					if props.previewRunning or not props.ffmpegPath then
						if not props.ffmpegPath then
							LrDialogs.message(props.ffmpegStatus, nil, 'warning')
						end
						return
					end
					props.previewRunning = true
					LrTasks.startAsyncTask(function()
						local scope = LrProgressScope {
							title = LOC "$$$/Timelapse/Progress/Preview=Timelapse: building preview...",
						}
						scope:setCancelable(true)
						local targetW, targetH = targetDims(props)
						local ok, pathOrMessage
						local pcallOk, pcallErr = LrTasks.pcall(function()
							ok, pathOrMessage = PreviewBuilder.build {
								photos = photos,
								targetW = targetW,
								targetH = targetH,
								shortSide = tonumber(props.previewRes) or 480,
								fps = effectiveFps(props),
								fit = props.fit,
								deflicker = props.deflicker,
								deflickerSize = tonumber(props.deflickerSize),
								ffmpegPath = props.ffmpegPath,
								tempRoot = tempRoot(),
								progressScope = scope,
							}
						end)
						scope:done()
						props.previewRunning = false
						if not pcallOk then
							Log:error('Preview failed: ' .. tostring(pcallErr))
							LrDialogs.message(LOC "$$$/Timelapse/Preview/Failed=Preview failed",
								tostring(pcallErr), 'warning')
						elseif ok then
							Platform.openFile(pathOrMessage)
						elseif pathOrMessage ~= 'canceled' then
							LrDialogs.message(LOC "$$$/Timelapse/Preview/Failed=Preview failed",
								tostring(pathOrMessage), 'warning')
						end
					end, 'TimelapseCreator preview')
				end,
			},
			f:static_text {
				title = LOC "$$$/Timelapse/UI/PreviewNote=Opens in the system video player",
			},
		},

		f:separator { fill_horizontal = 1 },
		f:static_text { title = bind 'ffmpegStatus', truncation = 'middle', fill_horizontal = 1, width_in_chars = 55 },
		f:static_text {
			title = bind 'ffmpegWarningText',
			visible = bind 'ffmpegVersionInsufficient',
			fill_horizontal = 1,
			width_in_chars = 55,
			height_in_lines = 2,
		},
	}
	end

	while true do
		local result = LrDialogs.presentModalDialog {
			title = LOC "$$$/Timelapse/Dialog/Title=Create Timelapse",
			contents = buildContents(),
			actionVerb = LOC "$$$/Timelapse/Dialog/Create=Create timelapse",
		}
		if result ~= 'ok' then
			return
		end

		-- Validation; on failure the dialog is shown again.
		if not props.ffmpegPath then
			LrDialogs.message(props.ffmpegStatus, nil, 'warning')
		elseif props.fps == 'custom' and not (tonumber(props.customFps) and tonumber(props.customFps) > 0
			and tonumber(props.customFps) <= 240) then
			LrDialogs.message(LOC "$$$/Timelapse/Error/BadFps=Please enter a valid custom frame rate (0-240 fps).", nil, 'warning')
		elseif not props.outputFolder or LrFileUtils.exists(props.outputFolder) ~= 'directory' then
			LrDialogs.message(LOC "$$$/Timelapse/Error/BadFolder=Please choose a valid output folder.", nil, 'warning')
		elseif tonumber(props.keyintMin) and tonumber(props.keyintMax)
			and tonumber(props.keyintMin) > tonumber(props.keyintMax) then
			LrDialogs.message(LOC "$$$/Timelapse/Error/BadKeyint=The minimum keyframe interval cannot exceed the maximum.", nil, 'warning')
		else
			savePrefs(props)
			runGeneration(props, photos, args.aspects)
			return
		end
	end
end

return TimelapseDialog
