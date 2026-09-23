-- MobKill.lua — loaded by ShrimpLauncher (sUNC) in the mob game
-- (place 108480725212443). Kill-aura for the client CombatController melee
-- system: collects every alive mob (Model with a MobId attribute) in the
-- game's own mob folders within RANGE, then fires Remotes.AttackMob with
-- arrays of them — the exact payload shape the game's own scanHitbox
-- produces, batched to Constants.MELEE_MAX_TARGETS and preceded by the same
-- SwingWeapon:FireServer() the controller sends first.
--
-- Toggle lives in Combat > Mob Killer. No keybinds by design.

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local LocalPlayer = Players.LocalPlayer
local Shrimp      = getgenv().Shrimp

-- ============================ remotes ================================
local Remotes     = ReplicatedStorage:WaitForChild("Remotes")
local AttackMob   = Remotes:WaitForChild("AttackMob")
local SwingWeapon = Remotes:WaitForChild("SwingWeapon")

-- ============================ config =================================
local RANGE       = 75    -- studs around you to grab mobs
local TICK        = 0.35  -- seconds between swings
local FOLDER_SCAN = 8     -- seconds between mob-folder rescans (islands stream in)
local LOG_EVERY   = 3     -- seconds between console status prints
local DEFAULT_ON  = false -- true = start killing as soon as the menu opens

-- the game's own cap, read live so payloads always look legit
local MAX_TARGETS = 8
do
	local ok, Constants = pcall(function()
		return require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Constants"))
	end)
	if ok and Constants and Constants.MELEE_MAX_TARGETS then
		MAX_TARGETS = Constants.MELEE_MAX_TARGETS
	end
end

-- ======================= mob discovery ===============================
-- mirrors CombatController.mobScanFolders(): Islands.*.Mobs,
-- RogueIslands.*._ActiveMobs, ClimbRuns.*.Mobs, Hub.HubEventMobs
local mobFolders, lastScan = {}, 0

local function rescanFolders()
	mobFolders = {}
	local Islands = workspace:FindFirstChild("Islands")
	if Islands then
		for _, child in ipairs(Islands:GetChildren()) do
			local m = child:FindFirstChild("Mobs")
			if m then table.insert(mobFolders, m) end
		end
	end
	local Rogue = workspace:FindFirstChild("RogueIslands")
	if Rogue then
		for _, child in ipairs(Rogue:GetChildren()) do
			local m = child:FindFirstChild("_ActiveMobs")
			if m then table.insert(mobFolders, m) end
		end
	end
	local Runs = workspace:FindFirstChild("ClimbRuns")
	if Runs then
		for _, child in ipairs(Runs:GetChildren()) do
			local m = child:FindFirstChild("Mobs")
			if m then table.insert(mobFolders, m) end
		end
	end
	local Hub = workspace:FindFirstChild("Hub")
	if Hub then
		local m = Hub:FindFirstChild("HubEventMobs")
		if m then table.insert(mobFolders, m) end
	end
	lastScan = os.clock()
end

local function getRoot()
	local char = LocalPlayer.Character
	return char and char:FindFirstChild("HumanoidRootPart")
end

-- Alive mobs within RANGE, nearest first (the game also sorts by distance
-- when it has to cap the batch). Same dead-mob filter as scanHitbox.
local function collectMobs()
	local origin = getRoot()
	if not origin then return {} end
	local found = {}
	for _, folder in ipairs(mobFolders) do
		for _, m in ipairs(folder:GetDescendants()) do
			if m:IsA("Model") and m:GetAttribute("MobId") ~= nil then
				local hum = m:FindFirstChildOfClass("Humanoid")
				if not hum or hum.Health > 0 then
					local pos  = m:GetPivot().Position
					local dist = (pos - origin.Position).Magnitude
					if dist <= RANGE then
						found[#found + 1] = { mob = m, dist = dist }
					end
				end
			end
		end
	end
	table.sort(found, function(a, b) return a.dist < b.dist end)
	local out = {}
	for i, e in ipairs(found) do out[i] = e.mob end
	return out
end

-- ======================== state + loop ===============================
local MobKill = {}
local enabled = false
local hooks   = {}
local alive   = true

local function setEnabled(on)
	if enabled == on then return end
	enabled = on
	print(("[Shrimp] MobKill %s"):format(on and "ON" or "OFF"))
	for _, fn in ipairs(hooks) do pcall(fn, on) end
end

function MobKill.SetEnabled(on)       setEnabled(on and true or false) end
function MobKill.IsEnabled()          return enabled end
function MobKill.OnEnabledChanged(fn) table.insert(hooks, fn) end

local function killPass()
	local mobs = collectMobs()
	if #mobs == 0 then return 0 end
	pcall(function() SwingWeapon:FireServer() end) -- same no-arg call the controller makes first
	for i = 1, #mobs, MAX_TARGETS do
		local batch = {}
		for j = i, math.min(i + MAX_TARGETS - 1, #mobs) do
			batch[#batch + 1] = mobs[j]
		end
		pcall(function() AttackMob:FireServer(batch) end)
	end
	return #mobs
end

-- UI manifest: the library reads this — no UI code lives in modules
function MobKill.Describe()
	return {
		Name = "MobKill",
		Tab = { label = "Combat", icon = "swords" },
		Rows = {
			{ type = "Section", label = "Mob Killer" },
			{ type = "Toggle", label = "Mob Killer", Get = MobKill.IsEnabled,
				Set = MobKill.SetEnabled, Sync = "OnEnabledChanged" },
			{ type = "Label", Text = "Range " .. RANGE .. " studs · batch cap " .. MAX_TARGETS },
		},
	}
end

function MobKill.Start()
	setEnabled(DEFAULT_ON)
	table.insert(Shrimp.Cleanups, function() alive = false end)

	task.spawn(function()
		while alive do
			if enabled then
				if os.clock() - lastScan > FOLDER_SCAN then rescanFolders() end
				local n = killPass()
				if n > 0 then
					if not MobKill._lastLog or os.clock() - MobKill._lastLog > LOG_EVERY then
						MobKill._lastLog = os.clock()
						print(("[Shrimp] MobKill: swinging at %d mob(s)"):format(n))
					end
				end
				task.wait(TICK)
			else
				task.wait(0.25)
			end
		end
	end)

	print(("[Shrimp] MobKill ready — range %d studs, batch cap %d%s")
		:format(RANGE, MAX_TARGETS, DEFAULT_ON and " (auto-on)" or " (off — enable in Combat tab)"))
end

return MobKill
