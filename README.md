# AutoChest

A 1v1 online autobattler (Clash Mini-style) built with Love2D/Lua.

## Game Overview

AutoChest is a competitive autobattler where players draft cards during a 30-second setup phase to place and upgrade units on their side of the grid. Once both players are ready (or the timer expires), units battle automatically until one side is eliminated. The first player to lose 3 lives loses the match.

**Key Features**:
- **Online multiplayer**: Cloud-hosted matchmaking server with authentication
- **Trophy-based matchmaking**: Players matched by skill rating (±100-500 range)
- **Deck building**: 5 persistent deck slots, up to 20 cards per deck
- **Strategic gameplay**: Unit placement, upgrades, and economy management
- **Deterministic battles**: Fixed timestep simulation ensures fair, reproducible results

## Current Status

✅ **Fully Implemented**:
- Complete 1v1 online multiplayer with authentication
- Cloud server deployment (75.119.142.247:12345)
- Trophy-based matchmaking system
- 5-panel swipe UI (Collection/Decks/Battle/Shop/Ranking)
- Persistent deck system (5 slots, server-synced)
- Card drafting and hand management
- Unit placement, upgrading, and repositioning
- Deterministic battle simulation
- Economy system (coins, rerolls, consolation bonuses)
- Lives system (3 lives each, -1 per loss)
- 4 unit types: Knight, Samurai, Boney, Marrow
- Ranged and melee combat with pathfinding
- Desync detection and prevention
- Round flow with intermissions
- SQLite database with bcrypt password hashing

🚧 **In Progress**:
- Additional unit types and abilities
- Shop system for unlocking units
- Trophy ranking leaderboards
- Unit collection UI

## How to Run

### Local Development (Localhost Server)

Run client and local server on your machine:

```bash
# Terminal 1: Start local development server
love server/

# Terminal 2: Start client (connects to localhost)
love .
```

### Production (Cloud Server)

Play online against other players:

```bash
# Quick launcher for production server
./play-online.sh

# Or manually
love .
# (server configured for production in src/config.lua)
```

### Prerequisites

