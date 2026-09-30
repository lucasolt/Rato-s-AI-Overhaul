---------------------------------------------------------------------------------------------------
---- VARIABLE AUTOFIRE LENGTH (GBO3 FEATURE_VariableAutofire)
----
---- AutoFire and MGBurstFire take any length; GBO3 prices each round past the first by RPM and
---- suppresses at SuppressMinShots. The AI used a fixed 8 (AILongShots) or the MG default.
---- Here each variable signature picks the length that maximizes the TURN's expected hits
---- (the same turn model as RATOAI_ExpectedRatio), so:
----   low AP   -> a long burst fits 0 times and a shorter one wins;
----   close    -> the cone ladder stays high, so extra rounds keep paying;
----   far      -> late rounds fall to the ladder floor and stop clearing BurstMarginalHits.
---- SuppressiveFire starts at SuppressMinShots: the minimum that still suppresses.
---------------------------------------------------------------------------------------------------
const.RATOAI = const.RATOAI or {}

if const.RATOAI.BurstChooser == nil then
    const.RATOAI.BurstChooser = true
end
---- stationed MG spends leftover AP on a shorter burst after its full-length ones
if const.RATOAI.BurstTail == nil then
    const.RATOAI.BurstTail = true
end

const.RATOAI.BurstMinShots = 3
const.RATOAI.BurstMaxShots = 12
---- expected hits x100 each extra round must add; without it the 5% ladder floor always wins
const.RATOAI.BurstMarginalHits = 10
const.RATOAI.BurstTailMinShots = 3

---------------------------------------------------------------------------------------------------
---- Ladder prefix cache. A ladder costs ~6 ms per round and is only ~5% off as a prefix of a
---- longer one, so while choosing, RATOAI_ExpectedFor reuses the longest ladder already built.
---- Active only inside the chooser; the chosen length is re-scored with its own exact ladder.
---------------------------------------------------------------------------------------------------
local function LadderKey(action, upos, target, aim, body_part)
    return tostring(action.id) .. "|" .. tostring(upos) .. "|" ..
               tostring(IsValid(target) and target.handle or target) .. "|" .. tostring(aim) ..
               "|" .. tostring(body_part or "Torso")
end

function RATOAI_BurstLadderPrefix(context, action, upos, target, aim, body_part, shots)
    local cache = context and context.__ratoai_burst_ladders
    local e = cache and cache[LadderKey(action, upos, target, aim, body_part)]
    if e and e.n >= shots then
        return e.ratios
    end
end

function RATOAI_BurstLadderStore(context, action, upos, target, aim, body_part, shots, ratios)
    local cache = context and context.__ratoai_burst_ladders
    if not cache then
        return
    end
    local k = LadderKey(action, upos, target, aim, body_part)
    local e = cache[k]
    if not e or e.n < shots then
        cache[k] = {n = shots, ratios = ratios}
    end
end

---------------------------------------------------------------------------------------------------
---- Chooser
---------------------------------------------------------------------------------------------------

---- Same destination/target resolution as GetDestArgs and AIGetAttackArgs.
local function PlanPoint(context)
    local unit = context.unit
    local dest_target = context.dest_target or empty_table
    local upos = context.ai_destination or GetPackedPosAndStance(unit)
    local target = upos and dest_target[upos]
    if not target then
        local cur = GetPackedPosAndStance(unit)
        target = dest_target[cur]
        if target then
            upos = cur
        end
    end
    return upos, target
end

---- One firing of the candidate plus default attacks with the AP left, or N of it when sustained.
local function TurnHits(context, view, upos, target, attacker_pos, sustained)
    local hits, _, _, stance, ap_left, first = RATOAI_ExpectedFor(context, view, upos, target,
                                                                  attacker_pos)
    if not hits then
        return nil
    end
    if sustained then
        return hits
    end
    local rest = 0
    if (ap_left or 0) > 0 and context.default_attack then
        local prev = context.__ratoai_stance_paid
        context.__ratoai_stance_paid = stance and true or prev
        rest = RATOAI_ExpectedFor(context, context.default_attack, upos, target, attacker_pos, nil,
                                  ap_left) or 0
        context.__ratoai_stance_paid = prev
    end
    return (first or 0) + rest
end

