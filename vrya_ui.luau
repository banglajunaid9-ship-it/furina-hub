--[[
	Vrya UI 1.0 | Liquid Glass interface prototype for Roblox

	A standalone visual prototype: dark translucent glass window, frosted panels,
	silver borders and floating chrome orbs. Pure UI, nothing here runs user code.

	Run it as a LocalScript (StarterPlayerScripts) or through loadstring:
		local Vrya = loadstring(game:HttpGet("<raw url>/vrya_ui.luau"))()
		Vrya:Notify({ Title = "Hello", Content = "Vrya is ready" })
		Vrya:Toggle()      -- show / hide
		Vrya:Minimize()    -- collapse into the Dynamic Island pill
		Vrya:Destroy()

	Pages: Home, Library, Favorites, Editor, Themes, Settings, About.
	Right Shift (rebindable) toggles the window on PC. On touch screens the window
	collapses into a floating pill; tap the pill to bring it back.

	Persistence: uses writefile/readfile when the environment provides them,
	otherwise state lives for the session in _G.
]]

local Vrya = { Version = "1.0.0" }

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local HttpService = game:GetService("HttpService")
local Lighting = game:GetService("Lighting")
local LP = Players.LocalPlayer

local genv = (typeof(getgenv) == "function" and getgenv()) or _G
if genv.Vrya_Unload then
	pcall(genv.Vrya_Unload)
end

