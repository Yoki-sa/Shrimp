-- ESP.lua — loaded by ShrimpLauncher (sUNC)
-- Visuals ESP: players get box + gradient health bar + name/distance; ore
-- models in workspace.OreSpawns get NAME + DISTANCE + an icon only (no box).
--
-- Everything scales with real projected geometry (boxes hug the target and
-- shrink with perspective). Behind-camera targets are fully hidden — no
-- edge-sticking.
--
-- Fonts: the default "Minecraft" font loads from shrimp/fonts/Minecraft.otf
-- via getcustomasset. Executor Drawing libs differ in what `.Font` accepts
-- (asset ids, Enum.Font, strings, numbers), so every candidate is probed on
-- a hidden Drawing and only a value that actually rasterizes is used.
--
-- Ore colors: metal = brown, sulfur = yellow, stone = light gray.
-- Icons: the user's REAL ore renders from shrimp/assets/*.png resolved via
-- getcustomasset (the lucide ids stay as fallbacks when files are missing).
-- Natural renders are drawn untinted (white) so they keep their real colors.
-- Body bags: any workspace model named "BodyBag" gets the same name+icon
-- treatment, in red.
-- Crates: workspace.LootSpawns models (Military/Food/basic Crate), each with
-- its own color + real render.

local Players           = game:GetService("Players")
local RunService        = game:GetService("RunService")
local UserInputService  = game:GetService("UserInputService")

local LocalPlayer = Players.LocalPlayer
local Camera      = workspace.CurrentCamera

local Shrimp   = getgenv().Shrimp
local Keybinds = Shrimp.Modules.Keybinds

-- ============================ config =================================
local ESP = {}

local Config = {
	Enabled        = true,
	Players        = true,
	Ores           = true,
	BodyBags       = true,
	Crates         = true,
	ScaleDistance  = true,   -- text/bars shrink with distance
	MaxDistance    = 750,    -- studs; 0 = unlimited
	BaseTextSize   = 15,     -- pixel size at close range
	MinTextSize    = 9,      -- floor when far away
	MaxTextSize    = 26,     -- ceiling when point-blank
	TextColor      = Color3.fromRGB(240, 240, 240),
	BarSide        = "Bottom", -- Bottom | Top | Left | Right
	BarGradient    = true,   -- green -> red by health (false = solid red)
	Font           = "Minecraft",
	ShowIcons      = true,
	IconSize       = 18,     -- px at close range (scales like text)
	PlayerIcon     = "rbxassetid://10747373176", -- lucide-user
	-- Real ore renders: shrimp/assets files resolved at runtime through
	-- getcustomasset, lucide fallbacks if the file/executor can't do it.
	-- "hq" is checked before "metal" so HQ Metal Ore matches it first.
	OreIcons = {
		{ key = "sulfur", file = "Sulfur_Ore_icon.png", fallback = "rbxassetid://10723376114" }, -- lucide-flame
		{ key = "hq",     file = "Metal_Ore_icon.png",  fallback = "rbxassetid://10709782497" }, -- lucide-box
		{ key = "metal",  file = "Metal_Ore_icon.png",  fallback = "rbxassetid://10709782497" }, -- lucide-box
		{ key = "stone",  file = "Stone_Ore.png",       fallback = "rbxassetid://10734965702" }, -- lucide-square
	},
	OreIconFallback = "rbxassetid://10734966248", -- lucide-star
	BodyBagIcon     = { file = "BodyBag.png", fallback = "rbxassetid://10709782497" },
	BodyBagColor    = Color3.fromRGB(220, 60, 60),
	-- Crate renders + colors: military = dark green, food = orange (not used
	-- by any other ESP type), basic = wheat. "military"/"food" are matched
	-- before the generic "crate" key, so a "Military Crate" never falls
	-- through to the basic entry.
	CrateIcons = {
		{ key = "military", file = "Military_Crate.png", fallback = "rbxassetid://10709782497" }, -- lucide-box
		{ key = "food",     file = "Food_Crate.png",     fallback = "rbxassetid://10709782497" }, -- lucide-box
		{ key = "crate",    file = "Basic_Crate.png",    fallback = "rbxassetid://10734965702" }, -- lucide-square
	},
	CrateColors = {
		{ key = "military", color = Color3.fromRGB(70, 105, 50)  }, -- dark green
		{ key = "food",     color = Color3.fromRGB(235, 120, 50) }, -- orange
		{ key = "crate",    color = Color3.fromRGB(245, 222, 179) }, -- wheat
	},
	CrateFallback = Color3.fromRGB(245, 222, 179),
	OreColors = {
		{ key = "sulfur", color = Color3.fromRGB(232, 200, 60)  }, -- yellow
		{ key = "metal",  color = Color3.fromRGB(150, 108, 62)  }, -- brown
		{ key = "hq",     color = Color3.fromRGB(150, 108, 62)  }, -- HQ metal -> brown
		{ key = "stone",  color = Color3.fromRGB(190, 190, 190) }, -- light gray
	},
	OreFallback = Color3.fromRGB(190, 190, 190),
}

