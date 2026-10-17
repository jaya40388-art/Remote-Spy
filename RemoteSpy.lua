--[[
    ╔══════════════════════════════════════════════════════════════╗
    ║                    JAYA REMOTE SPY v1.0                      ║
    ║        Perekam FireServer / InvokeServer + Terminal UI       ║
    ║          Compatible: Delta, Fluxus, Codex, Solara            ║
    ╚══════════════════════════════════════════════════════════════╝

    CARA PAKAI
    1. Jalankan script ini (cukup sekali, bisa di game apa saja).
    2. Lakukan aksi manual di game (mis. beli 1 benih di Shop Seed).
    3. Muncul notifikasi di pojok kanan atas + catatan di terminal:
         ReplicatedStorage.GameEvents.BuySeedStock
         ["Carrot"]
    4. Tombol [Salin] di tiap baris menyalin kode siap pakai:
         game:GetService("ReplicatedStorage").GameEvents.BuySeedStock:FireServer("Carrot")

    TOMBOL
      ⏸ Jeda    : berhenti / lanjut merekam
      🗑 Hapus   : kosongkan terminal
      📋 Salin   : salin semua baris yang tampil (ikut filter)
      🔔 Notif   : nyalakan / matikan notifikasi pop-up
      🔊 Unmute  : aktifkan lagi semua remote yang di-mute
      Mute (di tiap baris): sembunyikan remote yang berisik
      Kotak Filter: ketik kata (mis. "buy" atau "seed") untuk menyaring
]]

-- ═══════════════════════════════════════════════════════════════
-- BERSIHKAN INSTANCE LAMA (jika script dijalankan ulang)
-- ═══════════════════════════════════════════════════════════════
local env = (typeof(getgenv) == "function" and getgenv()) or _G
if env.JAYA_SPY_CLEANUP then
    pcall(env.JAYA_SPY_CLEANUP)
end

-- ═══════════════════════════════════════════════════════════════
-- KONFIGURASI
-- ═══════════════════════════════════════════════════════════════
local CONFIG = {
    MAX_ENTRIES        = 150,   -- maksimum baris di terminal
    MAX_QUEUE          = 300,   -- antrean maksimum sebelum yang lama dibuang
    MAX_PER_FRAME      = 8,     -- jumlah panggilan diproses per frame
    AUTO_MUTE_PER_SEC  = 25,    -- remote >N panggilan/detik di-mute otomatis (spam)
    TOAST_TIME         = 4.5,   -- lama notifikasi tampil (detik)
    TOAST_MAX          = 4,     -- maksimum notifikasi tampil bersamaan
    TOAST_REPEAT_GAP   = 1.5,   -- jeda notifikasi untuk panggilan identik berulang
    MAX_DEPTH          = 4,     -- kedalaman tabel saat ditampilkan
    MAX_ITEMS          = 25,    -- jumlah elemen tabel yang ditampilkan
    MAX_STRING         = 160,   -- panjang string maksimum yang ditampilkan
    LOG_EXECUTOR_CALLS = false, -- true = ikut rekam panggilan dari script executor
    HIGHLIGHT_KEYWORDS = { "buy", "purchase", "stock", "seed", "egg", "gear", "shop" },
}

-- ═══════════════════════════════════════════════════════════════
-- SERVICES & KEMAMPUAN EXECUTOR
-- ═══════════════════════════════════════════════════════════════
local Players          = game:GetService("Players")
local RunService       = game:GetService("RunService")
local TweenService     = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local CoreGui          = game:GetService("CoreGui")
local Player           = Players.LocalPlayer

local ncc          = newcclosure or function(f) return f end
local isExecutor   = checkcaller or function() return false end
local getCaller    = getcallingscript
local clipboardFn  = setclipboard or toclipboard

local CALL_METHODS = {
    FireServer   = "FireServer",   fireServer   = "FireServer",
    InvokeServer = "InvokeServer", invokeServer = "InvokeServer",
}
local REMOTE_CLASSES = {
    RemoteEvent = true, RemoteFunction = true, UnreliableRemoteEvent = true,
}

-- ═══════════════════════════════════════════════════════════════
-- STATE
-- ═══════════════════════════════════════════════════════════════
local State = {
    Active      = true,
    Paused      = false,
    Notif       = true,
    Filter      = "",
    Muted       = {},      -- [RemoteInstance] = true
    MutedCount  = 0,
    Total       = 0,
    Dropped     = 0,
    Connections = {},
    HookMode    = "none",
}

local function track(conn)
    table.insert(State.Connections, conn)
    return conn
end

-- ═══════════════════════════════════════════════════════════════
-- SERIALIZER (argumen -> teks yang mudah dibaca & valid sebagai kode Lua)
-- ═══════════════════════════════════════════════════════════════
local LUA_KEYWORDS = {
    ["and"] = true, ["break"] = true, ["do"] = true, ["else"] = true, ["elseif"] = true,
    ["end"] = true, ["false"] = true, ["for"] = true, ["function"] = true, ["if"] = true,
    ["in"] = true, ["local"] = true, ["nil"] = true, ["not"] = true, ["or"] = true,
    ["repeat"] = true, ["return"] = true, ["then"] = true, ["true"] = true,
    ["until"] = true, ["while"] = true,
}

local function isIdentifier(s)
    return type(s) == "string" and s:match("^[%a_][%w_]*$") ~= nil and not LUA_KEYWORDS[s]
end

