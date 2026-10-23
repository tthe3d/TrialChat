-- The group icon picker: a grid of the same icons macros have, so a group's
-- creator can choose the icon that stands for the group. Opened from the
-- create-group dialog and from a group's menu. The grid scrolls and only
-- builds the rows on screen.
TrialChatIconPicker = {}
local UI = TrialChatUI
local Color = UI.Color
local MEDIA = "Interface\\AddOns\\TrialChat\\Media\\"

local COLUMNS = 10
local ICON_SIZE = 28
local CELL = 34
local ROW_HEIGHT = 34
local ROW_SPACING = 4
local PADDING = 12
local HEADER_HEIGHT = 84
local BODY_HEIGHT = 300
local SCROLL_GAP = 14
local WIDTH = PADDING * 2 + COLUMNS * CELL + SCROLL_GAP

local picker
local searchableSpellIcons
local iconSearchNames = {}

local function findIconForName(query)
    if query == "" then return nil end

    if C_Spell and C_Spell.GetSpellInfo then
        local ok, spellInfo = pcall(C_Spell.GetSpellInfo, query)
        if not ok then spellInfo = nil end
        if spellInfo and spellInfo.iconID then
            return tostring(spellInfo.iconID)
        end
    elseif GetSpellInfo then
        local ok, _, _, icon = pcall(GetSpellInfo, query)
        if not ok then icon = nil end
        if icon then return tostring(icon) end
    end

    if C_Item and C_Item.GetItemInfo then
        local ok, _, _, _, _, _, _, _, _, _, icon =
            pcall(C_Item.GetItemInfo, query)
        if not ok then icon = nil end
        if icon then return tostring(icon) end
    elseif GetItemInfo then
        local ok, _, _, _, _, _, _, _, _, _, icon = pcall(GetItemInfo, query)
        if not ok then icon = nil end
        if icon then return tostring(icon) end
    end
end

local iconNames = {}

-- The icon's own name, when we have one: from the shipped id list, or the
-- icon's own text for an icon stored by name. Nil when all we have is the
-- number. Cached per icon, false for the ones with no name.
local function getIconName(icon)
    local key = tostring(icon)
    local cached = iconNames[key]
    if cached ~= nil then
        if cached == false then return nil end
        return cached
    end

    local name
    local fileID = tonumber(key)
    if fileID then
        if TrialChatIconNames then name = TrialChatIconNames[fileID] end
    else
        name = string.gsub(key, "^Interface[/\\]Icons[/\\]", "")
    end

    if name == "" then name = nil end
    iconNames[key] = name or false
    return name
end

local function getIconSearchName(icon)
    local key = tostring(icon)
    if iconSearchNames[key] then return iconSearchNames[key] end

    local name = strlower(string.gsub(getIconName(icon) or key, "[^%w]+", " "))
    iconSearchNames[key] = name
    return name
end

local function addSearchableSpell(name, icon)
    if type(name) ~= "string" or name == "" or not icon then return end
    searchableSpellIcons[#searchableSpellIcons + 1] = {
        displayName = name,
        name = strlower(name),
        icon = tostring(icon),
    }
end

local function getSearchableSpellIcons()
    if searchableSpellIcons and #searchableSpellIcons > 0 then
        return searchableSpellIcons
    end
    searchableSpellIcons = {}

    if C_SpellBook and C_SpellBook.GetNumSpellBookSkillLines
        and C_SpellBook.GetSpellBookSkillLineInfo
        and C_SpellBook.GetSpellBookItemType
        and C_SpellBook.GetSpellBookItemTexture
        and Enum and Enum.SpellBookSpellBank and Enum.SpellBookItemType then
        local spellBank = Enum.SpellBookSpellBank.Player
        local spellItemType = Enum.SpellBookItemType.Spell
        for skillLineIndex = 1, C_SpellBook.GetNumSpellBookSkillLines() do
            local skillLine = C_SpellBook.GetSpellBookSkillLineInfo(skillLineIndex)
            if skillLine then
                local firstIndex = skillLine.itemIndexOffset + 1
                local lastIndex = skillLine.itemIndexOffset + skillLine.numSpellBookItems
                for spellIndex = firstIndex, lastIndex do
                    local spellType, actionID, spellID =
                        C_SpellBook.GetSpellBookItemType(spellIndex, spellBank)
                    if (spellType == spellItemType or spellType == "SPELL")
                        and (spellID or actionID) then
                        spellID = spellID or actionID
                        local spellInfo
                        if C_Spell and C_Spell.GetSpellInfo then
                            local ok, info = pcall(C_Spell.GetSpellInfo, spellID)
                            if ok then spellInfo = info end
                        end
                        local name = spellInfo and spellInfo.name
                        if not name and GetSpellInfo then
                            local ok, legacyName = pcall(GetSpellInfo, spellID)
                            if ok then name = legacyName end
                        end
                        addSearchableSpell(name,
                            C_SpellBook.GetSpellBookItemTexture(spellIndex, spellBank))
                    end
                end
            end
        end
    elseif GetNumSpellTabs and GetSpellTabInfo and GetSpellBookItemInfo
        and GetSpellBookItemName and GetSpellBookItemTexture then
        for tab = 1, GetNumSpellTabs() do
            local _, _, offset, numSpells = GetSpellTabInfo(tab)
            for spellIndex = offset + 1, offset + numSpells do
                local spellType = GetSpellBookItemInfo(spellIndex, "spell")
                if spellType == "SPELL" or spellType == "FUTURESPELL" then
                    addSearchableSpell(GetSpellBookItemName(spellIndex, "spell"),
                        GetSpellBookItemTexture(spellIndex, "spell"))
                end
            end
        end
    end

    return searchableSpellIcons
