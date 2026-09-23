-- Keybinds.lua — shared keybind store (loaded by ShrimpLauncher)
-- The UI's AddKeybind component writes here, AutoFire reads from here.
-- One source of truth, rebindable live.

local UserInputService = game:GetService("UserInputService")

local Keybinds = {}

local Bindings  = {} -- name -> Enum.KeyCode | Enum.UserInputType (mouse)
local listeners = {} -- name -> { fn }

-- Register a default; keeps any existing value (idempotent).
function Keybinds.Register(name, default)
	if Bindings[name] == nil then
		Bindings[name] = default
	end
end

function Keybinds.Get(name)
	return Bindings[name]
end

function Keybinds.Set(name, input)
	if input == nil then return end
	Bindings[name] = input
	for _, fn in ipairs(listeners[name] or {}) do
		pcall(fn, input)
	end
end

function Keybinds.OnChanged(name, fn)
	listeners[name] = listeners[name] or {}
	table.insert(listeners[name], fn)
	return function() -- unsubscribe
		for i, f in ipairs(listeners[name] or {}) do
			if f == fn then table.remove(listeners[name], i) break end
		end
	end
end

-- True while the bound input is physically held (keyboard or mouse button).
function Keybinds.IsDown(name)
	local b = Bindings[name]
	if not b then return false end
	if typeof(b) == "EnumItem" then
		if b.EnumType == Enum.KeyCode then
			return UserInputService:IsKeyDown(b)
		elseif b.EnumType == Enum.UserInputType then
			if b == Enum.UserInputType.MouseButton1 then
				return UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton1)
			elseif b == Enum.UserInputType.MouseButton2 then
				return UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton2)
			end
		end
	end
	return false
end

-- Does a raw input event match this bind? (KeyCode or mouse button)
function Keybinds.Matches(name, input)
	local b = Bindings[name]
	if not b then return false end
	if b.EnumType == Enum.KeyCode and input.UserInputType == Enum.UserInputType.Keyboard then
		return input.KeyCode == b
	end
	if b.EnumType == Enum.UserInputType then
		return input.UserInputType == b
	end
	return false
end

-- Short pretty name for UI display.
function Keybinds.Pretty(b)
	if not b then return "..." end
	if b.EnumType == Enum.KeyCode then
		local map = {
			RightControl = "RCtrl", LeftControl = "LCtrl",
			RightShift = "RShift",  LeftShift = "LShift",
			RightAlt = "RAlt",      LeftAlt = "LAlt",
			CapsLock = "Caps",      Return = "Enter",
			KeypadEnter = "NumEnter", Escape = "Esc",
		}
		local n = b.Name
		if map[n] then return map[n] end
		if n:sub(1, 3) == "Key" then return n:sub(4) end
		return n
	end
	if b == Enum.UserInputType.MouseButton1 then return "MB1" end
	if b == Enum.UserInputType.MouseButton2 then return "MB2" end
	return b.Name
end

return Keybinds