local function quote(s)
    local extra = ""
    if #s > CONFIG.MAX_STRING then
        extra = string.format("…(+%d)", #s - CONFIG.MAX_STRING)
        s = s:sub(1, CONFIG.MAX_STRING)
    end
    s = s:gsub("\\", "\\\\")
    s = s:gsub('"', '\\"')
    s = s:gsub("\n", "\\n")
    s = s:gsub("\r", "\\r")
    s = s:gsub("\t", "\\t")
    return '"' .. s .. extra .. '"'
end

local function fmtNum(n)
    if n ~= n then return "0/0" end
    if n == math.huge then return "math.huge" end
    if n == -math.huge then return "-math.huge" end
    if n == math.floor(n) and math.abs(n) < 1e15 then
        return string.format("%d", n)
    end
    return tostring(n)
end

-- Jalur instance sebagai kode: game:GetService("ReplicatedStorage").Events.BuySeed
local function codePath(inst)
    local chain, cur = {}, inst
    while cur and cur ~= game do
        table.insert(chain, 1, cur)
        cur = cur.Parent
    end
    if cur ~= game then
        return "nil --[[ instance tidak berada di dalam game ]]"
    end
    if #chain == 0 then return "game" end

    local out = string.format('game:GetService("%s")', chain[1].ClassName)
    local startIdx = 2
    if chain[1] == Players and chain[2] == Player then
        out = out .. ".LocalPlayer"
        startIdx = 3
    end
    for i = startIdx, #chain do
        local name = chain[i].Name
        if isIdentifier(name) then
            out = out .. "." .. name
        else
            out = out .. "[" .. quote(name) .. "]"
        end
    end
    return out
end

local serialize
serialize = function(v, depth, seen)
    local t = typeof(v)
    if t == "string" then
        return quote(v)
    elseif t == "number" then
        return fmtNum(v)
    elseif t == "boolean" or t == "nil" then
        return tostring(v)
    elseif t == "Instance" then
        return codePath(v)
    elseif t == "Vector3" then
        return string.format("Vector3.new(%s, %s, %s)", fmtNum(v.X), fmtNum(v.Y), fmtNum(v.Z))
    elseif t == "Vector2" then
        return string.format("Vector2.new(%s, %s)", fmtNum(v.X), fmtNum(v.Y))
    elseif t == "CFrame" then
        local comps = { v:GetComponents() }
        for i = 1, #comps do comps[i] = fmtNum(comps[i]) end
        return "CFrame.new(" .. table.concat(comps, ", ") .. ")"
    elseif t == "Color3" then
        return string.format("Color3.new(%s, %s, %s)", fmtNum(v.R), fmtNum(v.G), fmtNum(v.B))
    elseif t == "UDim2" then
        return string.format("UDim2.new(%s, %s, %s, %s)",
            fmtNum(v.X.Scale), fmtNum(v.X.Offset), fmtNum(v.Y.Scale), fmtNum(v.Y.Offset))
    elseif t == "UDim" then
        return string.format("UDim.new(%s, %s)", fmtNum(v.Scale), fmtNum(v.Offset))
    elseif t == "EnumItem" then
        return tostring(v)
    elseif t == "BrickColor" then
        return "BrickColor.new(" .. quote(v.Name) .. ")"
    elseif t == "function" then
        return "function"
    elseif t == "table" then
        if depth >= CONFIG.MAX_DEPTH then return "{...}" end
        if seen[v] then return "<cycle>" end
        seen[v] = true

        local total = 0
        for _ in pairs(v) do total = total + 1 end
        local n = #v
        local parts, shown = {}, 0

        if n > 0 and total == n then
            for i = 1, n do
                if shown >= CONFIG.MAX_ITEMS then
                    table.insert(parts, "…")
                    break
                end
                table.insert(parts, serialize(v[i], depth + 1, seen))
                shown = shown + 1
            end
        else
            for k, val in pairs(v) do
                if shown >= CONFIG.MAX_ITEMS then
                    table.insert(parts, "…")
                    break
                end
                local keyStr
                if isIdentifier(k) then
                    keyStr = k
                else
                    keyStr = "[" .. serialize(k, depth + 1, seen) .. "]"
                end
                table.insert(parts, keyStr .. " = " .. serialize(val, depth + 1, seen))
                shown = shown + 1
            end
        end
        seen[v] = nil
        if #parts == 0 then return "{}" end
        return "{" .. table.concat(parts, ", ") .. "}"
    end
    return t .. "(" .. tostring(v) .. ")"
end

-- ═══════════════════════════════════════════════════════════════
-- UI: TEMA & HELPER
-- ═══════════════════════════════════════════════════════════════
local C = {
    Accent  = Color3.fromRGB(16, 185, 129),
    Amber   = Color3.fromRGB(245, 158, 11),
    Bg      = Color3.fromRGB(18, 18, 24),
    BgTop   = Color3.fromRGB(22, 22, 30),
    Card    = Color3.fromRGB(26, 26, 36),
    Hover   = Color3.fromRGB(34, 34, 48),
    Code    = Color3.fromRGB(14, 14, 20),
    Text    = Color3.fromRGB(245, 245, 250),
    Muted   = Color3.fromRGB(150, 150, 165),
    Border  = Color3.fromRGB(45, 45, 60),
    Args    = Color3.fromRGB(253, 224, 140),
}

local function new(className, props, parent)
    local inst = Instance.new(className)
    for k, v in pairs(props or {}) do inst[k] = v end
    if parent then inst.Parent = parent end
    return inst
end

local function corner(parent, r)
    return new("UICorner", { CornerRadius = UDim.new(0, r or 6) }, parent)
end

local function stroke(parent, color, thickness)
    return new("UIStroke", { Color = color or C.Border, Thickness = thickness or 1 }, parent)
end

local function mountGui(gui)
    local candidates = {}
    if typeof(gethui) == "function" then
        pcall(function() table.insert(candidates, gethui()) end)
    end
    table.insert(candidates, CoreGui)
    for _, p in ipairs(candidates) do
        local ok = pcall(function() gui.Parent = p end)
        if ok and gui.Parent == p then return end
    end
    gui.Parent = Player:WaitForChild("PlayerGui")
end

local function makeDraggable(handle, target)
    local dragging, moved = false, false
    local dragStart, startPos

    track(handle.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch then
            dragging, moved = true, false
            dragStart, startPos = input.Position, target.Position
            local c
            c = input.Changed:Connect(function()
                if input.UserInputState == Enum.UserInputState.End then
                    dragging = false
                    if c then c:Disconnect() end
                end
            end)
        end
    end))

    track(UserInputService.InputChanged:Connect(function(input)
        if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement
            or input.UserInputType == Enum.UserInputType.Touch) then
            local d = input.Position - dragStart
            if math.abs(d.X) + math.abs(d.Y) > 6 then moved = true end
            target.Position = UDim2.new(
                startPos.X.Scale, startPos.X.Offset + d.X,
                startPos.Y.Scale, startPos.Y.Offset + d.Y
            )
        end
    end))

    return function() return moved end
