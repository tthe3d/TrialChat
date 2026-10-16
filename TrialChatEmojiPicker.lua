-- The emoji picker: a grid of the emoticons in Media/Emoji, so one can be
-- dropped into the message box by clicking it. Animated emoticons play here,
-- drawn a cell at a time from their sprite sheet. Opened from the smiley
-- button next to the message box, which also offers the emote lists below it.
TrialChatEmojiPicker = {}
local UI = TrialChatUI
local Color = UI.Color

local COLUMNS = 10
local ICON_SIZE = 28
local CELL = 36
local ROW_HEIGHT = 36
local ROW_SPACING = 4
local PADDING = 12
local HEADER_HEIGHT = 84
local BODY_HEIGHT = 300
local FOOTER_HEIGHT = 48
local SCROLL_GAP = 14
local WIDTH = PADDING * 2 + COLUMNS * CELL + SCROLL_GAP

-- The emote list that pops out to the right of the picker: the same kind of
-- list as the members panel in the main window.
local PANEL_WIDTH = 190
local PANEL_HEADER_HEIGHT = 34
local PANEL_ROW_HEIGHT = 26

local picker

-- Whether the cursor is over a frame, no matter what lies on top of it. The
-- catcher covers the whole screen while the picker is up, so a hit test that
-- respected stacking would always say no.
local function cursorOver(region)
    if not region or not region:IsShown() then return false end
    local left, right = region:GetLeft(), region:GetRight()
    local bottom, top = region:GetBottom(), region:GetTop()
    if not left or not right or not bottom or not top then return false end
    local scale = region:GetEffectiveScale()
    local x, y = GetCursorPosition()
    x, y = x / scale, y / scale
    return x >= left and x <= right and y >= bottom and y <= top
end

