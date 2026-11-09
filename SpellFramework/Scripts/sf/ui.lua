-- Spell Framework: on-screen UI built from plain UMG widgets at run time.
--   UI.Toast(text, seconds)            short message at the top of the screen
--   UI.Wheel(options, onPick, onCancel) selection wheel (spell variants)
--   UI.Prompt(spec)                    text box with suggestions (e.g. Accio)
-- Only one Wheel or Prompt is open at a time. UI.Tick() must be called often
-- (about every 50 ms) on the game thread, and UI.Key(name) when a key is pressed.
local UEHelpers = require("UEHelpers")
local U = require("sf.util")

local UI = {}
local active = nil      -- the open Wheel or Prompt
local toasts = {}

local WHITE = { R = 1, G = 1, B = 1, A = 1 }
local GOLD = { R = 0.93, G = 0.78, B = 0.45, A = 1 }
local GREY = { R = 0.7, G = 0.7, B = 0.7, A = 1 }
local RED = { R = 0.95, G = 0.4, B = 0.35, A = 1 }

local function New(classPath, outer, name)
    return StaticConstructObject(StaticFindObject(classPath), outer, FName(U.UniqueName(name)))
end

local function Root(name)
    local gi = UEHelpers.GetGameInstance()
    local w = New("/Script/UMG.UserWidget", gi, "SF_" .. name)
    w.WidgetTree = New("/Script/UMG.WidgetTree", w, "WidgetTree")
    local canvas = New("/Script/UMG.CanvasPanel", w.WidgetTree, "Canvas")
    w.WidgetTree.RootWidget = canvas
    return w, canvas
end

-- Places `child` on `canvas`, centred on the screen point (cx, cy) offsets.
local function Place(canvas, child, x, y, w, h, alignX, alignY, anchorX, anchorY)
    local slot = canvas:AddChildToCanvas(child)
    anchorX, anchorY = anchorX or 0.5, anchorY or 0.5
    pcall(function() slot:SetAnchors({ Minimum = { X = anchorX, Y = anchorY }, Maximum = { X = anchorX, Y = anchorY } }) end)
    pcall(function() slot:SetAlignment({ X = alignX or 0.5, Y = alignY or 0.5 }) end)
    pcall(function() slot:SetPosition({ X = x, Y = y }) end)
    if w and h then
        pcall(function() slot:SetSize({ X = w, Y = h }) end)
    else
        pcall(function() slot:SetAutoSize(true) end)
    end
    return slot
end

local function Text(tree, s, size, color, justify)
    local t = New("/Script/UMG.TextBlock", tree, "Text")
    t:SetText(FText(s or ""))
    pcall(function() t:SetColorAndOpacity({ SpecifiedColor = color or WHITE, ColorUseRule = 0 }) end)
    if size then
        pcall(function()
            local font = t.Font
            font.Size = size
            t:SetFont(font)
        end)
    end
    if justify then pcall(function() t:SetJustification(justify) end) end
    return t
end

local function SetText(t, s, color)
    pcall(function() t:SetText(FText(s or "")) end)
    if color then pcall(function() t:SetColorAndOpacity({ SpecifiedColor = color, ColorUseRule = 0 }) end) end
end

local function Box(tree, color, padding)
    local b = New("/Script/UMG.Border", tree, "Box")
    pcall(function() b:SetBrushColor(color or { R = 0.02, G = 0.02, B = 0.02, A = 0.8 }) end)
    local p = padding or 12
    pcall(function() b:SetPadding({ Left = p, Top = p, Right = p, Bottom = p }) end)
    return b
end

local textureCache = {}
local function Texture(path)
    if not path or path == "" then return nil end
    local t = textureCache[path]
    if U.Valid(t) then return t end
    t = U.Load(path)
    textureCache[path] = t
    return t
end

local function Image(tree, texturePath, w, h, tint)
    local img = New("/Script/UMG.Image", tree, "Img")
    local tex = Texture(texturePath)
    if tex then pcall(function() img:SetBrushFromTexture(tex, false) end) end
    pcall(function() img:SetDesiredSizeOverride({ X = w, Y = h }) end)
    if tint then pcall(function() img:SetColorAndOpacity(tint) end) end
    return img, tex ~= nil
