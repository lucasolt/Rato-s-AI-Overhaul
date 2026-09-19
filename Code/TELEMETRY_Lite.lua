---------------------------------------------------------------------------------------------------
-- Lite AI telemetry: decisions and outcomes in normal play, no RATOAI_Debug needed.
-- One `[RATOTEL_REC]` JSON line per AI unit turn and per AI attack, in the game log;
-- `python tools/extract_telemetry.py` pulls them out. Records carry `tel = "lite"`.
-- Only reads what the turn already computed; never runs extra AI work.
---------------------------------------------------------------------------------------------------

const.RATOAI = const.RATOAI or {}

local MAX_ACTIONS = 24
local MAX_BEHAVIORS = 12

local session_id = tostring(GetPreciseTicks())
local mod_version = CurrentModDef.version
local pending = setmetatable({}, {__mode = "k"})
local reported = {}

---- const.RATOAI.TelemetryLite (console) wins; else the TelemetryLite mod option; else on
local function Enabled()
    local v = const.RATOAI.TelemetryLite
    if v == nil then
        v = CurrentModOptions.TelemetryLite
    end
    if v == false then
        return false
    end
    ---- Rato Dev's full recorder writes the same records with more fields; don't duplicate them
    local full = const.RATOAI.TelemetryFullActive
    return not (full and full())
end

local function Report(where, err)
    local key = where .. tostring(err)
    if not reported[key] then
        reported[key] = true
        printf("[RATOAI_TEL] %s failed: %s", where, tostring(err))
    end
end

local function Emit(rec)
    rec.tel = "lite"
    rec.ver = mod_version
    rec.sess = session_id
    rec.t = GameTime()
    rec.sector = gv_CurrentSectorId
    rec.turn = g_Combat and g_Combat.current_turn
    local err, json = LuaToJSON(rec)
    if err or not json then
        Report("LuaToJSON(" .. tostring(rec.ev) .. ")", err)
        return
    end
    DebugPrint("[RATOTEL_REC] " .. tostring(json) .. "\n")
end

---- whole units: `/` is integer division here, so a tenths scale would only truncate
local function Units(v, scale)
    return v and MulDivRound(v, 1, scale) or nil
end

local function DestInfo(dest)
    if not dest then
        return nil
    end
    local x, y, z, stance_idx = stance_pos_unpack(dest)
    return {x = x, y = y, z = z, stance = StancesList[stance_idx]}
end

local function IsAIUnit(unit)
    return IsKindOf(unit, "Unit") and unit.team and unit.team.control == "AI"
end

---------------------------------------------------------------------------------------------------
-- snapshots
---------------------------------------------------------------------------------------------------

local function SnapshotBehaviors(debug_data)
    local out = {}
    for _, d in ipairs(debug_data.behaviors or empty_table) do
        if #out >= MAX_BEHAVIORS then
            break
        end
        out[#out + 1] = {
            n = tostring(d.name),
            s = d.score,
            pri = d.priority and true or nil,
            off = d.disable and true or nil
        }
    end
    return out
end

local function SnapshotActions(context)
    local total = 0
    for _, descr in ipairs(context.choose_actions or empty_table) do
        if not descr.priority then
            total = total + Max(0, descr.weight or 0)
        end
    end
    local out = {}
    for _, descr in ipairs(context.choose_actions or empty_table) do
        if #out >= MAX_ACTIONS then
            break
        end
        out[#out + 1] = {
            n = descr.action and tostring(descr.action:GetEditorView()) or "BaseAttack",
            w = descr.weight,
            pct = (total > 0 and not descr.priority) and
                MulDivRound(Max(0, descr.weight or 0), 100, total) or nil,
            pri = descr.priority and true or nil,
            off = descr.disabled_by or nil
        }
    end
    return out, total
end

local function CaptureBefore(unit, rec)
    local ctx = unit.ai_context
    if not ctx then
        return
    end
    rec.unit = unit.session_id
    rec.arch = ctx.archetype and ctx.archetype.id
    rec.def = unit.unitdatadef_id
    rec.side = unit.team and unit.team.side
    rec.hp = unit.HitPoints
    rec.maxhp = unit.MaxHitPoints
    rec.ap0 = Units(unit.ActionPoints, const.Scale.AP)
    rec.beh = ctx.behavior and tostring(ctx.behavior:GetEditorView())
    rec.weapon = ctx.weapon and ctx.weapon.class
    rec.atk = ctx.default_attack and ctx.default_attack.id
    rec.max_atk = ctx.max_attacks

    rec.pos0 = DestInfo(GetPackedPosAndStance(unit))
    rec.best = DestInfo(ctx.best_dest)
    rec.best_score = ctx.best_score
    rec.dest = DestInfo(ctx.ai_destination)
    rec.dest_score = ctx.best_end_score

    local d = ctx.ai_destination
    if d then
        local tgt = ctx.dest_target and ctx.dest_target[d]
        rec.target = IsValid(tgt) and tgt.session_id or nil
        rec.tgt_score = ctx.dest_target_score and ctx.dest_target_score[d]
        rec.hit_score = ctx.dest_hit_score and ctx.dest_hit_score[d]
        rec.dest_ap = Units(ctx.dest_ap and ctx.dest_ap[d], const.Scale.AP)
        rec.cth_plan = ctx.dest_cth and ctx.dest_cth[d]
    end

    local upos = unit:GetPos()
    local visible, closest = 0, nil
    for _, enemy in ipairs(ctx.enemies or empty_table) do
        if IsValid(enemy) and not enemy:IsDead() then
            if ctx.enemy_visible and ctx.enemy_visible[enemy] then
                visible = visible + 1
            end
            local epos = ctx.enemy_pos and ctx.enemy_pos[enemy]
            local dist = epos and upos:Dist(epos)
            if dist and (not closest or dist < closest) then
                closest = dist
            end
        end
    end
    rec.enemies = #(ctx.enemies or empty_table)
    rec.enemies_vis = visible
    rec.closest = Units(closest, const.SlabSizeX)
