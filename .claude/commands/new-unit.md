Create a new AutoChest unit from the specification in $ARGUMENTS (or ask the user if not provided).

## What you need from the user (if not in $ARGUMENTS)

Ask for:
- **Name** (lowercase, used as the Lua class name capitalized and as the file/registry key)
- **Type**: `melee` (extends BaseUnit) or `ranged` (extends BaseUnitRanged)
- **Cost**: Gold cost (integer)
- **Stats**: HP, Damage, Attack Speed, Move Speed, Attack Range (and Projectile Speed if ranged)
- **Passive description** (one sentence)
- **3 upgrades**: name + description for each

## Checklist before writing any code

1. Read `src/units/marrow.lua` (ranged reference) or `src/units/knight.lua` (melee reference)
2. Read `src/unit_registry.lua` to confirm the 5 tables to update

## Files to create / modify

### 1. `src/units/{name}.lua`

Use the exact pattern below. Fill in the blanks, remove the comments.

**Melee template** (extends BaseUnit):
```lua
local BaseUnit = require('src.base_unit')

local {Name} = BaseUnit:extend()

function {Name}:new(row, col, owner, sprites)
    local stats = {
        health      = {HP},
        maxHealth   = {HP},
        damage      = {DMG},
        attackSpeed = {SPD},
        moveSpeed   = 1,
        attackRange = 0,
        unitType    = "{name}"
    }

    {Name}.super.new(self, row, col, owner, sprites, stats)

    -- Per-round state fields go here (reset in resetCombatState if needed)

    self.upgradeTree = {
        { name = "{U1 name}", description = "{U1 desc}", onApply = function(unit) end },
        { name = "{U2 name}", description = "{U2 desc}", onApply = function(unit) end },
        { name = "{U3 name}", description = "{U3 desc}", onApply = function(unit) end },
    }
end

-- Override only the hooks you need:
-- :getDamage(grid)        → modify damage value at attack time
-- :attack(target, grid)   → custom attack logic (call super or replicate melee hit)
-- :update(dt, grid)       → per-frame logic; always end with {Name}.super.update(self, dt, grid)
-- :onKill(target)         → triggered when this unit kills an enemy
-- :onBattleStart(grid)    → called once when battle begins
-- :resetCombatState()     → reset per-round fields; call {Name}.super.resetCombatState(self) first

return {Name}
```

**Ranged template** (extends BaseUnitRanged):
```lua
local BaseUnit      = require('src.base_unit')
local BaseUnitRanged = require('src.base_unit_ranged')
local Constants     = require('src.constants')  -- only if using GRID_COLS/GRID_ROWS

local {Name} = BaseUnitRanged:extend()

function {Name}:new(row, col, owner, sprites)
    local stats = {
        health          = {HP},
        maxHealth       = {HP},
        damage          = {DMG},
        attackSpeed     = {SPD},
        moveSpeed       = 1,
        attackRange     = {RNG},
        projectileSpeed = {PROJ},
        unitType        = "{name}"
    }

    {Name}.super.new(self, row, col, owner, sprites, stats)

    self.upgradeTree = {
        { name = "{U1 name}", description = "{U1 desc}", onApply = function(unit) end },
        { name = "{U2 name}", description = "{U2 desc}", onApply = function(unit) end },
        { name = "{U3 name}", description = "{U3 desc}", onApply = function(unit) end },
    }
end

-- Override only what you need.
-- IMPORTANT for ranged update overrides:
--   If you override update(), handle self.arrows yourself AND call
--   BaseUnit.update(self, dt, grid) at the end (NOT {Name}.super.update,
--   which is BaseUnitRanged:update — that would double-process arrows).
--   Only use {Name}.super.update(self, dt, grid) when you are NOT touching self.arrows.

return {Name}
```

### 2. `src/unit_registry.lua` — 5 additions

```lua
-- Line 1-6 (requires):
local {Name} = require('src.units.{name}')

-- unitClasses table:
{name} = {Name},

-- spritePaths table:
{name} = {
    front = "src/assets/{name}/front.png",
    back  = "src/assets/{name}/back.png",
    dead  = "src/assets/{name}/dead.png"
},

-- passiveDescriptions table:
{name} = "{passive description}",

-- unitCosts table:
{name} = {cost},
```

### 3. Sprites (manual step — remind the user)

Pixel art sprites (16×16 px) are needed at:
- `src/assets/{name}/front.png` — facing the enemy
- `src/assets/{name}/back.png` — moving away
- `src/assets/{name}/dead.png` — dead state

Until real art is ready, copy sprites from an existing unit as placeholders.

## ACTION Moves

ACTION moves are abilities that fire at the **start of a battle round**, before any regular unit pathfinding or attacking begins.

### When to use
Use ACTION moves for abilities that should resolve as an opening burst — charges, leaps, instant taunts, teleports, etc. Examples: **Bull** (Stampede charge), **Knight** (Taunt).

### How to implement

1. In the unit constructor, set:
   ```lua
   self.isActionUnit   = true
   self.actionDuration = N  -- seconds your action takes (0 for instant effects)
   ```
2. In `onBattleStart(grid)`: set up the action (positions, targets, animation, flag-setting).
3. If animated (actionDuration > 0): in `update(dt, grid)`, drive the animation and `return` early until complete, then resume normal combat by calling `{Name}.super.update(self, dt, grid)`.
4. In `resetCombatState()`: reset all per-round ACTION state. Do NOT reset `isActionUnit` / `actionDuration` — they are permanent.

The engine (`startBattle()` in `game.lua`) automatically sets `actionDelayTimer = maxActionDuration` on all **non-action** units after `onBattleStart()` is called for everyone, so they idle until all animated ACTION moves finish.

### Stun system
Any unit can stun another: `target.stunTimer = N` (seconds). Stunned units skip all AI until the timer expires. Automatically reset each round via `BaseUnit:resetCombatState()`.

### Notes
- Instant ACTION moves (`actionDuration = 0`) don't trigger the delay — only animated ones do.
- Multiple ACTION units on the field execute simultaneously; non-action units wait for the longest one.

---

## Key rules to follow

- Upgrade stat scaling is automatic: `1.5^level` multiplier applied to HP and damage.
  Do NOT manually multiply base stats in upgrades.
- `onApply` can be `function(unit) end` (no-op) when the effect is handled in `update`/`getDamage`/`onKill`.
- Use `self:hasUpgrade(index)` (1-based) to check active upgrades.
- For damage modifiers: override `getDamage(grid)` and return the modified value.
- For simple stat changes on purchase: use `onApply` directly (e.g. `unit.attackRange = unit.attackRange + 1`).
- `resetCombatState()` is called each round. Override it to reset per-round fields.

## After creating the files

1. Confirm both files look correct.
2. Remind the user to run `love .` to verify the unit appears in the collection and deck builder.
3. Remind the user to run `lua tests/test_battle_determinism.lua` if combat logic was added.
