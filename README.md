# 💬 TrialChat

> **Status:** ⚠️ This add-on is still in development.

This World of Warcraft Retail add-on allows characters (including trial accounts) to talk to other nearby players who also have the add-on installed.

---

## 🚀 How to Use

* **Toggle Window:** Type `/tc` in your chat or click the mini-map button to show/hide the interface.
* **Keybind Support:** A shortcut key option is also available under the game's official keybind menu.
* **Options:** Open it with **Options** in the mini-map button's right-click menu, or with the gear button in the window. It has every option in one place: chat bubbles (all, over your own character, for group chats), **Echo to Say (/s)** and **Echo to Party (/p)**. Press Escape or the close button to dismiss it.
* **Echo to Say:** With **Echo to Say (/s)** on, your nearby messages are also sent as a normal `/say`, so players without TrialChat can read them (your bubbles aren't doubled).
* **Echo to Party:** With **Echo to Party (/p)** on, your nearby messages are also sent to your group, so members who are elsewhere — or without TrialChat — can read them there. In a raid they go to the raid instead, and outside a group they stay nearby. It works alongside Echo to Say, and emotes are never echoed (the game already announces them).
* **Chat Bubbles:** Type `/tcbubbles` to turn chat bubbles on or off, `/tcbubbles self` for just the bubble over your own character, or `/tcbubbles groups` for just group chat bubbles. The same switches are in the Options window, which the gear button in the window opens.
* **Emotes:** Type them like in normal chat (`/wave`, `/e waves hello`), or pick one with the smiley button next to the message box. The same button opens an **emoji picker**: a searchable grid of the MSN/Windows Live Messenger emoticons in `Media/Emoji` (animated ones play right in the grid). Click one to drop its text shortcut into the message box. The picker also offers **All emotes**, **Sound emotes**, and **Make your own**.
* **Sound Emotes:** Type `//` and an emote name (`//laugh`, `//cheer`, `//vineboom`) to also play a sound file from `Media/SoundEmotes`. The sound plays for you and for the TrialChat players around you (and in your group): only the name is sent, and each of them plays their own copy of the file. If the name is a normal emote, the emote is sent to chat as well; a sound-only emote is heard but doesn't show as a chat line. Files are listed in `TrialChatSoundEmotes.lua`, and names without an entry fall back to `<name>.mp3`. Sound emotes play one at a time, so a new one never talks over (or gets cut off by) one that is still playing. **Mute sound emotes** in Options turns them all off for you (yours still reach the players around you).
* **Group Icons:** A group has an icon, chosen by its creator from the same icons macros use. Pick one in the **Create a group** dialog; the creator can change it later by clicking the icon in the group's header, or with **Change icon...** in the group's right-click menu. Everyone in the group sees the same icon.
* **Whispers:** Right-click a nearby player or a group member and choose **Whisper** (or **Whisper in TrialChat** in the game's player menu on a player) to open a one-on-one conversation in the window. Whispers travel as addon messages between TrialChat players, never as game whispers, so a trial account can hold a one-on-one conversation with a paid player. The conversation is listed on the left with the player's portrait and keeps its history and unread count like the other conversations. Whisper history belongs to the character you're playing, so logging in as someone else starts with their own list.
* **Replies:** Right-click a message for a small menu: **Reply** shows what you're answering above the message box until you send, and **Copy text** puts the message in a box you can select. The reply carries a little of the original with it, so other TrialChat users see what you answered; players on older versions see it as plain text.

---

## ✨ Features

* **Proximity Chat:** Talk with nearby players across all character types.
* **Chat Bubbles:** Messages from nearby players appear in speech bubbles above their heads (requires friendly player nameplates; open world only). Your own messages appear over your character too; its position is estimated from the camera, so it can be off with ActionCam or when the camera is pushed in by walls. Group chat messages get a purple bubble with the group's name.
* **Permanent Listeners:** Add permanently active listeners to stay in touch even when you travel to different zones.
* **Group Chat:** Full group chat functionality, including **chat history synchronization** between all group members. Click the **sync** button in a group to fetch any messages you're missing, up to the last 2000. When you log in, TrialChat reconnects your groups through whichever member is online, skipping the ones who aren't; if nobody is, the group opens anyway and joins up as soon as a member comes online. The game's "No player named ... is currently playing" lines for the players TrialChat looks for stay out of your chat.
* **Group Invites:** Invite a player with **Invite a player...** in a group's right-click menu, or with **Invite to TrialChat group** in the game's right-click menu on a player (their portrait, their name in chat, or your friends, guild and TrialChat member lists). TrialChat opens for them with the invite above the message box, and **Join** joins right away (or **Decline**; an invite left unanswered goes away after a minute). An invite shares the group's password with them, as joining does, and only reaches players who have TrialChat.
* **Whispers:** One-on-one conversations shown in the sidebar with the player's portrait (their class icon when the game can't draw the portrait). They are addon messages between TrialChat players, like nearby chat, so they work from a trial account and are read in the TrialChat window rather than the normal chat. Start one with **Whisper** on a nearby player or group member, or **Whisper in TrialChat** in the game's player menu. The other player is shown online while TrialChat can tell they're around: they answer a presence ping, they're an active player nearby, or they're online in a group you share. Whispers are kept per character, so a different character on the same account has its own separate list.
* **Removing Members:** A group's creator can remove a member with **Remove from TrialChat group** in the game's right-click menu on them (the same places the invite menu appears), or from the member list in the window. The member is told and leaves the group, and a removed member can't simply reconnect; inviting them again lets them back in. When a member leaves the group with **Exit group** while nobody else was online, the creator is told next time they look at the group. Disconnecting or logging out isn't leaving: it only shows them as offline until they are back.
* **Group Icons:** Each group has an icon from the same set of icons macros have, picked by its creator and shared with the whole group. It shows on the group's tile in the sidebar and beside its name in the header; a group whose creator hasn't picked one gets a distinct icon derived from its name.
* **Messenger Window:** Nearby chat and your groups are listed on the left with their unread messages (including ones you missed while offline), and saved groups you're not connected to can be connected with a click. Groups are saved on the account, but which ones a character is in is that character's own: a saved group this character hasn't joined shows a **✓** to join it and a **✗** to decline instead of a member count, and declining means it won't be offered again for that character (joining it later, or with **Join a group**, takes it back). Search the list, or right-click a group to invite someone, sync its history, mute it, or leave it. The **Create or join a group** button below the list starts a new group or joins one. Messages show under the sender's avatar and name in their class color (the avatar is their character's portrait when they're near you or in your group, and their race's portrait otherwise), with dividers for each day and for what's new since you last looked. Right-click a message to **Reply** to it or **Copy text**. The list on the right shows who is online, who isn't, and who is nearby.
* **Minimal View:** The button next to close in the window switches to a minimal view: the newest messages show over the game and fade like normal chat, with a row of conversations and a message box below them (Tab switches conversation, Esc stops typing). Scroll with the mouse wheel to read back through the conversation. Drag it by the dots or any message to move it, and by its top-right corner to resize it (it shows at its full size while you drag). A message in another conversation shows a notice in the corner; click it or press your TrialChat key to reply. A small field in its top-left corner, like a Mac window's, holds the window buttons above the conversations, so they never cover anything: red closes the chat and green opens the full window. It sits in the chat box's own corner curve and stays in the corner whether the chat is shrunk or grown, and reaching for it doesn't light the chat up.
* **Chat History:** Groups keep their last 2000 messages and nearby chat its last 1000, all of it scrollable in the window. While you're scrolled up reading, new messages don't pull you down; a **New messages** button takes you back.
* **Long Messages:** Nearby and group messages can be up to 1000 bytes; longer ones are sent in parts and joined back together (players on older versions won't see them).
* **Sound Notifications:** Never miss a message with integrated group chat audio alerts.
* **Rich Media Support:** Interactive clickable links for **webpages, items, quests**, and even **Musician** add-on songs.
* **Emotes:** Support for almost all standard WoW emotes.
* **Emoji:** The 76 original MSN/Windows Live Messenger emoticons in `Media/Emoji`, with the text shortcuts listed in that folder's README. Type a shortcut (`:)`, `:P`, `(L)`, `(bah)`...) in a message and it shows as the picture, animated ones included. The smiley button opens a searchable grid to pick one, and clicking one inserts its shortcut into the message box.
* **Sound Emotes:** Play audio for `//`-triggered emotes, with files in `Media/SoundEmotes` and a mapping in `TrialChatSoundEmotes.lua`. The name of a sound emote is sent to nearby TrialChat players and your group, so they hear it too (each plays their own copy of the file). They never play over each other: one that is still playing finishes first, and the next waits its turn. **Mute sound emotes** in Options turns them off.
* ...and a bunch of other stuff!


<img width="909" height="519" alt="Screenshot 2026-10-15 at 17 25 44" src="https://github.com/user-attachments/assets/37709916-6470-4e3b-a0a2-4681088a5fd9" />. 

<img width="479" height="293" alt="Screenshot 2026-10-15 at 17 28 12" src="https://github.com/user-attachments/assets/5f11757e-463d-484d-b773-ceedd0858ebe" />. 



---

## ❤️ Acknowledgements

Thank you **Tînky** for testing with me!
