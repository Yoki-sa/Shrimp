-- AutoFire.lua — loaded by ShrimpLauncher (sUNC)
-- Hold the swing bind -> fires ToolSystem.Swing at a fixed rate (default
-- 10/s). The old build fired every frame (~60/s), which lagged the game for
-- zero gain — the server enforces the swing cooldown regardless, so anything
-- past the cooldown window is wasted traffic. The tool name sent is
-- auto-picked from whatever the crosshair is over:
--     target name matches an ore keyword (ore/stone/metal/sulfur/hq,
--     case-insensitive) -> Metal Pickaxe
--     anything else                     -> Metal Hatchet (or held tool)
-- (no matter what the player is actually holding)
--
-- Default binds (rebindable in the menu):
--   Swing: hold LMB, toggle T

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService        = game:GetService("RunService")
local UserInputService  = game:GetService("UserInputService")

local LocalPlayer = Players.LocalPlayer
local Mouse       = LocalPlayer:GetMouse()

local Shrimp   = getgenv().Shrimp
local Keybinds = Shrimp.Modules.Keybinds

-- ============================ remotes ================================
local SwingRemote = ReplicatedStorage:WaitForChild("ToolSystem")
	:WaitForChild("RemoteEvents"):WaitForChild("Swing")

-- ============================ config =================================
-- Ore nodes aren't consistently named ("Sulfur Ore" vs plain "Stone"), so
-- match any known ore keyword instead of just "ore".
local ORE_KEYWORDS = { "ore", "sulfur", "metal", "hq", "stone" }
local PICKAXE_TOOL = "Metal Pickaxe"   -- sent when the target looks like ore
local HATCHET_TOOL = "Metal Hatchet"   -- sent for everything else
local RAY_DISTANCE = 1000              -- same reach as the game's raycasts

local SWING_RATE = 10                  -- swings/second while held (2-30)

-- =========================== targeting ===============================
local rayParams = RaycastParams.new()
rayParams.FilterType  = Enum.RaycastFilterType.Exclude
rayParams.IgnoreWater = true

local filterScratch = {} -- reused; Roblox snapshots the array on assignment
local function centerRayHit()
	local cam = workspace.CurrentCamera
	if not cam then return nil end
	local char = LocalPlayer.Character
	filterScratch[1] = char or cam
	filterScratch[2] = char and cam or nil
	rayParams.FilterDescendantsInstances = filterScratch
	local unit = cam:ViewportPointToRay(cam.ViewportSize.X * 0.5, cam.ViewportSize.Y * 0.5)
	return workspace:Raycast(unit.Origin, unit.Direction * RAY_DISTANCE, rayParams)
end

local function nameLooksLikeOre(name)
	local l = name:lower()
	for _, k in ipairs(ORE_KEYWORDS) do
		if l:find(k, 1, true) then return true end
	end
	return false
end

-- The ore keyword can be on the hit part OR its ancestor model, so walk the
-- chain up to Workspace and match any name.
local function targetLooksLikeOre()
	local hit = centerRayHit()
	local inst = hit and hit.Instance
	while inst and inst ~= workspace do
		if inst.Name and nameLooksLikeOre(inst.Name) then
			return true
		end
		inst = inst.Parent
	end
	return false
end

-- ============================== swing ================================
local function pickToolName()
	if targetLooksLikeOre() then
		return PICKAXE_TOOL
	end
	-- nothing ore-like under the crosshair: use the equipped tool if there
	-- is one, otherwise default to the hatchet
	local char = LocalPlayer.Character
	local tool = char and char:FindFirstChildOfClass("Tool")
	return tool and tool.Name or HATCHET_TOOL
end

local function doSwing()
	SwingRemote:FireServer(Mouse.UnitRay.Direction, pickToolName())
end

-- ====================== state + input loops ==========================
local AutoFire = {}
local enabled = { SWING = true }
local hooks   = {}

local function setEnabled(name, on)
	if enabled[name] == on then return end
	enabled[name] = on
	print(("[Shrimp] %s %s"):format(name, on and "ON" or "OFF"))
	for _, fn in ipairs(hooks[name] or {}) do pcall(fn, on) end
