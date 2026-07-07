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

-- Strips any existing .mp4/.mov extension and appends the one matching
-- `codec` (ProRes conventionally ships in .mov, H.264/H.265 in .mp4), so
-- switching codec never silently keeps a mismatched extension.
local function sanitizeFileName(name, codec)
	name = tostring(name or ''):gsub('[/\\:%*%?"<>|]', '-'):gsub('^%s+', ''):gsub('%s+$', '')
	if name == '' then
		name = 'timelapse_' .. os.date('%Y%m%d_%H%M%S')
	end
	name = name:gsub('%.[mM][oO][vV]$', ''):gsub('%.[mM][pP]4$', '')
	return name .. '.' .. FFmpegCommand.fileExtensionForCodec(codec)
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

-- Resolves the codec/quality-preset combination into the FFmpegCommand
-- options that actually control encoded quality (crf+preset, hardware
-- bitrate, or a ProRes profile — mutually exclusive, see FFmpegCommand.lua).
local function resolveEncodeOpts(props, targetW, targetH)
	if props.codec == 'prores' then
		return {
			codec = 'prores',
			hardware = props.hardware,
			proresProfile = FFmpegCommand.resolveProresProfile(props.qualityPreset),
			keyintMax = nil, keyintMin = nil, -- all-intra, no GOP
		}
	end
	if props.hardware then
		return {
			codec = props.codec,
			hardware = true,
			bitrate = tonumber(props.maxBitrate) or
				FFmpegCommand.resolveHardwareBitrate(props.qualityPreset, props.codec, targetW, targetH),
			keyintMax = tonumber(props.keyintMax),
			keyintMin = nil, -- no VideoToolbox equivalent
		}
	end
	local quality = FFmpegCommand.resolveQualityPreset(props.qualityPreset, props.codec)
	return {
		codec = props.codec,
		hardware = false,
		crf = tonumber(props.crf) or quality.crf,
		encoderPreset = props.encoderPreset or quality.preset,
		keyintMin = tonumber(props.keyintMin),
		keyintMax = tonumber(props.keyintMax),
		maxBitrate = tonumber(props.maxBitrate),
	}
end

-- When saveInSourceFolder is on, the video is saved next to the first photo
-- of the (capture-time-sorted) sequence. If the selection spans several
-- folders, only that first photo's folder is used — kept deliberately
-- simple, called out in the UI rather than auto-detected/warned about.
local function resolveOutputFolder(props, photos)
	if props.saveInSourceFolder then
		local firstPath = photos[1]:getRawMetadata('path')
		return LrPathUtils.parent(firstPath)
	end
	return props.outputFolder
end

--------------------------------------------------------------------------------
-- Preferences (remembered between sessions)

