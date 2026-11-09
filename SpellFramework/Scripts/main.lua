--[[
    Spell Framework - RuneScape: Dragonwilds (UE4SS Lua mod)

    Adds custom spells, defined in Lua files in the Spells folder, to the game's
    spell system. They appear in the Spellbook (P) under "Custom Spells", can be
    dragged into the spell radial (Q) and are cast like the game's own spells.

    A spell can have variants. Casting it then opens a second wheel where you pick
    the variant (the Accio spell mod works this way).

    How it fits into the game:
      * Each custom spell is a copy of one of the game's utility spells (its
        animation and cast flow), with its own name, icon, rune cost, cooldown and
        Lua code that runs when the cast finishes.
      * Saves only ever contain IDs the game knows. A custom spell borrows the save
        ID of an always-available spell (Siphon Runes), and the framework remembers
        which radial slot holds which custom spell in its own file
        (saved_slots_<character>.txt). Removing the mod can therefore never stop a
        character from loading: those slots just show Siphon Runes.
      * Only works in your own world (single player or as host).

    See README.md and Spells/_Template.lua for how to write a spell.
]]

local U = require("sf.util")
local UI = require("sf.ui")
local API = require("sf.api")

------------------------------------------------------------------------ config

local Defaults = {
    CategoryName = "CUSTOM SPELLS",
    CategoryIcon = "",                 -- texture path; empty = the Magic skill's icon
    AliasSpell = "/Game/Gameplay/UtilityMagic/WorldInteractionSpells/USD_SiphonRunes",
    DefaultBase = "DetectOre",
    DefaultIcon = "/Game/Art/UI/Icons/T_Icon_Spell_Vortex",
    DebugLogging = false,
}
local Config = {}
for k, v in pairs(Defaults) do Config[k] = v end
do
    local ok, user = pcall(require, "config")
    if ok and type(user) == "table" then
        for k, v in pairs(user) do Config[k] = v end
    elseif not ok then
        U.Log("config.lua could not be loaded, using defaults: %s", tostring(user))
    end
end
U.Debug = Config.DebugLogging == true

local MOD_FOLDER = U.ModFolder()

-- Short names for the game's utility spells that can be used as `base`.
local BASES = {
    DetectOre = "/Game/Gameplay/UtilityMagic/PerkSpells/DetectOre/USD_DetectOre",
    DetectAnimaVents = "/Game/Gameplay/UtilityMagic/PerkSpells/DetectAnimaVents/USD_DetectAnimaVents",
    EyeOfOculus = "/Game/Gameplay/UtilityMagic/PerkSpells/EyeOfOculus/USD_EyeOfOculus",
    HomeTeleport = "/Game/Gameplay/UtilityMagic/PerkSpells/HomeTeleport/USD_HomeTeleport",
    Surge = "/Game/Gameplay/UtilityMagic/PerkSpells/Surge/USD_Surge",
    TempestShield = "/Game/Gameplay/UtilityMagic/PerkSpells/TempestShield/USD_TempestShield",
    Windstep = "/Game/Gameplay/UtilityMagic/PerkSpells/Windstep/USD_Windstep",
    FireSpirit = "/Game/Gameplay/UtilityMagic/PerkSpells/FireSpirit/USD_FireSpirit",
    ShadowVeil = "/Game/Gameplay/UtilityMagic/PerkSpells/ShadowVeil/USD_ShadowVeil",
    InternalAlchemy = "/Game/Gameplay/UtilityMagic/PerkSpells/InternalAlchemy/USD_InternalAlchemy",
    AccessPersonalChest = "/Game/Gameplay/UtilityMagic/PerkSpells/AccessPersonalChest/USD_AccessPersonalChest",
}

