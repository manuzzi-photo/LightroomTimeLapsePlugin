--[[----------------------------------------------------------------------------
HdrDetector.lua — checks whether the selected photos are edited in HDR mode.

Uses the HDREditMode develop setting (available since Lightroom Classic SDK
13.0). HDR output is only offered when *all* photos in the selection are HDR.
------------------------------------------------------------------------------]]

local LrTasks = import 'LrTasks'

local HdrDetector = {}

-- Returns { total, hdrCount, allHdr }.
function HdrDetector.analyze(photos, progressScope)
	local hdrCount = 0
	for i = 1, #photos do
		local photo = photos[i]
		local ok, settings = pcall(photo.getDevelopSettings, photo)
		if ok and type(settings) == 'table' then
			local mode = settings.HDREditMode
			if mode == 1 or mode == true then
				hdrCount = hdrCount + 1
			end
		end
		if i % 25 == 0 then
			if progressScope then
				if progressScope:isCanceled() then break end
				progressScope:setPortionComplete(i, #photos)
			end
			LrTasks.yield()
		end
	end
	return {
		total = #photos,
		hdrCount = hdrCount,
		allHdr = (#photos > 0 and hdrCount == #photos),
	}
end

return HdrDetector
