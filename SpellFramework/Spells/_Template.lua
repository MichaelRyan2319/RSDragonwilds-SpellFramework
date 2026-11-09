-- Template for a new spell. Copy this file, rename it (files starting with _ are
-- ignored), change it and restart the game. Errors are written to
-- Win64\ue4ss\UE4SS.log, on lines starting with [SpellFramework].
--
-- `sf` (passed to OnCast) has these helpers:
--   sf.Toast(text, seconds)              message at the top of the screen
--   sf.Player(), sf.Controller(), sf.Location()
--   sf.AllItems()                        { {data, name} } for every item in the game
--   sf.FindItem(name)                    item data by name ("Clay") or asset name
--   sf.ItemName(data)
--   sf.Bag(), sf.CountInBag(data)
--   sf.NearbyStorage(radius)             linked chests near you, nearest first
--   sf.StorageContents(radius)           { {data, name, count} } in those chests
--   sf.PullFromStorage(data, amount, radius)   returns how many arrived in your bag
--   sf.GroundItems(radius), sf.PullGroundItems(radius)
--   sf.CanPay(costList)                  whether the bag holds a cost
--   sf.UI.Prompt{...}, sf.UI.Wheel{...}  see Scripts/sf/ui.lua
-- `ctx` has ctx.player, ctx.controller, ctx.spell, ctx.variant,
--   ctx.Pay()      take the variant's runes and start its cooldown
--   ctx.Cast(fn)   play the cast animation, then call fn when the spell goes off
--
-- Distances are in centimetres (100 = 1 metre).

return {
    id = "my_spell",                 -- unique, letters/digits/_ only. Don't change it later:
                                     -- it's how your radial slots are remembered.
    name = "My Spell",
    description = "What the spell does, shown in the Spellbook.",
    icon = "/Game/Art/UI/Icons/T_Icon_Spell_Vortex",   -- any texture in the game
    base = "DetectOre",              -- game spell whose casting animation is used:
                                     -- DetectOre, EyeOfOculus, Surge, Windstep, HomeTeleport,
                                     -- TempestShield, FireSpirit, ShadowVeil, ...

    -- A spell without variants: the game takes the cost and runs the cooldown.
    cost = { Air = 2, Law = 1 },     -- runes (Air, Water, Earth, Fire, Law, Nature, Astral)
                                     -- or any item by name
    cooldown = 5,                    -- seconds

    OnCast = function(sf, ctx)       -- runs when the cast animation finishes
        sf.Toast("Hello from My Spell!")
    end,

    -- Or give the spell variants instead of cost/cooldown/OnCast. Casting it then
    -- opens a wheel (no animation yet) to pick one. Each variant has its own name,
    -- description, icon, cost, cooldown, base (animation) and OnCast. After a pick,
    -- the cast animation plays and OnCast runs when the spell goes off (castTime
    -- seconds in, default 2).
    --   payment = "manual"    runes are only taken when OnCast calls ctx.Pay();
    --                         otherwise they're taken just before OnCast runs
    --   animation = "manual"  OnCast runs straight after the pick, and plays the
    --                         animation itself with ctx.Cast(fn), e.g. after asking
    --                         the player something (see Accio.lua)
    --
    -- variants = {
    --     { id = "my_spell_a", name = "Version A", cost = { Air = 1 }, cooldown = 3,
    --       OnCast = function(sf, ctx) sf.Toast("A") end },
    --     { id = "my_spell_b", name = "Version B", cost = { Fire = 1 }, cooldown = 3,
    --       base = "Surge", castTime = 1.5,
    --       OnCast = function(sf, ctx) sf.Toast("B") end },
    -- },
}
