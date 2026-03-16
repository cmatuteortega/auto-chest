function love.conf(t)
    t.window.width  = 420
    t.window.height = 260
    t.window.title  = "AutoChest – Relay Server"
    t.window.resizable = false
    t.audio.mic = false
    t.audio.mixwithsystem = false
    
    t.window = nil
    t.modules.audio = false
    t.modules.joystick = false
    t.modules.touch = false
    
    t.identity = "autochest-server"
end