local alive = true
local connections = {}
local function track(conn)
	connections[#connections + 1] = conn
	return conn
end

---------------------------------------------------------------- storage

local STORE_FILE = "vrya_ui.json"
local canFile = typeof(writefile) == "function" and typeof(readfile) == "function" and typeof(isfile) == "function"

local data = {}
if canFile then
	local ok, res = pcall(function()
		if isfile(STORE_FILE) then
			return HttpService:JSONDecode(readfile(STORE_FILE))
		end
		return nil
	end)
	if ok and type(res) == "table" then
		data = res
	end
elseif type(genv.Vrya_Session) == "table" then
	data = genv.Vrya_Session
end
genv.Vrya_Session = data

local saveQueued = false
local function save()
	if saveQueued then
		return
	end
	saveQueued = true
	task.delay(0.35, function()
		saveQueued = false
		if canFile then
			pcall(function()
				writefile(STORE_FILE, HttpService:JSONEncode(data))
			end)
		end
	end)
end

local DEFAULT_SETTINGS = {
	ToggleKey = "RightShift",
	Notifications = true,
	ReduceMotion = false,
	WorldBlur = true,
	Orbs = true,
	Scale = 100,
	IslandWhenHidden = false,
}
data.settings = type(data.settings) == "table" and data.settings or {}
local S = data.settings
for k, v in pairs(DEFAULT_SETTINGS) do
	if S[k] == nil then
		S[k] = v
	end
end
data.favorites = type(data.favorites) == "table" and data.favorites or {}
data.customThemes = type(data.customThemes) == "table" and data.customThemes or {}
data.snippets = type(data.snippets) == "table" and data.snippets or {}
data.recent = type(data.recent) == "table" and data.recent or {}
data.window = type(data.window) == "table" and data.window or { x = 0.5, y = 0.5 }

---------------------------------------------------------------- color helpers

local WHITE = Color3.new(1, 1, 1)
local BLACK = Color3.new(0, 0, 0)

local function toHex(c)
	return string.format(
		"#%02X%02X%02X",
		math.floor(c.R * 255 + 0.5),
		math.floor(c.G * 255 + 0.5),
		math.floor(c.B * 255 + 0.5)
	)
end

local function fromHex(s)
	if type(s) ~= "string" then
		return nil
	end
	s = s:gsub("#", ""):gsub("%s", "")
	if #s == 3 then
		s = s:sub(1, 1):rep(2) .. s:sub(2, 2):rep(2) .. s:sub(3, 3):rep(2)
	end
	if #s ~= 6 or s:find("[^%x]") then
		return nil
	end
	return Color3.fromRGB(tonumber(s:sub(1, 2), 16), tonumber(s:sub(3, 4), 16), tonumber(s:sub(5, 6), 16))
end

local function rgbOf(c)
	return math.floor(c.R * 255 + 0.5), math.floor(c.G * 255 + 0.5), math.floor(c.B * 255 + 0.5)
end

local function NS(...)
	local args = { ... }
	local kps = {}
	for i = 1, #args, 2 do
		kps[#kps + 1] = NumberSequenceKeypoint.new(args[i], math.clamp(args[i + 1], 0, 1))
	end
	return NumberSequence.new(kps)
end

---------------------------------------------------------------- themes

local COLOR_KEYS = { "Background", "Surface", "Accent", "Text", "Border" }

local PRESETS = {
	{ Name = "Graphite", Background = "#0E0E10", Surface = "#3A3A3F", Accent = "#E9E9EE", Text = "#F5F5F7", Border = "#D4D6DC", Glass = 0.80, Blur = 18, Reflection = 0.65 },
	{ Name = "Midnight", Background = "#05070F", Surface = "#26304D", Accent = "#6E95FF", Text = "#EEF2FF", Border = "#9DB2FF", Glass = 0.78, Blur = 20, Reflection = 0.55 },
	{ Name = "Aurora", Background = "#04110D", Surface = "#1E3D34", Accent = "#3DDC97", Text = "#EFFFF8", Border = "#A6F2D2", Glass = 0.76, Blur = 16, Reflection = 0.6 },
	{ Name = "Rose Quartz", Background = "#12080C", Surface = "#45283A", Accent = "#FF7AA8", Text = "#FFF1F5", Border = "#FFC6DA", Glass = 0.78, Blur = 18, Reflection = 0.7 },
	{ Name = "Ember", Background = "#110904", Surface = "#45301E", Accent = "#FF9F43", Text = "#FFF6EC", Border = "#FFD1A1", Glass = 0.80, Blur = 14, Reflection = 0.5 },
	{ Name = "Pearl", Background = "#C9CDD6", Surface = "#F4F5F8", Accent = "#0A84FF", Text = "#1C1C1E", Border = "#FFFFFF", Glass = 0.72, Blur = 24, Reflection = 0.8 },
}

local function themeFromData(d)
	local base = PRESETS[1]
	local t = { Name = tostring(d.Name or "Custom") }
	for _, k in ipairs(COLOR_KEYS) do
		t[k] = fromHex(d[k]) or fromHex(base[k])
	end
	t.Glass = math.clamp(tonumber(d.Glass) or base.Glass, 0.2, 1)
	t.Blur = math.clamp(tonumber(d.Blur) or base.Blur, 0, 56)
	t.Reflection = math.clamp(tonumber(d.Reflection) or base.Reflection, 0, 1)
	return t
end

local function themeToData(t)
	local d = { Name = t.Name }
	for _, k in ipairs(COLOR_KEYS) do
		d[k] = toHex(t[k])
	end
	d.Glass = math.floor(t.Glass * 100 + 0.5) / 100
	d.Blur = math.floor(t.Blur + 0.5)
	d.Reflection = math.floor(t.Reflection * 100 + 0.5) / 100
	return d
end

local T = themeFromData(type(data.theme) == "table" and data.theme or PRESETS[1])

local function C(key)
	return function(t)
		return t[key]
	end
end
local function SUB(t)
	return t.Text:Lerp(t.Background, 0.42)
end
local function MUTED(t)
	return t.Text:Lerp(t.Background, 0.62)
end
local function ON_ACCENT(t)
	-- readable text on top of the accent color
	local r, g, b = t.Accent.R, t.Accent.G, t.Accent.B
	return (0.299 * r + 0.587 * g + 0.114 * b) > 0.6 and Color3.fromRGB(18, 18, 20) or WHITE
end

-- Every themed property registers here so theme edits repaint the whole UI live.
local bindings = {}
local themeListeners = {}
local themeTweenInfo = TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

local function bind(inst, prop, fn)
	local b = { inst = inst, prop = prop, fn = fn, seen = inst.Parent ~= nil }
	bindings[#bindings + 1] = b
	inst[prop] = fn(T)
	return inst
end

local function applyTheme(instant)
	local keep = {}
	for _, b in ipairs(bindings) do
		local inst = b.inst
		if inst.Parent then
			b.seen = true
		end
		if inst.Parent or not b.seen then
			local v = b.fn(T)
			local tv = typeof(v)
			if instant or S.ReduceMotion or (tv ~= "Color3" and tv ~= "number") then
				inst[b.prop] = v
			else
				TweenService:Create(inst, themeTweenInfo, { [b.prop] = v }):Play()
			end
			keep[#keep + 1] = b
		end
	end
	bindings = keep
	for _, fn in ipairs(themeListeners) do
		task.spawn(fn, T)
	end
end

local themeQueued = false
local function queueThemeInstant()
	if themeQueued then
		return
	end
	themeQueued = true
	task.defer(function()
		themeQueued = false
		applyTheme(true)
	end)
end

local function persistTheme()
	data.theme = themeToData(T)
	save()
end

---------------------------------------------------------------- instance helpers

local FONT_FAMILY = "rbxasset://fonts/families/GothamSSm.json"
local MONO_FAMILY = "rbxasset://fonts/families/RobotoMono.json"
local W = Enum.FontWeight

local function font(weight)
	return Font.new(FONT_FAMILY, weight or W.Regular)
end

local function new(class, props, children)
	local inst = Instance.new(class)
	local parent
	if props then
		for k, v in pairs(props) do
			if k == "Parent" then
				parent = v
			else
				inst[k] = v
			end
		end
	end
	if children then
		for _, c in ipairs(children) do
			c.Parent = inst
		end
	end
	if parent then
		inst.Parent = parent
	end
	return inst
end

local function corner(inst, r)
	return new("UICorner", { CornerRadius = typeof(r) == "UDim" and r or UDim.new(0, r or 12), Parent = inst })
end
local ROUND = UDim.new(1, 0)

local function padding(inst, t, r, b, l)
	return new("UIPadding", {
		PaddingTop = UDim.new(0, t or 0),
		PaddingRight = UDim.new(0, r or t or 0),
		PaddingBottom = UDim.new(0, b or t or 0),
		PaddingLeft = UDim.new(0, l or r or t or 0),
		Parent = inst,
	})
end

local function list(inst, pad, horizontal, valign, halign)
	return new("UIListLayout", {
		Padding = UDim.new(0, pad or 8),
		FillDirection = horizontal and Enum.FillDirection.Horizontal or Enum.FillDirection.Vertical,
		SortOrder = Enum.SortOrder.LayoutOrder,
		VerticalAlignment = valign or Enum.VerticalAlignment.Top,
		HorizontalAlignment = halign or Enum.HorizontalAlignment.Left,
		Parent = inst,
	})
end

local function tween(inst, time, props, style, dir)
	local tw = TweenService:Create(
		inst,
		TweenInfo.new(S.ReduceMotion and 0 or time, style or Enum.EasingStyle.Quint, dir or Enum.EasingDirection.Out),
		props
	)
	tw:Play()
	return tw
end

local function label(parent, p)
	local size = p.Size or 14
	local l = new("TextLabel", {
		BackgroundTransparency = 1,
		FontFace = p.Font or font(p.Weight),
		TextSize = size,
		Text = p.Text or "",
		RichText = p.Rich or false,
		TextWrapped = p.Wrap or false,
		TextXAlignment = p.AlignX or Enum.TextXAlignment.Left,
		TextYAlignment = p.AlignY or Enum.TextYAlignment.Center,
		TextTruncate = p.Truncate and Enum.TextTruncate.AtEnd or Enum.TextTruncate.None,
		Size = p.UDim or UDim2.new(1, 0, 0, size + 6),
		Position = p.Position,
		AnchorPoint = p.Anchor,
		AutomaticSize = p.Auto,
		LayoutOrder = p.Order or 0,
		ZIndex = p.Z or 1,
		Parent = parent,
	})
	bind(l, "TextColor3", p.Color or C("Text"))
	if p.Transparency then
		l.TextTransparency = p.Transparency
	end
	return l
end

-- Diagonal white sheen: the "reflection" on top of every glass surface.
local function sheen(parent, radius)
	local s = new("Frame", {
		Name = "Sheen",
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = WHITE,
		BorderSizePixel = 0,
		ZIndex = 0,
		Parent = parent,
	})
	corner(s, radius)
	local g = new("UIGradient", { Rotation = 28, Parent = s })
	bind(g, "Transparency", function(t)
		local r = t.Reflection
		return NS(0, 1 - 0.13 * r, 0.35, 1 - 0.025 * r, 0.6, 1, 1, 1 - 0.05 * r)
	end)
	return s
end

-- Silver rim: a UIStroke whose gradient brightens two opposite corners like polished metal.
local function rim(parent, transparency)
	local st = new("UIStroke", {
		Thickness = 1,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
		Transparency = transparency or 0.55,
		Parent = parent,
	})
	bind(st, "Color", C("Border"))
	new("UIGradient", { Rotation = 35, Transparency = NS(0, 0, 0.45, 0.8, 0.7, 0.75, 1, 0.1), Parent = st })
	return st
end

-- Frosted glass panel. Strength scales the theme's glass opacity for this layer.
local function glass(parent, p)
	p = p or {}
	local f = new(p.Class or "Frame", {
		Name = p.Name or "Glass",
		Size = p.Size or UDim2.new(1, 0, 0, 60),
		Position = p.Position,
		AnchorPoint = p.Anchor,
		AutomaticSize = p.Auto,
		LayoutOrder = p.Order or 0,
		BorderSizePixel = 0,
		ClipsDescendants = p.Clip or false,
		ZIndex = p.Z or 1,
		Parent = parent,
	})
	if p.Class == "TextButton" then
		f.Text = ""
		f.AutoButtonColor = false
	end
	local tint = p.Tint or "Surface"
	bind(f, "BackgroundColor3", function(t)
		return t[tint]
	end)
	local k = p.Strength or 0.45
	bind(f, "BackgroundTransparency", function(t)
		return 1 - math.clamp(t.Glass * k, 0, 1)
	end)
	corner(f, p.Radius or 16)
	if not p.NoRim then
		rim(f, p.RimT)
	end
	if not p.NoSheen then
		sheen(f, p.Radius or 16)
	end
	return f
end

-- Press bounce shared by all buttons.
local function pressable(btn)
	local sc = new("UIScale", { Parent = btn })
	btn.MouseButton1Down:Connect(function()
		tween(sc, 0.12, { Scale = 0.95 })
	end)
	local function release()
		tween(sc, 0.35, { Scale = 1 }, Enum.EasingStyle.Back)
	end
	btn.MouseButton1Up:Connect(release)
	btn.MouseLeave:Connect(release)
	return sc
end

-- Shared drag helper for sliders, color fields and the window.
local function onDrag(guiObj, onMove, onEnd, onStart)
	local dragging = false
	guiObj.InputBegan:Connect(function(input)
		local ut = input.UserInputType
		if ut == Enum.UserInputType.MouseButton1 or ut == Enum.UserInputType.Touch then
			if onStart and onStart(input) == false then
				return
			end
			dragging = true
			onMove(input.Position, true)
			local c
			c = input.Changed:Connect(function()
				if input.UserInputState == Enum.UserInputState.End then
					dragging = false
					c:Disconnect()
					if onEnd then
						onEnd()
					end
				end
			end)
		end
	end)
	track(UserInputService.InputChanged:Connect(function(input)
		if not dragging then
			return
		end
		local ut = input.UserInputType
		if ut == Enum.UserInputType.MouseMovement or ut == Enum.UserInputType.Touch then
			onMove(input.Position, false)
		end
	end))
end

---------------------------------------------------------------- screen gui

local playerGui = LP:WaitForChild("PlayerGui")
local gui = new("ScreenGui", {
	Name = "Vrya",
	ResetOnSpawn = false,
	IgnoreGuiInset = false,
	ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
	DisplayOrder = 60,
	Parent = playerGui,
})

local blurFx = new("BlurEffect", { Name = "VryaBlur", Size = 0, Parent = Lighting })

---------------------------------------------------------------- components

local UI = {}

-- Pill button. Style: "primary" (accent fill), "glass" (frosted), "danger".
function UI.Button(parent, p)
	local style = p.Style or "glass"
	local b = new("TextButton", {
		Name = "Button",
		Size = p.Size or UDim2.fromOffset(0, 34),
		AutomaticSize = p.Size and Enum.AutomaticSize.None or Enum.AutomaticSize.X,
		Position = p.Position,
		AnchorPoint = p.Anchor,
		BorderSizePixel = 0,
		AutoButtonColor = false,
		Text = p.Text or "",
		FontFace = font(W.Medium),
		TextSize = p.TextSize or 13,
		LayoutOrder = p.Order or 0,
		Parent = parent,
	})
	corner(b, ROUND)
	padding(b, 0, 16, 0, 16)
	if style == "primary" then
		bind(b, "BackgroundColor3", C("Accent"))
		bind(b, "TextColor3", ON_ACCENT)
		b.BackgroundTransparency = 0.05
	elseif style == "danger" then
		b.BackgroundColor3 = Color3.fromRGB(255, 69, 58)
		b.BackgroundTransparency = 0.78
		b.TextColor3 = Color3.fromRGB(255, 140, 130)
		rim(b, 0.7)
	else
		bind(b, "BackgroundColor3", C("Text"))
		b.BackgroundTransparency = 0.92
		bind(b, "TextColor3", C("Text"))
		rim(b, 0.65)
	end
	local base = b.BackgroundTransparency
	b.MouseEnter:Connect(function()
		tween(b, 0.2, { BackgroundTransparency = math.max(base - 0.08, 0) })
	end)
	b.MouseLeave:Connect(function()
		tween(b, 0.25, { BackgroundTransparency = base })
	end)
	pressable(b)
	if p.Callback then
		b.MouseButton1Click:Connect(p.Callback)
	end
	return b
end

-- Small round icon button (text glyph).
function UI.IconButton(parent, p)
	local b = new("TextButton", {
		Size = UDim2.fromOffset(p.Px or 30, p.Px or 30),
		Position = p.Position,
		AnchorPoint = p.Anchor,
		BorderSizePixel = 0,
		AutoButtonColor = false,
		Text = p.Text,
		FontFace = font(W.Bold),
		TextSize = p.TextSize or 15,
		LayoutOrder = p.Order or 0,
		Parent = parent,
	})
	corner(b, ROUND)
	bind(b, "BackgroundColor3", C("Text"))
	b.BackgroundTransparency = 0.93
	bind(b, "TextColor3", p.Color or C("Text"))
	pressable(b)
	b.MouseEnter:Connect(function()
		tween(b, 0.2, { BackgroundTransparency = 0.85 })
	end)
	b.MouseLeave:Connect(function()
		tween(b, 0.2, { BackgroundTransparency = 0.93 })
	end)
	if p.Callback then
		b.MouseButton1Click:Connect(p.Callback)
	end
	return b
end

-- Row with a title, optional description and something on the right.
function UI.Row(parent, p)
	local row = glass(parent, { Size = UDim2.new(1, 0, 0, p.Desc and 62 or 50), Order = p.Order, Strength = 0.32, Radius = 14 })
	padding(row, 0, 14, 0, 16)
	local titleY = p.Desc and -9 or 0
	label(row, {
		Text = p.Text,
		Size = 14,
		Weight = W.Medium,
		UDim = UDim2.new(1, -(p.RightWidth or 120), 0, 20),
		Position = UDim2.new(0, 0, 0.5, titleY),
		Anchor = Vector2.new(0, 0.5),
		Truncate = true,
	})
	if p.Desc then
		label(row, {
			Text = p.Desc,
			Size = 12,
			Color = SUB,
			UDim = UDim2.new(1, -(p.RightWidth or 120), 0, 16),
			Position = UDim2.new(0, 0, 0.5, 11),
			Anchor = Vector2.new(0, 0.5),
			Truncate = true,
		})
	end
	return row
end

function UI.Toggle(parent, p)
	local state = p.Value and true or false
	local row = UI.Row(parent, { Text = p.Text, Desc = p.Desc, Order = p.Order, RightWidth = 70 })
	local trackF = new("TextButton", {
		Size = UDim2.fromOffset(46, 28),
		Position = UDim2.new(1, 0, 0.5, 0),
		AnchorPoint = Vector2.new(1, 0.5),
		Text = "",
		AutoButtonColor = false,
		BorderSizePixel = 0,
		Parent = row,
	})
	corner(trackF, ROUND)
	bind(trackF, "BackgroundColor3", function(t)
		return state and t.Accent or t.Text
	end)
	trackF.BackgroundTransparency = state and 0.05 or 0.86
	local knob = new("Frame", {
		Size = UDim2.fromOffset(22, 22),
		Position = state and UDim2.new(1, -25, 0.5, 0) or UDim2.new(0, 3, 0.5, 0),
		AnchorPoint = Vector2.new(0, 0.5),
		BackgroundColor3 = WHITE,
		BorderSizePixel = 0,
		Parent = trackF,
	})
	corner(knob, ROUND)
	new("UIGradient", {
		Rotation = 90,
		Color = ColorSequence.new(WHITE, Color3.fromRGB(214, 216, 222)),
		Parent = knob,
	})
	local api = {}
	local function render()
		tween(trackF, 0.3, {
			BackgroundColor3 = state and T.Accent or T.Text,
			BackgroundTransparency = state and 0.05 or 0.86,
		})
		tween(knob, 0.4, { Position = state and UDim2.new(1, -25, 0.5, 0) or UDim2.new(0, 3, 0.5, 0) }, Enum.EasingStyle.Back)
	end
	function api.Set(v, silent)
		state = v and true or false
		render()
		if not silent and p.Callback then
			task.spawn(p.Callback, state)
		end
	end
	function api.Get()
		return state
	end
	trackF.MouseButton1Click:Connect(function()
		api.Set(not state)
	end)
	api.Instance = row
	return api
end

function UI.Slider(parent, p)
	local min, max, step = p.Min or 0, p.Max or 100, p.Step or 1
	local value = math.clamp(p.Value or min, min, max)
	local row = glass(parent, { Size = UDim2.new(1, 0, 0, 64), Order = p.Order, Strength = 0.32, Radius = 14 })
	padding(row, 10, 16, 12, 16)
	label(row, { Text = p.Text, Size = 14, Weight = W.Medium, UDim = UDim2.new(1, -80, 0, 20) })
	local valueLbl = label(row, {
		Text = "",
		Size = 13,
		Color = SUB,
		UDim = UDim2.new(0, 80, 0, 20),
		Position = UDim2.new(1, 0, 0, 0),
		Anchor = Vector2.new(1, 0),
		AlignX = Enum.TextXAlignment.Right,
		Font = Font.new(MONO_FAMILY),
	})
	local bar = new("Frame", {
		Size = UDim2.new(1, 0, 0, 6),
		Position = UDim2.new(0, 0, 1, -6),
		BorderSizePixel = 0,
		Parent = row,
	})
	corner(bar, ROUND)
	bind(bar, "BackgroundColor3", C("Text"))
	bar.BackgroundTransparency = 0.85
	local fill = new("Frame", { Size = UDim2.fromScale(0, 1), BorderSizePixel = 0, Parent = bar })
	corner(fill, ROUND)
	bind(fill, "BackgroundColor3", C("Accent"))
	local knob = new("Frame", {
		Size = UDim2.fromOffset(18, 18),
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0, 0.5),
		BackgroundColor3 = WHITE,
		BorderSizePixel = 0,
		Parent = bar,
	})
	corner(knob, ROUND)
	local kst = new("UIStroke", { Thickness = 1, Transparency = 0.6, Parent = knob })
	bind(kst, "Color", C("Border"))
	-- wide invisible hit area so the bar is easy to grab on touch screens
	local hit = new("TextButton", {
		Size = UDim2.new(1, 16, 0, 30),
		Position = UDim2.new(0, -8, 0.5, 0),
		AnchorPoint = Vector2.new(0, 0.5),
		BackgroundTransparency = 1,
		Text = "",
		Parent = bar,
	})
	local function fmt(v)
		if p.Format then
			return p.Format(v)
		end
		return tostring(v) .. (p.Suffix or "")
	end
	local api = {}
	local function render(animate)
		local a = (value - min) / (max - min)
		valueLbl.Text = fmt(value)
		if animate then
			tween(fill, 0.25, { Size = UDim2.fromScale(a, 1) })
			tween(knob, 0.25, { Position = UDim2.fromScale(a, 0.5) })
		else
			fill.Size = UDim2.fromScale(a, 1)
			knob.Position = UDim2.fromScale(a, 0.5)
		end
	end
	function api.Set(v, silent, animate)
		v = math.clamp(math.floor((v - min) / step + 0.5) * step + min, min, max)
		v = math.floor(v * 1000 + 0.5) / 1000
		local changed = v ~= value
		value = v
		render(animate)
		if changed and not silent and p.Callback then
			p.Callback(value)
		end
	end
	function api.Get()
		return value
	end
	onDrag(hit, function(pos)
		local a = math.clamp((pos.X - bar.AbsolutePosition.X) / math.max(bar.AbsoluteSize.X, 1), 0, 1)
		api.Set(min + (max - min) * a)
	end, function()
		if p.Released then
			p.Released(value)
		end
	end)
	render(false)
	api.Instance = row
	return api
end

function UI.Input(parent, p)
	local box = new("TextBox", {
		Size = p.Size or UDim2.new(1, 0, 0, 38),
		Position = p.Position,
		AnchorPoint = p.Anchor,
		BorderSizePixel = 0,
		Text = p.Text or "",
		PlaceholderText = p.Placeholder or "",
		ClearTextOnFocus = false,
		FontFace = p.Mono and Font.new(MONO_FAMILY) or font(),
		TextSize = p.TextSize or 13,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = p.MultiLine and Enum.TextYAlignment.Top or Enum.TextYAlignment.Center,
		MultiLine = p.MultiLine or false,
		TextWrapped = p.MultiLine or false,
		ClipsDescendants = true,
		LayoutOrder = p.Order or 0,
		Parent = parent,
	})
	corner(box, p.Radius or 12)
	padding(box, p.MultiLine and 10 or 0, 12, p.MultiLine and 10 or 0, p.LeftPad or 12)
	bind(box, "BackgroundColor3", C("Background"))
	bind(box, "BackgroundTransparency", function(t)
		return 1 - t.Glass * 0.45
	end)
	bind(box, "TextColor3", C("Text"))
	bind(box, "PlaceholderColor3", MUTED)
	local st = rim(box, 0.7)
	box.Focused:Connect(function()
		tween(st, 0.2, { Transparency = 0.15 })
	end)
	box.FocusLost:Connect(function(enter)
		tween(st, 0.25, { Transparency = 0.7 })
		if p.Submit then
			p.Submit(box.Text, enter)
		end
	end)
	return box
end

-- Selectable capsule (filters, targets). Returns an object with Set(active).
function UI.Chip(parent, p)
	local active = p.Active or false
	local b = new("TextButton", {
		Size = UDim2.fromOffset(0, 30),
		AutomaticSize = Enum.AutomaticSize.X,
		BorderSizePixel = 0,
		AutoButtonColor = false,
		Text = p.Text,
		FontFace = font(W.Medium),
		TextSize = 12,
		LayoutOrder = p.Order or 0,
		Parent = parent,
	})
	corner(b, ROUND)
	padding(b, 0, 14, 0, 14)
	local st = rim(b, 0.7)
	bind(b, "BackgroundColor3", function(t)
		return active and t.Accent or t.Text
	end)
	bind(b, "TextColor3", function(t)
		return active and ON_ACCENT(t) or t.Text
	end)
	b.BackgroundTransparency = active and 0.05 or 0.93
	pressable(b)
	local api = { Instance = b }
	function api.Set(v)
		active = v
		tween(b, 0.25, {
			BackgroundColor3 = active and T.Accent or T.Text,
			BackgroundTransparency = active and 0.05 or 0.93,
			TextColor3 = active and ON_ACCENT(T) or T.Text,
		})
		st.Transparency = active and 0.9 or 0.7
	end
	if p.Callback then
		b.MouseButton1Click:Connect(p.Callback)
	end
	return api
end

function UI.Section(parent, text, order)
	return label(parent, {
		Text = string.upper(text),
		Size = 11,
		Weight = W.SemiBold,
		Color = SUB,
		Order = order,
		UDim = UDim2.new(1, 0, 0, 22),
		AlignY = Enum.TextYAlignment.Bottom,
	})
end

-- Responsive grid: columns follow the container width, never below minCell.
local currentScale = 1
function UI.Grid(parent, minCell, cellH, gap, order)
	gap = gap or 12
	local holder = new("Frame", {
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		LayoutOrder = order or 0,
		Parent = parent,
	})
	local grid = new("UIGridLayout", {
		CellPadding = UDim2.fromOffset(gap, gap),
		CellSize = UDim2.fromOffset(minCell, cellH),
		SortOrder = Enum.SortOrder.LayoutOrder,
		Parent = holder,
	})
	local function relayout()
		local w = holder.AbsoluteSize.X / math.max(currentScale, 0.01)
		if w <= 0 then
			return
		end
		local cols = math.max(1, math.floor((w + gap) / (minCell + gap)))
		grid.CellSize = UDim2.fromOffset(math.floor((w - gap * (cols - 1)) / cols), cellH)
	end
	holder:GetPropertyChangedSignal("AbsoluteSize"):Connect(relayout)
	task.defer(relayout)
	return holder, relayout
end

---------------------------------------------------------------- notifications

local notifyHolder = new("Frame", {
	Name = "Notifications",
	Size = UDim2.new(0, 300, 1, -20),
	Position = UDim2.new(1, -14, 0, 10),
	AnchorPoint = Vector2.new(1, 0),
	BackgroundTransparency = 1,
	ZIndex = 20,
	Parent = gui,
})
list(notifyHolder, 10, false, Enum.VerticalAlignment.Top, Enum.HorizontalAlignment.Right)
local notifyScale = new("UIScale", { Parent = notifyHolder })
local notifyOrder = 0

function Vrya:Notify(p)
	p = type(p) == "table" and p or { Content = tostring(p) }
	if not S.Notifications and not p.Force then
		return
	end
	notifyOrder -= 1
	local duration = p.Duration or 4
	local outer = new("Frame", {
		Size = UDim2.new(1, 0, 0, 0),
		BackgroundTransparency = 1,
		ClipsDescendants = false,
		LayoutOrder = notifyOrder,
		Parent = notifyHolder,
	})
	local card = glass(outer, {
		Class = "TextButton",
		Size = UDim2.new(1, 0, 0, 74),
		Position = UDim2.new(1, 40, 0, 0),
		Strength = 1.05,
		Tint = "Surface",
		Radius = 18,
	})
	local dot = new("Frame", {
		Size = UDim2.fromOffset(8, 8),
		Position = UDim2.fromOffset(16, 20),
		AnchorPoint = Vector2.new(0, 0.5),
		BorderSizePixel = 0,
		Parent = card,
	})
	corner(dot, ROUND)
	bind(dot, "BackgroundColor3", C("Accent"))
	label(card, {
		Text = p.Title or "Vrya",
		Size = 13,
		Weight = W.SemiBold,
		UDim = UDim2.new(1, -70, 0, 18),
		Position = UDim2.fromOffset(32, 11),
		Truncate = true,
	})
	label(card, {
		Text = "now",
		Size = 11,
		Color = MUTED,
		UDim = UDim2.new(0, 40, 0, 18),
		Position = UDim2.new(1, -14, 0, 11),
		Anchor = Vector2.new(1, 0),
		AlignX = Enum.TextXAlignment.Right,
	})
	label(card, {
		Text = p.Content or "",
		Size = 12,
		Color = SUB,
		Wrap = true,
		AlignY = Enum.TextYAlignment.Top,
		UDim = UDim2.new(1, -46, 0, 32),
		Position = UDim2.fromOffset(32, 31),
	})
	local bar = new("Frame", {
		Size = UDim2.new(1, -36, 0, 2),
		Position = UDim2.new(0, 18, 1, -6),
		BorderSizePixel = 0,
		Parent = card,
	})
	corner(bar, ROUND)
	bind(bar, "BackgroundColor3", C("Accent"))
	bar.BackgroundTransparency = 0.4

	local closed = false
	local function close()
		if closed then
			return
		end
		closed = true
		tween(card, 0.35, { Position = UDim2.new(1, 60, 0, 0) }, Enum.EasingStyle.Quint, Enum.EasingDirection.In)
		task.wait(S.ReduceMotion and 0 or 0.3)
		tween(outer, 0.25, { Size = UDim2.new(1, 0, 0, 0) })
		task.wait(S.ReduceMotion and 0 or 0.26)
		outer:Destroy()
	end
	card.MouseButton1Click:Connect(function()
		task.spawn(close)
	end)

	tween(outer, 0.3, { Size = UDim2.new(1, 0, 0, 74) })
	tween(card, 0.55, { Position = UDim2.new(0, 0, 0, 0) }, Enum.EasingStyle.Back)
	TweenService:Create(bar, TweenInfo.new(duration, Enum.EasingStyle.Linear), { Size = UDim2.new(0, 0, 0, 2) }):Play()
	task.delay(duration, close)

	-- keep the stack short
	local cards = {}
	for _, c in ipairs(notifyHolder:GetChildren()) do
		if c:IsA("Frame") then
			cards[#cards + 1] = c
		end
	end
	if #cards > 4 then
		table.sort(cards, function(a, b)
			return a.LayoutOrder > b.LayoutOrder
		end)
		cards[1]:Destroy()
	end
end

local function notify(title, content, duration)
	task.spawn(function()
		Vrya:Notify({ Title = title, Content = content, Duration = duration })
	end)
end

---------------------------------------------------------------- window shell

local BASE_W, BASE_H = 860, 540
local TOPBAR_H = 52
local state = {
	visible = true,
	minimized = false,
	maximized = false,
	compact = false,
	winW = BASE_W,
	winH = BASE_H,
	deviceScale = 1,
}

local stage = new("Frame", {
	Name = "Stage",
	AnchorPoint = Vector2.new(0.5, 0.5),
	BackgroundTransparency = 1,
	Size = UDim2.fromOffset(BASE_W, BASE_H),
	Position = UDim2.fromScale(tonumber(data.window.x) or 0.5, tonumber(data.window.y) or 0.5),
	Parent = gui,
})
local stageScale = new("UIScale", { Parent = stage })

-- Floating chrome objects behind the glass (spheres + rings, like polished metal).
local CHROME = ColorSequence.new({
	ColorSequenceKeypoint.new(0, Color3.fromRGB(252, 252, 254)),
	ColorSequenceKeypoint.new(0.25, Color3.fromRGB(168, 171, 178)),
	ColorSequenceKeypoint.new(0.5, Color3.fromRGB(40, 41, 46)),
	ColorSequenceKeypoint.new(0.75, Color3.fromRGB(128, 131, 140)),
	ColorSequenceKeypoint.new(1, Color3.fromRGB(238, 239, 243)),
})

local backdrop = new("Frame", {
	Name = "Backdrop",
	Size = UDim2.fromScale(1, 1),
	BackgroundTransparency = 1,
	ZIndex = 0,
	Parent = stage,
})
local driftTweens = {}

local function drift(inst, dx, dy, time)
	local p = inst.Position
	local tw = TweenService:Create(
		inst,
		TweenInfo.new(time, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
		{ Position = UDim2.new(p.X.Scale, p.X.Offset + dx, p.Y.Scale, p.Y.Offset + dy) }
	)
	driftTweens[#driftTweens + 1] = tw
	return tw
end

local function chromeSphere(size, ax, ay, ox, oy)
	local s = new("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Size = UDim2.fromOffset(size, size),
		Position = UDim2.new(ax, ox, ay, oy),
		BorderSizePixel = 0,
		Parent = backdrop,
	})
	corner(s, ROUND)
	bind(s, "BackgroundColor3", function(t)
		return WHITE:Lerp(t.Accent, 0.12)
	end)
	new("UIGradient", { Rotation = 125, Color = CHROME, Parent = s })
	local hl = new("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Size = UDim2.fromScale(0.42, 0.26),
		Position = UDim2.fromScale(0.36, 0.27),
		Rotation = -32,
		BackgroundColor3 = WHITE,
		BackgroundTransparency = 0.2,
		BorderSizePixel = 0,
		Parent = s,
	})
	corner(hl, ROUND)
	new("UIGradient", { Rotation = 90, Transparency = NS(0, 0, 1, 1), Parent = hl })
	drift(s, math.random(-10, 10), math.random(8, 16), 5 + math.random() * 3)
	return s
end

local function chromeRing(size, thickness, ax, ay, ox, oy)
	local r = new("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Size = UDim2.fromOffset(size, size),
		Position = UDim2.new(ax, ox, ay, oy),
		BackgroundTransparency = 1,
		Parent = backdrop,
	})
	corner(r, ROUND)
	local st = new("UIStroke", { Thickness = thickness, Parent = r })
	bind(st, "Color", function(t)
		return WHITE:Lerp(t.Accent, 0.12)
	end)
	new("UIGradient", { Rotation = 60, Color = CHROME, Parent = st })
	drift(r, math.random(-14, 14), math.random(-10, 10), 7 + math.random() * 3)
	return r
end

chromeSphere(96, 0.7, 0, 0, -18)
chromeSphere(130, 1, 0.42, 18, 0)
chromeSphere(62, 1, 0.66, 4, 0)
chromeRing(300, 36, 0.66, 1, -20, 26)
chromeRing(190, 22, 0, 0.66, -30, 0)

-- The main glass sheet.
local win = new("Frame", {
	Name = "Window",
	Size = UDim2.fromScale(1, 1),
	BorderSizePixel = 0,
	ZIndex = 2,
	Parent = stage,
})
corner(win, 26)
bind(win, "BackgroundColor3", function(t)
	return t.Surface:Lerp(t.Background, 0.55)
end)
bind(win, "BackgroundTransparency", function(t)
	return 1 - t.Glass
end)
rim(win, 0.35)

local clip = new("Frame", {
	Name = "Clip",
	Size = UDim2.fromScale(1, 1),
	BackgroundTransparency = 1,
	ClipsDescendants = true,
	Parent = win,
})

-- Soft frosted highlights inside the glass: stacked translucent circles read as blur.
local glowLayer = new("Frame", { Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, Parent = clip })
local function softGlow(size, ax, ay, strength)
	local g = new("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Size = UDim2.fromOffset(size, size),
		Position = UDim2.fromScale(ax, ay),
		BackgroundTransparency = 1,
		Parent = glowLayer,
	})
	local rings = 8
	for i = 1, rings do
		local c = new("Frame", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Size = UDim2.fromScale(i / rings, i / rings),
			Position = UDim2.fromScale(0.5, 0.5),
			BorderSizePixel = 0,
			Parent = g,
		})
		corner(c, ROUND)
		bind(c, "BackgroundColor3", function(t)
			return WHITE:Lerp(t.Accent, 0.3)
		end)
		bind(c, "BackgroundTransparency", function(t)
			return 1 - 0.045 * strength * t.Reflection
		end)
	end
	drift(g, math.random(-24, 24), math.random(-18, 18), 9 + math.random() * 4)
	return g
end
softGlow(260, 0.68, 0.02, 1)
softGlow(300, 1.0, 0.4, 1.2)
softGlow(460, 0.62, 0.98, 1.1)
softGlow(260, 0.0, 0.72, 0.9)
sheen(clip, 26)

---------------------------------------------------------------- top bar

local topbar = new("Frame", {
	Name = "Topbar",
	Size = UDim2.new(1, 0, 0, TOPBAR_H),
	BackgroundTransparency = 1,
	Parent = clip,
})
local divider = new("Frame", {
	Size = UDim2.new(1, 0, 0, 1),
	Position = UDim2.new(0, 0, 1, 0),
	BorderSizePixel = 0,
	Parent = topbar,
})
bind(divider, "BackgroundColor3", C("Border"))
divider.BackgroundTransparency = 0.82

local lights = new("Frame", {
	Size = UDim2.fromOffset(78, 20),
	Position = UDim2.new(0, 20, 0.5, 0),
	AnchorPoint = Vector2.new(0, 0.5),
	BackgroundTransparency = 1,
	Parent = topbar,
})
list(lights, 8, true, Enum.VerticalAlignment.Center)

local function trafficLight(color, glyph, order)
	local b = new("TextButton", {
		Size = UDim2.fromOffset(14, 14),
		BackgroundColor3 = color,
		BorderSizePixel = 0,
		AutoButtonColor = false,
		Text = "",
		FontFace = font(W.Bold),
		TextSize = 10,
		TextColor3 = Color3.fromRGB(60, 20, 15),
		LayoutOrder = order,
		Parent = lights,
	})
	corner(b, ROUND)
	-- glossy bead look
	new("UIGradient", {
		Rotation = 90,
		Color = ColorSequence.new(color:Lerp(WHITE, 0.45), color:Lerp(BLACK, 0.15)),
		Parent = b,
	})
	new("UIStroke", { Thickness = 1, Color = BLACK, Transparency = 0.75, Parent = b })
	pressable(b)
	lights.MouseEnter:Connect(function()
		b.Text = glyph
	end)
	lights.MouseLeave:Connect(function()
		b.Text = ""
	end)
	return b
end
local btnClose = trafficLight(Color3.fromRGB(255, 95, 87), "×", 1)
local btnMin = trafficLight(Color3.fromRGB(254, 188, 46), "–", 2)
local btnZoom = trafficLight(Color3.fromRGB(40, 200, 64), "+", 3)

local addressLbl = label(topbar, {
	Text = "vrya.app/home",
	Size = 13,
	Color = SUB,
	UDim = UDim2.new(0, 260, 1, 0),
	Position = UDim2.fromScale(0.5, 0),
	Anchor = Vector2.new(0.5, 0),
	AlignX = Enum.TextXAlignment.Center,
})
local clockLbl = label(topbar, {
	Text = "",
	Size = 12,
	Color = SUB,
	UDim = UDim2.new(0, 120, 1, 0),
	Position = UDim2.new(1, -20, 0, 0),
	Anchor = Vector2.new(1, 0),
	AlignX = Enum.TextXAlignment.Right,
	Font = Font.new(MONO_FAMILY),
})

---------------------------------------------------------------- sidebar + content

local body = new("Frame", {
	Name = "Body",
	Size = UDim2.new(1, 0, 1, -TOPBAR_H),
	Position = UDim2.fromOffset(0, TOPBAR_H),
	BackgroundTransparency = 1,
	Parent = clip,
})
local sidebar = new("Frame", {
	Name = "Sidebar",
	Size = UDim2.new(0, 196, 1, 0),
	BackgroundTransparency = 1,
	Parent = body,
})
local sideLine = new("Frame", {
	Size = UDim2.new(0, 1, 1, -24),
	Position = UDim2.new(1, 0, 0, 12),
	BorderSizePixel = 0,
	Parent = sidebar,
})
bind(sideLine, "BackgroundColor3", C("Border"))
sideLine.BackgroundTransparency = 0.85

local brand = label(sidebar, {
	Text = "Vrya",
	Size = 26,
	Weight = W.Bold,
	UDim = UDim2.new(1, -36, 0, 34),
	Position = UDim2.fromOffset(22, 14),
})
local brandSub = label(sidebar, {
	Text = "liquid glass",
	Size = 11,
	Color = MUTED,
	UDim = UDim2.new(1, -36, 0, 14),
	Position = UDim2.fromOffset(23, 46),
})

local navHolder = new("Frame", {
	Size = UDim2.new(1, -24, 1, -150),
	Position = UDim2.fromOffset(12, 76),
	BackgroundTransparency = 1,
	Parent = sidebar,
})
local indicator = glass(navHolder, {
	Name = "Indicator",
	Size = UDim2.new(1, 0, 0, 38),
	Strength = 0.75,
	Tint = "Accent",
	Radius = 12,
	RimT = 0.5,
})
bind(indicator, "BackgroundTransparency", function(t)
	return 1 - math.clamp(0.16 + t.Glass * 0.06, 0, 1)
end)

local NAV = {
	{ id = "home", text = "Home", icon = "⌂" },
	{ id = "library", text = "Library", icon = "▤" },
	{ id = "favorites", text = "Favorites", icon = "★" },
	{ id = "editor", text = "Editor", icon = "</>" },
	{ id = "themes", text = "Themes", icon = "◐" },
	{ id = "settings", text = "Settings", icon = "⚙" },
	{ id = "about", text = "About", icon = "i" },
}
local NAV_STEP = 42
local navButtons = {}

local profile = new("Frame", {
	Size = UDim2.new(1, -24, 0, 48),
	Position = UDim2.new(0, 12, 1, -60),
	BackgroundTransparency = 1,
	Parent = sidebar,
})
local avatar = new("ImageLabel", {
	Size = UDim2.fromOffset(32, 32),
	Position = UDim2.new(0, 8, 0.5, 0),
	AnchorPoint = Vector2.new(0, 0.5),
	BorderSizePixel = 0,
	Image = "",
	Parent = profile,
})
corner(avatar, ROUND)
bind(avatar, "BackgroundColor3", C("Surface"))
rim(avatar, 0.4)
local profileName = label(profile, {
	Text = LP.DisplayName,
	Size = 13,
	Weight = W.Medium,
	UDim = UDim2.new(1, -52, 0, 16),
	Position = UDim2.new(0, 50, 0.5, -8),
	Anchor = Vector2.new(0, 0.5),
	Truncate = true,
})
local profileSub = label(profile, {
	Text = "@" .. LP.Name,
	Size = 11,
	Color = MUTED,
	UDim = UDim2.new(1, -52, 0, 14),
	Position = UDim2.new(0, 50, 0.5, 9),
	Anchor = Vector2.new(0, 0.5),
	Truncate = true,
})
task.spawn(function()
	local ok, img = pcall(function()
		return Players:GetUserThumbnailAsync(LP.UserId, Enum.ThumbnailType.HeadShot, Enum.ThumbnailSize.Size100x100)
	end)
	if ok and img and avatar.Parent then
		avatar.Image = img
	end
end)

local content = new("Frame", {
	Name = "Content",
	Size = UDim2.new(1, -196, 1, 0),
	Position = UDim2.fromOffset(196, 0),
	BackgroundTransparency = 1,
	ClipsDescendants = true,
	Parent = body,
})

---------------------------------------------------------------- page system

local pages = {}
local pageHooks = {}
local currentNav

local function makePage(id)
	local p = new("ScrollingFrame", {
		Name = id,
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ScrollBarThickness = 3,
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollingDirection = Enum.ScrollingDirection.Y,
		ElasticBehavior = Enum.ElasticBehavior.Always,
		Visible = false,
		Parent = content,
	})
	bind(p, "ScrollBarImageColor3", C("Text"))
	p.ScrollBarImageTransparency = 0.6
	padding(p, 20, 22, 24, 22)
	list(p, 14)
	pages[id] = p
	return p
end

local function pageHeader(page, title, subtitle)
	local h = new("Frame", { Size = UDim2.new(1, 0, 0, 52), BackgroundTransparency = 1, LayoutOrder = -100, Parent = page })
	label(h, { Text = title, Size = 26, Weight = W.Bold, UDim = UDim2.new(1, 0, 0, 30) })
	label(h, { Text = subtitle, Size = 13, Color = SUB, UDim = UDim2.new(1, 0, 0, 18), Position = UDim2.fromOffset(0, 32) })
	return h
end

local function navigate(id)
	local pageId = id == "favorites" and "library" or id
	local target = pages[pageId]
	if not target then
		return
	end
	local samePage = currentNav and (currentNav == "favorites" and "library" or currentNav) == pageId
	currentNav = id
	for i, n in ipairs(NAV) do
		local nb = navButtons[n.id]
		local active = n.id == id
		tween(nb.icon, 0.25, { TextTransparency = active and 0 or 0.35 })
		tween(nb.text, 0.25, { TextTransparency = active and 0 or 0.35 })
		if active then
			tween(indicator, 0.45, { Position = UDim2.fromOffset(0, (i - 1) * NAV_STEP) }, Enum.EasingStyle.Back)
		end
	end
	addressLbl.Text = "vrya.app/" .. id
	if not samePage then
		for pid, pg in pairs(pages) do
			if pid ~= pageId then
				pg.Visible = false
			end
		end
		target.Visible = true
		target.CanvasPosition = Vector2.zero
		target.Position = UDim2.fromOffset(0, 16)
		tween(target, 0.5, { Position = UDim2.new() })
	end
	if pageHooks[pageId] then
		pageHooks[pageId](id)
	end
end

for i, n in ipairs(NAV) do
	local b = new("TextButton", {
		Name = n.id,
		Size = UDim2.new(1, 0, 0, 38),
		Position = UDim2.fromOffset(0, (i - 1) * NAV_STEP),
		BackgroundTransparency = 1,
		Text = "",
		Parent = navHolder,
	})
	local icon = label(b, {
		Text = n.icon,
		Size = n.icon == "</>" and 11 or 15,
		Weight = W.Bold,
		UDim = UDim2.new(0, 26, 1, 0),
		Position = UDim2.fromOffset(12, 0),
		AlignX = Enum.TextXAlignment.Center,
	})
	icon.TextTransparency = 0.35
	local txt = label(b, {
		Text = n.text,
		Size = 14,
		Weight = W.Medium,
		UDim = UDim2.new(1, -50, 1, 0),
		Position = UDim2.fromOffset(46, 0),
	})
	txt.TextTransparency = 0.35
	pressable(b)
	b.MouseButton1Click:Connect(function()
		navigate(n.id)
	end)
	navButtons[n.id] = { button = b, icon = icon, text = txt }
end

---------------------------------------------------------------- library data

local LIBRARY = {
	{
		id = "tween-playground",
		name = "Tween Playground",
		cat = "Animation",
		desc = "Preview every EasingStyle on a GuiObject, one after another.",
		code = [[local TweenService = game:GetService("TweenService")

-- Plays each easing style on a frame so you can compare them
local function preview(frame: Frame)
	for _, style in Enum.EasingStyle:GetEnumItems() do
		local info = TweenInfo.new(0.6, style, Enum.EasingDirection.Out)
		frame.Position = UDim2.fromScale(0.1, 0.5)
		TweenService:Create(frame, info, { Position = UDim2.fromScale(0.8, 0.5) }):Play()
		task.wait(0.9)
	end
end

return preview]],
	},
	{
		id = "spring",
		name = "Spring Animator",
		cat = "Animation",
		desc = "Critically damped spring for buttery UI motion.",
		code = [[local Spring = {}
Spring.__index = Spring

function Spring.new(target: number, speed: number?)
	return setmetatable({ x = target, v = 0, target = target, speed = speed or 18 }, Spring)
end

function Spring:step(dt: number): number
	local k = self.speed
	local a = k * k * (self.target - self.x) - 2 * k * self.v
	self.v += a * dt
	self.x += self.v * dt
	return self.x
end

return Spring]],
	},
	{
		id = "rainbow-text",
		name = "Rainbow Text",
		cat = "Interface",
		desc = "Cycles a TextLabel through the hue wheel with RichText.",
		code = [[local RunService = game:GetService("RunService")

local function rainbow(label: TextLabel, text: string)
	label.RichText = true
	return RunService.RenderStepped:Connect(function()
		local out, t = {}, os.clock()
		for i = 1, #text do
			local c = Color3.fromHSV((t * 0.2 + i * 0.04) % 1, 0.6, 1)
			out[i] = string.format('<font color="#%s">%s</font>', c:ToHex(), text:sub(i, i))
		end
		label.Text = table.concat(out)
	end)
end

return rainbow]],
	},
	{
		id = "toast",
		name = "Toast Queue",
		cat = "Interface",
		desc = "Tiny queue that shows messages one at a time.",
		code = [[local Toast = { queue = {}, busy = false }

function Toast.push(message: string)
	table.insert(Toast.queue, message)
	if Toast.busy then return end
	Toast.busy = true
	while #Toast.queue > 0 do
		local msg = table.remove(Toast.queue, 1)
		print("[toast]", msg) -- swap for your own label
		task.wait(2.5)
	end
	Toast.busy = false
end

return Toast]],
	},
	{
		id = "signal",
		name = "Signal Class",
		cat = "Utility",
		desc = "Lightweight connect / fire / disconnect event object.",
		code = [[local Signal = {}
Signal.__index = Signal

function Signal.new()
	return setmetatable({ handlers = {} }, Signal)
end

function Signal:Connect(fn)
	self.handlers[fn] = true
	return { Disconnect = function() self.handlers[fn] = nil end }
end

function Signal:Fire(...)
	for fn in self.handlers do
		task.spawn(fn, ...)
	end
end

return Signal]],
	},
	{
		id = "debounce",
		name = "Debounce",
		cat = "Utility",
		desc = "Wraps a function so rapid calls collapse into one.",
		code = [[local function debounce(fn, delay: number)
	local token = 0
	return function(...)
		token += 1
		local mine, args = token, table.pack(...)
		task.delay(delay, function()
			if mine == token then
				fn(table.unpack(args, 1, args.n))
			end
		end)
	end
end

return debounce]],
	},
	{
		id = "format",
		name = "Number Formatter",
		cat = "Utility",
		desc = "1234567 to 1.23M, plus comma grouping.",
		code = [[local SUFFIXES = { "", "K", "M", "B", "T" }

local function short(n: number): string
	local i = 1
	while math.abs(n) >= 1000 and i < #SUFFIXES do
		n /= 1000
		i += 1
	end
	return string.format(i == 1 and "%d" or "%.2f%s", n, SUFFIXES[i])
end

local function commas(n: number): string
	local s = tostring(math.floor(n))
	return (s:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", ""))
end

return { short = short, commas = commas }]],
	},
	{
		id = "pretty",
		name = "Table Printer",
		cat = "Learning",
		desc = "Recursively prints nested tables with indentation.",
		code = [[local function pretty(t, indent: string?)
	indent = indent or ""
	for k, v in t do
		if type(v) == "table" then
			print(indent .. tostring(k) .. " = {")
			pretty(v, indent .. "  ")
			print(indent .. "}")
		else
			print(indent .. tostring(k) .. " = " .. tostring(v))
		end
	end
end

pretty({ name = "Vrya", glass = { blur = 18, opacity = 0.8 } })]],
	},
	{
		id = "types",
		name = "Luau Types 101",
		cat = "Learning",
		desc = "Type annotations, unions and generics in one page.",
		code = [[--!strict
type Theme = {
	name: string,
	accent: Color3,
	glass: number,
}

type Result<T> = { ok: true, value: T } | { ok: false, err: string }

local function load(name: string): Result<Theme>
	if name == "" then
		return { ok = false, err = "empty name" }
	end
	return { ok = true, value = { name = name, accent = Color3.new(1, 1, 1), glass = 0.8 } }
end

print(load("Graphite"))]],
	},
	{
		id = "countdown",
		name = "Countdown Timer",
		cat = "Interface",
		desc = "mm:ss countdown bound to a TextLabel.",
		code = [[local function countdown(label: TextLabel, seconds: number)
	for s = seconds, 0, -1 do
		label.Text = string.format("%02d:%02d", s // 60, s % 60)
		task.wait(1)
	end
	label.Text = "Done"
end

return countdown]],
	},
}
local CATEGORIES = { "All", "Favorites", "Animation", "Interface", "Utility", "Learning", "My Snippets" }

local function allItems()
	local out = {}
	for _, it in ipairs(LIBRARY) do
		out[#out + 1] = it
	end
	for i, sn in ipairs(data.snippets) do
		out[#out + 1] = {
			id = "snippet:" .. tostring(sn.name),
			name = tostring(sn.name),
			cat = "My Snippets",
			desc = "Saved from the editor",
			code = tostring(sn.code or ""),
			snippetIndex = i,
		}
	end
	return out
end

local function countFavorites()
	local n = 0
	for _, v in pairs(data.favorites) do
		if v then
			n += 1
		end
	end
	return n
end

---------------------------------------------------------------- editor (defined early, used by library)

local Editor = {}
local statsDirty = {}

local function markStats()
	for _, fn in ipairs(statsDirty) do
		task.spawn(fn)
	end
end

---------------------------------------------------------------- HOME

local home = makePage("home")
do
	-- hero card echoing the reference: big two-tone wordmark + badges
	local hero = glass(home, { Size = UDim2.new(1, 0, 0, 210), Order = 1, Strength = 0.28, Radius = 22 })
	padding(hero, 22, 24, 20, 26)
	local greet = label(hero, { Text = "", Size = 12, Color = SUB, UDim = UDim2.new(1, 0, 0, 16) })
	label(hero, {
		Text = "Liquid",
		Size = 40,
		Weight = W.Bold,
		Color = MUTED,
		UDim = UDim2.new(1, 0, 0, 44),
		Position = UDim2.fromOffset(0, 22),
	})
	label(hero, {
		Text = "Glass.",
		Size = 40,
		Weight = W.Bold,
		UDim = UDim2.new(1, 0, 0, 44),
		Position = UDim2.fromOffset(0, 62),
	})
	local badges = new("Frame", {
		Size = UDim2.new(1, 0, 0, 22),
		Position = UDim2.new(0, 0, 1, -48),
		BackgroundTransparency = 1,
		Parent = hero,
	})
	list(badges, 8, true)
	for i, txt in ipairs({ "LUAU", "v" .. Vrya.Version, "UI ONLY" }) do
		local bd = new("TextLabel", {
			Size = UDim2.fromOffset(0, 22),
			AutomaticSize = Enum.AutomaticSize.X,
			BackgroundTransparency = 1,
			Text = txt,
			FontFace = Font.new(MONO_FAMILY, W.Bold),
			TextSize = 11,
			LayoutOrder = i,
			Parent = badges,
		})
		bind(bd, "TextColor3", C("Text"))
		padding(bd, 0, 8, 0, 8)
		corner(bd, 5)
		local st = new("UIStroke", { Thickness = 1.2, ApplyStrokeMode = Enum.ApplyStrokeMode.Border, Parent = bd })
		bind(st, "Color", C("Text"))
		st.Transparency = 0.3
	end
	label(hero, {
		Text = "<b>Modular</b> components & editable themes",
		Rich = true,
		Size = 13,
		Color = SUB,
		UDim = UDim2.new(1, 0, 0, 18),
		Position = UDim2.new(0, 0, 1, -18),
	})
	local heroBtns = new("Frame", {
		Size = UDim2.fromOffset(300, 34),
		Position = UDim2.new(1, 0, 0, 0),
		AnchorPoint = Vector2.new(1, 0),
		BackgroundTransparency = 1,
		Parent = hero,
	})
	list(heroBtns, 8, true, Enum.VerticalAlignment.Center, Enum.HorizontalAlignment.Right)
	UI.Button(heroBtns, { Text = "Theme Studio", Order = 2, Callback = function()
		navigate("themes")
	end })
	UI.Button(heroBtns, { Text = "Browse", Style = "primary", Order = 3, Callback = function()
		navigate("library")
	end })
	local function updateGreeting()
		local h = tonumber(os.date("%H")) or 12
		local part = h < 5 and "Good night" or h < 12 and "Good morning" or h < 18 and "Good afternoon" or "Good evening"
		greet.Text = part .. ", " .. LP.DisplayName
	end
	updateGreeting()
	pageHooks.home = updateGreeting

	-- live stat tiles
	UI.Section(home, "Overview", 2)
	local tiles = UI.Grid(home, 140, 86, 12, 3)
	local tileLabels = {}
	local function tile(key, title, order)
		local t = glass(tiles, { Strength = 0.32, Radius = 18, Order = order })
		padding(t, 14, 16, 14, 16)
		label(t, { Text = title, Size = 12, Color = SUB, UDim = UDim2.new(1, 0, 0, 16) })
		tileLabels[key] = label(t, {
			Text = "-",
			Size = 26,
			Weight = W.Bold,
			UDim = UDim2.new(1, 0, 0, 32),
			Position = UDim2.new(0, 0, 1, 0),
			Anchor = Vector2.new(0, 1),
		})
	end
	tile("scripts", "Library", 1)
	tile("favorites", "Favorites", 2)
	tile("themes", "Themes", 3)
	tile("session", "Session", 4)
	tile("fps", "Frame rate", 5)

	table.insert(statsDirty, function()
		tileLabels.scripts.Text = tostring(#allItems())
		tileLabels.favorites.Text = tostring(countFavorites())
		tileLabels.themes.Text = tostring(#PRESETS + #data.customThemes)
	end)

	local started = os.clock()
	local frames, fps = 0, 60
	track(RunService.RenderStepped:Connect(function()
		frames += 1
	end))
	task.spawn(function()
		while alive do
			task.wait(1)
			fps, frames = frames, 0
			local s = math.floor(os.clock() - started)
			if tileLabels.session.Parent then
				tileLabels.session.Text = string.format("%d:%02d", s // 60, s % 60)
				tileLabels.fps.Text = tostring(fps)
			end
			clockLbl.Text = os.date("%H:%M")
		end
	end)

	-- quick actions
	UI.Section(home, "Quick actions", 4)
	local actions = UI.Grid(home, 170, 70, 12, 5)
	local function action(title, sub, order, fn)
		local a = glass(actions, { Class = "TextButton", Strength = 0.3, Radius = 18, Order = order })
		padding(a, 0, 16, 0, 16)
		label(a, { Text = title, Size = 14, Weight = W.SemiBold, UDim = UDim2.new(1, 0, 0, 18), Position = UDim2.new(0, 0, 0.5, -9), Anchor = Vector2.new(0, 0.5) })
		label(a, { Text = sub, Size = 11, Color = SUB, UDim = UDim2.new(1, 0, 0, 14), Position = UDim2.new(0, 0, 0.5, 10), Anchor = Vector2.new(0, 0.5), Truncate = true })
		pressable(a)
		a.MouseButton1Click:Connect(fn)
	end
	action("New snippet", "Open a blank editor", 1, function()
		Editor.Open("untitled.luau", "-- start typing\n", nil)
		navigate("editor")
	end)
	action("Favorites", "Your starred scripts", 2, function()
		navigate("favorites")
	end)
	action("Random preset", "Shuffle the look", 3, function()
		local pick = PRESETS[math.random(1, #PRESETS)]
		Vrya:SetTheme(pick)
		notify("Theme", "Switched to " .. pick.Name)
	end)
	action("Test toast", "Fire a notification", 4, function()
		notify("Hello from Vrya", "Notifications stack, auto-dismiss and close on tap.", 5)
	end)

	-- recently opened
	UI.Section(home, "Recent", 6)
	local recentList = new("Frame", {
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		LayoutOrder = 7,
		Parent = home,
	})
	list(recentList, 8)
	local function renderRecent()
		for _, c in ipairs(recentList:GetChildren()) do
			if not c:IsA("UIListLayout") then
				c:Destroy()
			end
		end
		if #data.recent == 0 then
			label(recentList, { Text = "Nothing opened yet. Pick a script from the Library.", Size = 13, Color = MUTED })
			return
		end
		local items = allItems()
		for i, id in ipairs(data.recent) do
			for _, it in ipairs(items) do
				if it.id == id then
					local row = UI.Row(recentList, { Text = it.name, Desc = it.cat .. "  ·  " .. it.desc, Order = i, RightWidth = 90 })
					UI.Button(row, {
						Text = "Open",
						Size = UDim2.fromOffset(70, 30),
						Position = UDim2.new(1, 0, 0.5, 0),
						Anchor = Vector2.new(1, 0.5),
						Callback = function()
							Editor.Open(it.name, it.code, it.id)
							navigate("editor")
						end,
					})
					break
				end
			end
		end
	end
	table.insert(statsDirty, renderRecent)
end

---------------------------------------------------------------- LIBRARY

local library = makePage("library")
local Library = { filter = "All", query = "" }
do
	local header = pageHeader(library, "Library", "Curated Luau snippets. Open any card in the editor to read it.")

	local search = UI.Input(library, { Placeholder = "Search scripts, categories…", Order = 1, Size = UDim2.new(1, 0, 0, 42), Radius = 21, LeftPad = 40 })
	label(search, {
		Text = "⌕",
		Size = 18,
		Color = MUTED,
		UDim = UDim2.fromOffset(20, 42),
		Position = UDim2.new(0, -26, 0.5, 0),
		Anchor = Vector2.new(0, 0.5),
	})

	local chipBar = new("ScrollingFrame", {
		Size = UDim2.new(1, 0, 0, 34),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ScrollBarThickness = 0,
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.X,
		ScrollingDirection = Enum.ScrollingDirection.X,
		LayoutOrder = 2,
		Parent = library,
	})
	list(chipBar, 8, true, Enum.VerticalAlignment.Center)
	padding(chipBar, 0, 2, 0, 2)

	local grid = UI.Grid(library, 220, 156, 12, 3)
	local empty = label(library, {
		Text = "",
		Size = 13,
		Color = MUTED,
		Order = 4,
		AlignX = Enum.TextXAlignment.Center,
		UDim = UDim2.new(1, 0, 0, 60),
	})

	local chips = {}
	local function setFilter(cat)
		Library.filter = cat
		for c, chip in pairs(chips) do
			chip.Set(c == cat)
		end
		Library.Render()
	end
	for i, cat in ipairs(CATEGORIES) do
		chips[cat] = UI.Chip(chipBar, {
			Text = cat == "Favorites" and "★ Favorites" or cat,
			Active = cat == "All",
			Order = i,
			Callback = function()
				setFilter(cat)
				if currentNav == "favorites" and cat ~= "Favorites" then
					currentNav = "library"
					navigate("library")
				end
			end,
		})
	end

	local function matches(it)
		if Library.filter == "Favorites" then
			if not data.favorites[it.id] then
				return false
			end
		elseif Library.filter ~= "All" and it.cat ~= Library.filter then
			return false
		end
		local q = Library.query
		if q == "" then
			return true
		end
		local hay = string.lower(it.name .. " " .. it.desc .. " " .. it.cat)
		return hay:find(q, 1, true) ~= nil
	end

	local function card(it, order)
		local cardF = glass(grid, { Strength = 0.3, Radius = 18, Order = order })
		padding(cardF, 14, 14, 14, 16)
		local tag = new("TextLabel", {
			Size = UDim2.fromOffset(0, 20),
			AutomaticSize = Enum.AutomaticSize.X,
			Text = string.upper(it.cat),
			FontFace = font(W.SemiBold),
			TextSize = 10,
			BorderSizePixel = 0,
			Parent = cardF,
		})
		corner(tag, ROUND)
		padding(tag, 0, 8, 0, 8)
		bind(tag, "BackgroundColor3", C("Accent"))
		tag.BackgroundTransparency = 0.82
		bind(tag, "TextColor3", C("Text"))

		local fav = data.favorites[it.id] == true
		local star = UI.IconButton(cardF, {
			Text = fav and "★" or "☆",
			Px = 28,
			TextSize = 15,
			Position = UDim2.new(1, 0, 0, -4),
			Anchor = Vector2.new(1, 0),
			Color = function(t)
				return t.Accent
			end,
		})
		star.MouseButton1Click:Connect(function()
			fav = not fav
			data.favorites[it.id] = fav or nil
			save()
			star.Text = fav and "★" or "☆"
			local sc = star:FindFirstChildOfClass("UIScale")
			if sc then
				sc.Scale = 1.35
				tween(sc, 0.45, { Scale = 1 }, Enum.EasingStyle.Back)
			end
			markStats()
			if Library.filter == "Favorites" and not fav then
				task.delay(0.25, Library.Render)
			end
		end)

		label(cardF, {
			Text = it.name,
			Size = 16,
			Weight = W.SemiBold,
			UDim = UDim2.new(1, 0, 0, 20),
			Position = UDim2.fromOffset(0, 30),
			Truncate = true,
		})
		label(cardF, {
			Text = it.desc,
			Size = 12,
			Color = SUB,
			Wrap = true,
			AlignY = Enum.TextYAlignment.Top,
			UDim = UDim2.new(1, 0, 0, 32),
			Position = UDim2.fromOffset(0, 54),
		})
		local _, lines = it.code:gsub("\n", "")
		label(cardF, {
			Text = tostring(lines + 1) .. " lines",
			Size = 11,
			Color = MUTED,
			Font = Font.new(MONO_FAMILY),
			UDim = UDim2.new(0.5, 0, 0, 30),
			Position = UDim2.new(0, 0, 1, 0),
			Anchor = Vector2.new(0, 1),
		})
		local btnRow = new("Frame", {
			Size = UDim2.new(0.7, 0, 0, 30),
			Position = UDim2.new(1, 0, 1, 0),
			AnchorPoint = Vector2.new(1, 1),
			BackgroundTransparency = 1,
			Parent = cardF,
		})
		list(btnRow, 6, true, Enum.VerticalAlignment.Center, Enum.HorizontalAlignment.Right)
		if it.snippetIndex then
			UI.Button(btnRow, {
				Text = "Delete",
				Style = "danger",
				Size = UDim2.fromOffset(70, 30),
				Order = 1,
				Callback = function()
					table.remove(data.snippets, it.snippetIndex)
					data.favorites[it.id] = nil
					save()
					notify("Snippet deleted", it.name)
					Library.Render()
					markStats()
				end,
			})
		end
		UI.Button(btnRow, {
			Text = "Open",
			Style = "primary",
			Size = UDim2.fromOffset(70, 30),
			Order = 2,
			Callback = function()
				Editor.Open(it.name, it.code, it.id)
				navigate("editor")
			end,
		})

		-- hover lift
		local st = cardF:FindFirstChildOfClass("UIStroke")
		cardF.MouseEnter:Connect(function()
			if st then
				tween(st, 0.2, { Transparency = 0.2 })
			end
		end)
		cardF.MouseLeave:Connect(function()
			if st then
				tween(st, 0.3, { Transparency = 0.55 })
			end
		end)
		return cardF
	end

	function Library.Render()
		for _, c in ipairs(grid:GetChildren()) do
			if not c:IsA("UIGridLayout") then
				c:Destroy()
			end
		end
		local n = 0
		for _, it in ipairs(allItems()) do
			if matches(it) then
				n += 1
				card(it, n)
			end
		end
		if n == 0 then
			empty.Text = Library.filter == "Favorites" and "No favorites yet. Tap ☆ on any card to star it."
				or Library.filter == "My Snippets" and "No snippets yet. Save one from the Editor."
				or ("No results for \"" .. Library.query .. "\"")
			empty.Visible = true
		else
			empty.Visible = false
		end
	end

	local searchQueued = false
	search:GetPropertyChangedSignal("Text"):Connect(function()
		Library.query = string.lower(search.Text)
		if searchQueued then
			return
		end
		searchQueued = true
		task.delay(0.12, function()
			searchQueued = false
			Library.Render()
		end)
	end)

	pageHooks.library = function(navId)
		local want = navId == "favorites" and "Favorites" or (Library.filter == "Favorites" and "All" or Library.filter)
		header:FindFirstChildOfClass("TextLabel").Text = navId == "favorites" and "Favorites" or "Library"
		setFilter(want)
	end
	Library.SetFilter = setFilter
	Library.Render()
end

---------------------------------------------------------------- EDITOR

local editorPage = makePage("editor")
do
	local KEYWORDS = {}
	for _, k in ipairs({
		"and", "break", "do", "else", "elseif", "end", "false", "for", "function", "if", "in", "local",
		"nil", "not", "or", "repeat", "return", "then", "true", "until", "while", "continue", "type", "export",
	}) do
		KEYWORDS[k] = true
	end
	local BUILTINS = {}
	for _, k in ipairs({
		"game", "workspace", "script", "print", "warn", "error", "task", "math", "string", "table", "Instance",
		"Vector2", "Vector3", "Color3", "UDim", "UDim2", "TweenInfo", "Enum", "pairs", "ipairs", "typeof",
		"tostring", "tonumber", "require", "self", "setmetatable", "getmetatable", "os", "select", "pcall",
		"ColorSequence", "NumberSequence", "CFrame",
	}) do
		BUILTINS[k] = true
	end

	local function esc(s)
		return (s:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"))
	end

	-- Single-pass Luau tokenizer that emits RichText color tags.
	local function highlight(src, pal)
		local out = {}
		local i, n = 1, #src
		local function push(color, s)
			if color then
				out[#out + 1] = '<font color="' .. color .. '">' .. esc(s) .. "</font>"
			else
				out[#out + 1] = esc(s)
			end
		end
		while i <= n do
			local c = src:sub(i, i)
			if c == "-" and src:sub(i + 1, i + 1) == "-" then
				local j = src:find("\n", i, true) or (n + 1)
				push(pal.comment, src:sub(i, j - 1))
				i = j
			elseif c == '"' or c == "'" or c == "`" then
				local j = i + 1
				while j <= n do
					local d = src:sub(j, j)
					if d == "\\" then
						j += 2
					elseif d == c or d == "\n" then
						break
					else
						j += 1
					end
				end
				local stop = math.min(j, n)
				if src:sub(stop, stop) == "\n" then
					stop -= 1
				end
				push(pal.string, src:sub(i, stop))
				i = stop + 1
			elseif c == "[" and src:sub(i, i + 1) == "[[" then
				local _, e = src:find("]]", i + 2, true)
				e = e or n
				push(pal.string, src:sub(i, e))
				i = e + 1
			elseif c:match("%d") then
				local _, e = src:find("^[%w%.]+", i)
				push(pal.number, src:sub(i, e))
				i = e + 1
			elseif c:match("[%a_]") then
				local _, e = src:find("^[%w_]+", i)
				local word = src:sub(i, e)
				local nextChar = src:sub(e + 1, e + 1)
				if KEYWORDS[word] then
					push(pal.keyword, word)
				elseif BUILTINS[word] then
					push(pal.builtin, word)
				elseif nextChar == "(" then
					push(pal.call, word)
				else
					push(nil, word)
				end
				i = e + 1
			else
				local _, e = src:find("^[^%w_\"'`%-%[]+", i)
				e = e or i
				push(pal.symbol, src:sub(i, e))
				i = e + 1
			end
		end
		return table.concat(out)
	end

	local function palette(t)
		return {
			keyword = toHex(t.Accent:Lerp(Color3.fromRGB(255, 122, 168), 0.45)),
			builtin = toHex(t.Accent:Lerp(Color3.fromRGB(120, 200, 255), 0.6)),
			call = toHex(Color3.fromRGB(130, 170, 255):Lerp(t.Text, 0.25)),
			string = toHex(Color3.fromRGB(152, 222, 140):Lerp(t.Text, 0.15)),
			number = toHex(Color3.fromRGB(255, 190, 110):Lerp(t.Text, 0.15)),
			comment = toHex(t.Text:Lerp(t.Background, 0.55)),
			symbol = toHex(t.Text:Lerp(t.Background, 0.3)),
		}
	end

	pageHeader(editorPage, "Editor", "Read and write Luau with live highlighting. Code is never executed.")

	-- file bar
	local bar = new("Frame", { Size = UDim2.new(1, 0, 0, 38), BackgroundTransparency = 1, LayoutOrder = 1, Parent = editorPage })
	local nameBox = UI.Input(bar, {
		Text = "untitled.luau",
		Size = UDim2.new(1, -250, 1, 0),
		Mono = true,
		Radius = 19,
	})
	local btns = new("Frame", {
		Size = UDim2.new(0, 240, 1, 0),
		Position = UDim2.new(1, 0, 0, 0),
		AnchorPoint = Vector2.new(1, 0),
		BackgroundTransparency = 1,
		Parent = bar,
	})
	list(btns, 6, true, Enum.VerticalAlignment.Center, Enum.HorizontalAlignment.Right)

	-- code surface
	local surface = glass(editorPage, { Size = UDim2.new(1, 0, 0, 300), Order = 2, Strength = 0.5, Tint = "Background", Radius = 18, Clip = true })
	local gutter = new("TextLabel", {
		Size = UDim2.new(0, 40, 1, 0),
		BackgroundTransparency = 1,
		FontFace = Font.new(MONO_FAMILY),
		TextSize = 13,
		TextXAlignment = Enum.TextXAlignment.Right,
		TextYAlignment = Enum.TextYAlignment.Top,
		Text = "1",
		Parent = surface,
	})
	bind(gutter, "TextColor3", MUTED)
	padding(gutter, 12, 8, 0, 0)
	local gline = new("Frame", { Size = UDim2.new(0, 1, 1, 0), Position = UDim2.fromOffset(46, 0), BorderSizePixel = 0, Parent = surface })
	bind(gline, "BackgroundColor3", C("Border"))
	gline.BackgroundTransparency = 0.85

	local scroller = new("ScrollingFrame", {
		Size = UDim2.new(1, -52, 1, 0),
		Position = UDim2.fromOffset(52, 0),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ScrollBarThickness = 4,
		CanvasSize = UDim2.new(),
		ScrollingDirection = Enum.ScrollingDirection.XY,
		Parent = surface,
	})
	bind(scroller, "ScrollBarImageColor3", C("Text"))
	scroller.ScrollBarImageTransparency = 0.6

	local codeBox = new("TextBox", {
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		MultiLine = true,
		ClearTextOnFocus = false,
		TextWrapped = false,
		FontFace = Font.new(MONO_FAMILY),
		TextSize = 13,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
		Text = "",
		Parent = scroller,
	})
	bind(codeBox, "TextColor3", C("Text"))
	padding(codeBox, 12, 12, 12, 8)
	-- highlighted copy drawn over the box; input passes through to the TextBox underneath
	local hl = new("TextLabel", {
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		RichText = true,
		FontFace = Font.new(MONO_FAMILY),
		TextSize = 13,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
		Text = "",
		Active = false,
		Parent = scroller,
	})
	pcall(function()
		hl.Interactable = false
	end)
	bind(hl, "TextColor3", C("Text"))
	padding(hl, 12, 12, 12, 8)

	local status = label(editorPage, { Text = "", Size = 12, Color = MUTED, Order = 3, Font = Font.new(MONO_FAMILY) })

	local currentId
	local function refresh()
		local text = codeBox.Text
		hl.Text = highlight(text, palette(T))
		local _, lines = text:gsub("\n", "")
		lines += 1
		local nums = table.create(lines)
		for i = 1, lines do
			nums[i] = tostring(i)
		end
		gutter.Text = table.concat(nums, "\n")
		-- grow the canvas to fit the text so long files scroll both ways
		local tb = codeBox.TextBounds
		local w = math.max(scroller.AbsoluteSize.X / math.max(currentScale, 0.01), tb.X + 40)
		local h = math.max(scroller.AbsoluteSize.Y / math.max(currentScale, 0.01), tb.Y + 40)
		codeBox.Size = UDim2.fromOffset(w, h)
		hl.Size = codeBox.Size
		scroller.CanvasSize = UDim2.fromOffset(w, h)
		status.Text = string.format("%d lines  ·  %d chars  ·  Luau  ·  preview only", lines, #text)
	end
	-- keep the gutter aligned with the scrolled code
	scroller:GetPropertyChangedSignal("CanvasPosition"):Connect(function()
		gutter.Position = UDim2.fromOffset(0, -scroller.CanvasPosition.Y / math.max(currentScale, 0.01))
	end)

	local queued = false
	codeBox:GetPropertyChangedSignal("Text"):Connect(function()
		if queued then
			return
		end
		queued = true
		task.defer(function()
			queued = false
			refresh()
		end)
	end)
	table.insert(themeListeners, function()
		refresh()
	end)

	function Editor.Open(name, code, id)
		nameBox.Text = name
		codeBox.Text = code
		currentId = id
		if id then
			for i = #data.recent, 1, -1 do
				if data.recent[i] == id then
					table.remove(data.recent, i)
				end
			end
			table.insert(data.recent, 1, id)
			while #data.recent > 5 do
				table.remove(data.recent)
			end
			save()
			markStats()
		end
		refresh()
	end

	UI.Button(btns, { Text = "New", Order = 1, Callback = function()
		Editor.Open("untitled.luau", "", nil)
	end })
	UI.Button(btns, { Text = "Select all", Order = 2, Callback = function()
		codeBox:CaptureFocus()
		codeBox.SelectionStart = 1
		codeBox.CursorPosition = #codeBox.Text + 1
		if typeof(setclipboard) == "function" then
			pcall(setclipboard, codeBox.Text)
			notify("Copied", "Code copied to your clipboard.")
		else
			notify("Selected", "Press Ctrl+C to copy the code.")
		end
	end })
	UI.Button(btns, { Text = "Save", Style = "primary", Order = 3, Callback = function()
		local name = nameBox.Text:gsub("^%s+", ""):gsub("%s+$", "")
		if name == "" then
			notify("Name needed", "Give the snippet a file name first.")
			return
		end
		local found = false
		for _, sn in ipairs(data.snippets) do
			if sn.name == name then
				sn.code = codeBox.Text
				found = true
			end
		end
		if not found then
			table.insert(data.snippets, { name = name, code = codeBox.Text })
		end
		currentId = "snippet:" .. name
		save()
		markStats()
		Library.Render()
		notify(found and "Snippet updated" or "Snippet saved", name .. " is in Library › My Snippets.")
	end })

	-- fit the surface to the remaining page height
	local function fit()
		local h = editorPage.AbsoluteSize.Y / math.max(currentScale, 0.01)
		surface.Size = UDim2.new(1, 0, 0, math.max(200, h - 20 - 52 - 38 - 18 - 14 * 3 - 24))
		task.defer(refresh)
	end
	editorPage:GetPropertyChangedSignal("AbsoluteSize"):Connect(fit)
	task.defer(fit)

	Editor.Open(LIBRARY[1].name, LIBRARY[1].code, nil)
end

---------------------------------------------------------------- forward declarations for window controls

local computeLayout, updateBlur, collapse, expand
local isTouchOnly = UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled

---------------------------------------------------------------- THEMES (studio)

local themesPage = makePage("themes")
local Studio = {}

function Vrya:SetTheme(d)
	T = themeFromData(d)
	applyTheme(false)
	persistTheme()
end

function Vrya:GetTheme()
	return themeToData(T)
end

do
	pageHeader(themesPage, "Themes", "Presets, custom palettes and glass physics. Every change previews live.")

	local function markEdited()
		if not T.Name:find("edited", 1, true) then
			T.Name = T.Name .. " · edited"
		end
	end

	-- live preview: everything inside is bound to the theme, so it repaints while you edit
	UI.Section(themesPage, "Live preview", 1)
	local prev = glass(themesPage, { Size = UDim2.new(1, 0, 0, 150), Order = 2, Strength = 0.25, Radius = 20 })
	padding(prev, 14)
	local mini = new("Frame", { Size = UDim2.new(0.55, -8, 1, 0), BorderSizePixel = 0, Parent = prev })
	corner(mini, 14)
	bind(mini, "BackgroundColor3", function(t)
		return t.Surface:Lerp(t.Background, 0.55)
	end)
	bind(mini, "BackgroundTransparency", function(t)
		return 1 - t.Glass
	end)
	rim(mini, 0.35)
	sheen(mini, 14)
	for i, col in ipairs({ Color3.fromRGB(255, 95, 87), Color3.fromRGB(254, 188, 46), Color3.fromRGB(40, 200, 64) }) do
		local d = new("Frame", { Size = UDim2.fromOffset(8, 8), Position = UDim2.fromOffset(10 + (i - 1) * 13, 10), BackgroundColor3 = col, BorderSizePixel = 0, Parent = mini })
		corner(d, ROUND)
	end
	label(mini, { Text = "Preview", Size = 16, Weight = W.Bold, UDim = UDim2.new(1, -24, 0, 20), Position = UDim2.fromOffset(12, 28) })
	label(mini, { Text = "Glass, text and accents update as you drag.", Size = 11, Color = SUB, UDim = UDim2.new(1, -24, 0, 14), Position = UDim2.fromOffset(12, 50), Truncate = true })
	local pbar = new("Frame", { Size = UDim2.new(1, -24, 0, 4), Position = UDim2.fromOffset(12, 74), BorderSizePixel = 0, Parent = mini })
	corner(pbar, ROUND)
	bind(pbar, "BackgroundColor3", C("Text"))
	pbar.BackgroundTransparency = 0.85
	local pfill = new("Frame", { Size = UDim2.fromScale(0.62, 1), BorderSizePixel = 0, Parent = pbar })
	corner(pfill, ROUND)
	bind(pfill, "BackgroundColor3", C("Accent"))
	local pbtn = new("TextLabel", {
		Size = UDim2.fromOffset(74, 24),
		Position = UDim2.new(0, 12, 1, -10),
		AnchorPoint = Vector2.new(0, 1),
		Text = "Action",
		FontFace = font(W.Medium),
		TextSize = 11,
		BorderSizePixel = 0,
		Parent = mini,
	})
	corner(pbtn, ROUND)
	bind(pbtn, "BackgroundColor3", C("Accent"))
	bind(pbtn, "TextColor3", ON_ACCENT)
	local ptog = new("Frame", { Size = UDim2.fromOffset(36, 22), Position = UDim2.new(1, -12, 1, -11), AnchorPoint = Vector2.new(1, 1), BorderSizePixel = 0, Parent = mini })
	corner(ptog, ROUND)
	bind(ptog, "BackgroundColor3", C("Accent"))
	local pknob = new("Frame", { Size = UDim2.fromOffset(18, 18), Position = UDim2.new(1, -2, 0.5, 0), AnchorPoint = Vector2.new(1, 0.5), BackgroundColor3 = WHITE, BorderSizePixel = 0, Parent = ptog })
	corner(pknob, ROUND)

	local swatches = new("Frame", { Size = UDim2.new(0.45, -8, 1, 0), Position = UDim2.new(1, 0, 0, 0), AnchorPoint = Vector2.new(1, 0), BackgroundTransparency = 1, Parent = prev })
	list(swatches, 4)
	local themeNameLbl = label(swatches, { Text = T.Name, Size = 13, Weight = W.SemiBold, Truncate = true, Order = 0 })
	for i, key in ipairs(COLOR_KEYS) do
		local row = new("Frame", { Size = UDim2.new(1, 0, 0, 18), BackgroundTransparency = 1, LayoutOrder = i, Parent = swatches })
		local sw = new("Frame", { Size = UDim2.fromOffset(14, 14), Position = UDim2.new(0, 0, 0.5, 0), AnchorPoint = Vector2.new(0, 0.5), BorderSizePixel = 0, Parent = row })
		corner(sw, 4)
		bind(sw, "BackgroundColor3", C(key))
		new("UIStroke", { Thickness = 1, Color = WHITE, Transparency = 0.7, Parent = sw })
		label(row, { Text = key, Size = 11, Color = SUB, UDim = UDim2.new(0.5, 0, 1, 0), Position = UDim2.fromOffset(22, 0) })
		local hx = label(row, { Text = "", Size = 11, Font = Font.new(MONO_FAMILY), UDim = UDim2.new(0.5, -22, 1, 0), Position = UDim2.new(1, 0, 0, 0), Anchor = Vector2.new(1, 0), AlignX = Enum.TextXAlignment.Right })
		bind(hx, "Text", function(t)
			return toHex(t[key])
		end)
	end

	-- presets
	UI.Section(themesPage, "Presets", 3)
	local presetGrid = UI.Grid(themesPage, 150, 112, 12, 4)
	local presetCards = {}
	local function miniCard(parent, d, order)
		local th = themeFromData(d)
		local card = new("TextButton", {
			Text = "",
			AutoButtonColor = false,
			BackgroundColor3 = th.Background,
			BorderSizePixel = 0,
			LayoutOrder = order,
			Parent = parent,
		})
		corner(card, 16)
		local st = new("UIStroke", { Thickness = 1, Color = th.Border, Transparency = 0.6, ApplyStrokeMode = Enum.ApplyStrokeMode.Border, Parent = card })
		local w = new("Frame", {
			Size = UDim2.new(1, -20, 0, 54),
			Position = UDim2.fromOffset(10, 10),
			BackgroundColor3 = th.Surface:Lerp(th.Background, 0.4),
			BackgroundTransparency = 1 - th.Glass,
			BorderSizePixel = 0,
			Parent = card,
		})
		corner(w, 10)
		new("UIStroke", { Thickness = 1, Color = th.Border, Transparency = 0.6, Parent = w })
		local g = new("Frame", { Size = UDim2.fromScale(1, 1), BackgroundColor3 = WHITE, BorderSizePixel = 0, Parent = w })
		corner(g, 10)
		new("UIGradient", { Rotation = 28, Transparency = NS(0, 1 - 0.15 * th.Reflection, 0.5, 1, 1, 1), Parent = g })
		local bar1 = new("Frame", { Size = UDim2.new(0.5, 0, 0, 6), Position = UDim2.fromOffset(10, 14), BackgroundColor3 = th.Text, BorderSizePixel = 0, Parent = w })
		corner(bar1, ROUND)
		local bar2 = new("Frame", { Size = UDim2.new(0.32, 0, 0, 5), Position = UDim2.fromOffset(10, 26), BackgroundColor3 = th.Text, BackgroundTransparency = 0.55, BorderSizePixel = 0, Parent = w })
		corner(bar2, ROUND)
		local acc = new("Frame", { Size = UDim2.fromOffset(26, 12), Position = UDim2.new(1, -10, 1, -9), AnchorPoint = Vector2.new(1, 1), BackgroundColor3 = th.Accent, BorderSizePixel = 0, Parent = w })
		corner(acc, ROUND)
		new("TextLabel", {
			Size = UDim2.new(1, -20, 0, 18),
			Position = UDim2.new(0, 12, 1, -12),
			AnchorPoint = Vector2.new(0, 1),
			BackgroundTransparency = 1,
			Text = th.Name,
			TextColor3 = th.Text,
			FontFace = font(W.SemiBold),
			TextSize = 13,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextTruncate = Enum.TextTruncate.AtEnd,
			Parent = card,
		})
		pressable(card)
		return card, st
	end

	local function refreshPresetRings()
		for _, pc in ipairs(presetCards) do
			local active = pc.name == T.Name
			tween(pc.stroke, 0.25, { Thickness = active and 2 or 1, Transparency = active and 0 or 0.6, Color = active and T.Accent or pc.border })
		end
	end

	for i, d in ipairs(PRESETS) do
		local card, st = miniCard(presetGrid, d, i)
		presetCards[i] = { name = d.Name, stroke = st, border = fromHex(d.Border) }
		card.MouseButton1Click:Connect(function()
			Vrya:SetTheme(d)
			notify("Theme applied", d.Name)
		end)
	end

	-- customize
	UI.Section(themesPage, "Customize", 5)
	local targetBar = new("Frame", { Size = UDim2.new(1, 0, 0, 30), BackgroundTransparency = 1, LayoutOrder = 6, Parent = themesPage })
	list(targetBar, 8, true, Enum.VerticalAlignment.Center)

	local target = "Accent"
	local h, s, v = T[target]:ToHSV()
	local pickerDragging = false

	local panel = glass(themesPage, { Size = UDim2.new(1, 0, 0, 200), Order = 7, Strength = 0.3, Radius = 18 })
	padding(panel, 16)
	local SVW, SVH = 168, 168
	local sv = new("Frame", { Size = UDim2.fromOffset(SVW, SVH), BorderSizePixel = 0, Parent = panel })
	corner(sv, 12)
	local whiteOv = new("Frame", { Size = UDim2.fromScale(1, 1), BackgroundColor3 = WHITE, BorderSizePixel = 0, Parent = sv })
	corner(whiteOv, 12)
	new("UIGradient", { Transparency = NS(0, 0, 1, 1), Parent = whiteOv })
	local blackOv = new("Frame", { Size = UDim2.fromScale(1, 1), BackgroundColor3 = BLACK, BorderSizePixel = 0, Parent = sv })
	corner(blackOv, 12)
	new("UIGradient", { Rotation = 90, Transparency = NS(0, 1, 1, 0), Parent = blackOv })
	local svCursor = new("Frame", { Size = UDim2.fromOffset(16, 16), AnchorPoint = Vector2.new(0.5, 0.5), BackgroundTransparency = 1, Parent = sv })
	corner(svCursor, ROUND)
	new("UIStroke", { Thickness = 2.5, Color = WHITE, Parent = svCursor })

	local hueBar = new("Frame", { Size = UDim2.fromOffset(16, SVH), Position = UDim2.fromOffset(SVW + 12, 0), BackgroundColor3 = WHITE, BorderSizePixel = 0, Parent = panel })
	corner(hueBar, ROUND)
	local hueKeys = {}
	for i = 0, 6 do
		hueKeys[#hueKeys + 1] = ColorSequenceKeypoint.new(i / 6, Color3.fromHSV((i / 6) % 1, 1, 1))
	end
	new("UIGradient", { Rotation = 90, Color = ColorSequence.new(hueKeys), Parent = hueBar })
	local hueCursor = new("Frame", { Size = UDim2.fromOffset(22, 8), AnchorPoint = Vector2.new(0.5, 0.5), BackgroundColor3 = WHITE, BorderSizePixel = 0, Parent = hueBar })
	corner(hueCursor, ROUND)
	new("UIStroke", { Thickness = 1, Color = BLACK, Transparency = 0.6, Parent = hueCursor })

	local info = new("Frame", {
		Size = UDim2.new(1, -(SVW + 44), 1, 0),
		Position = UDim2.fromOffset(SVW + 44, 0),
		BackgroundTransparency = 1,
		Parent = panel,
	})
	local editingLbl = label(info, { Text = "", Size = 12, Color = SUB, UDim = UDim2.new(1, 0, 0, 16) })
	local swatch = new("Frame", { Size = UDim2.new(1, 0, 0, 46), Position = UDim2.fromOffset(0, 22), BorderSizePixel = 0, Parent = info })
	corner(swatch, 12)
	rim(swatch, 0.4)
	local hexBox = UI.Input(info, { Size = UDim2.new(1, 0, 0, 34), Position = UDim2.fromOffset(0, 78), Mono = true, Placeholder = "#RRGGBB" })
	local rgbRow = new("Frame", { Size = UDim2.new(1, 0, 0, 34), Position = UDim2.fromOffset(0, 120), BackgroundTransparency = 1, Parent = info })
	local rgbBoxes = {}
	for i, ch in ipairs({ "R", "G", "B" }) do
		rgbBoxes[i] = UI.Input(rgbRow, {
			Size = UDim2.new(1 / 3, -6, 1, 0),
			Position = UDim2.new((i - 1) / 3, (i - 1) * 3, 0, 0),
			Mono = true,
			Placeholder = ch,
			LeftPad = 10,
		})
	end
	label(info, { Text = "HEX or RGB · press Enter to apply", Size = 10, Color = MUTED, UDim = UDim2.new(1, 0, 0, 14), Position = UDim2.fromOffset(0, 158), Truncate = true })

	local function syncFields(c)
		hexBox.Text = toHex(c)
		local r, g, b = rgbOf(c)
		rgbBoxes[1].Text, rgbBoxes[2].Text, rgbBoxes[3].Text = tostring(r), tostring(g), tostring(b)
	end
	local function syncVisuals()
		sv.BackgroundColor3 = Color3.fromHSV(h, 1, 1)
		svCursor.Position = UDim2.fromScale(s, 1 - v)
		hueCursor.Position = UDim2.fromScale(0.5, h)
		swatch.BackgroundColor3 = Color3.fromHSV(h, s, v)
	end
	local function loadTarget()
		local c = T[target]
		h, s, v = c:ToHSV()
		editingLbl.Text = "Editing  " .. target
		syncVisuals()
		syncFields(c)
	end
	local function pushColor(final)
		local c = Color3.fromHSV(h, s, v)
		T[target] = c
		markEdited()
		swatch.BackgroundColor3 = c
		syncFields(c)
		queueThemeInstant()
		if final then
			persistTheme()
		end
	end
	local function setFromColor(c)
		h, s, v = c:ToHSV()
		syncVisuals()
		pushColor(true)
	end

	onDrag(sv, function(pos)
		s = math.clamp((pos.X - sv.AbsolutePosition.X) / math.max(sv.AbsoluteSize.X, 1), 0, 1)
		v = 1 - math.clamp((pos.Y - sv.AbsolutePosition.Y) / math.max(sv.AbsoluteSize.Y, 1), 0, 1)
		syncVisuals()
		pushColor(false)
	end, function()
		pickerDragging = false
		persistTheme()
	end, function()
		pickerDragging = true
	end)
	onDrag(hueBar, function(pos)
		h = math.clamp((pos.Y - hueBar.AbsolutePosition.Y) / math.max(hueBar.AbsoluteSize.Y, 1), 0, 0.999)
		syncVisuals()
		pushColor(false)
	end, function()
		pickerDragging = false
		persistTheme()
	end, function()
		pickerDragging = true
	end)

	hexBox.FocusLost:Connect(function()
		local c = fromHex(hexBox.Text)
		if c then
			setFromColor(c)
		else
			syncFields(T[target])
			notify("Invalid HEX", "Use #RRGGBB, for example #6E95FF.")
		end
	end)
	for _, box in ipairs(rgbBoxes) do
		box.FocusLost:Connect(function()
			local r, g, b = tonumber(rgbBoxes[1].Text), tonumber(rgbBoxes[2].Text), tonumber(rgbBoxes[3].Text)
			if r and g and b then
				setFromColor(Color3.fromRGB(math.clamp(r, 0, 255), math.clamp(g, 0, 255), math.clamp(b, 0, 255)))
			else
				syncFields(T[target])
				notify("Invalid RGB", "Each channel must be a number from 0 to 255.")
			end
		end)
	end

	local targetChips = {}
	for i, key in ipairs(COLOR_KEYS) do
		targetChips[key] = UI.Chip(targetBar, {
			Text = key,
			Active = key == target,
			Order = i,
			Callback = function()
				target = key
				for k, chip in pairs(targetChips) do
					chip.Set(k == key)
				end
				loadTarget()
			end,
		})
	end

	-- glass physics
	local glassSlider = UI.Slider(themesPage, {
		Text = "Glass opacity",
		Min = 20,
		Max = 100,
		Value = math.floor(T.Glass * 100 + 0.5),
		Suffix = "%",
		Order = 8,
		Callback = function(x)
			T.Glass = x / 100
			markEdited()
			queueThemeInstant()
		end,
		Released = persistTheme,
	})
	local blurSlider = UI.Slider(themesPage, {
		Text = "Background blur",
		Min = 0,
		Max = 56,
		Value = math.floor(T.Blur + 0.5),
		Suffix = " px",
		Order = 9,
		Callback = function(x)
			T.Blur = x
			markEdited()
			updateBlur()
		end,
		Released = persistTheme,
	})
	local reflSlider = UI.Slider(themesPage, {
		Text = "Reflections",
		Min = 0,
		Max = 100,
		Value = math.floor(T.Reflection * 100 + 0.5),
		Suffix = "%",
		Order = 10,
		Callback = function(x)
			T.Reflection = x / 100
			markEdited()
			queueThemeInstant()
		end,
		Released = persistTheme,
	})

	-- saved custom themes
	UI.Section(themesPage, "Your themes", 11)
	local saveRow = new("Frame", { Size = UDim2.new(1, 0, 0, 38), BackgroundTransparency = 1, LayoutOrder = 12, Parent = themesPage })
	local nameBox = UI.Input(saveRow, { Size = UDim2.new(1, -100, 1, 0), Placeholder = "Theme name", Radius = 19 })
	local customList = new("Frame", { Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, BackgroundTransparency = 1, LayoutOrder = 13, Parent = themesPage })
	list(customList, 8)

	local function renderCustom()
		for _, c in ipairs(customList:GetChildren()) do
			if not c:IsA("UIListLayout") then
				c:Destroy()
			end
		end
		if #data.customThemes == 0 then
			label(customList, { Text = "No custom themes yet. Tweak the colors above, name it and press Save.", Size = 12, Color = MUTED, Wrap = true, UDim = UDim2.new(1, 0, 0, 32) })
			return
		end
		for i, d in ipairs(data.customThemes) do
			local row = UI.Row(customList, { Text = tostring(d.Name), Desc = string.format("%s · %s · glass %d%%", tostring(d.Accent), tostring(d.Background), math.floor((tonumber(d.Glass) or 0.8) * 100)), Order = i, RightWidth = 230 })
			local dots = new("Frame", { Size = UDim2.fromOffset(70, 14), Position = UDim2.new(1, -160, 0.5, 0), AnchorPoint = Vector2.new(1, 0.5), BackgroundTransparency = 1, Parent = row })
			list(dots, -4, true, Enum.VerticalAlignment.Center)
			for j, key in ipairs(COLOR_KEYS) do
				local dot = new("Frame", { Size = UDim2.fromOffset(14, 14), BackgroundColor3 = fromHex(d[key]) or WHITE, BorderSizePixel = 0, LayoutOrder = j, Parent = dots })
				corner(dot, ROUND)
				new("UIStroke", { Thickness = 1.5, Color = BLACK, Transparency = 0.5, Parent = dot })
			end
			local btns = new("Frame", { Size = UDim2.fromOffset(150, 30), Position = UDim2.new(1, 0, 0.5, 0), AnchorPoint = Vector2.new(1, 0.5), BackgroundTransparency = 1, Parent = row })
			list(btns, 6, true, Enum.VerticalAlignment.Center, Enum.HorizontalAlignment.Right)
			UI.Button(btns, { Text = "Delete", Style = "danger", Size = UDim2.fromOffset(68, 30), Order = 1, Callback = function()
				table.remove(data.customThemes, i)
				save()
				renderCustom()
				markStats()
				notify("Theme deleted", tostring(d.Name))
			end })
			UI.Button(btns, { Text = "Edit", Style = "primary", Size = UDim2.fromOffset(60, 30), Order = 2, Callback = function()
				Vrya:SetTheme(d)
				nameBox.Text = tostring(d.Name)
				notify("Editing theme", tostring(d.Name) .. " is applied. Change it, then Save to overwrite.")
			end })
		end
	end

	UI.Button(saveRow, {
		Text = "Save",
		Style = "primary",
		Size = UDim2.fromOffset(90, 38),
		Position = UDim2.new(1, 0, 0, 0),
		Anchor = Vector2.new(1, 0),
		Callback = function()
			local name = nameBox.Text:gsub("^%s+", ""):gsub("%s+$", "")
			if name == "" then
				notify("Name needed", "Type a name for your theme first.")
				return
			end
			T.Name = name
			local d = themeToData(T)
			local replaced = false
			for i, existing in ipairs(data.customThemes) do
				if existing.Name == name then
					data.customThemes[i] = d
					replaced = true
				end
			end
			if not replaced then
				table.insert(data.customThemes, d)
			end
			persistTheme()
			renderCustom()
			markStats()
			applyTheme(true)
			notify(replaced and "Theme updated" or "Theme saved", name)
		end,
	})

	-- import / export
	UI.Section(themesPage, "Import / Export", 14)
	local ioBox = UI.Input(themesPage, {
		Size = UDim2.new(1, 0, 0, 96),
		MultiLine = true,
		Mono = true,
		TextSize = 11,
		Placeholder = 'Paste a theme JSON here, e.g. {"Name":"Mine","Accent":"#6E95FF",...}',
		Order = 15,
	})
	local ioRow = new("Frame", { Size = UDim2.new(1, 0, 0, 34), BackgroundTransparency = 1, LayoutOrder = 16, Parent = themesPage })
	list(ioRow, 8, true, Enum.VerticalAlignment.Center)
	UI.Button(ioRow, { Text = "Export current", Order = 1, Callback = function()
		ioBox.Text = HttpService:JSONEncode(themeToData(T))
		if typeof(setclipboard) == "function" then
			pcall(setclipboard, ioBox.Text)
			notify("Exported", "Theme JSON copied to your clipboard.")
		else
			notify("Exported", "Theme JSON is in the box. Select it and copy.")
		end
	end })
	UI.Button(ioRow, { Text = "Import", Style = "primary", Order = 2, Callback = function()
		local ok, decoded = pcall(function()
			return HttpService:JSONDecode(ioBox.Text)
		end)
		if not ok or type(decoded) ~= "table" then
			notify("Import failed", "That is not valid JSON.")
			return
		end
		local valid = 0
		for _, key in ipairs(COLOR_KEYS) do
			if fromHex(decoded[key]) then
				valid += 1
			end
		end
		if valid == 0 then
			notify("Import failed", "No colors found. Expected keys like Accent and Background as HEX.")
			return
		end
		decoded.Name = tostring(decoded.Name or "Imported")
		local d = themeToData(themeFromData(decoded))
		local replaced = false
		for i, existing in ipairs(data.customThemes) do
			if existing.Name == d.Name then
				data.customThemes[i] = d
				replaced = true
			end
		end
		if not replaced then
			table.insert(data.customThemes, d)
		end
		Vrya:SetTheme(d)
		renderCustom()
		markStats()
		notify("Theme imported", d.Name .. " was added to Your themes.")
	end })
	UI.Button(ioRow, { Text = "Clear", Order = 3, Callback = function()
		ioBox.Text = ""
	end })

	table.insert(themeListeners, function()
		themeNameLbl.Text = T.Name
		refreshPresetRings()
		if not pickerDragging then
			loadTarget()
		end
		glassSlider.Set(math.floor(T.Glass * 100 + 0.5), true)
		blurSlider.Set(math.floor(T.Blur + 0.5), true)
		reflSlider.Set(math.floor(T.Reflection * 100 + 0.5), true)
	end)

	loadTarget()
	renderCustom()
	refreshPresetRings()
	Studio.RenderCustom = renderCustom
end

---------------------------------------------------------------- SETTINGS

local settingsPage = makePage("settings")
do
	pageHeader(settingsPage, "Settings", "Window behaviour, motion and stored data.")

	UI.Section(settingsPage, "Window", 1)
	local keyRow = UI.Row(settingsPage, { Text = "Toggle keybind", Desc = "Shows or hides Vrya on PC", Order = 2, RightWidth = 150 })
	local keyBtn = UI.Button(keyRow, {
		Text = S.ToggleKey,
		Size = UDim2.fromOffset(130, 32),
		Position = UDim2.new(1, 0, 0.5, 0),
		Anchor = Vector2.new(1, 0.5),
	})
	keyBtn.FontFace = Font.new(MONO_FAMILY, W.Bold)
	local listening = false
	keyBtn.MouseButton1Click:Connect(function()
		if listening then
			return
		end
		listening = true
		Vrya._rebinding = true
		keyBtn.Text = "Press a key…"
		local conn
		conn = UserInputService.InputBegan:Connect(function(input)
			if input.UserInputType ~= Enum.UserInputType.Keyboard then
				return
			end
			conn:Disconnect()
			if input.KeyCode ~= Enum.KeyCode.Escape then
				S.ToggleKey = input.KeyCode.Name
				save()
				notify("Keybind updated", "Press " .. S.ToggleKey .. " to toggle Vrya.")
			end
			keyBtn.Text = S.ToggleKey
			listening = false
			task.defer(function()
				Vrya._rebinding = false
			end)
		end)
		track(conn)
	end)

	UI.Toggle(settingsPage, {
		Text = "Dynamic Island when hidden",
		Desc = "Keep the floating pill visible after using the keybind",
		Value = S.IslandWhenHidden,
		Order = 3,
		Callback = function(v)
			S.IslandWhenHidden = v
			save()
		end,
	})
	UI.Slider(settingsPage, {
		Text = "Interface scale",
		Min = 75,
		Max = 125,
		Step = 5,
		Value = S.Scale,
		Suffix = "%",
		Order = 4,
		Callback = function(x)
			S.Scale = x
		end,
		Released = function()
			save()
			computeLayout(true)
		end,
	})
	local winRow = UI.Row(settingsPage, { Text = "Window position", Desc = "Saved automatically when you drag the top bar", Order = 5, RightWidth = 110 })
	UI.Button(winRow, {
		Text = "Recenter",
		Size = UDim2.fromOffset(92, 32),
		Position = UDim2.new(1, 0, 0.5, 0),
		Anchor = Vector2.new(1, 0.5),
		Callback = function()
			data.window = { x = 0.5, y = 0.5 }
			save()
			tween(stage, 0.5, { Position = UDim2.fromScale(0.5, 0.5) })
		end,
	})

	UI.Section(settingsPage, "Appearance", 6)
	UI.Toggle(settingsPage, {
		Text = "Blur the world behind",
		Desc = "Uses a Lighting BlurEffect while Vrya is open",
		Value = S.WorldBlur,
		Order = 7,
		Callback = function(v)
			S.WorldBlur = v
			save()
			updateBlur()
		end,
	})
	UI.Toggle(settingsPage, {
		Text = "Floating chrome orbs",
		Desc = "Metal spheres and rings behind the glass",
		Value = S.Orbs,
		Order = 8,
		Callback = function(v)
			S.Orbs = v
			save()
			backdrop.Visible = v
		end,
	})
	UI.Toggle(settingsPage, {
		Text = "Reduce motion",
		Desc = "Skips transitions and spring animations",
		Value = S.ReduceMotion,
		Order = 9,
		Callback = function(v)
			S.ReduceMotion = v
			save()
			for _, tw in ipairs(driftTweens) do
				if v then
					tw:Pause()
				elseif stage.Visible then
					tw:Play()
				end
			end
		end,
	})
	UI.Toggle(settingsPage, {
		Text = "Notifications",
		Desc = "Toasts in the top-right corner",
		Value = S.Notifications,
		Order = 10,
		Callback = function(v)
			S.Notifications = v
			save()
			if v then
				notify("Notifications on", "You will see toasts again.")
			end
		end,
	})

	UI.Section(settingsPage, "Data", 11)
	UI.Row(settingsPage, {
		Text = "Storage",
		Desc = canFile and ("Saved to " .. STORE_FILE .. " in your workspace folder") or "Session only: saved until you leave the game",
		Order = 12,
		RightWidth = 10,
	})
	local dataRow = new("Frame", { Size = UDim2.new(1, 0, 0, 34), BackgroundTransparency = 1, LayoutOrder = 13, Parent = settingsPage })
	list(dataRow, 8, true, Enum.VerticalAlignment.Center)
	UI.Button(dataRow, { Text = "Clear favorites", Order = 1, Callback = function()
		table.clear(data.favorites)
		save()
		Library.Render()
		markStats()
		notify("Favorites cleared", "All stars were removed.")
	end })
	local armed = false
	local resetBtn
	resetBtn = UI.Button(dataRow, { Text = "Reset everything", Style = "danger", Order = 2, Callback = function()
		if not armed then
			armed = true
			resetBtn.Text = "Tap again to confirm"
			task.delay(3, function()
				armed = false
				if resetBtn.Parent then
					resetBtn.Text = "Reset everything"
				end
			end)
			return
		end
		armed = false
		resetBtn.Text = "Reset everything"
		table.clear(data.favorites)
		table.clear(data.customThemes)
		table.clear(data.snippets)
		table.clear(data.recent)
		data.window = { x = 0.5, y = 0.5 }
		Vrya:SetTheme(PRESETS[1])
		save()
		Library.Render()
		Studio.RenderCustom()
		markStats()
		notify("Reset", "Favorites, snippets and themes were cleared. Settings stay as they are.")
	end })
	UI.Button(dataRow, { Text = "Unload Vrya", Order = 3, Callback = function()
		Vrya:Destroy()
	end })
end

---------------------------------------------------------------- ABOUT

local aboutPage = makePage("about")
do
	local hero = glass(aboutPage, { Size = UDim2.new(1, 0, 0, 170), Order = -100, Strength = 0.25, Radius = 22 })
	padding(hero, 22, 24, 20, 26)
	label(hero, { Text = "Vrya", Size = 44, Weight = W.Bold, UDim = UDim2.new(1, 0, 0, 50) })
	label(hero, { Text = "interface.", Size = 28, Weight = W.Light, Color = SUB, UDim = UDim2.new(1, 0, 0, 34), Position = UDim2.fromOffset(2, 48) })
	label(hero, {
		Text = "Version " .. Vrya.Version .. "  ·  Liquid Glass design language for Roblox",
		Size = 12,
		Color = MUTED,
		UDim = UDim2.new(1, 0, 0, 16),
		Position = UDim2.new(0, 0, 1, 0),
		Anchor = Vector2.new(0, 1),
	})

	UI.Section(aboutPage, "What's inside", 1)
	local feats = {
		{ "Liquid Glass shell", "Translucent layers, silver rims, reflections and drifting chrome" },
		{ "Script library", "Search, categories, favorites and your own snippets" },
		{ "Code editor", "Live Luau highlighting with line numbers (display only)" },
		{ "Theme studio", "HSV picker, HEX and RGB entry, presets, import and export" },
		{ "Adaptive window", "Draggable, remembers its spot, scales to phones and tablets" },
		{ "Dynamic Island", "Minimize into a floating pill, tap to expand" },
	}
	for i, f in ipairs(feats) do
		UI.Row(aboutPage, { Text = f[1], Desc = f[2], Order = 1 + i, RightWidth = 10 })
	end

	UI.Section(aboutPage, "Shortcuts", 20)
	local keyHint = UI.Row(aboutPage, { Text = "Toggle window", Desc = "Change it in Settings", Order = 21, RightWidth = 140 })
	local keyLbl = label(keyHint, {
		Text = "",
		Size = 12,
		Font = Font.new(MONO_FAMILY, W.Bold),
		UDim = UDim2.new(0, 130, 1, 0),
		Position = UDim2.new(1, 0, 0, 0),
		Anchor = Vector2.new(1, 0),
		AlignX = Enum.TextXAlignment.Right,
	})
	pageHooks.about = function()
		keyLbl.Text = S.ToggleKey
	end
	UI.Row(aboutPage, { Text = "Move window", Desc = "Drag the top bar", Order = 22, RightWidth = 10 })
	UI.Row(aboutPage, { Text = "Minimize", Desc = "Yellow light, or tap the Dynamic Island to restore", Order = 23, RightWidth = 10 })

	UI.Section(aboutPage, "Notes", 30)
	label(aboutPage, {
		Text = "Vrya is a standalone UI prototype. The editor and library only display code; nothing is executed or injected.",
		Size = 12,
		Color = SUB,
		Wrap = true,
		Order = 31,
		UDim = UDim2.new(1, 0, 0, 34),
	})
end

---------------------------------------------------------------- Dynamic Island

local ISLAND_W, ISLAND_H, ISLAND_DOT = 196, 40, 38
local island = new("TextButton", {
	Name = "Island",
	AnchorPoint = Vector2.new(0.5, 0),
	Position = UDim2.new(0.5, 0, 0, 8),
	Size = UDim2.fromOffset(ISLAND_DOT, ISLAND_DOT),
	BackgroundColor3 = BLACK,
	BackgroundTransparency = 0.04,
	BorderSizePixel = 0,
	AutoButtonColor = false,
	Text = "",
	Visible = false,
	ClipsDescendants = true,
	ZIndex = 30,
	Parent = gui,
})
corner(island, ROUND)
local islandStroke = new("UIStroke", { Thickness = 1, Color = Color3.fromRGB(80, 82, 90), Transparency = 0.4, Parent = island })
local islandScale = new("UIScale", { Parent = island })
local islandDot = new("Frame", {
	Size = UDim2.fromOffset(10, 10),
	Position = UDim2.new(0, 15, 0.5, 0),
	AnchorPoint = Vector2.new(0, 0.5),
	BorderSizePixel = 0,
	Parent = island,
})
corner(islandDot, ROUND)
bind(islandDot, "BackgroundColor3", C("Accent"))
local islandPulse = new("Frame", {
	Size = UDim2.fromOffset(10, 10),
	Position = UDim2.fromScale(0.5, 0.5),
	AnchorPoint = Vector2.new(0.5, 0.5),
	BackgroundTransparency = 1,
	Parent = islandDot,
})
corner(islandPulse, ROUND)
local pulseStroke = new("UIStroke", { Thickness = 2, Transparency = 0.2, Parent = islandPulse })
bind(pulseStroke, "Color", C("Accent"))
local pulseTween = TweenService:Create(islandPulse, TweenInfo.new(1.4, Enum.EasingStyle.Quad, Enum.EasingDirection.Out, -1), { Size = UDim2.fromOffset(24, 24) })
local pulseFade = TweenService:Create(pulseStroke, TweenInfo.new(1.4, Enum.EasingStyle.Quad, Enum.EasingDirection.Out, -1), { Transparency = 1 })

local islandTitle = new("TextLabel", {
	Size = UDim2.new(1, -110, 1, 0),
	Position = UDim2.fromOffset(34, 0),
	BackgroundTransparency = 1,
	Text = "Vrya",
	TextColor3 = WHITE,
	FontFace = font(W.SemiBold),
	TextSize = 14,
	TextXAlignment = Enum.TextXAlignment.Left,
	TextTransparency = 1,
	Parent = island,
})
local islandTime = new("TextLabel", {
	Size = UDim2.fromOffset(70, ISLAND_H),
	Position = UDim2.new(1, -16, 0, 0),
	AnchorPoint = Vector2.new(1, 0),
	BackgroundTransparency = 1,
	Text = "",
	TextColor3 = Color3.fromRGB(170, 172, 180),
	FontFace = Font.new(MONO_FAMILY),
	TextSize = 12,
	TextXAlignment = Enum.TextXAlignment.Right,
	TextTransparency = 1,
	Parent = island,
})

local function showIsland()
	islandTime.Text = os.date("%H:%M")
	island.Visible = true
	island.Size = UDim2.fromOffset(ISLAND_DOT, ISLAND_DOT)
	islandTitle.TextTransparency = 1
	islandTime.TextTransparency = 1
	tween(island, 0.6, { Size = UDim2.fromOffset(ISLAND_W, ISLAND_H) }, Enum.EasingStyle.Back)
	task.delay(S.ReduceMotion and 0 or 0.2, function()
		tween(islandTitle, 0.3, { TextTransparency = 0 })
		tween(islandTime, 0.3, { TextTransparency = 0 })
	end)
	if not S.ReduceMotion then
		pulseTween:Play()
		pulseFade:Play()
	end
end

local function hideIsland()
	if not island.Visible then
		return
	end
	tween(islandTitle, 0.15, { TextTransparency = 1 })
	tween(islandTime, 0.15, { TextTransparency = 1 })
	tween(island, 0.3, { Size = UDim2.fromOffset(ISLAND_DOT, ISLAND_DOT) }, Enum.EasingStyle.Quint, Enum.EasingDirection.In)
	task.delay(S.ReduceMotion and 0 or 0.28, function()
		if not state.minimized then
			island.Visible = false
		end
		pulseTween:Pause()
		pulseFade:Pause()
	end)
end

---------------------------------------------------------------- layout + window controls

local busy = false
local ISLAND_ANCHOR = UDim2.new(0.5, 0, 0, 28)

local function savedPosition()
	if state.maximized or state.small then
		return UDim2.fromScale(0.5, 0.5)
	end
	return UDim2.fromScale(tonumber(data.window.x) or 0.5, tonumber(data.window.y) or 0.5)
end

local function clampPosition(nx, ny)
	local vp = gui.AbsoluteSize
	if vp.X <= 0 or vp.Y <= 0 then
		return nx, ny
	end
	local halfW = state.winW * currentScale / 2 / vp.X
	local halfH = state.winH * currentScale / 2 / vp.Y
	local minX, maxX = 0.12 - halfW + halfW * 0.2, 0.88 + halfW - halfW * 0.2
	nx = math.clamp(nx, math.min(minX, 0.5), math.max(maxX, 0.5))
	local minY = math.min(halfH, 0.5)
	local maxY = math.max(1 - TOPBAR_H * currentScale / vp.Y, 0.5)
	ny = math.clamp(ny, minY, maxY)
	return nx, ny
end

function computeLayout(animate)
	local vp = gui.AbsoluteSize
	if vp.X <= 0 or vp.Y <= 0 then
		return
	end
	local userScale = (tonumber(S.Scale) or 100) / 100
	state.small = isTouchOnly or vp.X < 720 or vp.Y < 460
	local ds, winW, winH
	if state.small then
		ds = math.clamp(math.min(vp.X, vp.Y) / 480, 0.68, 1) * userScale
		winW = (vp.X - 16) / ds
		winH = (vp.Y - 16) / ds
	else
		ds = math.clamp(math.min((vp.X - 40) / BASE_W, (vp.Y - 40) / BASE_H), 0.6, 1) * userScale
		if state.maximized then
			winW = (vp.X - 40) / ds
			winH = (vp.Y - 40) / ds
		else
			winW, winH = BASE_W, BASE_H
		end
	end
	state.winW, state.winH, state.deviceScale = winW, winH, ds
	currentScale = ds
	notifyScale.Scale = math.clamp(ds, 0.8, 1)
	islandScale.Scale = math.clamp(ds, 0.85, 1.1)
	notifyHolder.Position = state.small and UDim2.new(0.5, 0, 0, 56) or UDim2.new(1, -14, 0, 10)
	notifyHolder.AnchorPoint = state.small and Vector2.new(0.5, 0) or Vector2.new(1, 0)

	local compact = winW < 640
	state.compact = compact
	local sideW = compact and 64 or 196
	sidebar.Size = UDim2.new(0, sideW, 1, 0)
	content.Size = UDim2.new(1, -sideW, 1, 0)
	content.Position = UDim2.fromOffset(sideW, 0)
	brand.Text = compact and "V" or "Vrya"
	brand.Position = compact and UDim2.fromOffset(0, 14) or UDim2.fromOffset(22, 14)
	brand.Size = compact and UDim2.new(1, 0, 0, 34) or UDim2.new(1, -36, 0, 34)
	brand.TextXAlignment = compact and Enum.TextXAlignment.Center or Enum.TextXAlignment.Left
	brandSub.Visible = not compact
	navHolder.Position = UDim2.fromOffset(compact and 8 or 12, compact and 62 or 76)
	navHolder.Size = UDim2.new(1, compact and -16 or -24, 1, -150)
	for _, nb in pairs(navButtons) do
		nb.text.Visible = not compact
		nb.icon.Position = compact and UDim2.new(0.5, -13, 0, 0) or UDim2.fromOffset(12, 0)
	end
	profileName.Visible = not compact
	profileSub.Visible = not compact
	avatar.Position = compact and UDim2.new(0.5, -16, 0.5, 0) or UDim2.new(0, 8, 0.5, 0)
	profile.Size = compact and UDim2.new(1, -8, 0, 48) or UDim2.new(1, -24, 0, 48)
	profile.Position = compact and UDim2.new(0, 4, 1, -60) or UDim2.new(0, 12, 1, -60)
	addressLbl.Visible = winW > 520
	btnZoom.Visible = not state.small

	if state.visible and not busy then
		local pos = savedPosition()
		if not state.small and not state.maximized then
			local nx, ny = clampPosition(pos.X.Scale, pos.Y.Scale)
			pos = UDim2.fromScale(nx, ny)
		end
		if animate then
			tween(stage, 0.5, { Size = UDim2.fromOffset(winW, winH), Position = pos })
			tween(stageScale, 0.5, { Scale = ds })
		else
			stage.Size = UDim2.fromOffset(winW, winH)
			stage.Position = pos
			stageScale.Scale = ds
		end
	else
		stage.Size = UDim2.fromOffset(winW, winH)
	end
end

function updateBlur()
	local target = (state.visible and S.WorldBlur) and T.Blur or 0
	tween(blurFx, 0.45, { Size = target }, Enum.EasingStyle.Quad)
end
table.insert(themeListeners, function()
	updateBlur()
end)

local function setDrift(on)
	for _, tw in ipairs(driftTweens) do
		if on and not S.ReduceMotion then
			tw:Play()
		else
			tw:Pause()
		end
	end
end

function collapse(withIsland)
	if busy or not state.visible then
		return
	end
	busy = true
	state.visible = false
	state.minimized = withIsland and true or false
	updateBlur()
	local t = S.ReduceMotion and 0 or 0.42
	tween(stageScale, 0.42, { Scale = currentScale * 0.05 }, Enum.EasingStyle.Quint, Enum.EasingDirection.In)
	tween(stage, 0.42, { Position = ISLAND_ANCHOR }, Enum.EasingStyle.Quint, Enum.EasingDirection.In)
	task.delay(t, function()
		stage.Visible = false
		setDrift(false)
		if withIsland then
			showIsland()
		end
		busy = false
	end)
end

function expand()
	if busy or state.visible then
		return
	end
	busy = true
	state.visible = true
	state.minimized = false
	hideIsland()
	computeLayout(false)
	local delayT = (island.Visible and not S.ReduceMotion) and 0.18 or 0
	task.delay(delayT, function()
		stage.Visible = true
		stageScale.Scale = currentScale * 0.05
		stage.Position = ISLAND_ANCHOR
		tween(stageScale, 0.6, { Scale = currentScale }, Enum.EasingStyle.Back)
		tween(stage, 0.55, { Position = savedPosition() }, Enum.EasingStyle.Quint)
		setDrift(true)
		updateBlur()
		task.delay(S.ReduceMotion and 0 or 0.6, function()
			busy = false
		end)
	end)
end

function Vrya:Toggle()
	if state.visible then
		collapse(S.IslandWhenHidden or isTouchOnly)
	else
		expand()
	end
end
function Vrya:Minimize()
	collapse(true)
end
function Vrya:Restore()
	expand()
end
function Vrya:Navigate(id)
	navigate(id)
end

island.MouseButton1Click:Connect(function()
	expand()
end)

btnMin.MouseButton1Click:Connect(function()
	collapse(true)
end)
btnClose.MouseButton1Click:Connect(function()
	local withIsland = S.IslandWhenHidden or isTouchOnly
	collapse(withIsland)
	if not withIsland then
		notify("Vrya hidden", "Press " .. S.ToggleKey .. " to bring it back.")
	end
end)
btnZoom.MouseButton1Click:Connect(function()
	if state.small or busy then
		return
	end
	state.maximized = not state.maximized
	computeLayout(true)
end)

-- drag by the top bar; the position is stored as a fraction of the screen
do
	local dragStart, startPos
	onDrag(topbar, function(pos, first)
		if first then
			dragStart, startPos = pos, stage.Position
			return
		end
		local vp = gui.AbsoluteSize
		local d = pos - dragStart
		local nx, ny = clampPosition(startPos.X.Scale + d.X / vp.X, startPos.Y.Scale + d.Y / vp.Y)
		tween(stage, 0.08, { Position = UDim2.fromScale(nx, ny) }, Enum.EasingStyle.Quad)
	end, function()
		if state.maximized or state.small then
			return
		end
		task.delay(0.1, function()
			data.window = { x = stage.Position.X.Scale, y = stage.Position.Y.Scale }
			save()
		end)
	end, function(input)
		if state.maximized or state.small or busy then
			return false
		end
		local p = input.Position
		local a, sz = lights.AbsolutePosition, lights.AbsoluteSize
		if p.X >= a.X and p.X <= a.X + sz.X and p.Y >= a.Y and p.Y <= a.Y + sz.Y then
			return false
		end
		return true
	end)
end

-- keyboard toggle
track(UserInputService.InputBegan:Connect(function(input)
	if Vrya._rebinding or input.UserInputType ~= Enum.UserInputType.Keyboard then
		return
	end
	if UserInputService:GetFocusedTextBox() then
		return
	end
	if input.KeyCode.Name == S.ToggleKey then
		Vrya:Toggle()
	end
end))

track(gui:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
	computeLayout(false)
end))

-- island clock
task.spawn(function()
	while alive do
		if island.Visible then
			islandTime.Text = os.date("%H:%M")
		end
		task.wait(5)
	end
end)

---------------------------------------------------------------- lifecycle

function Vrya:Destroy()
	if not alive then
		return
	end
	alive = false
	for _, c in ipairs(connections) do
		pcall(function()
			c:Disconnect()
		end)
	end
	for _, tw in ipairs(driftTweens) do
		tw:Cancel()
	end
	pulseTween:Cancel()
	pulseFade:Cancel()
	local fade = TweenService:Create(blurFx, TweenInfo.new(0.3), { Size = 0 })
	fade:Play()
	fade.Completed:Connect(function()
		blurFx:Destroy()
	end)
	gui:Destroy()
	if genv.Vrya_Unload then
		genv.Vrya_Unload = nil
	end
end
genv.Vrya_Unload = function()
	Vrya:Destroy()
end

-- boot: lay out, open Home, spring the window in
backdrop.Visible = S.Orbs
computeLayout(false)
navigate("home")
markStats()
stageScale.Scale = currentScale * 0.9
tween(stageScale, 0.7, { Scale = currentScale }, Enum.EasingStyle.Back)
setDrift(true)
updateBlur()
task.delay(0.6, function()
	notify(
		"Welcome to Vrya",
		isTouchOnly and "Tap the yellow light to tuck Vrya into the island." or ("Press " .. S.ToggleKey .. " any time to hide or show."),
		5
	)
end)

return Vrya
