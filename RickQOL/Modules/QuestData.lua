-- Quest data from QuestieDB: which quest givers stand on which map, and whether the player can
-- take a quest right now. QuestieDB is optional; without it this module stays unavailable.
local _, R = ...

local QuestData = R:RegisterModule("questdata", {})
QuestData.available = false

local CONTRACT = 4 -- QuestieDB public API version this code was written against
local PER_FRAME = 150 -- quests indexed per frame, so login doesn't stall

-- QuestieDB keeps zone tables as "return {...}" source strings.
local function Decode(source)
    if type(source) == "table" then return source end
    if type(source) ~= "string" then return {} end
    local chunk = loadstring(source)
    local ok, result = pcall(chunk or error)
    return ok and type(result) == "table" and result or {}
end

local function Merge(base, overrides)
    local result = {}
    for k, v in pairs(base) do result[k] = v end
    for k, v in pairs(overrides) do result[k] = v end
    return result
end

function QuestData:LoadZones()
    local ok, zoneDB = pcall(self.lib.Support.Get, "ZoneDB")
    local private = ok and type(zoneDB) == "table" and zoneDB.private or {}
    self.areaToMap = Merge(Decode(private.areaIdToUiMapId), Decode(private.areaIdToUiMapIdOverride))
    self.subZoneParent = Merge(Decode(private.subZoneToParentZone), Decode(private.subZoneToParentZoneOverride))
end

-- QuestieDB area ID -> the game's uiMapID, walking up sub-zones (e.g. a town to its zone).
function QuestData:UiMapFor(areaID)
    for _ = 1, 8 do
        local mapID = self.areaToMap[areaID]
        if mapID == 0 then return nil end
        if type(mapID) == "number" then return mapID end
        areaID = self.subZoneParent[areaID]
        if not areaID then return nil end
    end
end

-- Most QuestieDB points use Classic Era coordinates. A few zones were redrawn for Forever, and
-- QuestieDB provides the conversion; points that come from Forever corrections are already right.
local REDRAWN_AREAS = { [215] = true, [139] = true, [44] = true, [1519] = true }

function QuestData:ToForever(kind, id, areaID, x, y)
    if not REDRAWN_AREAS[areaID] or not self.lib.EraToForever then return x, y end
    local ok, owner = pcall(self.lib.GetProvenance, kind, id, "spawns")
    if ok and type(owner) == "string" and owner:lower():find("forever") then return x, y end
    return self.lib.EraToForever(areaID, x, y)
end

----------------------------------------------------------------------------
-- Index: uiMapID -> list of { kind, id, name, x, y, quests }
----------------------------------------------------------------------------

