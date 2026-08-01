# Design principles / guardrails

Copied and tightened from the Project Brief.

1. **Extend existing systems, don’t invent parallel ones.**  
   Jobs, AI packages, dialogue, wildlife tables, research, buildings first.

2. **Player-proximity scope, not global simulation.**  
   If it needs always-on global brains, re-scope or cut.

3. **Static checks once; character-state checks cheap per tick.**  
   Building water adjacency at place time. Swim flag every tick is fine.

4. **No real collision/physics for faked platforms.**  
   Boats/crew = position + animation overrides, not moving navmesh geometry.

5. **Reframe engine bans; don’t unlock them first.**  
   e.g. standing-state so existing combat applies instead of “combat while swimming.”

6. **Single write path to world state.**  
   All durable WSM changes go through `Mutate*`; log + optional trim.

7. **Cvars default OFF (LAW 2).**  
   New expensive paths ship dark until soak-tested.

8. **Standalone then bundle.**  
   Workshop discoverability beats monolith-only releases.

9. **Passion-project budget.**  
   Simple and shippable > robust and general.

10. **Not Kenshi 2 branding.**  
    Respect Lo-Fi’s official sequel naming.
