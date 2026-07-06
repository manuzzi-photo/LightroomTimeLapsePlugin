--[[----------------------------------------------------------------------------
FFmpegCommand.lua — builds ffmpeg command lines for the timelapse pipeline.

PURE LUA: this module must not import any Lr* namespace, so that it can be
unit-tested outside Lightroom with a standalone Lua interpreter
(see tests/test_ffmpeg_command.lua).
------------------------------------------------------------------------------]]

local FFmpegCommand = {}

--------------------------------------------------------------------------------
-- Quality presets. Values differ per codec because x265 CRF is not on the same
-- perceptual scale as x264 (x265 needs ~+2 for comparable quality).
--------------------------------------------------------------------------------

FFmpegCommand.qualityPresets = {
	high   = { h264 = { crf = 18, preset = 'slow' },   h265 = { crf = 20, preset = 'slow' } },
	medium = { h264 = { crf = 21, preset = 'medium' }, h265 = { crf = 23, preset = 'medium' } },
	low    = { h264 = { crf = 26, preset = 'fast' },   h265 = { crf = 28, preset = 'fast' } },
}

--------------------------------------------------------------------------------
-- Shell quoting
--------------------------------------------------------------------------------

-- Quotes a single token for the platform shell (sh on macOS, cmd on Windows).
function FFmpegCommand.shellQuote(s, isWindows)
	s = tostring(s)
	if isWindows then
		return '"' .. s:gsub('"', '""') .. '"'
	end
	return '"' .. s:gsub('(["\\$`])', '\\%1') .. '"'
end

-- Tokens that are known-safe (plain option names and numbers) are not quoted,
-- everything else (paths, filter graphs) is.
local function needsQuoting(token)
	return not tostring(token):match('^[%w%._:=%-+]+$')
end

--------------------------------------------------------------------------------
-- Export sizing
--------------------------------------------------------------------------------

-- Computes the pixel box (fit-within) that the Lightroom export must use so
-- that every rendered frame fully covers the target video frame.
--
-- targetW/targetH: final video dimensions.
-- aspects: array of photo aspect ratios (width/height), one per photo (or a
--          representative subset). May be empty; 3:2 is assumed as fallback.
-- fit: 'crop' (frame must cover the target) or 'pad' (frame fits inside it).
--
-- Returns exportW, exportH.
function FFmpegCommand.computeExportSize(targetW, targetH, aspects, fit)
	if fit == 'pad' then
		return targetW, targetH
	end
	local targetAspect = targetW / targetH
	local boxW, boxH = 0, 0
	if aspects == nil or #aspects == 0 then
		aspects = { targetAspect >= 1 and 1.5 or (1 / 1.5) }
	end
	for i = 1, #aspects do
		local a = aspects[i]
		if a and a > 0 then
			local w, h
			if a >= targetAspect then
				-- wider than target: height is the limiting dimension
				h = targetH
				w = math.ceil(targetH * a)
			else
				-- taller than target: width is the limiting dimension
				w = targetW
				h = math.ceil(targetW / a)
			end
			if w > boxW then boxW = w end
			if h > boxH then boxH = h end
		end
	end
	if boxW == 0 then boxW, boxH = targetW, targetH end
	return boxW, boxH
end

--------------------------------------------------------------------------------
-- Filter chain
--------------------------------------------------------------------------------

