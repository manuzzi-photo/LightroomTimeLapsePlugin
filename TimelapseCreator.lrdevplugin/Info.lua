--[[----------------------------------------------------------------------------
Timelapse Creator — Adobe Lightroom Classic plug-in
Creates a timelapse video from the selected photos using ffmpeg.

Copyright (C) 2026 Marco Manuzzi
Licensed under the GNU General Public License v3; see LICENSE.
------------------------------------------------------------------------------]]

-- NOTE: Info.lua is parsed in a restricted environment where `require` does
-- not exist (confirmed by Lightroom's plug-in load error when it was used
-- here), so the version cannot be shared with Version.lua via require. Keep
-- this VERSION table in sync with Version.lua by hand when bumping.
return {

	LrSdkVersion = 13.0,
	LrSdkMinimumVersion = 13.0, -- HDREditMode develop settings require SDK 13

	LrToolkitIdentifier = 'com.marcomanuzzi.lightroom.timelapsecreator',
	LrPluginName = LOC "$$$/Timelapse/PluginName=Timelapse Creator",
	LrPluginInfoUrl = 'https://github.com/manuzzi-photo/LightroomTimeLapsePlugin',

	-- Plug-in Manager section: ffmpeg path configuration and version status.
	LrPluginInfoProvider = 'PluginInfoProvider.lua',

	-- Clears the temp work folder (previews, leftover failed-generation
	-- sessions) when Lightroom quits.
	LrShutdownApp = 'ShutdownApp.lua',

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

	VERSION = { major = 0, minor = 2, revision = 0, build = 0, display = '0.2.0' },
}
