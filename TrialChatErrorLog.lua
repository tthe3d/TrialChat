TrialChatErrorLog = {}
local UI = TrialChatUI
local Color = UI.Color

local PADDING = 8
local PANEL_RADIUS = 6
local RESIZER_SIZE = 18
local CLOSE_SIZE = 20
local CHAT_HEADER_HEIGHT = 24
local SCROLLBAR_SPACE = 24 -- room on the right for the scroll bar

local logFrame
local lines = {} -- pool of reusable FontStrings

local function createLog()
    if logFrame then return logFrame end
    local frame = CreateFrame("Frame", "TrialChatErrorLogFrame", UIParent)
    logFrame = frame
    frame:SetSize(320, 200)
    frame:SetFrameStrata("DIALOG")
    frame:SetClampedToScreen(true)
    frame:SetMovable(true)
    frame:SetResizable(true)
    if frame.SetResizeBounds then
        frame:SetResizeBounds(220, 120)
    elseif frame.SetMinResize then
        frame:SetMinResize(220, 120)
    end
    frame:EnableMouse(true)
    frame:SetPoint("CENTER")
    frame:Hide()

    -- Background panel
    local panel
    if UI.CreateBox then
        local ok, p = pcall(UI.CreateBox, frame, { radius = PANEL_RADIUS, border = true })
        if ok and p then
            panel = p
            if panel.SetAllPoints then panel:SetAllPoints() end
            if panel.SetColor then pcall(panel.SetColor, panel, Color.sidebar, 0.9) end
            if panel.SetBorderColor then pcall(panel.SetBorderColor, panel, Color.white, 0.25) end
        else
            panel = CreateFrame("Frame", nil, frame)
            panel:SetAllPoints()
        end
    else
        panel = CreateFrame("Frame", nil, frame)
        panel:SetAllPoints()
    end

    local baseLevel = frame:GetFrameLevel()

    -- Header (drag area). Stops before the close button so they don't overlap.
    local header = CreateFrame("Frame", nil, frame)
    header:SetHeight(CHAT_HEADER_HEIGHT)
    header:SetPoint("TOPLEFT", PADDING, -PADDING)
    header:SetPoint("TOPRIGHT", -(PADDING + CLOSE_SIZE + 4), -PADDING)
    header:SetFrameLevel(baseLevel + 2)
    header:EnableMouse(true)
    header:RegisterForDrag("LeftButton")
    header:SetScript("OnDragStart", function() frame:StartMoving() end)
    header:SetScript("OnDragStop", function() frame:StopMovingOrSizing() end)

    local title
    if UI.CreateText then
        title = UI.CreateText(header, UI.Font.small)
    else
        title = header:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    end
    title:SetPoint("LEFT", 2, 0)
    title:SetText("Error Logs")

    -- Close button (top right, inside the header row)
    local close
    if UI.CreateButton then
        local ok, c = pcall(UI.CreateButton, frame, {
            style = "ghost", icon = "close", iconSize = 10,
            width = CLOSE_SIZE, height = CLOSE_SIZE,
            tooltip = "Close the error logs",
            onClick = function() frame:Hide() end,
        })
        if ok and c then
            close = c
        else
            close = CreateFrame("Button", nil, frame)
            close:SetSize(CLOSE_SIZE, CLOSE_SIZE)
            close:SetNormalTexture("Interface\\Buttons\\UI-Panel-MinimizeButton-Up")
            close:SetHighlightTexture("Interface\\Buttons\\UI-Panel-MinimizeButton-Highlight")
            close:SetPushedTexture("Interface\\Buttons\\UI-Panel-MinimizeButton-Down")
            close:SetScript("OnClick", function() frame:Hide() end)
        end
    else
        close = CreateFrame("Button", nil, frame)
        close:SetSize(CLOSE_SIZE, CLOSE_SIZE)
        close:SetNormalTexture("Interface\\Buttons\\UI-Panel-MinimizeButton-Up")
        close:SetHighlightTexture("Interface\\Buttons\\UI-Panel-MinimizeButton-Highlight")
        close:SetPushedTexture("Interface\\Buttons\\UI-Panel-MinimizeButton-Down")
        close:SetScript("OnClick", function() frame:Hide() end)
    end
    close:ClearAllPoints()
    close:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -PADDING, -(PADDING + 2))
    close:SetFrameLevel(baseLevel + 10)           -- always above header/scroll
    close:SetHitRectInsets(-4, -4, -4, -4)        -- bigger click area
    if close.icon and UI.Tint then pcall(UI.Tint, close.icon, Color.white) end
    close:HookScript("OnEnter", function(button)
        if button.icon and UI.Tint then pcall(UI.Tint, button.icon, Color.accentHover) end
    end)
    close:HookScript("OnLeave", function(button)
        if button.icon and UI.Tint then pcall(UI.Tint, button.icon, Color.white) end
    end)

    -- Resizer (bottom right corner)
    local resizer = CreateFrame("Button", nil, frame)
    resizer:SetSize(RESIZER_SIZE, RESIZER_SIZE)
    resizer:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -(PADDING - 2), PADDING - 2)
    resizer:SetFrameLevel(baseLevel + 10)
    resizer:SetHitRectInsets(-4, -4, -4, -4)
    resizer:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    resizer:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
    resizer:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
    local nt = resizer:GetNormalTexture()
    local ht = resizer:GetHighlightTexture()
    local pt = resizer:GetPushedTexture()
    if nt and UI.Tint then pcall(UI.Tint, nt, Color.white) end
    if ht and UI.Tint then pcall(UI.Tint, ht, Color.accentHover) end
    if pt and UI.Tint then pcall(UI.Tint, pt, Color.accentHover) end
    resizer:SetScript("OnEnter", function()
        if nt and UI.Tint then pcall(UI.Tint, nt, Color.accentHover) end
    end)
    resizer:SetScript("OnLeave", function()
        if nt and UI.Tint then pcall(UI.Tint, nt, Color.white) end
    end)
    resizer:SetScript("OnMouseDown", function()
        frame:StartSizing("BOTTOMRIGHT")
    end)
    resizer:SetScript("OnMouseUp", function()
        frame:StopMovingOrSizing()
    end)

    -- Scroll area: sits between the header and the resizer, leaving room
    -- on the right for the scroll bar (and its arrows).
    local scroll = CreateFrame("ScrollFrame", nil, frame, "UIPanelScrollFrameTemplate")
    scroll:SetFrameLevel(baseLevel + 1)
    scroll:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -4)
    scroll:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT",
        -(PADDING + SCROLLBAR_SPACE), PADDING + RESIZER_SIZE)

    local content = CreateFrame("Frame", nil, scroll)
    content:SetWidth(1)
    content:SetHeight(1)
    scroll:SetScrollChild(content)

    frame.content = content
    frame.scroll = scroll
    return frame