-- opts: see FFmpegCommand.buildArgs
function FFmpegCommand.buildFilterChain(opts)
	local w, h = opts.width, opts.height
	local filters = {}

	if opts.deflicker then
		filters[#filters + 1] = string.format('deflicker=mode=am:size=%d', opts.deflickerSize or 5)
	end

	-- out_range=tv converts the full-range JPEG input to the limited range
	-- expected by video players.
	if opts.fit == 'pad' then
		filters[#filters + 1] = string.format(
			'scale=%d:%d:force_original_aspect_ratio=decrease:flags=lanczos:out_range=tv', w, h)
		filters[#filters + 1] = string.format(
			'pad=%d:%d:(ow-iw)/2:(oh-ih)/2:color=black', w, h)
	else -- default: center crop
		filters[#filters + 1] = string.format(
			'scale=%d:%d:force_original_aspect_ratio=increase:flags=lanczos:out_range=tv', w, h)
		filters[#filters + 1] = string.format('crop=%d:%d', w, h)
	end

	if opts.hdr == 'pq' or opts.hdr == 'hlg' then
		filters[#filters + 1] = 'format=yuv420p10le'
	else
		filters[#filters + 1] = 'format=yuv420p'
	end

	return table.concat(filters, ',')
end

--------------------------------------------------------------------------------
-- Command builder
--------------------------------------------------------------------------------

-- Builds the ffmpeg argument list (unquoted tokens, without the redirection).
--
-- opts:
--   ffmpegPath     (string)  path to the ffmpeg binary
--   inputPattern   (string)  image sequence pattern, e.g. .../frame_%06d.jpg
--   fps            (number)  output frame rate; 1 photo = 1 frame
--   width, height  (number)  final video dimensions
--   fit            (string)  'crop' | 'pad'
--   codec          (string)  'h264' | 'h265'
--   crf            (number)
--   encoderPreset  (string)  ultrafast..placebo
--   keyintMin      (number|nil)  minimum keyframe interval (frames)
--   keyintMax      (number|nil)  maximum keyframe interval (frames)
--   maxBitrate     (number|nil)  cap in kbit/s; nil or 0 disables
--   deflicker      (boolean), deflickerSize (number|nil)
--   hdr            (nil|'pq'|'hlg')  EXPERIMENTAL, h265 only
--   progressFile   (string|nil)  file that receives -progress output
--   outputPath     (string)
function FFmpegCommand.buildArgs(opts)
	local args = {}
	local function add(...)
		local n = select('#', ...)
		for i = 1, n do
			args[#args + 1] = tostring((select(i, ...)))
		end
	end

	add(opts.ffmpegPath)
	add('-y', '-hide_banner', '-loglevel', 'warning')
	add('-framerate', opts.fps)
	add('-start_number', '1')
	add('-i', opts.inputPattern)

	add('-vf', FFmpegCommand.buildFilterChain(opts))

	local isH265 = (opts.codec == 'h265')
	add('-c:v', isH265 and 'libx265' or 'libx264')
	add('-preset', opts.encoderPreset or 'medium')
	add('-crf', opts.crf or 21)

	-- Keyframe interval (GOP): x264 honors -g/-keyint_min, x265 only honors
	-- -g, so min-keyint must go through -x265-params.
	local keyintMin, keyintMax = opts.keyintMin, opts.keyintMax
	local x265params = {}
	if isH265 then
		if keyintMax then x265params[#x265params + 1] = 'keyint=' .. keyintMax end
		if keyintMin then x265params[#x265params + 1] = 'min-keyint=' .. keyintMin end
	else
		if keyintMax then add('-g', keyintMax) end
		if keyintMin then add('-keyint_min', keyintMin) end
	end

	if opts.hdr == 'pq' or opts.hdr == 'hlg' then
		-- EXPERIMENTAL: requires 10/16-bit input frames already encoded with
		-- the corresponding transfer function. H.265 only.
		local trc = (opts.hdr == 'pq') and 'smpte2084' or 'arib-std-b67'
		add('-color_primaries', 'bt2020')
		add('-color_trc', trc)
		add('-colorspace', 'bt2020nc')
		if isH265 then
			x265params[#x265params + 1] = 'colorprim=bt2020'
			x265params[#x265params + 1] = 'transfer=' .. trc
			x265params[#x265params + 1] = 'colormatrix=bt2020nc'
			x265params[#x265params + 1] = 'repeat-headers=1'
			if opts.hdr == 'pq' then
				x265params[#x265params + 1] = 'hdr10=1'
			end
		end
	else
		add('-color_primaries', 'bt709')
		add('-color_trc', 'bt709')
		add('-colorspace', 'bt709')
	end

	if #x265params > 0 then
		add('-x265-params', table.concat(x265params, ':'))
	end

	if isH265 then
		add('-tag:v', 'hvc1') -- required by Apple players
	end

	if opts.maxBitrate and opts.maxBitrate > 0 then
		add('-maxrate', opts.maxBitrate .. 'k')
		add('-bufsize', (opts.maxBitrate * 2) .. 'k')
	end

	add('-movflags', '+faststart')

	if opts.progressFile then
		add('-progress', opts.progressFile)
		add('-nostats')
	end

	add(opts.outputPath)
	return args
end

-- Builds the full shell command string (quoted). Redirection is appended by
-- the caller (FFmpegRunner) together with platform-specific wrapping.
function FFmpegCommand.buildCommand(opts, isWindows)
	local args = FFmpegCommand.buildArgs(opts)
	local quoted = {}
	for i = 1, #args do
		local token = args[i]
		if needsQuoting(token) then
			quoted[#quoted + 1] = FFmpegCommand.shellQuote(token, isWindows)
		else
			quoted[#quoted + 1] = token
		end
	end
	return table.concat(quoted, ' ')
end

-- Convenience: resolves a quality preset name into { crf, preset } for codec.
function FFmpegCommand.resolveQualityPreset(presetName, codec)
	local preset = FFmpegCommand.qualityPresets[presetName]
		or FFmpegCommand.qualityPresets.medium
	return preset[codec] or preset.h264
end

-- Rounds a dimension down to the nearest even number (required by yuv420).
function FFmpegCommand.evenDim(n)
	n = math.floor(n)
	if n % 2 == 1 then n = n - 1 end
	if n < 2 then n = 2 end
	return n
end

-- Computes preview dimensions: same aspect as the target video, with the
-- short side clamped to `shortSide` (480 or 240). Never upscales.
function FFmpegCommand.previewDimensions(targetW, targetH, shortSide)
	local short = math.min(targetW, targetH)
	if shortSide >= short then
		return FFmpegCommand.evenDim(targetW), FFmpegCommand.evenDim(targetH)
	end
	local scale = shortSide / short
	return FFmpegCommand.evenDim(targetW * scale), FFmpegCommand.evenDim(targetH * scale)
end

return FFmpegCommand
