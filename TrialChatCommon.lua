TrialChatCommon = {}

local linkInputs = {}
local linkInsertHooked = false

function TrialChatCommon.RegisterLinkInput(input)
    linkInputs[input] = true

    if linkInsertHooked or not ChatFrameUtil or not ChatFrameUtil.InsertLink then
        return
    end

    hooksecurefunc(ChatFrameUtil, "InsertLink", function(link)
        if not link then return end

        for registeredInput in pairs(linkInputs) do
            if registeredInput:IsShown() and registeredInput:HasFocus() then
                registeredInput:Insert(link)
                return
            end
        end
    end)
    linkInsertHooked = true
end

function TrialChatCommon.NormalizeMessageMarkup(text)
    text = string.gsub(text, "||([cChHrRtT])", "|%1")
    text = string.gsub(text, "\\124([cChHrRtT])", "|%1")

    local isPastedScript = string.match(text, "^%s*/script%s+")
        or string.find(text, "DEFAULT_CHAT_FRAME:AddMessage(", 1, true)
    if isPastedScript then
        local itemLink = string.match(text,
            "|cnIQ%d+:|Hitem:[^|]+|h[^|]*|h|r")
            or string.match(text,
                "|c%x%x%x%x%x%x%x%x|Hitem:[^|]+|h[^|]*|h|r")
        if itemLink then
            return itemLink
        end
    end

    return text
end

function TrialChatCommon.EncodeMessageMarkup(text)
    text = string.gsub(text, "~", "~~")
    return (string.gsub(text, "|", "~p"))
end

