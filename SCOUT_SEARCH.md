# Scout search — what exists and where to look

Enemies that lost sight of the mercs (`Scout_LastLocation`) used to walk onto the last known
spot one at a time and die in turn. The rework splits them into **seekers** and **holders**, adds a
**blind grenade** and an **overwatch on the suspected spot**, and remembers where each merc was seen.

## The pieces

| Piece | What it does | Code |
|---|---|---|
| Enemy memory | Last position + turn each AI team saw each merc. MapVar (survives save/load), wiped on CombatEnd / new combat. | `UTIL.lua:366` (`RATOAI_LastSeen`), recorder `UTIL.lua:393`, reader `RATOAI_LastSeenPos` `UTIL.lua:428` |
| Suspected spot | `unit.last_known_enemy_pos`, only while the unit itself can't see it. | `RATOAI_SuspectPos` `SOURCE_ScoutSearch.lua:48` |
| Believed enemies | Per merc: remembered position if fresh (`ThreatMemoryTurns`), else the suspected spot, with a trust %. Feeds the blind grenade and threat. | `RATOAI_BelievedEnemies` `SOURCE_ScoutSearch.lua:394` |
| Seekers / holders | Per team per turn, the `ScoutSeekers` (2) units with the shortest **walk** to the spot search; the rest in contact range become `RATOAI_Scout_Hold`. Roles in MapVar `RATOAI_ScoutRoles`. | `ScoutRank` / `RATOAI_IsScoutSeeker` `SOURCE_ScoutSearch.lua:444-497`, archetype swap in `UnitProperties:SelectArchetype` `:497` |
| Search band | Seekers approach to a standoff ring around the spot from cover, not onto it. Walk distance via own flood (`RATOAI_SpotDist`). | `ScoutBand` `:66`, `AIPolicyLastEnemyPos:EvalDest` `:168` |
| Rush when out of reach | Any scout (seeker or holder) whose optimal location is beyond this turn's reach gets the distance score normalized over the reachable span, so "stay" can't pass the 80% cut. | `RATOAI_ScoutRushing` `:127`, `SOURCE_AIScoreReachableVoxels.lua:298-317` |
| No-AP trap | Never end a turn next to / in view of the spot without AP to shoot. | `RATOAI_ScoutTrapDest` `:147`, end-turn gate `SOURCE_AIScoreReachableVoxels.lua:337` |
| Hold position | Holders stay out of view of the spot, inside a band. | `AIPolicyScoutHold` `AIPOLICYPOS_ScoutHold.lua:60` |
| Threat from the spot | Lost mercs threaten from the suspected spot; decays per consecutive search turn. | `AIPOLICYPOS_ThreatExposure.lua:1236`, `RATOAI_RefreshScoutTarget` `SOURCE_ScoutSearch.lua:359` |
| Blind grenade | Scores throws only against believed positions (not real hidden mercs), same floor only, scaled by trust. | `AIActionThrowGrenadeBlind` `AIACTION_ScoutSearch.lua:35` |
| Overwatch on spot | Aims where the enemy would come into view from the spot (walk path + LOS), not through walls. | `OverwatchAim` `AIACTION_ScoutSearch.lua:132`, `RATOAI_OverwatchArgsAt` `:250` |
| Fallback overwatch | Units that end attacks seeing nobody overwatch instead of idling. | `SOURCE_AIPlayAttacks.lua`, `AIPlaceFallbackOverwatch` `AIACTION_ScoutSearch.lua:240` |

Presets (editor-made, `items.lua`): `Scout_LastLocation` (`items.lua:1901`, blind grenade weight 150)
and `RATOAI_Scout_Hold` (`items.lua:1953`, overwatch 300, blind grenade 80, crouch, search radius 15).

## Open issue (2026-10-04): grenades from the floor above

**Root cause found:** the units upstairs knew their optimal location was downstairs (`best` on z 7700)
but stayed, because rush mode was seekers-only and keyed on the 20-tile contact band. A trip of 13+
walking tiles gave one turn's progress a few points of OptLocWeight, so "stay" won. Fixed: rush
whenever the optimal location is unreachable this turn (`RATOAI_ScoutRushing`). The blind-grenade
wall gap below is still open.

Report: scouts on the 2nd floor (z 11200) above the mercs (z 7700) keep throwing grenades as if close.
Telemetry (`logs/JA3.exe-20261004-00.31.03`, turn 4): `LegionRaider:461` (seeker) and
`LegionScout:457` (holder) chose the blind grenade from z 11200; suspected spot (166200,166200,7700).

Measured from that floor: predicted arcs toward the mercs mostly hit the ceiling/floor next to the
thrower (z 11200–13200), which the same-floor test rejects. One arc from 457's tile **does** reach
the ground floor (lands ~5 m from MD). Not yet known: which believed position the throws were scored
against and where they actually exploded. Suspects:
1. The blast test is 2D radius + same floor, with **no wall/obstruction check** between impact and
   believed position — a grenade landing outside a wall still "counts" the merc inside.
2. Believed positions are stale (memory up to `ThreatMemoryTurns` old).

Also seen: `RATOAI_LastSeen` was empty mid-combat (turn 5) in the live game — to check whether the
memory survives the load path used.

## Tools

- `tools/dap_probe.py` — evaluate Lua in the running game. Long results: store in
  `const.RATOAI.__out` and read line by line.
- Telemetry: `[RATOTEL_REC]` JSON lines in `logs/JA3.exe-*.log` (`ev = "turn"` has `sig`, `arch`,
  `pos0`, `dest`, actions and weights).
