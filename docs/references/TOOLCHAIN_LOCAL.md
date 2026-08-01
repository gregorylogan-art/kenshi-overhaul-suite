# Local toolchain clones

These are **upstream** community projects. Clone them; do not re-upload their binaries as our work.

## Repos

| Repo | URL | Role |
|------|-----|------|
| RE_Kenshi | https://github.com/BFrizzleFoShizzle/RE_Kenshi | DLL inject / hooks / plugin host |
| KenshiLib | https://github.com/BFrizzleFoShizzle/KenshiLib | Mapped game API |
| KenshiLib_Examples | https://github.com/BFrizzleFoShizzle/KenshiLib_Examples | HelloWorld, WorldStates, Dialogue plugins |
| KenshiLua | https://github.com/Genpretz/KenshiLua | Lua bindings + docs |
| KenshiExtensionPlugin | https://github.com/Lucius64/KenshiExtensionPlugin | KEP + Re_Dev lineage |

## Clone (desktop)

From repo root:

```bash
./scripts/clone-toolchain.sh
# or: ./scripts/clone-toolchain.sh /path/to/wherever
```

Or Git Bash:

```bash
mkdir -p third_party && cd third_party
git clone --depth 1 https://github.com/BFrizzleFoShizzle/RE_Kenshi.git
git clone --depth 1 https://github.com/BFrizzleFoShizzle/KenshiLib.git
git clone --depth 1 https://github.com/BFrizzleFoShizzle/KenshiLib_Examples.git
git clone --depth 1 https://github.com/Genpretz/KenshiLua.git
git clone --depth 1 https://github.com/Lucius64/KenshiExtensionPlugin.git
```

## Install into Kenshi (high level)

1. Build or use **prebuilt** RE_Kenshi per its README → install so Kenshi loads the injector.
2. Build plugins against KenshiLib (start with `KenshiLib_Examples/HelloWorld`).
3. KenshiLua: follow its README for deployment next to the game / RE_Kenshi.
4. Test: boot Kenshi → load save → check log.

Exact copy paths depend on version — read each upstream README.

## First files to read

- `KenshiLib_Examples/README.md` + `HelloWorld/`
- `KenshiLua/docs/`
- RE_Kenshi install docs
- Our `docs/architecture/FOUNDATION_SPIKES.md`
