-- Bag layout: Blizzard's combined bag window, rearranged so each bag is one row with the bag's icon in
-- a column on the left. Keeps Blizzard's frame, art, controller cursor and item actions.
--
-- Rules for touching the native frame (Forever drives it with Blizzard's secure controller UI):
--   * Only post-hook with hooksecurefunc; never replace Blizzard functions or write their state.
--   * Only widget calls on Blizzard frames (SetPoint, SetSize, Show/Hide).
--   * Frames we add (fillers) are made at login, never while the bag window is open.
--
-- Controller navigation: the native cursor treats each distinct X position as a column and moves
-- left/right to the same index in the next column, so every row is padded to full width with
-- dimmed "filler" slots; otherwise left/right would jump between rows.
local _, R = ...

local Bags = R:RegisterModule("bags", { help = "on | off | compare" })

local MAX_SLOT_COLUMNS = 24 -- a bag bigger than this wraps onto another row
local MIN_SLOT_COLUMNS = 8 -- keeps the header (title, search) from getting cramped
local FILLER_COUNT = 200
local FILLER_ATLAS = "bags-item-slot64"
local ICON_GAP = 6 -- extra space between the bag icon column and the items

local KEYRING = (Enum.BagIndex and Enum.BagIndex.Keyring) or -2
local LAST_BAG = NUM_TOTAL_EQUIPPED_BAG_SLOTS or NUM_BAG_SLOTS or 4

local function Frame()
    return ContainerFrameCombinedBags
end

local function GamepadBagButton(bagID)
    return GamepadBagBar and GamepadBagBar.GetBagButton and GamepadBagBar:GetBagButton(bagID)
end

local function IsCollapsed(bagID)
    local button = GamepadBagButton(bagID)
    return button and button.isCollapsed == true
end

-- Top to bottom: backpack, bags 1..N, then the keyring.
local function BagOrder()
    local order = {}
    for bagID = 0, LAST_BAG do order[#order + 1] = bagID end
    order[#order + 1] = KEYRING
    return order
end

----------------------------------------------------------------------------
-- Pieces we own: filler slots (navigable) and bag icons for mouse mode
----------------------------------------------------------------------------

function Bags:CreatePieces()
    local frame = Frame()
    self.fillers = {}
    for i = 1, FILLER_COUNT do
        local filler = CreateFrame("Button", nil, frame)
        filler:SetSize(37, 37)
        local texture = filler:CreateTexture(nil, "BACKGROUND")
        texture:SetAllPoints()
        texture:SetAtlas(FILLER_ATLAS)
        texture:SetAlpha(0.35)
        filler:Hide()
        self.fillers[i] = filler
    end

    -- Outside controller mode Blizzard shows no bag icons in the grid; draw plain ones.
    self.icons = {}
    for _, bagID in ipairs(BagOrder()) do
        local icon = frame:CreateTexture(nil, "ARTWORK")
        icon:SetSize(37, 37)
        icon:Hide()
        self.icons[bagID] = icon
    end
end

local function SetMouseIcon(icon, bagID)
    local texture
    if bagID == 0 then
        texture = "Interface\\Icons\\Inv_misc_bag_08"
    elseif bagID == KEYRING then
        texture = "Interface\\Icons\\ui-hud-actionbar-keyring"
    else
        texture = GetInventoryItemTexture("player", C_Container.ContainerIDToInventoryID(bagID))
    end
    icon:SetTexture(texture)
    return texture ~= nil
end

----------------------------------------------------------------------------
-- Layout
----------------------------------------------------------------------------

-- Rows of { icon = button|texture|nil, items = { buttons } }, top to bottom.
function Bags:BuildRows()
    local frame = Frame()
    local byBag = {}
    for _, item in frame:EnumerateValidItems() do
        local bagID = item:GetBagID()
        byBag[bagID] = byBag[bagID] or {}
        table.insert(byBag[bagID], item)
    end

    local rows = {}
    local widest = MIN_SLOT_COLUMNS
    for _, bagID in ipairs(BagOrder()) do
        local items = byBag[bagID]
        local native = GamepadBagButton(bagID)
        if native and not native:IsShown() then native = nil end
        local collapsed = IsCollapsed(bagID)
        if not collapsed and items then
            table.sort(items, function(a, b) return a:GetID() < b:GetID() end)
        end
        local visible = (not collapsed and items) or {}

        if #visible > 0 or native then -- empty bag slots keep their icon so a bag can be equipped
            local icon = native
            if not icon and SetMouseIcon(self.icons[bagID], bagID) then icon = self.icons[bagID] end
            local index = 1
            repeat
                local row = { icon = index == 1 and icon or nil, items = {} }
                for i = index, math.min(index + MAX_SLOT_COLUMNS - 1, #visible) do
                    row.items[#row.items + 1] = visible[i]
                end
                widest = math.max(widest, #row.items)
                rows[#rows + 1] = row
                index = index + MAX_SLOT_COLUMNS
            until index > #visible
        end
    end
    return rows, math.min(widest, MAX_SLOT_COLUMNS)
end

function Bags:Layout()
    local frame = Frame()
    if not (self.db.enabled and self.fillers and frame:IsShown()) then return end
    if InCombatLockdown() then
        self.pending = true
        return
    end
    self.pending = false

    local rows, slotColumns = self:BuildRows()
    if #rows == 0 then return end

    local sample = frame.Items and frame.Items[1]
    local size = sample and sample:GetWidth() or 37
    local spaceX, spaceY = ITEM_SPACING_X or 5, ITEM_SPACING_Y or 5
    local stepX, stepY = size + spaceX, size + spaceY

    -- Same anchor as Blizzard's grid: bottom-right cell sits on the money frame's top-right corner.
    -- Columns count from the left (0 = bag icons), rows from the top.
    local lastColumn, lastRow = slotColumns, #rows - 1
    local function Place(region, column, row)
        local x = -(lastColumn - column) * stepX - (column == 0 and ICON_GAP or 0)
        local y = 4 + (lastRow - row) * stepY
        region:ClearAllPoints()
        region:SetPoint("BOTTOMRIGHT", frame.MoneyFrame, "TOPRIGHT", x, y)
        region:Show()
    end

    for _, icon in pairs(self.icons) do icon:Hide() end
    local fillerIndex = 0
    local function Filler(column, row)
        fillerIndex = fillerIndex + 1
        local filler = self.fillers[fillerIndex]
        if filler then
            filler:SetSize(size, size)
            Place(filler, column, row)
        end
    end

    for r, row in ipairs(rows) do
        if row.icon then Place(row.icon, 0, r - 1) else Filler(0, r - 1) end
        for c = 1, slotColumns do
            local item = row.items[c]
            if item then Place(item, c, r - 1) else Filler(c, r - 1) end
        end
    end
    for i = fillerIndex + 1, #self.fillers do
        self.fillers[i]:ClearAllPoints()
        self.fillers[i]:Hide()
    end

    -- Blizzard's own size, with its grid swapped for ours.
    local blizzardRows = frame:GetRows()
    local blizzardGrid = blizzardRows * size + (blizzardRows - 1) * spaceY
    local ourGrid = #rows * size + (#rows - 1) * spaceY
    local height = frame:CalculateHeight() - blizzardGrid + ourGrid
    local columns = slotColumns + 1
    local width = columns * size + (columns - 1) * spaceX + ICON_GAP + frame:GetPaddingWidth()
    frame:SetSize(width, height)
end

----------------------------------------------------------------------------
-- Setup
----------------------------------------------------------------------------

function Bags:ApplyCompare()
    if self.db.compare then SetCVar("alwaysCompareItems", 1) end
end

function Bags:OnLogin(db)
    self.db = db
    self:ApplyCompare()
    local frame = Frame()
    if not frame then return end

    self:CreatePieces()
    local relayout = function()
        self:Layout()
    end
    hooksecurefunc(frame, "UpdateItemLayout", relayout)
    hooksecurefunc(frame, "UpdateFrameSize", relayout)
    frame:HookScript("OnShow", relayout)

    local events = CreateFrame("Frame")
    events:RegisterEvent("PLAYER_REGEN_ENABLED")
    events:SetScript("OnEvent", function()
        if self.pending then relayout() end
    end)
end

function Bags:Slash(args)
    if args == "on" or args == "off" then
        self.db.enabled = args == "on"
        R:Print("bag layout " .. (self.db.enabled and "on" or "off") .. "; reopen your bags (or /reload to fully restore Blizzard's).")
    elseif args == "compare" then
        self.db.compare = not self.db.compare
        SetCVar("alwaysCompareItems", self.db.compare and 1 or 0)
        R:Print("always compare items " .. (self.db.compare and "on" or "off"))
    else
        R:Print("/rqol bags " .. self.help)
    end
end
