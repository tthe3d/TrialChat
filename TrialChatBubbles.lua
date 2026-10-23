local BUBBLE_MAX_WIDTH = 220
local BUBBLE_MAX_TEXT_BYTES = 250
local BUBBLE_TEXT_PADDING = 9
local BUBBLE_OFFSET_Y = 25
local BUBBLE_TAIL_SIZE = 16
local BUBBLE_TAIL_OFFSET_X = -9
local BUBBLE_TAIL_OFFSET_Y = 6
local BUBBLE_MIN_SECONDS = 4
local BUBBLE_MAX_SECONDS = 12
local BUBBLE_SECONDS_PER_BYTE = 0.05
local BUBBLE_FADE_SECONDS = 0.5
local OWN_BUBBLE_OFFSET_Y = 3
local OWN_BUBBLE_ZOOM_OFFSET = 480
local OWN_BUBBLE_MIN_ZOOM = 1
local MAX_NAMEPLATES = 40
local DEFAULT_BUBBLE_COLOR = { r = 1, g = 1, b = 1 }
local GROUP_BUBBLE_COLOR = { r = 0.7, g = 0.42, b = 1 }
local GROUP_TAG_COLOR = string.format("|cff%02x%02x%02x",
    math.floor(GROUP_BUBBLE_COLOR.r * 255 + 0.5),
    math.floor(GROUP_BUBBLE_COLOR.g * 255 + 0.5),
    math.floor(GROUP_BUBBLE_COLOR.b * 255 + 0.5))

TrialChatBubbles = {}

local bubblesByPlate = {}
local bubblesByUnit = {}
local ownBubble

-- Nearby bubbles we've drawn, by sender, and recent /say messages, so a
-- message that arrives both as a TrialChat message and as a /say (when the
-- sender has "echo to say" on) only produces one bubble.
local nearbyBubbleBySender = {}
local recentSays = {}
local SAY_DEDUP_SECONDS = 2

local function isBubblesEnabled()
    return not (TrialChatDB and TrialChatDB.chatBubbles == false)
end

local function isOwnBubbleEnabled()
    return isBubblesEnabled()
        and not (TrialChatDB and TrialChatDB.ownChatBubble == false)
end

local function isGroupBubblesEnabled()
    return isBubblesEnabled()
        and not (TrialChatDB and TrialChatDB.groupChatBubbles == false)
end

-- Bubbles float in the game world, so only plain text is shown: links keep
-- their visible text, everything else that could render markup is removed.
local function toPlainText(text)
    text = string.gsub(text, "||", "\1")
    text = string.gsub(text, "|H.-|h(.-)|h", "%1")
    text = string.gsub(text, "|c%x%x%x%x%x%x%x%x", "")
    text = string.gsub(text, "|cn[^:|]*:", "")
    text = string.gsub(text, "|r", "")
    text = string.gsub(text, "|[TAK].-|[tak]", "")
    text = string.gsub(text, "|", "||")
    return (string.gsub(text, "\1", "||"))
end

-- Long messages are shortened in the bubble; the chat window shows them in
-- full. The cut never splits a UTF-8 character or an escaped "||".
local function shortenForBubble(text)
    if #text <= BUBBLE_MAX_TEXT_BYTES then return text end
    text = string.sub(text, 1, BUBBLE_MAX_TEXT_BYTES)
    text = string.gsub(text, "[\192-\255][\128-\191]*$", "")
    if #string.match(text, "|*$") % 2 == 1 then
        text = string.sub(text, 1, -2)
    end
    return text .. "..."
end

local function findNamePlateUnit(sender)
    local senderKey = TrialChatCommon.NormalizeCharacterName(sender)
    for index = 1, MAX_NAMEPLATES do
        local unit = "nameplate" .. index
        if UnitExists(unit) and UnitIsPlayer(unit)
            and C_NamePlate.GetNamePlateForUnit(unit) then
            local name, realm = UnitFullName(unit)
            local isSecret = issecretvalue
                and (issecretvalue(name) or issecretvalue(realm))
            if not isSecret and name then
                if realm and realm ~= "" then
                    name = name .. "-" .. realm
                end
                if TrialChatCommon.NormalizeCharacterName(name) == senderKey then
                    return unit
                end
            end
        end
    end
end

local function hideBubble(bubble)
    bubble.fadeOut:Stop()
    bubble:Hide()
    if bubble.unit and bubblesByUnit[bubble.unit] == bubble then
        bubblesByUnit[bubble.unit] = nil
    end
end

-- Whether the game itself shows chat bubbles; only then does a /say produce
-- a bubble of its own. If it doesn't, the TrialChat bubble is the only one
-- and hiding it would leave the speaker with no bubble at all.
local function blizzardBubblesShown()
    return GetCVar ~= nil and GetCVar("chatBubbles") == "1"
end

-- The text a bubble shows for a message, used to tell whether a TrialChat
-- message and a /say are the same one.
local function bubbleText(message)
    local text = strtrim(toPlainText(message))
    if text == "" then return "" end
    return shortenForBubble(text)
end

