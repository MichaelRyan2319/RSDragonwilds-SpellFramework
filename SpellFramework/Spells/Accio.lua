-- Accio: summon items. One spell in the Spellbook; casting it opens a wheel with:
--   Accio             type an item's name and it comes to your bag from nearby storage
--   Accio Everything  every item lying on the ground around you flies to you
-- Runes are only used when something actually arrives. The cast animation plays
-- once you've picked what to summon.

local STORAGE_RANGE = 3000   -- 30 metres; storage the game links to crafting ("nearby storage")
local GROUND_RANGE = 2500    -- 25 metres

-- "20 clay", "clay x20", "clay 20" -> 20, "clay"
local function ParseAmount(text)
    text = (text or ""):gsub("^%s+", ""):gsub("%s+$", "")
    local n, rest = text:match("^(%d+)%s*[xX]?%s+(.+)$")
    if n then return tonumber(n), rest end
    rest, n = text:match("^(.-)%s*[xX]%s*(%d+)$")
    if n then return tonumber(n), rest end
    rest, n = text:match("^(.-)%s+(%d+)$")
    if n then return tonumber(n), rest end
    return nil, text
end

local function Matches(contents, query)
    local q = query:lower()
    local list = {}
    for _, e in ipairs(contents) do
        local name = e.name:lower()
        local at = name:find(q, 1, true)
        if q == "" or at then
            list[#list + 1] = { entry = e, starts = (at == 1), exact = (name == q) }
        end
    end
    table.sort(list, function(a, b)
        if a.exact ~= b.exact then return a.exact end
        if a.starts ~= b.starts then return a.starts end
        return a.entry.name:lower() < b.entry.name:lower()
    end)
    return list
end

return {
    id = "accio",
    name = "Accio",
    description = "Summon items to you. Pick a variant from the wheel.",
    icon = "/Game/Art/UI/Icons/T_Icon_Spell_Vortex",
    base = "DetectOre",

    variants = {
        {
            id = "accio_item",
            name = "Accio",
            description = "Name an item and it comes to your bag from nearby storage (linked chests within 30 m). Type a number for an amount, e.g. \"20 clay\".",
            icon = "/Game/Art/UI/Skills/Icons/Unlock/Construction/T_Skill_Construction_Access_Personal_Chest",
            cost = { Law = 1, Air = 1 },
            cooldown = 2,
            payment = "manual",   -- runes are taken only when items arrive (ctx.Pay below)
            animation = "manual", -- ask for the item first; the cast animation plays on Enter (ctx.Cast)

            OnCast = function(sf, ctx)
                local contents = sf.StorageContents(STORAGE_RANGE)
                if #contents == 0 then
                    sf.Toast("Accio: there's no linked storage with items within 30 m.")
                    return
                end
                sf.UI.Prompt({
                    title = "Accio! Summon what?",
                    hint = "Item name (e.g. 20 clay)",
                    suggest = function(text)
                        local amount, query = ParseAmount(text)
                        local out = {}
                        for _, m in ipairs(Matches(contents, query)) do
                            local e = m.entry
                            out[#out + 1] = {
                                label = string.format("%s   (%d in storage)", e.name, e.count),
                                complete = (amount and (amount .. " ") or "") .. e.name,
                                entry = e,
                            }
                        end
                        return out
                    end,
                    onSubmit = function(text, choice)
                        local amount, query = ParseAmount(text)
                        local entry = choice and choice.entry
                        if not entry then
                            local m = Matches(contents, query)[1]
                            entry = m and m.entry
                        end
                        if not entry then
                            sf.Toast("Accio: nothing called \"" .. query .. "\" in nearby storage.")
                            return
                        end
                        local ok, missing = sf.CanPay(ctx.variant.costList)
                        if not ok then
                            sf.Toast("Not enough " .. tostring(missing) .. " for Accio.")
                            return
                        end
                        ctx.Cast(function()
                            if not ctx.Pay() then return end
                            local moved = sf.PullFromStorage(entry.data, amount, STORAGE_RANGE)
                            if moved > 0 then
                                sf.Toast(string.format("Accio! %d %s", moved, entry.name))
                            else
                                sf.Toast("Accio: your bag has no room for " .. entry.name .. ".")
                            end
                        end)
                    end,
                })
            end,
        },
        {
            id = "accio_everything",
            name = "Accio Everything",
            description = "Every item lying on the ground within 25 m flies to you.",
            icon = "/Game/Art/UI/Skills/Icons/Unlock/WoodCutting/T_Skill_Woodcutting_Spell_PileEmUp",
            cost = { Law = 1, Air = 3 },
            cooldown = 10,
            payment = "manual",

            OnCast = function(sf, ctx)
                local items = sf.GroundItems(GROUND_RANGE)
                if #items == 0 then
                    sf.Toast("Accio Everything: nothing on the ground within 25 m.")
                    return
                end
                if not ctx.Pay() then return end
                local pulled = sf.PullGroundItems(GROUND_RANGE)
                sf.Toast(string.format("Accio Everything! %d item pile%s incoming.", pulled, pulled == 1 and "" or "s"))
            end,
        },
    },
}
