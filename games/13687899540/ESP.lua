-- ESP.lua — games/13687899540 (ballistics game) — sUNC
-- Player ESP: box + health bar + name/distance + icon, scaled by projected
-- geometry, behind-camera targets fully hidden (Z check).
--
-- Team support (Roblox Teams service):
--   Team Check ON  -> teammates are hidden entirely
--   Team Color ON  -> box/text take the player's TeamColor
-- Visibility coloring:
--   camera has line of sight to the character -> GREEN
--   something blocks the camera ray           -> RED
-- If the game doesn't use Roblox Teams (Team is nil for everyone), the
-- check can't tell sides apart and simply shows everyone — tell me and I'll
-- wire the game's own team source from a decompile.

local Players          = game:GetService("Players")
local RunService       = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local LocalPlayer = Players.LocalPlayer
local Shrimp   = getgenv().Shrimp
local Keybinds = Shrimp.Modules.Keybinds

local ESP = {}

-- ============================ config =================================
local Config = {
	Enabled     = true,
	TeamCheck   = true,  -- hide teammates
	TeamColor   = true,  -- tint ESP with the player's TeamColor
	VisColor    = true,  -- green when camera sees them, red when blocked
	ShowBox     = true,
	ShowHealth  = true,
	ShowNames   = true,
	ShowIcons   = true,
	MaxDistance = 2000,  -- studs; 0 = unlimited
	BaseTextSize = 15,
	MinTextSize  = 9,
	MaxTextSize  = 26,
	TextColor   = Color3.fromRGB(240, 240, 240),
	IconSize    = 18,
	PlayerIcon  = "user", -- lucide name via Icons.lua
}

local listeners = {}
local function fireHook(key)
	for _, fn in ipairs(listeners[key] or {}) do pcall(fn, Config[key]) end
end
local SETTERS = {
	"Enabled", "TeamCheck", "TeamColor", "VisColor", "ShowBox", "ShowHealth", "ShowNames",
	"ShowIcons", "MaxDistance", "BaseTextSize", "TextColor", "IconSize",
}
for _, key in ipairs(SETTERS) do
	ESP["Set" .. key] = function(v) Config[key] = v fireHook(key) end
	ESP["Get" .. key] = function() return Config[key] end
end
ESP.Config = Config
function ESP.OnChanged(key, fn)
	listeners[key] = listeners[key] or {}
	table.insert(listeners[key], fn)
end

-- ========================== team helpers =============================
local function sameTeam(pl)
	if not Config.TeamCheck then return false end
	local mine = LocalPlayer.Team
	if not mine then return false end -- no team info: can't filter
	return pl.Team == mine
end

local function colorFor(pl)
	if Config.TeamColor and pl.Team then
		return pl.Team.TeamColor.Color
	end
	return Config.TextColor
end

-- ===================== visibility coloring ===========================
local seeParams = RaycastParams.new()
seeParams.FilterType  = Enum.RaycastFilterType.Exclude
seeParams.IgnoreWater = true

local VISIBLE = Color3.fromRGB(85, 255, 127)  -- camera sees them
local BLOCKED = Color3.fromRGB(235, 65, 65)   -- wall between camera and them

local function seenByCamera(char, camPos)
	local top = char:FindFirstChild("Head") or char:FindFirstChild("HumanoidRootPart")
	if not top then return false end
	local cam = workspace.CurrentCamera
	seeParams.FilterDescendantsInstances = cam and { char, cam } or { char }
	local hit = workspace:Raycast(camPos, top.Position - camPos, seeParams)
	if not hit then return true end -- open sky
	return hit.Instance == top or hit.Instance:IsDescendantOf(char)
end