end

function AutoFire.SetEnabled(name, on) setEnabled(name, on and true or false) end
function AutoFire.IsEnabled(name)      return enabled[name] end
function AutoFire.OnEnabledChanged(name, fn)
	hooks[name] = hooks[name] or {}
	table.insert(hooks[name], fn)
end

function AutoFire.GetRate() return SWING_RATE end
function AutoFire.SetRate(r)
	SWING_RATE = math.clamp(math.floor((tonumber(r) or SWING_RATE) + 0.5), 2, 30)
	return SWING_RATE
end

local function watchHold(bindName, fireFn)
	-- Hold state is tracked purely from input EVENTS (a `held` boolean),
	-- never from IsMouseButtonPressed/IsKeyDown polling — several executor
	-- VMs report those poll APIs as always-false, which kills the hold spam
	-- after the first swing. Events are reliable everywhere.
	--
	-- Firing is throttled to SWING_RATE per second: the every-frame version
	-- sent ~60 remotes + raycasts a second and lagged the game for nothing.
	local held = false
	local last = 0
	local c1 = UserInputService.InputBegan:Connect(function(input, gameProcessed)
		if Keybinds.Matches(bindName, input) then
			if gameProcessed then
				held = false -- press started on UI; this hold doesn't count
			else
				held = true
				last = os.clock()
				fireFn() -- instant fire on press, no frame latency
			end
		end
	end)
	local c2 = UserInputService.InputEnded:Connect(function(input)
		if Keybinds.Matches(bindName, input) then held = false end
	end)
	local c3 = RunService.Heartbeat:Connect(function()
		if held then
			local now = os.clock()
			if now - last >= 1 / SWING_RATE then
				last = now
				fireFn()
			end
		end
	end)
	-- launcher runs these on re-execute so old loops never double-fire
	table.insert(Shrimp.Cleanups, function()
		c1:Disconnect() c2:Disconnect() c3:Disconnect()
	end)
end

-- tap a bind to flip an action on/off (synced with the menu toggles)
local function makeToggle(toggleBind, actionName)
	local c = UserInputService.InputBegan:Connect(function(input, gameProcessed)
		if gameProcessed then return end
		if Keybinds.Matches(toggleBind, input) then
			setEnabled(actionName, not enabled[actionName])
		end
	end)
	table.insert(Shrimp.Cleanups, function() c:Disconnect() end)
end

-- UI manifest
function AutoFire.Describe()
	return {
		Name = "AutoFire",
		Tab = { label = "Combat", icon = "crosshair" },
		Rows = {
			{ type = "Section", label = "Auto Swing" },
			{ type = "Toggle", label = "Auto Swing", Get = function() return enabled.SWING end,
				Set = function(v) AutoFire.SetEnabled("SWING", v) end,
				Sync = "OnEnabledChanged", SyncKey = "SWING" },
			{ type = "Keybind", label = "Auto Swing — hold", Bind = "SWING", Default = Enum.UserInputType.MouseButton1 },
			{ type = "Keybind", label = "Auto Swing — toggle", Bind = "SWING_TOGGLE", Default = Enum.KeyCode.T },
			{ type = "Slider", label = "Swing Rate (/s)", Min = 2, Max = 30, Get = AutoFire.GetRate, Set = AutoFire.SetRate },
		},
	}
end

function AutoFire.Start()
	Keybinds.Register("SWING",        Enum.UserInputType.MouseButton1)
	Keybinds.Register("SWING_TOGGLE", Enum.KeyCode.T)
	-- TOGGLE_MENU is registered by the UI library, not here

	makeToggle("SWING_TOGGLE", "SWING")

	watchHold("SWING", function()
		if enabled.SWING then doSwing() end
	end)

	print(("[Shrimp] AutoFire running — hold LMB (T toggles) at %d swings/s. Tool: %s on ore, %s otherwise")
		:format(SWING_RATE, PICKAXE_TOOL, HATCHET_TOOL))
end

return AutoFire
