-- SilentAim.lua — games/13687899540 (ballistics game) — sUNC
-- Silent aim for the Shared.Ballistics system, built from the ClientFire
-- decompile. The client is authoritative about shot DIRECTION:
--   ClientFire.o9HACKmCVc(weapon, muzzleIdx, bulletIdx, Origin, dirs, opts)
-- encodes the pellet directions into the Net.Fire payload (ShotCodec) AND
-- simulates the pellets locally (tracers, impact presentation, hit claims)
-- from those same directions. We hook o9HACKmCVc — fire() calls it through
-- the shared module table at call time, so one hook covers both entry points
-- — and rigidly rotate the whole pellet cone onto the best crosshair target
-- before the original runs. Payload, local sim and hit claims then all
-- agree with each other, which is exactly what a legit shot looks like.
--
-- Tracers: the local sim would draw the bent path (not silent), so
-- redirected shots set opts.Tracer = false and draw a short muzzle->target
-- energy beam instead (red->yellow gradient, glow texture, face-camera) —
-- the only visual of where the shot actually goes.
--
-- Hook mechanics: plain function replacement on the module table — no
-- namecall, no newcclosure (both misbehaved on Potassium before). A flag on
-- getgenv prevents double-wrapping on re-execute; the wrapper reads the
-- shared Config so re-executes keep the menu wired to the live hook.

local Players           = game:GetService("Players")
local RunService        = game:GetService("RunService")
local UserInputService  = game:GetService("UserInputService")
local Debris            = game:GetService("Debris")

local LocalPlayer = Players.LocalPlayer
local Shrimp   = getgenv().Shrimp
local Keybinds = Shrimp.Modules.Keybinds

local SilentAim = {}