-- ======================== icon rendering =============================
-- Icons are ImageLabels in a hidden ScreenGui (Drawing Images don't
-- rasterize on Potassium — proven lesson from the Decay ESP).
local iconGui = nil
local function ensureIconGui()
	if iconGui and iconGui.Parent then return iconGui end
	local parent
	if gethui then
		local okH, h = pcall(gethui)
		if okH and h then parent = h end
	end
	if not parent then
		local okC, cg = pcall(function() return game:GetService("CoreGui") end)
		if okC and cg then parent = cg end
	end
	if not parent then
		parent = LocalPlayer:WaitForChild("PlayerGui")
	end
	local ok, sg = pcall(function()
		local s = Instance.new("ScreenGui")
		s.Name           = "ShrimpESPIcons"
		s.ResetOnSpawn   = false
		s.DisplayOrder   = 999
		s.IgnoreGuiInset = true -- GUI coords == WorldToViewportPoint coords
		s.Parent         = parent
		return s
	end)
	iconGui = ok and sg or nil
	return iconGui
end

local function newImage()
	local gui = ensureIconGui()
	if not gui then return nil end
	local ok, img = pcall(function()
		local i = Instance.new("ImageLabel")
		i.BackgroundTransparency = 1
		i.AnchorPoint            = Vector2.new(0.5, 0.5)
		i.Visible                = false
		i.Parent                 = gui
		return i
	end)
	return ok and img or nil
end

-- ========================== drawing helpers ==========================
local function newText()
	local ok, t = pcall(function() return Drawing.new("Text") end)
	if not ok or not t then return nil end
	pcall(function()
		t.Center = false t.Outline = true t.OutlineColor = Color3.new(0, 0, 0)
		t.Visible = false
	end)
	return t
end

local function newBox(filled)
	local ok, b = pcall(function() return Drawing.new("Square") end)
	if not ok or not b then return nil end
	pcall(function()
		b.Thickness = 1 b.Filled = filled and true or false b.Visible = false
	end)
	return b
end

-- ============================ scaling ================================
local function textScale(dist)
	local d = math.max(dist, 1)
	local s = Config.BaseTextSize * (40 / d)
	return math.clamp(math.floor(s + 0.5), Config.MinTextSize, Config.MaxTextSize)
end

local function iconScale(dist)
	local s = math.floor(textScale(dist) * (Config.IconSize / Config.BaseTextSize) + 0.5)
	return math.clamp(s, 10, 40)
end

local function shouldShow(dist)
	if Config.MaxDistance <= 0 then return true end
	return dist <= Config.MaxDistance
end

-- health: 1 = full green, 0 = red
local function healthColor(hp)
	local r = math.clamp(1.5 - hp * 1.5, 0, 1)
	local g = math.clamp(hp * 1.5, 0, 1)
	return Color3.fromRGB(math.floor(70 + 150 * r), math.floor(70 + 170 * g), 60)
end

-- ============================ tracking ===============================
local pool = {} -- player -> drawing set

local function acquire(pl)
	local set = pool[pl]
	if not set then
		set = {
			box    = newBox(false),
			text   = newText(),
			bar    = newBox(true),
			accent = newBox(true),
			icon   = newImage(),
			iconUrl = nil,
		}
		pool[pl] = set
	end
	return set
end

local function release(key)
	local set = pool[key]
	if not set then return end
	for k, d in pairs(set) do
		if k == "icon" and typeof(d) == "Instance" then
			pcall(function() d:Destroy() end)
		elseif typeof(d) ~= "boolean" and typeof(d) ~= "string" and d.Remove then
			pcall(d.Remove, d)
		end
	end
	pool[key] = nil
end

-- ============================ rendering ==============================
-- Box from real projected height: center + a point halfH above it; the
-- pixel gap IS the perspective scaling. Z <= 0.5 = behind camera -> hidden.
local function boxForCenter(worldPos, halfH, widthRatio)
	local cam = workspace.CurrentCamera
	if not cam then return nil end
	local c = cam:WorldToViewportPoint(worldPos)
	if c.Z <= 0.5 then return nil end
	local t = cam:WorldToViewportPoint(worldPos + Vector3.new(0, halfH, 0))
	if t.Z <= 0.5 then return nil end
	local px = math.abs(t.Y - c.Y)
	if px < 1 then return nil end
	local h = px * 2
	local w = h * widthRatio
	local x = math.floor(c.X - w / 2 + 0.5)
	local y = math.floor(t.Y + 0.5)
	local vp = cam.ViewportSize
	if x < -60 or y < -60 or x + w > vp.X + 60 or y + h > vp.Y + 60 then return nil end
	return { X = x, Y = y, W = math.floor(w + 0.5), H = math.floor(h + 0.5) }