-- Spell modules kept from the base spell: the animation, the cast itself and the
-- rune cost. Everything else (the base spell's actual effect) is removed.
local KEEP_MODULES = {
    SpellModule_PlayMontage = true,
    SpellModule_PlayMontageForHeldEquipment = true,
    SpellModule_Cast = true,
    SpellModule_CostItems = true,
}

------------------------------------------------------------------------ state

local Spells = {}        -- id -> def (radial spells only: standalone spells and variant groups)
local SpellList = {}     -- defs in load order
local ByAddress = {}     -- address of the game spell object -> def
local AliasId = nil      -- persistence ID borrowed from the alias spell
local Ready = false      -- spells created

------------------------------------------------------------------------ loading spell files

local function NormalizeDef(def, file)
    if type(def) ~= "table" then return nil, "the file must return a table" end
    if type(def.id) ~= "string" or not def.id:match("^[%w_]+$") then
        return nil, "missing or invalid id (letters, digits and _ only)"
    end
    def.file = file
    def.name = def.name or def.id
    def.description = def.description or ""
    def.icon = def.icon or Config.DefaultIcon
    def.base = def.base or Config.DefaultBase
    if def.variants then
        if type(def.variants) ~= "table" or #def.variants == 0 then return nil, "variants must be a non-empty list" end
        for i, v in ipairs(def.variants) do
            v.id = v.id or (def.id .. "_" .. i)
            v.name = v.name or v.id
            v.description = v.description or ""
            v.icon = v.icon or def.icon
            v.cooldown = v.cooldown or 0
            if type(v.OnCast) ~= "function" then return nil, "variant " .. v.id .. " has no OnCast function" end
        end
    elseif type(def.OnCast) ~= "function" then
        return nil, "no OnCast function (or variants)"
    end
    return def
end

local function LoadSpellFiles()
    local folder = MOD_FOLDER .. "Spells/"
    local files = U.ListLuaFiles(folder)
    if not files then
        U.Log("Could not list %s; loading only the spells named in Spells/_list.txt.", folder)
        files = {}
        local text = U.ReadFile(folder .. "_list.txt") or ""
        for line in text:gmatch("[^\r\n]+") do
            local name = line:gsub("^%s+", ""):gsub("%s+$", "")
            if name ~= "" then files[#files + 1] = name end
        end
    end
    for _, name in ipairs(files) do
        if name:sub(1, 1) ~= "_" then
            local chunk, err = loadfile(folder .. name, "t", setmetatable({}, { __index = _G }))
            if not chunk then
                U.Log("Spell file %s has an error: %s", name, tostring(err))
            else
                local ok, def = pcall(chunk)
                if not ok then
                    U.Log("Spell file %s failed: %s", name, tostring(def))
                else
                    local good, why = NormalizeDef(def, name)
                    if not good then
                        U.Log("Spell file %s skipped: %s", name, why)
                    elseif Spells[def.id] then
                        U.Log("Spell file %s skipped: id '%s' is already used by %s", name, def.id, Spells[def.id].file)
                    else
                        Spells[def.id] = def
                        SpellList[#SpellList + 1] = def
                    end
                end
            end
        end
    end
end

------------------------------------------------------------------------ creating the game spells

local function SetModuleList(spell, keepModules)
    local container = U.Get(spell, "Modules")
    local arr = container and U.Get(container, "Modules")
    if not arr then return false end
    local ok = pcall(function() arr:Empty() end)
    if not ok then return false end
    for i, m in ipairs(keepModules) do
        local okSet, err = pcall(function() arr[i] = { Module = m } end)
        if not okSet then
            U.Log("Could not rebuild the module list: %s", tostring(err))
            return false
        end
    end
    return true
end

local function ConfigureModules(spell, costList)
    local container = U.Get(spell, "Modules")
    local arr = container and U.Get(container, "Modules")
    local keep, castModule, costModule = {}, nil, nil
    local n = arr and arr:GetArrayNum() or 0
    for i = 1, n do
        local wrapper = arr[i]
        local m = wrapper and U.Get(wrapper, "Module")
        if U.Valid(m) then
            local cls = m:GetClass():GetFName():ToString()
            if KEEP_MODULES[cls] then
                keep[#keep + 1] = m
                if cls == "SpellModule_Cast" then castModule = m end
                if cls == "SpellModule_CostItems" then costModule = m end
            end
        end
    end
    if #keep ~= n and not SetModuleList(spell, keep) then
        U.Log("Warning: could not remove the base spell's effect modules.")
    end
    if castModule then
        -- No skill XP from the base spell's XP table entry.
        U.Set(castModule, "CastXpEvent", { DataTable = nil, RowName = FName("None") })
    end
    if costModule then
        U.Set(costModule, "ItemCostMultiplierAttribute", nil)
        U.Set(costModule, "bUseMagicAmmo", false)
        local costs = U.Get(costModule, "ItemsCostInfo")
        if costs then
            pcall(function() costs:Empty() end)
            for i, c in ipairs(costList or {}) do
                pcall(function() costs[i] = { ItemData = c.data, Count = c.count } end)
            end
        end
    end
end

local function CreatePerk(spell, def, template)
    if not U.Valid(template) then return nil end
    local perk = U.Clone(template, nil, "PERK_SF_" .. def.id)
    if not perk then return nil end
    U.Set(perk, "PersistenceID", "")
    U.Set(perk, "InternalName", "perk_sf_" .. def.id)
    U.Set(perk, "PerkName", FText(def.name))
    U.Set(perk, "PerkDescription", FText(def.description))
    local icon = U.Soft(def.icon)
    if icon then U.Set(perk, "SkillPerkImage", icon) end
    local mods = U.Get(perk, "PerkModules")
    for i = 1, (mods and mods:GetArrayNum() or 0) do
        local m = mods[i]
        if U.Valid(m) and U.Get(m, "SpellData") ~= nil then U.Set(m, "SpellData", spell) end
    end
    return perk
end

local function Register(spell, def)
    local sub = FindFirstOf("UtilitySpellDataSubsystem")
    if not U.Valid(sub) then return false end
    local internal = "sf_" .. def.id
    pcall(function() sub.InternalNameToDataMap:Add(internal, spell) end)
    pcall(function() sub.AssetNameToDataMap:Add(U.Name(spell), spell) end)
    local ok = pcall(function()
        local n = sub.NetIdToData:GetArrayNum()
        sub.NetIdToData[n + 1] = spell
        sub.DataToNetIdMap:Add(spell, { NetId = n })
    end)
    return ok
end

local function CreateSpell(def)
    local basePath = BASES[def.base] or def.base
    local template = U.Load(basePath)
    if not template then
        U.Log("Spell '%s': base spell %s not found.", def.id, tostring(def.base))
        return false
    end
    local spell = U.Clone(template, nil, "USD_SF_" .. def.id)
    if not spell then return false end

    def.costList = def.variants and {} or API.ResolveCost(def.cost)
    ConfigureModules(spell, def.costList)
    U.Set(spell, "PersistenceID", AliasId)
    U.Set(spell, "InternalName", "sf_" .. def.id)
    U.Set(spell, "SpellDisplayName", FText(def.name))
    U.Set(spell, "CooldownDuration", def.variants and 1.0 or (def.cooldown or 3.0))
    U.Set(spell, "SpecialRequirementsStrategy", nil)
    U.Set(spell, "bNeedsUnlocking", true)
    local icon = U.Soft(def.icon)
    if icon then U.Set(spell, "SpellIcon", icon) end
    local perk = CreatePerk(spell, def, U.Get(template, "OwningPerk"))
    U.Set(spell, "OwningPerk", perk)

    if not Register(spell, def) then
        U.Log("Spell '%s': could not register it with the game.", def.id)
        return false
    end
    def.object, def.perk = spell, perk
    ByAddress[U.Addr(spell)] = def
    for _, v in ipairs(def.variants or {}) do v.costList = API.ResolveCost(v.cost) end
    U.Log("Added spell '%s' (%s)%s", def.name, def.id, def.variants and (" with " .. #def.variants .. " variants") or "")
    return true
end

local function CreateAll()
    local alias = U.Load(Config.AliasSpell)
    AliasId = alias and U.Str(U.Get(alias, "PersistenceID")) or ""
    if AliasId == "" then
        U.Log("Alias spell %s not found; custom spells are disabled so your saves stay safe.", tostring(Config.AliasSpell))
        return
    end
    LoadSpellFiles()
    local made = 0
    for _, def in ipairs(SpellList) do
        local ok, err = pcall(CreateSpell, def)
        if ok and err then made = made + 1 elseif not ok then U.Log("Spell '%s' failed: %s", def.id, tostring(err)) end
    end
    Ready = true
    U.Log("%d custom spell(s) ready.", made)
end

------------------------------------------------------------------------ the player's world

local World = {
    pawnAddr = nil,
    pawn = nil,
    restoreAt = nil,
    restored = false,
    slotsFile = nil,
    slots = {},         -- slot index (0-based) -> spell id
}

local function SpellcastingComponent()
    return U.OwnedComponent("SpellcastingComponent", U.PlayerController())
end

local function ProgressComponent()
    return U.OwnedComponent("ProgressComponent", U.PlayerController())
end

local function CharacterKey()
    local pc = U.PlayerController()
    local ok, key = pcall(function()
        local g = pc:GetCharacterGuid().InnerGuid
        return string.format("%08X%08X%08X%08X", g.A & 0xFFFFFFFF, g.B & 0xFFFFFFFF, g.C & 0xFFFFFFFF, g.D & 0xFFFFFFFF)
    end)
    if ok and key and key ~= "00000000000000000000000000000000" then return key end
    local ps = U.Get(pc, "PlayerState")
    local okName, name = pcall(function() return ps:GetPlayerName():ToString() end)
    if okName and name and name ~= "" then return (name:gsub("[^%w_%-]", "_")) end
    return "default"
end

-- Format 2 files were written after the fix for custom spells copying themselves into a
-- new radial slot on every load. Older files can hold those extra copies.
local SLOTS_FORMAT = 2

local function LoadSlots(path)
    local slots = {}
    local text = U.ReadFile(path) or ""
    for slot, id in text:gmatch("(%d+)%s*=%s*([%w_]+)") do slots[tonumber(slot)] = id end
    local format = tonumber(text:match("#%s*format%s+(%d+)")) or 1
    return slots, format
end

local function SaveSlots()
    if not World.slotsFile then return end
    local lines = { "# Spell Framework: which radial slots hold custom spells. Written by the mod.",
                    "# format " .. SLOTS_FORMAT }
    local keys = {}
    for slot in pairs(World.slots) do keys[#keys + 1] = slot end
    table.sort(keys)
    for _, slot in ipairs(keys) do lines[#lines + 1] = slot .. "=" .. World.slots[slot] end
    U.WriteFile(World.slotsFile, table.concat(lines, "\n") .. "\n")
end

local function UnlockCustomSpells()
    local prog = ProgressComponent()
    if not prog then return false end
    local list = {}
    for _, def in ipairs(SpellList) do
        if U.Valid(def.object) then
            local ok, unlocked = U.Call(prog, "IsSpellUnlocked", def.object)
            if not (ok and unlocked) then list[#list + 1] = def.object end
        end
    end
    if #list > 0 then U.Call(prog, "UnlockSpells", list) end
    return true
end

-- Puts custom spells back into the radial slots they were in last time.
local function RestoreSlots()
    local sc = SpellcastingComponent()
    if not sc then return false end
    local arr = U.Get(sc, "SelectedSpells")
    if not arr then return false end
    local n = arr:GetArrayNum()
    for slot, id in pairs(World.slots) do
        local def = Spells[id]
        if def and U.Valid(def.object) and slot < n then
            local current = arr[slot + 1]
            -- Only fill slots that are empty or hold the alias spell the save wrote for us.
            if not U.Valid(current) or U.Str(U.Get(current, "PersistenceID")) == AliasId then
                arr[slot + 1] = def.object
                U.Call(sc, "Client_NotifySelectedSpell", def.object, slot)
            end
        end
    end
    return true
end

-- Empties a radial slot (saved as "" like any empty slot).
local function ClearSlot(sc, arr, slot)
    pcall(function() arr[slot + 1] = nil end)
end

-- Old slot files can list the same spell in many slots (see SLOTS_FORMAT). Keeps the
-- first slot of each spell; returns the kept slots and a list of the other slots.
local function KeepFirstCopies(slots)
    local first = {}
    for slot, id in pairs(slots) do
        if not first[id] or slot < first[id] then first[id] = slot end
    end
    local kept, extra = {}, {}
    for slot, id in pairs(slots) do
        if first[id] == slot then kept[slot] = id else extra[#extra + 1] = slot end
    end
    return kept, extra
end

-- Unlocking a spell makes the game put it into the first empty radial slot. Custom spells
-- are unlocked again on every load, so this removes custom spells from every slot the
-- player didn't put them in, plus `extraSlots` (copies an old slot file still had; the
-- save shows those as the alias spell). Returns how many slots were emptied.
local function CleanRadial(extraSlots)
    local sc = SpellcastingComponent()
    local arr = sc and U.Get(sc, "SelectedSpells")
    if not arr then return 0 end
    local removed = 0
    for i = 1, arr:GetArrayNum() do
        local def = ByAddress[U.Addr(arr[i])]
        if def and World.slots[i - 1] ~= def.id then
            ClearSlot(sc, arr, i - 1)
            removed = removed + 1
        end
    end
    for _, slot in ipairs(extraSlots or {}) do
        local current = arr[slot + 1]
        if U.Valid(current) and not ByAddress[U.Addr(current)]
            and U.Str(U.Get(current, "PersistenceID")) == AliasId then
            ClearSlot(sc, arr, slot)
            removed = removed + 1
        end
    end
    return removed
end

-- Records which radial slots hold custom spells now.
local function TrackSlots()
    local sc = SpellcastingComponent()
    if not sc then return end
    local arr = U.Get(sc, "SelectedSpells")
    if not arr then return end
    local now, changed = {}, false
    for i = 1, arr:GetArrayNum() do
        local def = ByAddress[U.Addr(arr[i])]
        if def then now[i - 1] = def.id end
    end
    for slot, id in pairs(now) do if World.slots[slot] ~= id then changed = true end end
    for slot in pairs(World.slots) do if not now[slot] then changed = true end end
    if changed then
        World.slots = now
        SaveSlots()
    end
end

local function UpdateWorld()
    local pawn = U.Pawn()
    local addr = pawn and U.Addr(pawn)
    if addr ~= World.pawnAddr then
        World.pawnAddr, World.pawn = addr, pawn
        World.restored = false
        World.restoreAt = pawn and (os.clock() + 2.0) or nil
        UI.Close()
    end
    if not pawn or not Ready then return end
    if not World.restored then
        if os.clock() < (World.restoreAt or 0) then return end
        local key = CharacterKey()
        World.slotsFile = MOD_FOLDER .. "saved_slots_" .. key .. ".txt"
        local slots, format = LoadSlots(World.slotsFile)
        local extra = {}
        if format < SLOTS_FORMAT then slots, extra = KeepFirstCopies(slots) end
        World.slots = slots
        if UnlockCustomSpells() and RestoreSlots() then
            World.restored = true
            -- The game may place the unlocked spells a moment later; keep cleaning for a few seconds.
            World.cleanUntil = os.clock() + 5
            local removed = CleanRadial(extra)
            SaveSlots()
            if removed > 0 then U.Log("Removed %d extra copies of custom spells from the spell radial.", removed) end
            U.DebugLog("Character %s: custom spells unlocked and radial restored.", key)
        end
        return
    end
    if World.cleanUntil and os.clock() < World.cleanUntil then
        local removed = CleanRadial(nil)
        if removed > 0 then U.Log("Removed %d extra copies of custom spells from the spell radial.", removed) end
    end
    TrackSlots()
end

------------------------------------------------------------------------ spellbook

local Book = { entries = {} }   -- screen address -> our list entry

local function IsTemplate(obj)
    local name = U.FullName(obj)
    return name:find("Default__", 1, true) ~= nil or name:find("^%S+ /Game/") ~= nil
end

local function UpdateSpellbook()
    if not Ready or #SpellList == 0 then return end
    for _, screen in ipairs(FindAllOf("SpellBookScreen") or {}) do
        if U.Valid(screen) and not IsTemplate(screen) then
            local okVis, visible = pcall(function() return screen:IsVisible() end)
            local list = U.Get(screen, "SpellsList")
            if okVis and visible and U.Valid(list) then
                local okNum, num = U.Call(list, "GetNumItems")
                if okNum and type(num) == "number" and num > 0 then
                    local key = U.Addr(screen)
                    local mine = Book.entries[key]
                    local present = false
                    if U.Valid(mine) then
                        for i = 0, num - 1 do
                            local okItem, item = U.Call(list, "GetItemAt", i)
                            if okItem and U.Same(item, mine) then present = true break end
                        end
                    end
                    if not present then
                        local first = select(2, U.Call(list, "GetItemAt", 0))
                        local magic = nil
                        for i = 0, num - 1 do
                            local _, item = U.Call(list, "GetItemAt", i)
                            if U.Valid(item) and U.Str(U.Get(item, "SkillName")):upper() == "MAGIC" then magic = item end
                        end
                        local entry = U.NewObject("/Script/Dominion.SpellBookListEntryData", screen, "SF_CustomSpells", false)
                        if entry then
                            U.Set(entry, "SkillName", FText(Config.CategoryName))
                            if Config.CategoryIcon ~= "" then
                                U.Set(entry, "SkillIcon", U.Soft(Config.CategoryIcon))
                            elseif magic or first then
                                U.Set(entry, "SkillIcon", U.Get(magic or first, "SkillIcon"))
                            end
                            U.Set(entry, "Index", num)
                            local entries = U.Get(entry, "DataEntries")
                            local i = 0
                            for _, def in ipairs(SpellList) do
                                if U.Valid(def.object) then
                                    i = i + 1
                                    pcall(function()
                                        entries[i] = { SpellData = def.object, SkillPerkData = U.Soft(U.FullName(def.perk):match("^%S+ (.+)$")) }
                                    end)
                                end
                            end
                            U.Call(list, "AddItem", entry)
                            Book.entries[key] = entry
                            U.DebugLog("Added the %s category to the spellbook.", Config.CategoryName)
                        end
                    end
                end
            end
        end
    end
end

------------------------------------------------------------------------ casting

local Casts = {}          -- tracked spell actors: { actor, def, started, done }
local NewActors = {}      -- spell actors created since the last tick
local Cooldowns = {}      -- variant id -> os.clock() when usable again
local Pending = {}        -- { at, fn, name } run when a Lua-played cast animation reaches its cast point
local MontageCache = {}   -- base spell path -> montage
local GroupMontage = {}   -- spell id -> object path of the body montage the game played when that spell was cast

-- The cast animation of a game spell (its PlayMontage module).
local function CastMontage(base)
    local path = BASES[base] or base
    if MontageCache[path] ~= nil then return MontageCache[path] or nil end
    local montage = false
    local spell = U.Load(path)
    local container = spell and U.Get(spell, "Modules")
    local arr = container and U.Get(container, "Modules")
    for i = 1, (arr and arr:GetArrayNum() or 0) do
        local m = U.Get(arr[i], "Module")
        local mont = U.Valid(m) and U.Get(m, "Montage")
        if U.Valid(mont) then montage = mont break end
    end
    MontageCache[path] = montage
    return montage or nil
end

-- Player spell animations only move the body when played through the copy the game
-- makes of a montage for each character, which has one slot per body part. Lua never
-- builds that copy itself (doing so crashed the game); it reuses the game's.
local function SlotCount(montage)
    local ok, n = pcall(function() return montage.SlotAnimTracks:GetArrayNum() end)
    return ok and n or 0
end

local function ObjectPathOf(obj)
    return U.FullName(obj):match("^%S+ (.+)$")
end

-- The montage the game's spell animation player is playing (or last played) for the pawn.
local function CurrentSpellMontage(pawn)
    local magic = U.Get(pawn, "PlayerUtilityMagicComponent")
    local player = U.Valid(magic) and U.Get(magic, "SpellAnimationPlayer")
    local m = U.Valid(player) and U.Get(player, "CurrentMontage")
    if U.Valid(m) and SlotCount(m) > 1 then return m end
    return nil
end

-- The game's body copy of `montage` for this pawn (named <montage>_<n>, inside the pawn).
local function BodyCopy(montage, pawn)
    local base, pawnPath = U.Name(montage), ObjectPathOf(pawn)
    if not pawnPath then return nil end
    local best = nil
    for _, m in ipairs(FindAllOf("AnimMontage") or {}) do
        local name = U.Name(m)
        if name:sub(1, #base + 1) == base .. "_" and name:sub(#base + 2):match("^%d+$") then
            local path = ObjectPathOf(m) or ""
            if path:sub(1, #pawnPath + 1) == pawnPath .. "." and SlotCount(m) > 1 then best = m end
        end
    end
    return best
end

-- Picks the montage to play for a Lua cast: the body copy whenever one exists.
local function MontageFor(def, variant, pawn)
    local function Recorded()
        local path = GroupMontage[def.id]
        if not path then return nil end
        local ok, m = pcall(StaticFindObject, path)
        if ok and U.Valid(m) then return m end
        return nil
    end
    local own = variant and variant.base and CastMontage(variant.base)
    local group = CastMontage(def.base)
    local pick = (own and BodyCopy(own, pawn)) or Recorded() or (group and BodyCopy(group, pawn))
    if pick then return pick, true end
    return own or group, false
end

local function MakeContext(def, variant)
    local spell = variant or def
    local ctx = { spell = def, variant = variant, player = U.Pawn(), controller = U.PlayerController(), paid = false }

    -- Takes the rune cost and starts the cooldown. False (with a message) if the runes are missing.
    function ctx.Pay()
        if ctx.paid then return true end
        local costList = spell.costList or {}
        local ok, missing = API.CanPay(costList)
        if not ok then
            UI.Toast("Not enough " .. tostring(missing) .. " for " .. spell.name .. ".")
            return false
        end
        API.Pay(costList)
        ctx.paid = true
        if variant and (variant.cooldown or 0) > 0 then Cooldowns[variant.id] = os.clock() + variant.cooldown end
        return true
    end

    -- Plays the spell's cast animation and calls fn at the moment the spell is cast.
    -- The player can't walk during the animation, as with the game's own spells.
    function ctx.Cast(fn)
        local delay = spell.castTime or def.castTime or 2.0
        local pawn = U.Pawn()
        local played, length, body = false, 0, false
        if pawn then
            local montage
            montage, body = MontageFor(def, variant, pawn)
            local mesh = U.Get(pawn, "Mesh")
            local ok, anim = U.Call(mesh, "GetAnimInstance")
            if montage and ok and U.Valid(anim) then
                local okPlay, res = U.Call(anim, "Montage_Play", montage, 1.0, 0, 0.0, true)
                played = okPlay and type(res) == "number" and res > 0
                length = played and res or 0
                U.DebugLog("Cast '%s': playing %s (%s, %.2fs)", spell.id, U.Name(montage), body and "body copy" or "original", length)
            end
        end
        if not played then delay = 0 end
        Pending[#Pending + 1] = { at = os.clock() + delay, fn = fn, name = spell.id }
        local pc = U.PlayerController()
        if played and body and pc then
            local hold = math.min(math.max(length - 0.25, delay), delay + 3)
            if U.Call(pc, "SetIgnoreMoveInput", true) then
                Pending[#Pending + 1] = { at = os.clock() + hold, name = spell.id, fn = function()
                    U.Call(pc, "SetIgnoreMoveInput", false)
                end }
            end
        end
    end
    return ctx
end

-- Runs a variant after it was picked in the wheel.
local function RunVariant(def, variant)
    local ctx = MakeContext(def, variant)
    local function Go()
        if variant.payment ~= "manual" and not ctx.Pay() then return end
        local ok, err = pcall(variant.OnCast, API, ctx)
        if not ok then U.Log("Spell '%s' failed: %s", variant.id, tostring(err)) end
    end
    if variant.animation == "manual" then
        -- The spell decides when to cast (e.g. after asking for an item) by calling ctx.Cast.
        local ok, err = pcall(variant.OnCast, API, ctx)
        if not ok then U.Log("Spell '%s' failed: %s", variant.id, tostring(err)) end
    else
        ctx.Cast(Go)
    end
end

local LastVariant = {}    -- spell id -> index of the variant picked last time

local function OpenVariantWheel(def)
    local options = {}
    for _, v in ipairs(def.variants) do
        local left = (Cooldowns[v.id] or 0) - os.clock()
        local canPay, missing = API.CanPay(v.costList)
        local status, bad = "", false
        if left > 0 then
            status, bad = string.format("Ready in %.0fs", left), true
        elseif not canPay then
            status, bad = "Not enough " .. tostring(missing), true
        end
        local cost = {}
        for _, c in ipairs(v.costList or {}) do cost[#cost + 1] = { icon = c.icon, count = c.count, name = c.name } end
        options[#options + 1] = {
            name = v.name, description = v.description, icon = v.icon,
            cost = cost, detail = API.CostText(v.costList), cooldown = v.cooldown,
            status = status, statusBad = bad, disabled = bad,
        }
    end
    UI.Wheel({
        title = def.name,
        hint = def.description ~= "" and def.description or "Choose a spell.",
        options = options,
        selected = LastVariant[def.id],
        onPick = function(idx)
            local v = def.variants[idx]
            if not v then return end
            LastVariant[def.id] = idx
            local left = (Cooldowns[v.id] or 0) - os.clock()
            if left > 0 then
                UI.Toast(string.format("%s is ready in %.0f seconds.", v.name, left))
                return
            end
            local ok, missing = API.CanPay(v.costList)
            if not ok then
                UI.Toast("Not enough " .. tostring(missing) .. " for " .. v.name .. ".")
                return
            end
            RunVariant(def, v)
        end,
    })
end

local function OnNewSpellActor(actor)
    NewActors[#NewActors + 1] = actor
end

local function SpellState(actor)
    local ok, st = pcall(function() return actor.SpellInstance.State.State end)
    if ok and type(st) == "number" then return st end
    return nil
end

local function RunPending()
    if #Pending == 0 then return end
    local now = os.clock()
    for i = #Pending, 1, -1 do
        local p = Pending[i]
        if now >= p.at then
            table.remove(Pending, i)
            local ok, err = pcall(p.fn)
            if not ok then U.Log("Spell '%s' failed: %s", tostring(p.name), tostring(err)) end
        end
    end
end

-- ESpellState: Invalid 0, Casting 1, Running 2, Expiring 3, Expired 4
local function UpdateCasts()
    RunPending()
    if #NewActors > 0 then
        local pawnAddr = World.pawnAddr
        for _, actor in ipairs(NewActors) do
            if U.Valid(actor) then
                local def = ByAddress[U.Addr(U.Get(actor, "Data"))]
                if def then
                    local comp = U.Get(actor, "OwningMagicComponent")
                    local owner = U.Valid(comp) and select(2, U.Call(comp, "GetOwner")) or nil
                    if not owner or U.Addr(owner) == pawnAddr then
                        Casts[#Casts + 1] = { actor = actor, def = def, started = os.clock() }
                    end
                end
            end
        end
        NewActors = {}
    end
    for i = #Casts, 1, -1 do
        local cast = Casts[i]
        local def = cast.def
        local valid = U.Valid(cast.actor)
        local state = valid and SpellState(cast.actor) or 4
        if not cast.opened then
            cast.opened = true
            local pawn = U.Pawn()
            local okAuth, auth = pcall(function() return pawn:HasAuthority() end)
            if okAuth and auth == false then
                UI.Toast("Custom spells only work in your own world.")
                cast.done = true
            elseif def.variants then
                -- Stop the game's cast straight away: the animation plays once a variant is picked.
                -- Remember the body montage the game started, to play it again then.
                local current = pawn and CurrentSpellMontage(pawn)
                if current then GroupMontage[def.id] = ObjectPathOf(current) end
                U.DebugLog("Cast '%s': game montage %s", def.id, current and U.Name(current) or "not found")
                local magic = pawn and U.Get(pawn, "PlayerUtilityMagicComponent")
                if U.Valid(magic) then U.Call(magic, "Server_CancelSpell") end
                cast.done = true
                OpenVariantWheel(def)
            end
        end
        if not cast.done and (state >= 2 or not valid) then
            cast.done = true
            local ctx = MakeContext(def, nil)
            ctx.paid = true -- the game took the rune cost
            local ok, err = pcall(def.OnCast, API, ctx)
            if not ok then U.Log("Spell '%s' failed: %s", def.id, tostring(err)) end
        end
        if cast.done or os.clock() - cast.started > 120 then table.remove(Casts, i) end
    end
end

------------------------------------------------------------------------ driving

local tickCount = 0
local function Tick()
    tickCount = tickCount + 1
    UI.Tick()
    if not Ready then return end
    UpdateCasts()
    if tickCount % 5 == 0 then UpdateSpellbook() end
    if tickCount % 20 == 0 then UpdateWorld() end
end

local function Guarded(name, fn)
    return function(...)
        local ok, err = pcall(fn, ...)
        if not ok then U.Log("%s error: %s", name, tostring(err)) end
    end
end
local SafeTick = Guarded("Tick", Tick)

-- Waits for the game's spell data to load, then creates the custom spells.
-- Some engine lookups fail in the first seconds after the game starts, so wait a bit.
local START_DELAY = 15
local loadedAt = os.clock()
local function TryStart()
    if os.clock() - loadedAt < START_DELAY then return false end
    local sub = FindFirstOf("UtilitySpellDataSubsystem")
    if not U.Valid(sub) then return false end
    local ok, n = pcall(function() return sub.NetIdToData:GetArrayNum() end)
    if not ok or n == 0 then return false end
    if not U.Valid(FindFirstOf("ItemSubsystem")) then return false end
    CreateAll()
    return true
end

local started = false
U.GameThreadLoop(50, function()
    if not started then
        local ok, res = pcall(TryStart)
        if not ok then
            U.Log("Startup error: %s", tostring(res))
            started = true
        elseif res then
            started = true
        end
        return
    end
    SafeTick()
end)

pcall(NotifyOnNewObject, "/Script/Dominion.DominionSpellActor", OnNewSpellActor)

for _, name in ipairs(UI.Keys) do
    local key = Key[name]
    if key then
        RegisterKeyBind(key, function()
            if UI.IsOpen() then
                ExecuteInGameThread(function() UI.Key(UI.KeyAlias[name] or name) end)
            end
        end)
    end
end

-- Other mods and the console can reach the framework through this global.
SpellFramework = { API = API, Spells = Spells, UI = UI, Config = Config }

U.Log("Loaded. Spells are read from %sSpells/", MOD_FOLDER)
