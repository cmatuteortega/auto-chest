local Constants = {}

-- Game resolution (virtual)
Constants.GAME_WIDTH = 540
Constants.GAME_HEIGHT = 960

-- Grid configuration
Constants.GRID_COLS = 5
Constants.GRID_ROWS = 8
Constants.CELL_SIZE = 64  -- Larger cells for better visibility

-- Grid dimensions in pixels
Constants.GRID_WIDTH = Constants.GRID_COLS * Constants.CELL_SIZE  -- 320px
Constants.GRID_HEIGHT = Constants.GRID_ROWS * Constants.CELL_SIZE -- 512px

-- Player sides (rows are split between two players)
Constants.PLAYER1_ROWS = 4  -- Bottom half (rows 5-8)
Constants.PLAYER2_ROWS = 4  -- Top half (rows 1-4)

-- Colors (placeholder)
Constants.COLORS = {
    BACKGROUND = {0.1, 0.1, 0.15, 1},
    GRID_LINE = {0.3, 0.3, 0.35, 1},
    GRID_BG = {0.15, 0.15, 0.2, 1},
    -- Chess pattern colors
    CHESS_LIGHT = {0x26/255, 0x38/255, 0x4D/255, 1},  -- #26384D
    CHESS_DARK = {0x16/255, 0x2A/255, 0x3D/255, 1},   -- #162A3D
    CELL_HIGHLIGHT = {1, 1, 1, 0.2},
}

-- UI spacing
Constants.GRID_OFFSET_X = (Constants.GAME_WIDTH - Constants.GRID_WIDTH) / 2
Constants.GRID_OFFSET_Y = 180  -- Leave room for UI at top and bottom

-- Font sizes (larger for better visibility)
Constants.FONT_SIZES = {
    LARGE = 48,   -- Titles
    MEDIUM = 32,  -- Subtitles, important text
    SMALL = 24,   -- UI elements, instructions
    TINY = 16     -- Debug text, card labels
}

return Constants