local function Choose(signature, context, weapon, id, upos, target, ap)
    local lo = signature.BiasId == "SuppressiveFire" and const.Combat.Autofire.SuppressMinShots or
                   const.RATOAI.BurstMinShots
    local ammo = weapon.ammo and weapon.ammo.Amount or 0
    local hi = Min(Max(const.RATOAI.BurstMaxShots, weapon:GetAutofireShots(CombatActions[id]) or 0),
                   ammo)
    if hi < lo then
        return nil
    end

    local ux, uy, uz = stance_pos_unpack(upos)
    local attacker_pos = point(ux, uy, uz)
    local turn = {}
    local store = context.__ratoai_burst_ladder_store or {}
    context.__ratoai_burst_ladder_store = store
    context.__ratoai_burst_ladders = store
    ---- longest first: its ladder is the prefix every shorter length reads
    local ok, err = pcall(function()
        for n = hi, lo, -1 do
            turn[n] = TurnHits(context, Rat_AutoFireView(n, id), upos, target, attacker_pos,
                               signature.SustainedAttack)
        end
    end)
    context.__ratoai_burst_ladders = nil
    if not ok then
        print("[RATOAI] burst length chooser failed --", err)
        return nil
    end
    if not turn[lo] then
        return nil
    end

    local best = lo
    local marginal = const.RATOAI.BurstMarginalHits or 0
    for n = lo + 1, hi do
        local t = turn[n]
        if t and t - turn[best] >= (n - best) * marginal then
            best = n
        end
    end

    if RATOAI_Debug then
        local row = {}
        for n = lo, hi do
            row[#row + 1] = n .. ":" .. tostring(turn[n])
        end
        printf("[RATOAI] %s: %s burst %d (ap %d) | %s", tostring(context.unit.session_id),
               tostring(signature.BiasId or id), best, ap, table.concat(row, " "))
    end
    return best
end

---- Length for a variable-autofire signature, memoized per (destination, target, AP) so scoring,
---- PrecalcAction and RATOAI_SustainFiringMode all see the same one. nil = keep the old length.
function RATOAI_BurstLengthFor(signature, context, weapon, id)
    if not (const.RATOAI.BurstChooser and context and context.unit) then
        return nil
    end
    if not IsKindOf(weapon, "Firearm") or IsKindOf(weapon, "HeavyWeapon") or
        not Rat_HasVariableAuto(weapon) then
        return nil
    end
    local unit = context.unit
    if not RATOAI_IsAttackModeAvailable(unit, weapon, id) then
        return nil
    end
    local upos, target = PlanPoint(context)
    if not (upos and IsValidTarget(target)) then
        return nil
    end
    local ap = (context.dest_ap and context.dest_ap[upos]) or unit.ActionPoints or 0
    local key = tostring(upos) .. "|" .. tostring(target.handle or target) .. "|" .. ap
    local memo = context.__ratoai_burst
    if not memo then
        memo = {}
        context.__ratoai_burst = memo
    end
    local m = memo[signature]
    if m and m.key == key then
        return m.n or nil
    end
    local n = Choose(signature, context, weapon, id, upos, target, ap)
    memo[signature] = {key = key, n = n or false}
    return n
end

---------------------------------------------------------------------------------------------------
---- TAIL BURST (stationed MG only)
----
---- The basic-attack loop fires the default length and stops when the next full burst does not
---- fit, leaving e.g. 4 AP on a 6-round MG. A shorter burst uses it. Only for units that cannot
---- move anyway: for everyone else that AP may be the end-of-turn cover move.
---------------------------------------------------------------------------------------------------
function RATOAI_FireTailBurst(unit, context, force_or_skip_action)
    if not (const.RATOAI.BurstTail and context and IsValid(unit)) or unit:IsDead() then
        return
    end
    if not (unit:HasStatusEffect("StationedMachineGun") or unit:HasStatusEffect("ManningEmplacement")) then
        return
    end
    local default = context.default_attack
    if not (default and Rat_IsVariableAuto(default)) then
        return
    end
    local weapon = context.weapon
    if not IsKindOf(weapon, "Firearm") or not weapon.ammo then
        return
    end
    local dest = not force_or_skip_action and context.ai_destination or GetPackedPosAndStance(unit)
    local target = context.dest_target and context.dest_target[dest]
    if not IsValidTarget(target) or (IsKindOf(target, "Unit") and target:IsIncapacitated()) then
        return
    end

    local hi = Min(weapon:GetAutofireShots(default) - 1, weapon.ammo.Amount)
    for n = hi, const.RATOAI.BurstTailMinShots, -1 do
        local view = Rat_AutoFireView(n, default.id)
        local args, has_ap = AIGetAttackArgs(context, view, "Torso", "None", target)
        if has_ap then
            args.num_shots = n
            if RATOAI_Debug then
                printf("[RATOAI] %s: tail burst %d with %d AP", tostring(unit.session_id), n,
                       unit.ActionPoints)
            end
            AIPlayCombatAction(default.id, unit, nil, args)
            return
        end
    end
end
