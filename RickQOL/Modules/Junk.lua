-- Sells grey (poor quality) items automatically when a vendor window opens.
local _, R = ...

local Junk = R:RegisterModule("junk", { help = "on | off" })

local POOR = (Enum and Enum.ItemQuality and Enum.ItemQuality.Poor) or 0
local LAST_BAG = NUM_TOTAL_EQUIPPED_BAG_SLOTS or NUM_BAG_SLOTS or 4

-- Every sellable grey in the bags, with the copper it should earn.
local function FindJunk()
    local list, total = {}, 0
    for bag = 0, LAST_BAG do
        for slot = 1, C_Container.GetContainerNumSlots(bag) do
            local info = C_Container.GetContainerItemInfo(bag, slot)
            if info and info.quality == POOR and not info.hasNoValue and not info.isLocked then
                local price = select(11, C_Item.GetItemInfo(info.itemID)) or 0
                list[#list + 1] = { bag = bag, slot = slot }
                total = total + price * (info.stackCount or 1)
            end
        end
    end
    return list, total
end

function Junk:Sell()
    if InCombatLockdown() then return end
    local list, total = FindJunk()
    if #list == 0 then return end

    self.blocked = false
    if C_MerchantFrame and C_MerchantFrame.SellAllJunkItems then
        -- The game's own "Sell All Junk" (it also keeps sold greys in buyback).
        C_MerchantFrame.SellAllJunkItems()
    else
        for _, entry in ipairs(list) do
            C_Container.UseContainerItem(entry.bag, entry.slot)
        end
    end

    -- ADDON_ACTION_BLOCKED fires synchronously, so the result is known here.
    if self.blocked then
        R:Print("the game blocked automatic junk selling; use the vendor's Sell All Junk button.")
    else
        R:Print(("sold %d junk item(s) for %s"):format(#list, R:FormatMoney(total)))
    end
end

function Junk:OnLogin(db)
    self.db = db
    local frame = CreateFrame("Frame")
    frame:RegisterEvent("MERCHANT_SHOW")
    frame:RegisterEvent("ADDON_ACTION_BLOCKED")
    frame:RegisterEvent("ADDON_ACTION_FORBIDDEN")
    frame:SetScript("OnEvent", function(_, event, addon)
        if event == "MERCHANT_SHOW" then
            if self.db.enabled then self:Sell() end
        elseif addon == "RickQOL" then
            self.blocked = true
        end
    end)
end

function Junk:Slash(args)
    if args == "on" or args == "off" then
        self.db.enabled = args == "on"
    end
    R:Print("auto-sell junk is " .. (self.db.enabled and "on" or "off"))
end