-- ============================ config =================================
-- Shared table on getgenv: the permanent-ish hook and any re-executed
-- menu both read the same state.
local Config = Shrimp.BallisticSAConfig
if not Config then
	Config = {
		Enabled        = true,
		FOV            = 140,    -- pixels around the crosshair
		HitPart        = "Head", -- Head | Torso
		VisibleCheck   = true,   -- only lock targets with line of sight
		TeamCheck      = true,   -- skip teammates (Roblox Teams; no teams -> can't filter)
		ShowFOV        = true,
		RedirectTracer = true,   -- muzzle->target beam on redirected shots
		Prediction      = true,   -- lead moving targets by their velocity
		PredictionStrength = 1,   -- seconds of travel time used for the lead
		FOVColor       = Color3.fromRGB(255, 255, 255),
	}
	Shrimp.BallisticSAConfig = Config
end

local listeners = {}
local function fireHook(key)
	for _, fn in ipairs(listeners[key] or {}) do pcall(fn, Config[key]) end
end

local SETTERS = { "Enabled", "FOV", "HitPart", "VisibleCheck", "TeamCheck", "ShowFOV", "RedirectTracer",
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
-- Same proven core as the other SilentAim module: closest-to-crosshair
-- player inside the FOV circle, behind-camera excluded (Z check), optional
-- line-of-sight, dead players skipped.
local rayParams = RaycastParams.new()
rayParams.FilterType  = Enum.RaycastFilterType.Exclude
rayParams.IgnoreWater = true

local function aimPartFor(char)
	if Config.HitPart == "Torso" then
		return char:FindFirstChild("HumanoidRootPart") or char:FindFirstChild("Head")
	end
	return char:FindFirstChild("Head") or char:FindFirstChild("HumanoidRootPart")
end

local function pickTarget(cam)
	if not cam then return nil end
	local center   = cam.ViewportSize / 2
	local best     = nil
	local bestDist = Config.FOV
	for _, pl in ipairs(Players:GetPlayers()) do
		if pl ~= LocalPlayer
			and not (Config.TeamCheck and LocalPlayer.Team and pl.Team == LocalPlayer.Team) then
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

-- ========================= redirect helpers ==========================
-- Short-lived muzzle->target beam (your spec: red->yellow gradient, glow
-- texture, face-camera, quick fade): the only visual showing where the shot
-- actually goes (local tracers are disabled on redirected shots so the view
-- stays honest to the crosshair).
local function spawnRedirectTracer(from, to)
	local len = (to - from).Magnitude
	if len < 0.1 then return end
	local holder = Instance.new("Folder")
	holder.Name = "ShrimpRedirectTracer"

	local function endPart(pos, name)
		local p = Instance.new("Part")
		p.Name         = name
		p.Size         = Vector3.one
		p.Position     = pos
		p.Anchored     = true
		p.CanCollide   = false
		p.CanTouch     = false
		p.CanQuery     = false -- never blocks our own raycasts
		p.CastShadow   = false
		p.Transparency = 1
		p.Parent       = holder
		return p
	end

	local p0 = endPart(from, "Origin")
	local p1 = endPart(to, "Target")
	local a0 = Instance.new("Attachment") a0.Parent = p0
	local a1 = Instance.new("Attachment") a1.Parent = p1

	local beam = Instance.new("Beam")
	beam.Attachment0    = a0
	beam.Attachment1    = a1
	beam.Color          = ColorSequence.new(Color3.new(1, 0, 0), Color3.new(1, 0.859, 0.063))
	beam.LightEmission  = 1
	beam.LightInfluence = 1
	beam.FaceCamera     = true
	beam.Segments       = 10
	beam.Texture        = "rbxassetid://1134824633"
	beam.TextureLength  = 1
	beam.TextureMode    = Enum.TextureMode.Stretch
	beam.TextureSpeed   = 1
	beam.Width0         = 2
	beam.Width1         = 2
	beam.Transparency   = NumberSequence.new(0.1, 0.7)
	beam.Parent         = p0

	holder.Parent = workspace
	-- quick fade so it punches in, then vanishes in ~0.3s
	task.delay(0.15, function()
		if beam.Parent then beam.Transparency = NumberSequence.new(0.55, 1) end
	end)
	Debris:AddItem(holder, 0.3)
end

-- Rotate the WHOLE pellet cone rigidly so cone[1] lands on the target:
-- spread shape and per-pellet relationships are preserved (a shotgun still
-- looks like a shotgun to the server, just centered on the target).
local ZERO = Vector3.zero
local function redirectCone(dirs, targetPos, origin)
	local goal = (targetPos - origin)
	if goal.Magnitude < 0.001 then return false end
	goal = goal.Unit
	local first = dirs[1]
	if typeof(first) ~= "Vector3" or first.Magnitude < 0.001 then return false end
	first = first.Unit
	local rot = CFrame.new(ZERO, goal) * CFrame.new(ZERO, first):Inverse()
	for i = 1, #dirs do
		local v = dirs[i]
		if typeof(v) == "Vector3" and v.Magnitude > 0.001 then
			dirs[i] = rot * v.Unit
		end
	end
	return true
end

-- shallow copy: the caller owns its opts table; our Tracer edit must not
-- leak into whatever the weapon controller reuses across shots
local function copyOpts(opts)
	local c = {}
	if type(opts) == "table" then
		for k, v in pairs(opts) do c[k] = v end
	end
	return c
end

-- ============================== hook =================================
function SilentAim.Start()
	-- locate the game's ClientFire module
	local PS = LocalPlayer:FindFirstChildOfClass("PlayerScripts")
	     or LocalPlayer:WaitForChild("PlayerScripts", 10)
	local BC  = PS and PS:FindFirstChild("BallisticsClient")
	local CFR = BC and BC:FindFirstChild("ClientFire")
	if not CFR then
		warn("[Shrimp] Ballistics ClientFire not found — silent aim unavailable")
		return
	end
	local okM, mod = pcall(require, CFR)
	if not okM or type(mod) ~= "table" or type(mod.o9HACKmCVc) ~= "function" then
		warn("[Shrimp] ClientFire module not hookable (" .. tostring(okM and "shape" or mod) .. ")")
		return
	end

	-- install ONCE (field replacement isn't a metamethod hook, but the flag
	-- still prevents stacking wrappers across re-executes)
	if not Shrimp.BallisticSAHooked then
		Shrimp.BallisticSAHooked = true
		local orig = mod.o9HACKmCVc
		mod.o9HACKmCVc = function(weapon, muzzleIdx, bulletIdx, origin, dirs, opts)
			if Config.Enabled and type(dirs) == "table" and #dirs > 0
				and typeof(origin) == "Vector3" then
				local okT, target = pcall(pickTarget, workspace.CurrentCamera)
				if okT and target then
					local tp = predictPart(target)
					local okR = pcall(redirectCone, dirs, tp, origin)
					if okR then
						-- kill the local tracer (would draw the bent path) and
						-- draw the green confirmation line instead
						opts = copyOpts(opts)
						opts.Tracer = false
						if Config.RedirectTracer then
							pcall(spawnRedirectTracer, origin, tp)
						end
						if not Shrimp.BallisticSASeen then
							Shrimp.BallisticSASeen = true
							print("[Shrimp] Ballistic SilentAim: shot redirected — active")
						end
					end
				end
			end
			return orig(weapon, muzzleIdx, bulletIdx, origin, dirs, opts)
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

	print(("[Shrimp] Ballistic SilentAim running — %s toggles, FOV %dpx, aim part %s, prediction %s @ %.1f")
		:format(Keybinds.Pretty(Keybinds.Get("SILENT_AIM_TOGGLE")), Config.FOV, Config.HitPart,
			Config.Prediction and "ON" or "OFF", Config.PredictionStrength))
end

-- ========================== UI manifest ==============================
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
			{ type = "Slider", label = "FOV (px)", Min = 30, Max = 500,
				Get = SilentAim.GetFOV, Set = SilentAim.SetFOV },
			{ type = "Toggle", label = "FOV Circle", Get = SilentAim.GetShowFOV,
				Set = SilentAim.SetShowFOV },
			{ type = "Toggle", label = "Redirect Tracer", Get = SilentAim.GetRedirectTracer,
				Set = SilentAim.SetRedirectTracer },
			{ type = "Toggle", label = "Prediction", Get = SilentAim.GetPrediction,
				Set = SilentAim.SetPrediction },
			{ type = "Slider", label = "Prediction Strength", Min = 0.1, Max = 2, Step = 0.1,
				Get = SilentAim.GetPredictionStrength, Set = SilentAim.SetPredictionStrength },
			{ type = "Toggle", label = "Visible Check", Get = SilentAim.GetVisibleCheck,
				Set = SilentAim.SetVisibleCheck },
			{ type = "Toggle", label = "Team Check", Get = SilentAim.GetTeamCheck,
				Set = SilentAim.SetTeamCheck },
			{ type = "Keybind", label = "Silent Aim — toggle", Bind = "SILENT_AIM_TOGGLE",
				Default = Enum.KeyCode.H },
		},
	}
end

return SilentAim
