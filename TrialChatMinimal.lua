-- The minimal view of TrialChat, split in two windows. The main window is
-- laid out: a toolbar across the top, the conversations under it and a
-- message box at the bottom. The chat window above it holds the newest
-- messages of the open conversation, fading with age like the chat frames
-- and shrinking as the text goes; when no text is left, it hides. Clicking
-- empty space in either window shows the conversation's history fully lit
-- for as long as you are using it. When another conversation gets a message,
-- a notice shows in the corner, and an invite to a group shows between the
-- two windows.
TrialChatMinimalView = {}
local UI = TrialChatUI
local Color = UI.Color

-- The width you can drag the windows to, and how tall the chat window can
-- grow; the main window's width and the chat's height.
local DEFAULT_WIDTH = 520
local MIN_WIDTH, MAX_WIDTH = 320, 1000
local DEFAULT_AREA_HEIGHT = 200
local MIN_AREA_HEIGHT, MAX_AREA_HEIGHT = 60, 600
-- Messages kept to show; as many as fit are on screen. The conversation's
-- whole stored history is loaded with them, like in the full view (it is
-- capped where it is stored); this is only a backstop for very long
-- sessions.
local MAX_LINES = 2000
-- Pixels scrolled per mouse wheel notch.
local SCROLL_PIXELS = 30
-- Messages are pills like the conversations: as tall as them for one line,
-- with the same rounded ends, and rounded boxes when they wrap.
local LINE_GAP = 4
local LINE_PADDING_X = 12
local LINE_PADDING_Y = 6
local LINE_MIN_HEIGHT = 26
local LINE_RADIUS = 13
local LINE_VISIBLE_SECONDS = 30
local LINE_FADE_SECONDS = 4
-- How far down from the top edge of the message area a line that only
-- partly fits fades out, by the middle of what is still shown of it (see
-- UpdateFade).
local TOP_FADE_HEIGHT = 24
-- While you aren't using the view, older lines are dimmer (newest first).
local LINE_ALPHA_BY_AGE = { 1, 1, 0.8, 0.55 }
local OLDEST_LINE_ALPHA = 0.35
local PILL_HEIGHT = 26
local PILL_GAP = 6
-- How far the mouse has to drag the resize grip before it resizes at all.
local RESIZE_DRAG_THRESHOLD = 3
-- Room kept between the view's edges and the screen's when it is at its
-- biggest. A frame exactly as large as the screen has only one position it
-- can be in, so it could never be dragged anywhere; the margin leaves it
-- room to move, and keeps the resize grips clear of the screen's edge.
local SCREEN_MARGIN = 64
local ROW_GAP = 8
local COMPOSER_HEIGHT = 38
-- A reply shown above the message box: who and what is being answered.
local REPLY_BAR_HEIGHT = 28

-- The right-click menu, in this view's colors (dark pills on the world).
local MENU_THEME = {
    bg = Color.sidebar, bgAlpha = 0.96,
    border = Color.white, borderAlpha = 0.16,
    radius = 10,
    hover = Color.white, hoverAlpha = 0.08,
    text = Color.textSoft,
    font = UI.Font.item,
    itemHeight = 24,
    padding = 5,
    minWidth = 120,
}
-- Room between the panel's edge and what's in it.
local PADDING = 10
local PANEL_RADIUS = 13
-- The panel's outline. The toolbar's outline is in the same colour and
-- alpha, so its curve is one line with the chat box's.
local PANEL_LINE_ALPHA = 0.08
-- The toolbar across the top of the main window, above the conversations,
-- holding the little window buttons on the left like a Mac window's: red
-- closes the chat, green opens the full window. It is as tall as two of the
-- panel's corner curves, so its top corners are the window's own curve and
-- its outline is one line with the window's. The pin and the resize grip
-- sit at its right end.
local WINDOW_BUTTON_SIZE = 12
local WINDOW_BUTTON_GAP = 6
local CONTROLS_HEIGHT = 2 * PANEL_RADIUS
local WINDOW_BUTTON_PADDING = (CONTROLS_HEIGHT - WINDOW_BUTTON_SIZE) / 2
local RESIZER_SIZE = 14
local RESIZER_PADDING = (CONTROLS_HEIGHT - RESIZER_SIZE) / 2
local PIN_SIZE = 16
local CLOSE_COLOR = { 1, 0.37, 0.34 }
local MAXIMIZE_COLOR = { 0.16, 0.78, 0.25 }
-- The chat window's own strip for its close button and resize grip.
local CHAT_HEADER_HEIGHT = 22
local CHAT_BOTTOM_PADDING = 8
-- The main window's smallest height: the toolbar, a row of conversation
-- pills and the message box, with the usual gaps. Dragging its grip adds
-- room between the pills and the message box.
local BASE_MAIN_HEIGHT = CONTROLS_HEIGHT + 2 * ROW_GAP + PILL_HEIGHT
    + COMPOSER_HEIGHT + PADDING
local IDLE_ALPHA = 0.45
local RECENT_SECONDS = 7
local RECENT_CHAT_KEEP_SECONDS = 10
local UPDATE_SECONDS = 0.1
local TOAST_WIDTH = 300
local TOAST_SECONDS = 8
local DEFAULT_X, DEFAULT_Y = 40, 300

local View = {}
View.__index = View

local function clamp(value, low, high)
    return math.max(low, math.min(high, value))
end

local function colorForName(name)
    return UI.ClassColor(TrialChatNearby:GetClass(name)) or Color.textSoft
end

-- The quoted part of a reply, muted, on a line of its own above the message.
-- It is drawn as a link, so clicking it jumps back to the message it quotes.
local function replyLine(reply, colorFor)
    local sender = TrialChatCommon.ShortName(reply.sender or "?")
    local text = TrialChatCommon.RemovePlayerLinks(reply.text or "")
    return TrialChatCommon.ReplyLink(
        UI.ColorText(Color.muted, "> ")
            .. UI.ColorText(colorFor({ sender = reply.sender }), sender)
            .. UI.ColorText(Color.muted, ": " .. text))
end

-- The keybinding to reply with, when there is one.
local function getReplyHint()
    local key = GetBindingKey and GetBindingKey("TRIALCHAT_OPEN")
    if key then
        return "Press " .. (GetBindingText and GetBindingText(key) or key) .. " to reply"
    end
    return "Click to reply"
end

-- The biggest the windows may get, kept a margin away from the screen's
-- edge so the grips stay grabbable (see SCREEN_MARGIN).
local function maxContentWidth()
    local width = MAX_WIDTH
    local parentWidth = UIParent:GetWidth()
    if parentWidth and parentWidth > 0 then
        width = math.min(width, parentWidth - SCREEN_MARGIN - 2 * PADDING)
    end
    return math.max(MIN_WIDTH, width)
end

local function maxContentHeight()
    local height = MAX_AREA_HEIGHT
    local parentHeight = UIParent:GetHeight()
    if parentHeight and parentHeight > 0 then
        height = math.min(height, parentHeight - SCREEN_MARGIN)
    end
    return math.max(MIN_AREA_HEIGHT, height)
end

-- The main window's own height can be dragged too, but never below the
-- toolbar, pills and message box, and never taller than the screen.
local function maxMainHeight()
    local height = maxContentHeight()
    local parentHeight = UIParent:GetHeight()
    if parentHeight and parentHeight > 0 then
        height = math.min(height, parentHeight - SCREEN_MARGIN)
    end
    return math.max(BASE_MAIN_HEIGHT, height)
end

-- The sizes a resize grip may set, rounded to whole units and kept in range.
local function resizeWidth(width)
    return clamp(math.floor(width + 0.5), MIN_WIDTH, maxContentWidth())
end

local function resizeMainHeight(height)
    return clamp(math.floor(height + 0.5), BASE_MAIN_HEIGHT, maxMainHeight())
end

local function resizeChatHeight(height)
    return clamp(math.floor(height + 0.5), MIN_AREA_HEIGHT, maxContentHeight())
end

-- The cursor's position in UI units, for the resize grips (which resize
-- both windows by hand, as one of them can be anchored to the other).
local function cursorPosition()
    local x, y = GetCursorPosition()
    local scale = UIParent:GetEffectiveScale()
    return x / scale, y / scale
end

---------------------------------------------------------------------------
-- Window buttons
---------------------------------------------------------------------------
-- The little window buttons, like a Mac window's traffic lights: red closes
-- the chat, green opens the full window. They take the mouse where they are
-- so they can be clicked.
function View:CreateWindowButton(color, icon, tooltip, onClick)
    local button = CreateFrame("Button", nil, self.controls)
    button:SetSize(WINDOW_BUTTON_SIZE, WINDOW_BUTTON_SIZE)
    button.box = UI.CreateBox(button, { radius = WINDOW_BUTTON_SIZE / 2, border = true })
    button.box:SetColor(color)
    -- A slightly darker ring around the dot, the way the real ones have.
    button.box:SetBorderColor({ color[1] * 0.55, color[2] * 0.55, color[3] * 0.55 })
    button:SetAlpha(1)
    -- The little symbol only shows while the cursor is on the button.
    button.glyph = UI.CreateIcon(button, icon, 7, Color.black, "OVERLAY")
    button.glyph:SetPoint("CENTER")
    button.glyph:Hide()
    button:RegisterForClicks("LeftButtonUp")
    button:SetScript("OnClick", onClick)
    button:SetScript("OnEnter", function(self)
        self.glyph:Show()
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(tooltip, nil, nil, nil, nil, true)
        GameTooltip:Show()
    end)
    button:SetScript("OnLeave", function(self)
        self.glyph:Hide()
        GameTooltip_Hide()
    end)
    return button
