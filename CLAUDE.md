# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Hero Tactics — a turn-based hex-grid tactics game for Roblox, written in Luau, synced with Rojo.
It's a port of an original Phaser web game (`tactics-game/`, not in this repo — some comments
reference `models/heroes.js`, `Board.js`, `src/heroes/skills.js` as the ported-from source).

## Commands

- Install toolchain (once): `rokit install` (installs Rojo, pinned in `rokit.toml`)
- Start the sync server: `rojo serve` — then in Roblox Studio, open the Rojo plugin → **Connect**.
  Studio then updates automatically whenever a `.luau` file is saved.
- Lint: `selene .` (config: `selene.toml`, uses the `roblox` std library profile)
- There is no automated test suite and no build step beyond Rojo's live sync — verification happens
  by playing the game in Studio (or a live server) after syncing.

## Rojo boundary — read before touching `default.project.json`

This project does **not** manage the whole DataModel, only scripts. Everything built by hand in
Studio (the map, lobby, `HexTile` parts, the `Remotes` folder, `Sounds`, `BotDummyTemplate`,
Lighting, Baseplate) lives **only in Studio** and is intentionally left out of `default.project.json`.

`default.project.json` maps exactly:

| Disk | Studio instance |
|---|---|
| `src/shared/Modules/` | `ReplicatedStorage.Modules` |
| `src/server/Modules/` | `ServerScriptService.Modules` |
| `src/server/*.server.luau` | individual `ServerScriptService` scripts |
| `src/client/*.client.luau` | individual `StarterPlayer.StarterPlayerScripts` scripts |

Rojo **overwrites** Studio with whatever is on disk. If a `$path` points at a folder that doesn't
have the corresponding files yet, syncing **deletes** those instances in Studio. Never add a new
`$path` entry until the files it points to actually exist on disk.

`RemoteEvent`s referenced in code (`ReplicatedStorage.Remotes.*`) are assumed to already exist in
Studio; several server modules (`ProgressionService`, `CoinService`, `HeroUnlockService`, etc.)
call `EnsureRemote`/create-if-missing on startup as a convenience for a freshly cloned repo, but
the `Remotes` folder itself is Studio-owned, not Rojo-managed.

Image/sound assets also live outside Rojo's reach: sound names are read from
`ReplicatedStorage.Sounds` (`Hit`, `SwordSwing`, `Heal`, `PoisonHiss`, `FootstepWood`, `MatchStart`,
`HeroSelect`, `HeroSelectBattle`); asset IDs (hero spritesheet, poison icon) are constants in
`HeroData.luau`.

## Architecture

### Layer split

- `src/shared/Modules/` (`ReplicatedStorage.Modules`) — pure rules and data both client and server
  need identically: `HexGrid` (axial coordinate topology), `GameConfig` (tunable constants),
  `HeroData` (hero catalog + sprite lookup), `Campaign` (bot-fight ladder → hero unlock mapping),
  `LobbyZones` (lobby layout plan), `Progression` (level curve), `Monetization` (dev product →
  coin catalog), `Tutorial`, `PixelIcons`, `SafeArea`.
- `src/server/Modules/` (`ServerScriptService.Modules`) — authoritative game state and services.
  The client is never trusted with anything that matters (prices, hero ownership, XP, combat
  resolution) except the tutorial's "seen this lesson" flag, which is deliberately unvalidated
  (see `TutorialService` header for why that specific exception is safe).
- `src/client/*.client.luau` — one `LocalScript` per concern (input, camera, HUD, lobby menu,
  sound), all driven by `RemoteEvent`s firing from server modules.

### Match lifecycle (the core loop)

`GameStartTrigger.server.luau` is the lobby entry point: touch/click pads (`StartBotMatch`,
`StartPvpMatch`) or campaign squares call into `MatchManager`, which owns everything about an
active match — draft, turns, combat, skills, the bot AI.