end

local function Show(widget, z)
    widget:AddToViewport(z or 900)
end

local function Remove(widget)
    if U.Valid(widget) then pcall(function() widget:RemoveFromParent() end) end
end

-------------------------------------------------------------------- input mode

local wbl
local function WBL()
    if not U.Valid(wbl) then wbl = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary") end
    return wbl
end

local function EnterUIMode(focusWidget)
    local pc = U.PlayerController()
    if not pc then return end
    U.Set(pc, "bShowMouseCursor", true)
    pcall(function() WBL():SetInputMode_UIOnlyEx(pc, focusWidget, 0, true) end)
    if focusWidget then pcall(function() focusWidget:SetKeyboardFocus() end) end
end

local function LeaveUIMode()
    local pc = U.PlayerController()
    if not pc then return end
    pcall(function() WBL():SetInputMode_GameOnly(pc, true) end)
    U.Set(pc, "bShowMouseCursor", false)
end

local wll
local function MouseFromCenter()
    if not U.Valid(wll) then wll = StaticFindObject("/Script/UMG.Default__WidgetLayoutLibrary") end
    local pc = U.PlayerController()
    if not (U.Valid(wll) and pc) then return nil end
    local ok, res = pcall(function()
        local mouse = wll:GetMousePositionOnViewport(pc)
        local size = wll:GetViewportSize(pc)
        local scale = wll:GetViewportScale(pc)
        if not scale or scale <= 0 then scale = 1 end
        return { X = mouse.X - size.X / scale / 2, Y = mouse.Y - size.Y / scale / 2 }
    end)
    if ok then return res end
    return nil
end

-------------------------------------------------------------------- toasts

