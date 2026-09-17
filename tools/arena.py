#!/usr/bin/env python3
"""AI vs AI arena driver (Rato Dev RATOARENA_AIvsAI.lua), over DAP.

    python tools/arena.py space Soldier RATOAI_Sniper
    python tools/arena.py match --side enemy1 --genome g.json --save "Arena.savegame.sav" --max-turns 12
    python tools/arena.py evolve --run soldier1 --side enemy1 --archetypes Soldier \
        --save "Arena.savegame.sav" --pop 6 --gens 10

A genome is {archetype_id: {path: number}}; paths come from `space`
(e.g. Behaviors/Standard#1/EndTurnPolicies/AIPolicyDealDamage#1/Weight).
Everything lands in arena/ (results.jsonl, space/, evolve/<run>/state.json).
Evolution runs in Python because mods cannot write files; the game only applies a genome and
reports a match. `evolve` is resumable: rerun the same command to continue.
"""

import argparse
import hashlib
import json
import os
import random
import re
import socket
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import dap_probe  # noqa: E402

ROOT = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "arena")
PAGE = 400  # the adapter truncates a result near 512 chars


# ---------------------------------------------------------------------------------------------
# game access
# ---------------------------------------------------------------------------------------------

def lua(expr, retries=40):
    """Evaluate one expression on a fresh connection; retries while the game is busy (loads, AI turns)."""
    last = None
    for attempt in range(retries):
        dap = None
        try:
            dap = dap_probe.Dap(timeout=15.0)
            dap_probe.handshake(dap)
            ok, out = dap_probe.evaluate(dap, expr)
            if not ok:
                raise RuntimeError("lua error: %s\n  in: %s" % (out, expr[:200]))
            return out
        except (dap_probe.DapError, socket.timeout, OSError) as exc:
            last = exc
            time.sleep(min(3 + 3 * attempt, 30))  # the adapter stalls during heavy AI turns
        finally:
            if dap:
                dap.close()
    raise RuntimeError("DAP unreachable: %s" % last)


def lua_str(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def lua_value(v):
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, (int, float)):
        return str(int(round(v)))  # engine math is integer-only
    if isinstance(v, str):
        return lua_str(v)
    if isinstance(v, dict):
        return "{" + ", ".join("[%s] = %s" % (lua_str(k), lua_value(x)) for k, x in v.items()) + "}"
    raise TypeError(type(v))


def read_paged(key, length):
    parts, off = [], 0
    while off < length:
        parts.append(lua("RatoArena_Read(%s, %d, %d)" % (lua_str(key), off, PAGE)))
        off += PAGE
    return "".join(parts)


def wait_until(check, timeout, every=5.0, what="condition"):
    end = time.time() + timeout
    while time.time() < end:
        v = check()
        if v:
            return v
        time.sleep(every)
    raise TimeoutError("timed out waiting for " + what)


def load_save(savename, timeout=240):
    lua("RatoArena_Load(%s)" % lua_str(savename))
    time.sleep(5)
    state = wait_until(lambda: (lambda s: s if s != "loading" else None)(lua("tostring(RATOARENA.load_state)")),
                       timeout, what="savegame load")
    if state != "ok":
        raise RuntimeError("LoadGame failed: %s" % state)
    wait_until(lambda: lua("tostring(g_Combat ~= nil and g_Teams ~= nil and g_CurrentTeam ~= nil)") == "true",
               60, every=2, what="combat after load")
    time.sleep(3)  # let the combat thread reach its turn wait


# ---------------------------------------------------------------------------------------------
# match
# ---------------------------------------------------------------------------------------------

