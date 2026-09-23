-- ShrimpLauncher.lua — sUNC entry point (game-agnostic)
-- Zero hardcoded games. Flow:
--   1. grab the PlaceId
--   2. look for games/<PlaceId>/ next to this script
--   3. load every .lua in it as a module (whatever the game needs)
--   4. shared modules (Keybinds, Icons) always load; modules with a
--      .Describe() manifest get their UI rows built by ShrimpUI
--   5. unknown game with no folder -> clear message, nothing half-loads
--
-- Adding a game = create games/<PlaceId>/ and drop modules in. That's it.

local FOLDER = "shrimp" -- executor workspace folder all paths hang off

local Shrimp = getgenv().Shrimp
if not Shrimp or not Shrimp.Modules then
	getgenv().Shrimp = {
		Folder   = FOLDER,
		Modules  = {},
		Cleanups = {},
		Game     = tostring(game.PlaceId),
	}
	Shrimp = getgenv().Shrimp
end
Shrimp.Folder  = Shrimp.Folder or FOLDER
Shrimp.Game    = tostring(game.PlaceId)
Shrimp.GameDir = FOLDER .. "/games/" .. Shrimp.Game -- modules load assets from here

-- Tear down the PREVIOUS session first: if this ran after Start(), it would
-- disconnect the connections modules just created.
local function runCleanups()
	local list = Shrimp.Cleanups or {}
	Shrimp.Cleanups = {}
	for _, fn in ipairs(list) do
		pcall(fn)
	end
end
runCleanups()

-- ============================ helpers =================================

local function loadModule(name)
	local mod = Shrimp.Modules[name]
	if mod then return mod end
	local path = ("%s/%s.lua"):format(FOLDER, name)
	local ok, src = pcall(readfile, path)
	if not ok or not src then
		warn(("[Shrimp] missing module %s"):format(path))
		return nil
	end
	local chunk = loadstring(src, "=" .. name .. ".lua")
	if not chunk then
		warn(("[Shrimp] %s failed to compile"):format(name))
		return nil
	end
	local good, result = pcall(chunk)
	if not good then
		warn(("[Shrimp] %s errored on load: %s"):format(name, tostring(result)))
		return nil
	end
	Shrimp.Modules[name] = result
	print(("[Shrimp] loaded %s"):format(name))
	return result
end

-- ============================ boot ====================================

local placeId = tostring(game.PlaceId)
local gameDir = FOLDER .. "/games/" .. placeId

local okList, entries = pcall(function() return listfiles(gameDir) end)
if not okList or not entries or #entries == 0 then
	warn(("[Shrimp] no module folder for this game (games/%s/) — nothing to load."):format(placeId))
	warn(("[Shrimp] create games/%s/ and drop .lua modules in to add a game."):format(placeId))
	return
end

-- Shared modules first: every game gets Keybinds + Icons.
loadModule("Keybinds")
loadModule("Icons")

-- Per-game modules from games/<PlaceId>/*.lua — folder contents decide
-- everything; the launcher hardcodes nothing.
local loaded = {}	for _, file in ipairs(entries) do
		local name = file:match("([^/\\]+)%.lua$")
		if name then
			local mod = loadModule("games/" .. placeId .. "/" .. name)
			if mod then
				loaded[#loaded + 1] = { name = name, mod = mod, path = "games/" .. placeId .. "/" .. name }
			end
		end
	end

if #loaded == 0 then
	warn(("[Shrimp] games/%s/ has no loadable modules"):format(placeId))
	return
end

-- Start every module that wants starting, keep manifests for the UI.
local manifest = {}
for _, e in ipairs(loaded) do
	if type(e.mod.Start) == "function" then
		local ok, err = pcall(e.mod.Start)
		if not ok then
			warn(("[Shrimp] %s.Start() errored: %s"):format(e.name, tostring(err)))
		end
	end
	if type(e.mod.Describe) == "function" then
		local okD, spec = pcall(e.mod.Describe)
		if okD and type(spec) == "table" then
			spec._mod   = e.mod
			spec._name  = e.name
			manifest[#manifest + 1] = spec
		end
	end
end

print(("[Shrimp] place %s: %d module(s) loaded, %d with UI manifests")
	:format(placeId, #loaded, #manifest))

-- ============================ UI ======================================

local ShrimpUI = loadModule("ShrimpUI")
if ShrimpUI and type(ShrimpUI.Show) == "function" then
	local ok, err = pcall(ShrimpUI.Show, Shrimp.Gui and Shrimp.Gui.Parent or nil, manifest)
	if not ok then
		warn(("[Shrimp] UI failed: %s"):format(tostring(err)))
	end
else
	warn("[Shrimp] ShrimpUI.lua missing or broken — modules run headless (binds still work)")
end
