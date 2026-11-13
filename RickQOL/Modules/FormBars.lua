-- Form bars: while you're in a form or stance (Druid forms, Warrior stances, Rogue stealth, Shadowform)
-- the controller buttons drive RickQOL's bar with that form's own page, and Blizzard's controller bars
-- fade out. In caster form (and for classes without forms) Blizzard's bars are untouched.
--
-- How it stays combat-safe (verified in-game with a probe, 2026-11-12):
--   * A secure state driver watches [bonusbar:n]. Its handler runs in the game's restricted
--     environment, so in combat it can still point our buttons at the form's action slots, take the
--     controller keys with override bindings and fade Blizzard's bar. Leaving the form clears our
--     bindings, which hands every key back to Blizzard.
--   * Each form's page lives in action slots the controller UI never shows (keyboard pages 2-6 and
--     11-15), reserved per character. Moving actions in combat is blocked, so slots are fixed up front.
--   * Never call into Blizzard's gamepad UI: we only read its frames' positions and fade its alpha
--     from the secure handler.
--
-- Positions follow Blizzard's page layout: top 1-8, left/LT 9-16, right/RT 17-24, bottom/LT+RT 25-32.
-- In each group 1-4 are the D-pad (left, up, right, down) and 5-8 the face buttons (X, Y, B, A).
-- Top group 5-8 are Blizzard's (jump, back, ...), so a form page has 28 buttons.
--
-- Groups: LT and RT are Blizzard bindings (GAMEPADLEFTMOD/RIGHTMOD), not Shift/Ctrl, so macro
-- conditions can't see them. While in a form we take LT/RT too, track them in the secure handler and
-- rebind the 8 keys to the held group. With nothing held the D-pad is ours and the face buttons click
-- Blizzard's own top-group buttons (interact, inspect, back, jump) directly: Blizzard never sees our
-- LT/RT releases, so letting the keys fall through would hit whichever group it last thought active.
local _, R = ...

local FormBars = R:RegisterModule("formbars", { help = "on | off | status | dump | reseed" })

local MAX_FORMS = 4 -- [bonusbar:1..4]
local POSITIONS = 32
local RESERVED = { [5] = true, [6] = true, [7] = true, [8] = true }
-- Action slots a controller player never sees: keyboard pages 2-6, 11 and 13-15. Page 12 (133-144) is
-- the totem bar ("Only Water Totem spells may be placed in this slot"), so it's left out.
local POOL = { { 13, 72 }, { 121, 132 }, { 145, 180 } }
local GAMEPAD_FORM_FIRST = 265 -- Blizzard's own 8-slot block per form (Stance Bar Override)
-- A new form page starts with Blizzard's 8 form slots, placed on the group the player's
-- "Stance Bar Override" setting (CVar GamepadStanceBarOverride) puts them on. Values: 1 none,
-- 2-4 page 1 left/right/bottom, 5-8 page 2 top/left/right/bottom, 9-12 page 3 top/left/right/bottom.
local OVERRIDE_GROUP = { [2] = 2, [3] = 3, [4] = 4, [5] = 1, [6] = 2, [7] = 3, [8] = 4, [9] = 1, [10] = 2, [11] = 3, [12] = 4 }
local DEFAULT_SEED_GROUP = 2 -- no override set: the LT group
local SEED_VERSION = 2
local OLD_SEED_ORDER = { 1, 2, 3, 4, 9, 10, 11, 12 } -- version 1 ignored the override setting

-- Group order matches positions: 1 top (nothing held), 2 left (LT), 3 right (RT), 4 bottom (LT+RT).
local GROUP_BARS = { "topBar", "leftBar", "rightBar", "bottomBar" }
-- Within a group: D-pad left, up, right, down, then face X, Y, B, A.
local GROUP_KEYS = { "PADDLEFT", "PADDUP", "PADDRIGHT", "PADDDOWN", "PAD3", "PAD4", "PAD2", "PAD1" }

-- Every live position, with its key and Blizzard's button at that spot.
local ACTIVE = {}
for group = 1, 4 do
    for i = 1, 8 do
        local pos = (group - 1) * 8 + i
        if not RESERVED[pos] then
            ACTIVE[#ACTIVE + 1] = {
                pos = pos, group = group, key = GROUP_KEYS[i], bar = GROUP_BARS[group],
                side = i <= 4 and "Left" or "Right", index = i <= 4 and i or i - 4,
            }
        end
    end
end

