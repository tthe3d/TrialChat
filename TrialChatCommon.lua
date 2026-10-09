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
    absent = "looks absent-minded.",
    accept = "accepts with an appreciative smile.",
    achieve = "achieves the perfect sitting position and refuses to risk moving.",
    act = "acts natural with the intensity of someone who has never been natural before.",
    add = "adds an unnecessary flourish to an otherwise simple gesture.",
    adjust = "fusses briefly with their clothing.",
    adjustcollar = "straightens their collar and smooths down their clothes.",
    admire = "admires their reflection in a spoon. Slightly distorted, still magnificent.",
    admit = "admits defeat to a particularly stubborn knot.",
    advise = "offers advice they have clearly never followed.",
    afford = "counts their coins and decides that window shopping builds character.",
    agree = "nods in agreement. Exactly!",
    agreeagain = "nods again, hoping the conversation ends before a question arrives.",
    aim = "aims a crumpled paper ball at a basket. Destiny awaits.",
    airguitar = "strums an invisible guitar with outrageous enthusiasm.",
    airhug = "wraps their arms around an imaginary friend.",
    airquote = "raises both hands and makes exaggerated air quotes.",
    allow = "allows themself one more snack. A generous ruler.",
    amaze = "stares in amazement, unable to believe their eyes. Wow!",
    angry = "raises their fist in anger.",
    announce = "announces that they have an announcement. Pauses for effect.",
    annoyed = "looks visibly annoyed.",
    answer = "offers an answer after a moment of thought.",
    apologize = "apologizes.",
    appear = "appears from behind a corner looking suspiciously innocent.",
    applaud = "applauds.",
    applause = "applauds.",
    apply = "applies themself to the task of looking extremely busy.",
    approach = "approaches the last pastry with the caution of a seasoned diplomat.",
    approve = "nods with approval.",
    argue = "argues their point with increasing enthusiasm.",
    arm = "stretches their arms out.",
    arrange = "arranges their belongings into a more aesthetically pleasing mess.",
    arrive = "arrives slightly late and entirely too pleased with themself.",
    ask = "asks a question with a curious tilt of their head.",
    attacktarget = "tells everyone to attack something.",
    attempt = "makes a cautious first attempt.",
    attend = "attends closely to the discussion, especially the part near the pastries.",
    avoid = "avoids eye contact with anything resembling a chore.",
    awe = "looks around in awe.",
    awkward = "looks around in a painfully awkward silence.",
    backpack = "digs through their backpack.",
    bad = "has a bad feeling about this...",
    badfeeling = "has a bad feeling about this...",
    bake = "checks on a batch of cookies with parental concern.",
    balance = "stands on one foot, trying to keep their balance.",
    bark = "barks. Woof woof!",
    base = "bases their entire strategy on a very encouraging dream.",
    bashful = "is bashful.",
    bathe = "tests the bathwater with a toe and immediately renegotiates their plans.",
    be = "exists with remarkable confidence for someone holding an upside-down map.",
    beat = "beats a tiny rhythm on the table until it becomes everybody's problem.",
    beckon = "beckons everyone over to them.",
    become = "becomes very interested in the ceiling when chores are mentioned.",
    beg = "begs everyone around them. How pathetic.",
    belch = "lets out a loud belch.",
    believe = "nods with quiet conviction.",
    belong = "settles into the best chair as though fulfilling an ancient prophecy.",
    bend = "bends down to inspect something near their feet.",
    berries = "pops a handful of sweet berries into their mouth.",
    bite = "looks around for someone to bite.",
    blame = "blames themself for what happened.",
    blank = "stares blankly at their surroundings.",
    blep = "lets the tip of their tongue peek out. Blep.",
    bless = "offers a quiet blessing.",
    blink = "blinks their eyes.",
    blow = "blows a kiss into the wind.",
    blowout = "blows out an imaginary candle and makes a wish for real cake.",
    blush = "blushes.",
    boggle = "boggles at the situation.",
    boil = "watches a pot with the intensity of someone who has heard none of the sayings.",
    bonk = "bonks someone on the noggin. Doh!",
    boo = "boos loudly. Booo!",
    boop = "boops someones nose. Boop!",
    boopair = "boops an imaginary nose. Boop!",
    bored = "is overcome with boredom. Oh the drudgery!",
    borrow = "gestures politely, hoping to borrow a spare pen.",
    bother = "pokes at a loose thread until it becomes an entirely new problem.",
    bounce = "bounces up and down.",
    bow = "bows deeply with a graceful flourish.",
    brandish = "brandishes their weapon fiercely.",
    bravo = "applauds.",
    brb = "lets everyone know they'll be right back.",
    bread = "takes a hearty bite of bread.",
    ["break"] = "snaps a dry twig between their fingers.",
    breakaway = "escapes the conversation with a graceful sideways shuffle.",
    breakdown = "attempts to explain a simple plan until it requires several diagrams.",
    breakfast = "takes a hearty bite of bread.",
    breakout = "breaks into an impromptu victory dance for reasons not yet disclosed.",
    breath = "takes a deep breath.",
    breathe = "takes a slow breath in, then lets it out.",
    breathless = "struggles to catch their breath.",
    bring = "brings over a spare cushion and sets it down.",
    brow = "raises their eyebrow inquisitively.",
    brush = "brushes a few stray hairs away from their face.",
    build = "stacks a few loose stones into a tiny tower.",
    bump = "bumps into a chair and apologizes to it automatically.",
    burn = "touches a hot cup, withdraws their hand, and gives the cup a betrayed look.",
    burp = "lets out a loud belch.",
    burst = "bursts into the room with news that could easily have waited.",
    buy = "examines their coins, then settles for admiring the merchandise.",
    bye = "waves goodbye.",
    cackle = "cackles maniacally at the situation.",
    calculate = "counts on their fingers and looks offended when the numbers disagree.",
    call = "calls for backup. Preferably someone carrying sandwiches.",
    calm = "remains calm.",
    calmdown = "takes three calming breaths and a precautionary bite of biscuit.",
    care = "carefully tucks a blanket around a suspiciously sleepy bundle.",
    carry = "hoists a bundle into their arms and carries it carefully.",
    carryon = "resumes their task as though the small disaster never happened.",
    cat = "scratches themself. Ah, much better!",
    catch = "catches a falling trinket just in time. Phew!",
    catty = "scratches themself. Ah, much better!",
    cause = "causes a minor disturbance by dropping every coin at once.",
    celebrate = "celebrates with joy, Yuppie!",
    challenge = "puts out a challenge to everyone. Bring it on!",
    change = "changes their mind halfway through an enthusiastic nod.",
    charge = "starts to charge.",
    chargeahead = "charges ahead with a plan that has not survived its first question.",
    chargeup = "takes a deep breath and prepares for the heroic task of standing up.",
    charm = "puts on the charm.",
    chase = "chases a rolling coin with rapidly diminishing dignity.",
    cheat = "sneaks a look at their own notes, then acts as though they discovered fire.",
    check = "checks everything once more, just to be sure.",
    checkpockets = "pats down their pockets, searching for something.",
    cheer = "cheers!",
    cheers = "lifts their drink with a bright grin. Cheers!",
    cheerup = "offers a crooked smile and a biscuit of questionable structural integrity.",
    chew = "begins to eat.",
    chewslowly = "chews very slowly to make the last bite last an entire chapter.",
    chicken = "struts around with arms flapping. Cluck, cluck, chicken!",
    chocolate = "savours a piece of chocolate with a contented sigh.",
    choke = "chokes and struggles to catch their breath.",
    choose = "weighs the options, then points out their choice.",
    chortle = "lets out a warm, amused chortle.",
    chuckle = "chuckles.",
    chug = "takes a mighty quaff of their beverage.",
    cigarette = "takes a slow drag from their cigarette, then exhales a thin stream of smoke.",
    claim = "claims the best seat using the ancient law of putting a coat on it.",
    clap = "claps.",
    clean = "cleans a stubborn mark from their sleeve.",
    cleanup = "clears the table by eating the remaining snacks. Efficient.",
    clear = "clears a space on the table by moving the mess slightly to the left.",
    climb = "searches for a foothold and begins to climb.",
    climbrope = "pretends to climb an invisible rope, one hand at a time.",
    cloak = "sweeps their cloak over one shoulder with dramatic flair.",
    close = "closes their journal with a soft thump.",
    cloudwatch = "leans back and watches the clouds drift by.",
    coinflip = "tosses a coin into the air and catches it without looking.",
    cold = "lets everyone know that they are cold.",
    collapse = "slumps to the ground in a heap.",
    collect = "gathers a few scattered belongings into a neat pile.",
    combhair = "carefully combs their hair into place.",
    comealong = "gestures for company on a grand expedition to the next room.",
    comeback = "returns for something they forgot. Mostly the opportunity to say goodbye again.",
    comein = "peeks in before entering, checking for both welcome and refreshments.",
    comeout = "emerges from behind a curtain with a mysterious amount of dust.",
    comeover = "wanders closer, drawn by either good company or the smell of food.",
    comfort = "comforts the situation.",
    commend = "commends everyone on a job well done.",
    compare = "compares two biscuits as though choosing an heir to the throne.",
    complain = "complains about the lack of snacks while actively eating one.",
    complete = "completes a simple task and waits for the fanfare.",
    concentrate = "concentrates so hard that their tongue pokes out a little.",
    confess = "confesses to the missing biscuit with crumbs still on their shirt.",
    confirm = "confirms the plan with a nod that suggests they missed half of it.",
    confuse = "gets tangled in their own explanation and quietly starts again.",
    confused = "looks confused.",
    congrats = "congratulates everyone nearby.",
    congratulate = "congratulates everyone around them.",
    conjurespark = "coaxes a tiny spark of magic to life between their fingers.",
    connect = "connects two unrelated ideas with tremendous enthusiasm.",
    consider = "considers every option, then selects the one closest to the kitchen.",
    contain = "barely contains their excitement at the sight of fresh bread.",
    contemplate = "falls silent in deep contemplation.",
    continue = "continues talking despite having lost the point several sentences ago.",
    control = "tries to control their expression. Their eyebrows revolt.",
    convince = "makes a persuasive case for calling a nap 'strategic recovery.'",
    cook = "stirs a little pot, checking the aroma.",
    cooldown = "fans themself with a piece of paper that was probably important.",
    copy = "copies a confident pose without knowing what it means.",
    correct = "corrects a tiny detail with the satisfaction of a dragon guarding treasure.",
    cough = "lets out a hacking cough.",
    count = "counts their fingers, then checks again. All accounted for.",
    countcoins = "counts their coins with great concentration.",
    cover = "covers a yawn with a cough. The disguise fools nobody.",
    coverears = "covers their ears.",
    coverup = "covers a fresh ink stain with a much larger piece of paper.",
    cower = "cowers in fear.",
    cozy = "wraps themself in a blanket and settles in comfortably.",
    crabdance = "scuttles sideways in a playful crab dance.",
    crack = "cracks their knuckles.",
    crackknuckles = "cracks their knuckles one by one.",
    crash = "bumps into a pile of cushions and accepts this as their destination.",
    crawl = "gets down on their hands and knees and crawls forward.",
    crazydance = "flails their limbs in a gloriously ridiculous dance.",
    create = "creates a tiny mountain of crumbs and names it after themself.",
    crickets = "pauses for a response. Only imaginary crickets answer.",
    cringe = "cringes in fear.",
    criticize = "examines a crooked stack of books with the severity of an art critic.",
    cross = "crosses the room with purpose, then forgets the purpose.",
    crossarms = "crosses their arms.",
    crouch = "crouches low to the ground.",
    cry = "bursts into tears and tries to wipe them away.",
    cuddle = "needs to be cuddled.",
    curious = "expresses their curiosity to those around them.",
    curtaincall = "takes a sweeping bow before an imaginary audience.",
    curtsey = "curtseys.",
    cut = "carefully cuts a length of string.",
    cycle = "pedals their feet in the air. Destination: absolutely nowhere.",
    dance = "bursts into dance.",
    dancedrunk = "dances with a drunken wobble.",
    dare = "eyes a suspiciously spicy pepper with misplaced courage.",
    deadpan = "stares ahead with an utterly unreadable expression.",
    deal = "deals imaginary cards with the confidence of a professional cheat.",
    deathgasp = "lets out a dramatic final gasp and goes still.",
    decide = "makes up their mind with a firm nod.",
    deliver = "delivers a folded note as though the fate of the world were inside.",
    demand = "demands an explanation from an empty cookie jar.",
    deny = "denies everything before anyone has asked a question.",
    depend = "leans on a chair that seems less dependable than anticipated.",
    describe = "describes a scene in vivid detail.",
    deserve = "looks at the dessert and silently concludes that they have earned this.",
    design = "sketches a chair with a built-in snack drawer. Visionary.",
    destroy = "crushes a fragile paper hat by accidentally sitting on it.",
    dig = "digs a shallow hole in the earth.",
    ding = "reached a new level. DING!",
    disagree = "shakes their head in disagreement. Not a chance!",
    disappear = "slips behind a curtain. Their feet remain very visible.",
    disappointed = "frowns.",
    disapprove = "shakes their head in disapproval.",
    discover = "discovers a spare sweet in their pocket. The expedition is a success.",
    discuss = "opens a thoughtful discussion.",
    disgust = "recoils in disgust.",
    dismiss = "waves a hand dismissively.",
    dive = "dives into a pile of pillows with absolutely no tactical purpose.",
    ["do"] = "does a little something. Declines to elaborate.",
    doh = "bonks someone on the noggin. Doh!",
    doom = "threatens everyone with the wrath of doom.",
    doubt = "doubts the situation.",
    doze = "nods off, then catches themself with a sleepy blink.",
    drag = "drags a chair closer to the food with painful subtlety.",
    dramaticentrance = "makes an entrance as though the whole room were waiting.",
    draw = "draws a little doodle in the margin of their notes.",
    dream = "daydreams about a world where every quest ends with free dessert.",
    dress = "straightens their outfit and adopts an expression of expensive importance.",
    driftoff = "drifts toward sleep with the determination of a very small boat.",
    drink = "raises a drink in the air before chugging it down. Cheers!",
    drinkgreentea = "takes a calming sip of green tea.",
    drinkup = "drains their cup and tips it hopefully to check for hidden reserves.",
    drive = "pretends to steer an invisible carriage through imaginary traffic.",
    drop = "drops a small trinket and stoops to retrieve it.",
    drum = "beats out a rhythm on a drum.",
    drunk = "sways drunkenly on their feet.",
    dry = "dries their hands on a cloth that is somehow wetter than their hands.",
    duck = "ducks for cover.",
    dustoff = "dusts off their clothes.",
    earn = "earns themself a break by thinking very hard about starting work.",
    eat = "begins to eat.",
    eatup = "finishes every crumb and looks ready to compliment the plate.",
    embarrass = "flushes with embarrassment.",
    encounter = "meets an unexpected cobweb face-first and performs an unscheduled dance.",
    encourage = "encourages everyone around them.",
    ["end"] = "ends their speech with a flourish that outshines the entire speech.",
    enemy = "warns everyone that an enemy is near.",
    enjoy = "savours a quiet moment until their own stomach interrupts it.",
    enter = "enters with a grand flourish, then checks whether this is the right room.",
    escape = "edges toward the doorway when someone mentions a group activity.",
    establish = "establishes a small kingdom on the comfiest chair.",
    estimate = "holds up two fingers, then three. Somewhere in that general direction.",
    evilgrin = "grins with suspiciously villainous satisfaction.",
    examine = "examines an ordinary spoon as though it holds ancient secrets.",
    exasperated = "throws up their hands in exasperation.",
    exchange = "swaps one uncomfortable sitting position for a different uncomfortable one.",
    excited = "bounces with excitement, barely able to stand still!",
    excuse = "gestures apologetically and slips away in the direction of refreshments.",
    exercise = "does one enthusiastic squat and checks whether that counts.",
    exist = "exists peacefully until someone says there is work to do.",
    expand = "spreads their belongings across the table with quiet imperial ambition.",
    expect = "waits with an expectant look.",
    expectmore = "looks at the tiny portion, then at the enormous potential for more.",
    experience = "experiences a brief crisis upon discovering that the teapot is empty.",
    experiment = "mixes two snacks and watches the result with scientific concern.",
    explain = "explains their reasoning with patient gestures.",
    explore = "investigates a cupboard with the spirit of a great explorer.",
    express = "expresses an entire opinion with a single exhausted blink.",
    eye = "crosses their eyes.",
    eyebrow = "raises their eyebrow inquisitively.",
    eyeroll = "rolls their eyes.",
    face = "faces the situation bravely, after checking for an easier exit.",
    facepalm = "covers their face with their palm.",
    faceplant = "stumbles forward and lands face-first. Oof.",
    fail = "fails to catch a tossed grape, then pretends it was a trick shot.",
    faint = "sways for a moment, then faints dramatically.",
    fall = "falls backward into a conveniently placed cushion. Calculated.",
    farewell = "waves goodbye.",
    fart = "farts loudly. Whew...what stinks?",
    fear = "cowers in fear.",
    feast = "begins to eat.",
    feed = "offers a crumb to a tiny imaginary dragon.",
    feel = "feels ready for adventure, provided adventure includes lunch.",
    fetch = "returns with a spoon when a fork was clearly the objective.",
    fidget = "fidgets.",
    fill = "fills their cup nearly to the brim and instantly regrets the journey ahead.",
    find = "finds a forgotten biscuit and immediately believes in miracles.",
    fingerheart = "forms a tiny heart with their fingers.",
    finish = "finishes their snack and stares at the plate in quiet betrayal.",
    fist = "shakes their fist.",
    fistbump = "holds out a fist, waiting for a friendly bump.",
    fistpump = "pumps their fist triumphantly.",
    fit = "squeezes into a narrow gap with an expression of growing negotiation.",
    fix = "fiddles with a loose buckle until it sits properly.",
    flap = "struts around with arms flapping. Cluck, cluck, chicken!",
    flee = "yells for everyone to flee!",
    flex = "flexes their muscles. Oooooh so strong!",
    flinch = "flinches and pulls back instinctively.",
    flipout = "flails their arms and completely loses their composure.",
    flirt = "gives a playful wink and a charming smile.",
    float = "lies back on a cushion and pretends to drift across a peaceful lake.",
    flop = "flops about helplessly.",
    flow = "lets a ribbon slip through their fingers with theatrical grace.",
    flustered = "fumbles for words, visibly flustered.",
    flute = "plays a gentle tune on a flute.",
    fly = "spreads their arms like wings. Takeoff remains an administrative challenge.",
    focus = "blocks out distractions and concentrates intently.",
    fold = "folds a small piece of paper with careful precision.",
    follow = "falls into step behind the others.",
    followme = "motions for everyone to follow.",
    food = "is hungry!",
    force = "tries to force a lid shut on a bag that clearly has other ambitions.",
    forget = "pauses mid-thought, having completely forgotten the point.",
    forgive = "lets go of a grievance with a softened expression.",
    form = "forms a committee of one and immediately requests a break.",
    forthealliance = "cheers for the Alliance!",
    forthehorde = "cheers for the Horde!",
    frame = "frames their face with their hands. A masterpiece, according to its creator.",
    freeze = "freezes mid-bite upon realizing there was a question.",
    frighten = "jumps out with a mighty 'Boo!' and startles themself.",
    frown = "frowns deeply, clearly unhappy with the situation.",
    fry = "tends a sizzling pan with the concentration of a battlefield commander.",
    gargle = "gargles noisily.",
    gasp = "gasps in surprise and covers their mouth.",
    gather = "gathers loose crumbs into a pile. Every kingdom starts somewhere.",
    gaze = "gazes off into the distance.",
    generate = "comes up with three new ideas and forgets the first two immediately.",
    gesticulate = "gestures animatedly while making a point.",
    get = "gets the idea about three conversations too late.",
    getalong = "offers a peaceable smile. Surely everyone can agree about cake.",
    getback = "returns to their seat before anyone can steal its carefully stored warmth.",
    getby = "makes do with a bent spoon and an optimistic attitude.",
    getdown = "ducks low, then checks whether there was actually a reason to duck.",
    getin = "squeezes into a cosy corner and looks pleased with the discovery.",
    getout = "edges away with the expression of someone escaping a very long story.",
    getover = "takes a deep breath and attempts to recover from a deeply mediocre lunch.",
    getready = "rolls up their sleeves for something that definitely does not require it.",
    getthrough = "pushes through a tedious task, powered entirely by the promise of pie.",
    getup = "gets to their feet with the sound of a much older adventurer.",
    giggle = "giggles.",
    give = "holds out a small gift with a warm smile.",
    giveaway = "offers a spare sweet with suspiciously saintly generosity.",
    giveback = "returns a borrowed pen with the ceremony of handing over a sacred sword.",
    givein = "finally gives in to the irresistible demands of a comfortable chair.",
    giveout = "hands out imaginary medals for surviving the conversation.",
    giveup = "throws their hands up and grants the tangled necklace its freedom.",
    glad = "is filled with happiness!",
    glance = "steals a quick glance at the dessert before returning to fake seriousness.",
    glare = "glares angrily, narrowing their eyes. Someone is in trouble.",
    glassbox = "feels around the walls of an imaginary glass box.",
    glasswall = "presses their palms against an invisible wall.",
    gloat = "gloats over everyone's misfortune.",
    glower = "glowers at everyone around them.",
    go = "tells everyone to go.",
    goblinbow = "performs an awkward goblin-style bow.",
    goblinsalute = "attempts a decidedly goblin-like salute.",
    going = "must be going.",
    golfclap = "claps half-heartedly, clearly unimpressed.",
    goodbye = "waves goodbye.",
    grab = "grabs at something just out of reach.",
    grats = "congratulates everyone nearby.",
    greet = "greets everyone warmly.",
    greetings = "greets everyone warmly.",
    grimace = "pulls a face in discomfort.",
    grin = "grins wickedly.",
    grip = "grips their cup with both hands. Emotional support beverage.",
    groan = "groans.",
    grovel = "grovels on the ground, wallowing in subservience.",
    grow = "grows increasingly suspicious of an empty plate.",
    growl = "lets out a low, threatening growl. Grrrr!",
    grumble = "grumbles under their breath.",
    grump = "looks thoroughly grumpy.",
    guard = "stands watch over the snacks with unwavering professional commitment.",
    guess = "ventures a guess with an uncertain expression.",
    guffaw = "lets out a boisterous guffaw!",
    guide = "gestures confidently toward a direction they have only just selected.",
    gurgle = "makes a low gurgling sound.",
    hail = "hails those around them.",
    hairflip = "flips their hair with effortless confidence.",
    handle = "handles a delicate cup with exaggerated, trembling care.",
    handpuppet = "makes a puppet with their hand and gives it a ridiculous voice.",
    handsonhips = "plants their hands on their hips.",
    handtoheart = "rests a hand over their heart.",
    hang = "hangs their coat on a hook and misses on the first attempt.",
    happen = "looks around as though hoping an explanation will happen to them.",
    happy = "is filled with happiness!",
    harm = "accidentally bends a paper flower and gives it a sincere apology.",
    have = "has a very important question. It is about snacks.",
    headache = "is getting a headache.",
    headbang = "bangs their head to an imaginary beat.",
    headpat = "gently pats someone's head. There, there. OwO.",
    headscratch = "scratches their head in puzzlement.",
    headtilt = "tilts their head with gentle curiosity.",
    heal = "presses a cool cloth to their forehead and requests medicinal pudding.",
    healme = "calls out for healing!",
    hear = "hears the word 'food' from an unreasonable distance.",
    heart = "shapes their hands into a heart.",
    heartbroken = "looks utterly heartbroken.",
    hello = "greets everyone with a hearty hello!",
    help = "steps forward, ready to lend a hand.",
    helpme = "cries out for help!",
    heroic = "stands tall in a heroic pose.",
    hi = "greets everyone with a hearty hello!",
    hiccup = "hiccups loudly.",
    hide = "hides behind their hands. An impenetrable fortress.",
    highfive = "puts up their hand for a high five.",
    hire = "interviews an imaginary assistant for the position of biscuit carrier.",
    hiss = "hisses at everyone around them.",
    hit = "hits the table for emphasis, then quietly rubs their hand.",
    hold = "holds on firmly, refusing to let go.",
    holdhand = "wishes someone would hold their hand.",
    holdit = "OBJECTS!",
    holler = "shouts.",
    hope = "clasps their hands and hopes for the best.",
    hug = "gives a hug.",
    hungry = "is hungry!",
    hurry = "tries to pick up the pace.",
    huzzah = "cheers boisterously! Huzzah!",
    idea = "has an idea!",
    identify = "identifies the source of the problem. It appears to be themself.",
    ignore = "ignores a problem so deliberately that it becomes a second activity.",
    imagine = "imagines a magnificent feast and begins smiling at an empty plate.",
    impatient = "fidgets.",
    impress = "attempts to impress the room by catching a sweet in their mouth. Almost.",
    impressed = "claps vigorously, clearly impressed.",
    improve = "improves the atmosphere by quietly opening a bag of sweets.",
    inc = "warns everyone of incoming enemies!",
    include = "includes an extra biscuit in their very serious travel plans.",
    incoming = "warns everyone of incoming enemies!",
    increase = "increases their personal space by deploying both elbows.",
    inform = "informs everyone that the situation would improve with tea.",
    insist = "makes their point with firm conviction.",
    insult = "thinks everyone around them is a son of a motherless ogre.",
    intend = "looks fully prepared to do something very soon. Probably.",
    interrupt = "raises a finger to politely interrupt.",
    introduce = "introduces themself to everyone.",
    invent = "folds a napkin into a hat and briefly considers a career in engineering.",
    invite = "gestures toward an empty seat with the air of a generous monarch.",
    involve = "draws everyone nearby into a debate about the correct size of a sandwich.",
    jealous = "is jealous of everyone around them.",
    jig = "dances a lively little jig.",
    jk = "was just kidding!",
    jog = "jogs on the spot to warm up.",
    join = "joins the discussion exactly when refreshments are mentioned.",
    judge = "judges a tiny pastry on presentation, aroma, and willingness to be eaten.",
    juggleflame = "juggles flickering flames with a steady hand.",
    jump = "jumps up with a burst of energy.",
    jumpforjoy = "jumps into the air with delight!",
    jumpingjacks = "starts doing jumping jacks.",
    justify = "explains why a second lunch is technically a late first lunch.",
    kawaiipose = "strikes an adorably dramatic pose. Ta-da!",
    keep = "tucks a small keepsake safely away.",
    kick = "gives a loose pebble a little kick and follows it with unnecessary interest.",
    kiss = "blows a kiss.",
    kneel = "kneels down.",
    knit = "works a pair of needles while the yarn develops its own agenda.",
    knock = "knocks politely on a surface that is very obviously not a door.",
    know = "gives a knowing look. Oh, they know.",
    knuckles = "cracks their knuckles.",
    kowtow = "kneels and bows their head to the ground.",
    label = "labels a small pouch 'Important' and fills it with sweets.",
    land = "lands after a tiny hop and checks whether anyone witnessed their athleticism.",
    last = "holds a dramatic pose for exactly as long as their knee permits.",
    laugh = "laughs.",
    launch = "launches a paper bird and watches it immediately surrender to gravity.",
    lavish = "praises the Light.",
    lay = "lies down.",
    laydown = "lies down.",
    lead = "leads the way, consulting a map that is clearly upside down.",
    lean = "leans back comfortably.",
    learn = "listens closely, eager to learn something new.",
    leave = "takes their leave with a final glance back.",
    lend = "offers to lend a useful little tool.",
    let = "lets out the breath they were holding for absolutely no reason.",
    lick = "licks their lips.",
    lie = "lies down.",
    liearound = "sprawls comfortably, conducting important research into doing nothing.",
    lieawake = "stares upward, kept awake by a conversation from several years ago.",
    lieback = "reclines as though every cushion in the room were personally theirs.",
    liedown = "lies down.",
    lieflat = "lies completely flat and briefly identifies as a rug.",
    lift = "lifts a heavy bundle with a small grunt.",
    limberup = "loosens their shoulder with a few circles of their arm.",
    limit = "sets a sensible limit of one more snack. The limit is renewable.",
    link = "links two paper loops together and admires the start of an empire.",
    listen = "is listening!",
    load = "loads their arms with more books than their balance recommends.",
    lock = "locks an imaginary vault around their last piece of chocolate.",
    lol = "laughs.",
    long = "looks wistfully into the distance, where lunch might be happening.",
    look = "looks around.",
    lookafter = "keeps a protective eye on a tiny potted plant. Small friend, big responsibilities.",
    lookaround = "surveys the room for danger, exits, and the nearest comfortable chair.",
    lookaway = "looks away from the sweets with heroic but temporary resolve.",
    lookback = "glances back to make sure their dramatic departure was appreciated.",
    lookdown = "looks down and discovers that their feet have been here all along.",
    lookforward = "waits for dinner with the optimism usually reserved for great prophecies.",
    lookinto = "peers into a bag as though it might contain a smaller, better-organized universe.",
    lookout = "peers around a corner with one eye and far too much visible hat.",
    lookover = "looks over a note and nods as if the handwriting is remotely readable.",
    lookup = "looks up hopefully. Perhaps snacks fall from the sky here.",
    lose = "loses their train of thought somewhere near the dining car.",
    lost = "is hopelessly lost.",
    love = "feels the love.",
    lower = "lowers their voice for a secret that turns out to be a soup recipe.",
    luck = "wishes everyone good luck.",
    lute = "strums a melody on a lute.",
    mad = "raises their fist in anger.",
    magicjuggle = "keeps glowing sparks dancing between their hands.",
    magictrick = "reveals a little sleight of hand. Ta-da!",
    magnificent = "nods approvingly. Magnificent job!",
    maintain = "maintains eye contact with the last slice of pie.",
    make = "makes a tiny crown out of paper and accepts their promotion.",
    manage = "manages to look occupied while accomplishing absolutely nothing.",
    map = "pulls out their map.",
    mark = "marks their place in a book with a crumb, then reconsiders.",
    massage = "needs a massage!",
    matter = "looks determined to make this small inconvenience everybody's concern.",
    mean = "means well. The overturned bucket suggests otherwise.",
    measure = "measures a gap with their hands and declares it approximately 'that big.'",
    meditate = "closes their eyes and settles into quiet meditation.",
    meet = "greets the room with the confidence of someone at the wrong party.",
    melt = "sinks into a soft chair until becoming mostly blanket.",
    mention = "casually mentions dessert for the fourth time.",
    meow = "meows.",
    mercy = "pleads for mercy.",
    messup = "makes a small mistake and pauses to decide whether anyone noticed.",
    micdrop = "drops an imaginary microphone and steps back.",
    mind = "politely minds their own business with one extremely attentive ear.",
    miss = "misses a tossed snack and looks accusingly at the laws of physics.",
    mix = "mixes a drink with the reckless confidence of someone skipping the recipe.",
    mlem = "licks their lips with a tiny mlem.",
    moan = "moans suggestively.",
    mock = "mocks life and all it stands for.",
    model = "models a borrowed scarf as though walking before royalty.",
    monologue = "launches into a long, theatrical monologue.",
    moon = "drops their trousers and moons everyone.",
    move = "shifts a little to make room.",
    mumble = "mumbles something barely audible.",
    murder = "gives the offending alarm clock a look of deeply theatrical menace.",
    mushroom = "sprouts into a giant mushroom and hides under its cap.",
    mutter = "mutters angrily to themself. Hmmmph!",
    name = "names a small stone and immediately becomes emotionally attached.",
    nap = "curls up for a quick little nap.",
    need = "needs a nap, a snack, and significantly fewer responsibilities.",
    nervous = "looks around nervously.",
    nibble = "takes a tiny, thoughtful nibble of a snack.",
    no = "shakes their head.",
    nod = "nods.",
    nodoff = "nods off halfway through looking interested.",
    noodle = "slurps a long noodle, then another. Where does this thing end?!",
    notice = "spots a small detail and pauses to inspect it.",
    nudge = "gives someone a gentle nudge to get their attention.",
    nuzzle = "offers someone a soft little nuzzle. UwU.",
    obey = "follows instructions with such literal precision that it becomes suspicious.",
    object = "OBJECTS!",
    objection = "OBJECTS!",
    observe = "studies their surroundings without saying a word.",
    occur = "lights up as a thought finally occurs to them. It is about cheese.",
    offer = "wants to make an offer.",
    oom = "announces that they have low mana!",
    oops = "made a mistake.",
    open = "opens a small pouch and peers inside.",
    openfire = "gives the order to open fire.",
    operate = "operates a stubborn pepper grinder like unfamiliar siege machinery.",
    order = "orders their thoughts into a line. One wanders off.",
    organize = "sorts their clutter into categories of urgent, important, and shiny.",
    owo = "perks up with wide-eyed curiosity. OwO.",
    pack = "digs through their backpack.",
    paint = "adds a careful dab of colour to a small sketch.",
    pale = "turns noticeably pale.",
    palm = "covers their face with their palm.",
    panic = "runs around in a frenzied state of panic.",
    paper = "holds out a flat hand. Paper!",
    participate = "contributes an enthusiastic nod to an activity they barely understand.",
    party = "starts dancing and cheering. Party time! Someone bring the snacks!",
    pass = "passes a snack from one hand to the other. Excellent teamwork.",
    pat = "gently pats someone, OwO.",
    pause = "pauses for dramatic effect and forgets what comes next.",
    pay = "pays close attention to everything except the explanation.",
    peace = "raises two fingers in a cheerful peace sign.",
    peekaboo = "covers their face, then peeks out. Peekaboo!",
    peel = "peels a piece of fruit with far more ceremony than necessary.",
    peer = "peers around, searchingly.",
    peon = "grovels on the ground, wallowing in subservience.",
    perform = "performs a tiny bow for a task of absolutely no significance.",
    permit = "grants themself permission to sit down. Request unanimously approved.",
    persuade = "tries to persuade an overstuffed bag to close through kind words.",
    pest = "shoos the measly pests away.",
    pet = "pets someone, OwO",
    petalthrow = "scatters a handful of flower petals into the air.",
    phew = "breathes out in relief. Phew!",
    pickapart = "picks apart an argument until only crumbs of logic remain.",
    pickat = "picks at a loose thread and looks increasingly concerned about its length.",
    pickout = "selects a particularly handsome potato and admires its character.",
    pickthrough = "rummages through a bag and finds everything except the intended object.",
    pickup = "picks up a dropped coin and briefly checks for witnesses to the struggle.",
    pinch = "pinches themself.",
    pity = "looks at everyone with pity.",
    pizza = "is drooling about the thought of pizza. Waaa.",
    place = "places a single sweet in the centre of the table. Negotiations begin.",
    plan = "sketches out a rough plan on a scrap of paper.",
    plant = "places a seed in the soil and gently covers it.",
    play = "plays a tiny drum solo on their knees. The encore is unavoidable.",
    playdead = "falls to the ground and pretends to be dead.",
    plead = "drops to their knees and pleads in desperation.",
    plot = "rubs their hands together, clearly plotting something.",
    poggers = "celebrates with joy, Yuppie!",
    point = "points into the distance, trying to draw attention to something.",
    pointout = "points out the obvious with the satisfaction of a great discovery.",
    poke = "pokes.... somebody.",
    polish = "polishes their gear until it gleams.",
    ponder = "ponders the situation.",
    pounce = "pounces out from the shadows.",
    pour = "pours a drink with the concentration usually reserved for dangerous magic.",
    pourtea = "carefully pours a steaming cup of tea.",
    pout = "pouts at everyone around them.",
    practice = "repeats a simple movement, trying to get it just right.",
    praise = "praises the Light.",
    pray = "prays to the Gods.",
    prefer = "indicates their preference with a small, certain nod.",
    prepare = "checks their belongings and gets ready.",
    press = "presses their lips together to keep a laugh from escaping.",
    prevent = "catches a wobbling cup and looks ready to accept a medal.",
    print = "stamps an inked thumb onto a scrap of paper. Official business.",
    produce = "produces a spoon from a pocket with suspicious confidence.",
    protect = "shields their last biscuit with both hands. Precious cargo.",
    proud = "is proud of themself.",
    prove = "demonstrates their point using three spoons and questionable logic.",
    provide = "provides a helpful nod and no additional information.",
    publish = "holds up a freshly written note and waits for the reviews.",
    pull = "leans back and gives a stubborn rope a firm pull.",
    pulse = "checks their own pulse.",
    punch = "punches themself.",
    puppyeyes = "makes the most irresistible puppy eyes they can manage.",
    purr = "purrs like a kitten.",
    push = "leans forward and pushes with all their strength.",
    pushup = "drops to the ground and starts doing push-ups.",
    put = "puts a pebble on the table as their contribution to the discussion.",
    putaway = "puts their belongings away, then immediately needs the thing at the bottom.",
    putback = "returns a sweet to the bowl after a lengthy internal negotiation.",
    putdown = "sets down a heavy bag and briefly considers never lifting it again.",
    putoff = "postpones a chore with the confidence of someone inventing tomorrow.",
    puton = "puts on an imaginary crown and immediately develops opinions about taxes.",
    putup = "holds up a handwritten sign requesting more comfortable adventures.",
    puzzled = "is puzzled. What's going on here?",
    quack = "pretends to be a duck. Quack!",
    question = "wants to know the meaning of life.",
    quiver = "quivers nervously, struggling to stay still.",
    rabbithop = "hops around like a cheerful little rabbit.",
    rage = "seethes with barely contained fury.",
    raise = "raises their hand in the air.",
    raisealarm = "raises the alarm about an unattended plate of pastries.",
    raisebrow = "raises an eyebrow so slowly it becomes a separate event.",
    raiseglass = "raises a glass to surviving another perfectly ordinary afternoon.",
    raisehand = "raises a hand, waiting to be noticed.",
    raisehopes = "looks hopeful at the sound of a lid opening somewhere nearby.",
    raisevoice = "raises their voice just enough to compete with their own stomach.",
    rasp = "makes a rude gesture.",
    raspberry = "sticks out their tongue and blows a raspberry. Pbbbt!",
    rawr = "roars with bestial vigor. So fierce!",
    rdy = "lets everyone know that they are ready!",
    reach = "reaches out, stretching their fingers.",
    reachout = "extends a hand toward the snacks with diplomatic caution.",
    react = "reacts a full second after everyone else and commits to it anyway.",
    read = "begins reading.",
    ready = "lets everyone know that they are ready!",
    realize = "suddenly puts the pieces together. Oh!",
    rear = "shakes their rear.",
    receive = "receives an imaginary award for outstanding snack awareness.",
    record = "writes down an important observation: more snacks needed.",
    recover = "steadies themself and regains their composure.",
    reduce = "reduces the biscuit supply by one. A valuable contribution.",
    reflect = "shuts their eyes for a moment of quiet reflection.",
    reflectlight = "angles a shiny spoon to send a tiny patch of light dancing around.",
    refuse = "firmly shakes their head in refusal.",
    regret = "is filled with regret.",
    relax = "loosens their shoulders and finally relaxes.",
    release = "releases a long sigh and several unrealistic expectations.",
    remain = "remains perfectly still, hoping responsibility hunts by movement.",
    remaincalm = "maintains a calm expression while internally rearranging the furniture.",
    remember = "smiles as an old memory comes back to them.",
    remind = "ties a string around their finger and immediately forgets what it means.",
    remove = "removes an imaginary speck of dust from their shoulder. Standards matter.",
    repair = "mends a small tear with a few careful stitches.",
    ["repeat"] = "repeats themself, a little more slowly this time.",
    replace = "replaces an empty cup with a full one. Personal growth.",
    reply = "replies with a few carefully chosen words.",
    report = "delivers a detailed report on the alarming shortage of biscuits.",
    represent = "stands proudly on behalf of everyone who would rather be napping.",
    request = "submits a very earnest request for five more minutes.",
    require = "requires a moment of silence for the last bite of cake.",
    research = "studies the menu as though preparing a groundbreaking thesis.",
    reserve = "reserves an empty chair for their imaginary but very tired friend.",
    resist = "resists the temptation to nap with rapidly declining success.",
    respond = "responds with a noise that is technically almost a word.",
    respondlate = "finally thinks of a clever response to yesterday's conversation.",
    rest = "settles down for a well-earned rest.",
    retch = "doubles over and retches.",
    retire = "announces their retirement from standing and takes a seat.",
    retreat = "yells for everyone to flee!",
    ["return"] = "returns with a familiar smile.",
    reveal = "opens their hands to reveal a tiny pebble. Behold!",
    revenge = "vows they will have their revenge.",
    review = "reviews their plan and quietly removes the part involving actual effort.",
    ride = "bounces on a chair as though riding a heroic, extremely stationary horse.",
    ring = "rings an imaginary dinner bell and looks disappointed by the response.",
    risk = "takes a chance on a suspicious-looking sweet. Brave little fool.",
    roar = "throws their head back and lets out a mighty roar. Raaawr!",
    rockout = "headbangs to an imaginary roaring guitar.",
    rofl = "rolls on the floor laughing.",
    roll = "rolls a coin across their knuckles and drops it on the second knuckle.",
    rolleyes = "rolls their eyes.",
    rub = "rubs their tired eyes.",
    rubhands = "rubs their hands together eagerly.",
    rude = "makes a rude gesture.",
    ruffle = "ruffles their hair.",
    run = "breaks into a quick run.",
    rush = "hurries three steps, then remembers they have nowhere urgent to be.",
    sad = "hangs their head dejectedly.",
    salute = "stands up straight and gives a proud salute.",
    satisfy = "settles back after a snack with the expression of a completed prophecy.",
    save = "sets aside the last biscuit for later.",
    say = "says something profound, then ruins it with a hiccup.",
    scare = "makes a spooky face that is mostly eyebrows.",
    scared = "is scared!",
    scissors = "extends two fingers. Scissors!",
    scoff = "scoffs.",
    scold = "scolds themself.",
    score = "flicks a crumb into an empty cup and celebrates like a champion.",
    scowl = "scowls.",
    scratch = "scratches themself. Ah, much better!",
    scratchout = "crosses out a bad idea so thoroughly that the paper takes offence.",
    scream = "lets out a piercing scream!",
    search = "searches for something.",
    see = "sees the problem. Briefly considers pretending otherwise.",
    seek = "seeks wisdom in the bottom of their cup. Finds tea leaves.",
    seem = "seems to have a plan. This is mostly a facial expression.",
    select = "chooses the largest biscuit after a completely impartial investigation.",
    sell = "presents a pebble as a rare collectible. Very limited edition.",
    sense = "senses a disturbance in the snack supply.",
    separate = "separates the sweets by colour with professional seriousness.",
    serve = "offers a freshly prepared hot drink.",
    set = "sets a cup down with the solemnity of an ancient ritual.",
    settle = "settles into a chair with a sigh that suggests a long and difficult quest.",
    sexy = "is too sexy for their tunic...so sexy it hurts.",
    shake = "shakes their rear.",
    shakefist = "shakes their fist.",
    shakehead = "shakes their head firmly.",
    shame = "lowers their gaze in shame.",
    shape = "moulds a scrap of dough into a creature with far too many opinions.",
    share = "offers to share what they have.",
    sharecookie = "holds out a cookie with a generous smile.",
    shimmy = "shimmies before the masses.",
    shindig = "raises a drink in the air before chugging it down. Cheers!",
    shiver = "shivers in their boots. Chilling!",
    shocked = "stares in stunned disbelief.",
    shoo = "shoos the measly pests away.",
    shoot = "makes finger guns and gives a tiny, unnecessary 'pew pew.'",
    shout = "shouts.",
    show = "shows off a perfectly ordinary rock with extraordinary pride.",
    showoff = "twirls a spoon with needless flair and nearly loses an eye to soup.",
    shrink = "tries to make themself as small and unnoticeable as possible.",
    shrug = "shrugs and spreads their hands. Who knows?",
    shudder = "shudders from head to toe. That was unsettling.",
    shush = "tells everyone to be quiet. Shhh!",
    shut = "shuts their notebook with the confidence of someone avoiding the contents.",
    shy = "looks away shyly, hiding a small smile.",
    shywave = "gives a small, bashful wave.",
    sigh = "lets out a long, tired sigh and lowers their shoulders.",
    sign = "signs an imaginary document with an extravagant flourish.",
    signal = "gives the signal.",
    silence = "tells everyone to be quiet. Shhh!",
    silly = "tells a joke.",
    sing = "bursts into song.",
    sipcoffee = "takes a leisurely sip of coffee.",
    siptea = "sips their tea with unhurried contentment.",
    sit = "sits down.",
    sitback = "leans back to enjoy the spectacle, discreetly searching for popcorn.",
    sitdown = "sits with the relief of someone completing a legendary quest.",
    sitstill = "sits perfectly still, apart from one extremely disobedient foot.",
    situp = "lies back and starts doing sit-ups.",
    skip = "skips along with a spring in their step.",
    slap = "slaps themself across the face. Ouch!",
    sleep = "falls asleep.",
    sleepin = "pulls an imaginary blanket higher and refuses to recognize morning.",
    slide = "slides a biscuit across the table like a confidential document.",
    slip = "slips slightly and converts it into an unconvincing dance step.",
    slowclap = "claps slowly, leaving the meaning open to interpretation.",
    slowdown = "slows their pace to better appreciate absolutely every shop window.",
    smack = "smacks their forehead.",
    smell = "smells the air around them. Wow, someone stinks!",
    smellflower = "lifts a flower to their nose and breathes in its scent.",
    smile = "gives a warm smile that reaches their eyes.",
    smoke = "takes a puff and watches a lazy curl of smoke drift away.",
    smoothdance = "glides into a smooth, flowing dance.",
    smug = "looks unbearably pleased with themself.",
    snap = "snaps their fingers.",
    snarl = "bares their teeth and snarls.",
    sneak = "tries to sneak away.",
    sneeze = "sneezes. Achoo!",
    snicker = "quietly snickers to themself.",
    sniff = "sniffs the air around them.",
    snore = "snores softly. Zzz...",
    snort = "snorts.",
    snub = "snubs all of the lowly peons around them.",
    snuggle = "snuggles up close, looking very comfortable.",
    sob = "sobs uncontrollably, struggling to catch their breath.",
    solve = "solves one problem by creating two more interesting problems.",
    soothe = "soothes the sorrowful. There, there... things will be ok.",
    sorry = "lowers their head and offers a sincere apology. Sorry!",
    sort = "sorts a handful of buttons with the seriousness of a royal treasurer.",
    sound = "sounds confident enough to briefly fool themself.",
    spare = "spares a sympathetic glance for an abandoned sandwich.",
    sparetime = "finds time for absolutely everything except the thing they should be doing.",
    sparkle = "poses as though surrounded by a shower of sparkles.",
    speedup = "quickens their steps upon hearing that the food is almost gone.",
    spellbook = "flips through a spellbook, muttering under their breath.",
    spend = "spends several seconds admiring a coin before putting it away again.",
    spin = "spins around on the spot.",
    spit = "spits on the ground.",
    split = "divides a biscuit into two uneven halves and contemplates justice.",
    spoil = "spoils their dramatic entrance by catching a sleeve on the doorway.",
    spoon = "needs to be cuddled.",
    spot = "spots a stray sweet on the table. Eyes lock onto the objective.",
    spread = "spreads their arms wide to demonstrate the size of a very questionable fish.",
    squeal = "squeals like a pig.",
    squeeze = "squeezes a soft cushion as though extracting the last ounce of comfort.",
    squint = "narrows their eyes for a closer look.",
    stand = "stands up.",
    standaside = "steps aside with a sweeping gesture worthy of a royal doorman.",
    standback = "takes a sensible step back from a very unsensible idea.",
    standout = "attempts to blend in while wearing an expression of obvious importance.",
    standup = "stands up too confidently and waits for the world to stop wobbling.",
    stare = "stares off into the distance.",
    starjump = "leaps up with their arms and legs spread wide.",
    starstruck = "stares in wide-eyed admiration.",
    start = "gets started with a determined nod.",
    stay = "decides to stay exactly where the cushions are.",
    steal = "sneaks a single fry with the subtlety of a brightly dressed goose.",
    stick = "sticks a leaf to their forehead and calls it camouflage.",
    stink = "smells the air around them. Wow, someone stinks!",
    stir = "stirs an empty cup, too absorbed in thought to notice.",
    stomp = "stomps their foot on the ground.",
    stop = "comes to an abrupt stop.",
    stretch = "stretches their limbs and loosens up.",
    strong = "flexes their muscles. Oooooh so strong!",
    struggle = "wrestles with a sleeve that has apparently declared independence.",
    strut = "struts around with arms flapping. Cluck, cluck, chicken!",
    study = "studies with intense concentration.",
    succeed = "finally opens the jar and holds it up like a conquered fortress.",
    suffer = "endures a minor inconvenience with the expression of a tragic monarch.",
    suggest = "suggests a break with the urgency of a starving philosopher.",
    sulk = "withdraws into a sullen silence.",
    supply = "supplies the group with a fresh round of entirely unrequested opinions.",
    support = "supports their chin with one hand. At least someone is getting support.",
    suppose = "looks as though they might agree, depending on the snack situation.",
    surprised = "is so surprised!",
    surrender = "surrenders to their opponents.",
    survive = "emerges from a boring explanation looking ten years wiser.",
    suspect = "gives their missing biscuit's last known location a suspicious look.",
    suspicious = "narrows their eyes in suspicion.",
    swallow = "swallows the last bite before attempting to look innocent.",
    sweat = "is sweating.",
    sweep = "sweeps the ground with a broom.",
    swim = "mimes swimming through a sea of paperwork.",
    swing = "swings their legs from a seat with cheerful disregard for dignity.",
    take = "carefully takes a small item in hand.",
    takeback = "reconsiders a bold statement and quietly takes it back.",
    takeoff = "removes their hat with a flourish and discovers their hair has staged a rebellion.",
    takeout = "takes a crumpled list from their pocket. It appears to be mostly snacks.",
    takeover = "assumes command of the teapot. Order will be restored.",
    taketurns = "waits for their turn with a smile that is losing structural integrity.",
    talk = "talks to themself since no one else seems interested.",
    tantrum = "stamps their feet and throws a spectacular tantrum.",
    tap = "taps their foot. Hurry up already!",
    taste = "samples a spoonful and delivers a verdict entirely through eyebrows.",
    taunt = "taunts everyone around them. Bring it fools!",
    teach = "demonstrates a simple lesson with patient care.",
    tease = "is such a tease.",
    tell = "tells a story that improves dramatically with each retelling.",
    tend = "carefully tends a little plant that appears to be judging them.",
    test = "tests a chair with one cautious hand before committing to comfort.",
    thank = "gives thanks.",
    thankagain = "offers another grateful nod. The biscuit was genuinely excellent.",
    thanks = "gives thanks.",
    think = "is lost in thought.",
    thirsty = "is so thirsty. Can anyone spare a drink?",
    threat = "threatens everyone with the wrath of doom.",
    threaten = "threatens everyone with the wrath of doom.",
    throw = "tosses a small pebble into the distance.",
    tickle = "wants to be tickled. Hee hee!",
    tidyup = "tidies one corner and creates a much larger problem in another.",
    tie = "bends down to tie a loose lace.",
    tippytoes = "rises onto their tiptoes for a better look.",
    tired = "lets everyone know that they are tired.",
    toast = "raises a glass. To good company!",
    touch = "lightly touches the nearest surface with their fingertips.",
    tracerune = "traces a mysterious rune in the air with one finger.",
    trade = "offers a shiny button in exchange for a much shinier button.",
    train = "makes a train noise.",
    translate = "attempts to interpret an unreadable note and invents an exciting new meaning.",
    travel = "takes three steps and announces that the journey has changed them.",
    treat = "rewards themself with a sweet for successfully locating the sweets.",
    tremble = "trembles from head to toe.",
    trick = "pretends a coin vanished while visibly holding it in the other hand.",
    trip = "trips over absolutely nothing and tries to look dignified.",
    tripover = "trips over their own confidence and catches themself just in time.",
    truce = "offers a truce.",
    trust = "relaxes a little, willing to place their trust in someone.",
    try = "gives it a try with a determined little breath.",
    tumble = "tumbles into a pile of cushions and announces a successful landing.",
    turn = "turns around to see what is happening.",
    turnaround = "turns in a full circle while trying to remember the original direction.",
    turnback = "retraces their steps after realizing the important thing is still on the table.",
    turndown = "declines politely, then checks that dessert was not included in the offer.",
    turnin = "announces that they are retiring for the night with considerable dramatic weight.",
    turnover = "rolls onto the cooler side of a cushion. Innovation never sleeps.",
    turnup = "appears just as the food arrives. Astonishing timing.",
    twiddle = "twiddles their thumbs.",
    twitch = "twitches involuntarily.",
    ty = "thanks everyone around them.",
    understand = "nods as understanding dawns on their face.",
    unimpressed = "raises one eyebrow, thoroughly unimpressed.",
    unite = "brings two lonely biscuits together. In their mouth.",
    update = "revises their plans to include a second breakfast.",
    use = "uses a spoon as a pointer. Important spoon business.",
    uwu = "clasps their hands and smiles sweetly. UwU.",
    value = "holds a favourite mug with the care usually reserved for priceless relics.",
    veto = "vetoes the motion on the floor.",
    victory = "basks in the glory of victory.",
    view = "inspects the scene from a new angle. Still confusing, but diagonally.",
    violin = "begins to play the world's smallest violin.",
    visit = "visits the snack table as though paying respects to an old friend.",
    volunteer = "raises their hand in the air.",
    vote = "raises a hand in favour of whatever option includes dessert.",
    wail = "lets out a long, mournful wail.",
    wait = "asks everyone to wait.",
    waitaround = "waits around so patiently that even their impatience gets bored.",
    wake = "blinks awake with the expression of someone summoned against their will.",
    wakeup = "wakes with a tiny snort and pretends they were thinking with closed eyes.",
    walk = "takes a few unhurried steps.",
    wander = "wanders a few steps, lost in thought.",
    want = "eyes something with barely concealed longing.",
    warmup = "rubs their hands together and negotiates with the cold.",
    warn = "warns everyone.",
    wash = "washes their hands with a little water.",
    watch = "watches the scene unfold with quiet interest.",
    wave = "waves enthusiastically with a bright smile. Hello there!",
    weep = "weeps quietly, brushing tears from their cheeks.",
    weigh = "weighs two apples in their hands and chooses the one that looks friendlier.",
    welcome = "welcomes everyone.",
    wgesticulate = "waves their arms in wild, sweeping gestures.",
    wheeze = "draws a wheezing breath.",
    whimper = "lets out a quiet, unhappy whimper.",
    whine = "whines pathetically.",
    whisper = "leans closer and whispers something quietly.",
    whistle = "lets forth a sharp whistle.",
    whoa = "is blown away.",
    wicked = "grins wickedly.",
    wickedly = "grins wickedly.",
    win = "celebrates their victory. Woohoo!",
    wince = "winces sympathetically.",
    wink = "winks slyly.",
    wipe = "wipes their face with a cloth.",
    wish = "closes their eyes and makes a quiet wish.",
    wonder = "stares thoughtfully into space. The universe offers no snacks.",
    woot = "cheers!",
    work = "begins to work.",
    worry = "worries about what might go wrong.",
    wrap = "wraps a small gift in so much paper that it gains a defensive bonus.",
    wrath = "threatens everyone with the wrath of doom.",
    write = "jots down a few thoughts.",
    yawn = "yawns sleepily.",
    yay = "is filled with happiness!",
    yell = "shouts an announcement that the nearest person could have heard whispered.",
    yes = "nods yes.",
    yield = "surrenders the good chair with a sigh of exaggerated nobility.",
    yuppie = "celebrates with joy, Yuppie!",
    yw = "was happy to help.",
    zombiedance = "breaks into a stiff, shambling zombie dance.",
    zombiewalk = "shambles forward with stiff arms and a vacant stare.",
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
