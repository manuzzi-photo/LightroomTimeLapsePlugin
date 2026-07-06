--[[----------------------------------------------------------------------------
Log.lua — shared logger for the plug-in.
The log file is written by Lightroom to its standard plug-in log location
(on macOS: ~/Library/Logs/Adobe/Lightroom/ or the Documents/lrClassicLogs
folder, depending on the Lightroom version).
------------------------------------------------------------------------------]]

local LrLogger = import 'LrLogger'

local logger = LrLogger('TimelapseCreator')
logger:enable('logfile')

return logger
