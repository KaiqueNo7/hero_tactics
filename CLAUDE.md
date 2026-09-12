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
`Workspace.Objects`, Lighting, Baseplate) lives **only in Studio** and is intentionally left out of
`default.project.json`.

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
`HeroSelect`, `HeroSelectBattle`; per-arena names too — `BattleDefault`, which plays only during hero selection, plus the per-region
`Music<Region>` battle tracks (a region with no such Sound plays silence, no fallback) and the object sounds each theme names in `Arenas.luau`); the hero spritesheet asset ID is a constant in
`HeroData.luau`.

## Architecture

### Layer split

- `src/shared/Modules/` (`ReplicatedStorage.Modules`) — pure rules and data both client and server
  need identically: `HexGrid` (axial coordinate topology), `GameConfig` (tunable constants),
  `HeroData` (hero catalog + sprite lookup), `Campaign` (bot-fight ladder → hero unlock mapping),
  `LobbyZones` (lobby layout plan), `Arenas` (arena themes), `Progression` (level curve), `Monetization` (dev product →
  coin catalog), `Tutorial`, `PixelIcons`, `SafeArea`.
- `src/server/Modules/` (`ServerScriptService.Modules`) — authoritative game state and services.
  The client is never trusted with anything that matters (prices, hero ownership, XP, combat
  resolution) except the tutorial's "seen this lesson" flag, which is deliberately unvalidated
  (see `TutorialService` header for why that specific exception is safe).
- `src/client/*.client.luau` — one `LocalScript` per concern (input, camera, HUD, lobby menu,
  sound), all driven by `RemoteEvent`s firing from server modules.

### Where a server module lives

`src/server/Modules/` is foldered by domain. The folder IS the instance path, so a require reads
`ServerScriptService.Modules.<Folder>.<Module>` — always absolute, never `script.Parent`, except
between two modules in the same folder.

| Folder | What belongs there |
|---|---|
| (root) | `MatchManager` only — the orchestrator, and the door everything outside comes through |
| `Match/` | the match as data: registry, queries, clock, snapshot, broadcast, log, outcome, rewards |
| `Combat/` | the rules of acting: `CombatCore`, movement, attack, placement, promotion, board objects, guard, `Skills` |
| `AI/` | `BotBrain` decides, `BotTurn` executes |
| `View/` | everything that only exists to be looked at |
| `Arena/` | building the arena and the board |
| `Lobby/` | building the lobby: trail, seats, leaderboard |
| `Data/` | anything backed by a DataStore, plus `SafeStore` and `DevAccess` |
| `Modes/` | match flavours that are not the normal game: challenges, sandbox, objectives |

### Who owns what on the server (the SRP split)

`MatchManager` and `HeroView` were the two files that grew into everything; these modules carved
responsibilities out of them and are the place new code of that kind belongs:

| Module | Owns | Never does |
|---|---|---|
| `CombatCore` | the combat ring: damage, shields, death and graves, heal, attack buffs, status effects, ground flames, the skill triggers and the `api` skills call into | own the turn, validate a player action, decide the match is over |
| `MovementService` / `AttackService` | one player action each, end to end: validate, execute, log, broadcast | decide damage (that is `CombatCore`) |
| `ActionGuard` | the single question every action asks first: can this hero act right now | know which action is being attempted |
| `PlacementService` | the draft: whose turn to place, what is available, where the bot puts it | anything after the first turn begins |
| `PromotionService` | promotion squares, resurrection, stance flip, the Shin swap, ally choices | combat |
| `BoardObjectService` | the match-side rules of destructible objects: spawn, hit, break, the prize | how they look (`BoardObjectView`) |
| `MatchOutcome` | whether the match is over and who won, plus the `Resolvers` registry other modes plug into | pay the rewards (`MatchRewards`) |
| `MatchRegistry` | which matches exist on this server, their slots, and finding a player's match | anything inside a match |
| `BotTurn` | executing a bot's turn: ask `BotBrain`, then spend the actions | decide which action is best |
| `ArenaObjectBuilder` | reading `theme.object`, resolving the model (`instance` → `asset` → `Arenas.DEFAULT_OBJECT` → `mesh`/`part`), scale, rotation X/Y/Z, size, skin, the hitbox `Part`, and the theme's dust colour / sound names | know a barrel has hit points |
| `BoardObjectView` | the destructible object's life on screen — pip badge, hit shake, dust, break fade | resolve models or read the theme |
| `BoardVfx` | effects that belong to a HEX, not to a hero: ground flames, range flash, blasts, fire circle, chain arcs, ice storm | know what a hero is |
| `VfxLibrary` | finding and preparing the hand-built VFX under `ReplicatedStorage.VFX` (or Workspace): cache, anchor, strip scripts/lights, fade a whole effect | know what any single effect means |
| `ViewStyle` | shared board-view vocabulary: `TILE_TOP_Y`, sprite metrics, badge colours, GUI distance, dust, team colours, `GroundCFrame`, `DustBurst`, `AttachTo`, `BuildTeamRing` | anything match-specific |
| `MatchAudio` | firing sound names to the players of one match (2D on the client, never on the server) | — |
| `MatchClock` | every "how many seconds are left" question (turn, reconnect, placement) | change the clock |
| `MatchLog` | the three cross-cutting writes: match log entries, per-hero tallies, action rejections to the client | know about turns or combat |
| `MatchBroadcast` | publishing state to the clients and the bookkeeping that follows a publish | decide what changed |
| `MatchSnapshot` | serialising a match into the table the client renders, per viewer | mutate the match |
| `MatchRewards` | what a finished match pays: XP, fight stars, campaign hero unlock, hero telemetry | decide who won |

