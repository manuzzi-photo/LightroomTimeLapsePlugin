--[[----------------------------------------------------------------------------
check_version.lua — verifies that the plugin's version is declared
consistently across the codebase.

Info.lua and Version.lua cannot share a single source of truth: Info.lua is
parsed by Lightroom in a restricted environment where `require` does not
exist (see the comment in Info.lua), so its VERSION table is a hand-written
literal that must be kept in sync with Version.lua by hand. This script
catches the case where someone forgot.

Usage:
  lua scripts/check_version.lua            -- checks Info.lua vs Version.lua only
  lua scripts/check_version.lua 0.2.0      -- also checks both against this version
  lua scripts/check_version.lua v0.2.0     -- a leading "v" (as in a git tag) is stripped

Exits 0 if everything matches, 1 otherwise (with a diagnostic on stderr).
------------------------------------------------------------------------------]]

local scriptDir = arg[0]:match('^(.*)[/\\][^/\\]+$') or '.'
local pluginDir = scriptDir .. '/../TimelapseCreator.lrdevplugin'

local function fail(msg)
	io.stderr:write('check_version: ' .. msg .. '\n')
	os.exit(1)
end

local function readFile(path)
	local f, err = io.open(path, 'r')
	if not f then fail('cannot read ' .. path .. ': ' .. tostring(err)) end
	local content = f:read('*a')
	f:close()
	return content
end

-- Info.lua is not executed (it calls LOC(), a Lightroom global unavailable
-- here): its VERSION.display is extracted with a plain text-pattern match.
local function infoLuaVersion()
	local content = readFile(pluginDir .. '/Info.lua')
	local versionBlock = content:match('VERSION%s*=%s*{(.-)}')
	if not versionBlock then fail("Info.lua: no VERSION table found") end
	local display = versionBlock:match("display%s*=%s*'([^']+)'")
	if not display then fail("Info.lua: VERSION.display not found") end
	return display
end

-- Version.lua has no Lightroom dependencies, so it can be loaded directly.
local function versionLuaVersion()
	local chunk, err = loadfile(pluginDir .. '/Version.lua')
	if not chunk then fail('cannot load Version.lua: ' .. tostring(err)) end
	local ok, versionTable = pcall(chunk)
	if not ok then fail('cannot run Version.lua: ' .. tostring(versionTable)) end
	if not versionTable.display then fail('Version.lua: .display not found') end
	return versionTable.display
end

local infoVersion = infoLuaVersion()
local versionLuaVer = versionLuaVersion()

print(string.format('Info.lua VERSION.display    = %s', infoVersion))
print(string.format('Version.lua display         = %s', versionLuaVer))

local expected = arg[1]
if expected then
	expected = expected:gsub('^v', '')
	print(string.format('Expected (from argument)    = %s', expected))
end

local mismatches = {}
if infoVersion ~= versionLuaVer then
	mismatches[#mismatches + 1] = string.format(
		'Info.lua (%s) and Version.lua (%s) disagree', infoVersion, versionLuaVer)
end
if expected and infoVersion ~= expected then
	mismatches[#mismatches + 1] = string.format(
		'Info.lua (%s) does not match expected version (%s)', infoVersion, expected)
end
if expected and versionLuaVer ~= expected then
	mismatches[#mismatches + 1] = string.format(
		'Version.lua (%s) does not match expected version (%s)', versionLuaVer, expected)
end

if #mismatches > 0 then
	io.stderr:write('\ncheck_version: version mismatch:\n')
	for _, m in ipairs(mismatches) do
		io.stderr:write('  - ' .. m .. '\n')
	end
	os.exit(1)
end

print('\nOK: version is consistent.')
