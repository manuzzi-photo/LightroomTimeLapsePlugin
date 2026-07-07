--[[----------------------------------------------------------------------------
MenuItem.lua — entry point for "Create Timelapse...".
Collects the selected photos, filters out videos, sorts by capture time,
analyzes HDR availability, then opens the options dialog.
------------------------------------------------------------------------------]]

local LrApplication = import 'LrApplication'
local LrDialogs = import 'LrDialogs'
local LrFunctionContext = import 'LrFunctionContext'
local LrProgressScope = import 'LrProgressScope'
local LrTasks = import 'LrTasks'

local HdrDetector = require 'HdrDetector'
local TimelapseDialog = require 'TimelapseDialog'
local Log = require 'Log'

LrTasks.startAsyncTask(function()
	LrFunctionContext.callWithContext('TimelapseCreatorMenu', function(context)
		-- One continuous progress scope for the whole pre-dialog phase, so
		-- there is visible feedback from the moment the menu item is
		-- clicked (metadata reads and HDR checks can take a few seconds on
		-- large selections, with nothing else shown otherwise).
		local scope = LrProgressScope {
			title = LOC "$$$/Timelapse/Progress/Loading=Timelapse Creator: loading...",
			functionContext = context,
		}
		scope:setCancelable(true)
		scope:setIndeterminate()

		local catalog = LrApplication.activeCatalog()
		local photos = catalog:getTargetPhotos()

		if not photos or #photos == 0 then
			scope:done()
			LrDialogs.message(
				LOC "$$$/Timelapse/NoSelection/Title=No photos selected",
				LOC "$$$/Timelapse/NoSelection/Detail=Select the photos for the timelapse, then run the command again.",
				'info')
			return
		end

		scope:setCaption(LOC "$$$/Timelapse/Progress/ReadingMetadata=Reading photo metadata...")
		local meta = catalog:batchGetRawMetadata(photos,
			{ 'dateTimeOriginal', 'croppedDimensions', 'fileFormat', 'path' })

		local stills = {}
		for _, photo in ipairs(photos) do
			local m = meta[photo]
			if m and m.fileFormat ~= 'VIDEO' then
				stills[#stills + 1] = photo
			end
		end

		if #stills < 2 then
			scope:done()
			LrDialogs.message(
				LOC "$$$/Timelapse/TooFew/Title=Not enough photos",
				LOC "$$$/Timelapse/TooFew/Detail=A timelapse needs at least 2 still photos (a few hundred is typical).",
				'info')
			return
		end

		table.sort(stills, function(a, b)
			local ma, mb = meta[a], meta[b]
			local ta = ma.dateTimeOriginal or 0
			local tb = mb.dateTimeOriginal or 0
			if ta == tb then
				return (ma.path or '') < (mb.path or '')
			end
			return ta < tb
		end)

		local aspects = {}
		for _, photo in ipairs(stills) do
			local d = meta[photo].croppedDimensions
			if d and d.width and d.height and d.height > 0 then
				aspects[#aspects + 1] = d.width / d.height
			end
		end

		scope:setCaption(LOC "$$$/Timelapse/Progress/Analyze=Checking for HDR...")
		local hdrInfo = HdrDetector.analyze(stills, scope)
		scope:done()

		if scope:isCanceled() then return end

		Log:info(string.format('Opening dialog: %d photos, %d HDR', #stills, hdrInfo.hdrCount))
		TimelapseDialog.show(context, {
			photos = stills,
			aspects = aspects,
			hdrInfo = hdrInfo,
		})
	end)
end, 'TimelapseCreator menu')