Two seams use an injected dependency instead of a require, both bound once at load:
`MatchSnapshot.Bind` receives `AllyOptionsFor` and `NextOpenFight`, and `CombatCore.Bind`
receives `CreateHero` (the Golem's Estilhaçar summons through the skill api, which is built long
before `CreateHero` exists in `MatchManager`). Everything else is a plain require.

`CombatCore` is one module and not four on purpose: `ApplyDamage` calls `KillHero`, which fires
`TriggerSkills`, which runs a skill, which calls back into the `api` built by `BuildSkillApi`,
which calls `ApplyDamage` again. That ring cannot be split across modules without a circular
require, so the rule is: a function that the ring calls, or that calls into the ring, belongs
here.

Anything extracted from `MatchManager` from here on can require `MatchLog` and `MatchBroadcast`
directly — that is what those two exist for, and it is why they came out before the combat split.

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

`Arenas` (shared) is the per-region arena catalog — one theme per campaign group: ground, backdrop,
props, ambient particles, lights, the board object that replaces the barrel and the hexes it spawns
on. `ArenaBuilder` rebuilds the theme into a diorama at the slot origin on every match start (or clones a
hand-built `ArenaMaster_<theme>` folder if the place has one — `BoardSpawner.BuildMaster("geleira")`
or `BoardSpawner.BuildAllMasters()` from the command bar generates those folders in Edit mode; re-running keeps whatever you hand-edited, and `BuildMaster(theme, true)` is the explicit discard), and `BoardSpawner` keeps the board rules while
asking for the arena of the match theme. Campaign fights load their group's region; PvP and free
training draw one at random. Arena lighting is applied CLIENT-side from the snapshot (`state.arena`),
like the lobby trail — Lighting is global, so the server can never set it per match.

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
campaign group, connected by bridges); `LobbyZoneBuilder.server` builds `Workspace.LobbyTrail` from
that plan **only when the place doesn't already have one**. Finding an existing `LobbyTrail`, it
adopts the place's layout and touches nothing — islands, bridges and fight pads all stay where
Studio put them, because aligning the trail by hand is the normal workflow here. `Build(true)` from
the command bar is the explicit opt-out that discards the hand layout and rebuilds from the plan.
The plan numbers stay live even when adopted (zone-ambience detection in `ZoneAt`, and where a
brand-new pad is born), so keep them measured from the real lobby. Several server modules follow this same
"idempotent builder driven by a shared-module plan" pattern: `LightingSetup`, `LeaderboardBoardView`,
and `LobbyZoneBuilder` can all be re-run from the command bar in Edit mode without duplicating
what they build.

### Sandbox de captura (dev)

`SandboxService` é o modo de captura de trailer: NÃO é uma cópia do jogo, é uma partida
normal com `options.sandbox = true`. Essa flag faz o `MatchManager` pular barris e draft, entrar
direto em `battle`, e ela é o que corta `CheckGameOver` e `AwardXp` — por isso nenhuma cena de
teste mexe em XP, moedas, heróis desbloqueados, ranking ou `HeroStatsService`. Tudo o que aparece
na tela (HUD, luz da arena, música, câmera de finalização, invisibilidade) continua vindo do
snapshot de sempre; o sandbox só monta o estado. `MatchManager.Internal` existe só pra ele.

Os comandos entram pelo `GameAction` com a ação `"sandbox"` (sem Remote novo) e são texto:
`spawn Nash 1 C3`, `status Kira poison 3`, `finish win`. `hit` e `go` passam pelo
`MatchManager` de verdade (turno, alcance, contra-ataque, gatilhos); `attack` e `move` são o
atalho forçado, pra montar o quadro. Os presets de "melhor momento" são 3v3 como partida real. Quem pode: Studio, o dono, ou
`DevAccess.EXTRA_TESTER_IDS` — amigos do dono NÃO entram. `SandboxService.ENABLED = false`
desliga tudo. `cam/hud/cine` são resolvidos no `SandboxClient` (painel com F2); o resto no
servidor. `Validate()` roda na carga e avisa se um preset citar herói, casa, arena ou comando
que não existe mais.

### Comment convention

**Never add comments to code.** Not header blocks, not inline notes, not `--` explanations above a
constant, not even to justify a non-obvious number. This is absolute and has no exceptions — if the
reasoning matters, put it in the chat reply, not in the file.

Existing comments are a different matter: leave them alone. Plenty of older modules
(`GameConfig.luau`, `MatchManager.luau`, `Campaign.luau`, `LobbyZones.luau`) carry heavy *why*
commentary from before this rule, and they are still worth reading before changing a number or a
decision. Just don't write more of them. Editing a line whose comment is now wrong means deleting
or correcting that comment, never expanding it.
