-- Climb.lua — loaded by ShrimpLauncher (sUNC) in the mob game
-- Automates the Climb tower mode using the remotes surfaced by the
-- decompiled ClimbController:
--   ClimbStart :InvokeServer(floorId, difficultyId) -> { Ok, Message }
--   ClimbLeave :FireServer()          ClimbGiveUp :FireServer()
--   ClimbRun.OnClientEvent    -> run state { Active, Elapsed, Reward, ... }
--   ClimbResult.OnClientEvent -> run finished { FloorName, ... }
--
-- Auto Climb: starts a run on the chosen floor/difficulty whenever none is
-- active, and re-starts after a finished run (Restart Delay).
-- Give Up On Death: fires ClimbGiveUp when you die mid-run so the loop
-- keeps going while AFK.
--
-- NOT automated on purpose: ClimbRevive and ClimbBuy — both are tied to
-- Robux products (ReviveProductId / purchase prompts) and firing them can
-- spend Robux. Only manual Leave/Give Up buttons are exposed.

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local LocalPlayer = Players.LocalPlayer
local Shrimp      = getgenv().Shrimp

-- ============================ remotes ================================
local Remotes     = ReplicatedStorage:WaitForChild("Remotes")
local ClimbStart  = Remotes:WaitForChild("ClimbStart")
local ClimbLeave  = Remotes:WaitForChild("ClimbLeave")
local ClimbGiveUp = Remotes:WaitForChild("ClimbGiveUp")
local ClimbRun    = Remotes:WaitForChild("ClimbRun")
local ClimbResult = Remotes:WaitForChild("ClimbResult")

-- ============================ config =================================
local POLL          = 1.0 -- loop cadence (s)
local FAIL_COOLDOWN = 4   -- min seconds between start attempts after a rejection

-- ============================ state ==================================
local enabled      = false
local autoGiveUp   = true
local floor        = 1
local difficulty   = "easy"
local restartDelay = 2

local runActive    = false
local busy         = false
local lastFailAt   = 0
local lastResultAt = 0
local elapsedBase, elapsedT0 = 0, os.clock()

local lastStatus  = "Idle"
local hooks       = {}  -- enabled-changed listeners
local statusHooks = {}  -- status listeners
local alive       = true

local Climb = {}

local function setStatus(text)
	lastStatus = text
	for _, fn in ipairs(statusHooks) do pcall(fn, text) end
end

local function runElapsed()
	if not runActive then return 0 end
	return math.floor(elapsedBase + (os.clock() - elapsedT0))
end

-- ========================= start attempt =============================
local function attemptStart()
	busy = true
	setStatus(("Starting floor %d (%s)…"):format(floor, difficulty))
	task.spawn(function()
		local ok, res = pcall(function()
			return ClimbStart:InvokeServer(floor, difficulty)
		end)
		busy = false
		if not ok then
			lastFailAt = os.clock()
			warn("[Shrimp] ClimbStart error: " .. tostring(res))
			setStatus("Start failed — retrying")
			return
		end
		if type(res) == "table" and res.Ok then
			print(("[Shrimp] Climb started — floor %d (%s)"):format(floor, difficulty))
		else
			lastFailAt = os.clock()
			local msg = type(res) == "table" and tostring(res.Message) or tostring(res)
			print("[Shrimp] ClimbStart rejected: " .. msg)
			setStatus("Rejected: " .. msg)
		end
	end)
end

-- =========================== main loop ===============================
task.spawn(function()
	while alive do
		if enabled and not busy then
			if runActive then
				setStatus(("In run · floor %d · %ds"):format(floor, runElapsed()))
			else
				local nextStart = math.max(lastResultAt + restartDelay, lastFailAt + FAIL_COOLDOWN)
				if os.clock() >= nextStart then
					attemptStart()
				else
					setStatus(("Idle — next run in %ds"):format(math.ceil(nextStart - os.clock())))
				end
			end
		end
		task.wait(POLL)
	end
end)

-- ======================= remote listeners ============================
local runConn = ClimbRun.OnClientEvent:Connect(function(p)
	if type(p) ~= "table" then return end
	if p.Active == true then
		if not runActive then
			print("[Shrimp] Climb run started")
		end
		runActive = true
		elapsedBase = tonumber(p.Elapsed) or 0
		elapsedT0 = os.clock()
	else
		if runActive then
			print("[Shrimp] Climb run ended")
		end
		runActive = false
		lastResultAt = os.clock() -- grace period before the next start
	end
end)

