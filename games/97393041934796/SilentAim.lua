-- SilentAim.lua — loaded by ShrimpLauncher (sUNC)
-- Silent aim for GunSystem: the Shot remote is client-authoritative about
-- direction — the game itself sends {CameraOrigin, CameraDirection, ...}
-- and the server raycasts along them. A direct hookfunction on the
-- remote's FireServer rewrites CameraDirection toward the target closest
-- to the crosshair (inside the FOV circle) before the remote fires, so
-- bullets land on the target while your view, crosshair and tracers stay
-- exactly where you're aiming.
--
-- NOTE: hooked via __namecall with a PLAIN function (no newcclosure).
-- hookfunction(FireServer) never catches the game's calls (Luau method
-- calls go through __namecall), and newcclosure-wrapped namecall hooks
-- mis-marshal the re-entry on Potassium ("argument #1 expects a string").
-- The plain-function + table.pack/unpack shape matches the user's proven
-- Cobalt interceptor; the intercepted shot is replayed through a DOT call
-- to the real FireServer (bypasses __namecall, immune to the namecall-
-- method register being clobbered by our own camera/raycast calls).
--
-- The hook is permanent (function hooks can't be removed), so it installs
-- ONCE and reads a shared config table on getgenv — re-executes reuse it
-- and the new menu keeps working because both runs share the same table.
--
-- Default bind: H toggles (rebindable in the menu).

local Players           = game:GetService("Players")
local RunService        = game:GetService("RunService")
local UserInputService  = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Debris            = game:GetService("Debris")

local LocalPlayer = Players.LocalPlayer
local Shrimp   = getgenv().Shrimp
local Keybinds = Shrimp.Modules.Keybinds

local SilentAim = {}

-- Shared config (survives re-executes — the permanent hook reads this).
local Config = Shrimp.SilentAimConfig
if not Config then
	Config = {
		Enabled        = true,
		FOV            = 140,    -- pixels around the crosshair
		HitPart        = "Head", -- Head | Torso
		VisibleCheck   = true,   -- only lock on targets with line of sight
		ShowFOV        = true,
		RedirectTracer = true,   -- green confirmation line on redirected shots
		Prediction      = true,   -- lead moving targets by their velocity
		PredictionStrength = 1,   -- seconds of travel time used for the lead
		FOVColor       = Color3.fromRGB(255, 255, 255),
	}
	Shrimp.SilentAimConfig = Config
end
if Config.RedirectTracer == nil then Config.RedirectTracer = true end -- backfill older shared configs
if Config.Prediction == nil then Config.Prediction = true end
if Config.PredictionStrength == nil then Config.PredictionStrength = 1 end

local listeners = {}
local function fireHook(key)
	for _, fn in ipairs(listeners[key] or {}) do pcall(fn, Config[key]) end
end

local SETTERS = { "Enabled", "FOV", "HitPart", "VisibleCheck", "ShowFOV", "RedirectTracer",
	"Prediction", "PredictionStrength" }
for _, key in ipairs(SETTERS) do
	SilentAim["Set" .. key] = function(v) Config[key] = v fireHook(key) end
	SilentAim["Get" .. key] = function() return Config[key] end
end
SilentAim.Config = Config
function SilentAim.OnChanged(key, fn)
	listeners[key] = listeners[key] or {}
	table.insert(listeners[key], fn)
end

-- ============================ targeting ==============================
local rayParams = RaycastParams.new()
rayParams.FilterType  = Enum.RaycastFilterType.Exclude
rayParams.IgnoreWater = true

local function aimPartFor(char)
	if Config.HitPart == "Torso" then
		return char:FindFirstChild("HumanoidRootPart") or char:FindFirstChild("Head")
	end
	return char:FindFirstChild("Head") or char:FindFirstChild("HumanoidRootPart")
end

-- Closest-to-crosshair target inside the FOV circle (Z > 0 only — behind-
-- camera projections lie, same trap the ESP edge-sticking came from).
local function pickTarget(cam)
	local center   = cam.ViewportSize / 2
	local best     = nil
	local bestDist = Config.FOV
	for _, pl in ipairs(Players:GetPlayers()) do
		if pl ~= LocalPlayer then
			local char = pl.Character
			local hum  = char and char:FindFirstChildOfClass("Humanoid")
			local part = char and aimPartFor(char)
			if part and hum and hum.Health > 0 then
				local sp = cam:WorldToViewportPoint(part.Position)
				if sp.Z > 0.5 then
					local d = (Vector2.new(sp.X, sp.Y) - center).Magnitude
					if d <= bestDist then
						if Config.VisibleCheck then
							local charL = LocalPlayer.Character
							rayParams.FilterDescendantsInstances = charL and { charL, cam } or { cam }
							local hit = workspace:Raycast(cam.CFrame.Position,
								part.Position - cam.CFrame.Position, rayParams)
							if hit and (hit.Instance == part or hit.Instance:IsDescendantOf(char)) then
								best, bestDist = part, d
							end
						else
							best, bestDist = part, d
						end
					end
				end
			end
		end
	end
	return best
end

-- Velocity lead: aiming at where the target WILL be. Predicted point is
-- clamped to a sphere around the current aim part (radius ~ hitbox size + 4
-- studs) so fast targets can't be led out of their own body.
local function predictPart(part)
	if not (Config.Prediction and Config.PredictionStrength > 0) then return part.Position end
	local ok, pos = pcall(function()
		local v = part.AssemblyLinearVelocity
		if typeof(v) ~= "Vector3" or v.Magnitude < 0.5 then return part.Position end
		local t   = Config.PredictionStrength
		local p   = part.Position + v * t
		local rad = math.max(part.Size.Magnitude * 0.5, 4) + 4
		local off = p - part.Position
		if off.Magnitude > rad then p = part.Position + off.Unit * rad end
		return p
	end)
	return ok and pos or part.Position
end

-- ============================ fov circle =============================
local circle = nil
pcall(function()
	circle = Drawing.new("Circle")
	circle.Thickness = 1
	circle.Filled    = false
	circle.Visible   = false
	circle.Color     = Config.FOVColor
end)

-- Confirmation tracer: short-lived green line from the real muzzle to the
-- redirected hit point. The game's own orange tracer still shows the
-- crosshair path (client prediction runs BEFORE our hook — confirmed in the
-- GunShootModule decompile), so this is the only visual showing where the
-- server will actually register the hit.
local function spawnRedirectTracer(from, to)
	local len = (to - from).Magnitude
	if len < 0.1 then return end
	local part = Instance.new("Part")
	part.Name        = "ShrimpRedirectTracer"
	part.Size        = Vector3.new(0.06, 0.06, len)
	part.Anchored    = true
	part.CanCollide  = false
	part.CanTouch    = false
	part.CanQuery    = false
	part.CastShadow  = false
	part.Material    = Enum.Material.Neon
	part.Color       = Color3.fromRGB(85, 255, 127)
	part.CFrame      = CFrame.lookAt(from, to) * CFrame.new(0, 0, -len / 2)
	part.Parent      = workspace
	Debris:AddItem(part, 0.2)
end

-- ============================== hook =================================
local ShotRemote = ReplicatedStorage:WaitForChild("GunSystem")
	:WaitForChild("RemoteEvents"):WaitForChild("Shot")

-- UI manifest
function SilentAim.Describe()
	return {
		Name = "SilentAim",
		Tab = { label = "Combat", icon = "crosshair" },
		Rows = {
			{ type = "Section", label = "Silent Aim" },
			{ type = "Toggle", label = "Silent Aim", Get = SilentAim.GetEnabled,
				Set = SilentAim.SetEnabled, Sync = "OnChanged", SyncKey = "Enabled" },
			{ type = "Dropdown", label = "Aim Part", Options = { "Head", "Torso" },
				Get = SilentAim.GetHitPart, Set = SilentAim.SetHitPart },
			{ type = "Slider", label = "FOV (px)", Min = 30, Max = 500, Get = SilentAim.GetFOV, Set = SilentAim.SetFOV },
			{ type = "Toggle", label = "FOV Circle", Get = SilentAim.GetShowFOV, Set = SilentAim.SetShowFOV },
			{ type = "Toggle", label = "Redirect Tracer", Get = SilentAim.GetRedirectTracer, Set = SilentAim.SetRedirectTracer },
			{ type = "Toggle", label = "Prediction", Get = SilentAim.GetPrediction,
				Set = SilentAim.SetPrediction },
			{ type = "Slider", label = "Prediction Strength", Min = 0.1, Max = 2, Step = 0.1,
				Get = SilentAim.GetPredictionStrength, Set = SilentAim.SetPredictionStrength },
			{ type = "Toggle", label = "Visible Check", Get = SilentAim.GetVisibleCheck, Set = SilentAim.SetVisibleCheck },
			{ type = "Keybind", label = "Silent Aim — toggle", Bind = "SILENT_AIM_TOGGLE", Default = Enum.KeyCode.H },
		},
	}
end

function SilentAim.Start()
	-- __namecall hook, mirroring the user's proven Cobalt interceptor shape:
	-- a PLAIN function (newcclosure wrappers mis-marshal the re-entry into
	-- the original on Potassium — that was the "argument #1 expects a
	-- string" storm), args table.pack'd and replayed verbatim.
	-- (hookfunction on FireServer alone never catches the game's calls:
	-- Luau routes method calls through __namecall, bypassing the indexed
	-- closure — which is why the previous build silently did nothing.)
	if not Shrimp.SilentAimNamecallHooked then
		local ok, err = pcall(function()
			local mtHook
			mtHook = hookmetamethod(game, "__namecall", function(...)
				local self = ...
				if rawequal(self, ShotRemote) and getnamecallmethod() == "FireServer" then
					local Args = table.pack(...)
					local payload = Args[2]
					if Config.Enabled and type(payload) == "table"
						and payload.CameraOrigin and payload.CameraDirection then
						-- pcall: a target-pick failure must never break the shot
						pcall(function()
							local cam    = workspace.CurrentCamera
							local target = cam and pickTarget(cam)
							if target then
									local aimPos = predictPart(target)
									local d = aimPos - payload.CameraOrigin
									if d.Magnitude > 0.001 then
										payload.CameraDirection = d.Unit
										if Config.RedirectTracer and typeof(payload.MuzzleOrigin) == "Vector3" then
											spawnRedirectTracer(payload.MuzzleOrigin, aimPos)
										end
									end
							end
						end)
						if not Shrimp.SilentAimSeenShot then
							Shrimp.SilentAimSeenShot = true
							print("[Shrimp] SilentAim: Shot intercepted — redirect active")
						end
					end
					-- Replay through the REAL FireServer via a DOT call: this
					-- bypasses __namecall entirely. Calling the original namecall
					-- directly was the bug — pickTarget's own cam:WorldToViewport-
					-- Point / workspace:Raycast calls overwrite the thread's
					-- namecall-method register, so the original then ran with
					-- method "WorldToViewportPoint" on the remote ("is not a valid
					-- member of RemoteEvent"). Dot-calls carry no method at all.
					return ShotRemote.FireServer(ShotRemote, table.unpack(Args, 2, Args.n))
				end
				return mtHook(...)
			end)
		end)
		Shrimp.SilentAimNamecallHooked = ok
		if not ok then
			warn("[Shrimp] SilentAim: namecall hook failed (" .. tostring(err)
				.. ") — silent aim disabled")
		end
	end

	Keybinds.Register("SILENT_AIM_TOGGLE", Enum.KeyCode.H)
	local cToggle = UserInputService.InputBegan:Connect(function(input, gameProcessed)
		if gameProcessed then return end
		if Keybinds.Matches("SILENT_AIM_TOGGLE", input) then
			SilentAim.SetEnabled(not Config.Enabled)
		end
	end)
	table.insert(Shrimp.Cleanups, function() cToggle:Disconnect() end)

	local conn = RunService.RenderStepped:Connect(function()
		if not circle then return end
		pcall(function()
			local cam = workspace.CurrentCamera
			if Config.Enabled and Config.ShowFOV and cam then
				circle.Radius   = Config.FOV
				circle.Position = cam.ViewportSize / 2
				circle.Color    = Config.FOVColor
				circle.Visible  = true
			else
				circle.Visible = false
			end
		end)
	end)
	table.insert(Shrimp.Cleanups, function()
		conn:Disconnect()
		if circle then pcall(function() circle:Remove() end) circle = nil end
	end)

	print(("[Shrimp] SilentAim running — %s toggles, FOV %dpx, aim part %s, prediction %s @ %.1f")
		:format(Keybinds.Pretty(Keybinds.Get("SILENT_AIM_TOGGLE")),
			Config.FOV, Config.HitPart, Config.Prediction and "ON" or "OFF",
			Config.PredictionStrength))
end

return SilentAim
