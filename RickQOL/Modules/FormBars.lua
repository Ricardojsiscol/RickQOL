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
--
-- Look: Blizzard's controller art and layout (ActionBarStyles.lua "leftSquareRightCircle"): square
-- D-pad buttons, round face buttons, empty slots show the button glyph, the held group is drawn
-- expanded and the others collapsed, LT / RT / LT+RT labels under their groups. Blizzard's bars are
-- faded group by group so its live top-group face buttons (jump, back, ...) stay visible; if those
-- frames can't be faded from secure code, the whole bar is faded and we draw stand-ins.
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

-- Blizzard's button offsets from the group centre, per focus state (left, top, right, bottom).
local LAYOUT = {
    dpad = {
        collapsed = { size = 32, { -92, 0 }, { -58, 17 }, { -24, 0 }, { -58, -17 } },
        expanded = { size = 40, { -119, 0 }, { -75, 23 }, { -31, 0 }, { -75, -23 } },
    },
    face = {
        collapsed = { size = 30, { 25, 0 }, { 55, 18 }, { 85, 0 }, { 55, -18 } },
        expanded = { size = 38, { 32, 0 }, { 70, 23 }, { 108, 0 }, { 70, -23 } },
    },
}
local SHAPE_ART = {
    dpad = {
        normal = "gamepad-actionbar-squareslot-border-normal",
        pushed = "gamepad-actionbar-squareslot-border-pressed",
        highlight = "gamepad-actionbar-squareslot-border-hover",
        shadow = "gamepad-actionbar-squareslot-dropshadow",
        mask = "SquareMask",
        checked = "gamepad-actionbar-squareslot-border-selected",
    },
    face = {
        normal = "gamepad-actionbar-circleslot-border-normal",
        pushed = "gamepad-actionbar-circleslot-border-pressed",
        highlight = "gamepad-actionbar-circleslot-border-hover",
        shadow = "gamepad-actionbar-circleslot-dropshadow",
        mask = "CircleMask",
        checked = "gamepad-actionbar-circleslot-border-selected",
    },
}
-- Empty-slot art per button (shows the glyph), Xbox and PlayStation sets.
local EMPTY_ART = {
    dpad = {
        "gamepad-actionbar-squareslot-generic-dpadleft-normal", "gamepad-actionbar-squareslot-generic-dpadup-normal",
        "gamepad-actionbar-squareslot-generic-dpadright-normal", "gamepad-actionbar-squareslot-generic-dpaddown-normal",
    },
    face = {
        "gamepad-actionbar-circleslot-xbox-x-normal", "gamepad-actionbar-circleslot-xbox-y-normal",
        "gamepad-actionbar-circleslot-xbox-b-normal", "gamepad-actionbar-circleslot-xbox-a-normal",
    },
    faceShapes = {
        "gamepad-actionbar-circleslot-ps-square-normal", "gamepad-actionbar-circleslot-ps-triangle-normal",
        "gamepad-actionbar-circleslot-ps-circle-normal", "gamepad-actionbar-circleslot-ps-cross-normal",
    },
}
-- Stand-ins for Blizzard's top-group face buttons when its whole bar has to be faded.
local TOP_FACE_ART = { [3] = "128-redbutton-exit", [4] = "gamepad-ability-icon-jump" }

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
-- Shared variables (header environment): buttons, layout (buttons + stand-ins), faded (Blizzard frames
-- to fade), bound, held = { left, right }.
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
        for i = 1, #faded do faded[i]:SetAlpha(0) end
        self:Show()
    else
        for i = 1, #faded do faded[i]:SetAlpha(1) end
        if topRight then topRight:SetAlpha(1) end
        self:Hide()
    end
    self:RunAttribute("bind")
]]

-- Binds LT/RT to our modifier buttons and the 8 keys to the held group; expands that group.
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
        end
    end
    self:RunAttribute("layout", group)
]]