local function sayKey(sender, text)
    return TrialChatCommon.NormalizeCharacterName(sender) .. "\0" .. (text or "")
end

local function wasRecentlySaid(sender, text)
    local at = recentSays[sayKey(sender, text)]
    return at ~= nil and GetTime() - at <= SAY_DEDUP_SECONDS
end

-- A /say came in: remember it so a TrialChat bubble for the same message is
-- skipped, and drop one already shown for it (the game draws its own).
local function onSaySpoken(sender, message)
    if not sender or not message or TrialChatCommon.IsSelf(sender) then return end
    if not blizzardBubblesShown() then return end

    local text = bubbleText(message)
    if text == "" then return end

    local key = sayKey(sender, text)
    recentSays[key] = GetTime()
    C_Timer.After(SAY_DEDUP_SECONDS, function()
        if recentSays[key] and GetTime() - recentSays[key] >= SAY_DEDUP_SECONDS then
            recentSays[key] = nil
        end
    end)

    local senderKey = TrialChatCommon.NormalizeCharacterName(sender)
    local record = nearbyBubbleBySender[senderKey]
    if record and record.text == text then
        nearbyBubbleBySender[senderKey] = nil
        hideBubble(record.bubble)
    end
end

local function createBubble(parent)
    local bubble = CreateFrame("Frame", nil, parent, "ChatBubbleTemplate")
    bubble:SetFrameLevel(parent:GetFrameLevel() + 10)
    bubble:SetIgnoreParentAlpha(true)
    -- Nameplates are scaled down (and shrink with distance); Blizzard's own
    -- bubbles live on the WorldFrame, so match its scale instead.
    bubble:SetIgnoreParentScale(true)
    -- The template leaves the tail unanchored, which stretches it over the
    -- bubble. Blizzard's bubbles draw it at a quarter of its atlas size.
    bubble.Tail:ClearAllPoints()
    bubble.Tail:SetAtlas("ChatBubble-Tail")
    bubble.Tail:SetSize(BUBBLE_TAIL_SIZE, BUBBLE_TAIL_SIZE)
    bubble.Tail:SetPoint("TOP", bubble, "BOTTOM",
        BUBBLE_TAIL_OFFSET_X, BUBBLE_TAIL_OFFSET_Y)

    bubble.fadeOut = bubble:CreateAnimationGroup()
    local fade = bubble.fadeOut:CreateAnimation("Alpha")
    fade:SetFromAlpha(1)
    fade:SetToAlpha(0)
    fade:SetDuration(BUBBLE_FADE_SECONDS)
    bubble.fadeOut:SetScript("OnFinished", function()
        hideBubble(bubble)
    end)

    bubble:Hide()
    return bubble
end

