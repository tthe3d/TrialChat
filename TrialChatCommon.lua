TrialChatCommon = {}

local playerName
local playerRealm
local fullPlayerName
local normalizedPlayerRealm
local playerClass
local linkInputs = {}
local linkInsertHooked = false

function TrialChatCommon.RefreshPlayerIdentity()
    playerName = UnitName("player")
    fullPlayerName, playerRealm = UnitFullName("player")
    normalizedPlayerRealm = GetNormalizedRealmName and GetNormalizedRealmName()
    _, playerClass = UnitClass("player")
    if fullPlayerName and playerRealm and playerRealm ~= "" then
        fullPlayerName = fullPlayerName .. "-" .. playerRealm
    end
end

function TrialChatCommon.GetPlayerName()
    return playerName
end

function TrialChatCommon.GetPlayerFullName()
    return fullPlayerName or playerName
end

function TrialChatCommon.GetPlayerClass()
    return playerClass
end

function TrialChatCommon.GetPlayerRealm()
    return playerRealm
end

function TrialChatCommon.NormalizeName(name)
    return name and strlower(name) or nil
end

function TrialChatCommon.ShortName(name)
    return string.match(name or "", "^([^-]+)") or name
end

function TrialChatCommon.NormalizeCharacterName(name)
    local normalized = TrialChatCommon.NormalizeName(name)
    if normalized and name and not string.find(name, "-", 1, true)
        and playerRealm and playerRealm ~= "" then
        return normalized .. "-" .. TrialChatCommon.NormalizeName(playerRealm)
    end
    return normalized
end

function TrialChatCommon.NormalizeRealm(realm)
    return TrialChatCommon.NormalizeName((string.gsub(realm or "", "[%s']", "")))
end

function TrialChatCommon.IsSelf(sender)
    if not sender or sender == "" then return false end

    local senderKey = TrialChatCommon.NormalizeName(sender)
    if senderKey == TrialChatCommon.NormalizeName(fullPlayerName) then
        return true
    end

    local senderShort, senderRealm = string.match(sender, "^([^-]+)%-(.+)$")
    if not senderShort then
        return senderKey == TrialChatCommon.NormalizeName(playerName)
    end
    if TrialChatCommon.NormalizeName(senderShort)
        ~= TrialChatCommon.NormalizeName(playerName) then
        return false
    end

    local currentRealm = normalizedPlayerRealm or playerRealm
    if not currentRealm or currentRealm == "" then return false end
    return TrialChatCommon.NormalizeRealm(senderRealm)
        == TrialChatCommon.NormalizeRealm(currentRealm)
end

function TrialChatCommon.NamesMatch(left, right)
    if TrialChatCommon.NormalizeName(left) == TrialChatCommon.NormalizeName(right) then
        return true
    end
    if string.find(left or "", "-", 1, true)
        and string.find(right or "", "-", 1, true) then
        return false
    end

    local leftShort = string.match(left or "", "^([^-]+)")
    local rightShort = string.match(right or "", "^([^-]+)")
    return leftShort ~= nil
        and TrialChatCommon.NormalizeName(leftShort)
            == TrialChatCommon.NormalizeName(rightShort)
end

function TrialChatCommon.GetClassColor(classFile)
    local classColor = classFile and RAID_CLASS_COLORS[classFile]
    if not classColor then return nil end
    if classColor.colorStr then
        return "|c" .. classColor.colorStr
    end

    return string.format("|cff%02x%02x%02x",
        math.floor(classColor.r * 255),
        math.floor(classColor.g * 255),
        math.floor(classColor.b * 255))
end

TrialChatCommon.RefreshPlayerIdentity()

function TrialChatCommon.RegisterLinkInput(input)
    linkInputs[input] = true

    input:HookScript("OnEditFocusGained", function(self)
        if ChatFrameUtil and ChatFrameUtil.SetChatFocusOverride then
            ChatFrameUtil.SetChatFocusOverride(self)
        end
    end)
    local function clearChatFocusOverride(self)
        if ChatFrameUtil
            and ChatFrameUtil.GetChatFocusOverride
            and ChatFrameUtil.GetChatFocusOverride() == self
            and ChatFrameUtil.ClearChatFocusOverride then
            ChatFrameUtil.ClearChatFocusOverride()
        end
    end
    input:HookScript("OnEditFocusLost", clearChatFocusOverride)
    input:HookScript("OnHide", clearChatFocusOverride)

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
    return (string.gsub(text, "~.", function(escape)
        if escape == "~~" then
            return "~"
        elseif escape == "~p" then
            return "|"
        end
        return escape
    end))
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

local function findHyperlinkEnd(text, position)
    local targetEnd = string.find(text, "|h", position + 2, true)
    if not targetEnd then return nil end

    local displayEnd = targetEnd + 2
    while true do
        local linkEnd = string.find(text, "|h", displayEnd, true)
        if not linkEnd then return nil end
        if string.sub(text, linkEnd - 1, linkEnd - 1) ~= "|" then
            return linkEnd + 1
        end
        displayEnd = linkEnd + 2
    end
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
                    linkEnd = findHyperlinkEnd(text, position)
                    if linkEnd then
                        linkStart = position
                    end
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
    local encodedPlayerName = string.match(link or "", "^tcplayer:(%x+)$")
    if encodedPlayerName then
        local playerName = decodeLinkPayload(encodedPlayerName)
        TrialChatCommon.ShowPlayerOptions(playerName, text, button)
        return
    end

    local encodedURL = string.match(link or "", "^tcurl:(%x+)$")
    local url = encodedURL and decodeLinkPayload(encodedURL)
    if url and string.match(url, "^https?://") and not string.find(url, "[%c|]") then
        showURLCopyDialog(url)
        return
    end

    SetItemRef(link, text, button, DEFAULT_CHAT_FRAME)
end

function TrialChatCommon.ShowPlayerOptions(playerName, displayName, button)
    if not playerName or playerName == ""
        or string.find(playerName, "[%c|]") then
        return
    end

    SetItemRef("player:" .. playerName, displayName or playerName,
        button or "LeftButton", DEFAULT_CHAT_FRAME)
end

function TrialChatCommon.RemovePlayerLinks(text)
    text = string.gsub(text, "|Htcplayer:%x+|h(.-)|h", "%1", 1)
    return (string.gsub(text, "|Hplayer:[^|]+|h(.-)|h", "%1", 1))
end

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

    local description = TrialChatCommon.EmoteDescriptions[command]
    if not description then
        return message, false
    end

    local target = argument
    if target == "" and UnitExists("target") then
        target = UnitName("target") or ""
    end

    if target ~= "" then
        local targetedDescription =
            TrialChatCommon.TargetedEmoteDescriptions[command]
        if targetedDescription then
            description = string.gsub(targetedDescription,
                "%[playername%]", function() return target end)
        end
    end

    local token = _G.hash_EmoteTokenList
        and _G.hash_EmoteTokenList["/" .. string.upper(command)]
    return description, true, token, target ~= "" and target or nil
end

function TrialChatCommon.PerformEmote(token, target)
    if not token then return end
    C_ChatInfo.PerformEmote(token, target)
end
