--[[----------------------------------------------------------------------------
Version.lua — version string used by diagnostics and other UI.

NOT required by Info.lua: that file is parsed by Lightroom in a restricted
environment without `require` (confirmed by a plug-in load failure), so its
VERSION table is a separate literal that must be bumped by hand alongside
this file.
------------------------------------------------------------------------------]]

return {
	major = 0,
	minor = 3,
	revision = 0,
	build = 0,
	display = '0.3.0',
}