end

-- The tooltip for an icon: its name, with the file id behind it, so an icon
-- can be named and handed to someone as text. An icon our list doesn't name
-- shows its id alone.
local function getIconDisplayName(icon)
    local key = tostring(icon)
    local name = getIconName(icon)

    -- An icon our list doesn't name may still be one of the player's spells,
    -- which names it well enough to show.
    if not name then
        for _, spell in ipairs(getSearchableSpellIcons()) do
            if spell.icon == key then
                name = spell.displayName
                break
            end
        end
    end
    if not name then return key end

    name = string.gsub(name, "[/\\]", " ")
    name = string.gsub(name, "[_%-]+", " ")
    name = strtrim(name)
    if name == "" then return key end

    local blue, white = "|cff70A2FF", "|cffffffff"
    -- An icon stored as a name is its own name already; only a file id gets
    -- the name in front of it. The brackets are blue, the text white, so the
    -- id stands out from the name.
    local display = blue .. "(" .. white .. name .. blue .. ")"
    if tonumber(key) then
        display = display .. " " .. blue .. "[" .. white .. key .. blue .. "]"
    end
    return display .. "|r"
end

-- The icon list sliced into rows of COLUMNS, one row per scroll box element.
local function getRows(query)
    local icons = TrialChatCommon.GetMacroIconList()
    query = strtrim(query or "")
    local normalizedQuery = strlower(query)
    local namedIcon = findIconForName(query)
    local rows = {}
    local matches = {}
    local seen = {}
    if namedIcon then
        matches[#matches + 1] = namedIcon
        seen[namedIcon] = true
    end
    if normalizedQuery ~= "" then
        for _, spell in ipairs(getSearchableSpellIcons()) do
            if string.find(spell.name, normalizedQuery, 1, true)
                and not seen[spell.icon] then
                matches[#matches + 1] = spell.icon
                seen[spell.icon] = true
            end
        end
    end
    for _, icon in ipairs(icons) do
        local key = tostring(icon)
        if not seen[key] and (normalizedQuery == ""
            or string.find(getIconSearchName(icon), normalizedQuery, 1, true)) then
            matches[#matches + 1] = icon
            seen[key] = true
        end
    end
    for index = 1, #matches, COLUMNS do
        local row = {}
        for column = 1, COLUMNS do
            row[column] = matches[index + column - 1]
        end
        rows[#rows + 1] = row
    end
    return rows
end

local function updateRows(resetScroll)
    picker.rows = getRows(picker.search:GetText())
    picker.scrollBox:SetDataProvider(CreateDataProvider(picker.rows),
        ScrollBoxConstants.RetainScrollPosition)
    picker.emptyText:SetShown(#picker.rows == 0)
    if resetScroll and #picker.rows > 0 then
        C_Timer.After(0, function()
            if picker:IsShown() and picker.rows and #picker.rows > 0 then
                picker.scrollBox:ScrollToElementDataIndex(1,
                    ScrollBoxConstants.AlignBegin, 0,
                    ScrollBoxConstants.NoScrollInterpolation)
            end
        end)
    end
end

local function updateIconButton(button, icon)
    local texture = TrialChatCommon.GetIconTexture(icon)
    button.preview:SetShown(texture ~= nil)
    if texture then
        button.preview:SetTexture(texture)
    end
end

-- Fills a row frame with its icons; rows are reused as the grid scrolls.
local function initializeRow(row, element)
    row.buttons = row.buttons or {}
    for column = 1, COLUMNS do
        local button = row.buttons[column]
        if not button then
            button = CreateFrame("Button", nil, row)
            button:SetSize(ICON_SIZE, ICON_SIZE)
            button.selected = UI.CreateBox(button, { radius = 6, border = true })
            button.selected:SetColor(Color.selected)
            button.selected:SetBorderColor(Color.accent)
            button.selected:Hide()
            button:SetHighlightTexture(UI.WHITE)
            local highlight = button:GetHighlightTexture()
            highlight:SetAllPoints()
            highlight:SetAlpha(0.12)
            button.icon = button:CreateTexture(nil, "ARTWORK")
            button.icon:SetAllPoints()
            button:SetScript("OnEnter", function(self)
                local tooltip = picker.iconTooltip
                tooltip.text:SetText(getIconDisplayName(self.iconValue))
                tooltip:SetWidth(math.ceil(tooltip.text:GetStringWidth()) + 18)
                tooltip:SetHeight(math.ceil(tooltip.text:GetStringHeight()) + 12)
                tooltip:ClearAllPoints()
                tooltip:SetPoint("BOTTOMLEFT", self, "TOPRIGHT", 4, 4)
                tooltip:Show()
            end)
            button:SetScript("OnLeave", function()
                picker.iconTooltip:Hide()
            end)
            -- Without this a Button never fires OnClick, so the icon could be
            -- looked at but never picked.
            button:RegisterForClicks("LeftButtonUp")
            button:SetScript("OnClick", function(self)
                local onPick = picker.onPick
                picker:Hide()
                if onPick and self.iconValue then
                    onPick(self.iconValue)
                end
            end)
            row.buttons[column] = button
        end

        local value = element[column]
        button.iconValue = value
        button.icon:SetShown(value ~= nil)
        if value then
            button.icon:SetTexture(TrialChatCommon.GetIconTexture(value))
            button.selected:SetShown(value == picker.selected)
        end
        button:SetShown(value ~= nil)
        button:ClearAllPoints()
        button:SetPoint("TOPLEFT", row, "TOPLEFT", (column - 1) * CELL, -3)
    end
end

local function createPicker()
    local frame = CreateFrame("Frame", "TrialChatIconPickerFrame", UIParent)
    frame:SetFrameStrata("FULLSCREEN_DIALOG")
    frame:SetFrameLevel(5000)
    frame:SetSize(WIDTH, HEADER_HEIGHT + BODY_HEIGHT + PADDING)
    frame:SetPoint("CENTER", UIParent, "CENTER", 0, 40)
    frame:SetClampedToScreen(true)
    frame:EnableMouse(true)
    frame:SetMovable(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
    frame.box = UI.CreateBox(frame, { radius = 10, border = true })
    frame.box:SetColor(Color.window)
    frame.box:SetBorderColor(Color.outline)

    frame.iconTooltip = CreateFrame("Frame", nil, frame)
    frame.iconTooltip:SetFrameLevel(frame:GetFrameLevel() + 10)
    frame.iconTooltip:SetClampedToScreen(true)
    frame.iconTooltip:EnableMouse(false)
    frame.iconTooltip.box = UI.CreateBox(frame.iconTooltip, {
        radius = 6,
        border = true,
    })
    frame.iconTooltip.box:SetColor(Color.window)
    frame.iconTooltip.box:SetBorderColor(Color.outline)
    frame.iconTooltip.text = UI.CreateText(
        frame.iconTooltip, UI.Font.small, Color.textSoft)
    frame.iconTooltip.text:SetPoint("CENTER")
    frame.iconTooltip:Hide()

    frame.title = UI.CreateText(frame, UI.Font.item, Color.textSoft)
    frame.title:SetPoint("TOPLEFT", frame, "TOPLEFT", PADDING, -16)
    frame.title:SetText("Choose an icon")

    frame.close = UI.CreateButton(frame, {
        style = "ghost", icon = "close", iconSize = 12, width = 28, height = 28,
        tooltip = "Close", onClick = function() frame:Hide() end,
    })
    frame.close:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -8, -8)

    frame.search = UI.CreateField(frame, {
        height = 30,
        icon = "search",
        insetLeft = 32,
        maxLetters = 64,
        placeholder = "Search name or ID",
    })
    frame.search:SetFontObject(UI.Font.item)
    frame.search.placeholder:SetFontObject(UI.Font.item)
    frame.search:SetPoint("TOPLEFT", frame, "TOPLEFT", PADDING, -46)
    frame.search:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -PADDING - SCROLL_GAP, -46)
    frame.search:HookScript("OnTextChanged", function()
        updateRows(true)
    end)
    frame.search:SetScript("OnEnterPressed", frame.search.ClearFocus)

    local scrollBox = CreateFrame("Frame", nil, frame, "WowScrollBoxList")
    scrollBox:SetPoint("TOPLEFT", frame, "TOPLEFT", PADDING, -HEADER_HEIGHT)
    scrollBox:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -PADDING - SCROLL_GAP, PADDING)
    local scrollBar = CreateFrame("EventFrame", nil, frame, "MinimalScrollBar")
    scrollBar:SetPoint("TOPLEFT", scrollBox, "TOPRIGHT", 2, -4)
    scrollBar:SetPoint("BOTTOMLEFT", scrollBox, "BOTTOMRIGHT", 2, 4)
    frame.scrollBox = scrollBox
    frame.scrollBar = scrollBar

    frame.emptyText = UI.CreateText(frame, UI.Font.small, Color.muted)
    frame.emptyText:SetPoint("CENTER", scrollBox, "CENTER")
    frame.emptyText:SetText("No matching icons")
    frame.emptyText:Hide()

    local view = CreateScrollBoxListLinearView(0, 0, 0, 0, ROW_SPACING)
    view:SetElementExtent(ROW_HEIGHT)
    view:SetElementFactory(function(factory)
        factory("Frame", initializeRow)
    end)
    ScrollUtil.InitScrollBoxListWithScrollBar(scrollBox, scrollBar, view)
    ScrollUtil.AddManagedScrollBarVisibilityBehavior(scrollBox, scrollBar)
    frame.view = view

    -- Any click outside the picker closes it.
    local catcher = CreateFrame("Frame", nil, UIParent)
    catcher:SetAllPoints(UIParent)
    catcher:SetFrameStrata("FULLSCREEN_DIALOG")
    catcher:SetFrameLevel(4999)
    catcher:EnableMouse(true)
    catcher:SetScript("OnMouseDown", function() frame:Hide() end)
    frame.catcher = catcher
    frame:SetScript("OnHide", function()
        catcher:Hide()
        frame.iconTooltip:Hide()
    end)

    tinsert(UISpecialFrames, "TrialChatIconPickerFrame")
    frame:Hide()
    return frame
end

local function scrollToSelected(frame, selected)
    if not selected then return end
    for index, row in ipairs(frame.rows) do
        for _, value in ipairs(row) do
            if value == selected then
                C_Timer.After(0, function()
                    if frame:IsShown() then
                        frame.scrollBox:ScrollToElementDataIndex(index,
                            ScrollBoxConstants.AlignCenter, 0,
                            ScrollBoxConstants.NoScrollInterpolation)
                    end
                end)
                return
            end
        end
    end
end

-- Opens the picker with initialIcon highlighted; onPick(icon) is called with
-- the chosen icon. onPick may be nil to preview without a callback.
function TrialChatIconPicker.Show(initialIcon, onPick)
    if not picker then picker = createPicker() end
    picker.onPick = onPick
    picker.selected = initialIcon
    picker.search:SetText("")
    picker.search:ClearFocus()
    updateRows(false)
    scrollToSelected(picker, picker.selected)
    picker:Show()
    picker:Raise()
    picker.catcher:Show()
    return picker
end

-- An outlined icon button that opens the picker when clicked.
-- Used by the create-group dialog and by a group's menu.
function TrialChatIconPicker.CreateButton(parent, options)
    options = options or {}
    options.style = options.style or "outline"
    local button = UI.CreateButton(parent, options)
    button.preview = button:CreateTexture(nil, "ARTWORK")
    local previewSize = options.previewSize or 22
    button.preview:SetSize(previewSize, previewSize)
    button.preview:SetPoint("CENTER")
    button.previewMask = button:CreateMaskTexture()
    button.previewMask:SetTexture(MEDIA .. "rounded-mask.tga",
        "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
    button.previewMask:SetAllPoints(button.preview)
    button.preview:AddMaskTexture(button.previewMask)
    button.SetIcon = function(self, icon) updateIconButton(self, icon) end
    button.SetIcon(button, nil)
    return button
end