def run_match(genomes, label, max_turns, save=None, time_factor=None, timeout=3600):
    """genomes: {side: genome}. Returns the result dict."""
    if save:
        load_save(save)
    if lua("tostring(g_Combat ~= nil)") != "true":
        raise RuntimeError("no combat running; load a save taken during combat (--save)")
    unknown = []
    for side, genome in genomes.items():
        u = lua("RatoArena_SetGenome(%s, %s)" % (lua_str(side), lua_value(genome) if genome else "false"))
        if u:
            unknown.append("%s: %s" % (side, u))
    if unknown:
        raise RuntimeError("unknown genome paths -> " + " | ".join(unknown))
    opts = {"label": label, "max_turns": max_turns}
    if time_factor:
        opts["time_factor"] = time_factor
    started = lua("RatoArena_Start(%s)" % lua_value(opts))
    if started != "ok":
        raise RuntimeError("RatoArena_Start: " + started)

    t0 = time.time()
    last = None
    while True:
        status = lua("RatoArena_Status()")
        if status != last:
            print("   [%4ds] %s" % (time.time() - t0, status), flush=True)
            last = status
        if status.startswith("done"):
            length = int(status.split()[-1])
            break
        if time.time() - t0 > timeout:
            lua('RatoArena_Stop("driver_timeout")')
            length = int(lua("RatoArena_Status()").split()[-1])
            break
        time.sleep(10)

    result = json.loads(read_paged("last_result", length))
    for side in genomes:
        lua("RatoArena_SetGenome(%s, false)" % lua_str(side))
    append_jsonl(os.path.join(ROOT, "results.jsonl"), dict(result, genomes=genomes, save=save))
    return result


def fitness(result, side):
    """Higher is better for `side`: HP-fraction trade, incapacitation trade, win/loss bonus."""
    own_hp0 = own_hp = foe_hp0 = foe_hp = own_out = foe_out = own_n = foe_n = 0
    for s, st in result["sides"].items():
        out = st.get("dead", 0) + st.get("down", 0)
        if s == side:
            own_hp0, own_hp, own_out, own_n = st.get("hp0", 0), st.get("hp", 0), out, st.get("units", 0)
        else:
            foe_hp0 += st.get("hp0", 0)
            foe_hp += st.get("hp", 0)
            foe_out += out
            foe_n += st.get("units", 0)
    frac = lambda lost, total: lost / total if total else 0.0  # noqa: E731
    score = 100 * (frac(foe_hp0 - foe_hp, foe_hp0) - frac(own_hp0 - own_hp, own_hp0))
    score += 100 * (frac(foe_out, foe_n) - frac(own_out, own_n))
    winner = result.get("winner")
    if winner == side:
        score += 50
    elif winner not in (None, "draw"):
        score -= 50
    return round(score, 2)


# ---------------------------------------------------------------------------------------------
# genome space and mutation
# ---------------------------------------------------------------------------------------------

def fetch_space(arch):
    length = int(lua("RatoArena_Space(%s)" % lua_str(arch)))
    if length < 0:
        raise RuntimeError("unknown archetype " + arch)
    space = json.loads(read_paged("space:" + arch, length))
    path = os.path.join(ROOT, "space", arch + ".json")
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(space, fh, indent=1)
    return space


def mutate(parent, space, rate, sigma_pct, rng):
    """Gaussian relative step per gene with probability `rate`; at least one gene always moves."""
    child = {a: dict(parent.get(a, {})) for a in space}
    flat = [(a, e) for a, entries in space.items() for e in entries]
    picked = [x for x in flat if rng.random() < rate] or [rng.choice(flat)]
    for arch, e in picked:
        cur = child[arch].get(e["p"], e["v"])
        step = abs(cur) * sigma_pct / 100.0 if cur else 10.0
        new = int(round(cur + rng.gauss(0, step)))
        lo = e.get("min", 0 if e["v"] >= 0 else None)
        hi = e.get("max")
        if lo is not None:
            new = max(lo, new)
        if hi is not None:
            new = min(hi, new)
        if new == e["v"]:
            child[arch].pop(e["p"], None)
        else:
            child[arch][e["p"]] = new
    return {a: g for a, g in child.items() if g}


def genome_id(genome):
    return hashlib.sha1(json.dumps(genome, sort_keys=True).encode()).hexdigest()[:10]


def append_jsonl(path, rec):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "a", encoding="utf-8") as fh:
        fh.write(json.dumps(rec, sort_keys=True) + "\n")


# ---------------------------------------------------------------------------------------------
# commands
# ---------------------------------------------------------------------------------------------

def cmd_space(args):
    for arch in args.archetypes:
        space = fetch_space(arch)
        print("%s: %d numeric genes -> arena/space/%s.json" % (arch, len(space), arch))


