-- A small bar showing the player's threat on the current target.
-- On Forever some combat values are "secret" (displayable, not comparable); bosses hide threat
-- numbers entirely. When the percentage is secret the bar falls back to the threat status only.
local _, R = ...

local Threat = R:RegisterModule("threat", { help = "on | off | unlock | lock | reset" })

local WIDTH, HEIGHT = 195, 13 -- Blizzard's timer bar size
local STATUS_TEXT = { [0] = "Safe", [1] = "Pulling aggro", [2] = "Losing aggro", [3] = "Tanking" }

local IsSecret = issecretvalue or function() return false end

local function Usable(...)
    for i = 1, select("#", ...) do
        if IsSecret((select(i, ...))) then return false end
    end
    return true
end

function Threat:CreateBar()
    -- Same art as Blizzard's cast bar and breath/fatigue timers (MirrorTimerTemplate).
    local bar = CreateFrame("StatusBar", "RickQOLThreatBar", UIParent)
    bar:SetSize(WIDTH, HEIGHT)
    bar:SetStatusBarTexture("ui-castingbar-filling-standard")
    -- The fill art is yellow; desaturate it so the threat status color shows true.
    bar:GetStatusBarTexture():SetDesaturated(true)
    bar:SetMinMaxValues(0, 100)

    local background = bar:CreateTexture(nil, "BACKGROUND")
    background:SetAtlas("ui-castingbar-background")
    background:SetPoint("TOPLEFT", -1, 1)
    background:SetPoint("BOTTOMRIGHT", 1, -1)

    local border = bar:CreateTexture(nil, "OVERLAY", nil, 0)
    border:SetAtlas("ui-castingbar-frame")
    border:SetPoint("TOPLEFT", -2, 2)
    border:SetPoint("BOTTOMRIGHT", 2, -2)

    bar.text = bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    bar.text:SetDrawLayer("OVERLAY", 7) -- above the border
    bar.text:SetPoint("CENTER")

    bar:SetMovable(true)
    bar:SetClampedToScreen(true)
    bar:RegisterForDrag("LeftButton")
    bar:SetScript("OnDragStart", bar.StartMoving)
    bar:SetScript("OnDragStop", function(frame)
        frame:StopMovingOrSizing()
        local point, _, relPoint, x, y = frame:GetPoint()
        self.db.point = { point, relPoint, x, y }
    end)
    bar:Hide()
    self.bar = bar
    self:ApplyPosition()
end

function Threat:ApplyPosition()
    local p = self.db.point
    self.bar:ClearAllPoints()
    self.bar:SetPoint(p[1], UIParent, p[2], p[3], p[4])
end

function Threat:SetColor(status)
    if status and Usable(status) and GetThreatStatusColor then
        self.bar:SetStatusBarColor(GetThreatStatusColor(status))
    else
        self.bar:SetStatusBarColor(0.5, 0.5, 0.5)
    end
end

function Threat:Update()
    local bar = self.bar
    if not self.db.locked then
        bar:SetValue(100)
        bar:SetStatusBarColor(0.2, 0.6, 1)
        bar.text:SetText("RickQOL threat — drag me")
        bar:Show()
        return
    end
    if not self.db.enabled or not UnitExists("target") or not UnitCanAttack("player", "target") then
        bar:Hide()
        return
    end

    local _, status, scaledPct = UnitDetailedThreatSituation("player", "target")
    if status == nil then
        -- Not on the target's threat list (not fighting it).
        bar:Hide()
        return
    end

    self:SetColor(status)
    if scaledPct and Usable(scaledPct) then
        bar:SetValue(scaledPct)
        bar.text:SetFormattedText("Threat %d%%", scaledPct)
    elseif Usable(status) then
        bar:SetValue(100)
        bar.text:SetText(STATUS_TEXT[status] or "Threat")
    else
        bar:SetValue(0)
        bar.text:SetText("Threat unavailable")
    end
    bar:Show()
end

function Threat:OnLogin(db)
    self.db = db
    db.locked = true -- always start locked; unlocking is a per-session action
    self:CreateBar()
    local frame = CreateFrame("Frame")
    for _, event in ipairs({
        "PLAYER_TARGET_CHANGED", "UNIT_THREAT_LIST_UPDATE", "UNIT_THREAT_SITUATION_UPDATE",
        "PLAYER_REGEN_DISABLED", "PLAYER_REGEN_ENABLED",
    }) do
        frame:RegisterEvent(event)
    end
    frame:SetScript("OnEvent", function() self:Update() end)
end

function Threat:SetLocked(locked)
    if InCombatLockdown() then
        R:Print("can't move the threat bar in combat.")
        return
    end
    self.db.locked = locked
    self.bar:EnableMouse(not locked)
    self:Update()
end

function Threat:Slash(args)
    if args == "on" or args == "off" then
        self.db.enabled = args == "on"
        R:Print("threat bar is " .. (self.db.enabled and "on" or "off"))
    elseif args == "unlock" then
        self:SetLocked(false)
        R:Print("drag the bar, then /rqol threat lock")
    elseif args == "lock" then
        self:SetLocked(true)
    elseif args == "reset" then
        self.db.point = { "CENTER", "CENTER", 0, -180 }
        self:ApplyPosition()
    else
        R:Print("/rqol threat " .. self.help)
    end
    self:Update()
end