-- The emoji list sliced into rows of COLUMNS, one row per scroll box element.
local function getRows(query)
    query = strtrim(query or "")
    local normalized = strlower(query)
    local matches = {}
    for _, entry in ipairs(TrialChatCommon.EmojiList) do
        if normalized == ""
            or string.find(strlower(entry.name), normalized, 1, true)
            or string.find(strlower(entry.shortcut), normalized, 1, true)
            or string.find(strlower(entry.file), normalized, 1, true) then
            matches[#matches + 1] = entry
        end
    end
    local rows = {}
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

-- Every emote of one kind, sorted, ready for the panel's list. All emotes are
-- the ones behind "/", sound emotes the ones behind "//".
local function emoteElements(isSound)
    local source = (isSound and TrialChatCommon.SoundEmotes
        or TrialChatCommon.EmoteDescriptions) or {}
    local names = {}
    for name in pairs(source) do
        names[#names + 1] = name
    end
    table.sort(names)
    local elements = {}
    for index = 1, #names do
        local name = names[index]
        elements[index] = {
            text = name,
            isSound = isSound,
            description = isSound and nil or source[name],
        }
    end
    return elements
end

-- A row in the emote list: the emote's name, and a click that sends it to the
-- conversation. Text emotes get a tooltip with what they do; sound emotes are
-- just a name and a sound, so hovering them shows nothing.
local function initializeEmoteRow(row, element)
    if not row.label then
        row:SetHighlightTexture(UI.WHITE)
        local highlight = row:GetHighlightTexture()
        highlight:SetAllPoints()
        highlight:SetAlpha(0.08)
        row.label = UI.CreateText(row, UI.Font.item, Color.textSoft)
        row.label:SetPoint("LEFT", row, "LEFT", 10, 0)
        row.label:SetPoint("RIGHT", row, "RIGHT", -10, 0)
        row.label:SetJustifyH("LEFT")
        row.label:SetWordWrap(false)
        row:RegisterForClicks("LeftButtonUp")
        row:SetScript("OnClick", function(self)
            local chosen = self.element
            if chosen and picker.onEmote then
                picker.onEmote(chosen.text, chosen.isSound)
            end
        end)
        row:SetScript("OnEnter", function(self)
            local chosen = self.element
            if not chosen or chosen.isSound then return end
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText(chosen.text)
            if chosen.description and chosen.description ~= "" then
                GameTooltip:AddLine(chosen.description, 1, 1, 1, true)
            end
            GameTooltip:AddLine("/" .. chosen.text, 0.6, 0.6, 0.6)
            GameTooltip:Show()
        end)
        row:SetScript("OnLeave", function()
            GameTooltip_Hide()
        end)
    end
    -- Rows are reused as the list scrolls.
    row.element = element
    row.label:SetText(element.text)
end

-- Fills the side panel with one of the emote lists. The picker stays up so
-- the other list (or an emoji) can still be picked.
local function showEmoteList(mode)
    local isSound = mode == "sound"
    local panel = picker.emotePanel
    panel.title:SetText(isSound and "Sound emotes" or "All emotes")
    panel.emoteList:SetDataProvider(CreateDataProvider(emoteElements(isSound)),
        ScrollBoxConstants.RetainScrollPosition)
    C_Timer.After(0, function()
        if picker:IsShown() and panel.emoteList then
            panel.emoteList:ScrollToElementDataIndex(1,
                ScrollBoxConstants.AlignBegin, 0,
                ScrollBoxConstants.NoScrollInterpolation)
        end
    end)
    UI.SetButtonActive(picker.allButton, not isSound)
    UI.SetButtonActive(picker.soundButton, isSound)
    panel:Show()
end

-- The list window that appears to the right of the picker when "All emotes"
-- or "Sound emotes" is pressed, built like the picker itself.
local function createEmotePanel(frame)
    local panel = CreateFrame("Frame", nil, frame)
    panel:SetPoint("TOPLEFT", frame, "TOPRIGHT", 6, 0)
    panel:SetPoint("BOTTOMLEFT", frame, "BOTTOMRIGHT", 6, 0)
    panel:SetWidth(PANEL_WIDTH)
    -- Above the catcher that closes everything on an outside click.
    panel:SetFrameLevel(frame:GetFrameLevel() + 1)
    -- Swallow clicks on the panel's padding, so only a click outside both the
    -- picker and the list closes them.
    panel:EnableMouse(true)
    panel.box = UI.CreateBox(panel, { radius = 10, border = true })
    panel.box:SetColor(Color.window)
    panel.box:SetBorderColor(Color.outline)

    panel.title = UI.CreateText(panel, UI.Font.item, Color.textSoft)
    panel.title:SetPoint("TOPLEFT", panel, "TOPLEFT", 12, -12)
    panel.title:SetText("All emotes")

    panel.emoteList = CreateFrame("Frame", nil, panel, "WowScrollBoxList")
    panel.emoteList:SetPoint("TOPLEFT", panel, "TOPLEFT", 6, -PANEL_HEADER_HEIGHT)
    panel.emoteList:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT",
        -6 - SCROLL_GAP, 8)
    local scrollBar = CreateFrame("EventFrame", nil, panel, "MinimalScrollBar")
    scrollBar:SetPoint("TOPLEFT", panel.emoteList, "TOPRIGHT", 2, -4)
    scrollBar:SetPoint("BOTTOMLEFT", panel.emoteList, "BOTTOMRIGHT", 2, 4)
    panel.scrollBar = scrollBar

    local view = CreateScrollBoxListLinearView(0, 0, 0, 0, 0)
    view:SetElementExtent(PANEL_ROW_HEIGHT)
    view:SetElementFactory(function(factory)
        factory("Button", initializeEmoteRow)
    end)
    ScrollUtil.InitScrollBoxListWithScrollBar(panel.emoteList, scrollBar, view)
    ScrollUtil.AddManagedScrollBarVisibilityBehavior(panel.emoteList, scrollBar)
    panel.view = view

    panel:Hide()
    return panel
end

-- Points an icon texture at the cell of an emoticon's sprite sheet that is
-- showing right now. The crop is inset by half a texel on each side, so the
-- neighbouring cells don't bleed into the edge of this one.
local function showEmojiFrame(icon, entry)
    local count = entry.frames
    local cell = entry.cell or 19
    local frame = TrialChatCommon.EmojiFrame(entry, GetTime())
    local inset = 0.5 / (count * cell)
    icon:SetTexCoord((frame - 1) / count + inset, frame / count - inset, 0, 1)
end

-- Draws an emoticon on a button: animated ones step through their sprite
-- sheet on every frame, the rest show their single picture.
local function showEmoji(button, entry)
    local icon = button.icon
    if not entry then
        button.emoji = nil
        icon:SetTexture(nil)
        return
    end
    button.emoji = entry
    local directory = TrialChatCommon.EmojiDirectory
    if entry.frames then
        icon:SetTexture(directory .. entry.file .. "-frames.png")
        showEmojiFrame(icon, entry)
    else
        icon:SetTexture(directory .. entry.file .. ".png")
        icon:SetTexCoord(0, 1, 0, 1)
    end
end

-- Fills a row frame with its emoticons; rows are reused as the grid scrolls.
local function initializeRow(row, element)
    row.buttons = row.buttons or {}
    for column = 1, COLUMNS do
        local button = row.buttons[column]
        if not button then
            button = CreateFrame("Button", nil, row)
            button:SetSize(ICON_SIZE, ICON_SIZE)
            button:SetHighlightTexture(UI.WHITE)
            local highlight = button:GetHighlightTexture()
            highlight:SetAllPoints()
            highlight:SetAlpha(0.12)
            button.icon = button:CreateTexture(nil, "ARTWORK")
            button.icon:SetAllPoints()
            button:SetScript("OnEnter", function(self)
                if not self.emoji then return end
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:SetText(self.emoji.name)
                GameTooltip:AddLine(self.emoji.shortcut, 1, 1, 1)
                GameTooltip:Show()
            end)
            button:SetScript("OnLeave", function()
                GameTooltip_Hide()
            end)
            button:SetScript("OnUpdate", function(self)
                local emoji = self.emoji
                if not emoji or not emoji.frames then return end
                showEmojiFrame(self.icon, emoji)
            end)
            -- Without this a Button never fires OnClick, so an emoji could be
            -- looked at but never picked.
            button:RegisterForClicks("LeftButtonUp")
            -- Picking an emoticon leaves the picker open, so several can be
            -- dropped into the message box in a row. It closes when the
            -- message box (or anywhere else outside) is clicked.
            button:SetScript("OnClick", function(self)
                local onPick = picker.onPick
                if onPick and self.emoji then
                    onPick(self.emoji)
                end
            end)
            row.buttons[column] = button
        end

        local entry = element[column]
        showEmoji(button, entry)
        button:SetShown(entry ~= nil)
        button:ClearAllPoints()
        button:SetPoint("TOPLEFT", row, "TOPLEFT", (column - 1) * CELL, -4)
    end
end

local function createFooterButton(frame, text, onClick)
    local button = UI.CreateButton(frame, {
        style = "outline", text = text, height = 26, radius = 13,
        font = UI.Font.small, onClick = onClick,
    })
    return button
end

local function createPicker()
    local frame = CreateFrame("Frame", "TrialChatEmojiPickerFrame", UIParent)
    frame:SetFrameStrata("FULLSCREEN_DIALOG")
    frame:SetFrameLevel(5000)
    frame:SetSize(WIDTH, HEADER_HEIGHT + BODY_HEIGHT + FOOTER_HEIGHT + PADDING)
    frame:SetPoint("CENTER", UIParent, "CENTER", 0, 40)
    frame:SetClampedToScreen(true)
    frame:EnableMouse(true)
    frame:SetMovable(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        -- Dragging drops the keyboard focus, so hand it back to the message
        -- box: writing carries on while the picker is moved around.
        if self.input then self.input:SetFocus() end
    end)
    frame.box = UI.CreateBox(frame, { radius = 10, border = true })
    frame.box:SetColor(Color.window)
    frame.box:SetBorderColor(Color.outline)

    frame.title = UI.CreateText(frame, UI.Font.item, Color.textSoft)
    frame.title:SetPoint("TOPLEFT", frame, "TOPLEFT", PADDING, -16)
    frame.title:SetText("Emoji")

    frame.close = UI.CreateButton(frame, {
        style = "ghost", icon = "close", iconSize = 12, width = 28, height = 28,
        tooltip = "Close",
        -- Closing the picker keeps the message box focused, so writing carries
        -- on rather than stopping with the picker.
        onClick = function()
            if frame.input then frame.input:SetFocus() end
            frame:Hide()
        end,
    })
    frame.close:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -8, -8)

    frame.search = UI.CreateField(frame, {
        height = 30,
        icon = "search",
        insetLeft = 32,
        maxLetters = 64,
        placeholder = "Search emoji",
    })
    frame.search:SetFontObject(UI.Font.item)
    frame.search.placeholder:SetFontObject(UI.Font.item)
    frame.search:SetPoint("TOPLEFT", frame, "TOPLEFT", PADDING, -46)
    frame.search:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -PADDING - SCROLL_GAP, -46)
    frame.search:HookScript("OnTextChanged", function()
        updateRows(true)
    end)
    -- Leaving the search for the picker's empty space shouldn't end writing
    -- either: hand the keyboard back to the message box.
    frame.search:HookScript("OnEditFocusLost", function()
        C_Timer.After(0, function()
            if frame:IsShown() and frame.input
                and not frame.search:HasFocus() and not frame.input:HasFocus() then
                frame.input:SetFocus()
            end
        end)
    end)
    frame.search:SetScript("OnEnterPressed", frame.search.ClearFocus)
    -- Escape in the search closes the picker and hands writing back to the
    -- message box, rather than just leaving the field.
    frame.search:SetScript("OnEscapePressed", function(self)
        self:ClearFocus()
        -- Focus the message box first, so the window never dims on the way out.
        if frame.input then frame.input:SetFocus() end
        frame:Hide()
    end)

    local scrollBox = CreateFrame("Frame", nil, frame, "WowScrollBoxList")
    scrollBox:SetPoint("TOPLEFT", frame, "TOPLEFT", PADDING, -HEADER_HEIGHT)
    scrollBox:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT",
        -PADDING - SCROLL_GAP, PADDING + FOOTER_HEIGHT)
    local scrollBar = CreateFrame("EventFrame", nil, frame, "MinimalScrollBar")
    scrollBar:SetPoint("TOPLEFT", scrollBox, "TOPRIGHT", 2, -4)
    scrollBar:SetPoint("BOTTOMLEFT", scrollBox, "BOTTOMRIGHT", 2, 4)
    frame.scrollBox = scrollBox
    frame.scrollBar = scrollBar

    frame.emptyText = UI.CreateText(frame, UI.Font.small, Color.muted)
    frame.emptyText:SetPoint("CENTER", scrollBox, "CENTER")
    frame.emptyText:SetText("No matching emoji")
    frame.emptyText:Hide()

    local view = CreateScrollBoxListLinearView(0, 0, 0, 0, ROW_SPACING)
    view:SetElementExtent(ROW_HEIGHT)
    view:SetElementFactory(function(factory)
        factory("Frame", initializeRow)
    end)
    ScrollUtil.InitScrollBoxListWithScrollBar(scrollBox, scrollBar, view)
    ScrollUtil.AddManagedScrollBarVisibilityBehavior(scrollBox, scrollBar)
    frame.view = view

    -- The emote lists pop out to the right of the picker, so they no longer
    -- hide it. "Make your own" keeps its old behaviour of closing the picker
    -- and starting a custom emote in the message box.
    frame.emotePanel = createEmotePanel(frame)
    frame.allButton = createFooterButton(frame, "All emotes", function()
        showEmoteList("all")
    end)
    frame.allButton:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", PADDING, 12)
    frame.soundButton = createFooterButton(frame, "Sound emotes", function()
        showEmoteList("sound")
    end)
    frame.soundButton:SetPoint("LEFT", frame.allButton, "RIGHT", 6, 0)
    local writeOwn = createFooterButton(frame, "Make your own", function()
        frame:Hide()
        if frame.onWriteOwn then frame.onWriteOwn() end
    end)
    writeOwn:SetPoint("LEFT", frame.soundButton, "RIGHT", 6, 0)

    -- Any click outside the picker closes it.
    local catcher = CreateFrame("Frame", nil, UIParent)
    catcher:SetAllPoints(UIParent)
    catcher:SetFrameStrata("FULLSCREEN_DIALOG")
    catcher:SetFrameLevel(4999)
    catcher:EnableMouse(true)
    catcher:SetScript("OnMouseDown", function()
        frame:Hide()
        -- Clicking the message box closes the picker and starts typing there.
        local input = frame.input
        if input and cursorOver(input) then
            input:SetFocus()
        end
    end)
    frame.catcher = catcher
    frame:SetScript("OnHide", function()
        catcher:Hide()
        GameTooltip_Hide()
        if frame.onClose then frame.onClose() end
    end)

    tinsert(UISpecialFrames, "TrialChatEmojiPickerFrame")
    frame:Hide()
    return frame