local listeners = {}
local function fireHook(key)
	for _, fn in ipairs(listeners[key] or {}) do pcall(fn, Config[key]) end
end

local SETTERS = {
	"Enabled", "Players", "Ores", "ScaleDistance", "MaxDistance",
	"BaseTextSize", "MinTextSize", "MaxTextSize", "TextColor",
	"BarSide", "BarGradient", "Font", "ShowIcons", "IconSize", "BodyBags", "Crates",
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

-- ============================ fonts ==================================
-- Executor Drawing Texts accept different `.Font` value types. Probe each
-- candidate on a hidden Drawing: it must assign without error AND produce a
-- non-zero TextBounds (some impls silently rasterize nothing otherwise).
local FONTS = {
	Minecraft   = { file = "fonts/Minecraft.otf", builtin = Enum.Font.Arcade },
	Montserrat  = { builtin = Enum.Font.GothamMedium },
	Gotham      = { builtin = Enum.Font.GothamBold },
	CloneRoboto = { builtin = Enum.Font.RobotoMono },
	Chelsea     = { builtin = Enum.Font.PermanentMarker },
}
local FontId     = nil               -- custom asset id when loaded
local ActiveFont = Enum.Font.Arcade  -- the value Drawing actually accepts

local probe = nil
pcall(function()
	probe = Drawing.new("Text")
	probe.Visible = false
	probe.Text = "Ag"
	probe.Size = 14
	probe.Outline = false
end)

local function fontRenders(value)
	if not probe then return true end -- can't probe; trust the candidate
	local ok = pcall(function() probe.Font = value end)
	if not ok then return false end
	local okB, b = pcall(function() return probe.TextBounds end)
	return okB and b and b.X ~= nil and b.X > 0
end

local function chooseFont(candidates)
	for _, v in ipairs(candidates) do
		if v ~= nil and fontRenders(v) then return v end
	end
	return Enum.Font.Arcade
end

function ESP.LoadFont(name)
	local entry = FONTS[name]
	if not entry then return end
	Config.Font = name
	local cands = {}		if entry.file and getcustomasset and isfile and readfile then
			local path = (Shrimp.GameDir or (Shrimp.Folder or "shrimp")) .. "/" .. entry.file
		local ok, id = pcall(getcustomasset, path)
		if ok and id then
			FontId = id
			table.insert(cands, id)
		else
			FontId = nil
			warn("[Shrimp ESP] getcustomasset failed for " .. path .. " — falling back")
		end
	else
		FontId = nil
	end
	if entry.builtin then table.insert(cands, entry.builtin) end
	table.insert(cands, "Arcade") -- some executors want font name strings
	table.insert(cands, 2)        -- or numeric indexes
	ActiveFont = chooseFont(cands)
end

-- ======================= custom image assets =========================
-- The user's real ore/bodybag renders live in shrimp/assets/*.png (shipped
-- next to the scripts). getcustomasset turns them into content ids Drawing
-- Images accept; missing files or missing APIs fall back to the lucide ids.
-- Returns id, isNaturalRender — natural renders are drawn untinted.
local assetCache = {}
local function customIcon(fileName, fallbackId)
	local hit = assetCache[fileName]
	if hit then return hit.id, hit.natural end
	local id, natural = fallbackId, false
	if getcustomasset and isfile and readfile then
		local path = (Shrimp.GameDir or (Shrimp.Folder or "shrimp")) .. "/assets/" .. fileName
		local ok, res = pcall(function()
			if not isfile(path) then return nil end
			return getcustomasset(path)
		end)
		if ok and res then
			id, natural = res, true
		else
			warn("[Shrimp ESP] custom icon unavailable: " .. path .. " — using fallback")
		end
	end
	assetCache[fileName] = { id = id, natural = natural }
	return id, natural
