-- The look of the TrialChat window: colors, fonts, and the rounded boxes,
-- icons, buttons and fields it's built from. Shapes and icons are the
-- addon's own white textures in Media, tinted in game.
TrialChatUI = {}
local UI = TrialChatUI

local MEDIA = "Interface\\AddOns\\TrialChat\\Media\\"
local WHITE = "Interface\\Buttons\\WHITE8X8"
UI.WHITE = WHITE

local function hexColor(hex)
    return {
        tonumber(string.sub(hex, 1, 2), 16) / 255,
        tonumber(string.sub(hex, 3, 4), 16) / 255,
        tonumber(string.sub(hex, 5, 6), 16) / 255,
        hex = hex,
    }
end

UI.Color = {
    window = hexColor("121418"),
    sidebar = hexColor("0d0f12"),
    panel = hexColor("0f1114"),
    line = hexColor("23272e"),
    outline = hexColor("2a2f36"),
    field = hexColor("171a1f"),
    fieldBorder = hexColor("2c3138"),
    fieldFocus = hexColor("4a505a"),
    hover = hexColor("1b1f25"),
    pressed = hexColor("23282f"),
    pressedBorder = hexColor("3a3f47"),
    selected = hexColor("1e232a"),
    divider = hexColor("262b32"),
    dashed = hexColor("343a42"),
    text = hexColor("e6e2d6"),
    textSoft = hexColor("d6d0bd"),
    muted = hexColor("8b929b"),
    white = hexColor("ffffff"),
    black = hexColor("000000"),
    accent = hexColor("70A2FF"),
    accentHover = hexColor("8ab4ff"),
    accentText = hexColor("0a1020"),
    accentFaint = hexColor("1a243a"),
    online = hexColor("5ccf7a"),
    offline = hexColor("5d636b"),
    emote = hexColor("ff7d0a"),
    error = hexColor("ff5c5c"),
    errorFaint = hexColor("3a1d1d"),
    errorText = hexColor("1a0a0a"),
    avatar = hexColor("13171c"),
    tile = hexColor("1f2329"),
    tileOffline = hexColor("1a1d22"),
}
local Color = UI.Color

-- Group tiles get one of these (background, letters) by their name.
UI.TileColors = {
    { hexColor("2a2134"), hexColor("c9a3ff") },
    { hexColor("1f2a24"), hexColor("8fd6a6") },
    { hexColor("1d2634"), hexColor("8fb8ff") },
    { hexColor("33221d"), hexColor("ffb08f") },
    { hexColor("1b2c2c"), hexColor("7ad9cb") },
    { hexColor("2e2716"), hexColor("e8c46a") },
    { hexColor("321d27"), hexColor("ff9ac4") },
}

local classColors = {}

function UI.ClassColor(classFile)
    local classColor = classFile and RAID_CLASS_COLORS[classFile]
    if not classColor then return nil end
    if not classColors[classFile] then
        classColors[classFile] = {
            classColor.r, classColor.g, classColor.b,
            hex = string.format("%02x%02x%02x",
                math.floor(classColor.r * 255 + 0.5),
                math.floor(classColor.g * 255 + 0.5),
                math.floor(classColor.b * 255 + 0.5)),
        }
    end
    return classColors[classFile]
end

function UI.ColorText(color, text)
    return "|cff" .. color.hex .. text .. "|r"
end

function UI.Tint(region, color, alpha)
    region:SetVertexColor(color[1], color[2], color[3], alpha or 1)
end

function UI.SetTextColor(fontString, color, alpha)
    fontString:SetTextColor(color[1], color[2], color[3], alpha or 1)
end

-- Text uses the game's fonts for the player's language: the interface font
-- for the window itself and the chat font for messages.
local function getFontFile(fontObject, fallback)
    if fontObject and fontObject.GetFont then
        local file = fontObject:GetFont()
        if file then return file end
    end
    return fallback
end

local CHAT_FONT = getFontFile(ChatFontNormal, "Fonts\\ARIALN.TTF")
local INTERFACE_FONT = STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF"

local function createFont(name, file, size)
    local font = CreateFont(name)
    font:SetFont(file, size, "")
    font:SetShadowColor(0, 0, 0, 0.6)
    font:SetShadowOffset(1, -1)
    return font
end

UI.Font = {
    title = createFont("TrialChatFontTitle", INTERFACE_FONT, 16),
    heading = createFont("TrialChatFontHeading", INTERFACE_FONT, 15),
    item = createFont("TrialChatFontItem", INTERFACE_FONT, 12),
    small = createFont("TrialChatFontSmall", INTERFACE_FONT, 11),
    label = createFont("TrialChatFontLabel", INTERFACE_FONT, 10),
    name = createFont("TrialChatFontName", INTERFACE_FONT, 13),
    initials = createFont("TrialChatFontInitials", INTERFACE_FONT, 13),
    body = createFont("TrialChatFontBody", CHAT_FONT, 14),
    time = createFont("TrialChatFontTime", CHAT_FONT, 11),
}

function UI.CreateText(parent, font, color, layer)
    local text = parent:CreateFontString(nil, layer or "ARTWORK")
    text:SetFontObject(font)
    UI.SetTextColor(text, color or Color.text)
    return text
end

-- The first letter of a name, which can take more than one byte.
function UI.FirstLetter(name)
    return string.match(name or "", "^[%z\1-\127\194-\244][\128-\191]*") or "?"
