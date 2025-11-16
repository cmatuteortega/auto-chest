# AutoChest

A 1v1 asynchronous grid-based autobattler mobile game built with Love2D.

## Game Concept

Players draft cards to place or upgrade units on their side of a 12x7 grid. After a timer expires, units automatically battle. The game features:

- **Grid**: 12 rows × 7 columns (16×16px cells)
- **Mobile-first**: Portrait orientation (1080×1920 resolution)
- **Asynchronous multiplayer**: Players make decisions during a timer, then watch the battle play out
- **Pixel art style**: Clean grid-based visuals

## Current Status (MVP)

✅ **Completed**:
- Core game setup and configuration
- Mobile portrait layout with pixel-perfect scaling
- 12×7 grid system with 16×16px cells
- Touch/mouse input handling
- Screen management (Menu → Game)
- Grid cell highlighting and selection
- Player zone separation (top/bottom halves)
- Setup timer (30 seconds countdown)
- Basic UI elements

❌ **Future Features**:
- Unit placement system
- Card drafting UI
- Unit stats (health, damage, abilities)
- Combat simulation
- Networking/multiplayer
- Deck building
- Pixel art character sprites
- Sound effects and music

## Project Structure

```
autochest/
├── conf.lua              # Love2D configuration
├── main.lua              # Entry point
├── lib/                  # External libraries
│   ├── classic.lua       # OOP system
│   ├── push.lua          # Resolution scaling
│   ├── screen_manager.lua # Screen state management
│   ├── screen.lua        # Base screen class
│   ├── baton.lua         # Input handling
│   ├── bump.lua          # Collision detection
│   ├── tween.lua         # Animation tweening
│   ├── cron.lua          # Timers
│   ├── signal.lua        # Event system
│   ├── camera.lua        # Camera effects
│   ├── tilemapper.lua    # Tile map support
│   ├── json.lua          # JSON serialization
│   ├── lume.lua          # Utility functions
│   ├── inspect.lua       # Debug tool
│   ├── audio.lua         # Audio helper
│   ├── anim8.lua         # Sprite animation
│   ├── sock.lua          # Networking
│   └── suit/             # UI library
└── src/
    ├── constants.lua     # Game constants
    ├── grid.lua          # Grid system
    └── screens/
        ├── menu.lua      # Menu screen
        └── game.lua      # Game screen

```

## How to Run

### Prerequisites

Install Love2D: https://love2d.org/

### Running the Game

```bash
# From the project directory
love .

# Or on macOS with Love2D installed
open -n -a love .
```

### Controls

- **Mouse/Touch**: Click or tap cells to select them
- **Escape**: Quit the game
- **R**: Reset the game (when in game screen)

## Technical Details

### Libraries Used

- **push.lua**: Handles resolution scaling for mobile devices
- **classic.lua**: Object-oriented programming
- **screen_manager.lua**: Screen state management
- **anim8.lua**: Ready for sprite animations
- **sock.lua**: Ready for networking
- **SUIT**: Ready for UI components

### Grid System

- 12 rows × 7 columns = 84 cells
- Each cell: 16×16 pixels
- Total grid size: 112px × 192px
- Player 1: Bottom 6 rows (rows 7-12)
- Player 2: Top 6 rows (rows 1-6)

### Resolution

- Target: 1080×1920 (mobile portrait)
- Desktop testing: 540×960 (50% scale)
- Uses pixel-perfect rendering

## Next Steps

To continue building the game, consider implementing:

1. **Unit System** ([src/unit.lua](src/unit.lua))
   - Extend classic.lua for unit entities
   - Add health, damage, and abilities
   - Unit rendering on grid

2. **Card System** ([src/card.lua](src/card.lua))
   - Card definitions and data
   - Draft UI using SUIT
   - Hand management

3. **Battle System** ([src/battle.lua](src/battle.lua))
   - Turn-based or real-time auto-combat
   - Damage calculation
   - Victory conditions

4. **Networking** ([src/network.lua](src/network.lua))
   - Integrate sock.lua
   - Matchmaking
   - State synchronization

5. **Assets**
   - Create pixel art sprites for units
   - Background artwork
   - Sound effects and music

## Development

The game uses a modular architecture:

- **Screens**: Menu, Game (future: Settings, Deck Builder, etc.)
- **Grid**: Handles cell positioning, highlighting, and ownership
- **Constants**: Centralized configuration
- **Input**: Normalized touch/mouse input through push.lua

All coordinates are automatically converted from window space to game space, ensuring consistent behavior across different screen sizes.

## License

TBD

---

Built with Love2D ❤️
