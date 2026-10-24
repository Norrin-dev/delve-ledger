-- Norrin Boon Tracker
-- Reads the "Boons" aura (spell ID 1280098) in Delves and prints its stats as on-screen text.

local ADDON_NAME = ...

local BOON_SPELL_ID     = 1280098
local BOON_SPELL_NAME   = "Boons"   -- fallback lookup (English client)
local DELVE_DIFFICULTY  = 208       -- GetInstanceInfo() difficultyID for Delves

-- The Labyrinth of Kindo'jan (GetInstanceInfo() 8th return)
local LABYRINTH_INSTANCE_ID = 3043
local HEXMASKS = {                  -- display order
    { id = 1308804, label = "Fiery Hexmask" },
    { id = 1308968, label = "Thundering Hexmask" },
    { id = 1309122, label = "Frozen Hexmask" },
}
local TREASURE_SPELL_ID = 1318775   -- "Treasure Room" reward-progress tooltip
-- Known caps per tooltip label (English client). Shown as x/max and colored red/yellow/green.
local TREASURE_MAX = {
    ["Chambers Completed"]     = 9,
    ["Bountiful Heavy Trunks"] = 6,
    ["Bountiful Coffers"]      = 3,
    ["Mislaid Treasures"]      = 3,
}
-- Display order of reward lines; labels not listed go last in tooltip order.
local TREASURE_ORDER = {
    "Bountiful Coffers",
    "Bountiful Heavy Trunks",
    "Mislaid Treasures",
    "Small Trunks",
}

-- 12.x "secret values": aura/tooltip data can be unreadable in combat. Never operate on those.
local issecret = issecretvalue or function() return false end

local db
local cache = nil        -- last good list of { label, value } (nil = never read)
local testMode = false
local pending = false
local inLabyrinth = false
local hexHave = {}       -- [spellID] = true once seen; sticky for the run (masks last the whole run)
local treasureCache = nil   -- list of cleaned tooltip lines
local treasureSource = "none"

---------------------------------------------------------------------------
-- Frame
---------------------------------------------------------------------------
local f = CreateFrame("Frame", "NorrinBoonTrackerFrame", UIParent, "BackdropTemplate")
f:SetSize(160, 40)
f:SetClampedToScreen(true)
f:SetMovable(true)
f:RegisterForDrag("LeftButton")
f:Hide()

local text = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
text:SetPoint("TOPLEFT", 6, -6)
text:SetJustifyH("LEFT")
text:SetJustifyV("TOP")

local function SavePosition()
    local point, _, relPoint, x, y = f:GetPoint(1)
    db.point, db.relPoint, db.x, db.y = point, relPoint, x, y
end

local function ApplyPosition()
    f:ClearAllPoints()
    f:SetPoint(db.point or "LEFT", UIParent, db.relPoint or "LEFT", db.x or 40, db.y or 120)
end

local function ApplyLock()
    if db.locked then
        f:EnableMouse(false)
        f:SetBackdrop(nil)
    else
        f:EnableMouse(true)
        f:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8x8", edgeFile = "Interface\\Buttons\\WHITE8x8", edgeSize = 1 })
        f:SetBackdropColor(0, 0, 0, 0.5)
        f:SetBackdropBorderColor(1, 0.82, 0, 0.8)
    end
end

f:SetScript("OnDragStart", function(self) self:StartMoving() end)
f:SetScript("OnDragStop", function(self) self:StopMovingOrSizing(); SavePosition() end)

---------------------------------------------------------------------------
-- Data
---------------------------------------------------------------------------
local function InDelve()
    if C_PartyInfo and C_PartyInfo.IsDelveInProgress and C_PartyInfo.IsDelveInProgress() then
        return true
    end
    local _, _, difficultyID = GetInstanceInfo()
    return difficultyID == DELVE_DIFFICULTY
end

local function InLabyrinth()
    local instanceID = select(8, GetInstanceInfo())
    return instanceID == LABYRINTH_INSTANCE_ID
end