def cmd_saves(args):
    expr = ('(function() local err, list = Savegame.ListForTag("savegame"); if err then return err end; '
            'local o = {} for _, s in ipairs(list) do if not %s or s.savename:lower():find(%s, 1, true) '
            'then o[#o + 1] = s.savename end end return table.concat(o, "|") end)()')
    flt = lua_str(args.filter.lower()) if args.filter else "false"
    out = lua(expr % (flt, flt))
    for n in [x for x in out.split("|") if x][:args.limit]:
        print("  " + n)


def cmd_match(args):
    genome = {}
    if args.genome:
        with open(args.genome, encoding="utf-8") as fh:
            genome = json.load(fh)
    res = run_match({args.side: genome}, args.label, args.max_turns, args.save, args.time_factor)
    print(json.dumps({k: res[k] for k in ("winner", "reason", "turns", "sides")}, indent=1))
    print("fitness(%s) = %s" % (args.side, fitness(res, args.side)))


def cmd_compose(args):
    """One unit of every missing archetype, spawned into the live combat. Save the game afterwards."""
    print(lua("RatoArena_Census(%s)" % lua_str(args.side)))
    opts = {"dry": args.dry}
    if args.remove:
        opts["remove"] = args.remove
    if args.family:
        opts["family"] = args.family
    print(lua("RatoArena_Compose(%s, %s)" % (lua_str(args.side), lua_value(opts))))
    if not args.dry:
        print(lua("RatoArena_Census(%s)" % lua_str(args.side)))
        print("save the game now (in-game menu) and use that savegame with --save")


def cmd_report(args):
    """Fitness per label from results.jsonl, plus a run's generation ladder."""
    import statistics
    path = os.path.join(ROOT, "results.jsonl")
    by_label = {}
    if os.path.exists(path):
        for line in open(path, encoding="utf-8"):
            r = json.loads(line)
            by_label.setdefault(r.get("label", ""), []).append(fitness(r, args.side))
    print("fitness for %s, per label (matches, mean, spread = noise floor)" % args.side)
    for label, f in sorted(by_label.items()):
        spread = max(f) - min(f) if len(f) > 1 else 0.0
        dev = statistics.pstdev(f) if len(f) > 1 else 0.0
        print("  %-28s n=%-3d mean %7.2f  spread %6.2f  stdev %5.2f" % (label[:28], len(f), sum(f) / len(f), spread, dev))
    if args.run:
        gens = os.path.join(ROOT, "evolve", args.run, "generations.jsonl")
        if not os.path.exists(gens):
            print("no generations yet for run " + args.run)
            return
        print("generation ladder for %s" % args.run)
        best = None
        for line in open(gens, encoding="utf-8"):
            g = json.loads(line)
            best = g
            print("  gen %-3d best %7.2f   all %s" % (g["gen"], g["best_score"], ", ".join("%.1f" % x for x in g["scores"])))
        print("best genome so far (re-run it with `match` before believing it):")
        print(json.dumps(best["best"], indent=1))