local DEFAULT_MOD_KEYS = { left = "PADLTRIGGER", right = "PADRTRIGGER" }

local DRIVER = "[vehicleui][possessbar][overridebar] 0; [bonusbar:1] 1; [bonusbar:2] 2; [bonusbar:3] 3; [bonusbar:4] 4; 0"

local IsSecret = issecretvalue or function() return false end

local function BlizzardBar()
    return rawget(_G, "GamepadMainActionBarFrame")
end

local function BlizzardButton(info)
    local bar = BlizzardBar()
    local bars = bar and bar.PageUnit and bar.PageUnit.actionBars
    local bar = bars and bars[info.bar]
    local side = bar and bar[info.side]
    return side and side["ActionButton" .. info.index]
end

-- The physical keys Blizzard uses for LT/RT (they can be rebound in the controller settings).
local function ModifierKey(binding, fallback)
    for _, key in ipairs({ GetBindingKey(binding, 1) }) do
        if type(key) == "string" and key:find("^PAD") then return key end
    end
    return fallback
end

local function UIFocused()
    local mode = rawget(_G, "GamepadMode")
    local manager = mode and mode.FrameControlsManager
    return manager ~= nil and manager.isUIFocused == true
end

----------------------------------------------------------------------------
-- Secure handler (restricted code: runs in combat too)
----------------------------------------------------------------------------

