-- The options window: every toggle TrialChat has in one place, as checkboxes,
-- in the same style as the messenger window (same colors, fonts and boxes).
TrialChatOptions = {}
local Options = TrialChatOptions
local UI = TrialChatUI
local Color = UI.Color

local WIDTH = 420
local PADDING = 18
local HEADER_HEIGHT = 66
local ROW_HEIGHT = 42
local SECTION_GAP = 24
local FOOTER_HEIGHT = 36
local CHECK_SIZE = 22
local CHECK_TEX = "Interface\\Buttons\\UI-CheckBox-Check"

local window
local rows = {}

local function setCheckboxLook(check, on)
    check.on = on and true or false
    check.box:SetColor(check.on and Color.accent or Color.field)
    check.box:SetBorderColor(check.on and Color.accent or Color.fieldFocus)
    UI.Tint(check.mark, check.on and Color.accentText or Color.textSoft)
    check.mark:SetShown(check.on)
end

-- A rounded square that fills with the accent color and shows a check when on.
local function createCheckbox(parent)
    local check = CreateFrame("Frame", nil, parent)
    check:SetSize(CHECK_SIZE, CHECK_SIZE)
    check.box = UI.CreateBox(check, { radius = 6, border = true })
    check.mark = check:CreateTexture(nil, "ARTWORK")
    check.mark:SetTexture(CHECK_TEX)
    check.mark:SetSize(CHECK_SIZE - 8, CHECK_SIZE - 8)
    check.mark:SetPoint("CENTER")
    setCheckboxLook(check, false)
    return check
end

