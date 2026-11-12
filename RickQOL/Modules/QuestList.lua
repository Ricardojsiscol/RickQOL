-- "Available quests in this zone": a window listing the quests the player can pick up in the current
-- zone, navigable with the controller. Pick one to put a waypoint on its quest giver.
-- Opens with RB while the quest tracker has the controller focus, a button on the tracker header
-- (mouse), a key binding (Bindings.xml) or /rqol quests.
--
-- Controller input: while the window is open, an own frame takes the D-pad and face buttons
-- (OnGamePadButtonDown + per-press SetPropagateKeyboardInput); every other button reaches the game.
-- Propagation can't change in combat, so the window only opens out of combat and closes when
-- combat starts. Nothing here registers with Blizzard's controller systems.
local _, R = ...

local QuestList = R:RegisterModule("quests", { help = "(opens the available quests list)" })

local ROWS = 10
local ROW_HEIGHT = 34
local WIDTH = 440
local CHAIN_LIMIT = 40 -- guard against loops in chain data

-- Controller and keyboard keys -> actions.
local ACTIONS = {
    PADDUP = "up", PADDDOWN = "down", PAD1 = "select", PAD2 = "close", PAD4 = "sort",
    PADLSHOULDER = "pageUp", PADRSHOULDER = "pageDown",
    UP = "up", DOWN = "down", ENTER = "select", ESCAPE = "close", PAGEUP = "pageUp", PAGEDOWN = "pageDown",
}
local REPEATS = { up = true, down = true }
local REPEAT_DELAY, REPEAT_RATE = 0.35, 0.08

----------------------------------------------------------------------------
-- Data
----------------------------------------------------------------------------

