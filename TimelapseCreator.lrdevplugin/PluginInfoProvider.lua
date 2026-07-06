--[[----------------------------------------------------------------------------
PluginInfoProvider.lua — "Timelapse Creator" section in Lightroom's
File > Plug-in Manager dialog.

Hosts the ffmpeg binary configuration, an installation-level setting that
does not belong in the per-video TimelapseDialog.lua. The same FFmpegLocator
used by the main dialog (auto-detect → LrPrefs → shell PATH) is reused here;
whichever path is saved is picked up everywhere else in the plugin.
------------------------------------------------------------------------------]]

local LrView = import 'LrView'
local LrDialogs = import 'LrDialogs'
local LrTasks = import 'LrTasks'

local FFmpegCommand = require 'FFmpegCommand'
local FFmpegLocator = require 'FFmpegLocator'

local PluginInfoProvider = {}

-- Re-runs ffmpeg detection and updates the observable propertyTable.
-- FFmpegLocator shells out (LrTasks.execute), which yields, so this must
-- always run inside its own task — never called directly from startDialog
-- or a button action, both of which execute on the main UI task.
local function refreshStatus(propertyTable)
	LrTasks.startAsyncTask(function()
		local path, version, sufficient = FFmpegLocator.locate()
		propertyTable.ffmpegPath = path
		propertyTable.ffmpegVersionInsufficient = (path ~= nil and not sufficient)
		if path then
			propertyTable.ffmpegStatus = LOC("$$$/Timelapse/FFmpeg/Found=ffmpeg ^1 — ^2", version, path)
			propertyTable.ffmpegWarningText = LOC(
				"$$$/Timelapse/FFmpeg/TooOld=ffmpeg ^1 detected — version ^2 or newer is recommended; some features (e.g. deflicker) may not work.",
				version, FFmpegCommand.MIN_FFMPEG_VERSION)
		else
			propertyTable.ffmpegStatus = LOC "$$$/Timelapse/FFmpeg/MissingHere=ffmpeg not found. Install it (e.g. 'brew install ffmpeg') or set its path below."
			propertyTable.ffmpegWarningText = ''
		end
	end, 'TimelapseCreator ffmpeg detection')
end

-- startDialog is a blocking call, not a task: seed a placeholder synchronously,
-- then refresh (which shells out) in the background.
function PluginInfoProvider.startDialog(propertyTable)
	propertyTable.ffmpegStatus = LOC "$$$/Timelapse/FFmpeg/Checking=Checking ffmpeg..."
	propertyTable.ffmpegWarningText = ''
	propertyTable.ffmpegVersionInsufficient = false
	refreshStatus(propertyTable)
end

function PluginInfoProvider.sectionsForTopOfDialog(f, propertyTable)
	local bind = LrView.bind

	return {
		{
			title = LOC "$$$/Timelapse/PluginInfo/Title=Timelapse Creator",

			f:row {
				spacing = f:control_spacing(),
				f:picture { value = _PLUGIN:resourceId('Icon.png') },
				f:column {
					spacing = f:control_spacing(),
					f:static_text {
						title = LOC "$$$/Timelapse/PluginInfo/Name=Timelapse Creator",
						font = '<system/bold>',
					},
					f:static_text {
						title = LOC(
							"$$$/Timelapse/PluginInfo/MinFfmpeg=Requires ffmpeg ^1 or newer.",
							FFmpegCommand.MIN_FFMPEG_VERSION),
					},
				},
			},

			f:separator { fill_horizontal = 1 },

			f:static_text {
				title = bind 'ffmpegStatus',
				truncation = 'middle',
				fill_horizontal = 1,
				width_in_chars = 50,
			},
			f:static_text {
				title = bind 'ffmpegWarningText',
				visible = bind 'ffmpegVersionInsufficient',
				fill_horizontal = 1,
				width_in_chars = 50,
				height_in_lines = 2,
			},

			f:row {
				spacing = f:control_spacing(),
				f:push_button {
					title = LOC "$$$/Timelapse/UI/DetectFFmpeg=Detect automatically",
					action = function()
						FFmpegLocator.saveUserPath(nil)
						propertyTable.ffmpegStatus = LOC "$$$/Timelapse/FFmpeg/Checking=Checking ffmpeg..."
						refreshStatus(propertyTable)
					end,
				},
				f:push_button {
					title = LOC "$$$/Timelapse/UI/SetFFmpeg=Set ffmpeg path...",
					action = function()
						local files = LrDialogs.runOpenPanel {
							title = LOC "$$$/Timelapse/UI/ChooseFFmpeg=Locate the ffmpeg binary",
							canChooseFiles = true,
							canChooseDirectories = false,
							allowsMultipleSelection = false,
							showHidden = true,
						}
						if files and files[1] then
							-- Button actions run on the main UI task; validate()
							-- yields (shells out via LrTasks.execute).
							LrTasks.startAsyncTask(function()
								local version = FFmpegLocator.validate(files[1])
								if version then
									FFmpegLocator.saveUserPath(files[1])
									refreshStatus(propertyTable)
								else
									LrDialogs.message(
										LOC "$$$/Timelapse/FFmpeg/Invalid=This file does not look like a working ffmpeg binary.",
										files[1], 'warning')
								end
							end, 'TimelapseCreator ffmpeg validation')
						end
					end,
				},
			},
		},
	}
end

return PluginInfoProvider
