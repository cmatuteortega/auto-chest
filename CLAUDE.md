# AutoChest — CLAUDE.md

Project reference for Claude Code. Keep this up to date as features are added.

---

## What This Game Is

AutoChest is a 1v1 online autobattler (Clash Mini-style) built in Love2D/Lua.
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

---

## Project Structure

```
autochest/
├── CLAUDE.md            ← this file
├── conf.lua             # Love2D config (540×960 window)
├── main.lua             # Entry point, font loading, screen manager setup
├── play-online.sh       # Quick launcher for production server
├── tests/
│   └── test_battle_determinism.lua  # Determinism regression test
├── deploy/              # Cloud deployment files
│   ├── DEPLOYMENT_GUIDE.md          # Complete deployment guide
│   ├── YOUR_DEPLOYMENT_STEPS.md     # Quick setup with actual IP
│   ├── server-setup.sh              # VPS setup script
│   ├── autochest-server.service     # Systemd service file
│   └── backup-db.sh                 # Database backup script
├── server/              # Authentication + Matchmaking Server
│   ├── conf.lua         # Love2D config (disables audio for headless)
│   ├── main.lua         # ENet server: auth, queue-based matchmaking, relay
│   ├── database.lua     # SQLite wrapper (players, sessions, decks)
│   ├── players.db       # SQLite database (created on first run)
│   └── matchmaking.log  # Server event log
├── lib/
│   ├── classic.lua      # OOP (Class:extend())
│   ├── sock.lua         # ENet networking wrapper
│   ├── json.lua         # JSON encode/decode (used for network messages)
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
    ├── card.lua             # Draggable card UI element
    ├── tooltip.lua          # Unit stat tooltip with upgrade button
    ├── pathfinding.lua      # A* pathfinding for unit movement
    ├── units/
    │   ├── knight.lua
    │   ├── samurai.lua
    │   ├── boney.lua
    │   └── marrow.lua
    └── screens/
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
   - Send `round_end_ready` (online).
   - When both sides done: consolation coins → `state = "intermission"`, `intermissionTimer = 2.5`.
7. `intermission` (2.5s, bodies stay): Timer expires → deduct life → if 0: `finished`, else `resetRound()`.
8. `resetRound()`: Clear grid, re-place all units at home positions, `+6 coins`, `state = "setup"`.

---

## Online Multiplayer Architecture

**Server Architecture**: Cloud-hosted matchmaking server with authentication and persistent player data.

**Production Server**: `75.119.142.247:12345` (Contabo VPS, Ubuntu 22.04)

**Server Components** (`server/`):
- `main.lua`: ENet server with auth, queue-based matchmaking, relay
- `database.lua`: SQLite wrapper (bcrypt password hashing, session tokens)
- `players.db`: SQLite database (players, sessions, decks)

**Authentication Flow**:
1. Client connects to server via ENet (TCP/UDP port 12345)
2. Login screen: `login` or `register` message → server validates/creates account
3. Server responds with `login_success` containing: `player_id`, `username`, `trophies`, `coins`, `decks`, `token`
4. Client stores `_G.PlayerData` and `_G.GameSocket` globally

**Matchmaking Flow**:
1. Client sends `queue_join` with `player_id` and `trophies`
2. Server adds player to matchmaking queue: `{peer, player_id, username, trophies, queue_time}`
3. Server continuously processes queue (every frame):
   - Base trophy range: ±100
   - Expands by +50 every 5 seconds (max ±500)
4. When match found: Server sends `match_found` to both players with:
   - `role` (1 = P1/host, 2 = P2/guest)
   - `opponent_name`, `opponent_trophies`, `my_trophies`
5. Server creates "room": pairs peers for relay forwarding
6. Clients receive role → update `Constants.PERSPECTIVE` → launch GameScreen

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
| `login` / `register` | Authentication |
| `login_success` / `login_failed` | Auth responses |
| `queue_join` / `queue_leave` | Matchmaking queue |
| `queue_joined` / `match_found` | Queue status |
| `sync_decks` | Save all 5 deck slots to server |
| `update_deck_slot` | Update single deck |
| `update_active_deck` | Set active deck for battle |

**Trophy System**:
- Winner: +20 trophies
- Loser: -15 trophies (min 0)
- Server updates database after each match

**Client Roles**: P1 = host (role 1), P2 = guest (role 2). Set in `Constants.PERSPECTIVE`.

**Opponent placement buffering**: During `setup`/`intermission`/`pre_battle`, incoming `place_unit`/`remove_unit`/`upgrade_unit` messages are buffered in `pendingOpponentMsgs`. Applied at `startBattle()` so enemy unit positions appear frozen during setup (showing last round's positions).

**Round 1**: Enemy units hidden entirely (element of surprise). Round 2+: enemy units visible during setup.

**Socket Keepalive**: Menu screen calls `_G.GameSocket:update()` every frame to prevent ENet connection timeout.

---

## Unit System

- All units extend `BaseUnit` (via `classic.lua`).
- Ranged units extend `BaseUnitRanged`.
- Key fields: `unitType`, `owner` (1 or 2), `col`, `row`, `level` (0–3), `isDead`, `health`, `maxHealth`.
- `unit:resetCombatState()` — resets all per-round combat state, restores full health.
- `unit:onBattleStart(grid)` — called once when battle begins.
- Units with `isDead == true` are drawn **behind** alive units (two-pass rendering in `Grid:draw()`).
- Sprites: `front.png` (facing enemy), `back.png` (moving away), `dead.png`.

---

## Grid Draw Order

`Grid:draw(draggedUnit, hideOwner)`:
1. Draw dead units (behind).
2. Draw alive units (on top).
3. Dragged unit drawn separately in `game.lua` on top of everything.

`hideOwner`: if set, skips drawing units belonging to that owner (used in round 1 setup).

---

## Input Handling (game.lua)

Unified tap vs drag detection:
- `handlePress(x, y)` → stores `pressedUnit` or `pressedCard`.
- `handleMove(x, y)` → once moved >10px, sets `hasMoved = true`, starts drag.
- `handleRelease(x, y)` → resolves: tooltip upgrade click → tap-on-unit → tap-on-card → unit drag drop → card drag drop.

**P2 drag fix**: unit drag origin computed via `grid:gridToWorld(col, row)` (not manual pixel math) to correctly account for perspective flip.

---

## Battle Simulation (Determinism)

Battle runs as an independent peer-to-peer simulation on each client. Determinism is enforced by three mechanisms:

**Fixed timestep loop** (`game.lua`, `battle` state):
- Real `dt` is accumulated in `self.battleAccumulator`.
- The simulation advances in discrete `FIXED_DT = 1/60` steps: `unit:update(FIXED_DT, grid)`.
- Both clients process the exact same number of steps per battle, eliminating drift from variable frame rates.
- `battle_ending` still uses real `dt` — it is cosmetic animation drain only, no simulation logic fires.
- `self.battleStepCount` tracks total steps for debugging/testing.

**Deterministic pathfinding** (`pathfinding.lua`):
- A* open-set selection tie-breaks equal f-scores by lower row → lower col, making path choices independent of insertion order.

**Deterministic target selection** (`base_unit.lua`, `findNearestEnemy`):
- Equidistant enemies are broken by lower col → lower row → lower owner number.

**Run the determinism regression test** after any combat changes:
```bash
lua tests/test_battle_determinism.lua
```

---

## Desync Detection

At `startBattle()`, each client:
1. Computes `computeBoardHash()`: sorted list of `"unitType,col,row,owner,level"` for all units.
2. Sends `board_sync_check` message with hash.
3. On receiving opponent's hash, `checkBoardSync()` compares and prints `[SYNC]` or `[DESYNC]` to console.

---

## UI Notes

- Fonts loaded globally as `Fonts.large`, `Fonts.medium`, `Fonts.small`, `Fonts.tiny`.
- SUIT used for Ready and Reroll buttons.
- Life pips: filled squares near player labels (top-left for top player, bottom-right for bottom player).
- Coin display: bottom-left, always visible during setup.
- State text: top-center. Shows timer during setup, "ROUND X" during intermission, "GO!" pre_battle, "YOU WIN!"/"YOU LOSE" only on `finished`.

---

## Lobby Screen

- Auto-joins matchmaking queue on init (no manual buttons).
- Displays animated spinner while searching.
- Shows queue time, player's trophy count.
- On `match_found`: receives `role`, opponent info → brief display (1.2s) → launches GameScreen.
- Cancel button: leaves queue, returns to menu.
- `close()` skips disconnect if `status == "matched"` (socket handed to GameScreen).

---

## Deck System

**Persistent Storage**: 5 deck slots per player, stored server-side in SQLite.

**Deck Structure**:
```lua
{
    name = "Deck 1",
    counts = {
        knight = 5,
        samurai = 3,
        boney = 7,
        marrow = 5
    }
}
```

**Deck Manager** (`src/deck_manager.lua`):
- **Persistent data**: `_data = {activeDeckIndex, decks}` (survives screen switches)
- **Transient draw pile**: `_drawPile = []` (reset each match)
- Max 20 cards per deck
- 5 deck slots (indices 1-5)
- Active deck index (nullable) indicates which deck is equipped for battle

**Key Functions**:
- `DeckManager.load()`: Loads from `_G.PlayerData.decks` (server) or local `decks.json` (offline backup)
- `DeckManager.save()`: Syncs to server via `sync_decks` message, saves locally as backup
- `DeckManager.setActive(deckIndex)`: Sets/toggles active deck for battle
- `DeckManager.initDrawPile()`: Builds and shuffles draw pile from active deck at game start
- `DeckManager.drawCards(n)`: Draws n cards from top of pile
- `DeckManager.reshuffleAndDraw(currentHand, n)`: Returns hand to pile, reshuffles, draws n new

**Menu UI** (Decks Panel):
- 5 deck slot tabs (D1-D5)
- Gold dot indicates active deck
- Card grid with +/- buttons to adjust unit counts
- Save button (shows "Saved!" feedback for 1.5s)
- Equip button (toggle active deck)
- Total card counter (20 max, red when full)

**Battle Integration**:
- `initDrawPile()` called at game start
- Returns `true` if active deck loaded, `false` for random fallback
- Cards drawn via `drawCards()` during setup phase
- Reroll returns cards via `returnCards()` then draws new ones

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
   cd /Users/cmatute1/auto-chest/auto-chest
   rsync -avz --exclude 'server/players.db' . root@75.119.142.247:/opt/autochest/
   ```

2. **Restart server:**
   ```bash
   ssh root@75.119.142.247
   sudo systemctl restart autochest-server
   ```

3. **Verify server is running:**
   ```bash
   sudo systemctl status autochest-server
   sudo journalctl -u autochest-server -f  # view logs
   ```

**Changes that require server restart:**
- Any changes to `server/` folder (matchmaking, database, authentication)
- Changes to network message formats in `src/screens/game.lua` or `src/screens/lobby.lua`
- Changes to unit behavior that affect determinism
- Changes to deck system or economy

**Local changes only (no server restart needed):**
- UI/visual changes (fonts, colors, layout)
- Client-side animations
- Menu screen changes (unless affecting networking)

**Production server:** `75.119.142.247:12345` (Contabo VPS, Ubuntu 22.04)

See `deploy/YOUR_DEPLOYMENT_STEPS.md` for complete deployment instructions.