end

-- ═══════════════════════════════════════════════════════════════
-- UI: WINDOW
-- ═══════════════════════════════════════════════════════════════
local Gui = new("ScreenGui", {
    Name = "Jaya_RemoteSpy",
    ResetOnSpawn = false,
    DisplayOrder = 999,
    ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
})
mountGui(Gui)

local viewW = 800
pcall(function() viewW = workspace.CurrentCamera.ViewportSize.X end)
local WIN_W = math.clamp(viewW - 24, 300, 440)
local WIN_H = 290

local Main = new("Frame", {
    Name = "Main",
    BackgroundColor3 = C.Bg,
    BorderSizePixel = 0,
    AnchorPoint = Vector2.new(0, 0.5),
    Position = UDim2.new(0, 12, 0.5, 0),
    Size = UDim2.fromOffset(WIN_W, WIN_H),
    Parent = Gui,
})
corner(Main, 10)
stroke(Main, C.Border, 1.5)

-- Topbar
local Topbar = new("Frame", {
    BackgroundColor3 = C.BgTop,
    BorderSizePixel = 0,
    Size = UDim2.new(1, 0, 0, 34),
    Parent = Main,
})
corner(Topbar, 10)
new("Frame", {
    BackgroundColor3 = C.BgTop,
    BorderSizePixel = 0,
    Position = UDim2.new(0, 0, 0.5, 0),
    Size = UDim2.new(1, 0, 0.5, 0),
    Parent = Topbar,
})

local badge = new("TextLabel", {
    Font = Enum.Font.GothamBold,
    Text = "SPY",
    TextColor3 = Color3.fromRGB(255, 255, 255),
    TextSize = 10,
    BackgroundColor3 = C.Accent,
    Position = UDim2.new(0, 8, 0.5, -9),
    Size = UDim2.new(0, 32, 0, 18),
    Parent = Topbar,
})
corner(badge, 4)

new("TextLabel", {
    Font = Enum.Font.GothamBold,
    Text = "JAYA REMOTE SPY",
    TextColor3 = C.Text,
    TextSize = 12,
    TextXAlignment = Enum.TextXAlignment.Left,
    BackgroundTransparency = 1,
    Position = UDim2.new(0, 46, 0, 0),
    Size = UDim2.new(0, 120, 1, 0),
    Parent = Topbar,
})

local StatusLabel = new("TextLabel", {
    Font = Enum.Font.Gotham,
    Text = "● REC",
    TextColor3 = C.Accent,
    TextSize = 11,
    TextXAlignment = Enum.TextXAlignment.Left,
    BackgroundTransparency = 1,
    Position = UDim2.new(0, 170, 0, 0),
    Size = UDim2.new(1, -250, 1, 0),
    TextTruncate = Enum.TextTruncate.AtEnd,
    Parent = Topbar,
})

local CloseBtn = new("TextButton", {
    Font = Enum.Font.GothamBold, Text = "✕", TextColor3 = C.Muted, TextSize = 13,
    BackgroundTransparency = 1, AnchorPoint = Vector2.new(1, 0.5),
    Position = UDim2.new(1, -6, 0.5, 0), Size = UDim2.new(0, 28, 0, 28),
    Parent = Topbar,
})
local MinBtn = new("TextButton", {
    Font = Enum.Font.GothamBold, Text = "—", TextColor3 = C.Muted, TextSize = 13,
    BackgroundTransparency = 1, AnchorPoint = Vector2.new(1, 0.5),
    Position = UDim2.new(1, -36, 0.5, 0), Size = UDim2.new(0, 28, 0, 28),
    Parent = Topbar,
})
makeDraggable(Topbar, Main)