end

local function renderSet(set, box, dist, label, color, hp, iconId)
	local cam = workspace.CurrentCamera
	if not cam then return end
	local vp = cam.ViewportSize
	local size = textScale(dist)

	if set.box and Config.ShowBox and box then
		pcall(function()
			set.box.Size = Vector2.new(box.W, box.H)
			set.box.Position = Vector2.new(box.X, box.Y)
			set.box.Color = color
			set.box.Visible = true
		end)
	elseif set.box then
		set.box.Visible = false
	end

	-- name + distance above the box
	local ty
	if set.text then
		pcall(function()
			if not Config.ShowNames or not box then
				set.text.Visible = false
				return
			end
			set.text.Text = label
			set.text.Size = size
			set.text.Color = color
			local tb = set.text.TextBounds
			if not tb or tb.X <= 0 or tb.Y <= 0 then return end
			set.text.Position = Vector2.new(
				math.clamp(box.X + box.W / 2 - tb.X / 2, 0, math.max(0, vp.X - tb.X)),
				math.clamp(box.Y - tb.Y - 3, 0, math.max(0, vp.Y - tb.Y)))
			set.text.Visible = true
			ty = box.Y - tb.Y - 3
		end)
	end

	-- icon above the name
	if set.icon then
		if Config.ShowIcons and iconId and box then				pcall(function()
					local Icons = Shrimp.Modules.Icons
					if set.iconUrl ~= iconId then
						set.icon.Image = iconId
						set.iconUrl = iconId
					end
					local s = iconScale(dist)
					-- user-supplied art files keep their real colors; bundled
					-- lucide masks take the team color
					local natural = Icons and Icons.IsOverride and Icons.IsOverride(Config.PlayerIcon)
					set.icon.ImageColor3 = natural and Color3.new(1, 1, 1) or color
				set.icon.Size = UDim2.fromOffset(s, s)
				set.icon.Position = UDim2.fromOffset(
					math.clamp(box.X + box.W / 2, 0, vp.X),
					math.clamp((ty or box.Y) - s / 2 - 2, 0, vp.Y))
				set.icon.Visible = true
			end)
		else
			set.icon.Visible = false
		end
	end

	-- health bar under the box
	if set.bar and set.accent then
		if Config.ShowHealth and box and hp then
			pcall(function()
				local t = 3
				local by = box.Y + box.H + 1
				set.accent.Size = Vector2.new(box.W, t)
				set.accent.Position = Vector2.new(box.X, by)
				set.accent.Color = Color3.fromRGB(20, 20, 20)
				set.accent.Visible = true
				local fw = math.floor(box.W * hp + 0.5)
				set.bar.Size = Vector2.new(fw, t)
				set.bar.Position = Vector2.new(box.X, by)
				set.bar.Color = healthColor(hp)
				set.bar.Visible = true
			end)
		else
			set.bar.Visible = false
			set.accent.Visible = false
		end
	end
end

local function hideSet(set)
	for _, d in pairs(set) do
		if typeof(d) == "Instance" then
			d.Visible = false
		elseif typeof(d) ~= "boolean" and typeof(d) ~= "string" and d.Visible ~= nil then
			pcall(function() d.Visible = false end)
		end
	end
end

