--[[----------------------------------------------------------------------------
ExportSettingsDumpFilter.lua — diagnostic export filter (HDR spike).

The Lightroom Classic SDK documents no HDR export settings, but the Export
dialog does offer HDR output for some formats. This post-process action dumps
every export-settings key to a text file during a manual export, so we can
discover the undocumented keys (run an export once with HDR enabled and once
without, then diff the two dumps).

Usage: Export dialog → Post-Process Actions → add "Timelapse: dump export
settings", then export one photo. The dump path is shown in the section.
------------------------------------------------------------------------------]]

local LrPathUtils = import 'LrPathUtils'

local dumpPath = LrPathUtils.child(
	LrPathUtils.getStandardFilePath('temp'),
	'TimelapseCreator_export_settings_dump.txt')

local dumped = false

local function dumpSettings(exportSettings)
	if dumped then return end
	dumped = true
	local keys = {}
	for k in pairs(exportSettings) do
		keys[#keys + 1] = tostring(k)
	end
	table.sort(keys)
	local f = io.open(dumpPath, 'w')
	if not f then return end
	f:write('Timelapse Creator export settings dump — ' .. os.date() .. '\n\n')
	for _, k in ipairs(keys) do
		local v = exportSettings[k]
		f:write(string.format('%s = %s (%s)\n', k, tostring(v), type(v)))
	end
	f:close()
end

local function sectionForFilterInDialog(f, _)
	return {
		title = LOC "$$$/Timelapse/DumpFilter/Title=Timelapse: dump export settings (diagnostic)",
		f:row {
			f:static_text {
				title = LOC("$$$/Timelapse/DumpFilter/Note=On export, all settings keys are written to:^n^1", dumpPath),
				fill_horizontal = 1,
				height_in_lines = 2,
			},
		},
	}
end

local function shouldRenderPhoto(exportSettings, _)
	dumpSettings(exportSettings)
	return true
end

return {
	exportPresetFields = {},
	sectionForFilterInDialog = sectionForFilterInDialog,
	shouldRenderPhoto = shouldRenderPhoto,
}
