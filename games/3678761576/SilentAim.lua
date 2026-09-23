-- SilentAim.lua — games/3678761576 (WeaponModule game) — sUNC
-- Built from the WeaponModule decompile. How shots work here:
--   shootEffect() computes the crosshair world point (Crosshair()), applies
--   mobile-only bulletMagnetism (returns nil on PC), spreads pellets around
--   the aim unit, raycasts each pellet locally, then fires:
--     ServerEvents.Shoot:FireServer(clientData, aimPoint, aiming, missCount, hitList, camPos)
--   (flamethrower/flaregun shape: FireServer(clientData, aimPoint) only)
-- The client REPORTS its own humanoid-hit list, and the game's own mobile
-- bulletMagnetism already replaces the aim point with an enemy part position
-- — so the server demonstrably accepts snap-to-target aim points. Silent aim:
-- intercept Shoot.FireServer and
--   • redirect aimPoint -> chosen target part
--   • optionally claim every pellet on that part (hitList rebuilt, miss 0)
-- payload shape stays exactly what a magnetized legit shot looks like.
--
-- Hook mechanics: direct hookfunction on Shoot.FireServer ONLY. A __namecall
-- layer was tried and REMOVED: it crashed the game ("AddItem is not a valid
-- member of RemoteEvent Shoot") — a namecall wrapper that makes nested method
-- calls pollutes the thread's namecall-method register, so the deferred
-- original resolved the WRONG method. The direct member hook has no such
-- register: it wraps the resolved FireServer closure and calls the original C
-- function directly (the Cobalt intercept pattern, proven on Potassium).
-- Flag on getgenv prevents stacking across re-executes; the wrapper reads
-- shared Config so a re-executed menu stays wired to the live hook.

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService        = game:GetService("RunService")
local UserInputService  = game:GetService("UserInputService")
local Debris            = game:GetService("Debris")

local LocalPlayer = Players.LocalPlayer
local Shrimp   = getgenv().Shrimp
local Keybinds = Shrimp.Modules.Keybinds

local SilentAim = {}

-- ============================ config =================================
local Config = Shrimp.ShootSAConfig
if not Config then
	Config = {
		Enabled         = true,
		FOV             = 140,    -- pixels around the crosshair
		HitPart         = "Head", -- Head | Torso
		VisibleCheck    = true,   -- only lock targets with line of sight
		TeamCheck       = true,   -- skip teammates (Roblox Teams)
		ShowFOV         = true,
		RedirectTracer  = true,   -- muzzle->target beam on redirected shots
		ClaimPellets    = true,   -- rebuild the hit list so damage actually lands
		Prediction      = true,   -- lead moving targets by their velocity
		PredictionStrength = 1,   -- seconds of travel time used for the lead
		FOVColor        = Color3.fromRGB(255, 255, 255),
	}
	Shrimp.ShootSAConfig = Config
end

local listeners = {}
local function fireHook(key)
	for _, fn in ipairs(listeners[key] or {}) do pcall(fn, Config[key]) end
end

local SETTERS = { "Enabled", "FOV", "HitPart", "VisibleCheck", "TeamCheck",
	"ShowFOV", "RedirectTracer", "ClaimPellets", "Prediction", "PredictionStrength" }
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
-- Same proven core as the other SilentAim modules: closest-to-crosshair
-- player inside the FOV circle, behind-camera excluded (Z check), optional
-- line-of-sight, dead players skipped.
local rayParams = RaycastParams.new()
rayParams.FilterType  = Enum.RaycastFilterType.Exclude
rayParams.IgnoreWater = true

local function aimPartFor(char)
	if Config.HitPart == "Torso" then
		return char:FindFirstChild("UpperTorso")
			or char:FindFirstChild("Torso")
			or char:FindFirstChild("HumanoidRootPart")
			or char:FindFirstChild("Head")
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

-- ========================= redirect tracer ===========================
-- Same beam spec as the ballistics module: red->yellow gradient, glow
-- texture, face-camera, quick fade. Anchor parts are CanQuery=false so the
-- beam never blocks our own raycasts.
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
		p.CanQuery     = false
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
	task.delay(0.15, function()
		if beam.Parent then beam.Transparency = NumberSequence.new(0.55, 1) end
	end)
	Debris:AddItem(holder, 0.3)
end

-- ========================= fire interception =========================
-- args (after self): [1]=clientData [2]=aimPoint [3]=aiming [4]=missCount
-- [5]=hitList [6]=camPos — or the flamethrower shape ([1],[2] only).
-- Returns true if args were modified.
-- Cheap re-entry guard: if the executor's namecall dispatch AND the direct
-- member hook both reach us for one shot, this collapses it to one handling.
-- Real shots are never 5ms apart (fire rate floor ~0.05s), so legit fire is
-- never skipped.
local lastHandle = 0
local function handleFire(args)
	if os.clock() - lastHandle < 0.005 then return false end
	if not Config.Enabled or args.n < 2 then return false end
	if typeof(args[2]) ~= "Vector3" then return false end

	lastHandle = os.clock() -- committed: mark this shot as handled

	local cam    = workspace.CurrentCamera
	local target = pickTarget(cam)
	if not target then return false end
	local tp = predictPart(target)

	args[2] = tp -- the aim point itself — what magnetism does on mobile

	-- claim the pellets: rebuild the client-reported hit list on the target
	if Config.ClaimPellets and args.n >= 5 then
		local okP, pellets = pcall(function()
			local cd   = args[1]
			local tool = cd and cd.Tool
			return (tool and tool:GetAttribute("Projectiles")) or 1
		end)
		if okP and type(pellets) == "number" and pellets >= 1 then
			local normal = Vector3.new(0, 1, 0)
			if typeof(args[6]) == "Vector3" then
				local n = (args[6] - tp)
				if n.Magnitude > 0.001 then normal = n.Unit end
			end
			local hits = {}
			for i = 1, math.min(pellets, 32) do
			hits[i] = {
				Instance = target,
				Position = tp, -- predicted point, claimed on the target part
				Normal   = normal,
				Material = target.Material,
			}
			end
			args[4] = 0    -- zero misses claimed
			args[5] = hits
		end
	end

	if Config.RedirectTracer then
		local char = LocalPlayer.Character
		local head = char and (char:FindFirstChild("Head") or char:FindFirstChild("HumanoidRootPart"))
		local from = (head and head.Position)
			or (cam and cam.CFrame.Position)
			or tp
		pcall(spawnRedirectTracer, from, tp)
	end

	if not Shrimp.ShootSASeen then
		Shrimp.ShootSASeen = true
		print("[Shrimp] WeaponModule SilentAim: shot redirected — active")
	end
	return true
end

-- ============================== hook =================================
function SilentAim.Start()
	local okR, Shoot = pcall(function()
		return ReplicatedStorage:WaitForChild("ServerEvents", 10)
			and ReplicatedStorage.ServerEvents:WaitForChild("Shoot", 10)
	end)
	if not okR or typeof(Shoot) ~= "Instance" then
		warn("[Shrimp] ServerEvents.Shoot not found — silent aim unavailable")
		return
	end

	if not Shrimp.ShootSAHooked then
		Shrimp.ShootSAHooked = true

		-- Direct member hook (Cobalt-proven pattern): wrap the resolved
		-- FireServer closure. NO namecall layer — a wrapper that makes nested
		-- method calls (targeting raycasts, tracer Debris) pollutes the
		-- thread's namecall-method register and the deferred original then
		-- resolves the WRONG method (the AddItem crash). Calling the original
		-- C closure directly has nothing to pollute.
		pcall(function()
			local orig = Shoot.FireServer
			hookfunction(Shoot.FireServer, function(self, ...)
				local args = table.pack(...)
				local okH, changed = pcall(handleFire, args)
				if okH and changed then
					return orig(self, table.unpack(args, 1, args.n))
				end
				return orig(self, ...)
			end)
		end)
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

	print(("[Shrimp] WeaponModule SilentAim running — %s toggles, FOV %dpx, aim part %s, pellet claims %s, prediction %s @ %.1f")
		:format(Keybinds.Pretty(Keybinds.Get("SILENT_AIM_TOGGLE")), Config.FOV,
			Config.HitPart, Config.ClaimPellets and "ON" or "OFF",
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
			{ type = "Toggle", label = "Claim Pellets", Get = SilentAim.GetClaimPellets,
				Set = SilentAim.SetClaimPellets },
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