end

-- ========================== ore lookups ==============================
local ORE_FOLDER = "OreSpawns"

local function oreColorFor(name)
	local n = name:lower()
	for _, e in ipairs(Config.OreColors) do
		if n:find(e.key, 1, true) then return e.color end
	end
	return Config.OreFallback
end

local function oreIconFor(name)
	local n = name:lower()
	for _, e in ipairs(Config.OreIcons) do
		if n:find(e.key, 1, true) then return customIcon(e.file, e.fallback) end
	end
	return Config.OreIconFallback, false
end

-- Ore model names aren't consistent ("Sulfur Ore" vs plain "Stone"), so
-- the match accepts any known ore keyword — on the model itself or an
-- ancestor model, never the OreSpawns folder (its own name has "ore"!).
local ORE_NAME_KEYS = { "ore", "sulfur", "metal", "hq", "stone" }
local function oreModelName(model, stopAt)
	local inst = model
	while inst and inst ~= workspace and inst ~= stopAt do
		if inst:IsA("Model") then
			local n = inst.Name:lower()
			for _, k in ipairs(ORE_NAME_KEYS) do
				if n:find(k, 1, true) then return inst.Name end
			end
		end
		inst = inst.Parent
	end
	return nil
end

local oreList  = {}  -- rescan every 0.5s: { model, name }
local nextScan = 0
local function rescanOres()
	nextScan = time() + 0.5
	table.clear(oreList)
	local folder = workspace:FindFirstChild(ORE_FOLDER)
	if not folder then return end
	local seen = {}
	for _, inst in ipairs(folder:GetDescendants()) do
		if inst:IsA("Model") and not seen[inst] then
			local name = oreModelName(inst, folder)
			if name then
				seen[inst] = true
				-- parent-first enumeration: skip nested models of listed ones
				local dup = false
				for _, e in ipairs(oreList) do
					if inst:IsDescendantOf(e.model) then dup = true break end
				end
				if not dup then table.insert(oreList, { model = inst, name = name }) end
			end
		end
	end
end

-- Body bags: models named "BodyBag" anywhere in workspace (they spawn where
-- players die, so no fixed folder to watch). A full workspace GetDescendants
-- sweep every second stalled big maps — so: ONE sweep at start, then live
-- tracking via DescendantAdded (new bags appear instantly), plus a cheap
-- 2-second prune of bags that left the world.
local bagList, bagSet = {}, {}
local nextBagPrune    = 0
local lastBagCount    = -1
local bagAddedConn    = nil

local function looksLikeBag(inst)
	return (inst:IsA("Model") or inst:IsA("BasePart"))
		and inst.Name:lower():find("bodybag", 1, true) ~= nil
end

local function addBag(inst)
	if bagSet[inst] then return end
	-- skip nested matches (a Part named BodyBag inside a Model named BodyBag)
	local p = inst.Parent
	while p and p ~= workspace do
		if bagSet[p] then return end
		p = p.Parent
	end
	bagSet[inst] = true
	table.insert(bagList, { model = inst })
end

