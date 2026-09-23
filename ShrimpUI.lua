-- ShrimpUI.lua — the UI library (game-agnostic)
-- Show(uiParent, manifest) builds the window from module Describe() specs —
-- the library knows nothing about any game or feature. Adding a module never
-- touches this file.
--
-- Manifest shape (array, one entry per module):
--   {
--     Name = "AutoFire",
--     Tab  = { label = "Combat", icon = "crosshair" },  -- lucide name
--     Rows = {
--       { type = "Toggle",   id = "AF", label = "Auto Swing",
--         Get = fn, Set = fn, Event = "SWING" },
--       { type = "Slider",   label = "Rate", Min = 2, Max = 30, Get = fn, Set = fn },
--       { type = "Dropdown", label = "Part", Options = {...}, Get = fn, Set = fn, Event = "HitPart" },
--       { type = "Button",   label = "Leave", Call = fn },
--       { type = "Keybind",  label = "Hold", Bind = "NAME", Default = Enum.KeyCode.V },
--       { type = "Label",    Text = "static" },   -- or Get = fn, On = subscribeFn
--       { type = "Section",  label = "Group" },
--     },
--   }
--
-- Design: black 734x458 window, white hairline, 45,45,45 1px separators,
-- sphere tab rail with glow transfer, uniquadev toggle. Icons come from
-- Icons.lua (assets/icons/*.png overrides > bundled lucide set).

local Players          = game:GetService("Players")
local TweenService     = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local ShrimpUI = {}

-- ===== design tokens ====================================================
local C = {
	bg      = Color3.fromRGB(0, 0, 0),
	sep     = Color3.fromRGB(45, 45, 45),
	stroke  = Color3.fromRGB(255, 255, 255),
	ctl     = Color3.fromRGB(28, 28, 28),
	dim     = Color3.fromRGB(150, 150, 150),
	iconOff = Color3.fromRGB(120, 120, 120),
	text    = Color3.fromRGB(255, 255, 255),
}
local GRAD_OFF = ColorSequence.new{
	ColorSequenceKeypoint.new(0.000, Color3.fromRGB(14, 14, 14)),
	ColorSequenceKeypoint.new(0.503, Color3.fromRGB(21, 21, 21)),
	ColorSequenceKeypoint.new(1.000, Color3.fromRGB(14, 14, 14)),
}
local FONT_TITLE = Font.new("rbxasset://fonts/families/Michroma.json", Enum.FontWeight.Bold, Enum.FontStyle.Normal)
local FONT_TEXT  = Font.new("rbxasset://fonts/families/GothamSSm.json", Enum.FontWeight.Medium, Enum.FontStyle.Normal)
local FONT_BOLD  = Font.new("rbxasset://fonts/families/GothamSSm.json", Enum.FontWeight.Bold, Enum.FontStyle.Normal)

function ShrimpUI.Show(uiParent, manifest)
	local Shrimp   = getgenv().Shrimp
	local Keybinds = Shrimp.Modules.Keybinds
	local Icons    = Shrimp.Modules.Icons

	manifest = manifest or {}

	-- UserInputService connections survive GUI destruction, so every one this
	-- UI creates is tracked and disconnected via Shrimp.Cleanups on
	-- re-execute (instance-bound connections die with the ScreenGui).
	local uiConns = {}
	local function track(conn)
		uiConns[#uiConns + 1] = conn
		return conn
	end

	-- helpers =============================================================

	local function new(class, props, parent)
		local inst = Instance.new(class)
		for k, v in pairs(props) do inst[k] = v end
		inst.Parent = parent
		return inst
	end

	local TWEEN_FAST = TweenInfo.new(0.15, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)
	local TWEEN_MED  = TweenInfo.new(0.25, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)
	local function tween(o, p, i)
		local t = TweenService:Create(o, i or TWEEN_MED, p) t:Play() return t
	end

	local function addGlow(parent, radius, transparency)
		local ok, sh = pcall(function()
			local s = Instance.new("UIShadow")
			s.Color = Color3.fromRGB(255, 255, 255)
			s.BlurRadius = UDim.new(0, radius)
			s.Transparency = transparency
			s.Parent = parent
			return s
		end)
		return ok and sh or nil
	end

	local function pressBounce(inst)
		local sc = inst:FindFirstChildOfClass("UIScale") or Instance.new("UIScale")
		sc.Parent = inst
		tween(sc, { Scale = 0.93 }, TweenInfo.new(0.06, Enum.EasingStyle.Quad, Enum.EasingDirection.Out))
		task.delay(0.07, function()
			pcall(function()
				tween(sc, { Scale = 1 }, TweenInfo.new(0.14, Enum.EasingStyle.Back, Enum.EasingDirection.Out))
			end)
		end)
	end

	-- icon into a container: real image when resolvable, glyph otherwise
	local function putIcon(parent, name, imageProps)
		local id = Icons and Icons.Get(name) or nil
		if id then
			local img = new("ImageLabel", {
				BackgroundTransparency = 1, Image = id,
				Size = UDim2.fromScale(1, 1), ZIndex = parent.ZIndex + 1,
			}, parent)
			if imageProps then
				for k, v in pairs(imageProps) do
					if k ~= "Parent" then img[k] = v end
				end
			end
			return img
		end
		return new("TextLabel", {
			BackgroundTransparency = 1, Font = Enum.Font.GothamBold, Text = "?",
			TextColor3 = C.dim, TextSize = 14, Size = UDim2.fromScale(1, 1),
			ZIndex = parent.ZIndex + 1,
		}, parent)
	end

	-- window ==============================================================

	if Shrimp.Gui and Shrimp.Gui.Parent then
		pcall(function() Shrimp.Gui:Destroy() end) -- re-execute: replace cleanly
	end
	Shrimp.Gui = nil

	local UI = new("ScreenGui", {
		Name = "ShrimpHack", ResetOnSpawn = false,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
	}, uiParent or Players.LocalPlayer:WaitForChild("PlayerGui"))

	local Main = new("Frame", {
		Name = "Main", BorderSizePixel = 0, BackgroundColor3 = C.bg,
		Size = UDim2.new(0, 734, 0, 458), Position = UDim2.new(0.16904, 0, 0.09007, 0),
		ClipsDescendants = true, ZIndex = 1,
	}, UI)
	new("UIStroke", { Color = C.stroke, Thickness = 1, ApplyStrokeMode = Enum.ApplyStrokeMode.Border }, Main)

	local Drag = new("Frame", {
		Name = "Drag", BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 50), ZIndex = 4,
	}, Main)

	new("TextLabel", {
		BackgroundTransparency = 1, Position = UDim2.new(0.08719, 0, 0, 0),
		Size = UDim2.new(0, 200, 0, 50), FontFace = FONT_TITLE,
		Text = "Shrimp Hack", TextColor3 = C.text, TextScaled = true,
		TextWrapped = true, ZIndex = 5,
	}, Drag)

	local SideBar = new("Frame", {
		Name = "SideBar", BorderSizePixel = 0, BackgroundColor3 = C.bg,
		Size = UDim2.new(0, 56, 0, 456), ZIndex = 2,
	}, Main)
	local logoHolder = new("Frame", {
		BackgroundTransparency = 1, Position = UDim2.new(0.5, 0, 0, 4),
		AnchorPoint = Vector2.new(0.5, 0), Size = UDim2.new(0, 40, 0, 40), ZIndex = 3,
	}, SideBar)
	putIcon(logoHolder, "logo") -- assets/icons/logo.png override, else lucide

	new("Frame", {
		Name = "Separator", BorderSizePixel = 0, BackgroundColor3 = C.sep,
		Position = UDim2.new(0, 56, 0, 0), Size = UDim2.new(0, 1, 1, 0), ZIndex = 2,
	}, Main)

	local closeBtn = new("ImageButton", {
		BackgroundTransparency = 1, Image = Icons and Icons.Get("x") or "",
		ImageColor3 = C.text,
		Position = UDim2.new(0.93597, 0, 0.0175, 0), Size = UDim2.new(0, 39, 0, 39), ZIndex = 10,
	}, Main)
	local minBtn = new("ImageButton", {
		BackgroundTransparency = 1, Image = Icons and Icons.Get("minus") or "",
		ImageColor3 = C.text,
		Position = UDim2.new(0.87193, 0, 0.0175, 0), Size = UDim2.new(0, 39, 0, 39), ZIndex = 10,
	}, Main)
	if not (Icons and Icons.Get("x")) then
		putIcon(closeBtn, "x", { Text = "" })
		closeBtn.Image = ""
	end
	for _, b in ipairs({ closeBtn, minBtn }) do
		b.MouseEnter:Connect(function() tween(b, { ImageColor3 = Color3.fromRGB(200, 200, 200) }, TWEEN_FAST) end)
		b.MouseLeave:Connect(function() tween(b, { ImageColor3 = C.text }, TWEEN_FAST) end)
	end

	local Content = new("Frame", {
		Name = "Content", BackgroundTransparency = 1, ClipsDescendants = true,
		Position = UDim2.new(0, 57, 0, 50), Size = UDim2.new(1, -57, 1, -50), ZIndex = 2,
	}, Main)

	local ORIGINAL_SIZE = Main.Size
	Main.Size = UDim2.new(0, 0, 0, 0)
	tween(Main, { Size = ORIGINAL_SIZE }, TweenInfo.new(0.4, Enum.EasingStyle.Back, Enum.EasingDirection.Out))

	-- tab state declared BEFORE the close/min handlers use it
	local TAB_Y_START, TAB_STEP = 70, 51
	local Tabs, CurrentTab, nextTabY = {}, nil, TAB_Y_START
	local tabsByLabel = {}

	local isMin = false
	closeBtn.MouseButton1Click:Connect(function()
		tween(Main, { Size = UDim2.new(0, 0, 0, 0) },
			TweenInfo.new(0.25, Enum.EasingStyle.Back, Enum.EasingDirection.In))
		task.wait(0.25)
		Shrimp.Gui = nil
		UI:Destroy()
	end)

	local function setMin(min)
		isMin = min
		for _, t in pairs(Tabs) do t.Button.Visible = not min end
		Content.Visible = not min
		Main.ClipsDescendants = true
		tween(Main, { Size = min and UDim2.new(0, 734, 0, 50) or ORIGINAL_SIZE }, TWEEN_MED)
	end
	minBtn.MouseButton1Click:Connect(function() setMin(not isMin) end)

	-- drag (mouse + touch)
	do
		local dragging, dragStart, startPos
		Drag.InputBegan:Connect(function(i)
			if i.UserInputType == Enum.UserInputType.MouseButton1
				or i.UserInputType == Enum.UserInputType.Touch then
				dragging = true dragStart = i.Position startPos = Main.Position
			end
		end)
		track(UserInputService.InputChanged:Connect(function(i)
			if dragging and (i.UserInputType == Enum.UserInputType.MouseMovement
				or i.UserInputType == Enum.UserInputType.Touch) then
				local d = i.Position - dragStart
				Main.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X,
					startPos.Y.Scale, startPos.Y.Offset + d.Y)
			end
		end))
		track(UserInputService.InputEnded:Connect(function(i)
			if i.UserInputType == Enum.UserInputType.MouseButton1
				or i.UserInputType == Enum.UserInputType.Touch then
				dragging = false
			end
		end))
	end

	-- tabs ================================================================

	local function createTabPage(name)
		local page = new("ScrollingFrame", {
			Name = name .. "Page", BackgroundTransparency = 1, BorderSizePixel = 0,
			Size = UDim2.new(1, 0, 1, 0), CanvasSize = UDim2.new(0, 0, 0, 0),
			ScrollBarThickness = 2, ScrollBarImageColor3 = C.sep,
			ScrollingDirection = Enum.ScrollingDirection.Y,
			Visible = false, ZIndex = 3,
		}, Content)
		local layout = new("UIListLayout", { Padding = UDim.new(0, 8) }, page)
		new("UIPadding", {
			PaddingTop = UDim.new(0, 10), PaddingBottom = UDim.new(0, 12),
			PaddingLeft = UDim.new(0, 16), PaddingRight = UDim.new(0, 16),
		}, page)
		layout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(function()
			page.CanvasSize = UDim2.new(0, 0, 0, layout.AbsoluteContentSize.Y + 24)
		end)
		return page
	end

	local function switchTab(name)
		if CurrentTab == name then return end
		local old, newT = Tabs[CurrentTab], Tabs[name]
		if not newT then return end
		if old then
			tween(old.Button, { ImageColor3 = C.iconOff }, TWEEN_FAST)
			if old.Glow then
				tween(old.Glow, { BlurRadius = UDim.new(0, 0), Transparency = 1 }, TWEEN_MED)
			end
			old.Page.Visible = false
		end
		CurrentTab = name
		tween(newT.Button, { ImageColor3 = C.text }, TWEEN_FAST)
		newT.Page.Visible = true
		newT.Page.Position = UDim2.new(0, 12, 0, 0)
		tween(newT.Page, { Position = UDim2.new(0, 0, 0, 0) }, TWEEN_MED)
		if newT.Glow then
			newT.Glow.Transparency = 0.63
			newT.Glow.BlurRadius = UDim.new(0, 0)
			tween(newT.Glow, { BlurRadius = UDim.new(0, 15) }, TWEEN_MED)
		end
	end

	local function AddTab(label, iconName)
		if tabsByLabel[label] then return tabsByLabel[label] end
		local btn = new("ImageButton", {
			Name = label .. "Tab", BackgroundTransparency = 1,
			ImageColor3 = C.iconOff, Position = UDim2.new(0.5, 0, 0, nextTabY),
			AnchorPoint = Vector2.new(0.5, 0), Size = UDim2.new(0, 39, 0, 39),
			AutoButtonColor = false, ZIndex = 5,
		}, SideBar)
		local id = Icons and Icons.Get(iconName or "box") or nil
		if id then btn.Image = id end
		new("UICorner", { CornerRadius = UDim.new(0, 30) }, btn) -- sphere tabs
		nextTabY += TAB_STEP
		local glow = addGlow(btn, 0, 1)
		local scale = Instance.new("UIScale") scale.Parent = btn
		local page = createTabPage(label)
		Tabs[label] = { Button = btn, Page = page, Glow = glow }
		tabsByLabel[label] = Tabs[label]
		btn.MouseButton1Click:Connect(function()
			pressBounce(btn)
			switchTab(label)
		end)
		btn.MouseEnter:Connect(function()
			tween(scale, { Scale = 1.1 }, TWEEN_FAST)
			if CurrentTab ~= label then tween(btn, { ImageColor3 = Color3.fromRGB(200, 200, 200) }, TWEEN_FAST) end
		end)
		btn.MouseLeave:Connect(function()
			tween(scale, { Scale = 1 }, TWEEN_FAST)
			if CurrentTab ~= label then tween(btn, { ImageColor3 = C.iconOff }, TWEEN_FAST) end
		end)
		if not CurrentTab then switchTab(label) end
		return Tabs[label]
	end

	-- row components ======================================================

	local function AddRow(page, height)
		return new("Frame", {
			BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, height or 38), ZIndex = 3,
		}, page)
	end

	local function AddRowLabel(row, text)
		return new("TextLabel", {
			BackgroundTransparency = 1, Position = UDim2.new(0, 4, 0, 0),
			Size = UDim2.new(1, -140, 1, 0), FontFace = FONT_TEXT, Text = text,
			TextColor3 = C.text, TextSize = 13, TextXAlignment = Enum.TextXAlignment.Left,
			TextTruncate = Enum.TextTruncate.AtEnd, ZIndex = 4,
		}, row)
	end

	local function AddSection(page, text)
		local head = new("Frame", {
			BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 26), ZIndex = 3,
		}, page)
		new("TextLabel", {
			BackgroundTransparency = 1, Position = UDim2.new(0, 4, 0, 0),
			Size = UDim2.new(1, -8, 0, 14), FontFace = FONT_BOLD, Text = string.upper(text),
			TextColor3 = C.dim, TextSize = 11, TextXAlignment = Enum.TextXAlignment.Left, ZIndex = 4,
		}, head)
		new("Frame", {
			BorderSizePixel = 0, BackgroundColor3 = C.sep,
			Position = UDim2.new(0, 4, 1, -6), Size = UDim2.new(1, -8, 0, 1), ZIndex = 4,
		}, head)
		return head
	end

	local function AddToggle(page, text, default, cb)
		local row = AddRow(page, 38)
		AddRowLabel(row, text)
		local box = new("Frame", {
			BackgroundColor3 = C.text,
			AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -4, 0.5, 0),
			Size = UDim2.new(0, 25, 0, 25), ZIndex = 5,
		}, row)
		new("UICorner", { CornerRadius = UDim.new(0, 8) }, box)
		local stroke = new("UIStroke", {
			Color = default and C.text or C.ctl, Thickness = 1,
			ApplyStrokeMode = Enum.ApplyStrokeMode.Border, ZIndex = 5,
		}, box)
		local glow = addGlow(box, 10, default and 0.63 or 1)
		local check = new("ImageLabel", {
			BackgroundTransparency = 1,
			Image = (Icons and Icons.Get("check")) or "rbxassetid://10709790644",
			ImageColor3 = C.bg,
			Size = UDim2.new(1, 0, 1, 0), ZIndex = 6, Visible = default and true or false,
		}, box)
		local grad = new("UIGradient", { Rotation = 90, Color = GRAD_OFF, Enabled = not default }, box)
		local btn = new("TextButton", {
			BackgroundTransparency = 1, Size = UDim2.new(1, 0, 1, 0), Text = "", ZIndex = 7,
		}, row)
		local state = default and true or false
		local function setState(v)
			state = v
			grad.Enabled = not v
			tween(stroke, { Color = v and C.text or C.ctl }, TWEEN_FAST)
			if glow then tween(glow, { Transparency = v and 0.63 or 1 }, TWEEN_FAST) end
			check.Visible = v
			if cb then pcall(cb, v) end
		end
		btn.MouseButton1Click:Connect(function() pressBounce(box) setState(not state) end)
		return { Set = setState }
	end

	local function AddSlider(page, text, min, max, default, cb, step)
		min, max = min or 0, max or 100
		default = math.clamp(default or min, min, max)
		local row = AddRow(page, 46)
		AddRowLabel(row, text)
		local valLbl = new("TextLabel", {
			BackgroundTransparency = 1, AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.new(1, -4, 0, 0), Size = UDim2.new(0, 60, 0, 18),
			FontFace = FONT_BOLD, Text = tostring(default), TextColor3 = C.text,
			TextSize = 13, TextXAlignment = Enum.TextXAlignment.Right, ZIndex = 4,
		}, row)
		local bar = new("Frame", {
			BackgroundColor3 = C.ctl, BorderSizePixel = 0, Position = UDim2.new(0, 4, 1, -16),
			Size = UDim2.new(1, -8, 0, 3), ZIndex = 4,
		}, row)
		-- NOTE: must not be named "track" — that's the connection-tracker helper
		-- above; shadowing it made track(InputEnded:Connect(...)) throw and the
		-- slider never saw mouse release (stuck dragging forever).
		new("UICorner", { CornerRadius = UDim.new(1, 0) }, bar)
		local fill = new("Frame", {
			BackgroundColor3 = C.text, BorderSizePixel = 0,
			Size = UDim2.new((default - min) / (max - min), 0, 1, 0), ZIndex = 5,
		}, bar)
		new("UICorner", { CornerRadius = UDim.new(1, 0) }, fill)
		local knob = new("Frame", {
			BackgroundColor3 = C.text, BorderSizePixel = 0, AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.new((default - min) / (max - min), 0, 0.5, 0),
			Size = UDim2.new(0, 12, 0, 12), ZIndex = 6,
		}, bar)
		new("UICorner", { CornerRadius = UDim.new(1, 0) }, knob)
		addGlow(fill, 10, 0.63)
		addGlow(knob, 10, 0.63)
		local dragging = false
		local function release()
			if not dragging then return end
			dragging = false
			tween(knob, { Size = UDim2.new(0, 12, 0, 12) }, TWEEN_FAST)
		end
		local function update(input)
			local rel = math.clamp((input.Position.X - bar.AbsolutePosition.X)
				/ math.max(bar.AbsoluteSize.X, 1), 0, 1)
			-- optional fractional step (e.g. 0.1): quantize the raw value
			local raw = min + (max - min) * rel
			local value
			if step and step > 0 then
				value = math.clamp(math.floor(raw / step + 0.5) * step, min, max)
				value = math.floor(value * 1000 + 0.5) / 1000 -- trim float noise
			else
				value = math.floor(raw + 0.5)
			end
			valLbl.Text = tostring(value)
			fill.Size = UDim2.new(rel, 0, 1, 0)
			knob.Position = UDim2.new(rel, 0, 0.5, 0)
			if cb then pcall(cb, value) end
		end
		bar.InputBegan:Connect(function(inp)
			if inp.UserInputType == Enum.UserInputType.MouseButton1
				or inp.UserInputType == Enum.UserInputType.Touch then
				dragging = true
				tween(knob, { Size = UDim2.new(0, 15, 0, 15) }, TWEEN_FAST)
				update(inp)
			end
		end)
		track(UserInputService.InputChanged:Connect(function(inp)
			if dragging and (inp.UserInputType == Enum.UserInputType.MouseMovement
				or inp.UserInputType == Enum.UserInputType.Touch) then
				update(inp)
			end
		end))
		track(UserInputService.InputEnded:Connect(function(inp)
			if (inp.UserInputType == Enum.UserInputType.MouseButton1
				or inp.UserInputType == Enum.UserInputType.Touch) and dragging then
				release()
			end
		end))
		-- alt-tab / focus loss mid-drag: Roblox can swallow the InputEnded, so
		-- force-release when the window loses focus instead of sticking
		track(UserInputService.WindowFocusReleased:Connect(release))
		return row
	end

	local function AddDropdown(page, text, options, default, cb)
		options = options or { "Option 1" }
		default = default or options[1]
		local closedH = 38
		local row = new("Frame", {
			BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, closedH),
			ClipsDescendants = true, ZIndex = 3,
		}, page)
		local head = new("Frame", {
			BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, closedH), ZIndex = 4,
		}, row)
		AddRowLabel(head, text)

		local chip = new("TextButton", {
			BackgroundColor3 = C.bg, BorderSizePixel = 0, AutoButtonColor = false,
			AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -4, 0, 19),
			Size = UDim2.new(0, 120, 0, 26), FontFace = FONT_TEXT,
			Text = default, TextColor3 = C.text, TextSize = 12,
			TextXAlignment = Enum.TextXAlignment.Left, ZIndex = 5,
		}, head)
		new("UICorner", { CornerRadius = UDim.new(0, 6) }, chip)
		new("UIStroke", { Color = C.sep, Thickness = 1, ApplyStrokeMode = Enum.ApplyStrokeMode.Border }, chip)
		new("UIPadding", { PaddingLeft = UDim.new(0, 10) }, chip)

		-- chevron icon (assets/icons/chevron-down.png override or bundled)
		local chevHolder = new("Frame", {
			BackgroundTransparency = 1, AnchorPoint = Vector2.new(1, 0.5),
			Position = UDim2.new(1, -6, 0.5, 0), Size = UDim2.new(0, 14, 0, 14), ZIndex = 6,
		}, chip)
		local chev
		if Icons then chev = putIcon(chevHolder, "chevron-down") end
		if not chev then
			new("TextLabel", {
				BackgroundTransparency = 1, Text = "▾", Font = Enum.Font.GothamBold,
				TextColor3 = C.text, TextSize = 12, Size = UDim2.fromScale(1, 1),
			}, chevHolder)
		end

		local list = new("Frame", {
			BackgroundTransparency = 1, Position = UDim2.new(0, 0, 0, closedH + 4),
			Size = UDim2.new(1, 0, 0, 0), ZIndex = 5,
		}, row)
		new("UIListLayout", { Padding = UDim.new(0, 4), SortOrder = Enum.SortOrder.LayoutOrder }, list)

		local isOpen, selected = false, default
		for i, opt in ipairs(options) do
			local optBtn = new("TextButton", {
				BackgroundColor3 = C.bg, BorderSizePixel = 0, AutoButtonColor = false,
				Size = UDim2.new(1, -8, 0, 26), FontFace = FONT_TEXT, Text = opt,
				TextColor3 = C.text, TextSize = 12,
				TextXAlignment = Enum.TextXAlignment.Left, LayoutOrder = i, ZIndex = 6,
			}, list)
			new("UIPadding", { PaddingLeft = UDim.new(0, 10) }, optBtn)
			new("UICorner", { CornerRadius = UDim.new(0, 6) }, optBtn)
			new("UIStroke", { Color = C.sep, Thickness = 1, ApplyStrokeMode = Enum.ApplyStrokeMode.Border }, optBtn)
			optBtn.MouseEnter:Connect(function()
				tween(optBtn, { BackgroundColor3 = C.text, TextColor3 = C.bg }, TWEEN_FAST)
			end)
			optBtn.MouseLeave:Connect(function()
				tween(optBtn, { BackgroundColor3 = C.bg, TextColor3 = C.text }, TWEEN_FAST)
			end)
			optBtn.MouseButton1Click:Connect(function()
				selected = opt
				chip.Text = selected
				isOpen = false
				tween(row, { Size = UDim2.new(1, 0, 0, closedH) }, TWEEN_MED)
				if chev then tween(chev, { Rotation = 0 }, TWEEN_MED) end
				if cb then pcall(cb, selected) end
			end)
		end

		chip.MouseButton1Click:Connect(function()
			isOpen = not isOpen
			if chev then tween(chev, { Rotation = isOpen and 180 or 0 }, TWEEN_MED) end
			if isOpen then
				local h = #options * 26 + (#options - 1) * 4 + 8
				row.ZIndex = 30
				tween(row, { Size = UDim2.new(1, 0, 0, closedH + 4 + h) }, TWEEN_MED)
			else
				tween(row, { Size = UDim2.new(1, 0, 0, closedH) }, TWEEN_MED)
				task.delay(0.26, function() row.ZIndex = 3 end)
			end
		end)
		return row
	end

	local function AddButton(page, text, cb)
		local btn = new("TextButton", {
			BackgroundColor3 = C.bg, BorderSizePixel = 0, AutoButtonColor = false,
			Size = UDim2.new(1, 0, 0, 32), FontFace = FONT_BOLD, Text = text,
			TextColor3 = C.text, TextSize = 13, ZIndex = 4,
		}, page)
		new("UICorner", { CornerRadius = UDim.new(0, 6) }, btn)
		new("UIStroke", { Color = C.sep, Thickness = 1, ApplyStrokeMode = Enum.ApplyStrokeMode.Border }, btn)
		btn.MouseEnter:Connect(function() tween(btn, { BackgroundColor3 = Color3.fromRGB(22, 22, 22) }, TWEEN_FAST) end)
		btn.MouseLeave:Connect(function() tween(btn, { BackgroundColor3 = C.bg }, TWEEN_FAST) end)
		btn.MouseButton1Click:Connect(function()
			pressBounce(btn)
			tween(btn, { BackgroundColor3 = C.text, TextColor3 = C.bg }, TWEEN_FAST)
			task.delay(0.12, function()
				tween(btn, { BackgroundColor3 = C.bg, TextColor3 = C.text }, TWEEN_FAST)
			end)
			if cb then pcall(cb) end
		end)
		return btn
	end

	local function AddLabel(page, text, dim)
		local row = AddRow(page, 20)
		local lbl = new("TextLabel", {
			BackgroundTransparency = 1, Position = UDim2.new(0, 4, 0, 0),
			Size = UDim2.new(1, -8, 1, 0), FontFace = FONT_TEXT, Text = text,
			TextColor3 = dim and C.dim or C.text, TextSize = 12,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextTruncate = Enum.TextTruncate.AtEnd, ZIndex = 4,
		}, row)
		return row, lbl
	end

	local function AddKeybind(page, text, bindName, default)
		if not Keybinds then return AddLabel(page, text) end
		Keybinds.Register(bindName, default)
		local row = AddRow(page, 38)
		AddRowLabel(row, text)
		local chip = new("TextButton", {
			BackgroundColor3 = C.bg, BorderSizePixel = 0, AutoButtonColor = false,
			AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -4, 0.5, 0),
			Size = UDim2.new(0, 90, 0, 26), FontFace = FONT_BOLD,
			Text = Keybinds.Pretty(Keybinds.Get(bindName)), TextColor3 = C.text,
			TextSize = 12, ZIndex = 5,
		}, row)
		new("UICorner", { CornerRadius = UDim.new(0, 6) }, chip)
		local stroke = new("UIStroke", { Color = C.sep, Thickness = 1, ApplyStrokeMode = Enum.ApplyStrokeMode.Border }, chip)
		local listening = false
		chip.MouseButton1Click:Connect(function()
			if listening then return end
			listening = true
			chip.Text = "press key..."
			chip.TextColor3 = C.dim
			stroke.Color = C.text
		end)
		track(UserInputService.InputBegan:Connect(function(input)
			if not listening then return end
			listening = false
			stroke.Color = C.sep
			chip.TextColor3 = C.text
			if input.KeyCode == Enum.KeyCode.Escape then
				chip.Text = Keybinds.Pretty(Keybinds.Get(bindName))
				return
			end
			if input.UserInputType == Enum.UserInputType.Keyboard then
				Keybinds.Set(bindName, input.KeyCode)
			elseif input.UserInputType == Enum.UserInputType.MouseButton1
				or input.UserInputType == Enum.UserInputType.MouseButton2
				or input.UserInputType == Enum.UserInputType.MouseButton3 then
				Keybinds.Set(bindName, input.UserInputType)
			end
			chip.Text = Keybinds.Pretty(Keybinds.Get(bindName))
		end))
		return row
	end

	-- manifest -> rows ====================================================

	local ROW_BUILDERS = {
		Section  = function(page, mod, r) AddSection(page, r.label or "") end,
		Toggle   = function(page, mod, r)
			local current = r.Get and r.Get() or r.Default or false
			local handle = AddToggle(page, r.label or r.id or "", current, function(v)
				if r.Set then pcall(r.Set, v) end
			end)
			-- external state changes (keybinds etc.) mirror onto the row.
			-- Sync = module subscribe fn; SyncKey = its event-name argument.
			if r.Sync and mod and type(mod[r.Sync]) == "function" then
				local mirror = function(v)
					if handle.Set then handle.Set(v) end
				end
				if r.SyncKey then
					pcall(mod[r.Sync], r.SyncKey, mirror)
				else
					pcall(mod[r.Sync], mirror)
				end
			end
		end,
		Slider   = function(page, mod, r)
			local current = r.Get and r.Get() or r.Default or r.Min or 0
			AddSlider(page, r.label or "", r.Min or 0, r.Max or 100, current, function(v)
				if r.Set then pcall(r.Set, v) end
			end, r.Step)
		end,
		Dropdown = function(page, mod, r)
			local current = r.Get and r.Get() or r.Default or (r.Options and r.Options[1])
			AddDropdown(page, r.label or "", r.Options, current, function(v)
				if r.Set then pcall(r.Set, v) end
			end)
		end,
		Button   = function(page, mod, r)
			AddButton(page, r.label or "", function()
				if r.Call then pcall(r.Call) end
			end)
		end,
		Keybind  = function(page, mod, r)
			AddKeybind(page, r.label or "", r.Bind or r.id, r.Default)
		end,
		Label    = function(page, mod, r)
			local initial = r.Text or (r.Get and r.Get()) or ""
			local _, lbl = AddLabel(page, initial, r.Dim ~= false)
			if r.On and mod then pcall(r.On, mod, function(text) lbl.Text = tostring(text) end) end
		end,
	}

	for _, spec in ipairs(manifest) do
		local tab = spec.Tab or { label = "Main", icon = "box" }
		local t = AddTab(tab.label, tab.icon)
		local mod = spec._mod
		for _, r in ipairs(spec.Rows or {}) do
			local builder = ROW_BUILDERS[r.type]
			if builder then
				local ok, err = pcall(builder, t.Page, mod, r)
				if not ok then
					warn(("[ShrimpUI] row %s (%s) failed: %s")
						:format(tostring(r.label or r.id), tostring(r.type), tostring(err)))
				end
			end
		end
	end

	if not next(Tabs) then
		local t = AddTab("Main", "box")
		AddLabel(t.Page, "No modules with Describe() loaded.", true)
	end

	-- menu bind + hotkey ==================================================

	if Keybinds then
		local lastTab = Tabs[CurrentTab]
		if lastTab then
			AddSection(lastTab.Page, "Menu")
			AddKeybind(lastTab.Page, "Toggle Menu", "TOGGLE_MENU", Enum.KeyCode.RightShift)
		end
		track(UserInputService.InputBegan:Connect(function(input, gp)
			if gp then return end
			if Keybinds.Matches("TOGGLE_MENU", input) then
				setMin(not isMin)
			end
		end))
	end

	table.insert(Shrimp.Cleanups, function()
		for _, c in ipairs(uiConns) do pcall(function() c:Disconnect() end) end
	end)

	Shrimp.Gui = UI
	return { ScreenGui = UI, SetVisible = function(v) setMin(not v) end }
end

return ShrimpUI
