---- Enemy loot: drop everything (EnemyDropEverything), strip fitted attachments (EnemyAttachmentDrop),
---- and wear down dropped gear (EnemyDropCondition). Tactical deaths only: auto-resolve loot skips DropLoot.

const.RATOAI = const.RATOAI or {}
---- EnemyDropCondition choice -> condition points lost, rolled in [min, max].
const.RATOAI.DropConditionLoss = {
    Light = {min = 5, max = 15},
    Moderate = {min = 10, max = 30},
    Heavy = {min = 20, max = 45}
}
---- Wear never takes a dropped item below this condition.
const.RATOAI.DropConditionFloor = 10

local function rat_loot_is_enemy(unit)
    local side = unit.team and unit.team.side
    return side == "enemy1" or side == "enemy2" or side == "enemyNeutral"
end

---- Only GBO3's attachment items are stripped: they are what a detach hands back as loot.
local function rat_loot_strip(unit, weapon, keep_pct)
    if not RAT_ATT_ENABLED then
        return
    end
    local subweapons = weapon.subweapons or empty_table
    for _, slot in ipairs(weapon.ComponentSlots or empty_table) do
        local st = slot.SlotType
        local cid = weapon.components[st]
        if cid and cid ~= "" and cid ~= slot.DefaultComponent and not subweapons[st] and
            Rat_AttItemFor(cid, weapon) and unit:Random(100) >= keep_pct then
            ---- "init" skips the unload into a squad bag the dead enemy does not have
            weapon:SetWeaponComponent(st, slot.DefaultComponent, "init")
        end
    end
end

local function rat_loot_wear(unit, item, loss)
    local floor = const.RATOAI.DropConditionFloor
    if (item.Condition or 0) <= floor then
        return
    end
    local points = loss.min + unit:Random(loss.max - loss.min + 1)
    item.Condition = Max(floor, item.Condition - points)
end

local orig = RATOAI_WSOriginal(Unit.DropLoot)
local function rat_drop_loot(self, container)
    if not rat_loot_is_enemy(self) then
        return orig(self, container)
    end
    local everything = CurrentModOptions.EnemyDropEverything
    local keep_pct = CurrentModOptions.EnemyAttachmentDrop or 100
    local loss = const.RATOAI.DropConditionLoss[CurrentModOptions.EnemyDropCondition]
    self:ForEachItem(function(item, slot_name)
        if slot_name == "InventoryDead" or item.locked then
            return
        end
        if everything then
            item.drop_chance = 100
        end
        if keep_pct < 100 and IsKindOf(item, "FirearmBase") then
            rat_loot_strip(self, item, keep_pct)
        end
        if loss and IsKindOfClasses(item, "Firearm", "MeleeWeapon", "Armor") then
            rat_loot_wear(self, item, loss)
        end
    end)
    return orig(self, container)
end
RATOAI_WS_WRAPS[rat_drop_loot] = orig

---- Class methods are copied down to subclasses (NonSyncUnit holds its own), so replace every copy.
for _, class in pairs(g_Classes) do
    local fn = rawget(class, "DropLoot")
    if fn and RATOAI_WSOriginal(fn) == orig then
        class.DropLoot = rat_drop_loot
    end
end