local function sweepBags()
	table.clear(bagList)
	table.clear(bagSet)
	for _, inst in ipairs(workspace:GetDescendants()) do
		if looksLikeBag(inst) then addBag(inst) end
	end
	lastBagCount = #bagList
	print(("[Shrimp ESP] %d body bag(s) found"):format(#bagList))
end

bagAddedConn = workspace.DescendantAdded:Connect(function(inst)
	if looksLikeBag(inst) then addBag(inst) end
end)

-- Crates: workspace.LootSpawns models. The folder is small, so a one-time
-- sweep + DescendantAdded tracking covers it with zero steady-state cost.
-- If the whole folder gets wiped/recreated, workspace.ChildAdded re-hooks it.
local LOOT_FOLDER           = "LootSpawns"
local crateList, crateSet   = {}, {}
local nextCratePrune        = 0
local lastCrateCount        = -1
local crateAddedConn        = nil
local lootWatchConn         = nil

local function crateKindFor(name)
	local l = name:lower()
	for _, e in ipairs(Config.CrateIcons) do
		if l:find(e.key, 1, true) then return e.key end
	end
	return nil
end

local function crateColorFor(kind)
	for _, e in ipairs(Config.CrateColors) do
		if e.key == kind then return e.color end
	end
	return Config.CrateFallback
end

local function crateIconFor(kind)
	for _, e in ipairs(Config.CrateIcons) do
		if e.key == kind then return customIcon(e.file, e.fallback) end
	end
	return Config.OreIconFallback, false
end

local function addCrate(inst)
	if not inst:IsA("Model") then return end
	local kind = crateKindFor(inst.Name)
	if not kind then return end
	if crateSet[inst] then return end
	-- skip nested matches (a "Crate" model inside a "Military Crate" model)
	local p = inst.Parent
	while p and p ~= workspace do
		if crateSet[p] then return end
		p = p.Parent
	end
	crateSet[inst] = true
	table.insert(crateList, { model = inst, kind = kind })
end

local function hookLootFolder()
	if crateAddedConn then crateAddedConn:Disconnect() crateAddedConn = nil end
	local folder = workspace:FindFirstChild(LOOT_FOLDER)
	if not folder then return end
	crateAddedConn = folder.DescendantAdded:Connect(addCrate)
	for _, inst in ipairs(folder:GetDescendants()) do
		addCrate(inst)
	end
end

lootWatchConn = workspace.ChildAdded:Connect(function(inst)
	if inst.Name == LOOT_FOLDER then task.defer(hookLootFolder) end
end)

local function modelCenter(m)
	if m.PrimaryPart then return m.PrimaryPart.Position end
	local ok, pivot = pcall(function() return m:GetPivot().Position end)
	if ok and pivot then return pivot end
	local ok2, cf = pcall(function() return m:GetModelCFrame().Position end)
	return ok2 and cf or nil
end

-- ========================= drawing helpers ===========================
local function newText()
	local ok, t = pcall(function() return Drawing.new("Text") end)
	if not ok or not t then return nil end
	pcall(function()
		t.Center = false t.Outline = true t.OutlineColor = Color3.new(0, 0, 0)
		t.Visible = false
	end)
	return t
end

local function newBox()
	local ok, b = pcall(function() return Drawing.new("Square") end)
	if not ok or not b then return nil end
	pcall(function()
		b.Thickness = 1 b.Filled = false b.Visible = false
	end)
	return b
end

local function newBar()
	local ok, b = pcall(function() return Drawing.new("Square") end)
	if not ok or not b then return nil end
	pcall(function()
		b.Thickness = 1 b.Filled = true b.Visible = false
	end)
	return b
end

-- Icons are plain ImageLabels in a hidden ScreenGui, NOT Drawing Images:
-- Potassium accepts the Drawing Image properties but never rasterizes them
-- (which is why icons silently never showed). ImageLabels render both
-- getcustomasset ids and rbxassetid on every executor.
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
	if not ok then
		warn("[Shrimp ESP] could not create the icon ScreenGui — icons disabled")
	end
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

-- Health gradient sample: 1 = full green, 0 = red.
local function healthColor(hp)
	if not Config.BarGradient then
		return Color3.fromRGB(220, 60, 60)
	end
	local r = math.clamp(1.5 - hp * 1.5, 0, 1)
	local g = math.clamp(hp * 1.5, 0, 1)
	return Color3.fromRGB(math.floor(70 + 150 * r), math.floor(70 + 170 * g), 60)
end

-- ============================ tracking ===============================
local pool = {} -- tracked object -> drawing set

local function acquire(key, isPlayer)
	local set = pool[key]
	if not set then
		set = {
			player  = isPlayer,
			box     = newBox(),
			text    = newText(),
			bar     = newBar(),
			accent  = newBar(),
			icon    = newImage(),
			iconUrl = nil,
		}
		pool[key] = set
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

local function releaseAll()
	for key in pairs(pool) do release(key) end
end

-- ============================ scaling ================================
local function textScale(dist)
	if not Config.ScaleDistance then return Config.BaseTextSize end
	local d = math.max(dist, 1)
	local s = Config.BaseTextSize * (40 / d) -- full size at 40 studs
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

-- ============================ rendering ==============================
local function drawBox(set, box, color)
	if not set.box or not box then
		if set.box then set.box.Visible = false end
		return
	end
	pcall(function()
		set.box.Size = Vector2.new(box.W, box.H)
		set.box.Position = Vector2.new(box.X, box.Y)
		set.box.Color = color
		set.box.Visible = true
	end)
end

-- Health bar with dark track: fill is hp% of the track along the chosen side.
local function drawBar(set, box, hp)
	if not set.bar or not set.accent or not box then
		if set.bar then set.bar.Visible = false end
		if set.accent then set.accent.Visible = false end
		return
	end
	pcall(function()
		local side, t = Config.BarSide, 3
		local x, y, w, h = box.X, box.Y, box.W, box.H

		if side == "Left" or side == "Right" then
			local bx = (side == "Left") and (x - t - 1) or (x + w + 1)
			set.accent.Size = Vector2.new(t, h)
			set.accent.Position = Vector2.new(bx, y)
			set.accent.Color = Color3.fromRGB(20, 20, 20)
			set.accent.Visible = true
			local fh = math.floor(h * hp + 0.5)
			set.bar.Size = Vector2.new(t, fh)
			set.bar.Position = Vector2.new(bx, y) -- drains downward
			set.bar.Color = healthColor(hp)
			set.bar.Visible = true
		else
			local by = (side == "Top") and (y - t - 1) or (y + h + 1)
			set.accent.Size = Vector2.new(w, t)
			set.accent.Position = Vector2.new(x, by)
			set.accent.Color = Color3.fromRGB(20, 20, 20)
			set.accent.Visible = true
			local fw = math.floor(w * hp + 0.5)
			set.bar.Size = Vector2.new(fw, t)
			set.bar.Position = Vector2.new(x, by)
			set.bar.Color = healthColor(hp)
			set.bar.Visible = true
		end
	end)
end

-- box: nil for ores (name+icon only). anchorX/anchorY = projected point for
-- text placement when there's no box. iconId: optional image above the text.
local function renderSet(set, box, anchorX, anchorY, dist, label, color, hp, iconId, iconTint)
	local size = textScale(dist)
	local vp = Camera.ViewportSize

	drawBox(set, box, color)

	-- name + distance (independent pcall so one failure can't kill the rest)
	local tx, ty, tbX, tbY = nil, nil, 0, 0
	if set.text then
		pcall(function()
			set.text.Text = label
			set.text.Size = size
			set.text.Color = color
			set.text.Font = ActiveFont
			local tb = set.text.TextBounds
			if not tb or tb.X <= 0 or tb.Y <= 0 then return end -- not rasterized
			tbX, tbY = tb.X, tb.Y
			if box then
				tx = math.clamp(box.X + box.W / 2 - tb.X / 2, 0, math.max(0, vp.X - tb.X))
				ty = (Config.BarSide == "Top" and set.player)
					and (box.Y + box.H + 3)  -- bar on top: label below the box
					or (box.Y - tb.Y - 3)
			else
				tx = math.clamp(anchorX - tb.X / 2, 0, math.max(0, vp.X - tb.X))
				ty = anchorY - tb.Y - 2
			end
			set.text.Position = Vector2.new(tx, ty)
			set.text.Visible = true
		end)
	end

	-- icon above the name+distance (ImageLabel; natural renders stay untinted)
	if set.icon and Config.ShowIcons and iconId then
		pcall(function()
			if set.iconUrl ~= iconId then
				set.icon.Image = iconId
				set.iconUrl = iconId
			end
			local s = iconScale(dist)
			local cx = (box and box.X + box.W / 2) or anchorX
			local iy
			if box then
				iy = (Config.BarSide == "Top" and set.player)
					and ((ty or (box.Y + box.H + 3)) + tbY + 2) -- label below box
					or ((ty or box.Y) - s - 2)                  -- icon above label/box
			else
				iy = (ty or anchorY) - s - 2
			end
			set.icon.ImageColor3 = iconTint or color
			set.icon.Size = UDim2.fromOffset(s, s)
			set.icon.Position = UDim2.fromOffset(
				math.clamp(cx, 0, vp.X),
				math.clamp(iy + s / 2, 0, vp.Y))
			set.icon.Visible = true
		end)
	elseif set.icon then
		set.icon.Visible = false
	end

	-- health bar (players only)
	if set.player and hp then
		drawBar(set, box, hp)
	else
		if set.bar then set.bar.Visible = false end
		if set.accent then set.accent.Visible = false end
	end
end

local function hideSet(set)
	if set.box then set.box.Visible = false end
	if set.text then set.text.Visible = false end
	if set.bar then set.bar.Visible = false end
	if set.accent then set.accent.Visible = false end
	if set.icon then set.icon.Visible = false end
end

-- Box from real projected height: project the center and a point halfH
-- studs above it; the pixel gap between them IS the perspective scaling.
-- Z <= 0 means the point is behind the camera plane -> hidden (WorldToView-
-- Point's `on` bool lies for mirrored behind-camera points, which is what
-- made boxes stick to screen edges before).
local function boxForCenter(worldPos, halfH, widthRatio)
	local c = Camera:WorldToViewportPoint(worldPos)
	if c.Z <= 0.5 then return nil end
	local t = Camera:WorldToViewportPoint(worldPos + Vector3.new(0, halfH, 0))
	if t.Z <= 0.5 then return nil end
	local px = math.abs(t.Y - c.Y)
	if px < 1 then return nil end
	local h = px * 2
	local w = h * widthRatio
	local x = math.floor(c.X - w / 2 + 0.5)
	local y = math.floor(t.Y + 0.5)
	local vp = Camera.ViewportSize
	if x < -60 or y < -60 or x + w > vp.X + 60 or y + h > vp.Y + 60 then return nil end
	return { X = x, Y = y, W = math.floor(w + 0.5), H = math.floor(h + 0.5) }
end

local function frame()
	local cam = workspace.CurrentCamera
	if not cam then return end
	if cam ~= Camera then
		Camera = cam
	end
	local camPos = cam.CFrame.Position

	if Config.Enabled and Config.Ores and time() >= nextScan then
		rescanOres()
	end

	local drawn = {}

	-- players: box + health bar + name/distance + icon
	if Config.Enabled and Config.Players then
		for _, pl in ipairs(Players:GetPlayers()) do
			if pl ~= LocalPlayer then
				local c = pl.Character
				local root = c and c:FindFirstChild("HumanoidRootPart")
				local hum  = c and c:FindFirstChildOfClass("Humanoid")
				if root and hum and hum.Health > 0 then
					local dist = (root.Position - camPos).Magnitude
					if shouldShow(dist) then
						-- ~6 stud tall character (root is at the center)
						local box = boxForCenter(root.Position, 3, 0.55)
						if box then
							local hp = math.clamp(hum.Health / math.max(hum.MaxHealth, 1), 0, 1)
							renderSet(acquire(pl, true), box, box.X + box.W / 2, box.Y, dist,
								("%s [%d]"):format(pl.Name, math.floor(dist + 0.5)),
								Config.TextColor, hp, Config.PlayerIcon)
							drawn[pl] = true
						end
					end
				end
			end
		end
	end

	-- ores: name + distance + icon ONLY (no box)
	if Config.Enabled and Config.Ores then
		local vp = Camera.ViewportSize
		for _, e in ipairs(oreList) do
			local m = e.model
			if m.Parent then
				local pos = modelCenter(m)
				if pos then
					local dist = (pos - camPos).Magnitude
					if shouldShow(dist) then
						local sp = Camera:WorldToViewportPoint(pos)
						-- Z > 0 = in front of the camera (fixes edge-sticking)
						if sp.Z > 0.5 and sp.X > -40 and sp.X < vp.X + 40
							and sp.Y > -40 and sp.Y < vp.Y + 40 then
							local iconId, naturalIcon = oreIconFor(e.name)
							renderSet(acquire(m, false), nil, sp.X, sp.Y, dist,
								("%s [%d]"):format(e.name, math.floor(dist + 0.5)),
								oreColorFor(e.name), nil, iconId,
								naturalIcon and Color3.new(1, 1, 1) or nil)
							drawn[m] = true
						end
					end
				end
			end
		end
	end

	-- body bags: red name+distance+icon, same layout as ores (no box)
	if Config.Enabled and Config.BodyBags and time() >= nextBagPrune then
		nextBagPrune = time() + 2
		local alive, n = {}, 0
		for _, e in ipairs(bagList) do
			if e.model.Parent then
				n += 1
				alive[n] = e
			else
				bagSet[e.model] = nil
			end
		end
		bagList = alive
		if #bagList ~= lastBagCount then
			lastBagCount = #bagList
			print(("[Shrimp ESP] %d body bag(s) tracked"):format(#bagList))
		end
	end
	if Config.Enabled and Config.BodyBags then
		local vp = Camera.ViewportSize
		for _, e in ipairs(bagList) do
			local m = e.model
			if m.Parent then
				local pos = modelCenter(m)
				if pos then
					local dist = (pos - camPos).Magnitude
					if shouldShow(dist) then
						local sp = Camera:WorldToViewportPoint(pos)
						if sp.Z > 0.5 and sp.X > -40 and sp.X < vp.X + 40
							and sp.Y > -40 and sp.Y < vp.Y + 40 then
							local iconId, naturalIcon =
								customIcon(Config.BodyBagIcon.file, Config.BodyBagIcon.fallback)
							renderSet(acquire(m, false), nil, sp.X, sp.Y, dist,
								("Body Bag [%d]"):format(math.floor(dist + 0.5)),
								Config.BodyBagColor, nil, iconId,
								naturalIcon and Color3.new(1, 1, 1) or nil)
							drawn[m] = true
						end
					end
				end
			end
		end
	end

	-- crates: wheat/orange/dark-green name+distance+icon from LootSpawns
	if Config.Enabled and Config.Crates and time() >= nextCratePrune then
		nextCratePrune = time() + 2
		local alive, n = {}, 0
		for _, e in ipairs(crateList) do
			if e.model.Parent then
				n += 1
				alive[n] = e
			else
				crateSet[e.model] = nil
			end
		end
		crateList = alive
		if #crateList ~= lastCrateCount then
			lastCrateCount = #crateList
			print(("[Shrimp ESP] %d crate(s) tracked"):format(#crateList))
		end
	end
	if Config.Enabled and Config.Crates then
		local vp = Camera.ViewportSize
		for _, e in ipairs(crateList) do
			local m = e.model
			if m.Parent then
				local pos = modelCenter(m)
				if pos then
					local dist = (pos - camPos).Magnitude
					if shouldShow(dist) then
						local sp = Camera:WorldToViewportPoint(pos)
						if sp.Z > 0.5 and sp.X > -40 and sp.X < vp.X + 40
							and sp.Y > -40 and sp.Y < vp.Y + 40 then
							local iconId, naturalIcon = crateIconFor(e.kind)
							renderSet(acquire(m, false), nil, sp.X, sp.Y, dist,
								("%s [%d]"):format(m.Name, math.floor(dist + 0.5)),
								crateColorFor(e.kind), nil, iconId,
								naturalIcon and Color3.new(1, 1, 1) or nil)
							drawn[m] = true
						end
					end
				end
			end
		end
	end

	-- hide + free anything no longer drawn
	for key, set in pairs(pool) do
		if not drawn[key] then
			hideSet(set)
			local dead = (typeof(key) == "Instance" and not key.Parent)
			if dead then release(key) end
		end
	end
end

-- typing in the menu's TextBoxes must never toggle ESP
local function makeToggle(bindName)
	return UserInputService.InputBegan:Connect(function(input, gameProcessed)
		if gameProcessed then return end
		if Keybinds.Matches(bindName, input) then
			ESP.SetEnabled(not Config.Enabled)
		end
	end)
end

local toggleConn = nil

function ESP.Start()
	if getcustomasset then
		ESP.LoadFont("Minecraft") -- default; probes + falls back if unsupported
		-- Some Drawing libs rasterize lazily (TextBounds reads 0 until a frame
		-- has rendered), which can make the first probe pick wrong. Re-probe
		-- once real frames exist.
		task.delay(0.25, function()
			pcall(ESP.LoadFont, Config.Font)
		end)
	else
		warn("[Shrimp ESP] getcustomasset not available — using built-in fonts")
	end

	Keybinds.Register("ESP_TOGGLE", Enum.KeyCode.G)
	toggleConn = makeToggle("ESP_TOGGLE")
	table.insert(Shrimp.Cleanups, function()
		if toggleConn then toggleConn:Disconnect() toggleConn = nil end
	end)

	local conn = RunService.RenderStepped:Connect(frame)
	table.insert(Shrimp.Cleanups, function()
		conn:Disconnect()
		releaseAll()
		if bagAddedConn then bagAddedConn:Disconnect() bagAddedConn = nil end
		if crateAddedConn then crateAddedConn:Disconnect() crateAddedConn = nil end
		if lootWatchConn then lootWatchConn:Disconnect() lootWatchConn = nil end
		if iconGui then pcall(function() iconGui:Destroy() end) iconGui = nil end
	end)

	-- one-time sweeps + icon report (console tells you exactly what loaded)
	ensureIconGui()
	sweepBags()
	hookLootFolder()
	local iconEntries = {}
	for _, e in ipairs(Config.OreIcons) do iconEntries[#iconEntries + 1] = e end
	iconEntries[#iconEntries + 1] = Config.BodyBagIcon
	for _, e in ipairs(Config.CrateIcons) do iconEntries[#iconEntries + 1] = e end
	local seenFiles, natIcons, totalFiles = {}, 0, 0
	for _, e in ipairs(iconEntries) do
		if not seenFiles[e.file] then
			seenFiles[e.file] = true
			totalFiles += 1
			local _, nat = customIcon(e.file, e.fallback)
			if nat then natIcons += 1 end
		end
	end

	print(("[Shrimp] ESP running — %d/%d custom icons loaded, %d body bag(s), %d crate(s)")
		:format(natIcons, totalFiles, #bagList, #crateList))
end

-- UI manifest — rows are built by ShrimpUI from this spec
function ESP.Describe()
	return {
		Name = "ESP",
		Tab = { label = "Visuals", icon = "eye" },
		Rows = {
			{ type = "Section", label = "ESP" },
			{ type = "Toggle", label = "ESP Enabled", Get = ESP.GetEnabled,
				Set = ESP.SetEnabled, Sync = "OnChanged", SyncKey = "Enabled" },
			{ type = "Toggle", label = "Players", Get = ESP.GetPlayers, Set = ESP.SetPlayers },
			{ type = "Toggle", label = "Ores", Get = ESP.GetOres, Set = ESP.SetOres },
			{ type = "Toggle", label = "Body Bags", Get = ESP.GetBodyBags, Set = ESP.SetBodyBags },
			{ type = "Toggle", label = "Crates", Get = ESP.GetCrates, Set = ESP.SetCrates },
			{ type = "Toggle", label = "Show Icons", Get = ESP.GetShowIcons, Set = ESP.SetShowIcons },
			{ type = "Section", label = "Players" },
			{ type = "Dropdown", label = "Health Bar Side", Options = { "Bottom", "Top", "Left", "Right" },
				Get = ESP.GetBarSide, Set = ESP.SetBarSide },
			{ type = "Toggle", label = "Bar Gradient", Get = ESP.GetBarGradient, Set = ESP.SetBarGradient },
			{ type = "Section", label = "Look" },
			{ type = "Dropdown", label = "ESP Font",
				Options = { "Minecraft", "Montserrat", "Gotham", "CloneRoboto", "Chelsea" },
				Get = function() return Config.Font end,
				Set = function(v) ESP.LoadFont(v) end },
			{ type = "Slider", label = "Text Size", Min = 9, Max = 26, Get = ESP.GetBaseTextSize, Set = ESP.SetBaseTextSize },
			{ type = "Slider", label = "Icon Size", Min = 10, Max = 40, Get = ESP.GetIconSize, Set = ESP.SetIconSize },
			{ type = "Slider", label = "Max Distance", Min = 0, Max = 2000, Get = ESP.GetMaxDistance, Set = ESP.SetMaxDistance },
			{ type = "Keybind", label = "ESP — toggle", Bind = "ESP_TOGGLE", Default = Enum.KeyCode.G },
		},
	}
end

return ESP
