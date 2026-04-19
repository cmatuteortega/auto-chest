# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

AutoChest is a 1v1 online autobattler (Clash Mini-style) built in Love2D/Lua. Keep this file up to date as features are added.

---

## What This Game Is

- Players draft cards during a 30s setup phase to place/upgrade units on their side of the grid.
- Both players click Ready (or the timer runs out) → GO! flash → battle simulates automatically.
- Units fight until one side is wiped. The loser loses a life.
- First player to lose 3 lives loses the match.

---

## How to Run

**Local Development (localhost server):**
```bash
love .                   # client (connects to localhost)
love server/             # local dev server
```

**Production (cloud server at 75.119.142.247):**
```bash
./play-online.sh         # client (connects to cloud)
```

**Cloud Server:**
```bash
# Runs automatically via systemd on VPS
sudo systemctl status autochest-server
sudo journalctl -u autochest-server -f   # view logs
```

**Determinism regression test** (run after any combat changes):
```bash
lua tests/test_battle_determinism.lua
```

---

## Project Structure

```
autochest/
├── conf.lua             # Love2D config (540×960 window)
├── main.lua             # Entry point, font loading, screen manager setup
├── play-online.sh       # Quick launcher for production server
├── tests/
│   ├── test_battle_determinism.lua  # Determinism regression test (lua, not love)
│   └── balance_sim.lua              # Unit balance simulation tool
├── deploy/              # Cloud deployment files
├── server/              # Authentication + Matchmaking Server
│   ├── main.lua         # ENet server: auth, queue-based matchmaking, relay
│   ├── database.lua     # SQLite wrapper (bcrypt password hashing, session tokens)
│   └── players.db       # SQLite database (created on first run)
├── lib/
│   ├── classic.lua      # OOP (Class:extend())
│   ├── sock.lua         # ENet networking wrapper
│   ├── json.lua         # JSON encode/decode
│   ├── screen.lua       # Base screen object
│   ├── screen_manager.lua
│   └── suit/            # Immediate-mode UI (buttons)
└── src/
    ├── config.lua           # Server address config (dev/production)
    ├── constants.lua        # Resolution, grid layout, scaling helpers
    ├── grid.lua             # Grid data model + rendering
    ├── deck_manager.lua     # Persistent deck storage + draw pile management
    ├── base_unit.lua        # Base class for all units
    ├── base_unit_ranged.lua # Ranged unit base (adds arrow projectiles)
    ├── unit_registry.lua    # Unit type registry, cost table, sprite loader
    ├── audio_manager.lua    # Music/SFX singleton with persistent settings
    ├── socket_manager.lua   # Socket health check + async reconnection
    ├── tutorial_manager.lua # First-time tutorial overlay + AI opponent
    ├── card.lua             # Draggable card UI element
    ├── tooltip.lua          # Unit stat tooltip with upgrade button
    ├── pathfinding.lua      # A* pathfinding for unit movement
    ├── units/               # 17 unit types: amalgam, boney, bonk, bull, burrow,
    │                        #   catapult, clavicula, humerus, knight, mage, marc,
    │                        #   marrow, mend, migraine, samurai, sinner, tomb
    └── screens/
        ├── loading.lua      # Auto-auth screen (reads session.dat token, 5s timeout)
        ├── login.lua        # Authentication screen (register/login)
        ├── menu.lua         # Main menu (5-panel swipe UI: Collection/Decks/Battle/Shop/Ranking)
        ├── lobby.lua        # Matchmaking lobby (auto-joins queue, waits for match)
        └── game.lua         # Core game screen (all game logic lives here)
```

---

## Coordinate System

- **Canonical coordinates**: rows 1–8, cols 1–5. Row 1 = P2 zone top, row 8 = P1 zone bottom.
- **Visual coordinates**: depend on `Constants.PERSPECTIVE` (1 = P1 at bottom, 2 = P2 at bottom).
- `Constants.toVisualRow(row)` converts canonical → visual (self-inverse).
- `Grid:gridToWorld(col, row)` → screen pixels (accounts for perspective flip).
- `Grid:worldToGrid(x, y)` → canonical (col, row) (also accounts for flip).
- **Always use `gridToWorld`/`worldToGrid` for coordinate conversion — never compute manually.**

---

