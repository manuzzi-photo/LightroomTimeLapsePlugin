--[[----------------------------------------------------------------------------
ShutdownApp.lua — deletes the plugin's temporary work folder when Lightroom
quits, so preview and (failed-generation) session scratch files never
accumulate across app restarts.

This is a backstop: PreviewBuilder.cleanup() already runs when the Create
Timelapse dialog closes (see TimelapseDialog.lua). This handler also catches
the case where that never ran (dialog never opened this session, Lightroom
crashed, etc.) by wiping the whole temp root at once.
------------------------------------------------------------------------------]]

local LrFileUtils = import 'LrFileUtils'
local LrPathUtils = import 'LrPathUtils'

return {
	LrShutdownFunction = function(doneFunction, _progressFunction)
		local root = LrPathUtils.child(LrPathUtils.getStandardFilePath('temp'), 'TimelapseCreator')
		if LrFileUtils.exists(root) then
			LrFileUtils.delete(root)
		end
		doneFunction()
	end,
}