def cmd_evolve(args):
    run_dir = os.path.join(ROOT, "evolve", args.run)
    state_path = os.path.join(run_dir, "state.json")
    if os.path.exists(state_path):
        with open(state_path, encoding="utf-8") as fh:
            state = json.load(fh)
        print("resuming %s at generation %d" % (args.run, state["gen"]))
    else:
        rx = re.compile(args.genes)
        space = {a: [e for e in fetch_space(a) if rx.search(e["p"])] for a in args.archetypes}
        state = {"args": vars(args), "gen": 0, "space": space, "evals": {},
                 "population": [{}], "seed": args.seed}
        print("new run %s: %s" % (args.run, ", ".join("%s=%d genes" % (a, len(s)) for a, s in space.items())))
    cfg = state["args"]
    rng = random.Random("%s:%d" % (state["seed"], state["gen"]))

    def save_state():
        os.makedirs(run_dir, exist_ok=True)
        with open(state_path + ".tmp", "w", encoding="utf-8") as fh:
            json.dump(state, fh, indent=1)
        os.replace(state_path + ".tmp", state_path)

    def evaluate_genome(genome):
        gid = genome_id(genome)
        ev = state["evals"].setdefault(gid, {"genome": genome, "scores": []})
        while len(ev["scores"]) < cfg["repeats"]:
            label = "%s/g%d/%s/%d" % (args.run, state["gen"], gid, len(ev["scores"]))
            print(" match %s (%d genes changed)" % (label, sum(len(g) for g in genome.values())), flush=True)
            res = run_match({cfg["side"]: genome}, label, cfg["max_turns"], cfg["save"], cfg["time_factor"])
            ev["scores"].append(fitness(res, cfg["side"]))
            save_state()
        return sum(ev["scores"]) / len(ev["scores"])

    while state["gen"] < cfg["gens"]:
        while len(state["population"]) < cfg["pop"]:
            parent = rng.choice(state["population"][:max(1, cfg["elite"])])
            state["population"].append(mutate(parent, state["space"], cfg["rate"], cfg["sigma"], rng))
        save_state()
        scored = [(evaluate_genome(g), g) for g in state["population"]]
        scored.sort(key=lambda x: -x[0])
        best = scored[0]
        append_jsonl(os.path.join(run_dir, "generations.jsonl"),
                     {"gen": state["gen"], "scores": [s for s, _ in scored], "best": best[1], "best_score": best[0]})
        print("generation %d: best %.2f (%s)  scores %s" % (state["gen"], best[0], genome_id(best[1]),
                                                           ", ".join("%.1f" % s for s, _ in scored)))
        state["population"] = [g for _, g in scored[:cfg["elite"]]]
        state["gen"] += 1
        rng = random.Random("%s:%d" % (state["seed"], state["gen"]))
        save_state()
    print("done; best genome in %s (generations.jsonl)" % run_dir)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("space", help="dump the numeric genes of archetypes")
    p.add_argument("archetypes", nargs="+")
    p.set_defaults(fn=cmd_space)

    p = sub.add_parser("saves", help="list savegame names usable with --save")
    p.add_argument("filter", nargs="?", help="substring, case-insensitive")
    p.add_argument("--limit", type=int, default=30)
    p.set_defaults(fn=cmd_saves)

    p = sub.add_parser("match", help="run one match")
    p.add_argument("--side", default="enemy1")
    p.add_argument("--genome", help="JSON file {archetype: {path: value}}; omit for vanilla weights")
    p.add_argument("--save", help="savegame to load first, e.g. 'Arena.savegame.sav'")
    p.add_argument("--max-turns", type=int, default=12)
    p.add_argument("--time-factor", type=int)
    p.add_argument("--label", default="manual")
    p.set_defaults(fn=cmd_match)

    p = sub.add_parser("compose", help="spawn one unit per missing archetype into the live combat")
    p.add_argument("--side", default="enemy1")
    p.add_argument("--dry", action="store_true", help="only report what would be spawned")
    p.add_argument("--remove", type=int, help="despawn this many of the most common archetype first")
    p.add_argument("--family", help="unit family to draw from (default: the one already fighting)")
    p.set_defaults(fn=cmd_compose)

    p = sub.add_parser("report", help="summarize results.jsonl and a run's generations")
    p.add_argument("--side", default="enemy1")
    p.add_argument("--run", help="also show this evolve run's ladder")
    p.set_defaults(fn=cmd_report)

    p = sub.add_parser("evolve", help="(mu+lambda) evolution of one side's archetype weights")
    p.add_argument("--run", required=True)
    p.add_argument("--side", default="enemy1")
    p.add_argument("--archetypes", nargs="+", default=["Soldier"])
    p.add_argument("--genes", default=r"/Weight$", help="regex over gene paths to mutate")
    p.add_argument("--save", required=True, help="savegame reloaded before every match")
    p.add_argument("--pop", type=int, default=6)
    p.add_argument("--elite", type=int, default=2)
    p.add_argument("--gens", type=int, default=10)
    p.add_argument("--repeats", type=int, default=2, help="matches per genome (combat is noisy)")
    p.add_argument("--rate", type=float, default=0.15, help="per-gene mutation probability")
    p.add_argument("--sigma", type=float, default=25.0, help="mutation std dev, percent of value")
    p.add_argument("--max-turns", type=int, default=12)
    p.add_argument("--time-factor", type=int)
    p.add_argument("--seed", type=int, default=1)
    p.set_defaults(fn=cmd_evolve)

    args = ap.parse_args()
    args.fn(args)


if __name__ == "__main__":
    main()
