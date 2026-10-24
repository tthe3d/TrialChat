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
local TAB_HEIGHT = 28
local TAB_GAP = 6
local CONTENT_TOP = HEADER_HEIGHT + TAB_HEIGHT + 8
local CHECK_TEX = "Interface\\Buttons\\UI-CheckBox-Check"

local window
local rows = {}
local activeTab = "general"
local layoutTab

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
    if layoutTab then layoutTab(activeTab) end
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
    title:SetText("Settings")

    local closeButton = UI.CreateButton(window, {
        style = "ghost", icon = "close", iconSize = 14, width = 28, height = 28,
        tooltip = "Close",
        onClick = function() window:Hide() end,
    })
    closeButton:SetPoint("TOPRIGHT", window, "TOPRIGHT", -12, -14)

    local divider = UI.CreateLine(window)
    divider:SetPoint("TOPLEFT", window, "TOPLEFT", PADDING, -CONTENT_TOP + 4)
    divider:SetPoint("TOPRIGHT", window, "TOPRIGHT", -PADDING, -CONTENT_TOP + 4)
    divider:SetHeight(1)

    local tabButtons = {}
    local tabNames = {
        { key = "general", text = "General" },
        { key = "nearby", text = "Nearby chat" },
        { key = "minimized", text = "Minimized chat" },
    }
    for index, tab in ipairs(tabNames) do
        local button = UI.CreateButton(window, {
            style = "outline", text = tab.text, height = TAB_HEIGHT,
        })
        button:SetPoint("TOPLEFT", window, "TOPLEFT",
            PADDING + (index - 1) * (WIDTH - 2 * PADDING) / #tabNames,
            -HEADER_HEIGHT + 1)
        button:SetWidth((WIDTH - 2 * PADDING - (TAB_GAP * (#tabNames - 1))) / #tabNames)
        button:SetScript("OnClick", function()
            activeTab = tab.key
            Options:Refresh()
        end)
        tabButtons[tab.key] = button
    end

    -- Each tab keeps its own sections and rows. Only the selected tab is
    -- positioned and shown, so the window height follows its contents.
    local LABEL_HEIGHT = 16
    local tabItems = { general = {}, nearby = {}, minimized = {} }
    local currentTab = "general"
    local function section(text, tab)
        currentTab = tab or currentTab
        local label = UI.CreateLabel(window, text)
        tabItems[currentTab][#tabItems[currentTab] + 1] = {
            kind = "section", frame = label,
        }
    end
    local function toggle(text, getter, setter, isEnabled)
        local row = createToggle(window, text, getter, setter, isEnabled)
        tabItems[currentTab][#tabItems[currentTab] + 1] = {
            kind = "toggle", frame = row,
        }
        row:SetWidth(WIDTH - 2 * PADDING)
    end

    section("Chat bubbles", "general")
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

    section("Nearby chat", "nearby")
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

    section("Minimized chat", "minimized")
    toggle("Expand chat while typing",
        function()
            return TrialChatDB == nil
                or TrialChatDB.messenger == nil
                or TrialChatDB.messenger.expandOnType ~= false
        end,
        function(checked)
            TrialChatDB = TrialChatDB or {}
            TrialChatDB.messenger = TrialChatDB.messenger or {}
            TrialChatDB.messenger.expandOnType = checked and true or false
        end)
    toggle("Close chat with second Escape",
        function()
            return TrialChatDB == nil
                or TrialChatDB.messenger == nil
                or TrialChatDB.messenger.closeOnSecondEscape ~= false
        end,
        function(checked)
            TrialChatDB = TrialChatDB or {}
            TrialChatDB.messenger = TrialChatDB.messenger or {}
            TrialChatDB.messenger.closeOnSecondEscape = checked and true or false
        end)

    section("Sound emotes", "general")
    toggle("Mute sound emotes",
        function() return TrialChatCommon.AreSoundEmotesMuted() end,
        function(checked) TrialChatCommon.SetSoundEmotesMuted(checked) end)

    -- The member list is deliberately NOT listed here: the maximized window
    -- already has its own toggle for it in the sidebar, so don't add one.

    local footer = UI.CreateText(window, UI.Font.small, Color.muted)
    footer:SetPoint("BOTTOMLEFT", window, "BOTTOMLEFT", PADDING, 14)
    footer:SetText("Settings are saved as you change them.")

    layoutTab = function(tab)
        for key, items in pairs(tabItems) do
            local cursor = 0
            local hasContent = false
            for _, item in ipairs(items) do
                if key == tab then
                    if item.kind == "section" then
                        cursor = cursor + (hasContent and SECTION_GAP or 14)
                        item.frame:ClearAllPoints()
                        item.frame:SetPoint("TOPLEFT", window, "TOPLEFT",
                            PADDING + 10, -(CONTENT_TOP + cursor))
                        item.frame:Show()
                        cursor = cursor + LABEL_HEIGHT
                    else
                        item.frame:ClearAllPoints()
                        item.frame:SetPoint("TOPLEFT", window, "TOPLEFT",
                            PADDING, -(CONTENT_TOP + cursor))
                        item.frame:Show()
                        cursor = cursor + ROW_HEIGHT
                    end
                    hasContent = true
                else
                    item.frame:Hide()
                end
            end
            if key == tab then
                window:SetHeight(CONTENT_TOP + cursor + FOOTER_HEIGHT)
            end
        end
        for key, button in pairs(tabButtons) do
            UI.SetButtonStyle(button, key == tab and "accent" or "outline")
        end
    end

    -- Leave a small gap between tab buttons while keeping their row inside the
    -- existing header area.
    for index, tab in ipairs(tabNames) do
        local button = tabButtons[tab.key]
        button:ClearAllPoints()
        button:SetPoint("TOPLEFT", window, "TOPLEFT",
            PADDING + (index - 1) * ((WIDTH - 2 * PADDING + TAB_GAP) / #tabNames),
            -HEADER_HEIGHT + 1)
        button:SetWidth((WIDTH - 2 * PADDING - TAB_GAP * (#tabNames - 1)) / #tabNames)
    end

    layoutTab(activeTab)
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