end

function View:CreateWindowButtons()
    -- Part of the chrome, so the toolbar fades with the rest of the view.
    local controls = CreateFrame("Frame", nil, self.chrome)
    self.controls = controls
    controls:SetHeight(CONTROLS_HEIGHT)
    controls:SetPoint("TOPLEFT", self.frame, "TOPLEFT")
    controls:SetPoint("TOPRIGHT", self.frame, "TOPRIGHT")
    controls:SetFrameLevel(self.chrome:GetFrameLevel() + 40)
    local fieldCorners = {
        TOPLEFT = true,
        TOPRIGHT = true,
        BOTTOMRIGHT = false,
        BOTTOMLEFT = false,
    }
    controls.box = UI.CreateBox(controls, { radius = PANEL_RADIUS, corners = fieldCorners, border = true })
    controls.box:SetColor(Color.sidebar, 0.85)
    controls.box:SetBorderColor(Color.white, PANEL_LINE_ALPHA)
    controls:SetAlpha(1)
    controls:EnableMouse(true)
    controls:EnableMouseWheel(true)
    controls:SetScript("OnMouseWheel", function(_, delta)
        self:Scroll(delta * SCROLL_PIXELS)
    end)
    local close = self:CreateWindowButton(CLOSE_COLOR, "close", "Close chat", function()
        self:Hide()
    end)
    close:SetPoint("TOPLEFT", controls, "TOPLEFT",
        WINDOW_BUTTON_PADDING, -WINDOW_BUTTON_PADDING)
    local maximize = self:CreateWindowButton(MAXIMIZE_COLOR, "expand",
        "Open the full TrialChat window", function()
            self.controller.ShowFullView()
        end)
    maximize:SetPoint("LEFT", close, "RIGHT", WINDOW_BUTTON_GAP, 0)
    -- The bar covers the top strip of the window, so it takes over dragging
    -- from there; the buttons still take their own clicks. Empty space on
    -- it opens the chat, like the rest of the window.
    self:DragBy(controls)
    controls:SetScript("OnMouseUp", function(_, button)
        if button == "LeftButton" and self:IsClick() then
            self:Expand()
        end
    end)
    return controls
end

