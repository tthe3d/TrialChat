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

local picker

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
            button:SetScript("OnClick", function(self)
                local onPick = picker.onPick
                picker:Hide()
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
    frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
    frame.box = UI.CreateBox(frame, { radius = 10, border = true })
    frame.box:SetColor(Color.window)
    frame.box:SetBorderColor(Color.outline)

    frame.title = UI.CreateText(frame, UI.Font.item, Color.textSoft)
    frame.title:SetPoint("TOPLEFT", frame, "TOPLEFT", PADDING, -16)
    frame.title:SetText("Emoji")

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
        placeholder = "Search emoji",
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

    -- The emote lists and the "write your own" entry live under the grid, in
    -- the same panel the emoji are picked from.
    local allEmotes = createFooterButton(frame, "All emotes", function()
        frame:Hide()
        if frame.onAllEmotes then frame.onAllEmotes() end
    end)
    allEmotes:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", PADDING, 12)
    local soundEmotes = createFooterButton(frame, "Sound emotes", function()
        frame:Hide()
        if frame.onSoundEmotes then frame.onSoundEmotes() end
    end)
    soundEmotes:SetPoint("LEFT", allEmotes, "RIGHT", 6, 0)
    local writeOwn = createFooterButton(frame, "Make your own", function()
        frame:Hide()
        if frame.onWriteOwn then frame.onWriteOwn() end
    end)
    writeOwn:SetPoint("LEFT", soundEmotes, "RIGHT", 6, 0)

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
        GameTooltip_Hide()
    end)

    tinsert(UISpecialFrames, "TrialChatEmojiPickerFrame")
    frame:Hide()
    return frame
end

-- Opens the picker. options.onPick(entry) is called with the chosen emoticon;
-- options.onAllEmotes(button) and options.onSoundEmotes(button) open the emote
-- lists, and options.onWriteOwn() starts a custom emote.
function TrialChatEmojiPicker.Show(options)
    if not picker then picker = createPicker() end
    options = options or {}
    picker.onPick = options.onPick
    picker.onAllEmotes = options.onAllEmotes
    picker.onSoundEmotes = options.onSoundEmotes
    picker.onWriteOwn = options.onWriteOwn
    picker.search:SetText("")
    picker.search:ClearFocus()
    updateRows(false)
    picker:Show()
    picker:Raise()
    picker.catcher:Show()
    return picker
end

function TrialChatEmojiPicker.Hide()
    if picker then picker:Hide() end
end
