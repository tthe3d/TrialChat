TrialChatCommon = {}

local linkInputs = {}
local linkInsertHooked = false

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

local emoteDescriptions = {
    chicken = "struts around with arms flapping. Cluck, cluck, chicken!",
    flap = "struts around with arms flapping. Cluck, cluck, chicken!",
    strut = "struts around with arms flapping. Cluck, cluck, chicken!",
    dance = "bursts into dance.",
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
    flex = "flexes their muscles. Oooooh so strong!",
    kiss = "blows a kiss.",
    hug = "gives a hug.",
    thanks = "gives thanks.",
    thank = "gives thanks.",
    sleep = "falls asleep.",
    sit = "sits down.",
    rude = "makes a rude gesture.",
    train = "makes a train noise.",
    welcome = "welcomes everyone.",
    goodbye = "waves goodbye.",
    bye = "waves goodbye.",
    applaud = "applauds.",
    applause = "applauds.",
    bravo = "applauds.",
    blush = "blushes.",
    confused = "looks confused.",
    cower = "cowers in fear.",
    poke = "pokes.... somebody.",
    gasp = "gasps.",
    groan = "groans.",
    growl = "growls.",
    pity = "looks at everyone with pity.",
    rofl = "rolls on the floor laughing.",
    shy = "acts shy.",
    weep = "weeps.",
    sob = "sobs.",
    sorry = "apologizes.",
    apologize = "apologizes.",
    mad = "raises their fist in anger.",
    angry = "raises their fist in anger.",
    strong = "flexes their muscles. Oooooh so strong!",
    farewell = "waves goodbye.",
    hi = "greets everyone with a hearty hello!",
    hello = "greets everyone with a hearty hello!",
    grats = "congratulates everyone nearby.",
    congrats = "congratulates everyone nearby.",
    absent = "looks absent-minded.",
    agree = "agrees.",
    amaze = "is amazed!",
    arm = "stretches their arms out.",
    attacktarget = "tells everyone to attack something.",
    awe = "looks around in awe.",
    backpack = "digs through their backpack.",
    bad = "has a bad feeling about this...",
    badfeeling = "has a bad feeling about this...",
    bark = "barks. Woof woof!",
    bashful = "is bashful.",
    beckon = "beckons everyone over to them.",
    beg = "begs everyone around them. How pathetic.",
    belch = "lets out a loud belch.",
    bite = "looks around for someone to bite.",
    blame = "blames themself for what happened.",
    blank = "stares blankly at their surroundings.",
    blink = "blinks their eyes.",
    blow = "blows a kiss into the wind.",
    boggle = "boggles at the situation.",
    bonk = "bonks themself on the noggin. Doh!",
    boop = "boops their own nose. Boop!",
    bored = "is overcome with boredom. Oh the drudgery!",
    bounce = "bounces up and down.",
    brandish = "brandishes their weapon fiercely.",
    brb = "lets everyone know they'll be right back.",
    breath = "takes a deep breath.",
    brow = "raises their eyebrow inquisitively.",
    burp = "lets out a loud belch.",
    cackle = "cackles maniacally at the situation.",
    calm = "remains calm.",
    cat = "scratches themself. Ah, much better!",
    catty = "scratches themself. Ah, much better!",
    challenge = "puts out a challenge to everyone. Bring it on!",
    charge = "starts to charge.",
    charm = "puts on the charm.",
    chew = "begins to eat.",
    chug = "takes a mighty quaff of their beverage.",
    cold = "lets everyone know that they are cold.",
    comfort = "needs to be comforted.",
    commend = "commends everyone on a job well done.",
    congratulate = "congratulates everyone around them.",
    cough = "lets out a hacking cough.",
    coverears = "covers their ears.",
    crack = "cracks their knuckles.",
    cringe = "cringes in fear.",
    crossarms = "crosses their arms.",
    cuddle = "needs to be cuddled.",
    curious = "expresses their curiosity to those around them.",
    curtsey = "curtseys.",
    ding = "reached a new level. DING!",
    disagree = "disagrees.",
    disappointed = "frowns.",
    doh = "bonks themself on the noggin. Doh!",
    doom = "threatens everyone with the wrath of doom.",
    doubt = "doubts the situation will end in their favor.",
    drink = "raises a drink in the air before chugging it down. Cheers!",
    duck = "ducks for cover.",
    eat = "begins to eat.",
    embarrass = "flushes with embarrassment.",
    encourage = "encourages everyone around them.",
    enemy = "warns everyone that an enemy is near.",
    excited = "talks excitedly with everyone.",
    eye = "crosses their eyes.",
    eyebrow = "raises their eyebrow inquisitively.",
    eyeroll = "rolls their eyes.",
    facepalm = "covers their face with their palm.",
    faint = "faints.",
    fart = "farts loudly. Whew...what stinks?",
    fear = "cowers in fear.",
    feast = "begins to eat.",
    fidget = "fidgets.",
    fist = "shakes their fist.",
    flee = "yells for everyone to flee!",
    flirt = "flirts.",
    flop = "flops about helplessly.",
    followme = "motions for everyone to follow.",
    food = "is hungry!",
    forthealliance = "cheers for the Alliance!",
    forthehorde = "cheers for the Horde!",
    frown = "frowns.",
    gaze = "gazes off into the distance.",
    giggle = "giggles.",
    glad = "is filled with happiness!",
    glare = "glares angrily.",
    gloat = "gloats over everyone's misfortune.",
    glower = "glowers at everyone around them.",
    go = "tells everyone to go.",
    going = "must be going.",
    golfclap = "claps half-heartedly, clearly unimpressed.",
    greet = "greets everyone warmly.",
    greetings = "greets everyone warmly.",
    grin = "grins wickedly.",
    grovel = "grovels on the ground, wallowing in subservience.",
    guffaw = "lets out a boisterous guffaw!",
    hail = "hails those around them.",
    happy = "is filled with happiness!",
    headache = "is getting a headache.",
    healme = "calls out for healing!",
    helpme = "cries out for help!",
    hiccup = "hiccups loudly.",
    highfive = "puts up their hand for a high five.",
    hiss = "hisses at everyone around them.",
    holdhand = "wishes someone would hold their hand.",
    holdit = "OBJECTS!",
    holler = "shouts.",
    hungry = "is hungry!",
    hurry = "tries to pick up the pace.",
    huzzah = "cheers boisterously! Huzzah!",
    idea = "has an idea!",
    impatient = "fidgets.",
    impressed = "claps vigorously, clearly impressed.",
    inc = "warns everyone of incoming enemies!",
    incoming = "warns everyone of incoming enemies!",
    insult = "thinks everyone around them is a son of a motherless ogre.",
    introduce = "introduces themself to everyone.",
    jealous = "is jealous of everyone around them.",
    jk = "was just kidding!",
    kneel = "kneels down.",
    knuckles = "cracks their knuckles.",
    lavish = "praises the Light.",
    lay = "lies down.",
    laydown = "lies down.",
    lick = "licks their lips.",
    lie = "lies down.",
    liedown = "lies down.",
    listen = "is listening!",
    look = "looks around.",
    lost = "is hopelessly lost.",
    love = "feels the love.",
    luck = "wishes everyone good luck.",
    magnificent = "nods approvingly. Magnificent job!",
    map = "pulls out their map.",
    massage = "needs a massage!",
    meow = "meows.",
    mercy = "pleads for mercy.",
    moan = "moans suggestively.",
    mock = "mocks life and all it stands for.",
    moon = "drops their trousers and moons everyone.",
    mutter = "mutters angrily to themself. Hmmmph!",
    nervous = "looks around nervously.",
    object = "OBJECTS!",
    objection = "OBJECTS!",
    offer = "wants to make an offer.",
    oom = "announces that they have low mana!",
    oops = "made a mistake.",
    openfire = "gives the order to open fire.",
    pack = "digs through their backpack.",
    palm = "covers their face with their palm.",
    panic = "runs around in a frenzied state of panic.",
    pat = "needs a pat.",
    peer = "peers around, searchingly.",
    peon = "grovels on the ground, wallowing in subservience.",
    pest = "shoos the measly pests away.",
    pet = "needs to be petted.",
    pinch = "pinches themself.",
    pizza = "is hungry!",
    plead = "drops to their knees and pleads in desperation.",
    ponder = "ponders the situation.",
    pounce = "pounces out from the shadows.",
    pout = "pouts at everyone around them.",
    praise = "praises the Light.",
    pray = "prays to the Gods.",
    proud = "is proud of themself.",
    pulse = "checks their own pulse.",
    punch = "punches themself.",
    purr = "purrs like a kitten.",
    puzzled = "is puzzled. What's going on here?",
    quack = "pretends to be a duck. Quack!",
    question = "wants to know the meaning of life.",
    raise = "raises their hand in the air.",
    rasp = "makes a rude gesture.",
    rawr = "roars with bestial vigor. So fierce!",
    rdy = "lets everyone know that they are ready!",
    read = "opens a map.",
    ready = "lets everyone know that they are ready!",
    rear = "shakes their rear.",
    regret = "is filled with regret.",
    retreat = "yells for everyone to flee!",
    revenge = "vows they will have their revenge.",
    rolleyes = "rolls their eyes.",
    ruffle = "ruffles their hair.",
    sad = "hangs their head dejectedly.",
    scared = "is scared!",
    scoff = "scoffs.",
    scold = "scolds themself.",
    scowl = "scowls.",
    scratch = "scratches themself. Ah, much better!",
    search = "searches for something.",
    sexy = "is too sexy for their tunic...so sexy it hurts.",
    shake = "shakes their rear.",
    shakefist = "shakes their fist.",
    shimmy = "shimmies before the masses.",
    shindig = "raises a drink in the air before chugging it down. Cheers!",
    shiver = "shivers in their boots. Chilling!",
    shoo = "shoos the measly pests away.",
    shout = "shouts.",
    shudder = "shudders.",
    shush = "tells everyone to be quiet. Shhh!",
    signal = "gives the signal.",
    silence = "tells everyone to be quiet. Shhh!",
    silly = "tells a joke.",
    sing = "bursts into song.",
    slap = "slaps themself across the face. Ouch!",
    smack = "smacks their forehead.",
    smell = "smells the air around them. Wow, someone stinks!",
    smile = "smiles.",
    snap = "snaps their fingers.",
    snarl = "bares their teeth and snarls.",
    sneak = "tries to sneak away.",
    sneeze = "sneezes. Achoo!",
    snicker = "quietly snickers to themself.",
    sniff = "sniffs the air around them.",
    snort = "snorts.",
    snub = "snubs all of the lowly peons around them.",
    soothe = "needs to be soothed.",
    spit = "spits on the ground.",
    spoon = "needs to be cuddled.",
    squeal = "squeals like a pig.",
    stand = "stands up.",
    stare = "stares off into the distance.",
    stink = "smells the air around them. Wow, someone stinks!",
    surprised = "is so surprised!",
    surrender = "surrenders to their opponents.",
    suspicious = "narrows their eyes in suspicion.",
    sweat = "is sweating.",
    talk = "talks to themself since no one else seems interested.",
    talkex = "talks excitedly with everyone.",
    talkq = "wants to know the meaning of life.",
    tap = "taps their foot. Hurry up already!",
    taunt = "taunts everyone around them. Bring it fools!",
    tease = "is such a tease.",
    think = "is lost in thought.",
    thirsty = "is so thirsty. Can anyone spare a drink?",
    threat = "threatens everyone with the wrath of doom.",
    threaten = "threatens everyone with the wrath of doom.",
    tickle = "wants to be tickled. Hee hee!",
    tired = "lets everyone know that they are tired.",
    truce = "offers a truce.",
    twiddle = "twiddles their thumbs.",
    ty = "thanks everyone around them.",
    veto = "vetoes the motion on the floor.",
    victory = "basks in the glory of victory.",
    violin = "begins to play the world's smallest violin.",
    volunteer = "raises their hand in the air.",
    wait = "asks everyone to wait.",
    warn = "warns everyone.",
    whine = "whines pathetically.",
    whistle = "lets forth a sharp whistle.",
    whoa = "is blown away.",
    wicked = "grins wickedly.",
    wickedly = "grins wickedly.",
    wince = "winces sympathetically.",
    wink = "winks slyly.",
    work = "begins to work.",
    wrath = "threatens everyone with the wrath of doom.",
    yawn = "yawns sleepily.",
    yay = "is filled with happiness!",
    yw = "was happy to help.",
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

    local description = emoteDescriptions[command]
    if not description then
        return message, false
    end

    local token = _G.hash_EmoteTokenList
        and _G.hash_EmoteTokenList["/" .. string.upper(command)]
    if not token then
        return message, false
    end

    return description, true, token, argument ~= "" and argument or nil
end

function TrialChatCommon.PerformEmote(token, target)
    if not token then return end
    C_ChatInfo.PerformEmote(token, target)
end