-- Group chat bubbles get a purple border and tail and the group's name on
-- top, so they can't be mistaken for nearby chat.
local function showBubble(bubble, text, groupName)
    local color = groupName and GROUP_BUBBLE_COLOR or DEFAULT_BUBBLE_COLOR
    bubble:SetBorderColor(color.r, color.g, color.b)
    bubble.Tail:SetVertexColor(color.r, color.g, color.b)
    bubble.groupName = groupName

    bubble:SetScale(WorldFrame:GetEffectiveScale())
    bubble.String:SetWidth(BUBBLE_MAX_WIDTH)
    local width = 0
    local tag = groupName and GROUP_TAG_COLOR .. "[" .. groupName .. "]|r"
    if tag then
        bubble.String:SetText(tag)
        width = bubble.String:GetUnboundedStringWidth()
    end
    bubble.String:SetText(text)
    width = math.max(width, bubble.String:GetUnboundedStringWidth())
    if tag then
        bubble.String:SetText(tag .. "\n" .. text)
    end
    bubble.String:SetWidth(math.min(BUBBLE_MAX_WIDTH,
        math.ceil(width) + BUBBLE_TEXT_PADDING))
    bubble.fadeOut:Stop()
    bubble:SetAlpha(1)
    bubble:Show()

    bubble.messageCounter = (bubble.messageCounter or 0) + 1
    local messageCounter = bubble.messageCounter
    local seconds = math.max(BUBBLE_MIN_SECONDS,
        math.min(BUBBLE_MAX_SECONDS, #text * BUBBLE_SECONDS_PER_BYTE))
    C_Timer.After(seconds, function()
        if bubble.messageCounter == messageCounter and bubble:IsShown() then
            bubble.fadeOut:Play()
        end
    end)
end

function TrialChatBubbles.ShowMessage(sender, message, groupName)
    if not isBubblesEnabled() or not sender or not message then return end
    if groupName and not isGroupBubblesEnabled() then return end

    local text = bubbleText(message)
    if text == "" then return end

    -- The message may also be arriving as a /say the game will bubble itself;
    -- skip ours so it isn't shown twice.
    local isNearby = not groupName
    if isNearby and blizzardBubblesShown() and wasRecentlySaid(sender, text) then
        return
    end

    local unit = findNamePlateUnit(sender)
    local plate = unit and C_NamePlate.GetNamePlateForUnit(unit)
    if not plate then return end

    local bubble = bubblesByPlate[plate]
    if not bubble then
        bubble = createBubble(plate)
        bubble.String:SetPoint("BOTTOM", plate, "TOP", 0, BUBBLE_OFFSET_Y)
        bubblesByPlate[plate] = bubble
    end
    if bubble.unit and bubblesByUnit[bubble.unit] == bubble then
        bubblesByUnit[bubble.unit] = nil
    end
    bubble.unit = unit
    bubblesByUnit[unit] = bubble

    showBubble(bubble, text, groupName)

    -- Remember it, so a /say for the same message arriving just after can
    -- take over (the game's bubble sits on the speaker's real position).
    if isNearby then
        local senderKey = TrialChatCommon.NormalizeCharacterName(sender)
        local record = { bubble = bubble, text = text, at = GetTime() }
        nearbyBubbleBySender[senderKey] = record
        C_Timer.After(SAY_DEDUP_SECONDS, function()
            if nearbyBubbleBySender[senderKey] == record then
                nearbyBubbleBySender[senderKey] = nil
            end
        end)
    end
end

-- Your own character has no nameplate and addons can't ask where it is on
-- screen. The camera orbits your character's head, so the head is usually
-- near the middle of the screen; keep the bubble just above that spot and
-- bring it closer as the camera zooms out.
local function updateOwnBubblePosition(bubble)
    local zoom = GetCameraZoom()
    if zoom == bubble.zoom then return end
    bubble.zoom = zoom

    if zoom < OWN_BUBBLE_MIN_ZOOM then
        hideBubble(bubble)
        return
    end
    bubble.String:ClearAllPoints()
    bubble.String:SetPoint("BOTTOM", WorldFrame, "CENTER", 0,
        OWN_BUBBLE_OFFSET_Y + OWN_BUBBLE_ZOOM_OFFSET / zoom)
end

function TrialChatBubbles.ShowOwnMessage(message, groupName)
    if not isOwnBubbleEnabled() or not message then return end
    if groupName and not isGroupBubblesEnabled() then return end
    if GetCameraZoom() < OWN_BUBBLE_MIN_ZOOM then return end

    local text = strtrim(toPlainText(message))
    if text == "" then return end
    text = shortenForBubble(text)

    if not ownBubble then
        ownBubble = createBubble(WorldFrame)
        ownBubble:SetScript("OnUpdate", updateOwnBubblePosition)
    end
    ownBubble.zoom = nil
    updateOwnBubblePosition(ownBubble)
    showBubble(ownBubble, text, groupName)
end

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("NAME_PLATE_UNIT_REMOVED")
eventFrame:RegisterEvent("CHAT_MSG_SAY")
eventFrame:SetScript("OnEvent", function(_, event, ...)
    if event == "CHAT_MSG_SAY" then
        local message, sender = ...
        onSaySpoken(sender, message)
        return
    end
    local unit = ...
    local bubble = bubblesByUnit[unit]
    if bubble then
        hideBubble(bubble)
    end
end)

-- option is nil for chat bubbles in general, or "self" or "groups" like
-- /tcbubbles (their own setting, which only matters while bubbles are on);
-- turning them on and off goes through /tcbubbles as well.
function TrialChatBubbles.IsEnabled(option)
    if option == "self" then
        return not (TrialChatDB and TrialChatDB.ownChatBubble == false)
    end
    if option == "groups" then
        return not (TrialChatDB and TrialChatDB.groupChatBubbles == false)
    end
    return isBubblesEnabled()
end

SLASH_TRIALCHATBUBBLES1 = "/tcbubbles"
SlashCmdList["TRIALCHATBUBBLES"] = function(msg)
    TrialChatDB = TrialChatDB or {}
    local option = strlower(strtrim(msg or ""))
    if option == "groups" then
        TrialChatDB.groupChatBubbles = TrialChatDB.groupChatBubbles == false
        if not TrialChatDB.groupChatBubbles then
            for _, bubble in pairs(bubblesByPlate) do
                if bubble.groupName then
                    hideBubble(bubble)
                end
            end
            if ownBubble and ownBubble.groupName then
                hideBubble(ownBubble)
            end
        end
        print("|cff70A2FF[TrialChat]|r Group chat bubbles "
            .. (TrialChatDB.groupChatBubbles and "on" or "off") .. ".")
        return
    end
    if option == "self" then
        TrialChatDB.ownChatBubble = TrialChatDB.ownChatBubble == false
        if not TrialChatDB.ownChatBubble and ownBubble then
            hideBubble(ownBubble)
        end
        print("|cff70A2FF[TrialChat]|r Chat bubble over your own character "
            .. (TrialChatDB.ownChatBubble and "on" or "off") .. ".")
        return
    end

    TrialChatDB.chatBubbles = not isBubblesEnabled()
    if not TrialChatDB.chatBubbles then
        for _, bubble in pairs(bubblesByPlate) do
            hideBubble(bubble)
        end
        if ownBubble then
            hideBubble(ownBubble)
        end
    end
    print("|cff70A2FF[TrialChat]|r Chat bubbles "
        .. (TrialChatDB.chatBubbles and "on" or "off") .. ".")
end
