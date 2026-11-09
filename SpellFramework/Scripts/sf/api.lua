-- Spell Framework: helpers for spell scripts. Every spell's OnCast gets this as `sf`.
-- All functions run on the game thread (OnCast already does).
local U = require("sf.util")
local UI = require("sf.ui")

local API = {}
API.UI = UI
API.Log = U.Log
API.Toast = UI.Toast

function API.Player() return U.Pawn() end
function API.Controller() return U.PlayerController() end
function API.Location() return U.Location(U.Pawn()) end

-------------------------------------------------------------------- items

local itemCache = nil   -- { {data, name, lower} }

-- Every item in the game that has a name.
function API.AllItems()
    if itemCache then return itemCache end
    local list, seen = {}, {}
    local sub = FindFirstOf("ItemSubsystem")
    if U.Valid(sub) then
        pcall(function()
            sub.PersistenceIDToDataMap:ForEach(function(_, v)
                local data = v:get()
                if U.Valid(data) and not U.Get(data, "bSoftDeleted") then
                    local name = U.Str(U.Get(data, "Name"))
                    if name ~= "" and not seen[name:lower()] then
                        seen[name:lower()] = true
                        list[#list + 1] = { data = data, name = name, lower = name:lower() }
                    end
                end
            end)
        end)
    end
    table.sort(list, function(a, b) return a.lower < b.lower end)
    if #list > 0 then itemCache = list end
    return list
end

-- An item by its in-game name ("Clay") or asset name ("ITEM_Resources_Clay").
function API.FindItem(name)
    if not name then return nil end
    local lower = name:lower()
    for _, it in ipairs(API.AllItems()) do
        if it.lower == lower then return it.data end
    end
    for _, it in ipairs(API.AllItems()) do
        if U.Name(it.data):lower() == lower then return it.data end
    end
    return nil
end

function API.ItemName(data) return U.Str(U.Get(data, "Name")) end

-------------------------------------------------------------------- the player's bags

-- The player's main bag (BP_Components_Inventory on the player controller).
function API.Bag()
    local pc = U.PlayerController()
    if not pc then return nil end
    local addr = U.Addr(pc)
    for _, c in ipairs(FindAllOf("InventoryComponent") or {}) do
        if U.Valid(c) and U.Name(c) == "BP_Components_Inventory" then
            local ok, owner = pcall(function() return c:GetOwner() end)
            if ok and U.Addr(owner) == addr then return c end
        end
    end
    return nil
end

function API.InventoryController()
    return U.OwnedComponent("InventoryController", U.PlayerController())
end

function API.CountInBag(itemData)
    local bag = API.Bag()
    if not (bag and U.Valid(itemData)) then return 0 end
    local ok, n = U.Call(bag, "GetNumItemsByData", itemData)
    return (ok and type(n) == "number") and n or 0
end

-------------------------------------------------------------------- storage

-- Storage near the player: chests, crates and the like that the game links to
-- crafting ("nearby storage"). Returns { {inventory, owner, distance} } nearest first.
function API.NearbyStorage(radius, includeUnlinked)
    local pawn = U.Pawn()
    local here = U.Location(pawn)
    if not here then return {} end
    radius = radius or 3000
    local linkable = {}
    for _, lic in ipairs(FindAllOf("LinkedInventoryComponent") or {}) do
        if U.Valid(lic) then
            local ok, owner = pcall(function() return lic:GetOwner() end)
            if ok and U.Valid(owner) then
                local usable = includeUnlinked or (U.Get(lic, "bIsLinkable") == true and U.Get(lic, "bIsLocked") ~= true)
                if usable then linkable[U.Addr(owner)] = true end
            end
        end
    end
    local result = {}
    for _, inv in ipairs(FindAllOf("InventoryComponent") or {}) do
        if U.Valid(inv) and U.Name(inv) == "BP_Components_WorldItemInventory" then
            local ok, owner = pcall(function() return inv:GetOwner() end)
            if ok and U.Valid(owner) and linkable[U.Addr(owner)] then
                local d = U.Distance(here, U.Location(owner))
                if d <= radius then result[#result + 1] = { inventory = inv, owner = owner, distance = d } end
            end
        end
    end
    table.sort(result, function(a, b) return a.distance < b.distance end)
    return result
end

-- What the nearby storage holds: { {data, name, count} } sorted by name.
function API.StorageContents(radius)
    local byAddr, list = {}, {}
    for _, s in ipairs(API.NearbyStorage(radius)) do
        local slots = U.Get(s.inventory, "ItemSlots")
        local n = slots and slots:GetArrayNum() or 0
        for i = 1, n do
            local item = slots[i]
            if U.Valid(item) then
                local data = U.Get(item, "ItemData")
                local count = U.Get(item, "Count") or 0
                local key = U.Addr(data)
                if key then
                    local e = byAddr[key]
                    if not e then
                        e = { data = data, name = API.ItemName(data), count = 0 }
                        byAddr[key] = e
                        list[#list + 1] = e
                    end
                    e.count = e.count + count
                end
            end
        end
    end
    table.sort(list, function(a, b) return a.name:lower() < b.name:lower() end)
    return list
end

local function FirstEmptySlot(inv)
    local slots = U.Get(inv, "ItemSlots")
    local n = slots and slots:GetArrayNum() or 0
    for i = 1, n do
        if not U.Valid(slots[i]) then return i - 1 end
    end
    return nil
end

-- Moves up to `amount` of an item (all of it if nil) from nearby storage into the
-- player's bag, nearest storage first. Returns how many were moved.
function API.PullFromStorage(itemData, amount, radius)
    local bag, ctl = API.Bag(), API.InventoryController()
    if not (bag and ctl and U.Valid(itemData)) then return 0 end
    local okSpace, space = U.Call(bag, "GetSpaceAvailableForItemByData", itemData)
    local want = amount or math.huge
    if okSpace and type(space) == "number" then want = math.min(want, space) end
    local start = API.CountInBag(itemData)
    local key = U.Addr(itemData)
    for _, s in ipairs(API.NearbyStorage(radius)) do
        local inv = s.inventory
        local slots = U.Get(inv, "ItemSlots")
        local n = slots and slots:GetArrayNum() or 0
        for i = 1, n do
            local moved = API.CountInBag(itemData) - start
            if moved >= want then return moved end
            local item = slots[i]
            if U.Valid(item) and U.Addr(U.Get(item, "ItemData")) == key then
                local count = U.Get(item, "Count") or 0
                local left = want - moved
                if count <= left then
                    U.Call(ctl, "MoveItemBetweenInventoriesAnySlot", inv, i - 1, bag)
                else
                    local target = FirstEmptySlot(bag)
                    if target then U.Call(ctl, "SplitAndPutStack", inv, i - 1, left, bag, target) end
                end
            end
        end
    end
    return API.CountInBag(itemData) - start
end

-------------------------------------------------------------------- items on the ground

function API.GroundItems(radius)
    local here = U.Location(U.Pawn())
    if not here then return {} end
    local list = {}
    for _, w in ipairs(FindAllOf("WorldItem") or {}) do
        if U.Valid(w) then
            local d = U.Distance(here, U.Location(w))
            if d <= (radius or 2000) then list[#list + 1] = { actor = w, distance = d } end
        end
    end
    table.sort(list, function(a, b) return a.distance < b.distance end)
    return list
end

-- Makes every item lying within `radius` fly to the player, using the game's own
-- pick-up magnet. Returns how many piles were pulled.
function API.PullGroundItems(radius)
    local pawn = U.Pawn()
    if not pawn then return 0 end
    local pulled = 0
    for _, e in ipairs(API.GroundItems(radius)) do
        local mag = U.Get(e.actor, "MagneticComponentGrantItem")
        if U.Valid(mag) and U.Get(mag, "bHasBeenGranted") ~= true then
            local ok = U.Call(mag, "BP_MagnetizeToPlayer", pawn, true)
            if ok then pulled = pulled + 1 end
        end
    end
    return pulled
end

-------------------------------------------------------------------- costs

-- Rune names accepted in spell costs, e.g. cost = { Law = 1, Air = 2 }.
API.Runes = {
    Air = "/Game/Gameplay/Items/Resources/Magic/ITEM_Rune_Air",
    Water = "/Game/Gameplay/Items/Resources/Magic/ITEM_Rune_Water",
    Earth = "/Game/Gameplay/Items/Resources/Magic/ITEM_Rune_Earth",
    Fire = "/Game/Gameplay/Items/Resources/Magic/ITEM_Rune_Fire",
    Law = "/Game/Gameplay/Items/Resources/Magic/ITEM_Rune_Law",
    Nature = "/Game/Gameplay/Items/Resources/Magic/ITEM_Rune_Nature",
    Astral = "/Game/Gameplay/Items/Resources/Magic/ITEM_Rune_Astral",
    Essence = "/Game/Gameplay/Items/Resources/Magic/ITEM_Rune_Essence",
}

-- Turns a cost table into { {data, count, name} }. Keys may be rune names, item
-- names or asset paths.
function API.ResolveCost(cost)
    local list = {}
    for key, count in pairs(cost or {}) do
        local data
        if API.Runes[key] then
            data = U.Load(API.Runes[key])
        elseif type(key) == "string" and key:sub(1, 1) == "/" then
            data = U.Load(key)
        else
            data = API.FindItem(key)
        end
        if U.Valid(data) then
            list[#list + 1] = { data = data, count = count, name = API.ItemName(data) }
        else
            U.Log("Unknown cost item '%s'", tostring(key))
        end
    end
    table.sort(list, function(a, b) return a.name < b.name end)
    return list
end

function API.CostText(costList)
    local parts = {}
    for _, c in ipairs(costList or {}) do parts[#parts + 1] = c.count .. " " .. c.name end
    if #parts == 0 then return "No cost" end
    return table.concat(parts, ", ")
end

-- Whether the bag holds the cost. Returns ok, and the first missing item's name.
function API.CanPay(costList)
    for _, c in ipairs(costList or {}) do
        if API.CountInBag(c.data) < c.count then return false, c.name end
    end
    return true
end

function API.Pay(costList)
    local bag = API.Bag()
    if not bag then return false end
    for _, c in ipairs(costList or {}) do
        U.Call(bag, "RemoveItemByData", c.data, c.count)
    end
    return true
end

return API