end

-- Opens the picker. options.onPick(entry) is called with the chosen emoticon;
-- options.onEmote(name, isSound) is called when an entry in the emote list is
-- clicked; options.onWriteOwn() starts a custom emote. options.input is the
-- message box: clicking it closes the picker and focuses it. options.onClose()
-- runs when the picker closes, so the window can fade back.
function TrialChatEmojiPicker.Show(options)
    if not picker then picker = createPicker() end
    options = options or {}
    picker.onPick = options.onPick
    picker.onEmote = options.onEmote
    picker.onWriteOwn = options.onWriteOwn
    picker.onClose = options.onClose
    picker.input = options.input
    picker.emotePanel:Hide()
    UI.SetButtonActive(picker.allButton, false)
    UI.SetButtonActive(picker.soundButton, false)
    picker.search:SetText("")
    picker.search:ClearFocus()
    updateRows(false)
    picker:Show()
    picker:Raise()
    picker.catcher:Show()
    return picker
end

function TrialChatEmojiPicker.IsShown()
    return picker ~= nil and picker:IsShown()
end

-- Whether the picker's search box is the one holding the keyboard.
function TrialChatEmojiPicker.IsSearchFocused()
    return picker ~= nil and picker.search ~= nil and picker.search:HasFocus()
end

function TrialChatEmojiPicker.Hide()
    if picker then picker:Hide() end
end
