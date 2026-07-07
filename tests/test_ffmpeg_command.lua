-- Unit tests for FFmpegCommand.lua (pure Lua, no Lightroom required).
-- Run from the repository root:  lua tests/test_ffmpeg_command.lua

package.path = 'TimelapseCreator.lrdevplugin/?.lua;' .. package.path
local C = require 'FFmpegCommand'

local failures = 0
local function check(name, cond, detail)
	if cond then
		print('ok    ' .. name)
	else
		failures = failures + 1
		print('FAIL  ' .. name .. (detail and ('  -- ' .. tostring(detail)) or ''))
	end
end

local function contains(list, ...)
	-- true if the varargs appear consecutively in list
	local want = { ... }
	for i = 1, #list - #want + 1 do
		local all = true
		for j = 1, #want do
			if list[i + j - 1] ~= tostring(want[j]) then all = false break end
		end
		if all then return true end
	end
	return false
end

local function baseOpts(overrides)
	local opts = {
		ffmpegPath = '/opt/homebrew/bin/ffmpeg',
		inputPattern = '/tmp/tl session/frame_%06d.jpg',
		fps = 30,
		width = 1920, height = 1080,
		fit = 'crop',
		codec = 'h264',
		crf = 21, encoderPreset = 'medium',
		keyintMin = 30, keyintMax = 300,
		outputPath = '/tmp/out dir/timelapse.mp4',
	}
	for k, v in pairs(overrides or {}) do opts[k] = v end
	return opts
end

------------------------------------------------------------------- buildArgs