-- How a quest sits in its chain: steps that follow it, and whether it continues an earlier quest.
local function ChainInfo(questID)
    local data = R.modules.questdata
    local after, current, seen = 0, questID, { [questID] = true }
    for _ = 1, CHAIN_LIMIT do
        local nextID = data:QuestField(current, "nextQuestInChain")
        if not nextID or nextID == 0 or seen[nextID] then break end
        seen[nextID] = true
        after = after + 1
        current = nextID
    end
    if after == 0 then
        local children = data:QuestField(questID, "childQuests")
        if type(children) == "table" and #children > 0 then after = 1 end
    end
    local group = data:QuestField(questID, "preQuestGroup")
    local single = data:QuestField(questID, "preQuestSingle")
    local continues = (type(group) == "table" and #group > 0) or (type(single) == "table" and #single > 0)
    return after, continues
end

-- Every quest the player can take in their current zone, one entry per quest (nearest giver).
function QuestList:Collect()
    local data, pins = R.modules.questdata, R.modules.pins
    local mapID = C_Map.GetBestMapForUnit("player")
    local info = mapID and C_Map.GetMapInfo(mapID)
    self.zoneName = info and info.name or "?"
    local entries = {}
    if not (data.ready and mapID) then return entries end

    local position = C_Map.GetPlayerMapPosition(mapID, "player")
    local px, py = 0, 0
    if position then px, py = position:GetXY() end
    local width, height = C_Map.GetMapWorldSize(mapID)

    local me = data:Snapshot()
    local byQuest = {}
    for _, spot in ipairs(data:PinsForMap(mapID) or {}) do
        local quests = pins:AvailableAt(spot, me)
        for _, quest in ipairs(quests or {}) do
            local distance = position and width and math.sqrt(((spot.x - px) * width) ^ 2 + ((spot.y - py) * height) ^ 2)
            local entry = byQuest[quest.questID]
            if not entry or (distance and entry.distance and distance < entry.distance) then
                local after, continues = ChainInfo(quest.questID)
                entry = {
                    questID = quest.questID,
                    title = data:Title(quest.questID),
                    level = data:QuestField(quest.questID, "questLevel") or 0,
                    trivial = quest.trivial,
                    starter = spot.starter,
                    waypoint = { mapID = mapID, x = spot.x, y = spot.y, starter = spot.starter, quests = { quest } },
                    distance = distance,
                    chainAfter = after,
                    continuesChain = continues,
                }
                byQuest[quest.questID] = entry
            end
        end
    end
    for _, entry in pairs(byQuest) do entries[#entries + 1] = entry end

    local byLevel = self.sortByLevel
    table.sort(entries, function(a, b)
        if byLevel and a.level ~= b.level then return a.level < b.level end
        if a.distance and b.distance and a.distance ~= b.distance then return a.distance < b.distance end
        return a.title < b.title
    end)
    return entries
end

local function ChainText(entry)
    if entry.chainAfter == 0 then return nil end
    if entry.continuesChain then
        return ("|cff9fd5ffChain: %d more|r"):format(entry.chainAfter)
    end
    return ("|cffffd100Starts a chain (%d quests)|r"):format(entry.chainAfter + 1)
end

----------------------------------------------------------------------------
-- Window
----------------------------------------------------------------------------

function QuestList:CreateWindow()
    local frame = CreateFrame("Frame", "RickQOLQuestList", UIParent, "BasicFrameTemplateWithInset")
    frame:SetSize(WIDTH, 120 + ROWS * ROW_HEIGHT + 90)
    frame:SetPoint("CENTER")
    frame:SetFrameStrata("DIALOG")
    frame:SetMovable(true)
    frame:SetClampedToScreen(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
    frame:Hide()
    frame.TitleText:SetText("Available quests")

    frame.zone = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    frame.zone:SetPoint("TOPLEFT", 16, -34)

    frame.count = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    frame.count:SetPoint("TOPRIGHT", -16, -38)

    frame.empty = frame:CreateFontString(nil, "OVERLAY", "GameFontDisable")
    frame.empty:SetPoint("TOP", 0, -90)
    frame.empty:SetText("No quests to pick up here right now.")

    self.rows = {}
    for i = 1, ROWS do
        local row = CreateFrame("Button", nil, frame)
        row:SetSize(WIDTH - 28, ROW_HEIGHT - 2)
        row:SetPoint("TOPLEFT", 14, -58 - (i - 1) * ROW_HEIGHT)
        -- Blizzard's quest log title highlight, for hover and for the selected row.
        row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
        row.selected = row:CreateTexture(nil, "BACKGROUND")
        row.selected:SetAllPoints()
        row.selected:SetTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
        row.selected:SetBlendMode("ADD")
        row.selected:SetVertexColor(1, 0.82, 0)
        row.selected:Hide()

        row.title = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        row.title:SetPoint("TOPLEFT", 6, -3)
        row.title:SetPoint("RIGHT", -70, 0)
        row.title:SetJustifyH("LEFT")
        row.title:SetWordWrap(false)

        row.sub = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.sub:SetPoint("BOTTOMLEFT", 6, 3)
        row.sub:SetPoint("RIGHT", -70, 0)
        row.sub:SetJustifyH("LEFT")
        row.sub:SetWordWrap(false)
        row.sub:SetTextColor(0.7, 0.7, 0.7)

        row.distance = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.distance:SetPoint("RIGHT", -6, 0)

        row:SetScript("OnClick", function(button)
            self.selected = button.index
            self:Choose()
        end)
        row:SetScript("OnEnter", function(button)
            self.selected = button.index
            self:Render()
        end)
        self.rows[i] = row
    end

    -- Details of the selected quest.
    local detail = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    detail:SetPoint("TOPLEFT", 18, -66 - ROWS * ROW_HEIGHT)
    detail:SetPoint("RIGHT", -18, 0)
    detail:SetJustifyH("LEFT")
    detail:SetJustifyV("TOP")
    detail:SetHeight(64)
    frame.detail = detail

    frame.hints = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    frame.hints:SetPoint("BOTTOM", 0, 12)
    frame.hints:SetText("A: set waypoint     B: close     Y: sort by distance / level     LB / RB: page")

    -- Input catcher (see the comment at the top of this file).
    frame:SetScript("OnGamePadButtonDown", function(f, key) self:OnInput(f, key) end)
    frame:SetScript("OnGamePadButtonUp", function() self.held = nil end)
    frame:SetScript("OnKeyDown", function(f, key) self:OnInput(f, key) end)
    frame:SetScript("OnKeyUp", function() self.held = nil end)
    frame:SetScript("OnUpdate", function(_, elapsed) self:OnRepeat(elapsed) end)
    frame:SetScript("OnHide", function() self.held = nil end)

    self.frame = frame
end

function QuestList:Render()
    local frame = self.frame
    local entries = self.entries or {}
    frame.zone:SetText(self.zoneName or "")
    frame.count:SetText(("%d quest%s%s"):format(#entries, #entries == 1 and "" or "s",
        self.sortByLevel and " · by level" or " · by distance"))
    frame.empty:SetShown(#entries == 0)

    -- Keep the selection on screen.
    if self.selected > self.offset + ROWS then self.offset = self.selected - ROWS end
    if self.selected <= self.offset then self.offset = math.max(0, self.selected - 1) end

    for i, row in ipairs(self.rows) do
        local index = self.offset + i
        local entry = entries[index]
        row.index = index
        if entry then
            local color = GetQuestDifficultyColor(entry.level)
            row.title:SetText(("[%d] %s"):format(entry.level, entry.title))
            row.title:SetTextColor(color.r, color.g, color.b)
            local chain = ChainText(entry)
            row.sub:SetText((entry.starter.name or "?") .. (chain and ("  ·  " .. chain) or ""))
            row.distance:SetText(entry.distance and ("%d yd"):format(entry.distance) or "")
            row.selected:SetShown(index == self.selected)
            row:Show()
        else
            row:Hide()
        end
    end

    local entry = entries[self.selected]
    if entry then
        local data = R.modules.questdata
        local lines = {}
        local objectives = data:QuestField(entry.questID, "objectivesText")
        if type(objectives) == "table" and objectives[1] then lines[#lines + 1] = table.concat(objectives, " ") end
        local chain = ChainText(entry)
        if chain then lines[#lines + 1] = chain end
        frame.detail:SetText(table.concat(lines, "\n"))
    else
        frame.detail:SetText("")
    end
end

function QuestList:Move(delta)
    local count = #(self.entries or {})
    if count == 0 then return end
    self.selected = math.max(1, math.min(count, self.selected + delta))
    self:Render()
end

function QuestList:Choose()
    local entry = self.entries and self.entries[self.selected]
    if not entry then return end
    R.modules.pins:SetWaypoint(entry.waypoint)
    self:Close()
end

function QuestList:Do(action)
    if action == "up" then self:Move(-1)
    elseif action == "down" then self:Move(1)
    elseif action == "pageUp" then self:Move(-ROWS)
    elseif action == "pageDown" then self:Move(ROWS)
    elseif action == "select" then self:Choose()
    elseif action == "close" then self:Close()
    elseif action == "sort" then
        self.sortByLevel = not self.sortByLevel
        self.entries = self:Collect()
        self.selected, self.offset = 1, 0
        self:Render()
    end
end

function QuestList:OnInput(frame, key)
    local action = ACTIONS[key]
    -- Keep what we use; let everything else (movement, abilities, chat) through.
    if not InCombatLockdown() then frame:SetPropagateKeyboardInput(action == nil) end
    if not action then return end
    self:Do(action)
    if REPEATS[action] then
        self.held, self.heldTime = action, -REPEAT_DELAY
    end
end

function QuestList:OnRepeat(elapsed)
    if not self.held then return end
    self.heldTime = self.heldTime + elapsed
    if self.heldTime >= REPEAT_RATE then
        self.heldTime = 0
        self:Do(self.held)
    end
end

function QuestList:Open()
    if InCombatLockdown() then
        R:Print("the quest list can't open in combat.")
        return
    end
    if not R.modules.questdata.ready then
        R:Print("quest data is still loading; try again in a moment.")
        return
    end
    local frame = self.frame
    self.entries = self:Collect()
    self.selected, self.offset = 1, 0
    frame:EnableKeyboard(true)
    frame:EnableGamePadButton(true)
    frame:SetPropagateKeyboardInput(true)
    self:Render()
    frame:Show()
end

function QuestList:Close()
    self.frame:Hide()
end

function QuestList:Toggle()
    if self.frame:IsShown() then self:Close() else self:Open() end
end

----------------------------------------------------------------------------
-- Entry points
----------------------------------------------------------------------------

function QuestList:AddTrackerButton()
    local header = ObjectiveTrackerFrame and ObjectiveTrackerFrame.Header
    if not (header and header.MinimizeButton) then return end
    local button = CreateFrame("Button", nil, header)
    button:SetSize(18, 19)
    -- Left of the collapse button, leaving room for Blizzard's (usually hidden) filter button.
    button:SetPoint("RIGHT", header.MinimizeButton, "LEFT", -22, 0)
    button:SetNormalAtlas("QuestNormal")
    button:SetHighlightAtlas("ui-questtrackerbutton-red-highlight", "ADD")
    button:SetScript("OnClick", function() self:Toggle() end)
    button:SetScript("OnEnter", function(b)
        GameTooltip:SetOwner(b, "ANCHOR_LEFT")
        GameTooltip:AddLine("Available quests in this zone", 1, 1, 1)
        GameTooltip:AddLine("Key binding: Options > Keybindings > AddOns > RickQOL", 0.7, 0.7, 0.7)
        GameTooltip:Show()
    end)
    button:SetScript("OnLeave", GameTooltip_Hide)
    self.trackerButton = button
end

-- Controller access from the quest tracker: while Blizzard's tracker has the controller focus, RB
-- opens the list and a small "RB" prompt shows next to the tracker button.
--
-- Taint: this only READS two fields of Blizzard's focus manager (like BagPad did) and never calls
-- into it. Adding an entry to the tracker's Y menu (Menu.ModifyMenu) was tried and tainted Forever's
-- controller bindings ("blocked from an action only available to the Blizzard UI"), so don't.
local TRACKER_KEY = "PADRSHOULDER"

local function TrackerHasFocus()
    local mode = rawget(_G, "GamepadMode")
    local manager = mode and mode.FrameControlsManager
    return manager ~= nil and manager.isUIFocused == true and manager.focusedFrame == ObjectiveTrackerFrame
end

function QuestList:WatchTrackerFocus()
    if not self.trackerButton then return end

    local prompt = self.trackerButton:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    prompt:SetPoint("RIGHT", self.trackerButton, "LEFT", -2, 0)
    prompt:SetText("|cffffffffRB|r")
    prompt:Hide()

    -- Takes RB only; every other button goes on to Blizzard's tracker controls.
    local catcher = CreateFrame("Frame", nil, UIParent)
    catcher:Hide()
    catcher:SetScript("OnGamePadButtonDown", function(frame, key)
        local mine = key == TRACKER_KEY
        if not InCombatLockdown() then frame:SetPropagateKeyboardInput(not mine) end
        if mine then self:Open() end
    end)

    local active = false
    local elapsed = 0
    local watcher = CreateFrame("Frame")
    watcher:SetScript("OnUpdate", function(_, delta)
        elapsed = elapsed + delta
        if elapsed < 0.1 then return end
        elapsed = 0
        local want = TrackerHasFocus() and not InCombatLockdown() and not self.frame:IsShown()
        if want == active then return end
        if InCombatLockdown() and want then return end
        active = want
        if want then
            catcher:EnableGamePadButton(true)
            catcher:SetPropagateKeyboardInput(true)
            catcher:Show()
        else
            catcher:Hide()
        end
        prompt:SetShown(want)
    end)
end

-- Key binding (Bindings.xml).
function RickQOL_ToggleQuestList()
    QuestList:Toggle()
end

function QuestList:OnLogin()
    if not R.modules.questdata.available then return end
    self:CreateWindow()
    self:AddTrackerButton()
    self:WatchTrackerFocus()
    table.insert(UISpecialFrames, "RickQOLQuestList")

    local events = CreateFrame("Frame")
    events:RegisterEvent("PLAYER_REGEN_DISABLED")
    events:SetScript("OnEvent", function() self:Close() end)
end

function QuestList:Slash()
    if self.frame then self:Toggle() end
end