- [Love2D](https://love2d.org/) (v11.4 or later)
- For server: LuaRocks packages: `luasocket`, `enet`, `lsqlite3`, `bcrypt`

## Project Structure

```
autochest/
├── CLAUDE.md                          # Complete project reference
├── conf.lua                           # Love2D config (540×960 window)
├── main.lua                           # Entry point
├── play-online.sh                     # Quick launcher for production
├── tests/
│   └── test_battle_determinism.lua    # Determinism regression test
├── deploy/                            # Cloud deployment files
│   ├── DEPLOYMENT_GUIDE.md            # Complete deployment guide
│   ├── YOUR_DEPLOYMENT_STEPS.md       # Quick setup instructions
│   ├── server-setup.sh                # VPS setup script
│   ├── autochest-server.service       # Systemd service file
│   └── backup-db.sh                   # Database backup script
├── server/                            # Matchmaking Server
│   ├── main.lua                       # ENet server (auth, matchmaking, relay)
│   ├── database.lua                   # SQLite wrapper
│   ├── players.db                     # Player database (created on first run)
│   └── matchmaking.log                # Server event log
├── lib/
│   ├── classic.lua                    # OOP system
│   ├── sock.lua                       # ENet networking wrapper
│   ├── json.lua                       # JSON encode/decode
│   ├── screen.lua & screen_manager.lua
│   └── suit/                          # Immediate-mode UI library
└── src/
    ├── config.lua                     # Server address config (dev/production)
    ├── constants.lua                  # Resolution, grid layout, scaling
    ├── grid.lua                       # Grid data model + rendering
    ├── deck_manager.lua               # Persistent deck storage + draw pile
    ├── base_unit.lua                  # Base class for all units
    ├── base_unit_ranged.lua           # Ranged unit base (arrow projectiles)
    ├── unit_registry.lua              # Unit type registry, cost table
    ├── card.lua                       # Draggable card UI element
    ├── tooltip.lua                    # Unit stat tooltip with upgrade button
    ├── pathfinding.lua                # A* pathfinding for unit movement
    ├── units/
    │   ├── knight.lua                 # Melee tank unit
    │   ├── samurai.lua                # High-damage melee unit
    │   ├── boney.lua                  # Ranged skeleton archer
    │   └── marrow.lua                 # Ranged bone mage
    └── screens/
        ├── login.lua                  # Authentication screen
        ├── menu.lua                   # Main menu (5-panel swipe UI)
        ├── lobby.lua                  # Matchmaking lobby
        └── game.lua                   # Core game screen (all game logic)
```

## Game Mechanics

### Grid System

- **8 rows × 5 columns** (16×16px cells)
- **Player 1 zone**: Rows 5-8 (bottom)
- **Player 2 zone**: Rows 1-4 (top)
- Perspective flips based on player role (always see your zone at bottom)

### Economy

- Start: **6 coins**
- Each round: **+6 coins**
- Losing a round: **+3 consolation coins**
- Reroll: **1 coin**

### Lives System

- Each player starts with **3 lives**
- Losing a round: **-1 life**
- 0 lives: **Game over**

### Round Flow

1. **Setup (30s)**: Place, upgrade, and reposition units from hand
2. **Pre-battle (1s)**: "GO!" flash before battle starts
3. **Battle**: Units fight automatically until one side is eliminated
4. **Intermission (2.5s)**: Bodies remain visible, life deducted after
5. **Reset**: All units return to home positions, +6 coins, repeat

### Deck System

- **5 deck slots** per player (server-synced)
- Up to **20 cards** per deck
- Active deck indicator (gold dot)
- Draw pile shuffles at game start
- Reroll returns cards and draws new ones

## Online Multiplayer

### Server Architecture

**Production Server**: `75.119.142.247:12345` (Contabo VPS, Ubuntu 22.04)

- **Authentication**: SQLite database with bcrypt password hashing
- **Matchmaking**: Queue-based, trophy range ±100 (expands +50 every 5s, max ±500)
- **Relay**: Server forwards game messages between matched players
- **Persistence**: Decks, trophies, and player stats stored server-side

### Authentication Flow

1. Register/login with username and password
2. Server validates and returns player data (ID, trophies, coins, decks)
3. Token stored for session management

### Matchmaking

1. Join queue with player ID and trophy count
2. Server matches players within trophy range
3. Roles assigned: P1 (host) generates RNG seed, P2 (guest) follows
4. Match begins with opponent information displayed

### Trophy System

- **Winner**: +20 trophies
- **Loser**: -15 trophies (min 0)
- Updated server-side after each match

## Determinism & Fair Play

AutoChest uses several techniques to ensure both players see identical battles:

1. **Fixed timestep loop**: Battle advances in discrete 1/60s steps (independent of frame rate)
2. **Deterministic pathfinding**: A* tie-breaks by row → col for reproducible paths
3. **Deterministic target selection**: Equidistant enemies broken by col → row → owner
4. **RNG seed**: P1 generates seed, both players initialize with same seed
5. **Board hash sync**: Clients exchange board state hash at battle start to detect desyncs

**Run determinism test**:
```bash
lua tests/test_battle_determinism.lua
```

## Controls

- **Mouse/Touch**: Click or drag units/cards
- **Drag & Drop**: Place units on grid or reposition existing units
- **Tooltip**: Click unit to see stats and upgrade button
- **Ready Button**: Start battle (both players must click)
- **Reroll Button**: Return cards and draw new hand (costs 1 coin)

## Cloud Server Management

### View Server Logs

```bash
ssh root@75.119.142.247
sudo journalctl -u autochest-server -f
```

### Restart Server

```bash
ssh root@75.119.142.247
sudo systemctl restart autochest-server
```

### Deploy Code Changes

```bash
# From local project directory
cd /Users/cmatute1/auto-chest/auto-chest
rsync -avz --exclude 'server/players.db' . root@75.119.142.247:/opt/autochest/
ssh root@75.119.142.247
sudo systemctl restart autochest-server
```

See [deploy/YOUR_DEPLOYMENT_STEPS.md](deploy/YOUR_DEPLOYMENT_STEPS.md) for complete deployment instructions.

## Development

### Adding New Units

1. Create unit file in `src/units/` extending `BaseUnit` or `BaseUnitRanged`
2. Implement stats, abilities, and `onBattleStart()` logic
3. Register in `src/unit_registry.lua` with cost and sprite paths
4. Add sprites: `front.png`, `back.png`, `dead.png`

### Network Messages

All game actions send messages through server relay:
- `place_unit`, `remove_unit`, `upgrade_unit` (setup phase)
- `ready` (trigger battle)
- `battle_start` (P1 only, includes RNG seed)
- `round_end_ready` (animations complete)
- `board_sync_check` (desync detection)

## Testing

### Determinism Regression Test

Ensures battles are reproducible across clients:

```bash
lua tests/test_battle_determinism.lua
```

Runs 10 battles with identical setups and verifies outcome consistency.

## Technical Stack

- **Love2D**: Game engine (Lua)
- **ENet**: UDP networking with reliability layer
- **SQLite**: Player database (server-side)
- **bcrypt**: Password hashing
- **SUIT**: Immediate-mode UI library
- **classic.lua**: OOP system
- **sock.lua**: ENet wrapper

## License

TBD

---

Built with Love2D ❤️

For detailed technical documentation, see [CLAUDE.md](CLAUDE.md).
