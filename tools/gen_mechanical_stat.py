"""Generate the hardcoded Mechanical stat for every enemy in Code/PATCH_UnitData.lua.

Vanilla leaves Mechanical at 0 on most enemies, and UnitData:RandomizeStats skips a stat
that is 0, so it never varies. Writing a value on the UnitDataDef class is the only level
that sticks (a write on a live Unit or on gv_UnitData is dropped by SyncWithSession), and
the engine then spreads it +-10 per unit for the classes with Randomization = true.

Value = affiliation base + 40% of vanilla Marksmanship + a name-seeded jitter, never below
the vanilla value. Deterministic: re-running reproduces the same numbers.
"""
import io, os, re, random, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFS = r"C:\Steam\steamapps\common\Jagged Alliance 3\ModTools\Src\Lua\UnitDataCompositeDef"
TARGET = os.path.join(ROOT, "Code", "PATCH_UnitData.lua")

AFFILIATION = {
    "Legion": 5, "Thugs": 5, "Rebel": 10, "Other": 10, "Civilian": 5,
    "Army": 15, "Adonis": 20, "Secret": 20, "SuperSoldiers": 25, "Militia": 10,
}
MARKSMANSHIP_SHARE = 40   # percent of vanilla Marksmanship folded in as the tier term
JITTER = 4                # +-, name-seeded, so same-tier classes are not identical


def vanilla(name, key, default):
    path = os.path.join(DEFS, name + ".generated.lua")
    text = io.open(path, encoding="utf-8").read()
    m = re.search(r"^\t%s = (.+?),\s*$" % key, text, re.M)
    if not m:
        return default
    return m.group(1).strip('"')


def roll(name):
    if vanilla(name, "species", "Human") != "Human":   # a hyena never jams a weapon
        return None
    marksmanship = int(vanilla(name, "Marksmanship", 60))
    if marksmanship == 0:                              # other non-shooters
        return None
    current = int(vanilla(name, "Mechanical", 0))
    affiliation = AFFILIATION.get(vanilla(name, "Affiliation", "Other"), 10)
    tier = marksmanship * MARKSMANSHIP_SHARE // 100
    jitter = random.Random("RATOAI:" + name).randint(-JITTER, JITTER)
    return min(100, max(current, affiliation + tier + jitter))


def props_span(text, start):
    """Return (open_brace, close_brace) of the props table of a call starting at `start`."""
    i = text.index("{", start)
    depth = 0
    for j in range(i, len(text)):
        if text[j] == "{":
            depth += 1
        elif text[j] == "}":
            depth -= 1
            if depth == 0:
                return i, j
    raise ValueError("unbalanced table at %d" % start)


def main():
    text = io.open(TARGET, encoding="utf-8").read()
    calls = list(re.finditer(r"RATOAI_ChangeUnitDataDef\(\s*([A-Za-z0-9_]+)\s*,", text))
    out, cursor, rolled, skipped = [], 0, {}, []
    for call in calls:
        name = call.group(1)
        open_b, close_b = props_span(text, call.end())
        body = re.sub(r"Mechanical = \d+, ?", "", text[open_b + 1:close_b])   # idempotent
        body = re.sub(r"\n[ ]*Mechanical = \d+,", "", body)
        value = roll(name)
        if value is None:
            skipped.append(name)
        else:
            rolled[name] = value
            multiline = re.match(r"[ ]*\n([ ]*)\S", body)
            if multiline:                      # own line, aligned with the other entries
                body = "\n%sMechanical = %d,%s" % (multiline.group(1), value, body)
            else:
                body = "Mechanical = %d, %s" % (value, body.lstrip())
        out.append(text[cursor:open_b + 1])
        out.append(body)
        cursor = close_b
    out.append(text[cursor:])
    result = "".join(out)

    if "--check" in sys.argv:
        for name in sorted(rolled):
            print("%-34s %3d" % (name, rolled[name]))
        print("\n%d rolled, %d skipped: %s" % (len(rolled), len(skipped), ", ".join(skipped)))
        return
    io.open(TARGET, "w", encoding="utf-8", newline="\n").write(result)
    print("wrote %d values to %s" % (len(rolled), TARGET))


main()