local args = C.buildArgs(baseOpts())
check('h264 codec', contains(args, '-c:v', 'libx264'))
check('framerate', contains(args, '-framerate', '30'))
check('crf', contains(args, '-crf', '21'))
check('x264 keyint', contains(args, '-g', '300') and contains(args, '-keyint_min', '30'))
check('faststart', contains(args, '-movflags', '+faststart'))
check('sdr color tags', contains(args, '-color_trc', 'bt709'))
check('output last', args[#args] == '/tmp/out dir/timelapse.mp4')

local vf
for i = 1, #args - 1 do if args[i] == '-vf' then vf = args[i + 1] end end
check('crop chain', vf == 'scale=1920:1080:force_original_aspect_ratio=increase:flags=lanczos:out_range=tv,crop=1920:1080,format=yuv420p', vf)

args = C.buildArgs(baseOpts{ codec = 'h265' })
check('h265 codec', contains(args, '-c:v', 'libx265'))
check('h265 hvc1 tag', contains(args, '-tag:v', 'hvc1'))
check('h265 keyint via x265-params', contains(args, '-x265-params', 'keyint=300:min-keyint=30'))
check('h265 no -g', not contains(args, '-g', '300'))

args = C.buildArgs(baseOpts{ fit = 'pad', deflicker = true, deflickerSize = 7 })
for i = 1, #args - 1 do if args[i] == '-vf' then vf = args[i + 1] end end
check('deflicker first in chain', vf:sub(1, #'deflicker=mode=am:size=7,') == 'deflicker=mode=am:size=7,', vf)
check('pad chain', vf:find('force_original_aspect_ratio=decrease', 1, true) and vf:find('pad=1920:1080:(ow-iw)/2:(oh-ih)/2:color=black', 1, true), vf)

args = C.buildArgs(baseOpts{ maxBitrate = 8000 })
check('maxrate/bufsize', contains(args, '-maxrate', '8000k') and contains(args, '-bufsize', '16000k'))

args = C.buildArgs(baseOpts{ maxBitrate = 0 })
check('maxrate 0 disabled', not contains(args, '-maxrate', '0k'))

args = C.buildArgs(baseOpts{ codec = 'h265', hdr = 'pq' })
for i = 1, #args - 1 do if args[i] == '-vf' then vf = args[i + 1] end end
check('hdr pq 10-bit format', vf:find('format=yuv420p10le', 1, true) ~= nil, vf)
check('hdr pq color tags', contains(args, '-color_trc', 'smpte2084') and contains(args, '-color_primaries', 'bt2020'))
local xp
for i = 1, #args - 1 do if args[i] == '-x265-params' then xp = args[i + 1] end end
check('hdr pq x265 params', xp and xp:find('transfer=smpte2084', 1, true) and xp:find('hdr10=1', 1, true), xp)

args = C.buildArgs(baseOpts{ codec = 'h265', hdr = 'hlg' })
check('hdr hlg trc', contains(args, '-color_trc', 'arib-std-b67'))

args = C.buildArgs(baseOpts{ progressFile = '/tmp/progress.txt' })
check('progress file', contains(args, '-progress', '/tmp/progress.txt') and contains(args, '-nostats'))

------------------------------------------------------------- hardware (VideoToolbox)

args = C.buildArgs(baseOpts{ hardware = true })
check('hw h264 encoder', contains(args, '-c:v', 'h264_videotoolbox'))
check('hw h264 bitrate', contains(args, '-b:v', '8000k'))
check('hw h264 no crf', not contains(args, '-crf', '21'))
check('hw h264 no preset', not contains(args, '-preset', 'medium'))
check('hw h264 keyint via -g', contains(args, '-g', '300'))
check('hw h264 no keyint_min', not contains(args, '-keyint_min', '30'))

args = C.buildArgs(baseOpts{ codec = 'h265', hardware = true, bitrate = 5000 })
check('hw h265 encoder', contains(args, '-c:v', 'hevc_videotoolbox'))
check('hw h265 bitrate override', contains(args, '-b:v', '5000k'))
check('hw h265 still tagged hvc1', contains(args, '-tag:v', 'hvc1'))
check('hw h265 no x265-params', not contains(args, '-x265-params'))

args = C.buildArgs(baseOpts{ hardware = true, maxBitrate = 8000 })
check('hw ignores software maxrate cap', not contains(args, '-maxrate', '8000k'))

args = C.buildArgs(baseOpts{ codec = 'h265', hardware = true, hdr = 'pq' })
check('hw hdr color tags still applied', contains(args, '-color_trc', 'smpte2084'))
local hasX265ParamsHw = false
for i = 1, #args do if args[i] == '-x265-params' then hasX265ParamsHw = true end end
check('hw hdr has no x265-params (not x265 at all)', not hasX265ParamsHw)

--------------------------------------------------------------------- prores

args = C.buildArgs(baseOpts{ codec = 'prores', proresProfile = 3 })
check('prores software encoder', contains(args, '-c:v', 'prores_ks'))
check('prores profile', contains(args, '-profile:v', '3'))
check('prores no crf', not contains(args, '-crf'))
check('prores no preset', not contains(args, '-preset'))
check('prores no tag hvc1', not contains(args, '-tag:v', 'hvc1'))
check('prores no keyint (all-intra)', not contains(args, '-g', '300') and not contains(args, '-keyint_min'))
check('prores ignores maxBitrate cap', not contains(args, '-maxrate'))
local vfProres
for i = 1, #args - 1 do if args[i] == '-vf' then vfProres = args[i + 1] end end
check('prores 10-bit 422 pixel format', vfProres:find('format=yuv422p10le', 1, true) ~= nil, vfProres)

args = C.buildArgs(baseOpts{ codec = 'prores', hardware = true })
check('prores hardware encoder', contains(args, '-c:v', 'prores_videotoolbox'))
check('prores default profile (medium/standard)', contains(args, '-profile:v', '2'))

---------------------------------------------------------------- buildCommand

local cmd = C.buildCommand(baseOpts(), false)
check('cmd quotes spaced input', cmd:find('"/tmp/tl session/frame_%06d.jpg"', 1, true) ~= nil, cmd)
check('cmd quotes spaced output', cmd:find('"/tmp/out dir/timelapse.mp4"', 1, true) ~= nil, cmd)
check('cmd does not quote plain flags', cmd:find('-movflags +faststart', 1, true) ~= nil, cmd)

------------------------------------------------------------------ shellQuote

check('posix quote escapes $', C.shellQuote('a$b', false) == '"a\\$b"', C.shellQuote('a$b', false))
check('posix quote escapes "', C.shellQuote('a"b', false) == '"a\\"b"', C.shellQuote('a"b', false))
check('windows quote doubles "', C.shellQuote('a"b', true) == '"a""b"', C.shellQuote('a"b', true))

----------------------------------------------------------- computeExportSize

-- 3:2 landscape photos into 16:9: width limits, need taller box
local w, h = C.computeExportSize(1920, 1080, { 1.5 }, 'crop')
check('export size 3:2 -> 16:9 crop', w == 1920 and h == 1280, w .. 'x' .. h)

-- pano (2.4) into 16:9: height limits
w, h = C.computeExportSize(1920, 1080, { 2.4 }, 'crop')
check('export size pano -> 16:9 crop', w == 2592 and h == 1080, w .. 'x' .. h)

-- portrait 2:3 into vertical 9:16
w, h = C.computeExportSize(1080, 1920, { 2 / 3 }, 'crop')
check('export size 2:3 -> 9:16 crop', w == 1280 and h == 1920, w .. 'x' .. h)

-- mixed aspects: box must cover both
w, h = C.computeExportSize(1920, 1080, { 1.5, 2.4 }, 'crop')
check('export size mixed crop', w == 2592 and h == 1280, w .. 'x' .. h)

-- pad mode: exact target box
w, h = C.computeExportSize(1920, 1080, { 1.5 }, 'pad')
check('export size pad', w == 1920 and h == 1080, w .. 'x' .. h)

-- no aspects: sane fallback that covers a 3:2 photo
w, h = C.computeExportSize(1920, 1080, {}, 'crop')
check('export size fallback', w >= 1920 and h >= 1280, w .. 'x' .. h)

--------------------------------------------------------- previewDimensions

w, h = C.previewDimensions(1920, 1080, 480)
check('preview 480p 16:9', w == 852 and h == 480, w .. 'x' .. h)
w, h = C.previewDimensions(1080, 1920, 240)
check('preview 240p 9:16', w == 240 and h == 426, w .. 'x' .. h)
w, h = C.previewDimensions(640, 360, 480)
check('preview no upscale', w == 640 and h == 360, w .. 'x' .. h)

--------------------------------------------------------------------- presets

for _, name in ipairs{ 'high', 'medium', 'low' } do
	for _, codec in ipairs{ 'h264', 'h265' } do
		local p = C.resolveQualityPreset(name, codec)
		check('preset ' .. name .. '/' .. codec,
			type(p.crf) == 'number' and type(p.preset) == 'string')
	end
end
check('preset fallback', C.resolveQualityPreset('bogus', 'h264').crf == 21)

------------------------------------------------------- hardware bitrate / prores

-- 1080p (~2.07 MP) h264 medium: documented as ~4.8 Mbps/MP -> ~10 Mbps
local kbps = C.resolveHardwareBitrate('medium', 'h264', 1920, 1080)
check('hw bitrate 1080p h264 medium in reasonable range', kbps > 8000 and kbps < 12000, kbps)

-- 4K should scale ~4x over 1080p (4x the pixels) for the same tier/codec
local kbps4k = C.resolveHardwareBitrate('medium', 'h264', 3840, 2160)
check('hw bitrate scales with resolution', kbps4k > kbps * 3.5 and kbps4k < kbps * 4.5,
	kbps .. ' -> ' .. kbps4k)

-- h265 should target a noticeably lower bitrate than h264 for the same tier
local kbpsH265 = C.resolveHardwareBitrate('medium', 'h265', 1920, 1080)
check('hw bitrate h265 lower than h264 at same tier', kbpsH265 < kbps, kbpsH265 .. ' vs ' .. kbps)

check('hw bitrate unknown tier falls back to medium',
	C.resolveHardwareBitrate('bogus', 'h264', 1920, 1080) == kbps)

check('prores profile high', C.resolveProresProfile('high') == 3)
check('prores profile medium', C.resolveProresProfile('medium') == 2)
check('prores profile low', C.resolveProresProfile('low') == 1)
check('prores profile fallback', C.resolveProresProfile('bogus') == 2)

check('file extension prores', C.fileExtensionForCodec('prores') == 'mov')
check('file extension h264', C.fileExtensionForCodec('h264') == 'mp4')
check('file extension h265', C.fileExtensionForCodec('h265') == 'mp4')

------------------------------------------------------------- isVersionAtLeast

check('min version constant', C.MIN_FFMPEG_VERSION == '4.0')

check('newer major sufficient', C.isVersionAtLeast('8.0.1', '4.0') == true)
check('exact match sufficient', C.isVersionAtLeast('4.0', '4.0') == true)
check('newer patch sufficient', C.isVersionAtLeast('4.0.5', '4.0') == true)
check('older major insufficient', C.isVersionAtLeast('3.2', '4.0') == false)
check('older minor insufficient', C.isVersionAtLeast('3.4.11', '4.0') == false)
check('distro suffix sufficient', C.isVersionAtLeast('4.4.1-0ubuntu1', '4.0') == true)
check('distro suffix insufficient', C.isVersionAtLeast('3.4.8-0ubuntu1', '4.0') == false)
check('leading n prefix', C.isVersionAtLeast('n4.4', '4.0') == true)
check('unparseable version', C.isVersionAtLeast('unknown', '4.0') == false)
check('nil version', C.isVersionAtLeast(nil, '4.0') == false)

--------------------------------------------------------------------- result

print(string.rep('-', 40))
if failures > 0 then
	print(failures .. ' test(s) FAILED')
	os.exit(1)
end
print('All tests passed')