end

local function CaptureAfter(unit, rec, status)
    rec.status = status and tostring(status) or nil
    if not IsValid(unit) or unit:IsDead() then
        rec.dead = true
        return
    end
    rec.ap1 = Units(unit.ActionPoints, const.Scale.AP)
    rec.pos1 = DestInfo(GetPackedPosAndStance(unit))
    if rec.pos0 then
        local a = point(rec.pos0.x, rec.pos0.y)
        rec.moved = Units(a:Dist2D(point(rec.pos1.x, rec.pos1.y)), const.SlabSizeX)
    end
    local ctx = unit.ai_context
    rec.degraded = ctx and ctx.__ratoai_degraded and true or nil
end

---------------------------------------------------------------------------------------------------
-- wrappers (originals kept on the Unit classdef so a mod reload never wraps our own wrapper)
---------------------------------------------------------------------------------------------------

Unit.ratoai_tel_orig = Unit.ratoai_tel_orig or {
    StartAI = Unit.StartAI,
    AIChooseSignatureAction = AIChooseSignatureAction,
    AIExecuteUnitBehavior = AIExecuteUnitBehavior
}
local orig = Unit.ratoai_tel_orig

function Unit:StartAI(debug_data, forced_behavior)
    if not Enabled() then
        return orig.StartAI(self, debug_data, forced_behavior)
    end
    ---- vanilla StartAI only writes behavior scores into debug_data; passing one is how we read them
    local dd = debug_data or {}
    local res = orig.StartAI(self, dd, forced_behavior)
    ---- StartAI bails without a context for dead/unconscious units; leave no stale record then
    local ok, err = pcall(function()
        pending[self] = self.ai_context and {ev = "turn", behs = SnapshotBehaviors(dd)} or nil
    end)
    if not ok then
        Report("StartAI", err)
    end
    return res
end

function AIChooseSignatureAction(context)
    local action = orig.AIChooseSignatureAction(context)
    local rec = Enabled() and pending[context.unit]
    if rec then
        local ok, err = pcall(function()
            rec.actions, rec.actions_total = SnapshotActions(context)
            rec.sig = action and tostring(action:GetEditorView()) or "(none)"
        end)
        if not ok then
            Report("AIChooseSignatureAction", err)
        end
    end
    return action
end

function AIExecuteUnitBehavior(unit, force_or_skip_action)
    local rec = Enabled() and pending[unit]
    if not rec then
        return orig.AIExecuteUnitBehavior(unit, force_or_skip_action)
    end
    rec.run = (rec.run or 0) + 1
    local ok, err = pcall(CaptureBefore, unit, rec)
    if not ok then
        Report("CaptureBefore", err)
    end

    local status = orig.AIExecuteUnitBehavior(unit, force_or_skip_action)

    ok, err = pcall(CaptureAfter, unit, rec, status)
    if not ok then
        Report("CaptureAfter", err)
    end
    Emit(rec)
    ---- a "restart" status re-runs this; the next pass is a fresh record with the same behavior scores
    pending[unit] = {ev = "turn", behs = rec.behs, run = rec.run}
    return status
end

---------------------------------------------------------------------------------------------------
-- outcomes and combat markers
---------------------------------------------------------------------------------------------------

function OnMsg.OnAttack(attacker, action, target, results, attack_args)
    if not g_Combat or not IsAIUnit(attacker) or not Enabled() then
        return
    end
    local ok, err = pcall(function()
        local hits = 0
        for _, obj in ipairs(results.hit_objs or empty_table) do
            if IsKindOf(obj, "Unit") then
                hits = hits + 1
            end
        end
        Emit({
            ev = "attack",
            unit = attacker.session_id,
            action = action and action.id,
            weapon = results.weapon and results.weapon.class,
            target = IsKindOf(target, "Unit") and target.session_id or nil,
            ---- attack out of the unit's own turn: overwatch, interrupt
            own_turn = g_Teams[g_CurrentTeam] == attacker.team or nil,
            aim = attack_args and attack_args.aim,
            stance = attacker.stance,
            cth = results.chance_to_hit,
            shots = results.shots and #results.shots or nil,
            unit_hits = hits,
            miss = results.miss and true or nil,
            crit = results.crit and true or nil,
            dmg = results.total_damage,
            kills = #(results.killed_units or empty_table)
        })
    end)
    if not ok then
        Report("OnAttack", err)
    end
end

function OnMsg.CombatStart()
    if not Enabled() then
        return
    end
    local sides = {}
    for _, team in ipairs(g_Teams or empty_table) do
        if #(team.units or empty_table) > 0 then
            sides[#sides + 1] = string.format("%s:%d", tostring(team.side), #team.units)
        end
    end
    Emit({ev = "combat_start", teams = table.concat(sides, " ")})
end

function OnMsg.CombatEnd()
    if not Enabled() then
        return
    end
    Emit({ev = "combat_end"})
    FlushLogFile()
end

---- the log is buffered; flushing per turn bounds a crash to the turn in progress
function OnMsg.TurnStart()
    if Enabled() then
        FlushLogFile()
    end
end