## Game States (game.lua)

```
setup → pre_battle → battle → battle_ending → intermission → setup (loop)
                                                           └→ finished
```

| State          | Description |
|---------------|-------------|
| `setup`        | 30s timer, players place/upgrade/reposition units |
| `pre_battle`   | 1s "GO!" flash |
| `battle`       | Units fight automatically |
| `battle_ending`| Animations finishing; waits for sync |
| `intermission` | 2.5s pause with bodies visible; life deducted after |
| `finished`     | Game over; shows YOU WIN / YOU LOSE |

---

## Economy

- Start of game: **6 coins**
- Start of each subsequent round: **+6 coins** (added in `resetRound()`)
- Losing a round: **+3 consolation coins** (added before `resetRound()`)
- Reroll cost: 1 coin

---

## Lives System

- Each player starts with **3 lives**.
- Losing a round → lose 1 life.
- 0 lives → `state = "finished"`.
- Life is deducted **after** the intermission timer expires (bodies stay on board during intermission).

---

## Round Flow (detailed)

1. `setup`: Players place units, timer counts down for both (P2 just can't auto-trigger).
2. Both click Ready (or P1's timer hits 0) → `ready` message sent → host generates RNG seed → `battle_start` message → both enter `pre_battle`.
3. `pre_battle` (1s "GO!" flash) → `startBattle()`:
   - Applies all buffered opponent placement messages.
   - Computes board hash for desync detection.
   - Saves `homeCol`/`homeRow` per unit, calls `onBattleStart()`.
4. `battle`: Units advance via a **fixed timestep loop** (see Battle Simulation below).
5. One side wiped → `state = "battle_ending"`.
6. `battle_ending`: Animations play out; once `areAllAnimationsComplete()`:
   - Both clients set `localRoundEndReady = true` and send `round_end_ready`.
   - When `opponentRoundEndReady` also arrives: consolation coins → `state = "intermission"`, `intermissionTimer = 2.5`.
7. `intermission` (2.5s, bodies stay): Timer expires → deduct life → if 0: `finished`, else `resetRound()`.
8. `resetRound()`: Clear grid, re-place all units at home positions, `+6 coins`, `state = "setup"`.

---

## Online Multiplayer Architecture

**Production Server**: `75.119.142.247:12345` (Contabo VPS, Ubuntu 22.04)

**Authentication Flow**:
1. `loading.lua` auto-reads `session.dat`; if token exists, sends `auto_login` → skips login screen.
2. Login screen: `login` or `register` → server validates → `login_success` with `player_id`, `username`, `trophies`, `coins`, `decks`, `token`.
3. Client stores `_G.PlayerData` and `_G.GameSocket` globally.

**Matchmaking Flow**:
1. Client sends `queue_join` with `player_id` and `trophies`.
2. Server matches by trophy range ±100 (expands +50/5s, max ±500).
3. `match_found` → `role` (1=P1/host, 2=P2/guest), opponent info → `Constants.PERSPECTIVE` set → `GameScreen`.

**Game Messages** (relayed through server):

| Message | Type | Sender | Description |
|---------|------|--------|-------------|
| `place_unit` | relay | Either | Unit placed on grid |
| `remove_unit` | relay | Either | Unit removed from grid |
| `upgrade_unit` | relay | Either | Unit upgraded |
| `ready` | relay | Either | Player clicked Ready |
| `battle_start` | relay | P1 only | Includes RNG `seed` |
| `round_end_ready` | relay | Either | Animations done, ready to reset |
| `board_sync_check` | relay | Either | Board hash for desync detection |
| `match_result` | direct | Either | Winner ID → server updates trophies |

**Server-Only Messages**:

| Message | Description |
|---------|-------------|
| `login` / `register` / `auto_login` | Authentication |
| `login_success` / `login_failed` | Auth responses |
| `queue_join` / `queue_leave` | Matchmaking queue |
| `sync_decks` | Save all 5 deck slots to server |
| `update_active_deck` | Set active deck for battle |

**Trophy System**: Winner: +20, Loser: -15 (min 0). Server updates DB after each match.

**Client Roles**: P1 = host (role 1), P2 = guest (role 2). Set in `Constants.PERSPECTIVE`.

**Opponent placement buffering**: During `setup`/`intermission`/`pre_battle`, incoming placement messages buffer in `pendingOpponentMsgs`. Applied at `startBattle()` so enemy positions appear frozen during setup.

**Round 1**: Enemy units hidden entirely. Round 2+: enemy units visible during setup.

**Socket Keepalive**: Menu screen calls `_G.GameSocket:update()` every frame to prevent ENet timeout.

**SocketManager** (`src/socket_manager.lua`): Use `SocketManager.isHealthy()` to check connection. `SocketManager.reconnect(onSuccess, onFailure)` handles async reconnection with saved token; pump with `SocketManager.updateReconnect(handle, dt)` each frame.

---

## Unit System

All units extend `BaseUnit` (via `classic.lua`). Ranged units extend `BaseUnitRanged`.

**Key fields**: `unitType`, `owner` (1 or 2), `col`, `row`, `level` (0–3), `isDead`, `health`, `maxHealth`.

**Combat hooks to override**:
- `unit:onBattleStart(grid)` — called once when battle begins
- `unit:getDamage(grid)` — override for conditional damage
- `unit:onKill(target)` — called when this unit kills an enemy
- `unit:findGoalNearTarget(grid, target)` — override movement goal calculation

**Per-round state**: `unit:resetCombatState()` resets all combat state and restores full health.

**Status effects**:
- `stunTimer > 0` — unit cannot move or attack
- `tauntedBy` + `tauntTimer` — overrides target selection (always attack taunter)

**Sprites**: `front.png` (facing enemy), `back.png` (moving away), `dead.png`. Units with `hasDirectionalSprites = true` use 8-directional animation via `getDirectionalSprite()`.

**Ranged projectiles** (`base_unit_ranged.lua`): `createProjectile(target, grid)` launches a projectile tracked in `self.arrows`. Override `onProjectileHit(projectile, grid)` for AoE effects. Override `drawProjectile(projectile)` for custom visuals.

---

## Upgrade System

Each unit has an `upgradeTree` table (up to 3 entries). Players choose upgrades during setup via the tooltip.

```lua
upgradeTree = {
    { name = "...", description = "...", onApply = function(unit) ... end },
    ...
}
```

- `unit:upgrade(index)` — purchases upgrade at index, calls `onApply`, broadcasts `upgrade_unit` in online mode.
- `unit:hasUpgrade(index)` — checks if upgrade is active.
- `unit:getNextAvailableUpgrade()` — returns index of next purchasable upgrade.
- `activeUpgrades` — list of purchased upgrade indices.
- Stat scaling: 1.3× per level (level 3 = 2.197× base).

In online mode the tooltip upgrade button is hidden/blocked for enemy units.

---

## Grid Draw Order

`Grid:draw(draggedUnit, hideOwner)`:
1. Draw dead units (behind).
2. Draw alive units (on top).
3. Dragged unit drawn separately in `game.lua` on top of everything.

`hideOwner`: skips drawing units belonging to that owner (used in round 1 setup).

---

## Input Handling (game.lua)

Unified tap vs drag detection:
- `handlePress(x, y)` → stores `pressedUnit` or `pressedCard`.
- `handleMove(x, y)` → once moved >10px, sets `hasMoved = true`, starts drag.
- `handleRelease(x, y)` → resolves: tooltip upgrade click → tap-on-unit → tap-on-card → unit drag drop → card drag drop.

**P2 drag fix**: unit drag origin computed via `grid:gridToWorld(col, row)` (not manual pixel math) to correctly account for perspective flip.

---

## Battle Simulation (Determinism)

Battle runs as independent peer-to-peer simulation on each client.

**Fixed timestep loop** (`game.lua`, `battle` state):
- Real `dt` accumulated in `self.battleAccumulator`.
- Simulation advances in discrete `FIXED_DT = 1/60` steps: `unit:update(FIXED_DT, grid)`.
- `battle_ending` uses real `dt` — cosmetic only, no simulation logic.
- `self.battleStepCount` tracks total steps for debugging.

**Deterministic pathfinding** (`pathfinding.lua`): A* tie-breaks equal f-scores by lower row → lower col.

**Deterministic target selection** (`base_unit.lua`, `findNearestEnemy`): equidistant enemies broken by lower col → lower row → lower owner.

---

## Desync Detection

At `startBattle()`, each client computes `computeBoardHash()` (sorted `"unitType,col,row,owner,level"` strings), sends `board_sync_check`, and `checkBoardSync()` prints `[SYNC]` or `[DESYNC]`.

---

## Audio

`AudioManager` (`src/audio_manager.lua`) is a singleton initialized at startup.

- `AudioManager.playMusic()` / `stopMusic()` — background OST
- `AudioManager.setBattleMode(enabled)` — applies low-pass filter during battle
- `AudioManager.playTap()` / `playSFX(name, volume)` — one-shot SFX
- `AudioManager.setMusic(enabled)` / `setSFX(enabled)` — toggles with persistence

---

## Tutorial

`TutorialManager` (`src/tutorial_manager.lua`) attaches to `GameScreen` when `isTutorial = true`. It drives an 8-step tutorial with required actions and schedules AI opponent placements via `AI_ACTIONS`. Detection is polling-based — no modifications to core game logic.

---

## UI Notes

- Fonts loaded globally as `Fonts.large`, `Fonts.medium`, `Fonts.small`, `Fonts.tiny`.
- SUIT used for Ready and Reroll buttons.
- Life pips: filled squares near player labels (top-left for top player, bottom-right for bottom player).
- Coin display: bottom-left, always visible during setup.
- State text: top-center. Shows timer during setup, "ROUND X" during intermission, "GO!" pre_battle, "YOU WIN!"/"YOU LOSE" only on `finished`.
- Emote panel: in-game with cooldown, visible to both players.

---

## Lobby Screen

- Auto-joins matchmaking queue on init (no manual buttons).
- Displays animated spinner while searching.
- On `match_found`: receives `role`, opponent info → brief display (1.2s) → launches GameScreen.
- Cancel button: leaves queue, returns to menu.
- `close()` skips disconnect if `status == "matched"` (socket handed to GameScreen).

---

## Deck System

**Persistent Storage**: 5 deck slots per player, stored server-side in SQLite.

**Deck Structure**:
```lua
{ name = "Deck 1", counts = { knight = 5, samurai = 3, boney = 7, marrow = 5 } }
```

**Deck Manager** (`src/deck_manager.lua`):
- `_data = {activeDeckIndex, decks}` persists across screen switches; `_drawPile` is reset each match.
- Max 20 cards per deck, 5 slots.

**Key Functions**:
- `DeckManager.load()` — loads from `_G.PlayerData.decks` (server) or local `decks.json` (offline fallback)
- `DeckManager.save()` — syncs via `sync_decks`, saves local backup
- `DeckManager.setActive(deckIndex)` — sets/toggles active deck
- `DeckManager.initDrawPile()` — builds and shuffles draw pile; returns `true` if active deck loaded, `false` for random fallback
- `DeckManager.drawCards(n)` / `reshuffleAndDraw(currentHand, n)` — card draw operations

---

## Known Constraints / Decisions

- **Timer**: Both P1 and P2 count down for display. Only P1 triggers auto-battle when timer hits 0 in online mode.
- **Enemy upgrades blocked**: In online mode, tooltip upgrade button is hidden and blocked for enemy units.
- **No drag of enemy units**: Online dragging is zone-restricted (own zone only).
- **Intermission shows bodies**: Grid is NOT cleared between `battle_ending` and `resetRound()`.
- **All units respawn each round**: Dead and alive units both return to `homeCol`/`homeRow`.
- **Cell size**: Rounded down to nearest multiple of 16 (sprites are 16×16px).

---

## IMPORTANT: Updating Production Server

**After ANY code changes that affect gameplay, server logic, or networking:**

1. **Upload changes to VPS:**
   ```bash
   rsync -avz --exclude 'server/players.db' . root@75.119.142.247:/opt/autochest/
   ```

2. **Restart server:**
   ```bash
   ssh root@75.119.142.247 sudo systemctl restart autochest-server
   ```

3. **Verify:**
   ```bash
   sudo journalctl -u autochest-server -f
   ```

**Requires server restart:** changes to `server/`, network message formats, unit determinism, deck/economy logic.

**Local only:** UI/visual changes, client-side animations, menu screen changes (unless affecting networking).

See `deploy/YOUR_DEPLOYMENT_STEPS.md` for complete deployment instructions.