local function UpdateHexmasks()
    for _, m in ipairs(HEXMASKS) do
        if not hexHave[m.id] then
            local ok, aura = pcall(C_UnitAuras.GetPlayerAuraBySpellID, m.id)
            if ok and aura then hexHave[m.id] = true end
        end
    end
end

local function CleanText(s)
    s = s:gsub("|c%x%x%x%x%x%x%x%x", "")   -- |cAARRGGBB
         :gsub("|cn[^:]*:", "")             -- |cnCOLOR_NAME:
         :gsub("|r", "")
         :gsub("|T.-|t", "")                -- textures
         :gsub("|A.-|a", "")                -- atlases
         :gsub("\194\160", " ")             -- non-breaking space
         :gsub("%s+", " ")
         :gsub("^%s+", "")
         :gsub("%s+$", "")
    return s
end

-- Show hidden escape codes and non-ASCII bytes (for /boons debug).
local function EscapeText(s)
    return (s:gsub("|", "||"):gsub("[\128-\255]", function(c) return ("\\%d"):format(c:byte()) end))
end

-- Substring lookup so stray prefixes/suffixes don't break matching.
local function FindKey(tbl, s)
    for key, v in pairs(tbl) do
        if s:find(key, 1, true) then return v end
    end
end

-- Treasure Room tooltip: try it as a player aura first, then as a plain spell tooltip.
-- Returns list of lines (or nil if unreadable), plus the source used.
local function ReadTreasure()
    local data, source
    local ok, aura = pcall(C_UnitAuras.GetPlayerAuraBySpellID, TREASURE_SPELL_ID)
    if ok and aura and aura.auraInstanceID and not issecret(aura.auraInstanceID) then
        data = C_TooltipInfo.GetUnitBuffByAuraInstanceID("player", aura.auraInstanceID, "HELPFUL")
        source = "aura"
    end
    if not data or not data.lines then
        data = C_TooltipInfo.GetSpellByID(TREASURE_SPELL_ID)
        source = "spell"
    end
    if not data or not data.lines then return nil, "none" end

    local out = {}
    for i = 2, #data.lines do                      -- line 1 is the title ("Treasure Room")
        local s = data.lines[i].leftText
        if s and issecret(s) then return nil, source end
        if s and s ~= "" then
            for part in s:gmatch("[^\r\n]+") do
                part = CleanText(part):gsub("^%s*%-%s*", "")
                if part ~= "" and not part:find("^Spell%s?ID") and not part:find("^Icon%s?ID") then
                    out[#out + 1] = part
                end
            end
        end
    end
    return out, source
end

local function GetBoonAura()
    local aura = C_UnitAuras.GetPlayerAuraBySpellID(BOON_SPELL_ID)
    if not aura and C_UnitAuras.GetAuraDataBySpellName then
        aura = C_UnitAuras.GetAuraDataBySpellName("player", BOON_SPELL_NAME, "HELPFUL")
    end
    return aura
end

-- Returns list of { label, value } or nil if unreadable right now.
local function ReadBoonLines(aura)
    local id = aura.auraInstanceID
    if not id or issecret(id) then return nil end

    local data = C_TooltipInfo.GetUnitBuffByAuraInstanceID("player", id, "HELPFUL")
    if not data or not data.lines then return nil end

    local out, raw = {}, {}
    for i = 2, #data.lines do                      -- line 1 is the aura name
        local s = data.lines[i].leftText
        if s and not issecret(s) and s ~= "" then
            for part in s:gmatch("[^\r\n]+") do
                local label, value = part:match("^%s*(.-):%s*([%d%.]+%%)")
                if label and label ~= "" and not label:find("Spell ID", 1, true) then
                    out[#out + 1] = { label, value }
                elseif not part:find("Spell ID", 1, true) and not part:find("remaining", 1, true) then
                    raw[#raw + 1] = { part }
                end
            end
        elseif s and issecret(s) then
            return nil
        end
    end
    if #out == 0 and #raw > 0 then return raw end  -- tooltip format changed: show it unparsed
    return out
end

---------------------------------------------------------------------------
-- Render
---------------------------------------------------------------------------
local function FormatCount(label, value, labelColor)
    local max = FindKey(TREASURE_MAX, label)
    local shown = labelColor and (labelColor .. label .. ":|r") or (label .. ":")
    if max then
        local n = tonumber(value)
        local color = (n <= 0 and "|cffff3333") or (n >= max and "|cff33ff33") or "|cffffff00"
        return ("%s %s%d/%d|r"):format(shown, color, n, max)
    end
    return ("%s |cff33ff33%s|r"):format(shown, value)
end

-- Splits the Treasure Room tooltip into the chambers line and sorted reward lines.
-- Only "Label: number" lines are kept; text-only lines and Great Vault lines are dropped.
local function BuildTreasure()
    local chambers, rewards = nil, {}
    for i, line in ipairs(treasureCache or {}) do
        if not line:lower():find("great vault", 1, true) then
            local label, value = line:match("^(.-)%s*:%s*(%d+)")
            if label then
                if label:find("Chambers Completed", 1, true) then
                    chambers = FormatCount(label, value, "|cffffd100")   -- gold, like headers
                else
                    local rank = 100 + i
                    for r, key in ipairs(TREASURE_ORDER) do
                        if label:find(key, 1, true) then rank = r; break end
                    end
                    rewards[#rewards + 1] = { rank = rank, text = FormatCount(label, value) }
                end
            end
        end
    end
    table.sort(rewards, function(a, b) return a.rank < b.rank end)
    return chambers, rewards
end

local function Render()
    local t = {}
    local showLab = inLabyrinth or testMode
    local chambers, rewards
    if showLab then
        chambers, rewards = BuildTreasure()
        if chambers then
            t[#t + 1] = chambers
            t[#t + 1] = " "
        end
    end

    t[#t + 1] = "|cffffd100Boons|r"
    if not cache or #cache == 0 then
        t[#t + 1] = "|cff999999none|r"
    else
        for _, e in ipairs(cache) do
            if e[2] then
                t[#t + 1] = ("%s: |cff33ff33%s|r"):format(e[1], e[2])
            else
                t[#t + 1] = e[1]
            end
        end
    end
    if showLab then
        t[#t + 1] = " "
        t[#t + 1] = "|cffffd100Hexmasks|r"
        for _, m in ipairs(HEXMASKS) do
            local color = hexHave[m.id] and "|cff33ff33" or "|cffff3333"
            t[#t + 1] = color .. m.label .. "|r"
        end

        t[#t + 1] = " "
        t[#t + 1] = "|cffffd100Treasure Room|r"
        if #rewards == 0 then
            t[#t + 1] = "|cff999999no data|r"
        else
            for _, r in ipairs(rewards) do t[#t + 1] = r.text end
        end
    end
    text:SetText(table.concat(t, "\n"))
    f:SetSize(math.max(80, text:GetStringWidth() + 12), text:GetStringHeight() + 12)
end

local Refresh
local function ScheduleRefresh(delay)
    if pending then return end
    pending = true
    C_Timer.After(delay or 0.2, function() pending = false; Refresh() end)
end

Refresh = function()
    local nowLab = InLabyrinth()
    if not nowLab then wipe(hexHave); treasureCache = nil end   -- new run starts fresh
    inLabyrinth = nowLab

    if not (InDelve() or testMode) then
        cache = nil
        f:Hide()
        return
    end

    if inLabyrinth or testMode then
        if inLabyrinth then UpdateHexmasks() end
        local okT, lines, src = pcall(ReadTreasure)
        if okT then
            treasureSource = src or "none"
            if lines then treasureCache = lines end   -- unreadable (combat): keep last
        end
    end

    local ok, aura = pcall(GetBoonAura)
    if ok then
        if aura then
            local ok2, lines = pcall(ReadBoonLines, aura)
            if ok2 and lines then
                cache = lines
                if #lines == 0 then ScheduleRefresh(1) end   -- tooltip text not cached yet
            end
            -- unreadable (combat secrets): keep last cache, re-read after combat
        elseif not InCombatLockdown() then
            cache = {}
        end
    end

    Render()
    f:Show()
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------
f:RegisterEvent("ADDON_LOADED")
f:RegisterEvent("PLAYER_ENTERING_WORLD")
f:RegisterEvent("ZONE_CHANGED_NEW_AREA")
f:RegisterEvent("PLAYER_REGEN_ENABLED")
f:RegisterUnitEvent("UNIT_AURA", "player")
-- Chamber completion likely fires scenario events; guarded in case an event name doesn't exist.
pcall(f.RegisterEvent, f, "SCENARIO_CRITERIA_UPDATE")
pcall(f.RegisterEvent, f, "SCENARIO_UPDATE")

-- Fallback poll: the Treasure Room text may change without any aura event.
C_Timer.NewTicker(3, function()
    if db and inLabyrinth and not InCombatLockdown() then ScheduleRefresh(0) end
end)

f:SetScript("OnEvent", function(self, event, arg1)
    if event == "ADDON_LOADED" then
        if arg1 ~= ADDON_NAME then return end
        NorrinBoonTrackerDB = NorrinBoonTrackerDB or { locked = true }
        db = NorrinBoonTrackerDB
        ApplyPosition()
        ApplyLock()
        self:UnregisterEvent("ADDON_LOADED")
        return
    end
    if not db then return end
    if event == "PLAYER_ENTERING_WORLD" or event == "ZONE_CHANGED_NEW_AREA" then
        ScheduleRefresh(1)                          -- instance info settles after loading
    else
        ScheduleRefresh(0.2)
    end
end)

---------------------------------------------------------------------------
-- Slash commands
---------------------------------------------------------------------------
SLASH_NORRINBOONTRACKER1 = "/boons"
SlashCmdList.NORRINBOONTRACKER = function(msg)
    msg = (msg or ""):lower():match("^%s*(.-)%s*$")
    if msg == "unlock" then
        db.locked = false; ApplyLock(); testMode = true; Refresh()
        print("|cffffd100Boon Tracker:|r unlocked - drag to move, /boons lock when done.")
    elseif msg == "lock" then
        db.locked = true; ApplyLock(); testMode = false; Refresh()
        print("|cffffd100Boon Tracker:|r locked.")
    elseif msg == "reset" then
        db.point, db.relPoint, db.x, db.y = nil, nil, nil, nil; ApplyPosition()
        print("|cffffd100Boon Tracker:|r position reset.")
    elseif msg == "test" then
        testMode = not testMode; Refresh()
        print("|cffffd100Boon Tracker:|r test mode " .. (testMode and "on" or "off") .. ".")
    elseif msg == "debug" then
        local name, _, difficultyID, _, _, _, _, instanceID = GetInstanceInfo()
        print(("|cffffd100Boon Tracker:|r instance=%s (%s) difficulty=%s delve=%s labyrinth=%s")
            :format(tostring(name), tostring(instanceID), tostring(difficultyID),
                    tostring(InDelve()), tostring(InLabyrinth())))
        local okT, lines, src = pcall(ReadTreasure)
        if not okT then
            print("  treasure: error - " .. tostring(lines))
        else
            print(("  treasure source=%s lines=%s"):format(tostring(src), lines and #lines or "unreadable"))
            if lines then for i, l in ipairs(lines) do print("   " .. i .. ": " .. l) end end
        end
        local data = C_TooltipInfo.GetSpellByID(TREASURE_SPELL_ID)
        if data and data.lines then
            print("  raw tooltip lines (escaped):")
            for i, ln in ipairs(data.lines) do
                local s = ln.leftText
                if s and not issecret(s) then print("   " .. i .. ": [" .. EscapeText(s) .. "]") end
            end
        end
    else
        print("|cffffd100Boon Tracker:|r /boons unlock | lock | reset | test | debug")
    end
end
