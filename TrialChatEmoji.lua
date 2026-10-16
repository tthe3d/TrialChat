-- The emoticons shipped in Media/Emoji, with the text shortcuts from that
-- folder's README. Typing a shortcut (for example ":P") shows the matching
-- image in a message.
--
-- Animated emoticons ship as a "-frames.png" sprite sheet; "frames" is how
-- many cells it holds and "cell" is the width/height of one cell. WoW cannot
-- animate APNG files, so "frames" is what makes an emoticon animate.
TrialChatCommon = TrialChatCommon or {}

TrialChatCommon.EmojiDirectory = "Interface\\AddOns\\TrialChat\\Media\\Emoji\\"

-- How big an emoji is drawn in a chat message, in pixels. A sprite cell is 19
-- pixels wide, so drawing at 19 keeps one texture pixel on one screen pixel:
-- the picture stays sharp and no cell bleeds into the next one.
TrialChatCommon.EmojiTextSize = 19
-- How fast animated emoji play, in frames per second. The original emoticons
-- step every 200 ms, so five frames a second.
TrialChatCommon.EmojiFPS = 5

TrialChatCommon.EmojiList = {
    { name = "Smile", shortcut = ":)", file = "smile" },
    { name = "Open-mouthed smile", shortcut = ":D", file = "open-mouthed-smile" },
    { name = "Winking smile", shortcut = ";)", file = "winking-smile", frames = 3, cell = 19 },
    { name = "Surprised smile", shortcut = ":-O", file = "surprised-smile" },
    { name = "Smile with tongue out", shortcut = ":P", file = "smile-with-tongue-out" },
    { name = "Hot smile", shortcut = "(H)", file = "hot-smile" },
    { name = "Angry smile", shortcut = ":@", file = "angry-smile" },
    { name = "Embarrassed smile", shortcut = ":$", file = "embarrassed-smile" },
    { name = "Confused smile", shortcut = ":S", file = "confused-smile" },
    { name = "Sad smile", shortcut = ":(", file = "sad-smile" },
    { name = "Crying face", shortcut = ":'(", file = "crying-face", frames = 15, cell = 19 },
    { name = "Disappointed smile", shortcut = ":|", file = "disappointed-smile" },
    { name = "Devil", shortcut = "(6)", file = "devil" },
    { name = "Angel", shortcut = "(A)", file = "angel" },
    { name = "Red heart", shortcut = "(L)", file = "red-heart" },
    { name = "Broken heart", shortcut = "(U)", file = "broken-heart" },
    { name = "Messenger", shortcut = "(M)", file = "messenger" },
    { name = "Cat face", shortcut = "(@)", file = "cat-face" },
    { name = "Dog face", shortcut = "(&)", file = "dog-face" },
    { name = "Sleeping half-moon", shortcut = "(S)", file = "sleeping-half-moon" },
    { name = "Star", shortcut = "(*)", file = "star" },
    { name = "Filmstrip", shortcut = "(~)", file = "filmstrip" },
    { name = "Note", shortcut = "(8)", file = "note" },
    { name = "E-mail", shortcut = "(E)", file = "e-mail" },
    { name = "Red rose", shortcut = "(F)", file = "red-rose" },
    { name = "Wilted rose", shortcut = "(W)", file = "wilted-rose" },
    { name = "Clock", shortcut = "(O)", file = "clock" },
    { name = "Red lips", shortcut = "(K)", file = "red-lips" },
    { name = "Gift with a bow", shortcut = "(G)", file = "gift-with-a-bow" },
    { name = "Birthday cake", shortcut = "(^)", file = "birthday-cake", frames = 8, cell = 17 },
    { name = "Camera", shortcut = "(P)", file = "camera" },
    { name = "Light bulb", shortcut = "(I)", file = "light-bulb" },
    { name = "Coffee cup", shortcut = "(C)", file = "coffee-cup" },
    { name = "Telephone receiver", shortcut = "(T)", file = "telephone-receiver" },
    { name = "Left hug", shortcut = "({)", file = "left-hug" },
    { name = "Right hug", shortcut = "(})", file = "right-hug" },
    { name = "Beer mug", shortcut = "(B)", file = "beer-mug" },
    { name = "Martini glass", shortcut = "(D)", file = "martini-glass" },
    { name = "Boy", shortcut = "(Z)", file = "boy" },
    { name = "Girl", shortcut = "(X)", file = "girl" },
    { name = "Thumbs up", shortcut = "(Y)", file = "thumbs-up" },
    { name = "Thumbs down", shortcut = "(N)", file = "thumbs-down" },
    { name = "Vampire bat", shortcut = ":[", file = "vampire-bat", frames = 9, cell = 19 },
    { name = "Goat", shortcut = "(nnh)", file = "goat" },
    { name = "Sun", shortcut = "(#)", file = "sun" },
    { name = "Rainbow", shortcut = "(R)", file = "rainbow" },
    { name = "Don't tell anyone smile", shortcut = ":-#", file = "dont-tell-anyone-smile" },
    { name = "Baring teeth smile", shortcut = "8o|", file = "baring-teeth-smile" },
    { name = "Nerd smile", shortcut = "8-|", file = "nerd-smile" },
    { name = "Sarcastic smile", shortcut = "^o)", file = "sarcastic-smile" },
    { name = "Secret telling smile", shortcut = ":-*", file = "secret-telling-smile" },
    { name = "Sick smile", shortcut = "+o(", file = "sick-smile" },
    { name = "Snail", shortcut = "(sn)", file = "snail" },
    { name = "Turtle", shortcut = "(tu)", file = "turtle" },
    { name = "Plate", shortcut = "(pl)", file = "plate" },
    { name = "Bowl", shortcut = "(||)", file = "bowl" },
    { name = "Pizza", shortcut = "(pi)", file = "pizza" },
    { name = "Soccer ball", shortcut = "(so)", file = "soccer-ball" },
    { name = "Auto", shortcut = "(au)", file = "auto" },
    { name = "Airplane", shortcut = "(ap)", file = "airplane" },
    { name = "Umbrella", shortcut = "(um)", file = "umbrella" },
    { name = "Island with a palm tree", shortcut = "(ip)", file = "island-with-a-palm-tree" },
    { name = "Computer", shortcut = "(co)", file = "computer" },
    { name = "Mobile phone", shortcut = "(mp)", file = "mobile-phone" },
    { name = "Be right back", shortcut = "(brb)", file = "be-right-back" },
    { name = "Storm cloud", shortcut = "(st)", file = "storm-cloud" },
    { name = "High five!", shortcut = "(h5)", file = "high-five" },
    { name = "Money", shortcut = "(mo)", file = "money" },
    { name = "Black sheep", shortcut = "(bah)", file = "black-sheep" },
    { name = "I don't know smile", shortcut = ":^)", file = "i-dont-know-smile", frames = 5, cell = 19 },
    { name = "Thinking smile", shortcut = "*-)", file = "thinking-smile", frames = 4, cell = 19 },
    { name = "Lightning", shortcut = "(li)", file = "lightning", frames = 6, cell = 19 },
    { name = "Party smile", shortcut = "<:o)", file = "party-smile", frames = 4, cell = 19 },
    { name = "Eye-rolling smile", shortcut = "8-)", file = "eye-rolling-smile", frames = 6, cell = 19 },
    { name = "Sleepy smile", shortcut = "|-)", file = "sleepy-smile", frames = 9, cell = 19 },
    { name = "Bunny", shortcut = "('.')", file = "bunny" },
    { name = "Cigarette", shortcut = "(CIG)", file = "cigarette", frames = 5, cell = 19 },
    { name = "Fingers crossed", shortcut = "(CRS)", file = "fingers-crossed" },
    { name = "Cuffs", shortcut = "(CF)", file = "cuffs" },
}

