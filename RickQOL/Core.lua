-- RickQOL core: namespace, saved settings, module lifecycle and the /rqol slash command.
local ADDON_NAME, R = ...

R.modules = {}

-- Defaults are merged into RickQOLDB on load; modules read their own sub-table.
local DEFAULTS = {
    junk = { enabled = true },
    threat = { enabled = true, locked = true, point = { "CENTER", "CENTER", 0, -180 } },
    pins = { enabled = true, hideTrivial = false, showWorldEvents = false },
    bags = { enabled = true, compare = true },
}

local function MergeDefaults(target, defaults)
    for key, value in pairs(defaults) do
        if type(value) == "table" then
            if type(target[key]) ~= "table" then target[key] = {} end
            MergeDefaults(target[key], value)
        elseif target[key] == nil then
            target[key] = value
        end
    end
end

function R:Print(...)
    print("|cff33ccffRickQOL|r:", ...)
end

-- Modules register a table; OnLogin(db) runs once settings and the world are ready.
function R:RegisterModule(name, module)
    module.name = name
    self.modules[#self.modules + 1] = module
    self.modules[name] = module
    return module
end

-- Copper amount to "1g 2s 3c" with the game's coin icons.
function R:FormatMoney(copper)
    return GetCoinTextureString and GetCoinTextureString(copper) or tostring(copper)
end

local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("PLAYER_LOGIN")
events:SetScript("OnEvent", function(self, event, arg1)
    if event == "ADDON_LOADED" and arg1 == ADDON_NAME then
        RickQOLDB = RickQOLDB or {}
        MergeDefaults(RickQOLDB, DEFAULTS)
        R.db = RickQOLDB
        self:UnregisterEvent("ADDON_LOADED")
    elseif event == "PLAYER_LOGIN" then
        for _, module in ipairs(R.modules) do
            if module.OnLogin then
                local ok, err = pcall(module.OnLogin, module, R.db[module.name] or {})
                if not ok then R:Print(module.name .. " failed to start: " .. tostring(err)) end
            end
        end
    end
end)

-- /rqol <module> <command>; each module can expose a Slash(args) handler.
SLASH_RICKQOL1 = "/rqol"
SlashCmdList.RICKQOL = function(input)
    local name, rest = (input or ""):lower():match("^%s*(%S*)%s*(.-)%s*$")
    local module = R.modules[name]
    if module and module.Slash then
        module:Slash(rest)
        return
    end
    R:Print("commands:")
    for _, m in ipairs(R.modules) do
        if m.help then print("  /rqol " .. m.name .. " " .. m.help) end
    end
end

-- Key binding labels (Bindings.xml).
BINDING_HEADER_RICKQOL = "RickQOL"
BINDING_NAME_RICKQOL_NEAREST_QUEST = "Waypoint to nearest pending quest"
BINDING_NAME_RICKQOL_QUEST_LIST = "Available quests in this zone"

-- Records actions the game blocked (the "only available to the Blizzard UI" popup), with the function
-- name and call stack, into RickQOLDB.blocked so they can be read from disk after a /reload.
local blockedWatch = CreateFrame("Frame")
blockedWatch:RegisterEvent("ADDON_ACTION_BLOCKED")
blockedWatch:RegisterEvent("ADDON_ACTION_FORBIDDEN")
blockedWatch:SetScript("OnEvent", function(_, event, addon, func)
    if addon ~= ADDON_NAME or not R.db then return end
    R.db.blocked = R.db.blocked or {}
    local list = R.db.blocked
    list[#list + 1] = {
        when = date("%H:%M:%S"),
        event = event,
        func = tostring(func),
        inCombat = InCombatLockdown(),
        stack = debugstack(2, 12, 0),
    }
    while #list > 20 do table.remove(list, 1) end
end)