-- Ikon mengambang saat di-minimize
local Float = new("TextButton", {
    Name = "Float",
    Font = Enum.Font.GothamBold,
    Text = "SPY",
    TextColor3 = C.Accent,
    TextSize = 13,
    BackgroundColor3 = C.Bg,
    BorderSizePixel = 0,
    AutoButtonColor = false,
    Position = UDim2.new(0, 12, 0.5, -22),
    Size = UDim2.new(0, 44, 0, 44),
    Visible = false,
    Parent = Gui,
})
corner(Float, 22)
stroke(Float, C.Accent, 2)
local floatMoved = makeDraggable(Float, Float)

-- Toolbar
local Toolbar = new("Frame", {
    BackgroundTransparency = 1,
    Position = UDim2.new(0, 8, 0, 40),
    Size = UDim2.new(1, -16, 0, 28),
    Parent = Main,
})
new("UIListLayout", {
    FillDirection = Enum.FillDirection.Horizontal,
    Padding = UDim.new(0, 6),
    SortOrder = Enum.SortOrder.LayoutOrder,
    Parent = Toolbar,
})

local function makeToolButton(text, order)
    local b = new("TextButton", {
        Font = Enum.Font.GothamBold,
        Text = text,
        TextColor3 = C.Text,
        TextSize = 11,
        BackgroundColor3 = C.Hover,
        BorderSizePixel = 0,
        AutoButtonColor = true,
        Size = UDim2.new(0.2, -5, 1, 0),
        LayoutOrder = order,
        Parent = Toolbar,
    })
    corner(b, 5)
    stroke(b, C.Border, 1)
    return b
end

local PauseBtn  = makeToolButton("⏸ Jeda", 1)
local ClearBtn  = makeToolButton("🗑 Hapus", 2)
local CopyAllBtn = makeToolButton("📋 Salin", 3)
local NotifBtn  = makeToolButton("🔔 Notif", 4)
local UnmuteBtn = makeToolButton("🔊 Unmute", 5)

-- Kotak filter
local FilterBox = new("TextBox", {
    Font = Enum.Font.Gotham,
    Text = "",
    PlaceholderText = "Filter: ketik kata (mis. buy, seed, egg)…",
    PlaceholderColor3 = Color3.fromRGB(110, 110, 125),
    TextColor3 = C.Text,
    TextSize = 11.5,
    TextXAlignment = Enum.TextXAlignment.Left,
    ClearTextOnFocus = false,
    BackgroundColor3 = C.Card,
    BorderSizePixel = 0,
    Position = UDim2.new(0, 8, 0, 72),
    Size = UDim2.new(1, -16, 0, 26),
    Parent = Main,
})
corner(FilterBox, 5)
stroke(FilterBox, C.Border, 1)
new("UIPadding", { PaddingLeft = UDim.new(0, 8), PaddingRight = UDim.new(0, 8) }, FilterBox)

-- Area log (terminal)
local Scroll = new("ScrollingFrame", {
    BackgroundColor3 = C.Code,
    BorderSizePixel = 0,
    Position = UDim2.new(0, 8, 0, 104),
    Size = UDim2.new(1, -16, 1, -130),
    CanvasSize = UDim2.new(0, 0, 0, 0),
    AutomaticCanvasSize = Enum.AutomaticSize.Y,
    ScrollingDirection = Enum.ScrollingDirection.Y,
    ScrollBarThickness = 4,
    ScrollBarImageColor3 = Color3.fromRGB(80, 80, 95),
    Parent = Main,
})
corner(Scroll, 6)
stroke(Scroll, C.Border, 1)
new("UIPadding", {
    PaddingTop = UDim.new(0, 4), PaddingBottom = UDim.new(0, 4),
    PaddingLeft = UDim.new(0, 4), PaddingRight = UDim.new(0, 4),
    Parent = Scroll,
})
local ScrollLayout = new("UIListLayout", {
    Padding = UDim.new(0, 4),
    SortOrder = Enum.SortOrder.LayoutOrder,
    Parent = Scroll,
})

-- Auto-scroll ke bawah jika user sedang berada di dasar
local lastContentY = 0
track(ScrollLayout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(function()
    local newY = ScrollLayout.AbsoluteContentSize.Y
    local viewH = Scroll.AbsoluteSize.Y
    local wasAtBottom = (lastContentY - (Scroll.CanvasPosition.Y + viewH)) <= 40
    lastContentY = newY
    if wasAtBottom then
        Scroll.CanvasPosition = Vector2.new(0, math.max(0, newY - viewH + 8))
    end
end))

local Footer = new("TextLabel", {
    Font = Enum.Font.Gotham,
    Text = "",
    TextColor3 = C.Muted,
    TextSize = 10.5,
    TextXAlignment = Enum.TextXAlignment.Left,
    BackgroundTransparency = 1,
    AnchorPoint = Vector2.new(0, 1),
    Position = UDim2.new(0, 10, 1, -4),
    Size = UDim2.new(1, -20, 0, 18),
    Parent = Main,
})

-- ═══════════════════════════════════════════════════════════════
-- UI: NOTIFIKASI (TOAST)
-- ═══════════════════════════════════════════════════════════════
local ToastHolder = new("Frame", {
    Name = "Toasts",
    BackgroundTransparency = 1,
    AnchorPoint = Vector2.new(1, 0),
    Position = UDim2.new(1, -12, 0, 12),
    Size = UDim2.new(0, 300, 1, -24),
    Parent = Gui,
})
new("UIListLayout", {
    Padding = UDim.new(0, 6),
    HorizontalAlignment = Enum.HorizontalAlignment.Right,
    SortOrder = Enum.SortOrder.LayoutOrder,
    Parent = ToastHolder,
})

