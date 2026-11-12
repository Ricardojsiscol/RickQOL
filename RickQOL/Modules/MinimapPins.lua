-- Minimap pins for available quests in the player's current zone. Uses the same filter as the
-- world map pins (QuestPins:AvailableAt). Pins are our own frames on the Minimap, made at login.
local _, R = ...

local MinimapPins = R:RegisterModule("minimap", {})

local MAX_PINS = 60
local PIN_SIZE = 14
local UPDATE_INTERVAL = 0.05

-- Minimap diameter in yards for each zoom level (0-5), indoors and outdoors.
local DIAMETER = {
    indoor = { [0] = 300, 240, 180, 120, 80, 50 },
    outdoor = { [0] = 466 + 2 / 3, 400, 333 + 1 / 3, 266 + 2 / 3, 200, 133 + 1 / 3 },
}

function MinimapPins:CreatePins()
    self.pins = {}
    for i = 1, MAX_PINS do
        local pin = CreateFrame("Frame", nil, Minimap)
        pin:SetSize(PIN_SIZE, PIN_SIZE)
        pin:SetFrameLevel(Minimap:GetFrameLevel() + 5)
        pin.icon = pin:CreateTexture(nil, "OVERLAY")
        pin.icon:SetAllPoints()
        pin:EnableMouse(true)
        pin:SetScript("OnMouseUp", function(frame, button)
            if button == "LeftButton" then R.modules.pins:ToggleWaypoint(frame.data) end
        end)
        pin:SetScript("OnEnter", R.modules.pins.ShowTooltip)
        pin:SetScript("OnLeave", GameTooltip_Hide)
        pin:Hide()
        self.pins[i] = pin
    end
end

-- Recompute which givers in the current zone have quests for the player. Cheap enough to run on
-- zone and quest changes; positions are updated separately every frame.
function MinimapPins:Rebuild()
    self.active = {}
    for _, pin in ipairs(self.pins or {}) do pin:Hide() end

    local data, pins = R.modules.questdata, R.modules.pins
    if not (self.pins and data.ready and pins.db.enabled) then return end

    local mapID = C_Map.GetBestMapForUnit("player")
    local spots = mapID and data:PinsForMap(mapID)
    if not spots then return end

    self.mapID = mapID
    self.mapWidth, self.mapHeight = C_Map.GetMapWorldSize(mapID)
    if not self.mapWidth or self.mapWidth == 0 then return end

    local me = data:Snapshot()
    for _, spot in ipairs(spots) do
        local quests, allTrivial = pins:AvailableAt(spot, me)
        if quests then
            local pin = self.pins[#self.active + 1]
            if not pin then break end
            pin.data = { starter = spot.starter, quests = quests, mapID = mapID, x = spot.x, y = spot.y }
            pins.SetIcon(pin.icon, allTrivial)
            self.active[#self.active + 1] = { pin = pin, x = spot.x, y = spot.y }
        end
    end
    self:UpdatePositions()
end

function MinimapPins:UpdatePositions()
    if not self.active or #self.active == 0 then return end
    local position = C_Map.GetPlayerMapPosition(self.mapID, "player")
    if not position then
        for _, entry in ipairs(self.active) do entry.pin:Hide() end
        return
    end
    local px, py = position:GetXY()

    local zoom = Minimap:GetZoom()
    local diameter = (IsIndoors() and DIAMETER.indoor or DIAMETER.outdoor)[zoom] or DIAMETER.outdoor[0]
    local radius = diameter / 2
    local pixelsPerYard = Minimap:GetWidth() / diameter

    -- With "Rotate Minimap" on, the map turns so the player's facing points up.
    local angle = 0
    if GetCVar("rotateMinimap") == "1" then angle = -(GetPlayerFacing() or 0) end
    local cosA, sinA = math.cos(angle), math.sin(angle)

    for _, entry in ipairs(self.active) do
        -- Offset in yards: east is +x; map y grows south, so north is -y.
        local east = (entry.x - px) * self.mapWidth
        local north = -(entry.y - py) * self.mapHeight
        if east * east + north * north > radius * radius then
            entry.pin:Hide()
        else
            local x = east * cosA - north * sinA
            local y = east * sinA + north * cosA
            entry.pin:ClearAllPoints()
            entry.pin:SetPoint("CENTER", Minimap, "CENTER", x * pixelsPerYard, y * pixelsPerYard)
            entry.pin:Show()
        end
    end
end

-- Waypoint to the closest giver in this zone with a quest the player can take.
function MinimapPins:WaypointNearest()
    local position = self.mapID and C_Map.GetPlayerMapPosition(self.mapID, "player")
    if not (position and self.active and #self.active > 0) then
        R:Print("no pending quests found in this zone.")
        return
    end
    local px, py = position:GetXY()
    local best, bestDistance
    for _, entry in ipairs(self.active) do
        local dx = (entry.x - px) * self.mapWidth
        local dy = (entry.y - py) * self.mapHeight
        local distance = dx * dx + dy * dy
        if not bestDistance or distance < bestDistance then
            best, bestDistance = entry, distance
        end
    end
    R.modules.pins:SetWaypoint(best.pin.data)
end

-- Key binding (Bindings.xml): Options > Keybindings > RickQOL.
function RickQOL_WaypointNearestQuest()
    MinimapPins:WaypointNearest()
end

function MinimapPins:OnLogin()
    local data = R.modules.questdata
    if not data.available then return end
    self:CreatePins()

    local rebuild = function() self:Rebuild() end
    data:OnReady(rebuild)

    local events = CreateFrame("Frame")
    for _, event in ipairs({ "ZONE_CHANGED_NEW_AREA", "ZONE_CHANGED", "ZONE_CHANGED_INDOORS",
        "QUEST_ACCEPTED", "QUEST_TURNED_IN", "QUEST_REMOVED", "PLAYER_LEVEL_UP", "SKILL_LINES_CHANGED" }) do
        events:RegisterEvent(event)
    end
    -- Completion flags update a moment after the quest events.
    events:SetScript("OnEvent", function() C_Timer.After(0.5, rebuild) end)

    local elapsed = 0
    events:SetScript("OnUpdate", function(_, delta)
        elapsed = elapsed + delta
        if elapsed < UPDATE_INTERVAL then return end
        elapsed = 0
        self:UpdatePositions()
    end)
end
