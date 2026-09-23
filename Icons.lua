-- Icons.lua — shared icon service for all Shrimp games (sUNC)
-- Resolution order per icon:
--   1. assets/icons/<name>.png       — a user-supplied override file
--   2. bundled lucide map            — 1500+ real rbxassetids (lucideblox)
--   3. UIStroke fallback glyph       — text-only environments
-- One file lookup, cached forever; missing file → bundled id, no warnings.

local Shrimp = getgenv().Shrimp

local Icons = {}

-- Lucide name -> rbxassetid. Bundled with the workspace (assets/icons.json,
-- 1500+ entries from the lucideblox set); lives on disk so you can update it
-- by re-downloading without touching this file.
local BUNDLED = nil -- name -> "rbxassetid://..." (lazy-loaded once)
local BUNDLED_LOADED = false

local cache = {} -- name -> { id = string|nil, override = boolean }

-- Brand ids that aren't lucide icons (logo art etc.). Overrides and the
-- bundled map still win over these.
local BRAND = {
	logo = "rbxassetid://102102634145249", -- shrimp logo
}

local function loadBundled()
	if BUNDLED_LOADED then return BUNDLED end
	BUNDLED_LOADED = true
	local ok, data = pcall(function()
		return game:GetService("HttpService"):JSONDecode(readfile(Shrimp.Folder .. "/assets/icons.json"))
	end)
	if ok and type(data) == "table" and type(data.icons) == "table" then
		BUNDLED = data.icons
	else
		BUNDLED = {}
	end
	return BUNDLED
end

-- Public API -----------------------------------------------------------

-- Returns "rbxassetid://..." / content id, or nil when even the fallback
-- glyph must carry the row. Cheap after first call per name.
function Icons.Get(name)
	local hit = cache[name]
	if hit ~= nil then return hit.id end

	local folder  = Shrimp.Folder or "shrimp"
	local id      = nil
	local override = false

	-- 1) user override file wins
	if readfile and isfile and isfile(folder .. "/assets/icons/" .. name .. ".png") then
		local ok, res = pcall(function()
			if getcustomasset then
				return getcustomasset(folder .. "/assets/icons/" .. name .. ".png")
			end
			return "rbxassetfile://" .. name -- some executors accept this
		end)
		if ok and res then
			id = res
			override = true
		end
	end

	-- 2) bundled lucide id
	if not id then
		local bundled = loadBundled()
		id = bundled[name]
	end

	-- 3) brand fallbacks
	if not id then
		id = BRAND[name]
	end

	cache[name] = { id = id, override = override }
	return id
end

-- Returns true when this name resolves to a user file (drawn untinted).
function Icons.IsOverride(name)
	local hit = cache[name]
	if hit == nil then Icons.Get(name) hit = cache[name] end
	return hit.override == true
end

-- Draw name as an ImageLabel if we have an id, else a centered TextLabel
-- glyph. Returns the created instance (parented to `parent`).
function Icons.Apply(target, name, props)
	local id = Icons.Get(name)
	if id then
		local img = Instance.new("ImageLabel")
		img.Name = name
		img.BackgroundTransparency = 1
		img.Image = id
		img.Size = UDim2.fromScale(1, 1)
		if props then
			for k, v in pairs(props) do
				if k ~= "Parent" then img[k] = v end
			end
		end
		img.Parent = target
		return img
	end
	local lbl = Instance.new("TextLabel")
	lbl.Name = name
	lbl.BackgroundTransparency = 1
	lbl.Font = Enum.Font.GothamBold
	lbl.Text = "?"
	lbl.TextColor3 = Color3.fromRGB(150, 150, 150)
	lbl.TextSize = 14
	lbl.Size = UDim2.fromScale(1, 1)
	if props then
		for k, v in pairs(props) do
			if k ~= "Parent" then lbl[k] = v end
		end
	end
	lbl.Parent = target
	return lbl
end

-- ESP/Drawing use: nothing to resolve for text glyphs — ids only.
function Icons.Has(name)
	return Icons.Get(name) ~= nil
end

return Icons
