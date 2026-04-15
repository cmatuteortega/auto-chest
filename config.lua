-- Solar2D project configuration (replaces conf.lua)
-- This file is read by Solar2D before main.lua

application = {
    content = {
        -- Virtual resolution (matches Love2D GAME_WIDTH/GAME_HEIGHT)
        width  = 540,
        height = 960,

        -- letterBox: preserves aspect ratio, adds black bars if needed
        scale = "letterBox",

        fps = 60,

        -- Center content on screen
        xAlign = "center",
        yAlign = "center",
    },
}