local activeToasts = {}
local toastOrder = 0

local function fadeDestroy(frame)
    pcall(function()
        local info = TweenInfo.new(0.35)
        for _, d in ipairs(frame:GetDescendants()) do
            if d:IsA("TextLabel") then
                TweenService:Create(d, info, { TextTransparency = 1 }):Play()
            elseif d:IsA("UIStroke") then
                TweenService:Create(d, info, { Transparency = 1 }):Play()
            end
        end
        TweenService:Create(frame, info, { BackgroundTransparency = 1 }):Play()
    end)
    task.delay(0.4, function() pcall(function() frame:Destroy() end) end)
end

local function toast(title, pathText, argsText, highlight, force)
    if not State.Active or (not State.Notif and not force) then return end

    toastOrder = toastOrder + 1
    local f = new("Frame", {
        BackgroundColor3 = C.Card,
        BorderSizePixel = 0,
        Size = UDim2.new(1, 0, 0, 58),
        LayoutOrder = -toastOrder, -- terbaru di atas
        Parent = ToastHolder,
    })
    corner(f, 8)
    stroke(f, highlight and C.Accent or C.Border, highlight and 1.6 or 1)

    new("TextLabel", {
        Font = Enum.Font.GothamBold,
        Text = "📡 " .. title,
        TextColor3 = highlight and C.Accent or C.Text,
        TextSize = 12.5,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextTruncate = Enum.TextTruncate.AtEnd,
        BackgroundTransparency = 1,
        Position = UDim2.new(0, 10, 0, 4),
        Size = UDim2.new(1, -20, 0, 16),
        Parent = f,
    })
    new("TextLabel", {
        Font = Enum.Font.Gotham,
        Text = pathText,
        TextColor3 = C.Muted,
        TextSize = 10,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextTruncate = Enum.TextTruncate.AtEnd,
        BackgroundTransparency = 1,
        Position = UDim2.new(0, 10, 0, 21),
        Size = UDim2.new(1, -20, 0, 13),
        Parent = f,
    })
    new("TextLabel", {
        Font = Enum.Font.Code,
        Text = argsText,
        TextColor3 = C.Args,
        TextSize = 11.5,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextTruncate = Enum.TextTruncate.AtEnd,
        BackgroundTransparency = 1,
        Position = UDim2.new(0, 10, 0, 36),
        Size = UDim2.new(1, -20, 0, 16),
        Parent = f,
    })

    table.insert(activeToasts, f)
    while #activeToasts > CONFIG.TOAST_MAX do
        local old = table.remove(activeToasts, 1)
        pcall(function() old:Destroy() end)
    end

    task.delay(CONFIG.TOAST_TIME, function()
        if f and f.Parent then fadeDestroy(f) end
    end)
end

-- ═══════════════════════════════════════════════════════════════
-- UI: BARIS LOG
-- ═══════════════════════════════════════════════════════════════
local Entries = {}
local entryOrder = 0