-- controller gives the view its data and does what it asks:
-- GetSelected(), Select(key), Cycle(step), GetConversations() (Nearby and
-- connected groups as { key, name, unread }), GetEntries() (the open
-- conversation's history, how to format a message and color a name),
-- GetName(), GetMessageLimit(), Send(text), ShowFullView(), GetSettings(),
-- AnswerInvite(join), OnShown() and OnHidden().
function TrialChatMinimalView.Create(controller)
    local view = setmetatable({
        controller = controller, lines = {}, chips = {}, pills = {},
        scroll = 0, newCount = 0, expanded = false, chatClosed = false,
        areaShown = 0, neededArea = 0,
    }, View)

    local settings = controller.GetSettings()
    view.width = clamp(tonumber(settings.minimalWidth) or DEFAULT_WIDTH, MIN_WIDTH, MAX_WIDTH)
    view.pinned = settings.minimalPinned == true
    view.chatWidth = view.pinned and view.width
        or clamp(tonumber(settings.minimalChatWidth) or view.width, MIN_WIDTH, MAX_WIDTH)
    view.chatAreaHeight = clamp(
        tonumber(settings.minimalChatHeight) or tonumber(settings.minimalHeight)
            or DEFAULT_AREA_HEIGHT,
        MIN_AREA_HEIGHT, MAX_AREA_HEIGHT)
    view.mainHeight = clamp(tonumber(settings.minimalMainHeight) or BASE_MAIN_HEIGHT,
        BASE_MAIN_HEIGHT, maxMainHeight())

    -- The main window: toolbar, conversations and message box. Its height
    -- and width are dragged by hand; messages never change its size.
    local frame = CreateFrame("Frame", "TrialChatMinimalFrame", UIParent)
    view.frame = frame
    frame:SetWidth(view.width + 2 * PADDING)
    frame:SetFrameStrata("MEDIUM")
    frame:SetClampedToScreen(true)
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:EnableMouseWheel(true)
    view:UpdateMainHeight()
    view:DragBy(frame)
    view:RestorePosition()

    -- Everything but the messages fades back while you aren't using it.
    view.chrome = CreateFrame("Frame", nil, frame)
    view.chrome:SetAllPoints()
    -- One rounded panel behind it all, fading with the rest.
    view.panel = UI.CreateBox(view.chrome, { radius = PANEL_RADIUS, border = true })
    view.panel:SetColor(Color.sidebar, 0.8)
    view.panel:SetBorderColor(Color.white, PANEL_LINE_ALPHA)
    view:CreateComposer()
    view:CreateWindowButtons()
    view:CreateResizer()

    -- The chat window: the messages, with its own panel, close button and
    -- resize grip. It sits above the main window while pinned, and keeps its
    -- own place while not.
    local chat = CreateFrame("Frame", "TrialChatMinimalChatFrame", UIParent)
    view.chat = chat
    chat:SetFrameStrata("MEDIUM")
    chat:SetFrameLevel(frame:GetFrameLevel() + 60)
    chat:SetClampedToScreen(true)
    chat:SetMovable(true)
    chat:EnableMouse(true)
    chat:EnableMouseWheel(true)
    chat:SetWidth(view.chatWidth + 2 * PADDING)
    chat:SetHeight(CHAT_HEADER_HEIGHT + view.chatAreaHeight + CHAT_BOTTOM_PADDING)
    view:SetupChatDrag(chat, true)
    -- Shown only when UpdateFade says so (there is text to show, or the
    -- chat has been opened), never as an empty panel at start-up.
    chat:Hide()

    view.chatChrome = CreateFrame("Frame", nil, chat)
    view.chatChrome:SetAllPoints()
    view.chatChrome:SetFrameLevel(chat:GetFrameLevel() + 1)
    view.chatPanel = UI.CreateBox(view.chatChrome, { radius = PANEL_RADIUS, border = true })
    view.chatPanel:SetColor(Color.sidebar, 0.8)
    view.chatPanel:SetBorderColor(Color.white, PANEL_LINE_ALPHA)
    view:CreateChatControls()
    view:CreateMessageArea()
    -- A hidden text frame used to measure message heights for pixel-based
    -- scrolling, so a wheel notch moves a fixed number of pixels instead of
    -- skipping a whole (possibly tall) message.
    view.measure = view.messageArea:CreateFontString(nil, "ARTWORK")
    view.measure:SetFontObject(UI.Font.body)
    view.measure:SetWordWrap(true)
    view.measure:SetNonSpaceWrap(true)
    view.measure:Hide()

    view.newestButton = UI.CreateButton(chat, {
        style = "hud", icon = "arrowDown", iconSize = 12, text = "Newest",
        height = PILL_HEIGHT, radius = 13, font = UI.Font.small,
        onClick = function() view:ScrollToNewest() end,
    })
    view.newestButton:SetFrameLevel(chat:GetFrameLevel() + 40)
    view.newestButton:Hide()
    -- Not part of the chrome, so it doesn't fade while it waits for you.
    view.inviteCard = UI.CreateInviteCard(frame, function(join) controller.AnswerInvite(join) end)
    view.inviteCard:SetFrameLevel(view.chrome:GetFrameLevel() + 10)
    view:PositionChat()
    view:CreateToast()

    local sinceUpdate = 0
    frame:SetScript("OnUpdate", function(_, elapsed)
        sinceUpdate = sinceUpdate + elapsed
        if sinceUpdate >= UPDATE_SECONDS then
            sinceUpdate = 0
            view:UpdateFade()
        end
    end)
    frame:SetScript("OnMouseWheel", function(_, delta)
        view:MarkChatRecent()
        view:Scroll(delta * SCROLL_PIXELS)
    end)
    chat:SetScript("OnMouseWheel", function(_, delta)
        view:MarkChatRecent()
        view:Scroll(delta * SCROLL_PIXELS)
    end)
    -- Clicking empty space in the main window unshrinks the chat.
    frame:SetScript("OnMouseUp", function(_, button)
        if button == "LeftButton" and view:IsClick() then
            view:MarkChatRecent()
            view:Expand()
        end
    end)
    frame:SetScript("OnShow", function()
        controller.OnShown()
        view:UpdateFade()
    end)
    frame:SetScript("OnHide", function()
        view:StopDrag()
        view:StopResizing()
        view.input:ClearFocus()
        view.chat:Hide()
        controller.OnHidden()
    end)
    frame:Hide()
    return view
end

-- The main window can be dragged by its toolbar, its message box, and any
-- empty space in it.
function View:DragBy(region)
    region:RegisterForDrag("LeftButton")
    region:SetScript("OnMouseDown", function(_, button)
        if button == "LeftButton" then
            self.pressX, self.pressY = cursorPosition()
        end
    end)
    region:SetScript("OnDragStart", function()
        self:StartDrag("main")
    end)
    region:SetScript("OnDragStop", function()
        self:StopDrag()
    end)
end

-- The chat window can be dragged by its panel, its messages, and by any
-- empty space inside it. While pinned, dragging it moves the main window,
-- with the chat riding along above it; otherwise it moves only itself.
function View:SetupChatDrag(region, expandOnClick)
    region:RegisterForDrag("LeftButton")
    region:SetScript("OnMouseDown", function(_, button)
        if button == "LeftButton" then
            self.pressX, self.pressY = cursorPosition()
        end
    end)
    region:SetScript("OnDragStart", function()
        self:StartDrag("chat")
    end)
    region:SetScript("OnDragStop", function()
        self:StopDrag()
    end)
    if expandOnClick then
        region:SetScript("OnMouseUp", function(_, button)
            if button == "LeftButton" and self:IsClick() then
                self:MarkChatRecent()
                self:Expand()
            end
        end)
    end
end

function View:StartDrag(kind)
    self.moving = true
    self:MarkChatRecent()
    -- While pinned, moving the chat window moves the main window instead,
    -- and the chat follows its anchor.
    local frame = (kind == "chat" and not self.pinned) and self.chat or self.frame
    self.moveFrame = frame
    frame:StartMoving()
    self:UpdateFade()
end

-- Whether the press that is ending was a click on the window rather than a
-- drag of it: the cursor hasn't moved since the button went down. This is
-- checked on release instead of the moving flag, because starting a drag and
-- releasing it happen on every plain click too.
function View:IsClick()
    if not self.pressX or not self.pressY then
        return not self.moving
    end
    local x, y = cursorPosition()
    return math.abs(x - self.pressX) <= RESIZE_DRAG_THRESHOLD
        and math.abs(y - self.pressY) <= RESIZE_DRAG_THRESHOLD
end

function View:StopDrag()
    local frame = self.moveFrame
    if not frame then return end
    frame:StopMovingOrSizing()
    self.moveFrame = nil
    self.moving = false
    if frame == self.frame then
        self:SavePosition()
        self:RestorePosition()
        -- Dragging the main window carries the pinned chat with it; the
        -- anchor is put back in terms of the window's new spot.
        if self.pinned then self:PositionChat() end
    else
        self:SaveChatPosition()
        self:RestoreChatPosition()
    end
    self:MarkChatRecent()
    self:UpdateFade()
end

-- A grip in the top corner resizes by hand: the main window's changes its
-- width and height, and the chat window's changes its width and the height
-- of the message area (and, while pinned, the main window's width with it).
function View:SetupResizeGrip(grip, mode)
    grip:SetScript("OnMouseDown", function(_, button)
        if button ~= "LeftButton" then return end
        -- Finish anything that was still held, then remember which grip is
        -- being dragged. Only that grip may resize, even though every shown
        -- frame's OnUpdate runs on every frame.
        self:StopResizing()
        self:MarkChatRecent()
        self.resizeGrip = grip
        self.resizeStartX, self.resizeStartY = cursorPosition()
        self.resizeStartMainWidth = self.width
        self.resizeStartMainHeight = self.mainHeight
        self.resizeStartChatWidth = self.chatWidth
        self.resizeStartAreaHeight = self.chatAreaHeight
    end)
    grip:SetScript("OnUpdate", function()
        -- Every grip has an OnUpdate, and all of them run each frame, not
        -- just the one under the cursor. The others must do nothing: without
        -- this check both grips would resize their window at once.
        if self.resizeGrip ~= grip then return end
        -- The mouse-up can be missed: the window can hide mid-drag. A grip
        -- still marked as held would otherwise start resizing on the next
        -- mouse move, without a click.
        if not IsMouseButtonDown("LeftButton") then
            self:StopResizing()
            return
        end
        local x, y = cursorPosition()
        local dx, dy = x - self.resizeStartX, y - self.resizeStartY
        if not self.resizing then
            if math.abs(dx) <= RESIZE_DRAG_THRESHOLD
                and math.abs(dy) <= RESIZE_DRAG_THRESHOLD then
                return
            end
            self.resizing = mode
            -- A main-window resize must leave the chat's height alone; it may
            -- still reflow its lines to the new width. A chat-window resize is
            -- the only one allowed to change that height.
            if mode == "main" then
                self:HoldChatHeight(self.areaShown)
            else
                self:ReleaseChatHeight()
            end
        end
        if mode == "main" then
            self:ApplyMainResize(self.resizeStartMainWidth + dx,
                self.resizeStartMainHeight + dy)
        else
            self:ApplyChatResize(self.resizeStartChatWidth + dx,
                self.resizeStartAreaHeight + dy)
        end
    end)
    grip:SetScript("OnMouseUp", function(_, button)
        if button == "LeftButton" and self.resizeGrip == grip then
            self:StopResizing()
        end
    end)
    grip:SetScript("OnHide", function()
        if self.resizeGrip == grip then self:StopResizing() end
    end)
    grip:SetScript("OnEnter", function(button)
        GameTooltip:SetOwner(button, "ANCHOR_TOP")
        GameTooltip:SetText("Drag to resize")
        GameTooltip:Show()
    end)
    grip:SetScript("OnLeave", GameTooltip_Hide)
    -- White grabber at rest, blue while the cursor is on it.
    grip:HookScript("OnEnter", function(button)
        local texture = button:GetNormalTexture()
        if texture then UI.Tint(texture, Color.accentHover) end
    end)
    grip:HookScript("OnLeave", function(button)
        local texture = button:GetNormalTexture()
        if texture then UI.Tint(texture, Color.white) end
    end)
end

-- The main window's grip, with the pin button just left of it.
function View:CreateResizer()
    local resizer = CreateFrame("Button", nil, self.controls)
    self.resizer = resizer
    resizer:SetSize(RESIZER_SIZE, RESIZER_SIZE)
    resizer:SetPoint("TOPRIGHT", self.controls, "TOPRIGHT", -RESIZER_PADDING, -RESIZER_PADDING)
    -- Kept above the messages so it stays grabbable when they fill the area.
    resizer:SetFrameLevel(self.controls:GetFrameLevel() + 50)
    resizer:SetScript("OnEnter", function()
        self:MarkChatRecent()
    end)
    resizer:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    resizer:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
    resizer:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
    UI.Tint(resizer:GetNormalTexture(), Color.white)
    UI.Tint(resizer:GetHighlightTexture(), Color.accentHover)
    UI.Tint(resizer:GetPushedTexture(), Color.accent)
    -- The game's grabber points down and right; this one points up and right.
    for _, texture in ipairs({
        resizer:GetNormalTexture(), resizer:GetHighlightTexture(), resizer:GetPushedTexture(),
    }) do
        texture:SetTexCoord(0, 1, 1, 0)
    end
    self:SetupResizeGrip(resizer, "main")

    local pin = UI.CreateButton(self.controls, {
        style = "ghost", icon = "pin", iconSize = 12, width = PIN_SIZE, height = PIN_SIZE,
        tooltip = function()
            return self.pinned and "Unpin the chat window" or "Pin the chat window"
        end,
        onClick = function()
            self:MarkChatRecent()
            self:SetPinned(not self.pinned)
        end,
    })
    pin:SetPoint("RIGHT", resizer, "LEFT", -WINDOW_BUTTON_GAP, 0)
    -- White while the chat floats free, blue while it is pinned to this
    -- window; the cursor brightens it either way.
    pin:HookScript("OnEnter", function() self:UpdatePin() end)
    pin:HookScript("OnLeave", function() self:UpdatePin() end)
    self.pin = pin
    self:UpdatePin()
end

function View:UpdatePin()
    if not self.pin then return end
    local color
    if self.pin.hovered then
        color = Color.accentHover
    elseif self.pinned then
        color = Color.accent
    else
        color = Color.white
    end
    UI.Tint(self.pin.icon, color)
end

-- The chat window's own close button and resize grip, on its top corners.
function View:CreateChatControls()
    local controls = CreateFrame("Frame", nil, self.chatChrome)
    self.chatControls = controls
    controls:SetAllPoints()
    controls:SetFrameLevel(self.chatChrome:GetFrameLevel() + 30)

    local close = UI.CreateButton(controls, {
        style = "ghost", icon = "close", iconSize = 10, width = 18, height = 18,
        tooltip = "Close the chat window",
        onClick = function() self:CloseChat() end,
    })
    close:SetPoint("TOPLEFT", self.chat, "TOPLEFT", 6, -4)
    close:SetScript("OnEnter", function()
        self:MarkChatRecent()
    end)
    -- White at rest, blue while the cursor is on it.
    close:HookScript("OnEnter", function(button)
        UI.Tint(button.icon, Color.accentHover)
    end)
    close:HookScript("OnLeave", function(button)
        UI.Tint(button.icon, Color.white)
    end)
    UI.Tint(close.icon, Color.white)
    self.chatClose = close

    local resizer = CreateFrame("Button", nil, controls)
    self.chatResizer = resizer
    resizer:SetSize(RESIZER_SIZE, RESIZER_SIZE)
    resizer:SetPoint("TOPRIGHT", self.chat, "TOPRIGHT", -3, -3)
    resizer:SetFrameLevel(controls:GetFrameLevel() + 10)
    resizer:SetScript("OnEnter", function()
        self:MarkChatRecent()
    end)
    resizer:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    resizer:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
    resizer:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
    UI.Tint(resizer:GetNormalTexture(), Color.white)
    UI.Tint(resizer:GetHighlightTexture(), Color.accentHover)
    UI.Tint(resizer:GetPushedTexture(), Color.accentHover)
    for _, texture in ipairs({
        resizer:GetNormalTexture(), resizer:GetHighlightTexture(), resizer:GetPushedTexture(),
    }) do
        texture:SetTexCoord(0, 1, 1, 0)
    end
    self:SetupResizeGrip(resizer, "chat")
end

-- The main window's height: what the grip was dragged to, plus an optional
-- reply strip above the message box.
function View:UpdateMainHeight()
    local replyHeight = self.reply and (REPLY_BAR_HEIGHT + ROW_GAP) or 0
    self.frame:SetHeight(self.mainHeight + replyHeight)
    if self.replyBar then
        self.replyBar:ClearAllPoints()
        self.replyBar:SetPoint("BOTTOMLEFT", self.composer, "TOPLEFT", 0, ROW_GAP)
        self.replyBar:SetPoint("BOTTOMRIGHT", self.composer, "TOPRIGHT", 0, ROW_GAP)
        self.replyBar:SetHeight(REPLY_BAR_HEIGHT)
    end
    -- The pinned chat sits above the main window's top edge, so it rises
    -- with it when the reply strip makes the window taller.
    if self.chat then
        self:PositionChat()
    end
end

-- Applies one window's width on its own. Whether the other window follows is
-- decided by the grip that is being dragged (see the two Apply*Resize).
function View:SetMainWidth(width)
    width = resizeWidth(width)
    self.width = width
    self.frame:SetWidth(width + 2 * PADDING)
end

function View:SetChatWidth(width)
    width = resizeWidth(width)
    self.chatWidth = width
    self.chat:SetWidth(width + 2 * PADDING)
    self.messageArea:SetWidth(width)
end

-- The main window's grip. While pinned both widths move together; this grip
-- never changes the chat's height.
function View:ApplyMainResize(width, height)
    self:SetMainWidth(width)
    self.mainHeight = resizeMainHeight(height)
    if self.pinned then
        self:SetChatWidth(self.width)
    end
    self:UpdateMainHeight()
    self:UpdateConversations()
end

-- The chat window's grip. While pinned both widths move together; this grip
-- never changes the main window's height.
function View:ApplyChatResize(width, areaHeight)
    self:ReleaseChatHeight()
    self:SetChatWidth(width)
    self.chatAreaHeight = resizeChatHeight(areaHeight)
    if self.pinned then
        self:SetMainWidth(self.chatWidth)
    end
    self:UpdateConversations()
end

function View:StopResizing()
    self.resizeGrip = nil
    if not self.resizing then return end
    local mode = self.resizing
    self.resizing = nil
    self:MarkChatRecent()
    local settings = self.controller.GetSettings()
    if mode == "main" then
        settings.minimalWidth = self.width
        settings.minimalMainHeight = self.mainHeight
        -- While pinned the chat took the main window's width too.
        if self.pinned then
            settings.minimalChatWidth = self.chatWidth
        end
        -- The last layout was at the final width; from here a change in what
        -- the chat needs means its content changed, not the main resize.
        if self.chatHeightHold ~= nil then
            self.chatHeightHoldNeeded = self.neededArea or 0
            -- Nothing left to show: let the chat hide instead of holding an
            -- empty window open.
            if self.chatHeightHoldNeeded == 0 then
                self:ReleaseChatHeight()
            end
        end
    else
        self:ReleaseChatHeight()
        settings.minimalChatWidth = self.chatWidth
        settings.minimalChatHeight = self.chatAreaHeight
        -- While pinned the chat's width is the main window's width too, so
        -- both are kept for the next session.
        if self.pinned then
            settings.minimalWidth = self.width
        else
            self:SaveChatPosition()
        end
        -- Back from the full-size preview to the height the text needs.
        self:LayoutLines()
    end
    self:UpdateFade()
end

function View:CreateComposer()
    local composer = CreateFrame("Frame", nil, self.chrome)
    self.composer = composer
    composer:SetPoint("BOTTOMLEFT", self.frame, "BOTTOMLEFT", PADDING, PADDING)
    composer:SetPoint("BOTTOMRIGHT", self.frame, "BOTTOMRIGHT", -PADDING, PADDING)
    composer:SetHeight(COMPOSER_HEIGHT)
    composer.box = UI.CreateBox(composer, { radius = COMPOSER_HEIGHT / 2, border = true })
    composer.box:SetColor(Color.sidebar, 0.88)
    composer.box:SetBorderColor(Color.white, 0.18)
    composer:EnableMouse(true)
    composer:HookScript("OnEnter", function() self:MarkChatRecent() end)
    composer:EnableMouseWheel(true)
    composer:SetScript("OnMouseWheel", function(_, delta)
        self:MarkChatRecent()
        self:Scroll(delta * SCROLL_PIXELS)
    end)
    self:DragBy(composer)
    -- A click there (not the end of a drag) starts typing.
    composer:SetScript("OnMouseUp", function(_, button)
        if button == "LeftButton" and self:IsClick() then
            self.input:SetFocus()
        end
    end)

    self.label = UI.CreateText(composer, UI.Font.item, Color.accent)
    self.label:SetPoint("LEFT", composer, "LEFT", 16, 0)

    local input = CreateFrame("EditBox", nil, composer)
    self.input = input
    input:EnableMouse(true)
    input:SetAutoFocus(false)
    input:SetFontObject(UI.Font.body)
    UI.SetTextColor(input, Color.text)
    input:SetHeight(COMPOSER_HEIGHT - 8)
    input:SetPoint("LEFT", self.label, "RIGHT", 10, 0)
    input:SetPoint("RIGHT", composer, "RIGHT", -16, 0)

    self.placeholder = UI.CreateText(composer, UI.Font.body, Color.muted)
    self.placeholder:SetPoint("LEFT", input, "LEFT", 0, 0)
    self.placeholder:SetText("Say something...")
    self.hint = UI.CreateText(composer, UI.Font.small, Color.muted)
    self.hint:SetPoint("RIGHT", composer, "RIGHT", -16, 0)
    self.hint:SetText("Tab switches")

    TrialChatCommon.RegisterLinkInput(input)
    -- Like the game's chat: Enter sends and stops typing, and so does Esc.
    input:SetScript("OnEnterPressed", function(box)
        local text = box:GetText()
        box:SetText("")
        box:ClearFocus()
        self.controller.Send(text)
    end)
    input:SetScript("OnEscapePressed", function(box)
        box:ClearFocus()
    end)
    input:SetScript("OnTabPressed", function()
        self.controller.Cycle(IsShiftKeyDown() and -1 or 1)
    end)
    local function update()
        local empty = (input:GetText() or "") == ""
        self.placeholder:SetShown(empty)
        self.hint:SetShown(empty)
        self:UpdateFade()
    end
    input:HookScript("OnTextChanged", update)
    input:HookScript("OnEditFocusGained", update)
    input:HookScript("OnEditFocusLost", update)
end

---------------------------------------------------------------------------
-- Conversations
---------------------------------------------------------------------------
function View:CreatePill()
    local pill = UI.CreateButton(self.chrome, {
        style = "hud", text = "", height = PILL_HEIGHT, radius = 13, font = UI.Font.small,
        onClick = function(button) self.controller.Select(button.key) end,
    })
    pill:HookScript("OnEnter", function() self:MarkChatRecent() end)
    pill:EnableMouseWheel(true)
    pill:SetScript("OnMouseWheel", function(_, delta)
        self:MarkChatRecent()
        self:Scroll(delta * SCROLL_PIXELS)
    end)
    self.pills[#self.pills + 1] = pill
    return pill
end

-- The conversations flow into rows under the toolbar, using extra vertical
-- space when the main window is taller.
function View:UpdateConversations()
    local selected = self.controller.GetSelected()
    local conversations = self.controller.GetConversations()
    local count = #conversations
    local replyHeight = self.reply and (REPLY_BAR_HEIGHT + ROW_GAP) or 0
    local extraHeight = (self.mainHeight or BASE_MAIN_HEIGHT) - BASE_MAIN_HEIGHT
    local maxRows = 1 + math.floor(math.max(0, extraHeight) / (PILL_HEIGHT + ROW_GAP))
    if maxRows < 1 then maxRows = 1 end
    local x = 0
    local y = 0
    local row = 0
    local shown = 0
    for index = 1, count do
        local conversation = conversations[index]
        local pill = self.pills[index] or self:CreatePill()
        pill.key = conversation.key
        local text = conversation.name
        if conversation.unread > 0 then
            text = text .. "  " .. UI.ColorText(Color.accent, tostring(conversation.unread))
        end
        pill:SetLabel(text)
        UI.SetButtonStyle(pill, conversation.key == selected and "accent" or "hud")
        local width = pill:GetWidth()
        if x > 0 and x + width > self.width then
            row = row + 1
            if row >= maxRows then
                pill:Hide()
                break
            end
            x = 0
            y = row * (PILL_HEIGHT + ROW_GAP)
        end
        pill:ClearAllPoints()
        pill:SetPoint("TOPLEFT", self.frame, "TOPLEFT",
            PADDING + x, -(CONTROLS_HEIGHT + ROW_GAP + y))
        pill:Show()
        x = x + width + PILL_GAP
        shown = index
    end
    for index = shown + 1, #self.pills do
        self.pills[index]:Hide()
    end
    self:UpdateInvite()
    self:LayoutLines()
end

-- An invite goes between the two windows, above the main window.
function View:UpdateInvite()
    local card = self.inviteCard
    card:SetShown(self.invite ~= nil)
    if self.invite then
        card:SetInvite(self.invite, self.width)
        card:ClearAllPoints()
        card:SetPoint("BOTTOMLEFT", self.frame, "TOPLEFT", PADDING, ROW_GAP)
    end
    self:PositionChat()
end

-- invite is { groupName, inviter }, or nil when there's none.
function View:SetInvite(invite)
    self.invite = invite
    self:UpdateInvite()
end

-- The strip above the message box that shows what a reply will answer.
function View:CreateReplyBar()
    local view = self
    local bar = CreateFrame("Frame", nil, self.chrome)
    bar.box = UI.CreateBox(bar, { radius = 10, border = true })
    bar.box:SetColor(Color.sidebar, 0.9)
    bar.box:SetBorderColor(Color.white, 0.18)
    bar.accent = UI.CreateLine(bar)
    bar.accent:SetWidth(2)
    bar.accent:SetPoint("TOP", bar, "TOP", 0, -6)
    bar.accent:SetPoint("BOTTOM", bar, "BOTTOM", 0, 6)
    bar.accent:SetPoint("LEFT", bar, "LEFT", 11, 0)
    bar.text = UI.CreateText(bar, UI.Font.small, Color.muted)
    bar.text:SetPoint("LEFT", bar, "LEFT", 20, 0)
    bar.text:SetPoint("RIGHT", bar, "RIGHT", -32, 0)
    bar.text:SetJustifyH("LEFT")
    bar.text:SetWordWrap(false)
    bar.cancel = UI.CreateButton(bar, {
        style = "ghost", icon = "close", iconSize = 10,
        width = 22, height = 22,
        onClick = function() view.controller.ClearReply() end,
    })
    bar.cancel:SetPoint("RIGHT", bar, "RIGHT", -5, 0)
    bar:Hide()
    return bar
end

-- reply is { sender, text }, or nil when nothing is being answered.
function View:SetReply(reply)
    self.reply = reply
    if not self.replyBar then
        self.replyBar = self:CreateReplyBar()
    end
    if reply then
        local color = colorForName(reply.sender)
        self.replyBar.text:SetText("Replying to "
            .. UI.ColorText(color, TrialChatCommon.ShortName(reply.sender or "?"))
            .. UI.ColorText(Color.muted, ": "
                .. TrialChatCommon.RemovePlayerLinks(reply.text or "")))
        UI.Tint(self.replyBar.accent, color, 0.9)
    end
    self.replyBar:SetShown(reply ~= nil)
    self:UpdateMainHeight()
end

---------------------------------------------------------------------------
-- Messages
---------------------------------------------------------------------------
-- An animated emoticon in a line is redrawn a cell at a time (see
-- TrialChatEmoji.lua); the text around it never changes. Only lines on screen
-- step, and only while their chip is shown, because a hidden frame gets no
-- OnUpdate. The split into text and emoticons is cached on the line, since
-- chips are recycled for whatever is scrolled into view. The message box is a
-- plain edit box, so what you are typing never shows the picture, only the
-- message once it is sent.
local function redrawChipEmoji(chip)
    chip.text:SetText(TrialChatCommon.BuildEmojiText(chip.emojiParts, GetTime()))
end

local function tickChipEmoji(chip, elapsed)
    chip.emojiElapsed = (chip.emojiElapsed or 0) + elapsed
    local step = 1 / (TrialChatCommon.EmojiFPS or 5)
    if chip.emojiElapsed < step then return end
    chip.emojiElapsed = 0
    redrawChipEmoji(chip)
end

-- Sets a chip's text and starts animating it when its line holds an animated
-- emoticon, stopping the tick on lines that don't.
local function setChipText(chip, line)
    chip.text:SetText(line.text)
    if not line.emojiChecked then
        line.emojiParts, line.emojiAnimated =
            TrialChatCommon.SplitEmojiMarkup(line.text)
        line.emojiChecked = true
    end
    if line.emojiAnimated then
        chip.emojiParts = line.emojiParts
        chip.emojiElapsed = 0
        chip:SetScript("OnUpdate", tickChipEmoji)
    elseif chip.emojiParts then
        chip:SetScript("OnUpdate", nil)
        chip.emojiParts = nil
        chip.emojiElapsed = nil
    end
end

function View:MakeLine(entry, format, colorFor)
    if type(entry) == "string" then
        return { entry = entry, text = TrialChatCommon.RemovePlayerLinks(entry), color = Color.text }
    end
    if type(entry) ~= "table" then return nil end

    local name = TrialChatCommon.ShortName(entry.sender or "?")
    local text
    if entry.isEmote then
        text = name .. " " .. format(entry)
    else
        text = UI.ColorText(colorFor(entry), name) .. ": " .. format(entry)
    end
    if entry.reply then
        text = replyLine(entry.reply, colorFor) .. "\n" .. text
    end
    return {
        entry = entry,
        text = text,
        color = entry.isEmote and Color.emote or Color.text,
    }
end

-- The messages live in their own frame inside the chat window, cut off at
-- the top of the space they get: a line too tall to fit shows the part that
-- fits and is clipped above the edge (see LayoutLines) instead of being left
-- out, so the space is always filled. A line cut off there fades out along
-- it (see UpdateFade), so no band is ever painted over the messages.
function View:CreateMessageArea()
    local area = CreateFrame("Frame", nil, self.chat)
    self.messageArea = area
    area:SetClipsChildren(true)
    area:SetPoint("TOPLEFT", self.chat, "TOPLEFT", PADDING, -CHAT_HEADER_HEIGHT)
    area:SetSize(self.chatWidth, math.max(1, self.chatAreaHeight))
    -- Under the chat panel's controls, above its own background.
    area:SetFrameLevel(self.chat:GetFrameLevel() + 5)
    area:HookScript("OnEnter", function() self:MarkChatRecent() end)
    area:EnableMouse(true)
    area:EnableMouseWheel(true)
    area:SetScript("OnMouseWheel", function(_, delta)
        self:MarkChatRecent()
        self:Scroll(delta * SCROLL_PIXELS)
    end)
    -- Clicking empty space in the chat, like in the main window, unshrinks
    -- it; dragging still moves it.
    self:SetupChatDrag(area, true)
end

function View:CreateChip()
    local view = self
    -- Parented to the message area so a line cut off at its top is clipped
    -- there (see CreateMessageArea).
    local chip = CreateFrame("Frame", nil, self.messageArea)
    chip.box = UI.CreateBox(chip, { radius = LINE_RADIUS, border = true })
    chip.box:SetColor(Color.sidebar, 0.85)
    chip.box:SetBorderColor(Color.white, 0.12)
    chip.text = UI.CreateText(chip, UI.Font.body)
    chip.text:SetPoint("TOPLEFT", chip, "TOPLEFT", LINE_PADDING_X, -LINE_PADDING_Y)
    chip.text:SetJustifyH("LEFT")
    chip.text:SetWordWrap(true)
    chip.text:SetNonSpaceWrap(true)
    TrialChatMessageList.EnableLinks(chip)
    -- Right-click opens the message menu, unless a link was clicked. A plain
    -- frame has no RegisterForClicks (that is a Button method), so this
    -- listens for the button coming up with the mouse over the chip.
    chip:EnableMouse(true)
    chip:SetScript("OnMouseUp", function(self, button)
        if button ~= "RightButton" then return end
        if self.hyperlinkMenu or self.hoveredLink then
            self.hyperlinkMenu = nil
            return
        end
        -- Only real messages get a menu; notices and emotes don't.
        local entry = self.line and self.line.entry
        if type(entry) == "table" and not entry.isEmote then
            view.controller.ShowMessageMenu(entry, MENU_THEME)
        end
    end)
    chip:HookScript("OnEnter", function() self:MarkChatRecent() end)
    self:SetupChatDrag(chip, false)
    chip:EnableMouseWheel(true)
    chip:SetScript("OnMouseWheel", function(_, delta)
        self:MarkChatRecent()
        view:Scroll(delta * SCROLL_PIXELS)
    end)
    chip:SetFrameLevel(self.messageArea:GetFrameLevel() + 5)
    chip:Hide()
    self.chips[#self.chips + 1] = chip
    return chip
end

-- The chat window shows the history at full height while you have opened it
-- by clicking, and while its grip is held (so you can see the space you are
-- giving it).
function View:IsFullHeight()
    return self.expanded or self.resizing == "chat"
end

-- Measures how tall a line is when wrapped at this width: the chip's text is
-- laid out in a single frame, so this matches what LayoutLines places. The
-- result is cached on the line so scrolling (which doesn't change the width)
-- doesn't re-measure every line on every wheel notch.
function View:MeasureLineHeight(line, textWidth)
    if line.measureWidth == textWidth then
        return line.measureHeight or LINE_MIN_HEIGHT
    end
    local text = self.measure
    text:SetWidth(math.max(1, textWidth))
    text:SetText(line.text)
    local height = math.max(LINE_MIN_HEIGHT,
        math.ceil(text:GetStringHeight() or 0) + 2 * LINE_PADDING_Y)
    line.measureWidth = textWidth
    line.measureHeight = height
    return height
end

-- The lines stack up from the bottom of the chat window, the newest at the
-- bottom (or the one scrolled back to), as many as fit; each background is
-- as wide as its text. The line at the top is shown even when it only partly
-- fits: it gets cut off at the top of the message area (see
-- CreateMessageArea) rather than left out, so the space is always filled.
function View:LayoutLines()
    local now = GetTime()
    local full = self:IsFullHeight()
    local count = #self.lines
    local cap = self.chatAreaHeight
    local textWidth = math.max(40, self.chatWidth - 2 * LINE_PADDING_X)

    -- Measure every scrollable line, newest first, and remember where each
    -- sits in the content measured from the bottom (newest) up. Expired lines
    -- aren't part of the scrollable content.
    local chips = {}
    local y = 0
    for index = count, 1, -1 do
        local line = self.lines[index]
        if not full and now - line.shownAt >= LINE_VISIBLE_SECONDS + LINE_FADE_SECONDS then
            break
        end
        local chip = self.chips[#chips + 1] or self:CreateChip()
        setChipText(chip, line)
        UI.SetTextColor(chip.text, line.color)
        local width = math.min(math.ceil(chip.text:GetUnboundedStringWidth()) + 1, textWidth)
        chip.text:SetWidth(width)
        local height = self:MeasureLineHeight(line, textWidth)
        if y > 0 then y = y + LINE_GAP end
        local bottom = y
        local top = bottom + height
        y = top
        chips[#chips + 1] = {
            chip = chip, line = line, width = width, height = height,
            bottom = bottom, top = top,
        }
    end
    local totalHeight = y

    -- Scrolling is measured in pixels: how far the stack has been pushed down
    -- from the bottom (the newest message). Clamp it to what the content and
    -- the view allow, so a tall message is scrolled through bit by bit instead
    -- of being skipped over as a whole.
    local maxScroll = math.max(0, totalHeight - cap)
    self.scroll = clamp(self.scroll, 0, maxScroll)
    local scroll = self.scroll

    local needed = 0
    for _, c in ipairs(chips) do
        local chip, line = c.chip, c.line
        local visualBottom = c.bottom - scroll
        local visualTop = c.top - scroll
        -- Show the line while any of it is still inside the message area.
        if visualTop > 0 and visualBottom < cap then
            chip.line = line
            local entry = line.entry
            chip.onReplyJump = (type(entry) == "table" and entry.reply)
                and function() self:JumpToReply(entry) end or nil
            chip:SetSize(math.max(c.height, c.width + 2 * LINE_PADDING_X), c.height)
            chip:ClearAllPoints()
            chip:SetPoint("BOTTOMLEFT", self.messageArea, "BOTTOMLEFT", 0, visualBottom)
            -- Where the line reaches to, for its fade along the top edge of the
            -- area (see UpdateFade), in view coordinates.
            chip.top = visualTop
            chip.height = c.height
            needed = math.max(needed, visualTop)
            chip:Show()
        else
            chip.line = nil
            chip.onReplyJump = nil
            chip:Hide()
        end
    end
    for index = #chips + 1, #self.chips do
        self.chips[index].line = nil
        self.chips[index].onReplyJump = nil
        self.chips[index]:Hide()
    end

    self.neededArea = needed
    if self.chatHeightHold ~= nil then
        -- Rewrapping at the main window's new width can change how much room
        -- the text needs; the height stays as it was.
        self:SetAreaShown(self.chatHeightHold)
    else
        self:SetAreaShown(full and cap or math.min(needed, cap))
    end
    self:UpdateNewestButton()
    self:UpdateFade()
end

-- The chat window's height is independent of the main window's: while the
-- main window is being resized (and until its content changes on its own),
-- the chat keeps the height it had.
function View:HoldChatHeight(height)
    self.chatHeightHold = math.max(0, math.floor((height or 0) + 0.5))
    -- Established by the next fade pass at the final width.
    self.chatHeightHoldNeeded = nil
end

function View:ReleaseChatHeight()
    self.chatHeightHold = nil
    self.chatHeightHoldNeeded = nil
end

-- The height the chat window has right now: the full height it was dragged
-- to while open, otherwise just enough for the lines still visible.
function View:SetAreaShown(height)
    height = math.max(0, math.floor((height or 0) + 0.5))
    if height == self.areaShown then return end
    self.areaShown = height
    self.messageArea:SetHeight(math.max(1, height))
    self.chat:SetHeight(CHAT_HEADER_HEIGHT + math.max(1, height) + CHAT_BOTTOM_PADDING)
end

-- While scrolled back, a button at the bottom goes back to the newest
-- message, counting the ones that came in meanwhile.
function View:UpdateNewestButton()
    local button = self.newestButton
    button:SetShown(self.scroll > 0)
    if self.scroll == 0 then return end
    button:SetLabel(self.newCount > 0 and (self.newCount .. " new") or "Newest")
    UI.SetButtonStyle(button, self.newCount > 0 and "accent" or "hud")
    button:ClearAllPoints()
    button:SetPoint("BOTTOMRIGHT", self.chat, "BOTTOMRIGHT", -PADDING, CHAT_BOTTOM_PADDING)
end

-- Scrolls back into older messages (positive) or forward. The whole stored
-- history is loaded (see Render), so this is a plain scroll. Scrolling back
-- opens the chat window at full height, like clicking it does.
function View:Scroll(lines)
    self:MarkChatRecent()
    self:ReleaseChatHeight()
    if lines > 0 and #self.lines > 0 then
        self.expanded = true
        self.chatClosed = false
    end
    self.scroll = math.max(0, self.scroll + lines)
    if self.scroll == 0 then
        self.newCount = 0
    end
    self:LayoutLines()
end

function View:ScrollToNewest()
    self:MarkChatRecent()
    self:ReleaseChatHeight()
    self.scroll = 0
    self.newCount = 0
    self:LayoutLines()
end

-- Scrolls back to the message a reply quotes; the whole history is loaded
-- (see Render), like in the full view. entry is the reply-carrying line's
-- message; the nearest quote before it wins.
function View:JumpToReply(entry)
    local reply = type(entry) == "table" and entry.reply
    if not reply then return end
    self:MarkChatRecent()
    self:ReleaseChatHeight()
    local lines, count = self.lines, #self.lines
    local start = count + 1
    for index = count, 1, -1 do
        if lines[index].entry == entry then
            start = index
            break
        end
    end
    for index = start - 1, 1, -1 do
        if TrialChatCommon.ReplyQuotesEntry(reply, lines[index].entry) then
            -- Scroll so the quoted line lands at the bottom of the view, by
            -- the combined pixel height of everything newer than it.
            local textWidth = math.max(40, self.chatWidth - 2 * LINE_PADDING_X)
            local newer = count - index
            local scrollPixels = 0
            if newer > 0 then
                scrollPixels = LINE_GAP * (newer - 1)
                for j = index + 1, count do
                    scrollPixels = scrollPixels + self:MeasureLineHeight(lines[j], textWidth)
                end
            end
            self.scroll = scrollPixels
            self.newCount = 0
            self.expanded = true
            self.chatClosed = false
            self:LayoutLines()
            return
        end
    end
end

-- New lines don't move what you're reading while scrolled back, unless
-- jumpToNewest (your own message, a notice). A new message also brings the
-- chat window back after it was closed.
function View:AddLine(line, jumpToNewest)
    -- New content may change how much room the chat needs. During a main
    -- resize keep the height held until the drag ends.
    if self.resizing ~= "main" then
        self:ReleaseChatHeight()
    end
    if self.chatClosed then
        self.chatClosed = false
        self.scroll = 0
        self.newCount = 0
    end
    self:MarkChatRecent()
    line.shownAt = GetTime()
    self.lines[#self.lines + 1] = line
    if jumpToNewest then
        self.scroll = 0
        self.newCount = 0
    elseif self.scroll > 0 then
        -- A new line pushes the stack up; keep the older content in view by
        -- scrolling down by the new line's height (plus the gap between lines).
        local textWidth = math.max(40, self.chatWidth - 2 * LINE_PADDING_X)
        self.scroll = self.scroll + self:MeasureLineHeight(line, textWidth) + LINE_GAP
        self.newCount = self.newCount + 1
    end
    if self.scroll == 0 then
        while #self.lines > MAX_LINES do
            table.remove(self.lines, 1)
        end
    end
    if not (line and line.expiresAt) then
        self.lastLineAt = line.shownAt
    end
    self:LayoutLines()
end

-- Shows the whole stored history of the open conversation, like the full
-- view; as many lines as fit are on screen (see LayoutLines).
function View:Render()
    if self.resizing ~= "main" then
        self:ReleaseChatHeight()
    end
    self:MarkChatRecent()
    local entries, format, colorFor = self.controller.GetEntries()
    local now = GetTime()
    self.lines = {}
    self.scroll = 0
    self.newCount = 0
    for index = 1, #entries do
        local line = self:MakeLine(entries[index], format, colorFor)
        if line then
            line.shownAt = now
            self.lines[#self.lines + 1] = line
        end
    end
    self:LayoutLines()
end

function View:AddEntry(entry, isOwn)
    local _, format, colorFor = self.controller.GetEntries()
    local line = self:MakeLine(entry, format, colorFor)
    if line then
        self:AddLine(line, isOwn)
    end
end

-- A line from TrialChat itself; it isn't kept in the history.
function View:AddNotice(text, color)
    local line = { text = text, color = color or Color.muted }
    self:AddLine(line, true)
    if text and (string.find(text, "skipped: message too long") or string.find(text, "Chat message limits exceeded") or string.find(text, "limits exceeded")) then
        line.expiresAt = GetTime() + 5
        self.lastLineAt = GetTime()
        self:LayoutLines()
    end
end

function View:Refresh()
    self.label:SetText("To " .. self.controller.GetName())
    self.input:SetMaxLetters(self.controller.GetMessageLimit())
    self:UpdateConversations()
    self:Render()
end

---------------------------------------------------------------------------
-- Fading and the chat window's size
---------------------------------------------------------------------------
-- Clicking empty space in either window opens the chat at full height, with
-- the conversation's history fully lit; leaving lets it fade and shrink back
-- to fit the text, then hide.
function View:MarkChatRecent()
    self.chatRecentAt = GetTime()
end

function View:Expand()
    if not self.frame:IsShown() or #self.lines == 0 then return end
    self:MarkChatRecent()
    self:ReleaseChatHeight()
    self.expanded = true
    self.chatClosed = false
    self:LayoutLines()
end

function View:Collapse()
    if not self.expanded then return end
    self:ReleaseChatHeight()
    self.expanded = false
    -- What was on screen starts its life over, so it fades away naturally
    -- now that it is no longer being read.
    local now = GetTime()
    for _, chip in ipairs(self.chips) do
        if chip:IsShown() and chip.line then
            chip.line.shownAt = now
        end
    end
    self:LayoutLines()
end

-- X on the chat window: it stays hidden until the next message, or until
-- you click empty space to open it again.
function View:CloseChat()
    self:ReleaseChatHeight()
    self.chatClosed = true
    self.expanded = false
    self.scroll = 0
    self.newCount = 0
    self.chatRecentAt = nil
    self.chat:Hide()
end

function View:IsOverChat()
    if not self.chat:IsShown() then return false end
    if self.chat:IsMouseOver() or self.chatControls:IsMouseOver()
        or self.messageArea:IsMouseOver() then
        return true
    end
    for _, chip in ipairs(self.chips) do
        if chip:IsShown() and chip:IsMouseOver() then return true end
    end
    return false
end

function View:IsOverMain()
    if self.frame:IsMouseOver() or self.controls:IsMouseOver()
        or self.composer:IsMouseOver() then
        return true
    end
    for _, pill in ipairs(self.pills) do
        if pill:IsShown() and pill:IsMouseOver() then return true end
    end
    local card = self.inviteCard
    if card:IsShown() and card:IsMouseOver() then return true end
    return false
end

-- While you hover, type or read back, everything shows. Otherwise the rest
-- fades back, each message fades out a while after it came in, older ones
-- dimmer, and the chat window shrinks back to the messages still on screen,
-- hiding when there are none.
function View:UpdateFade()
    if self.updatingFade then return end
    self.updatingFade = true

    local now = GetTime()
    local overChat = self:IsOverChat()
    if overChat then self:MarkChatRecent() end
    local chatKept = self.chatRecentAt ~= nil
        and now - self.chatRecentAt < RECENT_CHAT_KEEP_SECONDS
    local inUse = overChat or self:IsOverMain() or self.input:HasFocus()
        or self.moving or self.resizing
    local recent = self.lastLineAt and now - self.lastLineAt < RECENT_SECONDS
    local full = self:IsFullHeight()

    -- Only clicking (or scrolling) opens the chat; hovering just brings it
    -- into focus. Once you are done with it, and it hasn't been touched for a
    -- while, it closes again.
    if self.expanded and not (inUse or self.scroll > 0 or chatKept) then
        self:Collapse()
        full = self:IsFullHeight()
    end

    local limit = self.areaShown or 0
    for rank, chip in ipairs(self.chips) do
        local line = chip.line
        local alpha = 0
        if line then
            if line.expiresAt and now >= line.expiresAt then
                alpha = 0
            elseif full then
                alpha = 1
            else
                local left = 1 - math.max(0,
                    now - line.shownAt - LINE_VISIBLE_SECONDS) / LINE_FADE_SECONDS
                alpha = math.max(0, left) * (LINE_ALPHA_BY_AGE[rank] or OLDEST_LINE_ALPHA)
            end
            -- A line cut off at the top of the area fades out along the edge
            -- itself: it still shows where it enters the fade strip, and is
            -- completely gone by the top of the area.
            if chip.top and chip.height and chip.top > limit then
                local low = math.max(chip.top - chip.height, limit - TOP_FADE_HEIGHT)
                local high = math.min(chip.top, limit)
                if high > low then
                    local center = (low + high) / 2
                    alpha = alpha * clamp((limit - center) / TOP_FADE_HEIGHT, 0, 1)
                end
            end
        end
        chip:SetAlpha(alpha)
        chip:SetShown(alpha > 0)
    end

    if not full then
        local needed = 0
        for _, chip in ipairs(self.chips) do
            if chip:IsShown() and chip.line and chip.top then
                needed = math.max(needed, chip.top)
            end
        end
        self.neededArea = needed
        -- A change here while no resize is running means the chat's content
        -- itself changed (a line arrived or faded out), so it may size to fit
        -- again. During a main-window resize the height stays held. The first
        -- pass after a hold starts only records the baseline.
        if self.chatHeightHold ~= nil and not self.resizing then
            if self.chatHeightHoldNeeded == nil then
                self.chatHeightHoldNeeded = needed
            elseif needed ~= self.chatHeightHoldNeeded then
                self:ReleaseChatHeight()
            end
        end
    end
    -- While you are using it, the chat window only grows (to show a new
    -- message): it never shrinks away from the cursor under you. Leaving it
    -- lets it fit the text again.
    local area
    if self.chatHeightHold ~= nil then
        area = self.chatHeightHold
    elseif full then
        area = self.chatAreaHeight
    else
        area = math.min(self.neededArea or 0, self.chatAreaHeight)
        if overChat or self.moving or self.resizing or chatKept then
            area = math.max(area, self.areaShown or 0)
        end
    end
    -- If only a short-lived notice remains and it's about to expire, let it collapse
    if not full and self.neededArea and self.neededArea > 0 and self.lines and #self.lines == 1 then
        local l = self.lines[1]
        if l and l.expiresAt and now + 1 >= l.expiresAt and not chatKept and not inUse and self.scroll == 0 then
            area = math.min(self.neededArea or 0, self.chatAreaHeight)
        end
    end
    self:SetAreaShown(area)

    -- Remove expired notices from the line list so the chat can roll back
    if not self.resizing and not self.chatHeightHold then
        local changed = false
        for index = #self.lines, 1, -1 do
            local line = self.lines[index]
            if line and line.expiresAt and now >= line.expiresAt then
                table.remove(self.lines, index)
                changed = true
            end
        end
        if changed then
            self:LayoutLines()
            -- Recompute area after removal
            local limit2 = self.areaShown or 0
            for rank, chip in ipairs(self.chips) do
                local l = chip.line
                local alpha = 0
                if l and not (l.expiresAt and now >= l.expiresAt) then
                    if full then
                        alpha = 1
                    else
                        local left = 1 - math.max(0,
                            now - l.shownAt - LINE_VISIBLE_SECONDS) / LINE_FADE_SECONDS
                        alpha = math.max(0, left) * (LINE_ALPHA_BY_AGE[rank] or OLDEST_LINE_ALPHA)
                    end
                    if chip.top and chip.height and chip.top > limit2 then
                        local low = math.max(chip.top - chip.height, limit2 - TOP_FADE_HEIGHT)
                        local high = math.min(chip.top, limit2)
                        if high > low then
                            local center = (low + high) / 2
                            alpha = alpha * clamp((limit2 - center) / TOP_FADE_HEIGHT, 0, 1)
                        end
                    end
                end
                chip:SetAlpha(alpha)
                chip:SetShown(alpha > 0)
            end
            area = math.min(self.neededArea or 0, self.chatAreaHeight)
            if overChat or self.moving or self.resizing or chatKept then
                area = math.max(area, self.areaShown or 0)
            end
            self:SetAreaShown(area)
        end
    end

    -- Touched in the last few seconds: stay on screen even if the last line
    -- has faded out by now.
    local showChat = self.frame:IsShown() and not self.chatClosed and area > 0
    self.chat:SetShown(showChat)

    -- The chrome fades as one, with no competing alpha of its own, so the
    -- toolbar and buttons never flicker as the windows change size.
    local target = (inUse or recent or self.scroll > 0) and 1 or IDLE_ALPHA
    TrialChatCommon.FadeTo(self.chrome, target)
    TrialChatCommon.FadeTo(self.chatChrome, target)

    self.updatingFade = false
end

---------------------------------------------------------------------------
-- Showing, typing and position
---------------------------------------------------------------------------
function View:Show()
    self.chatClosed = false
    self.frame:Show()
    self:UpdateFade()
end

function View:Hide()
    self.frame:Hide()
    self.chat:Hide()
end

function View:IsShown() return self.frame:IsShown() end
function View:FocusInput() self.input:SetFocus() end

function View:SetPinned(pinned)
    self.pinned = pinned and true or false
    local settings = self.controller.GetSettings()
    settings.minimalPinned = self.pinned
    -- Whatever the pin state, the chat keeps the height it had.
    local shownHeight = self.areaShown
    if self.pinned then
        -- If both windows have different sizes when pinning, the width of the
        -- chat window becomes the same size as the width main window currently has,
        -- and the height remains the same.
        self.chatWidth = self.width
        settings.minimalChatWidth = self.chatWidth
        self.chat:SetWidth(self.chatWidth + 2 * PADDING)
        self.messageArea:SetWidth(self.chatWidth)
        self:PositionChat()
    else
        -- Kept where it is, and free to move from there. Its width is its
        -- own from now on too; the main window is left as it is.
        self:SaveChatPosition()
        self:PositionChat()
    end
    self:HoldChatHeight(shownHeight)
    self:LayoutLines()
    self:UpdatePin()
end

function View:PositionChat()
    -- While dragging, the windows are already moving together or alone;
    -- re-anchoring now would pull the one being dragged out from under the
    -- cursor.
    if self.moving then return end
    self.chat:ClearAllPoints()
    if self.pinned then
        -- Above the main window, or above an invite when one is waiting. It
        -- stays aligned with the main window's edges either way, so the two
        -- are one stack.
        local y = self.frame:GetHeight() + ROW_GAP
        local card = self.inviteCard
        if self.invite and card:IsShown() then
            y = y + card:GetHeight() + ROW_GAP
        end
        self.chat:SetPoint("BOTTOMLEFT", self.frame, "BOTTOMLEFT", 0, y)
    else
        self:RestoreChatPosition()
    end
end

function View:RestorePosition()
    local settings = self.controller.GetSettings()
    local x = tonumber(settings.minimalX) or DEFAULT_X
    local y = tonumber(settings.minimalY) or DEFAULT_Y
    -- A saved position can hang off the edge of the screen (or the screen
    -- can have shrunk since it was saved). The frame is pulled back inside
    -- it, so the resize grip in the top right corner always stays reachable.
    local parentWidth, parentHeight = UIParent:GetSize()
    if parentWidth and parentHeight and parentWidth > 0 and parentHeight > 0 then
        x = clamp(x, 0, math.max(0, parentWidth - self.frame:GetWidth()))
        y = clamp(y, 0, math.max(0, parentHeight - self.frame:GetHeight()))
    end
    self.frame:ClearAllPoints()
    self.frame:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", x, y)
end

function View:SavePosition()
    local settings = self.controller.GetSettings()
    settings.minimalX = self.frame:GetLeft()
    settings.minimalY = self.frame:GetBottom()
end

function View:RestoreChatPosition()
    local settings = self.controller.GetSettings()
    local x = tonumber(settings.minimalChatX)
    local y = tonumber(settings.minimalChatY)
    if not x or not y then
        -- The first time: just above the main window, where it starts pinned.
        x = self.frame:GetLeft() or DEFAULT_X
        y = (self.frame:GetTop() or DEFAULT_Y) + ROW_GAP
    end
    local parentWidth, parentHeight = UIParent:GetSize()
    if parentWidth and parentHeight and parentWidth > 0 and parentHeight > 0 then
        x = clamp(x, 0, math.max(0, parentWidth - self.chat:GetWidth()))
        y = clamp(y, 0, math.max(0, parentHeight - self.chat:GetHeight()))
    end
    self.chat:ClearAllPoints()
    self.chat:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", x, y)
end

function View:SaveChatPosition()
    if self.pinned then return end
    local settings = self.controller.GetSettings()
    settings.minimalChatX = self.chat:GetLeft()
    settings.minimalChatY = self.chat:GetBottom()
end

---------------------------------------------------------------------------
-- Notices of messages elsewhere
---------------------------------------------------------------------------
function View:CreateToast()
    local toast = CreateFrame("Button", "TrialChatToast", UIParent)
    self.toast = toast
    toast:SetWidth(TOAST_WIDTH)
    toast:SetPoint("TOPRIGHT", UIParent, "TOPRIGHT", -24, -230)
    toast:SetFrameStrata("HIGH")
    toast:RegisterForClicks("LeftButtonUp")
    toast.box = UI.CreateBox(toast, { radius = 10, border = true })
    toast.box:SetColor(Color.window, 0.92)
    toast.box:SetBorderColor(Color.white, 0.12)

    toast.title = UI.CreateText(toast, UI.Font.item, Color.accent)
    toast.title:SetPoint("TOPLEFT", toast, "TOPLEFT", 16, -14)
    toast.count = UI.CreateText(toast, UI.Font.small, Color.muted)
    toast.count:SetPoint("LEFT", toast.title, "RIGHT", 8, 0)
    toast.close = UI.CreateButton(toast, {
        style = "ghost", icon = "close", iconSize = 12, width = 24, height = 24,
        onClick = function() toast:Hide() end,
    })
    toast.close:SetPoint("TOPRIGHT", toast, "TOPRIGHT", -8, -8)
    toast.text = UI.CreateText(toast, UI.Font.body)
    toast.text:SetPoint("TOPLEFT", toast.title, "BOTTOMLEFT", 0, -8)
    toast.text:SetWidth(TOAST_WIDTH - 32)
    toast.text:SetJustifyH("LEFT")
    toast.text:SetWordWrap(true)
    toast.text:SetMaxLines(2)
    toast.hint = UI.CreateText(toast, UI.Font.small, Color.muted)
    toast.hint:SetPoint("TOPLEFT", toast.text, "BOTTOMLEFT", 0, -6)

    toast:SetScript("OnClick", function() self:Reply() end)
    toast:SetScript("OnUpdate", function()
        if GetTime() > (toast.hideAt or 0) and not toast:IsMouseOver() then
            toast:Hide()
        end
    end)
    toast:Hide()
end

-- entry is the message that came in for conversation key, which has unread
-- messages; format and colorFor are as for the conversation's history.
function View:ShowToast(key, name, unread, entry, format, colorFor)
    local line = self:MakeLine(entry, format, colorFor)
    if not line then return end
    local toast = self.toast
    toast.key = key
    toast.title:SetText(name)
    toast.count:SetText(unread > 1 and (unread .. " new") or "")
    toast.text:SetText(line.text)
    UI.SetTextColor(toast.text, line.color)
    toast.hint:SetText(getReplyHint())
    toast:SetHeight(math.ceil(14 + toast.title:GetStringHeight() + 8
        + toast.text:GetStringHeight() + 6 + toast.hint:GetStringHeight() + 14))
    toast.hideAt = GetTime() + TOAST_SECONDS
    toast:Show()
end

function View:GetToastKey()
    return self.toast:IsShown() and self.toast.key or nil
end

-- Opens the conversation from the notice, ready to type.
function View:Reply()
    local key = self.toast.key
    self.toast:Hide()
    self:Show()
    self.controller.Select(key)
    self:FocusInput()
end