**Multiple matches run concurrently per server.** `MatchManager` used to hold one global `match`;
it's now a registry (`matches[matchId]`, `matchBySlot[slot]`), and every internal function takes
the `match` table it's operating on as an explicit argument — nothing reads global state. This is
why concurrent games can't see or interfere with each other. The same pattern repeats in
`HexGrid` (topology is global, but board *offset* and hex *occupancy* are per-match/per-call) and
in `HeroView` (all presentation state — folders, sound emitters — lives in a per-match `view`
table hung off each hero, because `SoundService` sounds are global-audible otherwise).

`BoardSpawner` builds arena N as a positioned clone of the hand-built Arena 1 scenery; the first
arena is edited by hand in Studio, the rest are code-driven clones so decor changes only need to
happen once.

`Skills.luau` holds every named hero ability, ported from `src/heroes/skills.js`. Each skill gets
a `ctx` (`hero, target, isCounterAttack, api, damageApplied`); setting `ctx.damageApplied = true`
replaces the default attack damage entirely, `passive = true` marks skills with no trigger event
(applied via `modifyIncomingDamage`, called by `MatchManager`). `MatchManager` builds the `api`
that skills call into (`BuildSkillApi`), which is why `CreateHero` is forward-declared at the top
of the file — the skill API exists before hero construction does.

### Progression — one source of truth per concern, all derived

- **Hero ownership** (`HeroUnlockService`): the only place hero possession is recorded. There is
  no separate "bots defeated" list — `Campaign.FIGHTS` maps each bot fight to the single hero it
  rewards, so "beat bot X" and "own hero X" are the same fact by construction. Group-unlocked,
  fight-completed, and PvP-unlocked are all *derived* from this list, never stored redundantly.
- **Player XP** (`ProgressionService`) and **coin wallet** (`CoinService`) are separate per-`userId`
  DataStores; hero win-rate telemetry (`HeroStatsService`) is a *third*, per-hero (not per-player)
  aggregate used only for balance decisions — don't conflate it with player progression.
- **Access exceptions** (`DevAccess`): owner + friends-of-owner + a fixed tester ID list bypass
  the unlock ladder entirely. `DevAccess.UNLOCK_FOR_OWNER_FRIENDS` must be flipped to `false`
  before launch — it's on for playtesting.
- All DataStore access goes through `SafeStore` (retry + budget wait wrapper) — never call
  `DataStoreService` directly from a new service; failures should warn and degrade to
  session-only state, not silently drop player progress.
- DataStore-backed services (`ProgressionService`, `CoinService`, `HeroUnlockService`,
  `TutorialService`) all require "Enable Studio Access to API Services" (Game Settings > Security)
  to persist while testing in Studio; without it they warn and fall back to session-only state.

### Monetization

`Monetization.luau` (shared) is the catalog dev products map to; `CoinService.server` is the
**only** place allowed to register `MarketplaceService.ProcessReceipt` (Roblox allows exactly one
handler per game) and the only place that decides how much a receipt is worth — the client only
opens the purchase prompt, it never asserts a price.

### Lobby layout

`LobbyZones.luau` (shared) is the numeric/color *plan* for the lobby trail (one themed island per
campaign group, connected by bridges); `LobbyZoneBuilder.server` is the idempotent builder that
reads that plan and rebuilds `Workspace.LobbyTrail` from scratch on every server start — moving a
piece by hand in the Explorer doesn't stick, edit the numbers in `LobbyZones` instead (or set the
`KeepPosition` attribute on a specific pad to exempt it). Several server modules follow this same
"idempotent builder driven by a shared-module plan" pattern: `LightingSetup`, `LeaderboardBoardView`,
and `LobbyZoneBuilder` can all be re-run from the command bar in Edit mode without duplicating
what they build.

### Comment convention

Non-obvious constants and decisions in this codebase are heavily commented with *why*, not *what*
— especially in `GameConfig.luau` (game balance numbers), `MatchManager.luau`, and `Campaign.luau`.
Read the header comment of a module before changing it; the reasoning for a specific number or
architectural choice is usually already written down.
