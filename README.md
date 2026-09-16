# Dungeon Lootr — GitHub updates (PlayerTools-style)

Friends install / update with one line in their executor:

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/NickB926/dungeon-lootr/main/bootstrap.lua"))()
```

That pulls **Dungeon Lootr** + bundled **Ataraxia** chrome (Anti-AFK included). No PlayerTools install required.

## How it works

1. `bootstrap.lua` downloads `dungeon-lootr/Updater.lua`
2. Updater reads `version.json` from this repo
3. Listed files land in the executor `dungeon-lootr/` folder
4. `launch.lua` starts the helper

## Publish a new update (you)

From Windows — same idea as PlayerTools:

- Double-click **`Publish-DungeonLootr.vbs`** (or the Desktop shortcut — pin that to the taskbar)
- Or `publish-updates.bat`
- Or:

```powershell
cd C:\Users\Revi\Documents\dungeon-lootr
npm run publish:updates
```

That auto-bumps `1.0.0` → `1.0.1`, stages `DungeonLootr.lua` / `LootHUD.lua` / `launch.lua`, bundles latest `AtaraxiaLibrary.lua` from PlayerTools, syncs Potassium, commits, and pushes `main`.

Optional:

```powershell
npm run publish:updates -- -Message "parry fix"
npm run publish:updates -- -Version 1.2.0 -Message "big drop"
npm run publish:updates:skip-bump
```

## Visibility

Raw `HttpGet` needs a **public** repo (or awkward tokens). Create/publish uses `--public` by default.
