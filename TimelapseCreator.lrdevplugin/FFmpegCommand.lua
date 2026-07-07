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

-- Hardware encoders (VideoToolbox) have no CRF-equivalent perceptual quality
-- knob; quality is controlled by target bitrate instead, scaled by
-- resolution so the same quality tier looks reasonable at 720p and 4K alike.
-- Values are Mbps per megapixel, derived from common streaming/delivery
-- bitrate guidelines (e.g. ~16/10/5 Mbps for 1080p H.264 high/medium/low).
FFmpegCommand.hardwareBitratePerMP = {
	h264 = { high = 7.7, medium = 4.8, low = 2.4 },
	h265 = { high = 3.5, medium = 2.2, low = 1.1 },
}

-- ProRes has no bitrate/CRF control either: quality is selected via a fixed
-- profile. Reuses the same high/medium/low tiers as the other codecs so the
-- Quality menu keeps a consistent meaning regardless of codec.
FFmpegCommand.proresProfiles = {
	high   = 3, -- 422 HQ
	medium = 2, -- 422 (standard)
	low    = 1, -- 422 LT
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

	if opts.codec == 'prores' then
		-- ProRes is natively 10-bit 4:2:2, unlike the 4:2:0 used for H.264/H.265.
		filters[#filters + 1] = 'format=yuv422p10le'
	elseif opts.hdr == 'pq' or opts.hdr == 'hlg' then
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
--   codec          (string)  'h264' | 'h265' | 'prores'
--   hardware       (boolean|nil)  use VideoToolbox instead of software x264/x265/ProRes
--   crf            (number)  software h264/h265 only
--   encoderPreset  (string)  ultrafast..placebo; software h264/h265 only
--   bitrate        (number|nil)  target kbit/s; hardware h264/h265 only (no CRF equivalent)
--   proresProfile  (number|nil)  0=proxy 1=lt 2=standard 3=hq; prores only, default 2
--   keyintMin      (number|nil)  minimum keyframe interval (frames); software only
--   keyintMax      (number|nil)  maximum keyframe interval (frames)
--   maxBitrate     (number|nil)  cap in kbit/s; software h264/h265 only, nil or 0 disables
--   deflicker      (boolean), deflickerSize (number|nil)
--   hdr            (nil|'pq'|'hlg')  EXPERIMENTAL, software h265 only
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

	local isProres = (opts.codec == 'prores')
	local isH265 = (opts.codec == 'h265')
	local hardware = (opts.hardware == true) -- VideoToolbox applies to all three codecs alike

	if isProres then
		add('-c:v', hardware and 'prores_videotoolbox' or 'prores_ks')
		add('-profile:v', opts.proresProfile or FFmpegCommand.proresProfiles.medium)
	elseif hardware then
		add('-c:v', isH265 and 'hevc_videotoolbox' or 'h264_videotoolbox')
		add('-b:v', (opts.bitrate or 8000) .. 'k')
	else
		add('-c:v', isH265 and 'libx265' or 'libx264')
		add('-preset', opts.encoderPreset or 'medium')
		add('-crf', opts.crf or 21)
	end

	-- Keyframe interval (GOP): x264 honors -g/-keyint_min, x265 only honors
	-- -g (min-keyint must go through -x265-params). ProRes is all-intra, no
	-- GOP concept. VideoToolbox produces a fixed-length GOP via -g alone —
	-- confirmed empirically (keyframes land at exactly every Nth frame) —
	-- and has no minimum-interval equivalent to -keyint_min.
	local keyintMin, keyintMax = opts.keyintMin, opts.keyintMax
	local x265params = {}
	if isProres then
		-- nothing to set
	elseif hardware then
		if keyintMax then add('-g', keyintMax) end
	elseif isH265 then
		if keyintMax then x265params[#x265params + 1] = 'keyint=' .. keyintMax end
		if keyintMin then x265params[#x265params + 1] = 'min-keyint=' .. keyintMin end
	else
		if keyintMax then add('-g', keyintMax) end
		if keyintMin then add('-keyint_min', keyintMin) end
	end

	if not isProres then
		if opts.hdr == 'pq' or opts.hdr == 'hlg' then
			-- EXPERIMENTAL: requires 10/16-bit input frames already encoded
			-- with the corresponding transfer function. Software H.265 only.
			local trc = (opts.hdr == 'pq') and 'smpte2084' or 'arib-std-b67'
			add('-color_primaries', 'bt2020')
			add('-color_trc', trc)
			add('-colorspace', 'bt2020nc')
			if isH265 and not hardware then
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
	end

	if #x265params > 0 then
		add('-x265-params', table.concat(x265params, ':'))
	end

	if isH265 then
		add('-tag:v', 'hvc1') -- required by Apple players, software and hardware alike
	end

	if not isProres and not hardware and opts.maxBitrate and opts.maxBitrate > 0 then
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
-- Software h264/h265 only — see resolveHardwareBitrate and resolveProresProfile.
function FFmpegCommand.resolveQualityPreset(presetName, codec)
	local preset = FFmpegCommand.qualityPresets[presetName]
		or FFmpegCommand.qualityPresets.medium
	return preset[codec] or preset.h264
end

-- Resolves a quality preset name into a target bitrate (kbit/s) for
-- hardware (VideoToolbox) h264/h265 encoding, scaled by resolution.
function FFmpegCommand.resolveHardwareBitrate(presetName, codec, width, height)
	local perMP = FFmpegCommand.hardwareBitratePerMP[codec]
		or FFmpegCommand.hardwareBitratePerMP.h264
	local mbpsPerMP = perMP[presetName] or perMP.medium
	local megapixels = (width * height) / 1000000
	return math.max(500, math.floor(mbpsPerMP * megapixels * 1000 + 0.5))
end

-- Resolves a quality preset name into a ProRes profile number (see
-- FFmpegCommand.proresProfiles).
function FFmpegCommand.resolveProresProfile(presetName)
	return FFmpegCommand.proresProfiles[presetName] or FFmpegCommand.proresProfiles.medium
end

-- ProRes ships in a .mov container by convention; H.264/H.265 use .mp4.
function FFmpegCommand.fileExtensionForCodec(codec)
	return (codec == 'prores') and 'mov' or 'mp4'
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

--------------------------------------------------------------------------------
-- Version requirements
--------------------------------------------------------------------------------

-- The newest feature this plugin depends on is the `deflicker` filter
-- (ffmpeg 3.4, 2017); everything else (libx265, hvc1 tagging, faststart,
-- BT.709/BT.2020 color tags) is much older. 4.0 adds a safety margin while
-- staying trivially available on any current package manager.
FFmpegCommand.MIN_FFMPEG_VERSION = '4.0'

-- Extracts numeric dot-separated components from a version string, ignoring
-- any leading/trailing non-digit metadata (e.g. "n4.4-20220222" -> {4, 4},
-- "6.1.1" -> {6, 1, 1}).
local function versionComponents(version)
	local components = {}
	for num in tostring(version):gmatch('%d+') do
		components[#components + 1] = tonumber(num)
	end
	return components
end

-- Compares two dot-separated version strings numerically component by
-- component. Returns true if `version` >= `minVersion`. A version that
-- cannot be parsed at all is treated as insufficient (returns false).
function FFmpegCommand.isVersionAtLeast(version, minVersion)
	local v = versionComponents(version)
	local m = versionComponents(minVersion)
	if #v == 0 then return false end
	for i = 1, math.max(#v, #m) do
		local vc, mc = v[i] or 0, m[i] or 0
		if vc ~= mc then return vc > mc end
	end
	return true
end

return FFmpegCommand
