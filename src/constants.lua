local Constants = {}

-- Game resolution (virtual)
Constants.GAME_WIDTH = 540
Constants.GAME_HEIGHT = 960

-- Grid configuration
Constants.GRID_COLS = 7
Constants.GRID_ROWS = 12
Constants.CELL_SIZE = 48  -- Larger cells for better visibility

-- Grid dimensions in pixels
Constants.GRID_WIDTH = Constants.GRID_COLS * Constants.CELL_SIZE  -- 336px
Constants.GRID_HEIGHT = Constants.GRID_ROWS * Constants.CELL_SIZE -- 576px

-- Player sides (rows are split between two players)
Constants.PLAYER1_ROWS = 6  -- Bottom half (rows 7-12)
Constants.PLAYER2_ROWS = 6  -- Top half (rows 1-6)

-- Colors (placeholder)
Constants.COLORS = {
    BACKGROUND = {0.1, 0.1, 0.15, 1},
    GRID_LINE = {0.3, 0.3, 0.35, 1},
    GRID_BG = {0.15, 0.15, 0.2, 1},
    PLAYER1_CELL = {0.2, 0.3, 0.5, 0.3},
    PLAYER2_CELL = {0.5, 0.2, 0.3, 0.3},
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
