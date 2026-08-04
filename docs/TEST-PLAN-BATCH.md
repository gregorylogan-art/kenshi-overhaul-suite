# Batch test plan — one Kenshi session, everything at once

> Greg: *"doing 1 system and then closing and reloading kenshi is honestly
> exhausting. and 1 fix 1 broken 1 crash each time burns time like noones
> business."*
>
> Fair. So: **one restart, one pass, one report.** Everything below is already
> deployed and headless-green; none of it has been seen in a live game.
>
> Ordered so a failure early does not invalidate what comes after, and so the
> risky engine calls are probed **before** anything is shown on screen.

---

## Before you start

```lua
Fishing.status()
```
Confirms the modules loaded. If this errors, stop — nothing else will work.

---

## PHASE 1 — probes (safe, draw nothing, ~30 seconds)

Run all three back to back. **None of them show anything or change any state.**
They exist so we learn whether the risky calls are reachable *before* we make
them in the middle of gameplay.

```lua
Fishing.probeContainer()
```
```lua
Fishing.probeInvGui()
```
```lua
Items.verify()
```

**What I need from you:** nothing but "ran clean" or "crashed at step N".
The probe prints each step before it acts, so if Kenshi dies the log names the
exact call.

**If `probeContainer` reaches step 5**, a separate catch pane works and the rest
of the plan is meaningful. **If it stops at step 3** (`getBackpack`), your
character isn't wearing a backpack — put one on and re-run, because that is the
container the pane comes from.

---

## PHASE 2 — the fishing loop (~3 minutes)

Wade in, press **G**.

| Check | Expect |
|---|---|
| Bar appears over the fisher | caption + filling smoothly over 5s |
| Bar **fills** rather than snapping | this was the 0..1000 vs 0..1 fix |
| Catches log as `banked (N in catch bag)` | nothing enters your inventory yet |
| Press **G** again | fish are **deposited into a container** and a **pane opens** |

**The headline question: does a separate pane open, and are the fish in it?**

The log will say which it used:
- `deposited N into backpack` — the real separate pane
- `deposited N into character pack` — fallback, still works but not separate

---

## PHASE 3 — cooking (~1 minute)

With fish banked (fish a little, **don't** press G to stop):

```lua
Cooking.status()
```

**Expect:** `can cook: true (N Small Fish ready to cook)`.
If it says *"no Small Fish banked"* while you clearly have fish, that is the
name-mismatch class again and I want the exact wording.

```lua
Cooking.cook(getSelectedCharacter(), 5)
```

**Expect:** a mix of cooked and burnt, roughly 40% burnt at low skill. Burning
is the economy sink, so seeing some burn is the system working, not failing.

---

## PHASE 4 — the new modules (~1 minute, no fishing needed)

```lua
Skills.status()
```
Lists measured stat ids and, separately, the ones we refuse to guess.

```lua
Economy.registerVendor("dock", 500) Economy.mint("dock", 500, "test") Economy.report()
```

```lua
Storage.report("dock")
```

**Expect:** `invariants CLEAN` from the economy report. A violation line here is
a real bug and worth stopping for.

---

## PHASE 5 — the freeze, deliberately (~2 minutes)

This is the one I most want data on, because we have been wrong about it four
times.

1. Fill your pack until fishing stops
2. **Mash G at a full pack** — this is what produced the last freeze
3. Try to open your inventory and stats screen

**If the character freezes:** run `Fishing.unstick()` *before* restarting. If
that recovers them, the freeze is a wedged GUI window rather than data
corruption, and #37 changes completely.

---

## How to report

One line per phase is plenty:

```
P1 ok / P2 pane opened, fish inside / P3 cook said no fish / P4 ok / P5 no freeze
```

Paste log lines only where something failed. I read
`mods/KenshiLua/plugin/KenshiLua_*.log` directly, so I can pull the detail
myself — I mostly need to know **which phase** broke.

---

## Kill switches, if something misbehaves mid-session

No restart needed for any of these:

```lua
Fishing.setOpenPack(false)   -- stop the pane opening
Fishing.setBar(false)        -- stop the floating bar
Fishing.setXp(false)         -- stop XP grants
Fishing.setBarHeight(8)      -- move the bar up/down
```