local function copyText(text)
    if typeof(clipboardFn) == "function" then
        local ok = pcall(clipboardFn, text)
        if ok then
            toast("Disalin", "Teks sudah ada di clipboard", #text .. " karakter", false, true)
            return true
        end
    end
    if typeof(writefile) == "function" then
        local ok = pcall(writefile, "jaya_remote_spy_log.txt", text)
        if ok then
            toast("Disimpan ke file", "workspace/jaya_remote_spy_log.txt",
                "Executor tidak punya clipboard", false, true)
            return true
        end
    end
    toast("Gagal menyalin", "Executor tidak mendukung clipboard/writefile", "", false, true)
    print(text)
    return false
end

local function updateFooter()
    Footer.Text = string.format(
        "Terekam %d   •   Di-mute %d   •   Dibuang %d   •   Baris %d",
        State.Total, State.MutedCount, State.Dropped, #Entries
    )
end

local function isVisible(rec)
    if rec.system then return true end
    if State.Muted[rec.remote] then return false end
    if State.Filter ~= "" and not rec.search:find(State.Filter, 1, true) then
        return false
    end
    return true
end

local function applyFilter()
    for _, rec in ipairs(Entries) do
        rec.frame.Visible = isVisible(rec)
    end
end

local function renderHead(rec)
    local tag, color = "EVENT", "#34d399"
    if rec.class == "RemoteFunction" then
        tag, color = "FUNC", "#60a5fa"
    elseif rec.class == "UnreliableRemoteEvent" then
        tag, color = "UEVENT", "#c084fc"
    end
    local star = rec.highlight and ' <font color="#facc15">★</font>' or ""
    local cnt = rec.count > 1 and (' <font color="#facc15">×' .. rec.count .. "</font>") or ""
    rec.head.Text = string.format(
        '<font color="#8b8b9a">%s</font>  <b><font color="%s">%s</font></b>%s%s',
        rec.time, color, tag, star, cnt
    )
end

local function pruneEntries()
    while #Entries > CONFIG.MAX_ENTRIES do
        local old = table.remove(Entries, 1)
        pcall(function() old.frame:Destroy() end)
    end
end

local function smallButton(text, parent, xOffset)
    local b = new("TextButton", {
        Font = Enum.Font.GothamBold,
        Text = text,
        TextColor3 = C.Text,
        TextSize = 10.5,
        BackgroundColor3 = C.Hover,
        BorderSizePixel = 0,
        AnchorPoint = Vector2.new(1, 0.5),
        Position = UDim2.new(1, xOffset, 0.5, 0),
        Size = UDim2.new(0, 46, 0, 20),
        Parent = parent,
    })
    corner(b, 4)
    return b
end

local function setMuteButtonText()
    UnmuteBtn.TextColor3 = (State.MutedCount > 0) and C.Amber or C.Muted
end

local function muteRemote(remote)
    if State.Muted[remote] then return end
    State.Muted[remote] = true
    State.MutedCount = State.MutedCount + 1
    setMuteButtonText()
    applyFilter()
    updateFooter()
end

local addSystem -- forward declaration

local function addEntry(data)
    entryOrder = entryOrder + 1

    local frame = new("Frame", {
        BackgroundColor3 = C.Card,
        BorderSizePixel = 0,
        Size = UDim2.new(1, -6, 0, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        LayoutOrder = entryOrder,
        Parent = Scroll,
    })
    corner(frame, 5)
    stroke(frame, data.highlight and C.Accent or C.Border, 1)
    new("UIPadding", {
        PaddingTop = UDim.new(0, 5), PaddingBottom = UDim.new(0, 5),
        PaddingLeft = UDim.new(0, 7), PaddingRight = UDim.new(0, 7),
        Parent = frame,
    })
    new("UIListLayout", {
        Padding = UDim.new(0, 3),
        SortOrder = Enum.SortOrder.LayoutOrder,
        Parent = frame,
    })

    -- Baris 1: waktu, tipe, jumlah, tombol Salin & Mute
    local row1 = new("Frame", {
        BackgroundTransparency = 1,
        Size = UDim2.new(1, 0, 0, 20),
        LayoutOrder = 1,
        Parent = frame,
    })
    local head = new("TextLabel", {
        Font = Enum.Font.Gotham,
        RichText = true,
        Text = "",
        TextColor3 = C.Text,
        TextSize = 11,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextTruncate = Enum.TextTruncate.AtEnd,
        BackgroundTransparency = 1,
        Size = UDim2.new(1, -100, 1, 0),
        Parent = row1,
    })
    local muteBtn = smallButton("Mute", row1, 0)
    local copyBtn = smallButton("Salin", row1, -50)

    -- Baris 2: nama remote (path lengkap)
    new("TextLabel", {
        Font = Enum.Font.GothamBold,
        Text = data.path,
        TextColor3 = data.highlight and C.Accent or C.Text,
        TextSize = 12,
        TextWrapped = true,
        TextXAlignment = Enum.TextXAlignment.Left,
        BackgroundTransparency = 1,
        Size = UDim2.new(1, 0, 0, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        LayoutOrder = 2,
        Parent = frame,
    })

    -- Baris 3: argumen
    local argsLbl = new("TextLabel", {
        Font = Enum.Font.Code,
        Text = data.args,
        TextColor3 = C.Args,
        TextSize = 12,
        TextWrapped = true,
        TextXAlignment = Enum.TextXAlignment.Left,
        BackgroundColor3 = C.Code,
        BorderSizePixel = 0,
        Size = UDim2.new(1, 0, 0, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        LayoutOrder = 3,
        Parent = frame,
    })
    corner(argsLbl, 4)
    new("UIPadding", {
        PaddingTop = UDim.new(0, 3), PaddingBottom = UDim.new(0, 3),
        PaddingLeft = UDim.new(0, 5), PaddingRight = UDim.new(0, 5),
        Parent = argsLbl,
    })

    -- Baris 4 (opsional): script pemanggil
    if data.caller then
        new("TextLabel", {
            Font = Enum.Font.Gotham,
            Text = "↳ dari script: " .. data.caller,
            TextColor3 = C.Muted,
            TextSize = 10,
            TextWrapped = true,
            TextXAlignment = Enum.TextXAlignment.Left,
            BackgroundTransparency = 1,
            Size = UDim2.new(1, 0, 0, 0),
            AutomaticSize = Enum.AutomaticSize.Y,
            LayoutOrder = 4,
            Parent = frame,
        })
    end

    local rec = {
        frame = frame, head = head, remote = data.remote, class = data.class,
        time = data.time, count = 1, highlight = data.highlight, sig = data.sig,
        path = data.path, args = data.args, code = data.code, caller = data.caller,
        lastToast = os.clock(),
        search = (data.path .. " " .. data.args .. " " .. (data.caller or "")):lower(),
    }
    renderHead(rec)

    copyBtn.Activated:Connect(function()
        copyText(rec.code)
    end)
    muteBtn.Activated:Connect(function()
        muteRemote(rec.remote)
        addSystem("Di-mute: " .. rec.path .. "  (tekan 🔊 Unmute untuk mengaktifkan lagi)")
    end)

    table.insert(Entries, rec)
    rec.frame.Visible = isVisible(rec)
    pruneEntries()
    updateFooter()
    return rec
end

addSystem = function(text)
    entryOrder = entryOrder + 1
    local lbl = new("TextLabel", {
        Font = Enum.Font.Gotham,
        Text = "• " .. text,
        TextColor3 = C.Muted,
        TextSize = 11,
        TextWrapped = true,
        TextXAlignment = Enum.TextXAlignment.Left,
        BackgroundTransparency = 1,
        Size = UDim2.new(1, -6, 0, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        LayoutOrder = entryOrder,
        Parent = Scroll,
    })
    table.insert(Entries, { frame = lbl, system = true })
    pruneEntries()
    updateFooter()
end

-- ═══════════════════════════════════════════════════════════════
-- ANTREAN & PEMROSES PANGGILAN REMOTE
-- (hook hanya menaruh data ke antrean; semua kerja berat di sini)
-- ═══════════════════════════════════════════════════════════════
local Queue, qHead, qTail = {}, 1, 0

local function push(item)
    if qTail - qHead + 1 >= CONFIG.MAX_QUEUE then
        Queue[qHead] = nil
        qHead = qHead + 1
        State.Dropped = State.Dropped + 1
    end
    qTail = qTail + 1
    Queue[qTail] = item
end

local RateInfo = setmetatable({}, { __mode = "k" })

local function pathOf(inst)
    local ok, p = pcall(function() return inst:GetFullName() end)
    if ok and p then return p end
    return tostring(inst)
end

local function handleItem(item)
    local remote = item.remote
    if State.Muted[remote] then return end

    -- Deteksi spam: remote yang menembak terlalu sering di-mute otomatis
    local now = os.clock()
    local r = RateInfo[remote]
    if not r or now - r.t > 1 then
        r = { t = now, n = 0 }
        RateInfo[remote] = r
    end
    r.n = r.n + 1
    if r.n > CONFIG.AUTO_MUTE_PER_SEC then
        muteRemote(remote)
        addSystem("Auto-mute (spam > " .. CONFIG.AUTO_MUTE_PER_SEC .. "/detik): " .. pathOf(remote))
        return
    end

    State.Total = State.Total + 1

    local path = pathOf(remote)
    local okCP, cpath = pcall(codePath, remote)
    if not okCP then cpath = "nil --[[ gagal membuat path ]]" end

    local parts = {}
    for i = 1, item.args.n do
        local ok, s = pcall(serialize, item.args[i], 0, {})
        parts[i] = ok and s or ("<gagal: " .. tostring(s) .. ">")
    end
    local joined = table.concat(parts, ", ")
    local argsStr = "[" .. joined .. "]"
    local code = cpath .. ":" .. item.method .. "(" .. joined .. ")"
    local sig = item.method .. "|" .. path .. "|" .. argsStr

    -- Panggilan identik beruntun digabung (×N) agar terminal tidak banjir
    local last = Entries[#Entries]
    if last and not last.system and last.sig == sig then
        last.count = last.count + 1
        renderHead(last)
        if now - last.lastToast > CONFIG.TOAST_REPEAT_GAP then
            last.lastToast = now
            toast(remote.Name .. " ×" .. last.count, path, argsStr, last.highlight)
        end
        updateFooter()
        return
    end

    local callerPath
    if item.caller then
        local ok, p = pcall(function() return item.caller:GetFullName() end)
        callerPath = ok and p or tostring(item.caller)
    end

    local lower = (path .. " " .. argsStr):lower()
    local highlight = false
    for _, kw in ipairs(CONFIG.HIGHLIGHT_KEYWORDS) do
        if lower:find(kw, 1, true) then
            highlight = true
            break
        end
    end

    local rec = addEntry({
        remote = remote,
        class = item.class,
        time = item.time,
        path = path,
        args = argsStr,
        code = code,
        caller = callerPath,
        highlight = highlight,
        sig = sig,
    })
    toast(remote.Name, path, argsStr, highlight)
    rec.lastToast = now

    print(string.format("[JAYA SPY] %s\n    args: %s\n    code: %s", path, argsStr, code))
end

track(RunService.Heartbeat:Connect(function()
    if not State.Active then return end
    local processed = 0
    while qHead <= qTail and processed < CONFIG.MAX_PER_FRAME do
        local item = Queue[qHead]
        Queue[qHead] = nil
        qHead = qHead + 1
        processed = processed + 1
        local ok, err = pcall(handleItem, item)
        if not ok then
            warn("[JAYA SPY] gagal memproses panggilan:", err)
        end
    end
end))

-- ═══════════════════════════════════════════════════════════════
-- HOOK: MENANGKAP FireServer / InvokeServer
-- ═══════════════════════════════════════════════════════════════
local function capture(remote, method, ...)
    local caller
    if getCaller then
        local ok, scr = pcall(getCaller)
        if ok then caller = scr end
    end
    push({
        remote = remote,
        class = remote.ClassName,
        method = CALL_METHODS[method] or method,
        args = table.pack(...),
        time = os.date("%H:%M:%S"),
        caller = caller,
    })
end

local function installNamecallHook()
    if typeof(hookmetamethod) ~= "function" or typeof(getnamecallmethod) ~= "function" then
        return false, "hookmetamethod/getnamecallmethod tidak tersedia"
    end
    local old
    local ok, err = pcall(function()
        old = hookmetamethod(game, "__namecall", ncc(function(self, ...)
            local method = getnamecallmethod()
            if State.Active and not State.Paused and CALL_METHODS[method]
                and typeof(self) == "Instance" and REMOTE_CLASSES[self.ClassName]
                and not State.Muted[self]
                and (CONFIG.LOG_EXECUTOR_CALLS or not isExecutor()) then
                pcall(capture, self, method, ...)
                if typeof(setnamecallmethod) == "function" then
                    setnamecallmethod(method)
                end
            end
            return old(self, ...)
        end))
    end)
    if not ok then return false, tostring(err) end
    return true
end

local function installFunctionHooks()
    if typeof(hookfunction) ~= "function" then
        return 0, "hookfunction tidak tersedia"
    end
    local installed = 0
    local defs = {
        { "RemoteEvent", "FireServer" },
        { "RemoteFunction", "InvokeServer" },
        { "UnreliableRemoteEvent", "FireServer" },
    }
    for _, def in ipairs(defs) do
        local className, methodName = def[1], def[2]
        local ok = pcall(function()
            local probe = Instance.new(className)
            local fn = probe[methodName]
            probe:Destroy()
            local old
            old = hookfunction(fn, ncc(function(self, ...)
                if State.Active and not State.Paused and typeof(self) == "Instance"
                    and not State.Muted[self]
                    and (CONFIG.LOG_EXECUTOR_CALLS or not isExecutor()) then
                    pcall(capture, self, methodName, ...)
                end
                return old(self, ...)
            end))
        end)
        if ok then installed = installed + 1 end
    end
    return installed
end

local okNC, errNC = installNamecallHook()
if okNC then
    State.HookMode = "namecall"
else
    local n, errFn = installFunctionHooks()
    if n > 0 then
        State.HookMode = "function (" .. n .. ")"
    else
        State.HookMode = "TIDAK DIDUKUNG"
        warn("[JAYA SPY] Hook gagal:", errNC, "|", errFn)
    end
end

-- ═══════════════════════════════════════════════════════════════
-- KONTROL UI
-- ═══════════════════════════════════════════════════════════════
local function refreshStatus()
    if State.HookMode == "TIDAK DIDUKUNG" then
        StatusLabel.Text = "● Hook gagal: executor tidak mendukung"
        StatusLabel.TextColor3 = Color3.fromRGB(239, 68, 68)
    elseif State.Paused then
        StatusLabel.Text = "● JEDA · " .. State.HookMode
        StatusLabel.TextColor3 = C.Amber
    else
        StatusLabel.Text = "● REC · " .. State.HookMode
        StatusLabel.TextColor3 = C.Accent
    end
    PauseBtn.Text = State.Paused and "▶ Lanjut" or "⏸ Jeda"
    PauseBtn.BackgroundColor3 = State.Paused and C.Amber or C.Hover
    NotifBtn.BackgroundColor3 = State.Notif and C.Accent or C.Hover
    NotifBtn.TextColor3 = State.Notif and Color3.fromRGB(255, 255, 255) or C.Muted
    setMuteButtonText()
end

PauseBtn.Activated:Connect(function()
    State.Paused = not State.Paused
    refreshStatus()
end)

ClearBtn.Activated:Connect(function()
    for _, rec in ipairs(Entries) do
        pcall(function() rec.frame:Destroy() end)
    end
    Entries = {}
    State.Total = 0
    updateFooter()
end)

CopyAllBtn.Activated:Connect(function()
    local lines = {}
    for _, rec in ipairs(Entries) do
        if not rec.system and isVisible(rec) then
            table.insert(lines, string.format("[%s] %s%s\n    args: %s\n    code: %s",
                rec.time, rec.path, rec.count > 1 and (" ×" .. rec.count) or "", rec.args, rec.code))
        end
    end
    if #lines == 0 then
        toast("Tidak ada data", "Belum ada panggilan yang tercatat", "", false, true)
        return
    end
    copyText(table.concat(lines, "\n\n"))
end)

NotifBtn.Activated:Connect(function()
    State.Notif = not State.Notif
    refreshStatus()
end)

UnmuteBtn.Activated:Connect(function()
    State.Muted = {}
    State.MutedCount = 0
    RateInfo = setmetatable({}, { __mode = "k" })
    refreshStatus()
    applyFilter()
    updateFooter()
    addSystem("Semua remote di-unmute.")
end)

track(FilterBox:GetPropertyChangedSignal("Text"):Connect(function()
    State.Filter = FilterBox.Text:lower():gsub("^%s+", ""):gsub("%s+$", "")
    applyFilter()
end))

MinBtn.Activated:Connect(function()
    Main.Visible = false
    Float.Visible = true
end)

Float.Activated:Connect(function()
    if floatMoved() then return end
    Main.Visible = true
    Float.Visible = false
end)

local function Shutdown()
    if not State.Active then return end
    State.Active = false
    for _, c in ipairs(State.Connections) do
        pcall(function() c:Disconnect() end)
    end
    State.Connections = {}
    pcall(function() Gui:Destroy() end)
    env.JAYA_SPY_CLEANUP = nil
    print("[JAYA SPY] Dimatikan. (Hook tetap terpasang tetapi tidak lagi merekam.)")
end

CloseBtn.Activated:Connect(Shutdown)
env.JAYA_SPY_CLEANUP = Shutdown

-- ═══════════════════════════════════════════════════════════════
-- MULAI
-- ═══════════════════════════════════════════════════════════════
refreshStatus()
updateFooter()
if State.HookMode == "TIDAK DIDUKUNG" then
    addSystem("Executor ini tidak mendukung hookmetamethod/hookfunction, jadi remote tidak bisa direkam. Coba executor lain (mis. Delta atau Codex versi terbaru).")
else
    addSystem("Siap merekam (mode hook: " .. State.HookMode .. "). Sekarang beli 1 benih secara manual di toko — nama remote & argumennya akan muncul di sini.")
    addSystem("Baris bertanda ★ = kemungkinan besar remote pembelian. Gunakan Mute jika ada remote yang terlalu berisik.")
    toast("JAYA REMOTE SPY", "Mode hook: " .. State.HookMode, "Siap merekam…", true)
end