function UI.Toast(message, seconds)
    local ok, err = pcall(function()
        for _, t in ipairs(toasts) do Remove(t.widget) end
        toasts = {}
        local w, canvas = Root("Toast")
        local box = Box(w.WidgetTree, { R = 0.03, G = 0.025, B = 0.02, A = 0.85 }, 14)
        box:SetContent(Text(w.WidgetTree, message, 20, GOLD, 1))
        Place(canvas, box, 0, 140, nil, nil, 0.5, 0, 0.5, 0)
        Show(w, 950)
        toasts[#toasts + 1] = { widget = w, untilTime = os.clock() + (seconds or 3) }
    end)
    if not ok then U.Log("Toast failed: %s (%s)", tostring(err), tostring(message)) end
    U.Log("%s", message)
end

-------------------------------------------------------------------- wheel

-- options: { { name, description, icon (texture path), detail (cost/cooldown line), disabled } }
function UI.Wheel(spec)
    UI.Close()
    local options = spec.options or {}
    local n = #options
    if n == 0 then return end
    local w, canvas = Root("Wheel")
    local tree = w.WidgetTree
    local radius = spec.radius or (n <= 4 and 170 or 210)
    local self = { kind = "wheel", widget = w, options = options, spec = spec, hovered = nil, slots = {}, opened = os.clock() }

    -- Background, using the game's spell radial textures when they load.
    local bg, okBg = Image(tree, "/Game/Art/UI/Spellcasting/T_Radial_Base_Bg", radius * 2 + 190, radius * 2 + 190, { R = 1, G = 1, B = 1, A = 0.95 })
    if okBg then Place(canvas, bg, 0, 0, radius * 2 + 190, radius * 2 + 190) else
        local disc = Box(tree, { R = 0.03, G = 0.025, B = 0.02, A = 0.85 }, 0)
        Place(canvas, disc, 0, 0, radius * 2 + 150, radius * 2 + 150)
    end
    local center, okCenter = Image(tree, "/Game/Art/UI/Spellcasting/T_Radial_Centre_Bg", 300, 300)
    if okCenter then Place(canvas, center, 0, 0, 300, 300) end

    for i, opt in ipairs(options) do
        local angle = math.rad(-90 + (i - 1) * 360 / n)
        local x, y = math.cos(angle) * radius, math.sin(angle) * radius
        local frame = Box(tree, { R = 0.1, G = 0.08, B = 0.05, A = 0.0 }, 6)
        local icon = Image(tree, opt.icon, 84, 84)
        frame:SetContent(icon)
        Place(canvas, frame, x, y, 100, 100)
        local label = Text(tree, (i <= 9 and (i .. "  ") or "") .. (opt.name or "?"), 16, opt.disabled and GREY or WHITE, 1)
        Place(canvas, label, x, y + 66, nil, nil, 0.5, 0)
        self.slots[i] = { frame = frame, icon = icon, label = label, angle = angle }
    end

    local title = Text(tree, spec.title or "", 22, GOLD, 1)
    Place(canvas, title, 0, -48, 270, 34)
    local detail = Text(tree, "", 16, WHITE, 1)
    Place(canvas, detail, 0, -8, 260, 30)
    local desc = Text(tree, spec.hint or "Move the mouse to choose, click to cast. Esc cancels.", 14, GREY, 1)
    pcall(function() desc:SetAutoWrapText(true) end)
    Place(canvas, desc, 0, 40, 250, 90)
    self.title, self.detail, self.desc = title, detail, desc

    Show(w, 940)
    EnterUIMode(nil)
    active = self

    function self.Highlight(idx)
        if self.hovered == idx then return end
        self.hovered = idx
        for j, s in ipairs(self.slots) do
            local on = (j == idx)
            pcall(function() s.frame:SetBrushColor(on and { R = 0.93, G = 0.78, B = 0.45, A = 0.55 } or { R = 0.1, G = 0.08, B = 0.05, A = 0.0 }) end)
        end
        local opt = idx and options[idx]
        if opt then
            SetText(self.title, opt.name or "")
            SetText(self.detail, opt.detail or "", opt.disabled and RED or WHITE)
            SetText(self.desc, opt.description or "")
        else
            SetText(self.title, spec.title or "")
            SetText(self.detail, "")
            SetText(self.desc, spec.hint or "")
        end
    end

    function self.Tick()
        local m = MouseFromCenter()
        if not m then return end
        local dist = math.sqrt(m.X * m.X + m.Y * m.Y)
        if dist < 60 then return end -- keep the last highlight inside the centre
        local a = math.atan(m.Y, m.X)
        local best, bestDiff = nil, math.huge
        for j, s in ipairs(self.slots) do
            local d = math.abs(math.atan(math.sin(a - s.angle), math.cos(a - s.angle)))
            if d < bestDiff then best, bestDiff = j, d end
        end
        self.Highlight(best)
    end

    function self.Pick(idx)
        local opt = idx and options[idx]
        if not opt then return end
        UI.Close()
        if spec.onPick then
            local ok, err = pcall(spec.onPick, idx, opt)
            if not ok then U.Log("Wheel choice failed: %s", tostring(err)) end
        end
    end

    function self.Key(key)
        if key == "ESCAPE" then
            UI.Close()
            if spec.onCancel then pcall(spec.onCancel) end
        elseif key == "LEFT_MOUSE_BUTTON" or key == "RETURN" then
            if os.clock() - self.opened > 0.25 then self.Pick(self.hovered) end
        elseif key:match("^NUM_?%d$") or key:match("^%d$") then
            self.Pick(tonumber(key:match("(%d)$")))
        end
    end

    self.Highlight(nil)
    return self
end

-------------------------------------------------------------------- prompt

-- spec: { title, hint, suggest = function(text) -> { {label, value}... }, onSubmit(text, suggestion), onCancel }
function UI.Prompt(spec)
    UI.Close()
    local w, canvas = Root("Prompt")
    local tree = w.WidgetTree
    local panel = Box(tree, { R = 0.03, G = 0.025, B = 0.02, A = 0.9 }, 18)
    local vb = New("/Script/UMG.VerticalBox", tree, "VB")
    panel:SetContent(vb)
    vb:AddChildToVerticalBox(Text(tree, spec.title or "", 24, GOLD))
    local input = New("/Script/UMG.EditableTextBox", tree, "Input")
    pcall(function() input:SetHintText(FText(spec.hint or "")) end)
    vb:AddChildToVerticalBox(input)
    local rows = {}
    for i = 1, 8 do
        local t = Text(tree, "", 17, WHITE)
        vb:AddChildToVerticalBox(t)
        rows[i] = t
    end
    local help = Text(tree, "Up/Down choose  -  Tab completes  -  Enter casts  -  Esc cancels", 13, GREY)
    vb:AddChildToVerticalBox(help)
    Place(canvas, panel, 0, -120, 620, 400)
    Show(w, 940)

    local self = { kind = "prompt", widget = w, input = input, rows = rows, list = {}, selected = 1, lastText = nil, opened = os.clock() }

    local function Current()
        local ok, s = pcall(function() return input:GetText():ToString() end)
        return ok and s or ""
    end

    function self.Refresh(force)
        local text = Current()
        if not force and text == self.lastText then return end
        self.lastText = text
        local ok, list = pcall(spec.suggest, text)
        self.list = (ok and type(list) == "table") and list or {}
        if self.selected > #self.list then self.selected = 1 end
        for i, row in ipairs(rows) do
            local s = self.list[i]
            if s then
                SetText(row, (i == self.selected and "> " or "   ") .. s.label, i == self.selected and GOLD or WHITE)
            else
                SetText(row, "")
            end
        end
    end

    function self.Tick() self.Refresh(false) end

    function self.Key(key)
        if key == "ESCAPE" then
            UI.Close()
            if spec.onCancel then pcall(spec.onCancel) end
        elseif key == "DOWN_ARROW" then
            if #self.list > 0 then self.selected = self.selected % math.min(#self.list, #rows) + 1 end
            self.Refresh(true)
        elseif key == "UP_ARROW" then
            if #self.list > 0 then
                self.selected = self.selected - 1
                if self.selected < 1 then self.selected = math.min(#self.list, #rows) end
            end
            self.Refresh(true)
        elseif key == "TAB" then
            local s = self.list[self.selected]
            if s then
                pcall(function() input:SetText(FText(s.complete or s.value or s.label)) end)
                self.Refresh(true)
            end
        elseif key == "RETURN" then
            if os.clock() - self.opened < 0.2 then return end
            local text = Current()
            local s = self.list[self.selected]
            UI.Close()
            if spec.onSubmit then
                local ok, err = pcall(spec.onSubmit, text, s)
                if not ok then U.Log("Prompt failed: %s", tostring(err)) end
            end
        end
    end

    active = self
    EnterUIMode(input)
    self.Refresh(true)
    return self
end

-------------------------------------------------------------------- shared

function UI.IsOpen() return active ~= nil end

function UI.Close()
    if active then
        Remove(active.widget)
        active = nil
        LeaveUIMode()
    end
end

function UI.Key(key)
    if active and active.Key then
        local ok, err = pcall(active.Key, key)
        if not ok then U.Log("UI key error: %s", tostring(err)) end
    end
end

function UI.Tick()
    local now = os.clock()
    for i = #toasts, 1, -1 do
        if now >= toasts[i].untilTime then
            Remove(toasts[i].widget)
            table.remove(toasts, i)
        end
    end
    if active then
        if not U.Valid(active.widget) then
            active = nil
            LeaveUIMode()
            return
        end
        local ok, err = pcall(active.Tick)
        if not ok then U.Log("UI tick error: %s", tostring(err)) end
    end
end

-- Keys the UI listens for. main.lua registers these with UE4SS.
UI.Keys = { "ESCAPE", "RETURN", "TAB", "UP_ARROW", "DOWN_ARROW", "LEFT_MOUSE_BUTTON",
            "ONE", "TWO", "THREE", "FOUR", "FIVE", "SIX", "SEVEN", "EIGHT", "NINE" }
UI.KeyAlias = { ONE = "1", TWO = "2", THREE = "3", FOUR = "4", FIVE = "5", SIX = "6", SEVEN = "7", EIGHT = "8", NINE = "9" }

return UI
