--[[----------------------------------------------------------------------------
Timelapse Creator — Adobe Lightroom Classic plug-in
Creates a timelapse video from the selected photos using ffmpeg.

Copyright (C) 2026 Marco Manuzzi
Licensed under the GNU General Public License v3; see LICENSE.
------------------------------------------------------------------------------]]

return {

	LrSdkVersion = 13.0,
	LrSdkMinimumVersion = 13.0, -- HDREditMode develop settings require SDK 13

	LrToolkitIdentifier = 'com.marcomanuzzi.lightroom.timelapsecreator',
	LrPluginName = LOC "$$$/Timelapse/PluginName=Timelapse Creator",
	LrPluginInfoUrl = 'https://github.com/manuzzi-photo/LightroomTimeLapsePlugin',

	LrExportMenuItems = {
		{
			title = LOC "$$$/Timelapse/Menu/Create=Create Timelapse...",
			file = 'MenuItem.lua',
			enabledWhen = 'photosSelected',
		},
		{
			title = LOC "$$$/Timelapse/Menu/Diagnostics=Timelapse Diagnostics...",
			file = 'DiagnosticsMenuItem.lua',
		},
	},

	LrLibraryMenuItems = {
		{
			title = LOC "$$$/Timelapse/Menu/Create=Create Timelapse...",
			file = 'MenuItem.lua',
			enabledWhen = 'photosSelected',
		},
	},

	-- Diagnostic post-process action: dumps the real export-settings keys
	-- during a manual export, to discover the undocumented HDR keys.
	LrExportFilterProvider = {
		title = LOC "$$$/Timelapse/DumpFilter/Title=Timelapse: dump export settings (diagnostic)",
		file = 'ExportSettingsDumpFilter.lua',
		id = 'timelapseSettingsDump',
	},

	VERSION = { major = 0, minor = 1, revision = 0, build = 0, display = '0.1.0' },
}