end

---------------------------------------------------------------------------
-- Rounded boxes: four corner pieces cut from a circle and three strips
-- that don't overlap, so they blend the same as one texture when faded.
---------------------------------------------------------------------------
local CORNER_COORDS = {
    TOPLEFT = { 0, 0.5, 0, 0.5 },
    TOPRIGHT = { 0.5, 1, 0, 0.5 },
    BOTTOMLEFT = { 0, 0.5, 0.5, 1 },
    BOTTOMRIGHT = { 0.5, 1, 0.5, 1 },
}
local ALL_CORNERS = { TOPLEFT = true, TOPRIGHT = true, BOTTOMLEFT = true, BOTTOMRIGHT = true }
UI.ALL_CORNERS = ALL_CORNERS

-- A 1 px outline needs a ring as thin as 1 px at the corner's size.
local RING_TEXTURES = { [13] = "ring-13.tga", [19] = "ring-19.tga" }

local Box = {}
Box.__index = Box

local function addPart(box, layer, subLevel, texture)
    local part = box.owner:CreateTexture(nil, layer, nil, subLevel)
    part:SetTexture(texture or WHITE)
    box.parts[#box.parts + 1] = part
    return part
end

-- options: radius, corners (which are rounded), layer, subLevel, region (to
-- cover instead of the owner), border (a 1 px outline; all corners rounded).
function UI.CreateBox(owner, options)
    options = options or {}
    local radius = options.radius or 8
    local layer = options.layer or "BACKGROUND"
    local subLevel = options.subLevel or 0
    local region = options.region or owner
    local box = setmetatable({
        owner = owner, parts = {}, fill = {}, corners = {}, borderParts = {},
        color = Color.field, alpha = 1, shown = true,
    }, Box)

    for point in pairs(CORNER_COORDS) do
        local corner = addPart(box, layer, subLevel)
        corner:SetSize(radius, radius)
        corner:SetPoint(point, region, point)
        box.corners[point] = corner
        box.fill[#box.fill + 1] = corner
    end
    local top = addPart(box, layer, subLevel)
    top:SetPoint("TOPLEFT", region, "TOPLEFT", radius, 0)
    top:SetPoint("BOTTOMRIGHT", region, "TOPRIGHT", -radius, -radius)
    local bottom = addPart(box, layer, subLevel)
    bottom:SetPoint("TOPLEFT", region, "BOTTOMLEFT", radius, radius)
    bottom:SetPoint("BOTTOMRIGHT", region, "BOTTOMRIGHT", -radius, 0)
    local middle = addPart(box, layer, subLevel)
    middle:SetPoint("TOPLEFT", region, "TOPLEFT", 0, -radius)
    middle:SetPoint("BOTTOMRIGHT", region, "BOTTOMRIGHT", 0, radius)
    box.fill[#box.fill + 1] = top
    box.fill[#box.fill + 1] = bottom
    box.fill[#box.fill + 1] = middle

    if options.border then
        local corners = options.corners or ALL_CORNERS
        for point, coords in pairs(CORNER_COORDS) do
            if corners[point] then
                local ring = addPart(box, layer, subLevel + 1, MEDIA .. (RING_TEXTURES[radius] or "ring.tga"))
                ring:SetTexCoord(coords[1], coords[2], coords[3], coords[4])
                ring:SetSize(radius, radius)
                ring:SetPoint(point, region, point)
                box.borderParts[#box.borderParts + 1] = ring
            end
        end
        local edges = {}
        local c = options.corners or ALL_CORNERS
        -- Top edge
        if c.TOPLEFT and c.TOPRIGHT then
            edges[#edges + 1] = { "TOPLEFT", radius, 0, "TOPRIGHT", -radius, 0, nil, 1 }
        elseif c.TOPLEFT and not c.TOPRIGHT then
            edges[#edges + 1] = { "TOPLEFT", radius, 0, "TOPRIGHT", 0, 0, nil, 1 }
        elseif not c.TOPLEFT and c.TOPRIGHT then
            edges[#edges + 1] = { "TOPLEFT", 0, 0, "TOPRIGHT", -radius, 0, nil, 1 }
        else
            edges[#edges + 1] = { "TOPLEFT", 0, 0, "TOPRIGHT", 0, 0, nil, 1 }
        end
        -- Bottom edge
        if c.BOTTOMLEFT and c.BOTTOMRIGHT then
            edges[#edges + 1] = { "BOTTOMLEFT", radius, 0, "BOTTOMRIGHT", -radius, 0, nil, 1 }
        elseif c.BOTTOMLEFT and not c.BOTTOMRIGHT then
            edges[#edges + 1] = { "BOTTOMLEFT", radius, 0, "BOTTOMRIGHT", 0, 0, nil, 1 }
        elseif not c.BOTTOMLEFT and c.BOTTOMRIGHT then
            edges[#edges + 1] = { "BOTTOMLEFT", 0, 0, "BOTTOMRIGHT", -radius, 0, nil, 1 }
        else
            edges[#edges + 1] = { "BOTTOMLEFT", 0, 0, "BOTTOMRIGHT", 0, 0, nil, 1 }
        end
        -- Left edge
        if c.TOPLEFT and c.BOTTOMLEFT then
            edges[#edges + 1] = { "TOPLEFT", 0, -radius, "BOTTOMLEFT", 0, radius, 1, nil }
        elseif c.TOPLEFT and not c.BOTTOMLEFT then
            edges[#edges + 1] = { "TOPLEFT", 0, -radius, "BOTTOMLEFT", 0, 0, 1, nil }
        elseif not c.TOPLEFT and c.BOTTOMLEFT then
            edges[#edges + 1] = { "TOPLEFT", 0, 0, "BOTTOMLEFT", 0, radius, 1, nil }
        else
            edges[#edges + 1] = { "TOPLEFT", 0, 0, "BOTTOMLEFT", 0, 0, 1, nil }
        end
        -- Right edge
        if c.TOPRIGHT and c.BOTTOMRIGHT then
            edges[#edges + 1] = { "TOPRIGHT", 0, -radius, "BOTTOMRIGHT", 0, radius, 1, nil }
        elseif c.TOPRIGHT and not c.BOTTOMRIGHT then
            edges[#edges + 1] = { "TOPRIGHT", 0, -radius, "BOTTOMRIGHT", 0, 0, 1, nil }
        elseif not c.TOPRIGHT and c.BOTTOMRIGHT then
            edges[#edges + 1] = { "TOPRIGHT", 0, 0, "BOTTOMRIGHT", 0, radius, 1, nil }
        else
            edges[#edges + 1] = { "TOPRIGHT", 0, 0, "BOTTOMRIGHT", 0, 0, 1, nil }
        end
        for _, edge in ipairs(edges) do
            local line = addPart(box, layer, subLevel + 1)
            line:SetPoint(edge[1], region, edge[1], edge[2], edge[3])
            line:SetPoint(edge[4], region, edge[4], edge[5], edge[6])
            if edge[7] then line:SetWidth(edge[7]) end
            if edge[8] then line:SetHeight(edge[8]) end
            box.borderParts[#box.borderParts + 1] = line
        end
        box:SetBorderColor(Color.fieldBorder)
    end

    box:SetCorners(options.corners or ALL_CORNERS)
    return box
end

function Box:SetCorners(corners)
    for point, corner in pairs(self.corners) do
        if corners[point] then
            local coords = CORNER_COORDS[point]
            corner:SetTexture(MEDIA .. "disc.tga")
            corner:SetTexCoord(coords[1], coords[2], coords[3], coords[4])
        else
            corner:SetTexture(WHITE)
            corner:SetTexCoord(0, 1, 0, 1)
        end
    end
    self:SetColor(self.color, self.alpha)
end

function Box:SetColor(color, alpha)
    self.color, self.alpha = color, alpha or 1
    for _, part in ipairs(self.fill) do
        UI.Tint(part, color, self.alpha)
    end
end

function Box:SetBorderColor(color, alpha)
    self.borderColor = color
    for _, part in ipairs(self.borderParts) do
        UI.Tint(part, color, alpha)
    end
end

function Box:SetShown(shown)
    self.shown = shown and true or false
    for _, part in ipairs(self.parts) do
        part:SetShown(self.shown)
    end
end

function Box:Show() self:SetShown(true) end
function Box:Hide() self:SetShown(false) end

local DASH_LENGTH = 4
local DASH_GAP = 3

-- A dashed 1 px outline with rounded corners, laid out again on resize.
local function layoutDashes(owner)
    local dashes = owner.dashes
    local width, height = owner:GetSize()
    local count = 0
    local function dash(point, x, y, dashWidth, dashHeight)
        count = count + 1
        local texture = dashes.parts[count]
        if not texture then
            texture = owner:CreateTexture(nil, "BORDER")
            texture:SetTexture(WHITE)
            dashes.parts[count] = texture
        end
        texture:ClearAllPoints()
        texture:SetPoint(point, owner, point, x, y)
        texture:SetSize(dashWidth, dashHeight)
        UI.Tint(texture, dashes.color)
        texture:Show()
    end

    local radius = dashes.radius
    for x = radius + 2, width - radius - DASH_LENGTH, DASH_LENGTH + DASH_GAP do
        dash("TOPLEFT", x, 0, DASH_LENGTH, 1)
        dash("BOTTOMLEFT", x, 0, DASH_LENGTH, 1)
    end
    for y = radius + 2, height - radius - DASH_LENGTH, DASH_LENGTH + DASH_GAP do
        dash("TOPLEFT", 0, -y, 1, DASH_LENGTH)
        dash("TOPRIGHT", 0, -y, 1, DASH_LENGTH)
    end
    for index = count + 1, #dashes.parts do
        dashes.parts[index]:Hide()
    end
end

function UI.AddDashedOutline(owner, radius, color)
    owner.dashes = { parts = {}, radius = radius, color = color }
    for point, coords in pairs(CORNER_COORDS) do
        local ring = owner:CreateTexture(nil, "BORDER")
        ring:SetTexture(MEDIA .. "ring.tga")
        ring:SetTexCoord(coords[1], coords[2], coords[3], coords[4])
        ring:SetSize(radius, radius)
        ring:SetPoint(point, owner, point)
        UI.Tint(ring, color)
    end
    owner:HookScript("OnSizeChanged", layoutDashes)
    layoutDashes(owner)
end

---------------------------------------------------------------------------
-- Icons, dots, avatars, tiles and badges
---------------------------------------------------------------------------
function UI.CreateIcon(parent, name, size, color, layer)
    local icon = parent:CreateTexture(nil, layer or "ARTWORK")
    icon:SetSize(size, size)
    UI.SetIcon(icon, name)
    UI.Tint(icon, color or Color.textSoft)
    return icon
end

function UI.SetIcon(icon, name)
    icon:SetTexture(MEDIA .. "icon-" .. name .. ".tga")
end

-- A presence dot: filled when online, a ring when not.
function UI.CreateDot(parent, size)
    local dot = parent:CreateTexture(nil, "ARTWORK")
    dot:SetSize(size, size)
    return dot
end

function UI.SetDot(dot, online)
    dot:SetTexture(MEDIA .. (online and "disc.tga" or "ring-bold.tga"))
    UI.Tint(dot, online and Color.online or Color.offline)
end

-- Race portraits are atlases named after the race and gender. Their names
-- aren't documented, so the likely ones are tried until one exists.
local RACE_ATLAS_NAMES = {
    Scourge = "undead",
    HighmountainTauren = "highmountain",
    LightforgedDraenei = "lightforged",
    ZandalariTroll = "zandalari",
    EarthenDwarf = "earthen",
}
local RACE_ATLAS_PREFIXES = { "raceicon128-", "raceicon-" }
local raceAtlases = {}

function UI.GetRaceAtlas(raceFile, sex)
    if type(raceFile) ~= "string" or not (C_Texture and C_Texture.GetAtlasInfo) then
        return nil
    end
    local gender = sex == 3 and "female" or "male"
    local key = raceFile .. "-" .. gender
    if raceAtlases[key] == nil then
        raceAtlases[key] = false
        local names = { strlower(raceFile) }
        if RACE_ATLAS_NAMES[raceFile] then
            table.insert(names, 1, RACE_ATLAS_NAMES[raceFile])
        end
        for _, prefix in ipairs(RACE_ATLAS_PREFIXES) do
            for _, name in ipairs(names) do
                local atlas = prefix .. name .. "-" .. gender
                if not raceAtlases[key] and C_Texture.GetAtlasInfo(atlas) then
                    raceAtlases[key] = atlas
                end
            end
        end
    end
    return raceAtlases[key] or nil
end

-- Shows the player's portrait when the game can draw it, their race's
-- portrait when it knows their race, and otherwise their first letter.
local function setAvatarPerson(avatar, fullName, color, classFile)
    UI.Tint(avatar.ring, color)
    local unit = TrialChatCommon.FindUnit(fullName)
    local atlas, classTexture
    if not unit then
        -- Match the chat-log avatar: prefer the saved race portrait, then
        -- fall back to the saved class icon when no look is available.
        local raceFile, sex = TrialChatCommon.GetKnownLook(fullName)
        atlas = UI.GetRaceAtlas(raceFile, sex)
        if not atlas then
            classTexture = classFile
                and TrialChatCommon.GetIconTexture("ClassIcon_" .. classFile)
        end
    end
    avatar.portrait:SetShown(unit ~= nil)
    avatar.face:SetShown(unit == nil and (classTexture ~= nil or atlas ~= nil))
    avatar.letter:SetShown(not unit and not classTexture and not atlas)
    if unit then
        SetPortraitTexture(avatar.portrait, unit)
    elseif classTexture then
        avatar.face:SetTexture(classTexture)
    elseif atlas then
        avatar.face:SetAtlas(atlas)
    else
        avatar.letter:SetText(UI.FirstLetter(TrialChatCommon.ShortName(fullName)))
        UI.SetTextColor(avatar.letter, color)
    end
end

-- A round avatar inside a ring in the player's class color.
function UI.CreateAvatar(parent, size)
    local avatar = CreateFrame("Button", nil, parent)
    avatar:SetSize(size, size)
    avatar.fill = avatar:CreateTexture(nil, "BACKGROUND")
    avatar.fill:SetAllPoints()
    avatar.fill:SetTexture(MEDIA .. "disc.tga")
    UI.Tint(avatar.fill, Color.avatar)

    -- Pictures fill the inside of the ring; the game rounds portraits itself.
    local inner = size - 4
    avatar.portrait = avatar:CreateTexture(nil, "ARTWORK")
    avatar.portrait:SetSize(inner, inner)
    avatar.portrait:SetPoint("CENTER")
    avatar.face = avatar:CreateTexture(nil, "ARTWORK")
    avatar.face:SetSize(inner, inner)
    avatar.face:SetPoint("CENTER")
    local mask = avatar:CreateMaskTexture()
    mask:SetTexture(MEDIA .. "disc.tga", "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
    mask:SetAllPoints(avatar.face)
    avatar.face:AddMaskTexture(mask)

    avatar.ring = avatar:CreateTexture(nil, "OVERLAY")
    avatar.ring:SetAllPoints()
    avatar.ring:SetTexture(MEDIA .. "ring.tga")
    avatar.letter = UI.CreateText(avatar, UI.Font.initials, nil, "OVERLAY")
    avatar.letter:SetPoint("CENTER", avatar, "CENTER", 1, 0)
    avatar.SetPerson = setAvatarPerson
    return avatar
end

local function setTileLook(tile, background, foreground, text, icon)
    tile.box:SetColor(background)
    tile.icon:ClearAllPoints()
    tile.icon:SetSize(tile:GetWidth() - 12, tile:GetHeight() - 12)
    tile.icon:SetPoint("CENTER")
    if tile.hasIconMask then
        tile.icon:RemoveMaskTexture(tile.iconMask)
        tile.hasIconMask = false
    end
    if icon then
        UI.SetIcon(tile.icon, icon)
        UI.Tint(tile.icon, foreground)
        tile.icon:Show()
        tile.text:Hide()
    else
        tile.text:SetText(text or "")
        UI.SetTextColor(tile.text, foreground)
        tile.text:Show()
        tile.icon:Hide()
    end
end

-- Shows a raw texture (a group's chosen icon) on the tile instead of a named
-- icon or initials.
local function setTileTexture(tile, texture)
    tile.icon:ClearAllPoints()
    tile.icon:SetAllPoints(tile)
    if not tile.iconMask then
        tile.iconMask = tile:CreateMaskTexture()
        tile.iconMask:SetTexture(
            MEDIA .. "rounded-mask.tga",
            "CLAMPTOBLACKADDITIVE",
            "CLAMPTOBLACKADDITIVE")
        tile.iconMask:SetAllPoints(tile.icon)
    end
    if not tile.hasIconMask then
        tile.icon:AddMaskTexture(tile.iconMask)
        tile.hasIconMask = true
    end
    tile.icon:SetTexture(texture)
    tile.icon:SetVertexColor(1, 1, 1, 1)
    tile.icon:Show()
    tile.text:Hide()
end

-- The rounded square in front of a conversation: an icon or initials.
function UI.CreateTile(parent, size)
    local tile = CreateFrame("Frame", nil, parent)
    tile:SetSize(size, size)
    tile.box = UI.CreateBox(tile, { radius = 7 })
    tile.icon = tile:CreateTexture(nil, "ARTWORK")
    tile.icon:SetSize(size - 12, size - 12)
    tile.icon:SetPoint("CENTER")
    tile.text = UI.CreateText(tile, UI.Font.label)
    tile.text:SetPoint("CENTER", tile, "CENTER", 1, 0)
    tile.SetLook = setTileLook
    tile.SetTexture = setTileTexture
    return tile
end

local function setBadgeCount(badge, count)
    badge.text:SetText(count > 99 and "99+" or tostring(count))
    badge:SetWidth(math.max(badge:GetHeight(), math.ceil(badge.text:GetStringWidth()) + 12))
end

-- An accent pill with a count, for unread messages.
function UI.CreateBadge(parent)
    local badge = CreateFrame("Frame", nil, parent)
    badge:SetSize(18, 18)
    badge.box = UI.CreateBox(badge, { radius = 9 })
    badge.box:SetColor(Color.accent)
    badge.text = UI.CreateText(badge, UI.Font.small, Color.accentText)
    badge.text:SetPoint("CENTER", badge, "CENTER", 0, 0)
    badge.SetCount = setBadgeCount
    return badge
end

function UI.CreateLabel(parent, text)
    local label = UI.CreateText(parent, UI.Font.label, Color.muted)
    label:SetText(text and string.upper(text) or "")
    return label
end

function UI.CreateLine(parent, color, layer)
    local line = parent:CreateTexture(nil, layer or "BORDER")
    line:SetTexture(WHITE)
    UI.Tint(line, color or Color.line)
    return line
end

---------------------------------------------------------------------------
-- Buttons
---------------------------------------------------------------------------
local BUTTON_STYLES = {
    -- A field-colored button with an outline.
    outline = { fill = "field", hover = "hover", border = "fieldBorder", content = "textSoft" },
    -- No background until the cursor is on it.
    ghost = { hover = "field", content = "muted", hoverContent = "textSoft" },
    -- Filled with the accent color.
    accent = { fill = "accent", hover = "accentHover", content = "accentText" },
    -- A dashed outline, for adding things; blue while hovered.
    dashed = {
        hover = "accent", content = "textSoft", hoverContent = "accentText",
    },
    -- A faint blue that fills in and brightens on hover, for accepting.
    accept = {
        fill = "accentFaint", hover = "accent", content = "accent",
        hoverContent = "accentText", border = "accent", borderAlpha = 0.45,
    },
    -- A faint red that fills in and brightens on hover, for declining.
    decline = {
        fill = "errorFaint", hover = "error", content = "error",
        hoverContent = "errorText", border = "error", borderAlpha = 0.45,
    },
    -- See-through dark with a faint outline, for buttons over the game world.
    hud = {
        fill = "sidebar", hover = "selected", fillAlpha = 0.8,
        border = "white", borderAlpha = 0.16, content = "textSoft",
    },
}

-- Buttons can switch style (a pill becomes "accent" when selected); a style
-- without an outline hides the one it was made with.
function UI.SetButtonStyle(button, style)
    button.style = style
    UI.UpdateButton(button)
end

function UI.UpdateButton(button)
    local style = BUTTON_STYLES[button.style]
    local enabled = button:IsEnabled()
    local hovered = button.hovered and enabled
    local fill = button.active and "pressed"
        or (hovered and style.hover) or style.fill
    if fill then
        button.box:SetColor(Color[fill], not button.active and style.fillAlpha or 1)
        button.box:Show()
    else
        button.box:Hide()
    end
    if button.active then
        button.box:SetBorderColor(Color.pressedBorder)
    elseif style.border then
        button.box:SetBorderColor(Color[style.border], style.borderAlpha)
    else
        button.box:SetBorderColor(Color.white, 0)
    end

    local content = Color[(button.active and "white")
        or (hovered and style.hoverContent) or style.content]
    if button.icon then UI.Tint(button.icon, content) end
    if button.label then UI.SetTextColor(button.label, content) end
    button:SetAlpha(enabled and 1 or 0.5)
end

function UI.SetButtonActive(button, active)
    button.active = active and true or false
    UI.UpdateButton(button)
end

local function layoutButtonContent(button)
    local icon, label = button.icon, button.label
    if icon and label then
        local iconSize = icon:GetWidth()
        icon:ClearAllPoints()
        if button.centered then
            local width = iconSize + 6 + label:GetStringWidth()
            icon:SetPoint("LEFT", button, "CENTER", -width / 2, 0)
        else
            icon:SetPoint("LEFT", button, "LEFT", 12, 0)
            button:SetWidth(math.ceil(12 + iconSize + 6 + label:GetStringWidth() + 14))
        end
        label:ClearAllPoints()
        label:SetPoint("LEFT", icon, "RIGHT", 6, 0)
    elseif label then
        label:SetPoint("CENTER")
        if button.autoWidth then
            button:SetWidth(math.ceil(label:GetStringWidth() + 26))
        end
    elseif icon then
        icon:SetPoint("CENTER")
    end
end

local function resolveButtonTooltip(button)
    local tooltip = button.tooltip
    if type(tooltip) == "function" then tooltip = tooltip(button) end
    return tooltip
end

local function showButtonTooltip(button)
    local text = resolveButtonTooltip(button)
    if not text then return end
    GameTooltip:SetOwner(button, button.tooltipAnchor or "ANCHOR_TOP")
    GameTooltip:SetText(text, nil, nil, nil, nil, true)
    GameTooltip:Show()
end

local function showThemedButtonTooltip(button)
    local text = resolveButtonTooltip(button)
    if not text then return end
    UI.ShowTooltip(button, text)
end

local function setButtonText(button, text)
    if button.label then
        button.label:SetText(text)
    end
    layoutButtonContent(button)
end

-- options: style, width, height, radius, icon, iconSize, text, centered
-- (icon and text in the middle instead of sizing the button to them),
-- tooltip (text, or a function returning it), onClick.
function UI.CreateButton(parent, options)
    local button = CreateFrame("Button", nil, parent)
    button.style = options.style or "outline"
    button:SetSize(options.width or 32, options.height or 32)
    button.box = UI.CreateBox(button, {
        radius = options.radius or 8,
        border = BUTTON_STYLES[button.style].border ~= nil,
    })
    if button.style == "dashed" then
        UI.AddDashedOutline(button, options.radius or 8, Color.dashed)
    end
    if options.icon then
        button.icon = UI.CreateIcon(button, options.icon, options.iconSize or 16)
    end
    if options.text then
        button.label = UI.CreateText(button, options.font or UI.Font.item)
        button.label:SetText(options.text)
    end
    button.centered = options.centered
    button.autoWidth = options.width == nil
    button.themedTooltip = options.themedTooltip
    button.tooltip = options.tooltip
    button.SetLabel = setButtonText
    layoutButtonContent(button)

    button:RegisterForClicks("LeftButtonUp")
    if options.onClick then
        button:SetScript("OnClick", options.onClick)
    end
    button:SetScript("OnEnter", function(self)
        self.hovered = true
        UI.UpdateButton(self)
        if self.themedTooltip then
            showThemedButtonTooltip(self)
        else
            showButtonTooltip(self)
        end
    end)
    button:SetScript("OnLeave", function(self)
        self.hovered = false
        UI.UpdateButton(self)
        if self.themedTooltip then
            UI.HideTooltip()
        else
            GameTooltip_Hide()
        end
    end)
    if options.themedTooltip then
        button:HookScript("OnHide", UI.HideTooltip)
    end
    button:SetScript("OnEnable", UI.UpdateButton)
    button:SetScript("OnDisable", UI.UpdateButton)
    UI.UpdateButton(button)
    return button
end

---------------------------------------------------------------------------
-- Text fields
---------------------------------------------------------------------------
local function updateFieldLook(field)
    field.placeholder:SetShown((field:GetText() or "") == "")
    -- keepFocusLook holds the focused border while the field's focus is handed
    -- back and forth (the message box while the emoji picker is up), so the
    -- border doesn't flick to the unfocused colour in between.
    local focused = field:HasFocus() or field.keepFocusLook
    field.box:SetBorderColor(focused and Color.fieldFocus or Color.fieldBorder)
end

-- options: height, placeholder, maxLetters, insetLeft, insetRight, icon.
function UI.CreateField(parent, options)
    options = options or {}
    local field = CreateFrame("EditBox", nil, parent)
    field:EnableMouse(true)
    field:SetAutoFocus(false)
    field:SetHeight(options.height or 32)
    field:SetFontObject(UI.Font.body)
    field:SetTextColor(Color.text[1], Color.text[2], Color.text[3], 1)
    field:SetMaxLetters(options.maxLetters or 255)
    local insetLeft = options.insetLeft or 12
    field:SetTextInsets(insetLeft, options.insetRight or 12, 0, 0)
    field.box = UI.CreateBox(field, { radius = 8, border = true })
    field.box:SetColor(Color.field)

    if options.icon then
        field.icon = UI.CreateIcon(field, options.icon, 15, Color.muted)
        field.icon:SetPoint("LEFT", field, "LEFT", 10, 0)
    end
    field.placeholder = UI.CreateText(field, UI.Font.body, Color.muted)
    field.placeholder:SetPoint("LEFT", field, "LEFT", insetLeft, 0)
    field.placeholder:SetPoint("RIGHT", field, "RIGHT", -8, 0)
    field.placeholder:SetJustifyH("LEFT")
    field.placeholder:SetWordWrap(false)
    field.placeholder:SetText(options.placeholder or "")

    field:HookScript("OnTextChanged", updateFieldLook)
    field:HookScript("OnEditFocusGained", updateFieldLook)
    field:HookScript("OnEditFocusLost", updateFieldLook)
    field:SetScript("OnEscapePressed", field.ClearFocus)
    -- Holds the focused border look on while true, whether or not the field
    -- really has the keyboard. Used while a popup hands focus back on every
    -- click, to keep the border from flickering between the two states.
    field.SetFocusLook = function(self, keep)
        self.keepFocusLook = keep and true or nil
        updateFieldLook(self)
    end
    updateFieldLook(field)
    return field
end

---------------------------------------------------------------------------
-- Group invites
---------------------------------------------------------------------------
local INVITE_PADDING = 12
local INVITE_TEXT_LEFT = 36
local INVITE_BUTTON_HEIGHT = 26

-- Lays the card out for invite ({ groupName, inviter }) at this width and
-- returns its height.
local function setInvite(card, invite, width)
    card:SetWidth(width)
    card.text:SetWidth(width - INVITE_TEXT_LEFT - INVITE_PADDING)
    card.text:SetText(invite.inviter .. " invites you to join "
        .. UI.ColorText(Color.accent, invite.groupName))
    local height = math.ceil(INVITE_PADDING + card.text:GetStringHeight() + 8
        + INVITE_BUTTON_HEIGHT + 10)
    card:SetHeight(height)
    return height
end

-- Who invites you to which group, with Join and Decline; onAnswer is called
-- with true to join.
function UI.CreateInviteCard(parent, onAnswer)
    local card = CreateFrame("Frame", nil, parent)
    card:EnableMouse(true)
    card.box = UI.CreateBox(card, { radius = 13, border = true })
    card.box:SetColor(Color.window, 0.96)
    card.box:SetBorderColor(Color.accent, 0.5)
    card.icon = UI.CreateIcon(card, "members", 16, Color.accent)
    card.icon:SetPoint("TOPLEFT", card, "TOPLEFT", 12, -INVITE_PADDING)
    card.text = UI.CreateText(card, UI.Font.body)
    card.text:SetPoint("TOPLEFT", card, "TOPLEFT", INVITE_TEXT_LEFT, -INVITE_PADDING)
    card.text:SetJustifyH("LEFT")
    card.text:SetWordWrap(true)
    card.join = UI.CreateButton(card, {
        style = "accent", text = "Join", height = INVITE_BUTTON_HEIGHT, radius = 13,
        font = UI.Font.small, onClick = function() onAnswer(true) end,
    })
    card.join:SetPoint("BOTTOMRIGHT", card, "BOTTOMRIGHT", -10, 10)
    card.decline = UI.CreateButton(card, {
        style = "outline", text = "Decline", height = INVITE_BUTTON_HEIGHT, radius = 13,
        font = UI.Font.small, onClick = function() onAnswer(false) end,
    })
    card.decline:SetPoint("RIGHT", card.join, "LEFT", -6, 0)
    card.SetInvite = setInvite
    card:Hide()
    return card
end

---------------------------------------------------------------------------
-- Tooltips: a small themed box, like the popup menu, shown for button hints.
---------------------------------------------------------------------------
local TOOLTIP_INSET = 10
local tooltip

function UI.HideTooltip()
    if tooltip then tooltip:Hide() end
end

-- Shows text near the owner, to the right by default. The frame is clamped
-- to the screen.
function UI.ShowTooltip(owner, text)
    if not text or text == "" then UI.HideTooltip(); return end
    if not tooltip then
        local frame = CreateFrame("Frame", "TrialChatTooltip", UIParent)
        frame:SetFrameStrata("TOOLTIP")
        frame:SetClampedToScreen(true)
        frame.box = UI.CreateBox(frame, { radius = 8, border = true })
        frame.box:SetColor(Color.window, 0.98)
        frame.box:SetBorderColor(Color.outline, 1)
        frame.text = UI.CreateText(frame, UI.Font.item, Color.textSoft)
        frame.text:SetPoint("LEFT", frame, "LEFT", TOOLTIP_INSET, 0)
        frame.text:SetPoint("RIGHT", frame, "RIGHT", -TOOLTIP_INSET, 0)
        frame.text:SetWordWrap(false)
        tooltip = frame
    end
    tooltip.text:SetText(text)
    tooltip:SetSize(math.ceil(tooltip.text:GetStringWidth()) + 2 * TOOLTIP_INSET, 26)
    tooltip:ClearAllPoints()
    tooltip:SetPoint("BOTTOM", owner, "TOP", 0, 6)
    tooltip:Show()
end

---------------------------------------------------------------------------
local POPUP_NAME = "TrialChatPopupMenu"
local POPUP_LEVEL = 4999
local POPUP_TEXT_INSET = 9
local popup

function UI.HidePopupMenu()
    if popup then popup:Hide() end
end

local function createPopup()
    local frame = CreateFrame("Frame", POPUP_NAME, UIParent)
    frame:SetFrameStrata("FULLSCREEN_DIALOG")
    frame:SetFrameLevel(POPUP_LEVEL)
    frame:EnableMouse(true)
    frame.box = UI.CreateBox(frame, { radius = 8, border = true })
    frame.rows = {}

    -- Any click outside the menu closes it.
    local catcher = CreateFrame("Frame", nil, UIParent)
    catcher:SetAllPoints(UIParent)
    catcher:SetFrameStrata("FULLSCREEN_DIALOG")
    catcher:SetFrameLevel(POPUP_LEVEL - 1)
    catcher:EnableMouse(true)
    catcher:SetScript("OnMouseDown", function() frame:Hide() end)
    frame.catcher = catcher

    frame:SetScript("OnHide", function() catcher:Hide() end)
    frame:Hide()
    tinsert(UISpecialFrames, POPUP_NAME)
    return frame
end

local function ensureRow(frame, index, theme)
    local row = frame.rows[index]
    if not row then
        row = CreateFrame("Button", nil, frame)
        row:RegisterForClicks("LeftButtonUp")
        row:EnableMouseWheel(true)
        row:SetScript("OnMouseWheel", function(_, delta)
            local handler = frame:GetScript("OnMouseWheel")
            if handler then handler(frame, delta) end
        end)
        row.box = UI.CreateBox(row, { radius = 6 })
        row.text = UI.CreateText(row, theme.font or UI.Font.item,
            theme.text or Color.textSoft)
        row.text:SetPoint("LEFT", row, "LEFT", POPUP_TEXT_INSET, 0)
        row.text:SetPoint("RIGHT", row, "RIGHT", -POPUP_TEXT_INSET, 0)
        row.text:SetJustifyH("LEFT")
        row:SetScript("OnEnter", function(self) self.box:Show() end)
        row:SetScript("OnLeave", function(self) self.box:Hide() end)
        row:SetScript("OnClick", function(self)
            local action = self.action
            UI.HidePopupMenu()
            if action then action() end
        end)
        frame.rows[index] = row
    end
    -- Restyled every time: one menu is shared by views with their own colors.
    row.box:SetColor(theme.hover or Color.hover, theme.hoverAlpha or 1)
    UI.SetTextColor(row.text, theme.text or Color.textSoft)
    if theme.font then row.text:SetFontObject(theme.font) end
    row.box:Hide()
    return row
end

-- items: a list of { text = ..., onClick = ... }, in order from the top.
function UI.ShowPopupMenu(theme, items)
    if not items or #items == 0 then return end

    local frame = popup or createPopup()
    popup = frame
    frame.box:SetColor(theme.bg or Color.window, theme.bgAlpha or 1)
    frame.box:SetBorderColor(theme.border or Color.outline,
        theme.borderAlpha or 1)

    local itemHeight = theme.itemHeight or 24
    local padding = theme.padding or 5
    local maxItems = theme.maxItems or #items
    local visibleItems = math.min(maxItems, #items)
    local firstItem = math.max(1, math.min(theme.scrollOffset or 1,
        math.max(1, #items - visibleItems + 1)))
    local lastItem = math.min(#items, firstItem + visibleItems - 1)
    local textWidth = 0
    for index = firstItem, lastItem do
        local item = items[index]
        local rowIndex = index - firstItem + 1
        local row = ensureRow(frame, rowIndex, theme)
        row.text:SetText(item.text)
        row.action = item.onClick
        row:Show()
        textWidth = math.max(textWidth, row.text:GetStringWidth())
    end
    for index = visibleItems + 1, #frame.rows do
        frame.rows[index]:Hide()
    end

    local width = textWidth + 2 * (POPUP_TEXT_INSET + padding)
    width = math.max(width, theme.minWidth or 0)
    frame:SetSize(width, visibleItems * itemHeight + 2 * padding)
    for index = 1, visibleItems do
        local row = frame.rows[index]
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", frame, "TOPLEFT", padding,
            -(padding + (index - 1) * itemHeight))
        row:SetSize(width - 2 * padding, itemHeight)
    end
    frame:EnableMouseWheel(theme.onScroll ~= nil)
    frame:SetScript("OnMouseWheel", function(_, delta)
        if theme.onScroll then theme.onScroll(delta) end
    end)

    -- Open where the cursor is, then nudge it back onto the screen. Keep the
    -- existing position while a scrollable menu is being redrawn.
    local left, bottom
    if theme.keepPosition and frame:IsShown() then
        left, bottom = frame:GetLeft(), frame:GetBottom()
    else
        local scale = frame:GetEffectiveScale()
        local cursorX, cursorY = GetCursorPosition()
        local uiLeft, uiBottom = UIParent:GetLeft() or 0, UIParent:GetBottom() or 0
        local uiWidth, uiHeight = UIParent:GetWidth(), UIParent:GetHeight()
        left = cursorX / scale + 4
        bottom = cursorY / scale - 4 - frame:GetHeight()
        if left + frame:GetWidth() > uiLeft + uiWidth then
            left = uiLeft + uiWidth - frame:GetWidth()
        end
        if left < uiLeft then left = uiLeft end
        if bottom + frame:GetHeight() > uiBottom + uiHeight then
            bottom = uiBottom + uiHeight - frame:GetHeight()
        end
        if bottom < uiBottom then bottom = uiBottom end
    end

    frame:ClearAllPoints()
    frame:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", left, bottom)
    frame:Show()
    frame.catcher:Show()
end