end

local function refresh()
    local frame = createLog()
    local content = frame.content
    local scroll = frame.scroll

    -- Hide pooled lines (FontStrings are regions, not children, so reuse them)
    for i = 1, #lines do lines[i]:Hide() end

    TrialChatDB = TrialChatDB or {}
    local logs = TrialChatDB.errorLogs or {}

    local width = scroll:GetWidth()
    if not width or width < 50 then
        width = frame:GetWidth() - PADDING * 2 - SCROLLBAR_SPACE
    end
    local textWidth = math.max(50, width - 8)

    local y, n = 0, 0
    for i = #logs, 1, -1 do
        local entry = logs[i]
        n = n + 1
        local text = lines[n]
        if not text then
            text = content:CreateFontString(nil, "OVERLAY")
            pcall(text.SetFont, text, "Fonts\\FRIZQT__.TTF", 10)
            text:SetJustifyH("LEFT")
            text:SetJustifyV("TOP")
            lines[n] = text
        end

        local timeStr = ""
        if type(entry.time) == "number" and date then
            timeStr = date("%H:%M:%S", entry.time) .. " "
        end

        text:ClearAllPoints()
        text:SetPoint("TOPLEFT", content, "TOPLEFT", 4, -y)
        text:SetWidth(textWidth)
        text:SetText(timeStr .. (entry.text or ""))
        if entry.isError then
            text:SetTextColor(1, 0.3, 0.3)
        else
            text:SetTextColor(0.7, 0.7, 0.7)
        end
        text:Show()

        y = y + (text:GetStringHeight() or 12) + 2
    end

    content:SetHeight(math.max(y, 1))
    content:SetWidth(width)
end

function TrialChatErrorLog:Show()
    local frame = createLog()
    frame:Show()
    refresh() -- after Show so the scroll frame has a real size
    frame:Raise()
    if not frame.sizeHooked then
        frame.sizeHooked = true
        frame:SetScript("OnSizeChanged", function(f)
            if f:IsShown() then refresh() end
        end)
    end
end

function TrialChatErrorLog:Hide()
    if logFrame then logFrame:Hide() end
end

function TrialChatErrorLog:Toggle()
    if logFrame and logFrame:IsShown() then
        self:Hide()
    else
        self:Show()
    end
end