function QuestData:AddStarter(kind, id, questID)
    local key = kind .. id
    local starter = self.starters[key]
    if starter then
        starter.quests[#starter.quests + 1] = questID
        return
    end
    local entity = kind == "Npc" and self.lib.Npc or self.lib.Object
    starter = { kind = kind, id = id, name = entity.Get(id, "name"), quests = { questID } }
    if kind == "Npc" then starter.friendly = entity.Get(id, "friendlyToFaction") end
    self.starters[key] = starter

    local spawns = entity.Get(id, "spawns")
    if type(spawns) ~= "table" then return end
    for areaID, points in pairs(spawns) do
        local mapID = self:UiMapFor(areaID)
        if mapID then
            for _, point in ipairs(points) do
                local x, y = point[1], point[2]
                if x and y and x >= 0 and y >= 0 then
                    x, y = self:ToForever(kind, id, areaID, x, y)
                    local list = self.byMap[mapID]
                    if not list then
                        list = {}
                        self.byMap[mapID] = list
                    end
                    list[#list + 1] = { starter = starter, x = x / 100, y = y / 100 }
                end
            end
        end
    end
end

-- Keeps the first error of each kind so /rqol pins debug can show it.
function QuestData:NoteError(where, err)
    self.errors = self.errors or {}
    self.errorCount = (self.errorCount or 0) + 1
    if not self.errors[where] then self.errors[where] = tostring(err) end
end

function QuestData:BuildIndex()
    self.starters, self.byMap = {}, {}
    self.questCount, self.starterQuestCount = 0, 0
    local okIds, ids = pcall(self.lib.Quest.GetAllIds, false)
    if not okIds then
        self:NoteError("GetAllIds", ids)
        ids = {}
    end
    ids = ids or {}
    local index = 0
    local worker = CreateFrame("Frame")
    worker:SetScript("OnUpdate", function(frame)
        for _ = 1, PER_FRAME do
            index = index + 1
            local questID = ids[index]
            if not questID then
                frame:SetScript("OnUpdate", nil)
                self.ready = true
                for _, callback in ipairs(self.readyCallbacks) do callback() end
                return
            end
            self.questCount = self.questCount + 1
            local ok, startedBy = pcall(self.lib.Quest.Get, questID, "startedBy")
            if not ok then
                self:NoteError("startedBy", startedBy)
            elseif type(startedBy) == "table" then
                if startedBy[1] or startedBy[2] then self.starterQuestCount = self.starterQuestCount + 1 end
                for _, npcID in ipairs(startedBy[1] or {}) do
                    local okAdd, err = pcall(self.AddStarter, self, "Npc", npcID, questID)
                    if not okAdd then self:NoteError("npc", err) end
                end
                for _, objectID in ipairs(startedBy[2] or {}) do
                    local okAdd, err = pcall(self.AddStarter, self, "Object", objectID, questID)
                    if not okAdd then self:NoteError("object", err) end
                end
            end
        end
    end)
end

-- Runs callback once the index is built (right away if it already is).
QuestData.readyCallbacks = {}
function QuestData:OnReady(callback)
    if self.ready then callback() end
    self.readyCallbacks[#self.readyCallbacks + 1] = callback
end

function QuestData:PinsForMap(mapID)
    return self.byMap and self.byMap[mapID]
end

----------------------------------------------------------------------------
-- Holidays: festival quests only count while their festival is on the calendar
----------------------------------------------------------------------------

-- QuestieDB quest sort (negative zoneOrSort) -> words found in the calendar's holiday titles.
-- Titles are matched in English, so other client languages treat festivals as never active.
local HOLIDAY_SORTS = {
    [-366] = { "lunar festival" },
    [-369] = { "midsummer" },
    [-370] = { "brewfest" },
    [-21] = { "hallow" },
    [-374] = { "noblegarden" },
    [-378] = { "children" },
    [-376] = { "love is in the air" },
    [-375] = { "pilgrim" },
    [-364] = { "darkmoon" },
    [-404] = { "winter veil" },
    [-402] = { "harvest festival" },
    [-41] = { "day of the dead" },
    [-22] = { "winter veil", "harvest festival" }, -- the generic "Seasonal" sort
}

-- World events the calendar doesn't announce; their quest givers only appear while they run.
-- Hidden unless "/rqol pins events" turns them on.
local WORLD_EVENT_SORTS = {
    [-368] = "Scourge Invasion",
    [-365] = "Ahn'Qiraj War Effort",
}

function QuestData:ReadCalendar()
    local titles = {}
    local ok = pcall(function()
        local today = C_DateAndTime.GetCurrentCalendarTime()
        for i = 1, C_Calendar.GetNumDayEvents(0, today.monthDay) do
            local event = C_Calendar.GetDayEvent(0, today.monthDay, i)
            if event and event.calendarType == "HOLIDAY" and event.title then
                titles[#titles + 1] = event.title:lower()
            end
        end
    end)
    self.holidayTitles = ok and titles or {}
end

function QuestData:IsHolidayActive(sort)
    for _, word in ipairs(HOLIDAY_SORTS[sort]) do
        for _, title in ipairs(self.holidayTitles or {}) do
            if title:find(word, 1, true) then return true end
        end
    end
    return false
end

function QuestData:WatchCalendar()
    local frame = CreateFrame("Frame")
    frame:RegisterEvent("CALENDAR_UPDATE_EVENT_LIST")
    frame:SetScript("OnEvent", function()
        self:ReadCalendar()
        -- Redraw pins now that festivals are known.
        if self.ready then
            for _, callback in ipairs(self.readyCallbacks) do callback() end
        end
    end)
    -- The calendar has no data until it's opened once; re-check every hour for festivals starting.
    pcall(C_Calendar.OpenCalendar)
    C_Timer.NewTicker(3600, function() pcall(C_Calendar.OpenCalendar) end)
end

----------------------------------------------------------------------------
-- Availability
----------------------------------------------------------------------------

-- Facts about the player, gathered once per redraw.
function QuestData:Snapshot()
    local _, _, raceID = UnitRace("player")
    local _, _, classID = UnitClass("player")
    local faction = UnitFactionGroup("player")
    local enum = self.lib.Enum or {}
    local raceMasks = enum.raceMaskById or {}
    local skills = {}
    if GetProfessions then
        for _, index in pairs({ GetProfessions() }) do
            local _, _, rank, _, _, _, skillLine = GetProfessionInfo(index)
            if skillLine then skills[skillLine] = rank end
        end
    end
    local level = UnitLevel("player")
    local trivialRange = (UnitQuestTrivialLevelRange and UnitQuestTrivialLevelRange("player"))
        or (GetQuestGreenRange and GetQuestGreenRange()) or 8
    return {
        level = level,
        trivialBelow = level - trivialRange,
        raceMask = raceMasks[raceID] or (raceID and 2 ^ (raceID - 1)) or 0,
        classMask = classID and 2 ^ (classID - 1) or 0,
        factionCode = faction == "Horde" and "H" or faction == "Alliance" and "A" or nil,
        skills = skills,
        cache = {},
        reasons = {},
        showWorldEvents = R.db.pins and R.db.pins.showWorldEvents or false,
    }
end

local function Done(questID)
    return C_QuestLog.IsQuestFlaggedCompleted(questID)
end

local function InLog(questID)
    return C_QuestLog.GetLogIndexForQuestID(questID) ~= nil
end

local function AnyDoneOrActive(list)
    for _, id in ipairs(list or {}) do
        if Done(id) or InLog(id) then return true end
    end
    return false
end

function QuestData:QuestField(questID, field)
    local ok, value = pcall(self.lib.Quest.Get, questID, field)
    return ok and value or nil
end

-- True when the player could pick this quest up now. Second result: the quest is trivial (grey).
function QuestData:IsAvailable(questID, me)
    local cached = me.cache[questID]
    if cached ~= nil then return cached, me.cache[-questID] end

    -- reason says why a quest is hidden (shown by /rqol pins debug).
    local function Result(ok, trivial, reason)
        me.cache[questID], me.cache[-questID] = ok, trivial
        me.reasons[questID] = reason
        return ok, trivial
    end

    if Done(questID) then return Result(false, nil, "completed") end
    if InLog(questID) then return Result(false, nil, "in quest log") end
    local q = function(field) return self:QuestField(questID, field) end

    local races = q("requiredRaces")
    if races and races ~= 0 and bit.band(races, me.raceMask) == 0 then return Result(false, nil, "other race") end
    local classes = q("requiredClasses")
    if classes and classes ~= 0 and bit.band(classes, me.classMask) == 0 then return Result(false, nil, "other class") end

    local sort = q("zoneOrSort")
    if sort and HOLIDAY_SORTS[sort] and not self:IsHolidayActive(sort) then
        return Result(false, nil, "festival not active")
    end
    if sort and WORLD_EVENT_SORTS[sort] and not me.showWorldEvents then
        return Result(false, nil, "world event: " .. WORLD_EVENT_SORTS[sort])
    end
    -- Quests with no level at all are system/mail quests, not something an NPC offers.
    if (q("questLevel") or 0) == 0 and (q("requiredLevel") or 0) == 0 then
        return Result(false, nil, "system quest")
    end

    if (q("requiredLevel") or 0) > me.level then return Result(false, nil, "level too low") end
    local maxLevel = q("requiredMaxLevel")
    if maxLevel and maxLevel > 0 and me.level > maxLevel then return Result(false, nil, "level too high") end

    local skill = q("requiredSkill")
    if type(skill) == "table" and skill[1] and (me.skills[skill[1]] or -1) < (skill[2] or 0) then
        return Result(false, nil, "needs profession")
    end

    for _, id in ipairs(q("preQuestGroup") or {}) do
        if not Done(id) then return Result(false, nil, "earlier quest not done") end
    end
    local single = q("preQuestSingle")
    if type(single) == "table" and #single > 0 then
        local any = false
        for _, id in ipairs(single) do
            if Done(id) then any = true break end
        end
        if not any then return Result(false, nil, "earlier quest not done") end
    end

    if AnyDoneOrActive(q("exclusiveTo")) then return Result(false, nil, "alternative quest taken") end
    local breadcrumbFor = q("breadcrumbForQuestId")
    if breadcrumbFor and breadcrumbFor ~= 0 and (Done(breadcrumbFor) or InLog(breadcrumbFor)) then
        return Result(false, nil, "breadcrumb no longer needed")
    end

    local questLevel = q("questLevel") or 0
    return Result(true, questLevel > 0 and questLevel < me.trivialBelow)
end

-- The quest's title in the player's language when the game knows it, else QuestieDB's.
function QuestData:Title(questID)
    local title = C_QuestLog.GetTitleForQuestID and C_QuestLog.GetTitleForQuestID(questID)
    if title and title ~= "" then return title end
    return self:QuestField(questID, "name") or ("Quest " .. questID)
end

function QuestData:OnLogin()
    local lib = _G.LibQuestieDB
    if type(lib) ~= "table" or type(lib.RequireContract) ~= "function" then
        self.problem = "QuestieDB not found"
        R:Print("QuestieDB not found; quest map pins are disabled.")
        return
    end
    local ok, compatible, message = pcall(lib.RequireContract, CONTRACT)
    if not ok or not compatible then
        self.problem = "incompatible QuestieDB: " .. tostring(message or compatible)
        R:Print("incompatible QuestieDB (" .. tostring(message or compatible) .. "); quest map pins are disabled.")
        return
    end
    self.lib = lib
    self.available = true
    self:LoadZones()
    self:WatchCalendar()
    self:BuildIndex()
end