-- A full-width row: its name on the left, its checkbox on the right. Clicking
-- anywhere on it flips the checkbox. isEnabled (optional) greys out the row
-- while another setting it depends on is off.
local function createToggle(parent, text, getter, setter, isEnabled)
    local row = CreateFrame("Button", nil, parent)
    row:SetHeight(ROW_HEIGHT)
    -- Sit above the window's own background so the row and its checkbox show.
    row:SetFrameLevel(parent:GetFrameLevel() + 1)
    row.hover = UI.CreateBox(row, { radius = 8 })
    row.hover:SetColor(Color.hover)
    row.hover:SetShown(false)

    row.label = UI.CreateText(row, UI.Font.item, Color.text)
    row.label:SetPoint("LEFT", row, "LEFT", 10, 0)
    row.label:SetPoint("RIGHT", row, "RIGHT", -(CHECK_SIZE + 16), 0)
    row.label:SetJustifyH("LEFT")
    row.label:SetWordWrap(false)
    row.label:SetText(text)

    row.check = createCheckbox(row)
    row.check:SetPoint("RIGHT", row, "RIGHT", -10, 0)

    row.getter, row.setter, row.isEnabled = getter, setter, isEnabled
    row:RegisterForClicks("LeftButtonUp")
    row:SetScript("OnClick", function(self)
        if self.isEnabled and not self.isEnabled() then return end
        self.setter(not self.getter())
        Options:Refresh()
    end)
    row:SetScript("OnEnter", function(self) self.hover:SetShown(true) end)
    row:SetScript("OnLeave", function(self) self.hover:SetShown(false) end)

    rows[#rows + 1] = row
    return row
end

function Options:Refresh()
    for _, row in ipairs(rows) do
        setCheckboxLook(row.check, row.getter())
        local enabled = (not row.isEnabled) or row.isEnabled()
        UI.SetTextColor(row.label, enabled and Color.text or Color.muted)
        row:SetAlpha(enabled and 1 or 0.5)
    end
end

local function createWindow()
    if window then return end

    window = CreateFrame("Frame", "TrialChatOptionsFrame", UIParent)
    window:SetPoint("CENTER")
    window:SetWidth(WIDTH)
    window:SetFrameStrata("DIALOG")
    window:SetFrameLevel(200)
    window:SetMovable(true)
    window:SetClampedToScreen(true)
    window:EnableMouse(true)
    window:RegisterForDrag("LeftButton")
    window:SetScript("OnDragStart", window.StartMoving)
    window:SetScript("OnDragStop", window.StopMovingOrSizing)
    window.box = UI.CreateBox(window, { radius = 10, border = true })
    window.box:SetColor(Color.window)
    window.box:SetBorderColor(Color.outline)

    local title = UI.CreateText(window, UI.Font.title, Color.white)
    title:SetPoint("TOPLEFT", window, "TOPLEFT", PADDING, -17)
    title:SetText("Options")

    local subtitle = UI.CreateText(window, UI.Font.small, Color.muted)
    subtitle:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -4)
    subtitle:SetText("TrialChat settings")

    local closeButton = UI.CreateButton(window, {
        style = "ghost", icon = "close", iconSize = 14, width = 28, height = 28,
        tooltip = "Close",
        onClick = function() window:Hide() end,
    })
    closeButton:SetPoint("TOPRIGHT", window, "TOPRIGHT", -12, -14)

    local divider = UI.CreateLine(window)
    divider:SetPoint("TOPLEFT", window, "TOPLEFT", PADDING, -HEADER_HEIGHT)
    divider:SetPoint("TOPRIGHT", window, "TOPRIGHT", -PADDING, -HEADER_HEIGHT)
    divider:SetHeight(1)

    -- Lays the options out from just under the header, name on the left and
    -- checkbox on the right, anchored straight to the window the same as the
    -- group dialog. The cursor is how far down the window each thing has
    -- reached; a section label takes a little room of its own and an extra gap
    -- above it once options have come before.
    local LABEL_HEIGHT = 16
    local cursor = 0
    local function section(text)
        cursor = cursor + (#rows > 0 and SECTION_GAP or 14)
        local label = UI.CreateLabel(window, text)
        label:SetPoint("TOPLEFT", window, "TOPLEFT", PADDING + 10, -(HEADER_HEIGHT + cursor))
        cursor = cursor + LABEL_HEIGHT
    end
    local function toggle(text, getter, setter, isEnabled)
        local row = createToggle(window, text, getter, setter, isEnabled)
        row:SetPoint("TOPLEFT", window, "TOPLEFT", PADDING, -(HEADER_HEIGHT + cursor))
        row:SetWidth(WIDTH - 2 * PADDING)
        cursor = cursor + ROW_HEIGHT
    end

    section("Chat bubbles")
    toggle("Show chat bubbles",
        function() return TrialChatBubbles.IsEnabled() end,
        function() SlashCmdList["TRIALCHATBUBBLES"]("") end)
    toggle("Over your own character",
        function() return TrialChatBubbles.IsEnabled("self") end,
        function() SlashCmdList["TRIALCHATBUBBLES"]("self") end,
        function() return TrialChatBubbles.IsEnabled() end)
    toggle("For group chats",
        function() return TrialChatBubbles.IsEnabled("groups") end,
        function() SlashCmdList["TRIALCHATBUBBLES"]("groups") end,
        function() return TrialChatBubbles.IsEnabled() end)

    section("Nearby chat")
    toggle("Echo messages to Say (/s)",
        function() return TrialChatDB ~= nil and TrialChatDB.echoToSay == true end,
        function(checked)
            TrialChatDB = TrialChatDB or {}
            TrialChatDB.echoToSay = checked and true or false
        end)
    toggle("Echo messages to Party (/p)",
        function() return TrialChatDB ~= nil and TrialChatDB.echoToParty == true end,
        function(checked)
            TrialChatDB = TrialChatDB or {}
            TrialChatDB.echoToParty = checked and true or false
        end)

    section("Sound emotes")
    toggle("Mute sound emotes",
        function() return TrialChatCommon.AreSoundEmotesMuted() end,
        function(checked) TrialChatCommon.SetSoundEmotesMuted(checked) end)

    -- The member list is deliberately NOT listed here: the maximized window
    -- already has its own toggle for it in the sidebar, so don't add one.

    local footer = UI.CreateText(window, UI.Font.small, Color.muted)
    footer:SetPoint("BOTTOMLEFT", window, "BOTTOMLEFT", PADDING, 14)
    footer:SetText("Settings are saved as you change them.")

    window:SetHeight(HEADER_HEIGHT + cursor + FOOTER_HEIGHT)
    window:SetScript("OnShow", function() Options:Refresh() end)
    window:Hide()
end

function Options:IsShown()
    return window ~= nil and window:IsShown()
end

function Options:Show()
    createWindow()
    window:Show()
end

function Options:Hide()
    if window then
        window:Hide()
    end
end

function Options:Toggle()
    if self:IsShown() then
        self:Hide()
    else
        self:Show()
    end
end

-- Escape closes it, like the other windows.
table.insert(UISpecialFrames, "TrialChatOptionsFrame")