local resultConn = ClimbResult.OnClientEvent:Connect(function(p)
	if type(p) ~= "table" then return end
	lastResultAt = os.clock()
	print("[Shrimp] Climb result: " .. tostring(p.FloorName or "?"))
	setStatus("Finished: " .. tostring(p.FloorName or "?"))
end)

-- ===================== give up on death ==============================
local diedConn
local function hookCharacter(char)
	if diedConn then diedConn:Disconnect() diedConn = nil end
	if not char then return end
	task.spawn(function()
		local hum = char:WaitForChild("Humanoid", 10)
		if not hum or not alive then return end
		diedConn = hum.Died:Connect(function()
			if autoGiveUp and runActive then
				task.spawn(function()
					task.wait(1.5)
					pcall(function() ClimbGiveUp:FireServer() end)
					print("[Shrimp] Climb: died mid-run — fired Give Up, farm loop continues")
				end)
			end
		end)
	end)
end
hookCharacter(LocalPlayer.Character)
local charConn = LocalPlayer.CharacterAdded:Connect(hookCharacter)

table.insert(Shrimp.Cleanups, function()
	alive = false
	runConn:Disconnect() resultConn:Disconnect()
	if diedConn then diedConn:Disconnect() end
	charConn:Disconnect()
end)

-- ============================ API ====================================
function Climb.SetEnabled(on)
	if enabled == on then return end
	enabled = on and true or false
	print(("[Shrimp] Auto Climb %s"):format(enabled and "ON" or "OFF"))
	if enabled then
		lastResultAt = 0 -- attempt immediately on toggle-on
		lastFailAt = 0
	end
	for _, fn in ipairs(hooks) do pcall(fn, enabled) end
end
function Climb.IsEnabled()          return enabled end
function Climb.OnEnabledChanged(fn) table.insert(hooks, fn) end

function Climb.SetFloor(n)        floor = math.max(1, math.floor(tonumber(n) or 1)) end
function Climb.GetFloor()         return floor end
function Climb.SetDifficulty(s)   difficulty = tostring(s) end
function Climb.GetDifficulty()    return difficulty end
function Climb.SetRestartDelay(n) restartDelay = math.max(0, tonumber(n) or 0) end
function Climb.GetRestartDelay()  return restartDelay end
function Climb.SetAutoGiveUp(v)   autoGiveUp = v and true or false end
function Climb.GetAutoGiveUp()    return autoGiveUp end

function Climb.OnStatus(fn) table.insert(statusHooks, fn) end
function Climb.GetStatus()  return lastStatus end

function Climb.Leave()
	task.spawn(function()
		pcall(function() ClimbLeave:FireServer() end)
		print("[Shrimp] Climb: leave fired")
	end)
end

function Climb.GiveUp()
	task.spawn(function()
		pcall(function() ClimbGiveUp:FireServer() end)
		print("[Shrimp] Climb: give up fired")
	end)
end

-- UI manifest
function Climb.Describe()
	return {
		Name = "AutoClimb",
		Tab = { label = "Climb", icon = "mountain" },
		Rows = {
			{ type = "Section", label = "Auto Climb" },
			{ type = "Toggle", label = "Auto Climb", Get = Climb.IsEnabled,
				Set = Climb.SetEnabled, Sync = "OnEnabledChanged" },
			{ type = "Slider", label = "Floor", Min = 1, Max = 20, Get = Climb.GetFloor,
				Set = Climb.SetFloor },
			{ type = "Dropdown", label = "Difficulty", Options = { "easy", "medium", "hard" },
				Get = Climb.GetDifficulty, Set = Climb.SetDifficulty },
			{ type = "Slider", label = "Restart Delay (s)", Min = 0, Max = 30, Get = Climb.GetRestartDelay,
				Set = Climb.SetRestartDelay },
			{ type = "Toggle", label = "Give Up On Death", Get = Climb.GetAutoGiveUp,
				Set = Climb.SetAutoGiveUp },
			{ type = "Label", Get = Climb.GetStatus, On = function(_, fn) Climb.OnStatus(fn) end },
			{ type = "Section", label = "Run Controls" },
			{ type = "Button", label = "Leave Run", Call = Climb.Leave },
			{ type = "Button", label = "Give Up", Call = Climb.GiveUp },
		},
	}
end

function Climb.Start()
	print(("[Shrimp] Climb module ready — floor %d (%s), Auto Climb %s")
		:format(floor, difficulty, enabled and "ON" or "OFF (enable in Settings)"))
end

return Climb