-- ============================ main loop ==============================
local function frame()
	local cam = workspace.CurrentCamera
	if not cam then return end
	local camPos = cam.CFrame.Position

	local drawn = {}
	if Config.Enabled then
		for _, pl in ipairs(Players:GetPlayers()) do
			if pl ~= LocalPlayer and not sameTeam(pl) then
				local c = pl.Character
				local root = c and c:FindFirstChild("HumanoidRootPart")
				local hum  = c and c:FindFirstChildOfClass("Humanoid")
				if root and hum and hum.Health > 0 then
					local dist = (root.Position - camPos).Magnitude
					if shouldShow(dist) then
						-- ~6 stud tall character (root at center)
						local box = boxForCenter(root.Position, 3, 0.55)
						if box then
							local hp = math.clamp(hum.Health / math.max(hum.MaxHealth, 1), 0, 1)
						local color = colorFor(pl)
						if Config.VisColor then
							-- visibility beats team colors: red/green tells you who can
							-- actually shoot you this frame
							color = seenByCamera(c, camPos) and VISIBLE or BLOCKED
						end
							local Icons = Shrimp.Modules.Icons
							local iconId = Icons and Icons.Get(Config.PlayerIcon) or nil
							renderSet(acquire(pl), box, dist,
								("%s [%d]"):format(pl.Name, math.floor(dist + 0.5)),
								color, hp, iconId)
							drawn[pl] = true
						end
					end
				end
			end
		end
	end

	for pl, set in pairs(pool) do
		if not drawn[pl] then
			hideSet(set)
			if pl.Parent == nil then release(pl) end -- left the game
		end
	end
end

-- ============================ lifecycle ==============================
local toggleConn = nil

function ESP.Start()
	ensureIconGui()

	Keybinds.Register("ESP_TOGGLE", Enum.KeyCode.G)
	toggleConn = UserInputService.InputBegan:Connect(function(input, gameProcessed)
		if gameProcessed then return end
		if Keybinds.Matches("ESP_TOGGLE", input) then
			ESP.SetEnabled(not Config.Enabled)
		end
	end)
	table.insert(Shrimp.Cleanups, function()
		if toggleConn then toggleConn:Disconnect() toggleConn = nil end
	end)

	local conn = RunService.RenderStepped:Connect(frame)
	table.insert(Shrimp.Cleanups, function()
		conn:Disconnect()
		for key in pairs(pool) do release(key) end
		if iconGui then pcall(function() iconGui:Destroy() end) iconGui = nil end
	end)

	print("[Shrimp] ESP running — players, team check "
		.. (Config.TeamCheck and "ON" or "OFF"))
end

-- ========================== UI manifest ==============================
function ESP.Describe()
	return {
		Name = "ESP",
		Tab = { label = "Visuals", icon = "eye" },
		Rows = {
			{ type = "Section", label = "ESP" },
			{ type = "Toggle", label = "ESP Enabled", Get = ESP.GetEnabled,
				Set = ESP.SetEnabled, Sync = "OnChanged", SyncKey = "Enabled" },
			{ type = "Toggle", label = "Team Check", Get = ESP.GetTeamCheck, Set = ESP.SetTeamCheck },
			{ type = "Toggle", label = "Team Colors", Get = ESP.GetTeamColor, Set = ESP.SetTeamColor },
			{ type = "Toggle", label = "Visibility Colors", Get = ESP.GetVisColor, Set = ESP.SetVisColor },
			{ type = "Toggle", label = "Boxes", Get = ESP.GetShowBox, Set = ESP.SetShowBox },
			{ type = "Toggle", label = "Health Bars", Get = ESP.GetShowHealth, Set = ESP.SetShowHealth },
			{ type = "Toggle", label = "Names", Get = ESP.GetShowNames, Set = ESP.SetShowNames },
			{ type = "Toggle", label = "Icons", Get = ESP.GetShowIcons, Set = ESP.SetShowIcons },
			{ type = "Section", label = "Look" },
			{ type = "Slider", label = "Text Size", Min = 9, Max = 26,
				Get = ESP.GetBaseTextSize, Set = ESP.SetBaseTextSize },
			{ type = "Slider", label = "Icon Size", Min = 10, Max = 40,
				Get = ESP.GetIconSize, Set = ESP.SetIconSize },
			{ type = "Slider", label = "Max Distance", Min = 0, Max = 5000,
				Get = ESP.GetMaxDistance, Set = ESP.SetMaxDistance },
			{ type = "Keybind", label = "ESP — toggle", Bind = "ESP_TOGGLE",
				Default = Enum.KeyCode.G },
		},
	}
end

return ESP