-- Look an emoticon up by its shortcut (what the player types) or by its file
-- name (what a drawing refers to).
TrialChatCommon.EmojiByShortcut = {}
TrialChatCommon.EmojiByFile = {}

-- Shortcuts that start with the same character, longest first, so a single
-- left-to-right scan can replace a whole message in one pass.
TrialChatCommon.EmojiByFirstChar = {}

local shortcutBuckets = {}
for index = 1, #TrialChatCommon.EmojiList do
    local entry = TrialChatCommon.EmojiList[index]
    entry.animated = entry.frames ~= nil
    -- Stagger the animations, so emoticons don't all tick on the same frame.
    entry.offset = (index * 7) % 31
    TrialChatCommon.EmojiByShortcut[entry.shortcut] = entry
    TrialChatCommon.EmojiByFile[entry.file] = entry
    local first = string.sub(entry.shortcut, 1, 1)
    local bucket = shortcutBuckets[first]
    if not bucket then
        bucket = {}
        shortcutBuckets[first] = bucket
    end
    bucket[#bucket + 1] = entry
end
for first, bucket in pairs(shortcutBuckets) do
    table.sort(bucket, function(a, b) return #a.shortcut > #b.shortcut end)
    TrialChatCommon.EmojiByFirstChar[first] = bucket
end

-- The picture for an emoticon as an inline texture a font string can show.
-- An animated emoticon draws one cell of its sprite sheet, chosen by frame.
function TrialChatCommon.EmojiMarkup(entry, frame)
    local size = TrialChatCommon.EmojiTextSize or 19
    local directory = TrialChatCommon.EmojiDirectory
    if not entry.frames then
        return "|T" .. directory .. entry.file .. ".png:" .. size .. ":" .. size .. "|t"
    end
    local count = entry.frames
    local cell = entry.cell or 19
    frame = ((frame - 1) % count) + 1
    local left = (frame - 1) * cell
    local right = frame * cell
    return "|T" .. directory .. entry.file .. "-frames.png:"
        .. size .. ":" .. size .. ":0:0:"
        .. (count * cell) .. ":" .. cell
        .. ":" .. left .. ":" .. right .. ":0:" .. cell .. "|t"
end

-- Which cell of its sprite sheet an animated emoticon shows right now.
function TrialChatCommon.EmojiFrame(entry, time)
    if not entry.frames then return 1 end
    local count = entry.frames
    local tick = math.floor((time or GetTime()) * (TrialChatCommon.EmojiFPS or 5)
        + (entry.offset or 0))
    return tick % count + 1
end

-- A message split into plain text and emoticons, so the emoticons can be
-- redrawn on later frames while the text around them stays put.
function TrialChatCommon.BuildEmojiText(parts, time)
    local out = {}
    for index = 1, #parts do
        local part = parts[index]
        if type(part) == "string" then
            out[#out + 1] = part
        else
            out[#out + 1] = TrialChatCommon.EmojiMarkup(
                part.emoji, TrialChatCommon.EmojiFrame(part.emoji, time))
        end
    end
    return table.concat(out)
end

-- Splits already drawn text (see ApplyEmojiMarkup) back into its text and
-- emoticon pieces. Returns nil when there is no emoticon in it, otherwise the
-- pieces and whether any of them animate.
function TrialChatCommon.SplitEmojiMarkup(text)
    if not text or text == "" then return nil end
    local marker = "|T" .. TrialChatCommon.EmojiDirectory
    local markerLength = #marker
    local parts = {}
    local hasAnimated = false
    local position = 1     -- next character of the text not yet taken
    local searchFrom = 1   -- where the next marker search begins
    while true do
        local start = string.find(text, marker, searchFrom, true)
        if not start then break end
        local closeEnd = string.find(text, "|t", start + markerLength, true)
        local file
        if closeEnd then
            local colon = string.find(text, ":", start + markerLength, true)
            if colon and colon < closeEnd then
                file = string.sub(text, start + markerLength, colon - 1)
                file = string.gsub(file, "%.png$", "")
                file = string.gsub(file, "%-frames$", "")
            end
        end
        local entry = file and TrialChatCommon.EmojiByFile[file]
        if entry then
            if start > position then
                parts[#parts + 1] = string.sub(text, position, start - 1)
            end
            parts[#parts + 1] = { emoji = entry }
            if entry.frames then hasAnimated = true end
            position = closeEnd + 2
            searchFrom = position
        else
            -- Not one of ours; leave it as ordinary text.
            searchFrom = start + 2
        end
    end
    if #parts == 0 then return nil end
    if position <= #text then
        parts[#parts + 1] = string.sub(text, position)
    end
    return parts, hasAnimated
end

-- Whether a character belongs to a word, so an emoticon is only replaced when
-- it stands on its own ("hi :P") and not inside one ("hi:P").
local function isWordChar(char)
    return char ~= nil and char ~= "" and string.find(char, "[%w]") ~= nil
end

-- Replaces every emoticon shortcut in a message with the picture it stands
-- for. Run before FormatMessageText, which lets the pictures through.
function TrialChatCommon.ApplyEmojiMarkup(text)
    if not text or text == "" then return text end
    local out = {}
    local position = 1
    local length = #text
    while position <= length do
        local char = string.sub(text, position, position)
        local candidates = TrialChatCommon.EmojiByFirstChar[char]
        local matched = false
        if candidates then
            for index = 1, #candidates do
                local entry = candidates[index]
                local shortcut = entry.shortcut
                local shortcutLength = #shortcut
                if string.sub(text, position, position + shortcutLength - 1)
                    == shortcut then
                    local before = position > 1
                        and string.sub(text, position - 1, position - 1) or nil
                    local after = position + shortcutLength <= length
                        and string.sub(text, position + shortcutLength,
                            position + shortcutLength) or nil
                    if not isWordChar(before) and not isWordChar(after) then
                        out[#out + 1] = TrialChatCommon.EmojiMarkup(entry, 1)
                        position = position + shortcutLength
                        matched = true
                        break
                    end
                end
            end
        end
        if not matched then
            out[#out + 1] = char
            position = position + 1
        end
    end
    return table.concat(out)
end