function TrialChatCommon.DecodeMessageMarkup(text)
    local result = {}
    local position = 1

    while position <= #text do
        if string.sub(text, position, position + 1) == "~~" then
            result[#result + 1] = "~"
            position = position + 2
        elseif string.sub(text, position, position + 1) == "~p" then
            result[#result + 1] = "|"
            position = position + 2
        else
            result[#result + 1] = string.sub(text, position, position)
            position = position + 1
        end
    end

    return table.concat(result)
end

local function encodeLinkPayload(text)
    return (string.gsub(text, ".", function(char)
        return string.format("%02x", string.byte(char))
    end))
end

local function decodeLinkPayload(text)
    if #text % 2 ~= 0 or string.find(text, "[^%x]") then return nil end

    return (string.gsub(text, "%x%x", function(byte)
        return string.char(tonumber(byte, 16))
    end))
end

local function makeURLLink(url)
    local encodedURL = encodeLinkPayload(url)
    return "|cff00ccff|Htcurl:" .. encodedURL .. "|h" .. url .. "|h|r"
end

function TrialChatCommon.FormatMessageText(text)
    local result = {}
    local position = 1

    while position <= #text do
        local namedColorLinkStart, namedColorLinkEnd =
            string.find(text, "|cn[%a]+%d+:|H[^|]+|h[^|]*|h|r", position)
        if namedColorLinkStart ~= position then
            namedColorLinkStart = nil
        end

        if namedColorLinkStart then
            result[#result + 1] =
                string.sub(text, namedColorLinkStart, namedColorLinkEnd)
            position = namedColorLinkEnd + 1
        else
            local colorEnd = string.sub(text, position, position + 1) == "|c"
                and position + 9
                or nil
            if colorEnd and string.match(
                string.sub(text, position + 2, colorEnd),
                "^%x%x%x%x%x%x%x%x$") then
                result[#result + 1] = string.sub(text, position, colorEnd)
                position = colorEnd + 1
            elseif string.sub(text, position, position + 1) == "|r" then
                result[#result + 1] = "|r"
                position = position + 2
            elseif string.sub(text, position, position + 1) == "||" then
                result[#result + 1] = "||"
                position = position + 2
            else
                local remainder = string.sub(text, position)
                local url = string.match(remainder, "^https?://[^%s<>\"|]+")
                if url then
                    url = string.gsub(url, "[.,!?;:)]+$", "")
                end
                local linkStart, linkEnd
                if url and #url > 0 then
                    result[#result + 1] = makeURLLink(url)
                    position = position + #url
                else
                    linkStart, linkEnd =
                        string.find(text, "|H[^|]+|h[^|]*|h", position)
                end
                if not url and linkStart == position then
                    result[#result + 1] = string.sub(text, linkStart, linkEnd)
                    position = linkEnd + 1
                elseif not url then
                    local char = string.sub(text, position, position)
                    result[#result + 1] = char == "|" and "||" or char
                    position = position + 1
                end
            end
        end
    end

    return table.concat(result)
end

local urlDialog

local function showURLCopyDialog(url)
    if not urlDialog then
        urlDialog = CreateFrame("Frame", "TrialChatURLDialog", UIParent, "BackdropTemplate")
        urlDialog:SetSize(460, 130)
        urlDialog:SetPoint("CENTER")
        urlDialog:SetFrameStrata("DIALOG")
        urlDialog:SetFrameLevel(200)
        urlDialog:SetMovable(true)
        urlDialog:EnableMouse(true)
        urlDialog:RegisterForDrag("LeftButton")
        urlDialog:SetScript("OnDragStart", urlDialog.StartMoving)
        urlDialog:SetScript("OnDragStop", urlDialog.StopMovingOrSizing)
        urlDialog:SetBackdrop({
            bgFile = "Interface/Tooltips/UI-Tooltip-Background",
            edgeFile = "Interface/Tooltips/UI-Tooltip-Border",
            tile = true,
            tileSize = 16,
            edgeSize = 16,
            insets = { left = 4, right = 4, top = 4, bottom = 4 },
        })
        urlDialog:SetBackdropColor(0.04, 0.04, 0.04, 0.95)

        local title = urlDialog:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        title:SetPoint("TOP", urlDialog, "TOP", 0, -14)
        title:SetText("Copy this URL")

        local instructions = urlDialog:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        instructions:SetPoint("TOP", title, "BOTTOM", 0, -8)
        instructions:SetText("WoW does not allow addons to open arbitrary websites. Press Ctrl+C to copy.")

        urlDialog.input = CreateFrame("EditBox", nil, urlDialog, "InputBoxTemplate")
        urlDialog.input:SetPoint("TOPLEFT", urlDialog, "TOPLEFT", 18, -62)
        urlDialog.input:SetPoint("RIGHT", urlDialog, "RIGHT", -18, 0)
        urlDialog.input:SetHeight(24)
        urlDialog.input:SetAutoFocus(false)
        urlDialog.input:SetMaxLetters(2048)

        local closeButton = CreateFrame("Button", nil, urlDialog, "UIPanelButtonTemplate")
        closeButton:SetSize(70, 22)
        closeButton:SetPoint("BOTTOM", urlDialog, "BOTTOM", 0, 10)
        closeButton:SetText(CLOSE)
        closeButton:SetScript("OnClick", function()
            urlDialog:Hide()
        end)
        urlDialog:Hide()
    end

    urlDialog.input:SetText(url)
    urlDialog:Show()
    urlDialog.input:SetFocus()
    urlDialog.input:HighlightText()
end

function TrialChatCommon.HandleHyperlinkClick(link, text, button)
    local encodedURL = string.match(link or "", "^tcurl:(%x+)$")
    local url = encodedURL and decodeLinkPayload(encodedURL)
    if url and string.match(url, "^https?://") and not string.find(url, "[%c|]") then
        showURLCopyDialog(url)
        return
    end

    SetItemRef(link, text, button, DEFAULT_CHAT_FRAME)
end

local emoteDescriptions = {
    chicken = "With arms flapping, you strut around. Cluck, Cluck, Chicken!",
    flap = "With arms flapping, you strut around. Cluck, Cluck, Chicken!",
    strut = "With arms flapping, you strut around. Cluck, Cluck, Chicken!",
    dance = "You burst into dance.",
    bow = "bows.",
    wave = "waves.",
    laugh = "laughs.",
    lol = "laughs.",
    chuckle = "chuckles.",
    cry = "cries.",
    cheer = "cheers!",
    woot = "cheers!",
    clap = "claps.",
    point = "points.",
    shrug = "shrugs.",
    nod = "nods.",
    no = "shakes their head.",
    yes = "nods yes.",
    sigh = "sighs.",
    salute = "salutes.",
    roar = "roars.",
    flex = "You flex your muscles. Oooooh so strong!",
    kiss = "blows a kiss.",
    hug = "gives a hug.",
    thanks = "gives thanks.",
    thank = "gives thanks.",
    sleep = "falls asleep.",
    sit = "sits down.",
    rude = "makes a rude gesture.",
    train = "You make a train noise.",
    welcome = "welcomes everyone.",
    goodbye = "waves goodbye.",
    bye = "waves goodbye.",
    applaud = "applauds.",
    applause = "applauds.",
    bravo = "applauds.",
    blush = "blushes.",
    confused = "looks confused.",
    cower = "cowers in fear.",
    gasp = "gasps.",
    groan = "groans.",
    growl = "growls.",
    pity = "looks at everyone with pity.",
    rofl = "rolls on the floor laughing.",
    shy = "acts shy.",
    weep = "weeps.",
    sob = "cries.",
    sorry = "apologizes.",
    apologize = "apologizes.",
    mad = "raises their fist in anger.",
    angry = "raises their fist in anger.",
    strong = "You flex your muscles. Oooooh so strong!",
    farewell = "waves goodbye.",
    hi = "greets everyone with a hearty hello!",
    hello = "greets everyone with a hearty hello!",
    grats = "congratulates everyone around you.",
    congrats = "congratulates everyone around you.",
}

function TrialChatCommon.ParseEmote(message)
    message = TrialChatCommon.NormalizeMessageMarkup(message)
    local command, argument = string.match(message, "^/([%a]+)%s*(.-)%s*$")
    if not command then
        return message, false
    end

    command = string.lower(command)
    if command == "e" or command == "em" or command == "emote" or command == "me" then
        if argument == "" then
            return nil
        end
        return argument, true, nil, nil
    end

    local token = _G.hash_EmoteTokenList
        and _G.hash_EmoteTokenList["/" .. string.upper(command)]
    if not token then
        return message, false
    end

    local description = emoteDescriptions[command]
        or ("performs /" .. command .. ".")
    return description, true, token, argument ~= "" and argument or nil
end

function TrialChatCommon.PerformEmote(token, target)
    if not token then return end
    C_ChatInfo.PerformEmote(token, target)
end
