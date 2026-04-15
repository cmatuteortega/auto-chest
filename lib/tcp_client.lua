-- tcp_client.lua – drop-in replacement for lib/sock.lua
--
-- Presents the same public API that the rest of the codebase expects:
--   local sock = require("lib.tcp_client")
--   local client = sock.newClient(host, port)
--   client:setSerialization(encode, decode)   -- no-op; JSON is used internally
--   client:on("eventName", fn)
--   client:connect()
--   client:send("eventName", data)
--   client:update()                           -- call every frame (enterFrame)
--   client:isConnected() → bool
--   client:disconnect()
--   client:setTimeout(...)                    -- no-op; TCP handles this
--
-- Wire format: newline-delimited JSON arrays matching the server's encode():
--   ["eventName", {...data...}]\n
--
-- Solar2D includes LuaSocket, so require("socket") works on device and simulator.

local socket = require("socket")
local json   = require("lib.json")

local M = {}

function M.newClient(host, port)
    local self = {
        _host     = host,
        _port     = port,
        _socket   = nil,
        _buffer   = "",
        _handlers = {},
        _connected = false,
        _connecting = false,
    }

    -- ── Public API ────────────────────────────────────────────────────────────

    -- No-op: serialization is always JSON (matches server wire format)
    function self:setSerialization() end
    function self:setTimeout() end

    function self:on(eventName, fn)
        self._handlers[eventName] = fn
        return { event = eventName }
    end

    function self:removeCallback(handle)
        if handle and handle.event then
            self._handlers[handle.event] = nil
        end
    end

    function self:isConnected()
        return self._connected
    end

    function self:connect()
        local tcp, err = socket.tcp()
        if not tcp then
            print("[TCP] Failed to create socket:", err)
            self:_fire("connect_failed", {reason = err})
            return
        end
        tcp:settimeout(0)   -- non-blocking
        self._socket = tcp
        self._connecting = true

        -- Non-blocking connect returns "timeout" immediately; actual connection
        -- is confirmed on the next successful send/receive (checked in update()).
        local ok, cerr = tcp:connect(self._host, self._port)
        if ok or cerr == "timeout" then
            -- Will confirm connected state in update()
        else
            print("[TCP] Connect error:", cerr)
            self._connecting = false
            self:_fire("connect_failed", {reason = cerr})
        end
    end

    function self:send(eventName, data)
        if not self._socket then return end
        local msg = json.encode({eventName, data or {}}) .. "\n"
        local ok, err = pcall(function()
            self._socket:send(msg)
        end)
        if not ok then
            print("[TCP] Send error:", err)
        end
    end

    -- Poll for incoming messages. Call this every frame (e.g. in an enterFrame
    -- listener or in the composer scene's update loop via timer).
    function self:update()
        if not self._socket then return end

        -- Detect completed non-blocking connect
        if self._connecting then
            -- Attempt a zero-byte send to probe connection state
            local _, err = self._socket:send("")
            if err == nil or err == "closed" then
                -- Connected (send("") with no error means socket is writable)
                if err ~= "closed" then
                    self._connecting = false
                    self._connected  = true
                    self:_fire("connect", {})
                else
                    self._connecting = false
                    self:_fire("disconnect", {})
                    return
                end
            elseif err ~= "timeout" then
                -- Real connection error
                self._connecting = false
                print("[TCP] Connection failed:", err)
                self:_fire("connect_failed", {reason = err})
                return
            else
                return  -- still connecting, try again next frame
            end
        end

        -- Read all available data into buffer
        local chunk, err, partial = self._socket:receive(4096)
        local incoming = chunk or partial or ""
        if incoming ~= "" then
            self._buffer = self._buffer .. incoming
        end

        -- Dispatch every complete newline-delimited message
        while true do
            local nl = self._buffer:find("\n", 1, true)
            if not nl then break end

            local line   = self._buffer:sub(1, nl - 1)
            self._buffer = self._buffer:sub(nl + 1)

            if line ~= "" then
                local ok2, decoded = pcall(json.decode, line)
                if ok2 and type(decoded) == "table" and #decoded == 2 then
                    local evName = decoded[1]
                    local evData = decoded[2] or {}
                    self:_fire(evName, evData)
                end
            end
        end

        -- Handle disconnect
        if err == "closed" then
            self._connected = false
            self:_fire("disconnect", {})
        end
    end

    function self:disconnect()
        if self._socket then
            pcall(function() self._socket:close() end)
            self._socket    = nil
            self._connected = false
            self._connecting = false
            self._buffer    = ""
        end
    end

    -- ── Private ───────────────────────────────────────────────────────────────

    function self:_fire(eventName, data)
        local fn = self._handlers[eventName]
        if fn then
            local ok, err = pcall(fn, data)
            if not ok then
                print("[TCP] Handler error for '" .. eventName .. "':", err)
            end
        end
    end

    return self
end

return M
