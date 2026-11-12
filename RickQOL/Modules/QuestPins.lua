-- World map pins for quests the player can pick up but hasn't.
--
-- Taint rules (Forever's map is driven by Blizzard's secure controller UI): pins are our own frames
-- on top of the map canvas, created at login only; we never register a data provider with the map
-- and only post-hook its methods with hooksecurefunc.
local _, R = ...

local QuestPins = R:RegisterModule("pins", { help = "on | off | trivial | events | nearest | debug | report [zone]" })

local MAX_PINS = 250
local PIN_SIZE = 18
local AVAILABLE_ATLAS = "QuestNormal"
local TRIVIAL_ATLAS = "TrivialQuests"
local FALLBACK_TEXTURE = "Interface\\GossipFrame\\AvailableQuestIcon"

local function SetIcon(texture, trivial)
    local atlas = trivial and TRIVIAL_ATLAS or AVAILABLE_ATLAS
    if C_Texture and C_Texture.GetAtlasInfo and C_Texture.GetAtlasInfo(atlas) then
        texture:SetAtlas(atlas)
        texture:SetDesaturated(false)
    else
        texture:SetTexture(FALLBACK_TEXTURE)
        texture:SetDesaturated(trivial)
    end
end

local function ShowTooltip(pin)
    local data = pin.data
    if not data then return end
    GameTooltip:SetOwner(pin, "ANCHOR_RIGHT")
    GameTooltip:AddLine(data.starter.name or "?", 1, 1, 1)
    for _, entry in ipairs(data.quests) do
        local level = R.modules.questdata:QuestField(entry.questID, "questLevel") or 0
        local color = GetQuestDifficultyColor and GetQuestDifficultyColor(level) or NORMAL_FONT_COLOR
        local prefix = level > 0 and ("[" .. level .. "] ") or ""
        GameTooltip:AddLine(prefix .. R.modules.questdata:Title(entry.questID), color.r, color.g, color.b)
    end
    GameTooltip:AddLine(" ")
    local hint = R.modules.pins:IsWaypointAt(data) and "Click: clear waypoint" or "Click: set waypoint"
    GameTooltip:AddLine(hint, 0.5, 0.8, 1)
    GameTooltip:Show()
end

function QuestPins:CreatePins()
    local canvas = WorldMapFrame:GetCanvas()
    local layer = CreateFrame("Frame", nil, canvas)
    layer:SetAllPoints(canvas)
    layer:SetFrameLevel(canvas:GetFrameLevel() + 500)
    self.layer = layer

    self.pins = {}
    for i = 1, MAX_PINS do
        local pin = CreateFrame("Frame", nil, layer)
        pin:SetSize(PIN_SIZE, PIN_SIZE)
        pin.icon = pin:CreateTexture(nil, "OVERLAY")
        pin.icon:SetAllPoints()
        pin:EnableMouse(true)
        pin:SetScript("OnMouseUp", function(frame, button)
            if button == "LeftButton" then QuestPins:ToggleWaypoint(frame.data) end
        end)
        pin:SetScript("OnEnter", ShowTooltip)
        pin:SetScript("OnLeave", GameTooltip_Hide)
        pin:Hide()
        self.pins[i] = pin
    end
end

function QuestPins:HideAll()
    for _, pin in ipairs(self.pins) do
        pin:Hide()
        pin.data = nil
    end
end

