-- AutoChest Configuration
-- Switch between local development and production server

local config = {}

-- Check for environment variable to determine mode
local PRODUCTION = os.getenv("AUTOCHEST_PRODUCTION")

if PRODUCTION == "true" then
    -- Production: Connect to cloud server
    config.SERVER_ADDRESS = os.getenv("AUTOCHEST_SERVER_IP") or "75.119.142.247"
    config.SERVER_PORT = tonumber(os.getenv("AUTOCHEST_SERVER_PORT")) or 12345
else
    -- Development: Connect to localhost
    config.SERVER_ADDRESS = "127.0.0.1"
    --config.SERVER_ADDRESS = "75.119.142.247"
    config.SERVER_PORT = 12345
end

return config