-- Inputs: attribute "state-form" (driver), "enabled", "suspended" (Blizzard's UI has controller focus),
-- "has-formN", "key-left"/"key-right" (LT/RT), and per button "key", "group" and "action-formN".
-- Shared variables (header environment): buttons, blizzard, bound, held = { left, right }.
local APPLY = [[
    local form = ...
    local active = self:GetAttribute("enabled") and form and form ~= "0" and self:GetAttribute("has-form" .. form)
    held.left, held.right = false, false
    bound = active and not self:GetAttribute("suspended")
    if active then
        for i = 1, #buttons do
            local button = buttons[i]
            button:SetAttribute("action", button:GetAttribute("action-form" .. form))
        end
        if blizzard then blizzard:SetAlpha(0) end
        self:Show()
    else
        if blizzard then blizzard:SetAlpha(1) end
        self:Hide()
    end
    self:RunAttribute("bind")
]]

-- Binds LT/RT to our modifier buttons and the 8 keys to the held group; dims the other groups.
local BIND = [[
    self:ClearBindings()
    if not bound then return end
    self:SetBindingClick(true, self:GetAttribute("key-left"), "RickQOLFormModLeft")
    self:SetBindingClick(true, self:GetAttribute("key-right"), "RickQOLFormModRight")
    local group = 1
    if held.left and held.right then
        group = 4
    elseif held.left then
        group = 2
    elseif held.right then
        group = 3
    end
    if group == 1 then
        for i = 1, 4 do
            local key, target = self:GetAttribute("top-key" .. i), self:GetAttribute("top-click" .. i)
            if key and target then self:SetBindingClick(true, key, target) end
        end
    end
    for i = 1, #buttons do
        local button = buttons[i]
        if button:GetAttribute("group") == group then
            self:SetBindingClick(true, button:GetAttribute("key"), button)
            button:SetAlpha(1)
        else
            button:SetAlpha(0.55)
        end
    end
]]

-- LT/RT pressed or released (wrapped OnClick of the modifier buttons, runs in the header's environment).
local MODIFIER = [[
    held[self:GetAttribute("side")] = down and true or false
    owner:RunAttribute("bind")
]]

----------------------------------------------------------------------------
-- Slots: reserve each form's page once per character
----------------------------------------------------------------------------

function FormBars:Character()
    local guid = UnitGUID("player")
    local char = self.db.chars[guid] or { forms = {}, seeded = {} }
    char.badSlots = char.badSlots or {}
    char.goodSlots = char.goodSlots or {}
    self.db.chars[guid] = char
    return char
end

local ATTACK_SPELL = 6603 -- every character has it; used to test whether a slot accepts actions

-- Some empty-looking slots refuse actions (e.g. 133-144, likely the vehicle page). Test by placing
-- Attack and taking it off again. Out of combat only; results are remembered per character.
function FormBars:Placeable(slot)
    local char = self.char
    if HasAction(slot) then return true end
    if char.badSlots[slot] then return false end
    if char.goodSlots[slot] then return true end
    if GetCursorInfo() then return false end -- don't disturb something the player is dragging
    ;(C_Spell and C_Spell.PickupSpell or PickupSpell)(ATTACK_SPELL)
    PlaceAction(slot)
    local ok = HasAction(slot)
    if ok then PickupAction(slot) end
    ClearCursor()
    if ok then char.goodSlots[slot] = true else char.badSlots[slot] = true end
    return ok
end

-- Empty, usable, unreserved slots from the pool, in order.
function FormBars:FreeSlots()
    local taken = {}
    for _, set in pairs(self.char.forms) do
        for _, slot in pairs(set) do taken[slot] = true end
    end
    local range, slot = 1, POOL[1][1] - 1
    return function()
        while POOL[range] do
            slot = slot + 1
            if slot > POOL[range][2] then
                range = range + 1
                slot = POOL[range] and POOL[range][1] - 1 or slot
            elseif not taken[slot] and not HasAction(slot) and self:Placeable(slot) then
                taken[slot] = true
                return slot
            end
        end
    end
end

-- Swaps reserved slots that turned out not to accept actions for good ones, then lets the form be
-- seeded again so the missing copies land.
function FormBars:ValidateForms()
    local char = self.char
    local nextFree = self:FreeSlots()
    for form, set in pairs(char.forms) do
        for pos, slot in pairs(set) do
            if not HasAction(slot) and not self:Placeable(slot) then
                set[pos] = nextFree()
                char.seeded[form] = nil
                if not set[pos] then
                    R:Print("form bars: out of free action slots.")
                    return
                end
            end
        end
    end
end

-- Reserves a page for one form (the first time you're in it).
function FormBars:ReserveForm(form)
    local char = self.char
    if char.forms[form] then return true end
    local nextFree = self:FreeSlots()
    local set = {}
    for pos = 1, POSITIONS do
        if not RESERVED[pos] then
            set[pos] = nextFree()
            if not set[pos] then
                R:Print("form bars: not enough free action slots for form " .. form .. ".")
                return false
            end
        end
    end
    char.forms[form] = set
    return true
end

function FormBars:ApplyForm(form)
    local set = self.char.forms[form]
    for _, button in ipairs(self.buttons) do
        button:SetAttribute("action-form" .. form, set[button.info.pos])
    end
    self.header:SetAttribute("has-form" .. form, true)
end

-- Copies what's on `from` onto `to` without taking it off `from`. Out of combat only.
local function CopyAction(from, to)
    local kind, id = GetActionInfo(from)
    if kind == "spell" then
        (C_Spell and C_Spell.PickupSpell or PickupSpell)(id)
    elseif kind == "macro" then
        (C_Macro and C_Macro.PickupMacro or PickupMacro)(id)
    elseif kind == "item" then
        (C_Item and C_Item.PickupItem or PickupItem)(id)
    else
        return
    end
    PlaceAction(to)
    ClearCursor()
end

local function SameAction(a, b)
    local kindA, idA = GetActionInfo(a)
    local kindB, idB = GetActionInfo(b)
    return kindA ~= nil and kindA == kindB and idA == idB
end

-- Where Blizzard's form slot k (1-8) goes on our page.
local function SeedPosition(k)
    local group = OVERRIDE_GROUP[tonumber(GetCVar("GamepadStanceBarOverride")) or 1] or DEFAULT_SEED_GROUP
    local pos = (group - 1) * 8 + k
    if RESERVED[pos] then pos = (DEFAULT_SEED_GROUP - 1) * 8 + k end -- top face buttons are Blizzard's
    return pos
end

-- Version 1 seeded into a fixed order. Take back those copies (only where still untouched) so the
-- form is seeded again by the player's setting.
function FormBars:MigrateSeeds()
    local char = self.char
    if (char.seedVersion or 1) >= SEED_VERSION then return end
    for form in pairs(char.seeded) do
        local set = char.forms[form]
        local first = GAMEPAD_FORM_FIRST + (form - 1) * 8
        for k = 1, 8 do
            local slot = set and set[OLD_SEED_ORDER[k]]
            if slot and SameAction(first + k - 1, slot) then
                PickupAction(slot)
                ClearCursor()
            end
        end
        char.seeded[form] = nil
    end
    char.seedVersion = SEED_VERSION
end

-- First time in a form: start its page with what Blizzard already keeps for that form.
function FormBars:Seed(form)
    local char = self.char
    local set = char.forms[form]
    if not set or char.seeded[form] or InCombatLockdown() then return end
    char.seeded[form] = true
    char.seedVersion = SEED_VERSION
    local first = GAMEPAD_FORM_FIRST + (form - 1) * 8
    for k = 1, 8 do
        local from, to = first + k - 1, set[SeedPosition(k)]
        if to and HasAction(from) and not HasAction(to) then
            local ok, err = pcall(CopyAction, from, to)
            if not ok then R:Print("form bars: couldn't copy slot " .. from .. ": " .. tostring(err)) end
        end
    end
end

----------------------------------------------------------------------------
-- Buttons
----------------------------------------------------------------------------

local function ActionCooldown(action)
    if C_ActionBar and C_ActionBar.GetActionCooldown then
        local info = C_ActionBar.GetActionCooldown(action)
        if info then return info.startTime, info.duration end
    elseif GetActionCooldown then
        return GetActionCooldown(action)
    end
end

local function UpdateButton(button)
    local action = button:GetAttribute("action")
    local texture = action and GetActionTexture(action)
    button.icon:SetTexture(texture)
    button.icon:SetShown(texture ~= nil)
    if not texture then
        button.cooldown:Clear()
        button.count:SetText("")
        return
    end

    local usable, noMana = IsUsableAction(action)
    if IsSecret(usable) or usable then
        button.icon:SetVertexColor(1, 1, 1)
    elseif noMana then
        button.icon:SetVertexColor(0.5, 0.5, 1)
    else
        button.icon:SetVertexColor(0.4, 0.4, 0.4)
    end

    local ok, start, duration = pcall(ActionCooldown, action)
    if ok and start and duration and not IsSecret(start) and not IsSecret(duration) and duration > 0 then
        button.cooldown:SetCooldown(start, duration)
    elseif ok and not (IsSecret(start) or IsSecret(duration)) then
        button.cooldown:Clear()
    end

    local count = GetActionCount(action)
    if not IsSecret(count) and count and count > 1 then
        button.count:SetText(count)
    else
        button.count:SetText("")
    end
end

function FormBars:CreateButton(info)
    local button = CreateFrame("Button", "RickQOLFormButton" .. info.pos, self.header, "SecureActionButtonTemplate")
    button:SetAttribute("type", "action")
    button:SetAttribute("useOnKeyDown", true)
    button:SetAttribute("key", info.key)
    button:SetAttribute("group", info.group)
    button:RegisterForClicks("AnyDown")
    button:RegisterForDrag("LeftButton")
    button:SetSize(40, 40)

    local slot = button:CreateTexture(nil, "BACKGROUND")
    slot:SetAllPoints()
    slot:SetAtlas("UI-HUD-ActionBar-IconFrame-Slot")
    button.icon = button:CreateTexture(nil, "ARTWORK")
    button.icon:SetAllPoints()
    local border = button:CreateTexture(nil, "OVERLAY")
    border:SetAllPoints()
    border:SetAtlas("UI-HUD-ActionBar-IconFrame")
    button:SetHighlightAtlas("UI-HUD-ActionBar-IconFrame-Mouseover")
    button.cooldown = CreateFrame("Cooldown", nil, button, "CooldownFrameTemplate")
    button.cooldown:SetAllPoints()
    button.count = button:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
    button.count:SetPoint("BOTTOMRIGHT", -2, 2)

    -- Insecure scripts only on things the secure click doesn't run through.
    button:HookScript("OnAttributeChanged", function(frame, name)
        if name == "action" then UpdateButton(frame) end
    end)
    button:SetScript("OnReceiveDrag", function(frame)
        if InCombatLockdown() then return end
        PlaceAction(frame:GetAttribute("action"))
        UpdateButton(frame)
    end)
    button:SetScript("OnDragStart", function(frame)
        if InCombatLockdown() then return end
        PickupAction(frame:GetAttribute("action"))
        UpdateButton(frame)
    end)
    button:SetScript("OnEnter", function(frame)
        local action = frame:GetAttribute("action")
        if action and HasAction(action) then
            GameTooltip:SetOwner(frame, "ANCHOR_RIGHT")
            GameTooltip:SetAction(action)
        end
    end)
    button:SetScript("OnLeave", GameTooltip_Hide)

    button.info = info
    return button
end

-- Sits each of our buttons exactly over Blizzard's button at the same spot.
function FormBars:PlaceButtons()
    for _, button in ipairs(self.buttons) do
        local target = BlizzardButton(button.info)
        if target then
            button:ClearAllPoints()
            button:SetAllPoints(target)
        end
    end
end

function FormBars:UpdateAll()
    if not self.header:IsShown() then return end
    for _, button in ipairs(self.buttons) do UpdateButton(button) end
end

----------------------------------------------------------------------------
-- Setup
----------------------------------------------------------------------------

function FormBars:CreateHeader()
    local header = CreateFrame("Frame", "RickQOLFormBar", UIParent, "SecureHandlerStateTemplate")
    header:SetFrameStrata("MEDIUM")
    header:SetAllPoints(UIParent)
    header:Hide()
    self.header = header

    self.buttons = {}
    for i, info in ipairs(ACTIVE) do
        local button = self:CreateButton(info)
        self.buttons[i] = button
        header:SetFrameRef("button" .. i, button)
    end
    -- LT/RT: clicked on press and on release so the handler always knows what's held.
    for _, side in ipairs({ "left", "right" }) do
        local name = side == "left" and "RickQOLFormModLeft" or "RickQOLFormModRight"
        local modifier = CreateFrame("Button", name, header, "SecureActionButtonTemplate")
        modifier:SetAttribute("side", side)
        modifier:RegisterForClicks("AnyDown", "AnyUp")
        header:WrapScript(modifier, "OnClick", MODIFIER)
    end

    local blizzard = BlizzardBar()
    if blizzard then header:SetFrameRef("blizzard", blizzard) end
    header:Execute(([[
        buttons = newtable()
        for i = 1, %d do buttons[i] = self:GetFrameRef("button" .. i) end
        blizzard = self:GetFrameRef("blizzard")
        held = newtable()
        bound = false
    ]]):format(#self.buttons))
    header:SetAttribute("apply", APPLY)
    header:SetAttribute("bind", BIND)
    header:SetAttribute("_onstate-form", [[ self:RunAttribute("apply", newstate) ]])
end

-- Re-runs the handler with the current form (out of combat only).
function FormBars:Reapply()
    if InCombatLockdown() or not self.ready then return end
    self.header:SetAttribute("enabled", self.db.enabled)
    self.header:Execute([[ self:RunAttribute("apply", self:GetAttribute("state-form")) ]])
end

-- Runs once the character's action bars are loaded, out of combat, for a class with forms.
function FormBars:Setup()
    if self.ready or InCombatLockdown() then return end
    if GetNumShapeshiftForms() == 0 or not BlizzardBar() then return end
    self.char = self:Character()
    self:MigrateSeeds()
    self:ValidateForms()
    for form in pairs(self.char.forms) do self:ApplyForm(form) end
    self.header:SetAttribute("key-left", ModifierKey("GAMEPADLEFTMOD", DEFAULT_MOD_KEYS.left))
    self.header:SetAttribute("key-right", ModifierKey("GAMEPADRIGHTMOD", DEFAULT_MOD_KEYS.right))
    -- Blizzard's top-group face buttons (X interact, Y inspect, B back, A jump), clicked by name.
    for i = 1, 4 do
        local target = BlizzardButton({ bar = "topBar", side = "Right", index = i })
        local name = target and target:GetName()
        if name and not name:find(":") then
            self.header:SetAttribute("top-key" .. i, GROUP_KEYS[4 + i])
            self.header:SetAttribute("top-click" .. i, name)
        end
    end
    self:PlaceButtons()

    self.ready = true
    self.header:SetAttribute("enabled", self.db.enabled)
    RegisterStateDriver(self.header, "form", DRIVER)
    self:SeedCurrent()
end

-- In a form out of combat: make sure it has a page (first visit) and is seeded.
function FormBars:SeedCurrent()
    local form = GetBonusBarOffset()
    if not self.ready or InCombatLockdown() or form < 1 or form > MAX_FORMS then return end
    if not self.char.forms[form] then
        if not self:ReserveForm(form) then return end
        self:ApplyForm(form)
        self:Reapply()
    end
    self:Seed(form)
    self:UpdateAll()
end

-- When Blizzard's UI takes the controller (bags, map, menus), give the D-pad back so it can navigate.
-- Bindings can only change out of combat from here, so UI focus during combat keeps our bindings.
function FormBars:WatchFocus()
    local elapsed, suspended = 0, false
    CreateFrame("Frame"):SetScript("OnUpdate", function(_, delta)
        elapsed = elapsed + delta
        if elapsed < 0.1 then return end
        elapsed = 0
        if not self.ready or InCombatLockdown() then return end
        local want = UIFocused()
        if want ~= suspended then
            suspended = want
            self.header:SetAttribute("suspended", want)
            self:Reapply()
        end
    end)
end

function FormBars:OnLogin(db)
    self.db = db
    R.db.probe = nil -- leftovers from the feasibility probe
    self:CreateHeader()
    self:WatchFocus()

    local events = CreateFrame("Frame")
    for _, event in ipairs({
        "PLAYER_ENTERING_WORLD", "PLAYER_REGEN_ENABLED", "UPDATE_SHAPESHIFT_FORMS",
        "UPDATE_BONUS_ACTIONBAR", "ACTIONBAR_SLOT_CHANGED", "ACTIONBAR_UPDATE_COOLDOWN",
        "ACTIONBAR_UPDATE_USABLE", "SPELL_UPDATE_USABLE", "SPELL_UPDATE_COOLDOWN", "BAG_UPDATE_DELAYED",
    }) do
        events:RegisterEvent(event)
    end
    events:SetScript("OnEvent", function(_, event)
        if event == "PLAYER_ENTERING_WORLD" or event == "UPDATE_SHAPESHIFT_FORMS" then
            -- Action slots are only reliable a moment after entering the world.
            C_Timer.After(1, function() self:Setup() end)
        elseif event == "PLAYER_REGEN_ENABLED" then
            self:Setup()
            self:SeedCurrent()
        elseif event == "UPDATE_BONUS_ACTIONBAR" then
            self:SeedCurrent()
        else
            self:UpdateAll()
        end
    end)
end

function FormBars:Slash(args)
    if args == "on" or args == "off" then
        if InCombatLockdown() then return R:Print("change form bars out of combat.") end
        self.db.enabled = args == "on"
        self:Reapply()
        R:Print("form bars " .. (self.db.enabled and "on" or "off"))
    elseif args == "dump" or args == "reseed" then
        if not self.ready then return R:Print("form bars: not active.") end
        local form = GetBonusBarOffset()
        if form < 1 or form > MAX_FORMS then return R:Print("shift into a form first.") end
        if args == "reseed" then
            if InCombatLockdown() then return R:Print("reseed out of combat.") end
            self.char.seeded[form] = nil
            self:Seed(form)
            self:UpdateAll()
        end
        local function Describe(slot)
            if not slot then return "-" end
            if not HasAction(slot) then return slot .. " empty" end
            local kind, id, subType = GetActionInfo(slot)
            local name = kind == "spell" and C_Spell.GetSpellName(id) or nil
            return ("%d %s %s %s %s"):format(slot, tostring(kind), tostring(id), tostring(subType), tostring(name))
        end
        local lines = {
            ("form %d, override CVar %s, seeded %s, seedVersion %s"):format(form,
                tostring(GetCVar("GamepadStanceBarOverride")), tostring(self.char.seeded[form]),
                tostring(self.char.seedVersion)),
        }
        local first = GAMEPAD_FORM_FIRST + (form - 1) * 8
        for k = 1, 8 do
            lines[#lines + 1] = ("blizzard k%d: %s -> pos %d"):format(k, Describe(first + k - 1), SeedPosition(k))
        end
        local set = self.char.forms[form]
        for pos = 1, POSITIONS do
            if set[pos] then lines[#lines + 1] = ("pos %2d: %s"):format(pos, Describe(set[pos])) end
        end
        self.db.dump = lines
        R:Print("form bars: dump saved (" .. #lines .. " lines); /reload to write it to disk.")
    elseif args == "status" then
        if not self.ready then
            R:Print("form bars: not active (no forms yet, or Blizzard's controller bars are off).")
            return
        end
        R:Print(("form bars %s; current form bar %d; LT=%s RT=%s"):format(self.db.enabled and "on" or "off",
            GetBonusBarOffset(), tostring(self.header:GetAttribute("key-left")),
            tostring(self.header:GetAttribute("key-right"))))
        for i = 1, 4 do
            R:Print(("  %s -> %s"):format(GROUP_KEYS[4 + i], tostring(self.header:GetAttribute("top-click" .. i))))
        end
        for form, set in pairs(self.char.forms) do
            local used = 0
            for _, slot in pairs(set) do
                if HasAction(slot) then used = used + 1 end
            end
            R:Print(("  form %d: slots %d-%d, %d buttons filled"):format(form, set[1], set[POSITIONS], used))
        end
    else
        R:Print("/rqol formbars " .. self.help)
    end
end