function QuestPins:Refresh()
    if not self.pins then return end
    self:HideAll()
    local data = R.modules.questdata
    local mapID = WorldMapFrame:GetMapID()
    self.lastRefresh = ("map %s: enabled=%s ready=%s shown=%s"):format(tostring(mapID),
        tostring(self.db.enabled), tostring(data.ready), tostring(WorldMapFrame:IsShown()))
    if not self.db.enabled or not data.ready or not WorldMapFrame:IsShown() then return end

    local spots = data:PinsForMap(mapID)
    if not spots then
        self.lastRefresh = self.lastRefresh .. " no giver spots for this map"
        return
    end

    local me = data:Snapshot()
    local canvas = WorldMapFrame:GetCanvas()
    local width, height = canvas:GetSize()
    local scale = 1 / (WorldMapFrame:GetCanvasScale() or 1)
    local used = 0

    for _, spot in ipairs(spots) do
        local quests, allTrivial = self:AvailableAt(spot, me)
        if quests then
            used = used + 1
            local pin = self.pins[used]
            if not pin then break end
            pin.data = { starter = spot.starter, quests = quests, mapID = mapID, x = spot.x, y = spot.y }
            SetIcon(pin.icon, allTrivial)
            pin:SetScale(scale)
            pin:ClearAllPoints()
            -- SetScale also scales the offset, so divide it back out.
            pin:SetPoint("CENTER", self.layer, "TOPLEFT", spot.x * width / scale, -spot.y * height / scale)
            pin:Show()
        end
    end
end