-- Draws group `...` expanded and the rest collapsed (and handles Blizzard's compact layout).
local LAYOUT_SNIPPET = [[
    local group = ...
    -- Blizzard's compact layout stacks every group in one spot and shows only the active one.
    local compact = self:GetAttribute("compact")
    for g = 1, #groups do
        if compact and g ~= group then groups[g]:Hide() else groups[g]:Show() end
    end
    -- ...and Blizzard's live jump/back/... buttons would sit on top of the held LT/RT group.
    if topRight then topRight:SetAlpha((compact and group ~= 1) and 0 or 1) end
    for i = 1, #layout do
        local frame = layout[i]
        local state = frame:GetAttribute("group") == group and "e" or "c"
        local size = frame:GetAttribute(state .. "s")
        frame:ClearAllPoints()
        frame:SetPoint("CENTER", "$parent", "CENTER", frame:GetAttribute(state .. "x"), frame:GetAttribute(state .. "y"))
        frame:SetWidth(size)
        frame:SetHeight(size)
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

local ActionBar = C_ActionBar or {}
local IsUsable = ActionBar.IsUsableAction or IsUsableAction
local IsCurrent = ActionBar.IsCurrentAction or IsCurrentAction
local IsAutoRepeat = ActionBar.IsAutoRepeatAction or IsAutoRepeatAction

-- Cooldown swipe. In combat the cooldown numbers are secret values, and the swipe only accepts secrets
-- from Blizzard's own code, so addons pass an opaque duration object instead
-- (C_ActionBar.GetActionCooldownDuration -> Cooldown:SetCooldownFromDurationObject).
local lastCooldownError
local function UpdateCooldown(button, action)
    local ok, err = pcall(function()
        if ActionBar.GetActionCooldownDuration and button.cooldown.SetCooldownFromDurationObject then
            button.cooldown:SetCooldownFromDurationObject(ActionBar.GetActionCooldownDuration(action), true)
            return
        end
        local info = ActionBar.GetActionCooldown and ActionBar.GetActionCooldown(action)
        if info and info.isActive and not IsSecret(info.duration) then
            button.cooldown:SetCooldown(info.startTime, info.duration, info.modRate)
        else
            button.cooldown:Clear()
        end
    end)
    if not ok and err ~= lastCooldownError then
        lastCooldownError = err
        R.db.formbars.cooldownError = { when = date("%H:%M:%S"), combat = InCombatLockdown(), err = tostring(err) }
        R:Print("form bars: cooldown display failed: " .. tostring(err))
    end
end

local function UpdateButton(button)
    local action = button:GetAttribute("action")
    local texture = action and GetActionTexture(action)
    button.icon:SetTexture(texture)
    button.icon:SetShown(texture ~= nil)
    button.empty:SetShown(texture == nil)
    if not texture then
        button.cooldown:Clear()
        button.count:SetText("")
        button.checked:Hide()
        return
    end

    local usable, noMana = IsUsable(action)
    if IsSecret(usable) or usable then
        button.icon:SetVertexColor(1, 1, 1)
    elseif noMana then
        button.icon:SetVertexColor(0.5, 0.5, 1)
    else
        button.icon:SetVertexColor(0.4, 0.4, 0.4)
    end

    -- Blizzard's "active" border: queued (Maul), auto-attack, auto-shot, ...
    local current = IsCurrent and IsCurrent(action)
    local repeating = IsAutoRepeat and IsAutoRepeat(action)
    button.checked:SetShown((not IsSecret(current) and current) or (not IsSecret(repeating) and repeating) or false)

    UpdateCooldown(button, action)

    local count = GetActionCount(action)
    if not IsSecret(count) and count and count > 1 then
        button.count:SetText(count)
    else
        button.count:SetText("")
    end
end

-- Pressed look for a moment after a press (Blizzard's pushed border, icon pulled in like its -4 size).
local PRESS_TIME = 0.12
local function ShowPress(button)
    button.border:SetAtlas(button.art.pushed)
    button.icon:ClearAllPoints()
    button.icon:SetPoint("TOPLEFT", 2, -2)
    button.icon:SetPoint("BOTTOMRIGHT", -2, 2)
    button.pressedAt = GetTime()
    C_Timer.After(PRESS_TIME, function()
        if GetTime() - button.pressedAt < PRESS_TIME - 0.01 then return end -- pressed again since
        button.border:SetAtlas(button.art.normal)
        button.icon:ClearAllPoints()
        button.icon:SetAllPoints()
    end)
end

local function IconSet()
    local manager = rawget(_G, "InputDeviceIconSetManager")
    local ok, set = pcall(function() return manager and manager:GetActiveInputDeviceIconSet() end)
    return ok and set or nil
end

-- Layout attributes ("cx", "cy", "cs" collapsed; "ex", "ey", "es" expanded) read by the BIND snippet.
local function SetLayout(frame, shape, index)
    local collapsed, expanded = LAYOUT[shape].collapsed, LAYOUT[shape].expanded
    frame:SetAttribute("cx", collapsed[index][1])
    frame:SetAttribute("cy", collapsed[index][2])
    frame:SetAttribute("cs", collapsed.size)
    frame:SetAttribute("ex", expanded[index][1])
    frame:SetAttribute("ey", expanded[index][2])
    frame:SetAttribute("es", expanded.size)
    frame:SetPoint("CENTER", frame:GetParent(), "CENTER", collapsed[index][1], collapsed[index][2])
    frame:SetSize(collapsed.size, collapsed.size)
end

-- Blizzard-style art on a button-sized frame: drop shadow, empty-slot glyph, masked icon, border.
local function Dress(frame, shape, index)
    local art = SHAPE_ART[shape]
    local shadow = frame:CreateTexture(nil, "BACKGROUND", nil, -1)
    shadow:SetAtlas(art.shadow)
    shadow:SetPoint("TOPLEFT", -4, 4)
    shadow:SetPoint("BOTTOMRIGHT", 4, -4)

    local emptySet = shape == "dpad" and EMPTY_ART.dpad or (IconSet() == "Shapes" and EMPTY_ART.faceShapes or EMPTY_ART.face)
    frame.empty = frame:CreateTexture(nil, "BACKGROUND")
    frame.empty:SetAllPoints()
    frame.empty:SetAtlas(emptySet[index])

    frame.icon = frame:CreateTexture(nil, "ARTWORK")
    frame.icon:SetAllPoints()
    local mask = frame:CreateMaskTexture()
    mask:SetAtlas(art.mask)
    mask:SetAllPoints(frame.icon)
    frame.icon:AddMaskTexture(mask)

    frame.border = frame:CreateTexture(nil, "OVERLAY")
    frame.border:SetAllPoints()
    frame.border:SetAtlas(art.normal)

    frame.checked = frame:CreateTexture(nil, "OVERLAY", nil, 1)
    frame.checked:SetPoint("TOPLEFT", -4, 4)
    frame.checked:SetPoint("BOTTOMRIGHT", 4, -4)
    frame.checked:SetAtlas(art.checked)
    frame.checked:Hide()
    frame.art = art

    -- Marks the button picked up in edit mode.
    frame.selected = frame:CreateTexture(nil, "OVERLAY", nil, 2)
    frame.selected:SetPoint("TOPLEFT", -6, 6)
    frame.selected:SetPoint("BOTTOMRIGHT", 6, -6)
    frame.selected:SetAtlas(art.checked)
    frame.selected:SetVertexColor(1, 0.82, 0)
    frame.selected:Hide()
end

function FormBars:CreateButton(info, parent)
    local shape = info.side == "Left" and "dpad" or "face"
    local button = CreateFrame("Button", "RickQOLFormButton" .. info.pos, parent, "SecureActionButtonTemplate")
    button:SetAttribute("type", "action")
    button:SetAttribute("useOnKeyDown", true)
    button:SetAttribute("key", info.key)
    button:SetAttribute("group", info.group)
    button:RegisterForClicks("AnyDown")
    button:RegisterForDrag("LeftButton")
    SetLayout(button, shape, info.index)
    Dress(button, shape, info.index)
    button:SetHighlightAtlas(SHAPE_ART[shape].highlight)
    button:SetPushedAtlas(SHAPE_ART[shape].pushed)

    button.cooldown = CreateFrame("Cooldown", nil, button, "CooldownFrameTemplate")
    button.cooldown:SetAllPoints()
    if shape == "face" then button.cooldown:SetSwipeTexture("Interface\\CharacterFrame\\TempPortraitAlphaMask") end
    button.count = button:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
    button.count:SetPoint("BOTTOMRIGHT", -2, 2)

    -- Insecure scripts only on things the secure click doesn't run through.
    button:HookScript("OnAttributeChanged", function(frame, name)
        if name == "action" then UpdateButton(frame) end
    end)
    button:HookScript("OnClick", ShowPress) -- post-hook: runs after the secure click, can't taint it
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

-- Centres each of our groups on Blizzard's anchor for that group (stable while its bars animate).
function FormBars:PlaceGroups()
    local bar = BlizzardBar()
    local bars = bar and bar.PageUnit and bar.PageUnit.actionBars
    for group, frame in ipairs(self.groups) do
        local blizzardGroup = bars and bars[GROUP_BARS[group]]
        local anchor = blizzardGroup and blizzardGroup:GetParent()
        if anchor then
            frame:ClearAllPoints()
            frame:SetPoint("CENTER", anchor, "CENTER")
        end
    end
end

-- Controller glyph (Blizzard's shared input icon template), or nil if it isn't available.
local function Glyph(parent, key)
    if not key then return end
    local ok, glyph = pcall(CreateFrame, "Frame", nil, parent, "InputIconTextureFrameTemplate")
    if not ok or not glyph then return end
    pcall(glyph.SetInputKey, glyph, key)
    return glyph
end

-- "LT", "RT" and "LT + RT" under their groups, where Blizzard puts them.
function FormBars:CreateLabels()
    local LT, RT, PLUS = rawget(_G, "GAMEPAD_TRIGGER_LEFT"), rawget(_G, "GAMEPAD_TRIGGER_RIGHT"),
        rawget(_G, "GAMEPAD_PROMPT_DIVIDER_PLUS")
    local function Place(glyph, group, x)
        if glyph then glyph:SetPoint("CENTER", self.groups[group], "CENTER", x, -35) end
    end
    Place(Glyph(self.groups[2], LT), 2, 0)
    Place(Glyph(self.groups[3], RT), 3, 0)
    Place(Glyph(self.groups[4], LT), 4, -24)
    local plus = Glyph(self.groups[4], PLUS)
    Place(plus, 4, 0)
    if plus then plus:SetSize(16, 16) end
    Place(Glyph(self.groups[4], RT), 4, 24)
end

-- Picks what to fade: Blizzard's groups one by one (keeps its jump/back/... buttons live) when they
-- are all protected, otherwise the whole bar plus our stand-ins for those buttons.
function FormBars:ChooseFade()
    local bar = BlizzardBar()
    local unit = bar and bar.PageUnit
    local bars = unit and unit.actionBars
    local parts = bars and {
        bars.topBar and bars.topBar.Left, unit.LeftCenteredAnchor, unit.RightCenteredAnchor,
        unit.BottomCenteredAnchor, bars.stanceBar, bars.possessBar,
    }
    local partial = parts ~= nil and #parts == 6
    if partial then
        for i = 1, 6 do
            if not (parts[i] and parts[i].IsProtected and parts[i]:IsProtected()) then partial = false end
        end
    end
    local list = partial and parts or { bar }
    for i, frame in ipairs(list) do self.header:SetFrameRef("fade" .. i, frame) end
    local topRight = partial and bars.topBar.Right
    local useTopRight = topRight and topRight.IsProtected and topRight:IsProtected()
    if useTopRight then self.header:SetFrameRef("topright", topRight) end
    self.header:Execute(([[
        faded = newtable()
        for i = 1, %d do faded[i] = self:GetFrameRef("fade" .. i) end
        topRight = %s
    ]]):format(#list, useTopRight and 'self:GetFrameRef("topright")' or "nil"))
    for _, standIn in ipairs(self.standIns) do standIn:SetShown(not partial) end
    self.fadeMode = partial and "groups" or "whole bar"
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

    self.groups = {}
    for group = 1, 4 do
        local frame = CreateFrame("Frame", "RickQOLFormGroup" .. group, header, "SecureFrameTemplate")
        frame:SetSize(266, 86)
        frame:SetPoint("CENTER")
        self.groups[group] = frame
    end

    self.buttons = {}
    for i, info in ipairs(ACTIVE) do
        local button = self:CreateButton(info, self.groups[info.group])
        self.buttons[i] = button
        header:SetFrameRef("button" .. i, button)
    end
    for group, frame in ipairs(self.groups) do header:SetFrameRef("group" .. group, frame) end

    -- Stand-ins for Blizzard's top face buttons (only shown if its whole bar is faded).
    self.standIns = {}
    for index = 1, 4 do
        local standIn = CreateFrame("Frame", "RickQOLFormTopFace" .. index, self.groups[1], "SecureFrameTemplate")
        standIn:SetAttribute("group", 1)
        SetLayout(standIn, "face", index)
        Dress(standIn, "face", index)
        if TOP_FACE_ART[index] then
            standIn.icon:SetAtlas(TOP_FACE_ART[index])
            standIn.empty:Hide()
        end
        standIn:Hide()
        self.standIns[index] = standIn
        header:SetFrameRef("standin" .. index, standIn)
    end
    self:CreateLabels()
    -- LT/RT: clicked on press and on release so the handler always knows what's held.
    for _, side in ipairs({ "left", "right" }) do
        local name = side == "left" and "RickQOLFormModLeft" or "RickQOLFormModRight"
        local modifier = CreateFrame("Button", name, header, "SecureActionButtonTemplate")
        modifier:SetAttribute("side", side)
        modifier:RegisterForClicks("AnyDown", "AnyUp")
        header:WrapScript(modifier, "OnClick", MODIFIER)
    end

    header:Execute(([[
        buttons = newtable()
        layout = newtable()
        for i = 1, %d do
            buttons[i] = self:GetFrameRef("button" .. i)
            layout[i] = buttons[i]
        end
        for i = 1, 4 do layout[#layout + 1] = self:GetFrameRef("standin" .. i) end
        groups = newtable()
        for i = 1, 4 do groups[i] = self:GetFrameRef("group" .. i) end
        faded = newtable()
        held = newtable()
        bound = false
    ]]):format(#self.buttons))
    header:SetAttribute("apply", APPLY)
    header:SetAttribute("bind", BIND)
    header:SetAttribute("layout", LAYOUT_SNIPPET)
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
    self:PlaceGroups()
    self:ChooseFade()

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

----------------------------------------------------------------------------
-- Assigning with the controller: Blizzard's "bind to action bar" screen (GamepadActionBarEditFrame)
-- only knows its own slots. While you're in a form we show the form page in its place and take the next
-- D-pad/face press (LT/RT pick the group) to put the spell there. We only read the screen's state
-- (activeMode, pickupFunc, pickupParams) and fade its page display; closing it stays Blizzard's (B).
----------------------------------------------------------------------------

local function EditFrame()
    return rawget(_G, "GamepadActionBarEditFrame")
end

function FormBars:HeldGroup()
    local left = IsKeyDown(self.header:GetAttribute("key-left") or DEFAULT_MOD_KEYS.left)
    local right = IsKeyDown(self.header:GetAttribute("key-right") or DEFAULT_MOD_KEYS.right)
    if left and right then return 4 elseif left then return 2 elseif right then return 3 end
    return 1
end

function FormBars:ShowGroup(group)
    if InCombatLockdown() then return end
    self.header:Execute(("self:RunAttribute(%q, %d)"):format("layout", group))
end

local function FormName()
    local index = GetShapeshiftForm()
    local _, _, _, spellID = GetShapeshiftFormInfo(index or 0)
    return spellID and C_Spell.GetSpellName(spellID) or "form"
end

function FormBars:CreateAssign()
    local catcher = CreateFrame("Frame", nil, UIParent)
    catcher:SetFrameStrata("FULLSCREEN_DIALOG")
    catcher:Hide()
    catcher.prompt = catcher:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
    catcher.prompt:SetPoint("BOTTOM", self.groups[1], "TOP", 0, 60)
    catcher:SetScript("OnGamePadButtonDown", function(frame, key) self:AssignInput(frame, key, true) end)
    catcher:SetScript("OnGamePadButtonUp", function(frame, key) self:AssignInput(frame, key, false) end)
    self.catcher = catcher
end

-- Blizzard's screen dims everything below its strata; lift our bar above it while it's open.
function FormBars:SetLifted(lifted)
    local strata = lifted and "FULLSCREEN" or "MEDIUM"
    self.header:SetFrameStrata(strata)
    for _, frame in ipairs(self.groups) do frame:SetFrameStrata(strata) end
    for _, button in ipairs(self.buttons) do button:SetFrameStrata(strata) end
    for _, standIn in ipairs(self.standIns) do standIn:SetFrameStrata(strata) end
end

function FormBars:SetPrompt(text)
    self.catcher.prompt:SetText(("%s page: %s"):format(FormName(), text))
end

function FormBars:Select(button)
    if self.selectedButton then self.selectedButton.selected:Hide() end
    self.selectedButton = button
    if button then button.selected:Show() end
end

-- Swaps two of the form page's slots (either may be empty). Never leaves anything on the cursor.
local function SwapSlots(from, to)
    ClearCursor()
    PickupAction(from)
    if not GetCursorInfo() then return end
    PlaceAction(to) -- `to`'s old action (if any) is now on the cursor
    if GetCursorInfo() then PlaceAction(from) end
    ClearCursor()
end

local function ClearSlot(slot)
    ClearCursor()
    PickupAction(slot)
    ClearCursor()
end

function FormBars:ButtonAt(group, index)
    local pos = (group - 1) * 8 + index
    for _, button in ipairs(self.buttons) do
        if button.info.pos == pos then return button end
    end
end

function FormBars:AssignInput(frame, key, down)
    if InCombatLockdown() then return end
    local function Pass() frame:SetPropagateKeyboardInput(true) end
    local leftKey = self.header:GetAttribute("key-left") or DEFAULT_MOD_KEYS.left
    local rightKey = self.header:GetAttribute("key-right") or DEFAULT_MOD_KEYS.right
    if key == leftKey or key == rightKey then
        Pass()
        C_Timer.After(0, function() if self.assigning then self:ShowGroup(self:HeldGroup()) end end)
        return
    end
    if not down then return Pass() end

    local index
    for i, groupKey in ipairs(GROUP_KEYS) do
        if groupKey == key then index = i end
    end
    local group = self:HeldGroup()
    local edit = EditFrame()

    -- Edit mode, nothing held: X removes the picked-up button's action.
    if self.assigning == "edit" and group == 1 and index == 5 and self.selectedButton then
        frame:SetPropagateKeyboardInput(false)
        ClearSlot(self.selectedButton:GetAttribute("action"))
        self:Select(nil)
        self:SetPrompt("removed. Pick another button to move, or press B to finish.")
        self:UpdateAll()
        return
    end
    -- Top face buttons otherwise stay Blizzard's: B closes the screen.
    if not index or (group == 1 and index > 4) then return Pass() end
    frame:SetPropagateKeyboardInput(false)

    local button = self:ButtonAt(group, index)
    local slot = button and button:GetAttribute("action")
    if not slot then return end

    if self.assigning == "bind" then
        if not (edit and edit.pickupFunc) then return end
        ClearCursor()
        local ok = pcall(edit.pickupFunc, unpack(edit.pickupParams or {}))
        if ok and GetCursorInfo() then
            PlaceAction(slot) -- whatever was there lands on the cursor...
            ClearCursor() -- ...and is dropped, as Blizzard's screen does
            self:SetPrompt("placed. Press B to finish.")
        end
    elseif not self.selectedButton then
        if not HasAction(slot) then return end
        self:Select(button)
        self:SetPrompt("pick where to move it (same button cancels, X removes it).")
    else
        local from = self.selectedButton:GetAttribute("action")
        if from ~= slot then SwapSlots(from, slot) end
        self:Select(nil)
        self:SetPrompt("pick a button to move (LT / RT for the other groups), B to finish.")
    end
    self:UpdateAll()
end

-- Runs from the focus watcher (out of combat): starts/stops the overlay for Blizzard's bind screen
-- ("bind": placing a new spell) and edit screen ("edit": rearranging).
local EDIT_MODES = {
    BIND_ACTION = "bind", SELECT_ACTION_TO_PICKUP = "edit", PLACE_OR_CLEAR_HELD_ACTION = "edit",
}
function FormBars:WatchAssign()
    local edit = EditFrame()
    local mode = self.header:IsShown() and edit ~= nil and edit:IsShown() and EDIT_MODES[edit.activeMode] or nil
    if mode == "bind" and not edit.pickupFunc then mode = nil end
    if mode == (self.assigning or nil) then return end
    local was = self.assigning
    self.assigning = mode
    self:Select(nil)
    local pageUnit = edit and edit.PageUnit
    if mode then
        if mode == "bind" then
            self:SetPrompt("press a button to place it (LT / RT for the other groups)")
        else
            self:SetPrompt("pick a button to move (LT / RT for the other groups), B to finish.")
        end
        if not was then
            if pageUnit then pageUnit:SetAlpha(0) end
            self:SetLifted(true)
            self.catcher:EnableGamePadButton(true)
            self.catcher:SetPropagateKeyboardInput(true)
            self.catcher:Show()
            self:ShowGroup(self:HeldGroup())
        end
    else
        if pageUnit then pageUnit:SetAlpha(1) end
        self:SetLifted(false)
        self.catcher:Hide()
        self:Reapply()
    end
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
        self:WatchAssign()
        local want = UIFocused()
        local bar = BlizzardBar()
        local compact = bar ~= nil and bar.useCompactLayout == true
        if want ~= suspended or compact ~= (self.header:GetAttribute("compact") == true) then
            suspended = want
            self.header:SetAttribute("suspended", want)
            self.header:SetAttribute("compact", compact)
            self:Reapply()
        end
    end)
end

function FormBars:OnLogin(db)
    self.db = db
    R.db.probe = nil -- leftovers from the feasibility probe
    self:CreateHeader()
    self:CreateAssign()
    self:WatchFocus()

    local events = CreateFrame("Frame")
    for _, event in ipairs({
        "PLAYER_ENTERING_WORLD", "PLAYER_REGEN_ENABLED", "UPDATE_SHAPESHIFT_FORMS",
        "UPDATE_BONUS_ACTIONBAR", "ACTIONBAR_SLOT_CHANGED", "ACTIONBAR_UPDATE_COOLDOWN",
        "ACTIONBAR_UPDATE_USABLE", "SPELL_UPDATE_USABLE", "SPELL_UPDATE_COOLDOWN", "BAG_UPDATE_DELAYED",
        "ACTION_USABLE_CHANGED", "ACTIONBAR_UPDATE_STATE", "PLAYER_ENTER_COMBAT", "PLAYER_LEAVE_COMBAT",
        "START_AUTOREPEAT_SPELL", "STOP_AUTOREPEAT_SPELL", "LOSS_OF_CONTROL_UPDATE",
    }) do
        pcall(events.RegisterEvent, events, event) -- some events may not exist on every client
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
        R:Print(("form bars %s; current form bar %d; LT=%s RT=%s; fading %s"):format(self.db.enabled and "on" or "off",
            GetBonusBarOffset(), tostring(self.header:GetAttribute("key-left")),
            tostring(self.header:GetAttribute("key-right")), tostring(self.fadeMode)))
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