local REMEMBERED = {
	'resolution', 'orientation', 'fit', 'fps', 'customFps', 'codec', 'qualityPreset',
	'hardware', 'deflicker', 'deflickerSize', 'previewRes', 'outputFolder', 'saveInSourceFolder',
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
	local outputFolder = resolveOutputFolder(props, photos)
	local outputPath = LrPathUtils.child(outputFolder, sanitizeFileName(props.fileName, props.codec))

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
	local encodeOpts = resolveEncodeOpts(props, targetW, targetH)
	encodeOpts.inputPattern = result.pattern
	encodeOpts.ffmpegPath = props.ffmpegPath
	encodeOpts.fps = effectiveFps(props)
	encodeOpts.width = targetW
	encodeOpts.height = targetH
	encodeOpts.fit = props.fit
	encodeOpts.deflicker = props.deflicker
	encodeOpts.deflickerSize = tonumber(props.deflickerSize)
	encodeOpts.progressFile = LrPathUtils.child(sessionDir, 'progress.txt')
	encodeOpts.outputPath = outputPath

	local encodeScope = LrProgressScope {
		title = LOC("$$$/Timelapse/Progress/Encode=Timelapse: encoding ^1 frames with ffmpeg...", result.count),
	}
	encodeScope:setCancelable(true)
	local outcome, _, tail = FFmpegRunner.run(encodeOpts, {
		logFile = LrPathUtils.child(sessionDir, 'ffmpeg.log'),
		progressScope = encodeScope,
		totalFrames = result.count,
	})
	encodeScope:done()

	if outcome == 'canceled' then
		LrFileUtils.delete(sessionDir)
		return
	end
	if outcome ~= 'ok' then
		-- Keep the session folder so the ffmpeg log can be inspected.
		LrDialogs.message(
			LOC "$$$/Timelapse/Error/EncodeFailed=ffmpeg could not encode the video",
			LOC("$$$/Timelapse/Error/EncodeFailedDetail=Log: ^1^n^n^2",
				LrPathUtils.child(sessionDir, 'ffmpeg.log'), tail or ''),
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
	props.hardware = false
	props.showAdvanced = false
	props.deflicker = false
	props.deflickerSize = 5
	props.maxBitrate = 0
	props.previewRes = 480
	props.outputFolder = defaultOutputFolder()
	props.saveInSourceFolder = false
	loadPrefs(props)
	props.previewRunning = false

	-- ffmpeg detection. Path, version and the minimum-version warning are
	-- only ever shown in Lightroom's Plug-in Manager (see
	-- PluginInfoProvider.lua); this dialog just needs to know whether
	-- generation can proceed, surfaced only as a validation message.
	local ffmpegPath = FFmpegLocator.locate()
	props.ffmpegPath = ffmpegPath
	props.ffmpegStatus = ffmpegPath
		and LOC "$$$/Timelapse/FFmpeg/ConfiguredElsewhere=ffmpeg is configured."
		or LOC "$$$/Timelapse/FFmpeg/Missing=ffmpeg not found. Configure it in Lightroom's Plug-in Manager (File > Plug-in Manager > Timelapse Creator)."

	-- VideoToolbox is part of macOS, but a minimal/custom ffmpeg build could
	-- lack it, so this is probed rather than assumed. Fixed for the life of
	-- the dialog (no UI path changes ffmpeg mid-session).
	local hardwareAvailable = ffmpegPath and FFmpegLocator.hasHardwareAcceleration(ffmpegPath) or false
	if not hardwareAvailable then
		props.hardware = false
	end

	props.fileName = sanitizeFileName('timelapse_' .. os.date('%Y%m%d_%H%M%S'), props.codec)

	-- Advanced fields follow the quality preset until edited by hand.
	-- Quality has three, mutually exclusive meanings depending on codec and
	-- hardware/software mode (see resolveEncodeOpts): CRF+preset (software
	-- H.264/H.265), a VideoToolbox bitrate target (hardware H.264/H.265,
	-- which has no CRF-equivalent perceptual quality knob), or a fixed
	-- ProRes profile (ProRes has neither CRF nor bitrate control).
	local autoKeyint = {}
	local function applyQualityPreset()
		if props.codec == 'prores' then
			return -- resolved directly from qualityPreset at generation time
		end
		if props.hardware then
			local w, h = targetDims(props)
			props.maxBitrate = FFmpegCommand.resolveHardwareBitrate(props.qualityPreset, props.codec, w, h)
		else
			local q = FFmpegCommand.resolveQualityPreset(props.qualityPreset, props.codec)
			props.crf = q.crf
			props.encoderPreset = q.preset
		end
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
	props:addObserver('resolution', function()
		updateSummary()
		applyQualityPreset() -- hardware bitrate target scales with resolution
	end)
	props:addObserver('orientation', function()
		updateSummary()
		applyQualityPreset()
	end)
	props:addObserver('qualityPreset', applyQualityPreset)
	props:addObserver('hardware', applyQualityPreset)
	props:addObserver('codec', function()
		applyQualityPreset()
		props.fileName = sanitizeFileName(props.fileName, props.codec)
	end)

	local function updateOutputFolderDisplay()
		props.outputFolderDisplay = resolveOutputFolder(props, photos)
	end
	updateOutputFolderDisplay()
	props:addObserver('saveInSourceFolder', updateOutputFolderDisplay)
	props:addObserver('outputFolder', updateOutputFolderDisplay)

	local hdrText
	if args.hdrInfo.allHdr then
		hdrText = LOC("$$$/Timelapse/Hdr/All=All ^1 photos are HDR. HDR output is not available yet: run the diagnostics to probe your Lightroom version.", args.hdrInfo.total)
	else
		hdrText = LOC("$$$/Timelapse/Hdr/Some=HDR photos: ^1 of ^2 (HDR output requires all photos to be HDR).",
			args.hdrInfo.hdrCount, args.hdrInfo.total)
	end

	-- Static frame-scrubber preview: instant, no ffmpeg involved (unlike the
	-- "Build preview" MP4 below). Shows the photo's own library thumbnail
	-- (develop settings and any per-photo crop applied), not the target
	-- video's crop/fit — the two can differ.
	--
	-- addObserver callbacks run in a restricted Lightroom context where
	-- yielding is not allowed — confirmed by a real "Yielding is not
	-- allowed within a C or metamethod call (...for condition
	-- previewFrameIndex)" plugin error, the same class of bug as the
	-- pcall/yield issues fixed earlier, but here even starting a task from
	-- inside the observer was enough to trigger it. The observer below only
	-- records the request (plain variables, no yielding calls); a single
	-- long-lived watcher task started once here does the actual async work.
	local FRAME_PREVIEW_W, FRAME_PREVIEW_H = 320, 240
	local FRAME_PREVIEW_DEBOUNCE = 0.15
	props.previewFrameIndex = 1
	props.previewFrameImagePath = nil
	props.previewFrameLabel = ''

	local lastFramePreviewPath
	local requestedFrameIndex = 1
	local requestedFrameToken = 1
	local handledFrameToken = 0
	local frameWatcherRunning = true

	props:addObserver('previewFrameIndex', function()
		requestedFrameIndex = math.floor(props.previewFrameIndex)
		requestedFrameToken = requestedFrameToken + 1
	end)

	LrTasks.startAsyncTask(function()
		while frameWatcherRunning do
			if requestedFrameToken == handledFrameToken then
				LrTasks.sleep(0.05)
			else
				local myToken = requestedFrameToken
				local index = requestedFrameIndex
				LrTasks.sleep(FRAME_PREVIEW_DEBOUNCE)
				if frameWatcherRunning and requestedFrameToken == myToken then
					handledFrameToken = myToken
					local photo = photos[index]
					props.previewFrameLabel = LOC("$$$/Timelapse/UI/FramePreviewLabel=Photo ^1 of ^2 — ^3",
						index, #photos, LrPathUtils.leafName(photo:getRawMetadata('path')))

					local jpegData, finished
					photo:requestJpegThumbnail(FRAME_PREVIEW_W, FRAME_PREVIEW_H, function(data, _)
						jpegData = data
						finished = true
					end)
					local waited = 0
					while not finished and waited < 15 do
						LrTasks.sleep(0.05)
						waited = waited + 0.05
					end

					if frameWatcherRunning and requestedFrameToken == myToken
						and type(jpegData) == 'string' and #jpegData > 0 then
						local path = LrPathUtils.child(tempRoot(),
							string.format('frame_preview_%d_%d.jpg', index, myToken))
						local file = io.open(path, 'wb')
						if file then
							file:write(jpegData)
							file:close()
							props.previewFrameImagePath = path
							local previous = lastFramePreviewPath
							lastFramePreviewPath = path
							if previous then LrFileUtils.delete(previous) end
						end
					end
				end
			end
		end
	end, 'TimelapseCreator frame preview watcher')

	context:addCleanupHandler(function()
		frameWatcherRunning = false
		if lastFramePreviewPath then LrFileUtils.delete(lastFramePreviewPath) end
	end)

	local fpsItems, resItems = {}, {}
	for _, v in ipairs(FPS_VALUES) do
		fpsItems[#fpsItems + 1] = { title = tostring(v) .. ' fps', value = v }
	end
	fpsItems[#fpsItems + 1] = { title = LOC "$$$/Timelapse/UI/FpsCustom=Custom...", value = 'custom' }
	for _, r in ipairs(RESOLUTIONS) do
		resItems[#resItems + 1] = { title = r.title, value = r.value }
	end

	-- Small reusable visibility bindings for the codec/hardware-dependent
	-- Advanced rows below: CRF+preset only make sense for software H.264/
	-- H.265; bitrate only for hardware H.264/H.265; ProRes has neither (and
	-- no keyframe/GOP concept at all, being all-intra).
	local function bindWhen(keys, test)
		return LrView.bind {
			keys = keys,
			operation = function(_, values, fromTable)
				if fromTable then return test(values) end
				return LrBinding.kUnsupportedDirection
			end,
		}
	end
	local function bindNotProres() return bindWhen({ 'codec' }, function(v) return v.codec ~= 'prores' end) end
	local function bindIsProres() return bindWhen({ 'codec' }, function(v) return v.codec == 'prores' end) end
	local function bindSoftwareH26x()
		return bindWhen({ 'codec', 'hardware' }, function(v) return v.codec ~= 'prores' and not v.hardware end)
	end
	local function bindHardwareH26x()
		return bindWhen({ 'codec', 'hardware' }, function(v) return v.codec ~= 'prores' and v.hardware end)
	end
	local function bindNotHardware() return bindWhen({ 'hardware' }, function(v) return not v.hardware end) end

	-- Rebuilt on every presentation: the validation loop below may present
	-- the dialog more than once, and a view object should not be reused.
	local function buildContents()
	return f:column {
		bind_to_object = props,
		spacing = f:control_spacing(),
		fill_horizontal = 1,

		f:static_text { title = bind 'summaryText', font = '<system/bold>', fill_horizontal = 1 },
		f:static_text { title = hdrText, fill_horizontal = 1 },

		f:group_box {
			title = LOC "$$$/Timelapse/UI/GroupPreview=Preview",
			fill_horizontal = 1,
			spacing = f:control_spacing(),

			f:column {
				spacing = f:control_spacing(),
				fill_horizontal = 1,
				place_horizontal = 0.5,
				f:picture {
					value = bind 'previewFrameImagePath',
					width = 320,
					height = 240,
				},
				f:row {
					spacing = f:label_spacing(),
					f:push_button {
						title = '◀',
						width = 30,
						action = function()
							props.previewFrameIndex = math.max(1, props.previewFrameIndex - 1)
						end,
					},
					f:slider {
						value = bind 'previewFrameIndex',
						min = 1, max = #photos, integral = true,
						width = 300,
					},
					f:push_button {
						title = '▶',
						width = 30,
						action = function()
							props.previewFrameIndex = math.min(#photos, props.previewFrameIndex + 1)
						end,
					},
				},
				f:static_text { title = bind 'previewFrameLabel' },
				f:static_text {
					title = LOC "$$$/Timelapse/UI/FramePreviewNote=Shows the photo as developed, not the video's crop/fit",
				},
			},

			f:separator { fill_horizontal = 1 },

			f:row {
				spacing = f:label_spacing(),
				f:static_text { title = LOC "$$$/Timelapse/UI/Preview=Video preview:", width = LrView.share 'label' },
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
									hardware = props.hardware,
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
		},

		f:group_box {
			title = LOC "$$$/Timelapse/UI/GroupFormat=Format & Speed",
			fill_horizontal = 1,
			spacing = f:control_spacing(),

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
		},

		f:group_box {
			title = LOC "$$$/Timelapse/UI/GroupEncoding=Encoding",
			fill_horizontal = 1,
			spacing = f:control_spacing(),

			f:row {
				spacing = f:label_spacing(),
				f:static_text { title = LOC "$$$/Timelapse/UI/Codec=Codec:", width = LrView.share 'label' },
				f:popup_menu {
					value = bind 'codec',
					items = {
						{ title = 'H.264 (AVC)',  value = 'h264' },
						{ title = 'H.265 (HEVC)', value = 'h265' },
						{ title = 'ProRes 422',   value = 'prores' },
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
				visible = hardwareAvailable,
				spacing = f:label_spacing(),
				f:spacer { width = LrView.share 'label' },
				f:checkbox {
					title = LOC "$$$/Timelapse/UI/UseHardware=Use hardware acceleration (VideoToolbox)",
					value = bind 'hardware',
				},
				f:static_text {
					title = LOC "$$$/Timelapse/UI/UseHardwareNote=Much faster; files are usually a bit larger",
				},
			},

			f:static_text {
				visible = bindIsProres(),
				fill_horizontal = 1,
				title = LOC "$$$/Timelapse/UI/ProresNote=ProRes files are much larger than H.264/H.265 — roughly 8-10x for the same duration.",
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
					visible = bindSoftwareH26x(),
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
					visible = bindNotProres(),
					spacing = f:label_spacing(),
					f:static_text { title = LOC "$$$/Timelapse/UI/Keyframes=Keyframes:", width = LrView.share 'label' },
					f:static_text { title = LOC "$$$/Timelapse/UI/KeyintMin=min interval:", enabled = bindNotHardware() },
					f:edit_field {
						value = bind 'keyintMin', enabled = bindNotHardware(),
						min = 1, max = 9999, precision = 0, width_in_digits = 5,
					},
					f:static_text { title = LOC "$$$/Timelapse/UI/KeyintMax=max interval:" },
					f:edit_field { value = bind 'keyintMax', min = 1, max = 9999, precision = 0, width_in_digits = 5 },
					f:static_text { title = LOC "$$$/Timelapse/UI/KeyintUnit=frames" },
				},
				f:row {
					visible = bindSoftwareH26x(),
					spacing = f:label_spacing(),
					f:static_text { title = LOC "$$$/Timelapse/UI/MaxBitrate=Max bitrate:", width = LrView.share 'label' },
					f:edit_field { value = bind 'maxBitrate', min = 0, max = 200000, precision = 0, width_in_digits = 7 },
					f:static_text { title = LOC "$$$/Timelapse/UI/MaxBitrateUnit=kbit/s (0 = unlimited)" },
				},
				f:row {
					visible = bindHardwareH26x(),
					spacing = f:label_spacing(),
					f:static_text { title = LOC "$$$/Timelapse/UI/TargetBitrate=Target bitrate:", width = LrView.share 'label' },
					f:edit_field { value = bind 'maxBitrate', min = 0, max = 200000, precision = 0, width_in_digits = 7 },
					f:static_text { title = LOC "$$$/Timelapse/UI/TargetBitrateUnit=kbit/s" },
				},
			},
		},

		f:group_box {
			title = LOC "$$$/Timelapse/UI/GroupOutput=Output",
			fill_horizontal = 1,
			spacing = f:control_spacing(),

			f:row {
				spacing = f:label_spacing(),
				f:static_text { title = LOC "$$$/Timelapse/UI/Output=Save to:", width = LrView.share 'label' },
				f:static_text { title = bind 'outputFolderDisplay', truncation = 'middle', width_in_chars = 30 },
				f:push_button {
					title = LOC "$$$/Timelapse/UI/Choose=Choose...",
					enabled = LrBinding.negativeOfKey('saveInSourceFolder'),
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
				f:spacer { width = LrView.share 'label' },
				f:checkbox {
					title = LOC "$$$/Timelapse/UI/SaveInSourceFolder=Save in the photos' original folder",
					value = bind 'saveInSourceFolder',
				},
				f:static_text {
					title = LOC "$$$/Timelapse/UI/SaveInSourceFolderNote=Uses the folder of the first photo in the sequence",
				},
			},
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
		elseif not props.saveInSourceFolder
			and (not props.outputFolder or LrFileUtils.exists(props.outputFolder) ~= 'directory') then
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