-- The quests the player can take from this spot's giver (nil when none), and whether all are grey.
-- Shared with the minimap pins.
function QuestPins:AvailableAt(spot, me)
    local data = R.modules.questdata
    local starter = spot.starter
    if starter.friendly and me.factionCode and not starter.friendly:find(me.factionCode, 1, true) then
        return nil
    end
    local quests, allTrivial = {}, true
    for _, questID in ipairs(starter.quests) do
        local ok, trivial = data:IsAvailable(questID, me)
        if ok and (not self.db.hideTrivial or not trivial) then
            quests[#quests + 1] = { questID = questID, trivial = trivial }
            allTrivial = allTrivial and trivial
        end
    end
    if #quests == 0 then return nil end
    return quests, allTrivial
end

----------------------------------------------------------------------------
-- Waypoints: Blizzard's own user waypoint (map pin, distance and guide arrow)
----------------------------------------------------------------------------

-- data = { mapID, x, y, starter, quests } from a pin.
function QuestPins:IsWaypointAt(data)
    local point = C_Map.GetUserWaypoint and C_Map.GetUserWaypoint()
    if not (point and data and data.mapID == point.uiMapID) then return false end
    local x, y = point.position:GetXY()
    return math.abs(x - data.x) < 0.001 and math.abs(y - data.y) < 0.001
end

function QuestPins:SetWaypoint(data)
    if not C_Map.CanSetUserWaypointOnMap(data.mapID) then
        R:Print("waypoints can't be placed on this map.")
        return
    end
    C_Map.SetUserWaypoint(UiMapPoint.CreateFromCoordinates(data.mapID, data.x, data.y))
    C_SuperTrack.SetSuperTrackedUserWaypoint(true)
    local first = data.quests[1]
    local quest = first and R.modules.questdata:Title(first.questID) or ""
    local more = #data.quests > 1 and (" (+%d more)"):format(#data.quests - 1) or ""
    R:Print(("waypoint set: %s — %s%s"):format(data.starter.name or "?", quest, more))
end

function QuestPins:ToggleWaypoint(data)
    if not data then return end
    if self:IsWaypointAt(data) then
        C_Map.ClearUserWaypoint()
        R:Print("waypoint cleared.")
    else
        self:SetWaypoint(data)
    end
    if GameTooltip:IsShown() then GameTooltip:Hide() end
end

-- Returns the report as lines; prints it too unless silent (used when saving it on logout).
function QuestPins:Debug(silent)
    local data = R.modules.questdata
    local lines = {}
    local out = function(...)
        local parts = {}
        for i = 1, select("#", ...) do parts[#parts + 1] = tostring((select(i, ...))) end
        lines[#lines + 1] = table.concat(parts, " ")
        if not silent then print("  ", ...) end
    end
    if not silent then R:Print("quest pins debug") end
    out("last world map refresh:", self.lastRefresh or "never ran")
    out("enabled:", tostring(self.db.enabled), " QuestieDB:", data.available and "ok" or (data.problem or "not loaded"))
    if not data.available then return lines end
    local maps = 0
    for _ in pairs(data.byMap or {}) do maps = maps + 1 end
    local starters = 0
    for _ in pairs(data.starters or {}) do starters = starters + 1 end
    out("index ready:", tostring(data.ready), " quests:", data.questCount or 0, " with givers:", data.starterQuestCount or 0,
        " givers:", starters, " maps:", maps)
    out("world map:", self.pins and "hooked" or "NOT hooked", " shown:", tostring(WorldMapFrame and WorldMapFrame:IsShown()))

    local mapID = (WorldMapFrame and WorldMapFrame:IsShown() and WorldMapFrame:GetMapID()) or C_Map.GetBestMapForUnit("player")
    local info = mapID and C_Map.GetMapInfo(mapID)
    local spots = mapID and data:PinsForMap(mapID) or {}
    local available = 0
    if data.ready then
        local ok, err = pcall(function()
            local me = data:Snapshot()
            for _, spot in ipairs(spots) do
                if self:AvailableAt(spot, me) then available = available + 1 end
            end
        end)
        if not ok then out("filter error:", tostring(err)) end
    end
    out("map:", tostring(mapID), info and info.name or "?", " giver spots:", #spots, " with available quests:", available)

    -- Every quest given on this map, and why the hidden ones are hidden.
    if data.ready then
        local ok, err = pcall(function()
            local me = data:Snapshot()
            local seen, total, shownQuests, wrongFaction = {}, 0, 0, 0
            local tally = {}
            for _, spot in ipairs(spots) do
                local starter = spot.starter
                local hostile = starter.friendly and me.factionCode and not starter.friendly:find(me.factionCode, 1, true)
                for _, questID in ipairs(starter.quests) do
                    if not seen[questID] then
                        seen[questID] = true
                        total = total + 1
                        if hostile then
                            wrongFaction = wrongFaction + 1
                        elseif data:IsAvailable(questID, me) then
                            shownQuests = shownQuests + 1
                        else
                            local reason = me.reasons[questID] or "?"
                            tally[reason] = (tally[reason] or 0) + 1
                        end
                    end
                end
            end
            out("quests given on this map:", total, " shown:", shownQuests, " other faction:", wrongFaction)
            for reason, count in pairs(tally) do out("  hidden, " .. reason .. ":", count) end
        end)
        if not ok then out("count error:", tostring(err)) end
    end
    local shown = 0
    for _, pin in ipairs(self.pins or {}) do
        if pin:IsShown() then shown = shown + 1 end
    end
    out("pins on world map now:", shown)
    out("errors:", data.errorCount or 0)
    for where, err in pairs(data.errors or {}) do out(where .. ":", err) end
    return lines
end

-- Find a zone map by ID or (part of its) name; defaults to the player's zone.
local function FindMap(query)
    if not query or query == "" then return C_Map.GetBestMapForUnit("player") end
    local id = tonumber(query)
    if id then return id end
    local data = R.modules.questdata
    for mapID in pairs(data.byMap or {}) do
        local info = C_Map.GetMapInfo(mapID)
        if info and info.name and info.name:lower() == query then return mapID end
    end
    for mapID in pairs(data.byMap or {}) do
        local info = C_Map.GetMapInfo(mapID)
        if info and info.name and info.name:lower():find(query, 1, true) then return mapID end
    end
end

-- Every quest given on a map with its status, saved to RickQOLDB.report (on disk after /reload).
function QuestPins:Report(query)
    local data = R.modules.questdata
    if not data.ready then
        R:Print("quest data is still loading; try again in a few seconds.")
        return
    end
    local mapID = FindMap(query)
    local info = mapID and C_Map.GetMapInfo(mapID)
    if not info then
        R:Print("no zone found for '" .. tostring(query) .. "'.")
        return
    end

    local me = data:Snapshot()
    local rows, seen, counts = {}, {}, {}
    for _, spot in ipairs(data:PinsForMap(mapID) or {}) do
        local starter = spot.starter
        local hostile = starter.friendly and me.factionCode and not starter.friendly:find(me.factionCode, 1, true)
        for _, questID in ipairs(starter.quests) do
            if not seen[questID] then
                seen[questID] = true
                local status
                if hostile then
                    status = "other faction"
                else
                    local ok, trivial = data:IsAvailable(questID, me)
                    status = ok and (trivial and "PENDING (grey)" or "PENDING") or (me.reasons[questID] or "?")
                end
                counts[status] = (counts[status] or 0) + 1
                rows[#rows + 1] = {
                    status = status, id = questID,
                    text = ("[%d] %s (lvl %s, req %s) - %s @ %.1f,%.1f - %s"):format(questID, data:Title(questID),
                        tostring(data:QuestField(questID, "questLevel")), tostring(data:QuestField(questID, "requiredLevel")),
                        starter.name or "?", spot.x * 100, spot.y * 100, status),
                }
            end
        end
    end
    table.sort(rows, function(a, b)
        if a.status ~= b.status then return a.status < b.status end
        return a.id < b.id
    end)

    local lines = {}
    for _, row in ipairs(rows) do lines[#lines + 1] = row.text end
    R.db.report = {
        zone = info.name, mapID = mapID, level = me.level, made = date("%Y-%m-%d %H:%M"),
        counts = counts, quests = lines,
    }
    R:Print(("%s: %d quests given here."):format(info.name, #rows))
    for status, count in pairs(counts) do print("  ", status .. ":", count) end
    R:Print("full list saved; /reload to write it to disk.")
end

QuestPins.SetIcon = SetIcon
QuestPins.ShowTooltip = ShowTooltip

function QuestPins:OnLogin(db)
    self.db = db
    local data = R.modules.questdata

    -- Keep the last debug report in the saved settings, so it can be read from disk.
    local logout = CreateFrame("Frame")
    logout:RegisterEvent("PLAYER_LOGOUT")
    logout:SetScript("OnEvent", function()
        local ok, lines = pcall(self.Debug, self, true)
        R.db.debug = ok and lines or { "debug failed: " .. tostring(lines) }
    end)

    if not data.available then return end

    local function Setup()
        if self.pins then return end
        self:CreatePins()
        local refresh = function()
            local ok, err = pcall(self.Refresh, self)
            if not ok then
                data:NoteError("refresh", err)
                if not self.reported then
                    self.reported = true
                    R:Print("quest pins hit an error; /rqol pins debug shows it.")
                end
            end
        end
        hooksecurefunc(WorldMapFrame, "OnMapChanged", refresh)
        hooksecurefunc(WorldMapFrame, "OnCanvasScaleChanged", refresh)
        WorldMapFrame:HookScript("OnShow", refresh)
        data:OnReady(refresh)
    end
    if WorldMapFrame then
        Setup()
    else
        EventUtil.ContinueOnAddOnLoaded("Blizzard_WorldMap", Setup)
    end

    -- Quest state changes what's available.
    local events = CreateFrame("Frame")
    for _, event in ipairs({ "QUEST_ACCEPTED", "QUEST_TURNED_IN", "QUEST_REMOVED", "PLAYER_LEVEL_UP", "SKILL_LINES_CHANGED" }) do
        events:RegisterEvent(event)
    end
    events:SetScript("OnEvent", function()
        if WorldMapFrame and WorldMapFrame:IsShown() then
            -- Completion flags update a moment after the event.
            C_Timer.After(0.5, function() self:Refresh() end)
        end
    end)
end

function QuestPins:Slash(args)
    if args == "on" or args == "off" then
        self.db.enabled = args == "on"
    elseif args == "trivial" then
        self.db.hideTrivial = not self.db.hideTrivial
    elseif args == "events" then
        self.db.showWorldEvents = not self.db.showWorldEvents
        R:Print("Scourge Invasion / Ahn'Qiraj War Effort quests " .. (self.db.showWorldEvents and "shown" or "hidden"))
    elseif args:find("^report") then
        self:Report(args:match("^report%s*(.-)$"))
        return
    elseif args == "debug" then
        self:Debug()
        return
    elseif args == "nearest" then
        R.modules.minimap:WaypointNearest()
        return
    end
    R:Print(("quest pins %s, low-level quests %s"):format(
        self.db.enabled and "on" or "off", self.db.hideTrivial and "hidden" or "shown"))
    self:Refresh()
    R.modules.minimap:Rebuild()
end
