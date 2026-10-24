--- Non-blocking HTTP/IPP server for the FileSync plugin.
--- Built on LuaSocket, integrated with KOReader's UIManager for cooperative scheduling.
--- Handles routing for static file serving (web UI) and JSON API endpoints.
--- Delegates file operations to the fileops module and uses the shared json module
--- for request/response serialization.
---
--- Key dependencies: socket (LuaSocket), UIManager (KOReader), filesync/json, filesync/fileops

local logger = require("logger")
local socket = require("socket")
local UIManager = require("ui/uimanager")

local IPP_PATH = '/ipp/print'
local DEFAULT_MAX_BODY_SIZE = 50 * 1024 * 1024
local MAX_HEADER_COUNT = 100 -- max HTTP headers per request
local CONNECTION_TIMEOUT = 2 --- secs
local BODY_CHUNK_TIMEOUT = 10
local STREAM_CHUNK_SIZE = 65536
local UI_YIELD_INTERVAL = 32 -- chunks
local MAX_POLL_TIME = 3

local STATUS_TEXTS = {
    [100] = "Continue",
    [200] = "OK",
    [400] = "Bad Request",
    [404] = "Not Found",
    [405] = "Method Not Allowed",
    [411] = "Length Required",
    [413] = "Payload Too Large",
    [415] = "Unsupported Media Type",
    [431] = "Request Header Fields Too Large",
    [500] = "Internal Server Error",
    [501] = "Not Implemented",
}

local HttpServer = {
    port = 6310,
    max_size = DEFAULT_MAX_BODY_SIZE,
    ipp_handler = nil,
    _server_socket = nil,
    _running = false,
    _poll_function = nil,
}

function HttpServer:new(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    return o
end

--- Bind to the listening socket and start polling
function HttpServer:start()
    if self._running then return end

    local server = socket.tcp()
    server:setoption('reuseaddr', true)

    local ok, err = server:bind('*', self.port)
    if not ok then
        server:close()
        error("Could not bind to port " .. self.port .. ": " .. tostring(err))
    end

    ok, err = server:listen(16)
    if not ok then
        server:close()
        error("Could not listen to port " .. self.port .. ": " .. tostring(err))
    end

    server:settimeout(0) -- Non-blocking

    self._server_socket = server
    self._running = true
    logger.info("Print server listening on port", self.port)

    -- Schedule polling via UIManager
    self:_schedulePoll()
end

--- Stop the HTTP server: close the socket, clear caches, and stop polling.
function HttpServer:stop()
    self._running = false

    if self._poll_function then
        UIManager:unschedule(self._poll_function)
        self._poll_function = nil
    end

    if self._server_socket then
        self._server_socket:close()
        self._server_socket = nil
    end
    logger.info("Print server stopped")
end

function HttpServer:_schedulePoll()
    if not self._running then return end
    if not self._poll_function then
        self._poll_function = function() self:_poll() end
    end
    UIManager:scheduleIn(0.1, self._poll_function)
end

function HttpServer:_poll()
    if not self._running or not self._server_socket then return end

    local poll_start = socket.gettime()

    for _ = 1, 4 do
        if socket.gettime() - poll_start >= MAX_POLL_TIME then
            logger.dbg("Print server: poll time budget exceeded, deferring remaining connections")
            break
        end

        local client = self._server_socket:accept()
        if not client then break end

        client:settimeout(CONNECTION_TIMEOUT)
        logger.info('Print server: Connection accepted')
        local ok, err = pcall(function()
            self:_handleClient(client)
        end)
        if not ok then
            logger.warn("Print server: Error handling client:", err)
            pcall(function()
                self:_sendText(client, 500, tostring(err))
            end)
        end
        pcall(function() client:close() end)
    end

    self:_schedulePoll()
end

function HttpServer:_handleClient(client)
    local request_line, recv_err = client:receive("*l")
    if not request_line then
        logger.warn("Print server HTTP: receive failed:", recv_err)
        self:_sendText(client, 400, "Bad Request")
        return
    end

    local method, path, _ = request_line:match("^(%S+)%s+(%S+)%s+(%S+)")
    if not method or not path then
        self:_sendText(client, 400, "Bad Request")
        return
    end
    logger.dbg("Print server HTTP:", method, path)

    -- Read headers (limit count to prevent resource exhaustion)
    local headers = {}
    local header_count = 0
    while true do
        local line = client:receive("*l")
        if not line or line == "" then break end
        header_count = header_count + 1
        if header_count > MAX_HEADER_COUNT then
            self:_sendText(client, 431, "Request Header Fields Too Large")
            return
        end
        local key, value = line:match("^([^:]+):%s*(.+)")
        if key then
            headers[key:lower()] = value
        end
    end

    local request = {
        method = method,
        path = path,
        headers = headers,
        content_length = tonumber(headers['content-length']),
        chunked = (headers['transfer-encoding'] or ''):lower():find('chunked', 1, true) ~= nil,
    }

    if method == 'GET' and path == IPP_PATH then
        self:_sendText(client, 200, "Print server ok")
        return
    end

    if method == 'POST' and path == IPP_PATH then
        self:_handleIpp(client, request)
        return
    end

    if path == IPP_PATH or path == '/' then
        self:_sendText(client, 405, "Method Not Allowed")
        return
    end

    self:_sendText(client, 404, "Not Found")
end


function HttpServer:_handleIpp(client, request)
    if not self.ipp_handler then
        self:_sendText(client, 501, 'Not Implemented')
        return
    end
 
    local content_type = (request.headers['content-type'] or ''):lower()
    if not content_type:find('application/ipp', 1, true) then
        self:_sendText(client, 415, 'Unsupported Media Type')
        return
    end
 
    -- A body needs a length or chunked encoding.
    if not request.chunked and not request.content_length then
        self:_sendText(client, 411, 'Length Required')
        return
    end
    if request.content_length and request.content_length > self.max_size then
        self:_sendText(client, 413, 'Payload Too Large')
        return
    end
 
    -- Clients send Expect: 100-continue before the body; answer after the cheap checks above so we can still reject without receiving it.
    local expect = (request.headers['expect'] or ''):lower()
    if expect:find('100-continue', 1, true) then
        self:_sendAll(client, 'HTTP/1.1 100 Continue\r\n\r\n')
    end
 
    self.ipp_handler(self, client, request)
end

function HttpServer:_bodyReader(client, request)
    client:settimeout(BODY_CHUNK_TIMEOUT)
    local max_size = self.max_size
    local total = 0
    local chunk_count = 0
    local raw_next
 
    if request.chunked then
        local remaining = 0
        local finished = false
        raw_next = function()
            if finished then return nil end
            if remaining == 0 then
                local line, err = client:receive('*l')
                if not line then return nil, err or 'connection lost' end
                local hex = line:match('^%s*(%x+)')
                if not hex then return nil, 'bad chunk size' end
                local size = tonumber(hex, 16)
                if size == 0 then
                    -- Consume trailer headers up to the blank line.
                    while true do
                        local trailer = client:receive('*l')
                        if not trailer or trailer == '' then break end
                    end
                    finished = true
                    return nil
                end
                remaining = size
            end
            local want = math.min(remaining, STREAM_CHUNK_SIZE)
            local data, err, partial = client:receive(want)
            data = data or partial
            if not data or #data == 0 then
                return nil, err or 'connection lost'
            end
            remaining = remaining - #data
            if remaining == 0 then
                client:receive('*l') -- CRLF that follows every chunk
            end
            return data
        end
    else
        local remaining = request.content_length or 0
        raw_next = function()
            if remaining <= 0 then return nil end
            local data, err, partial =
                client:receive(math.min(remaining, STREAM_CHUNK_SIZE))
            data = data or partial
            if not data or #data == 0 then
                return nil, err or 'connection lost'
            end
            remaining = remaining - #data
            return data
        end
    end
 
    return function()
        local data, err = raw_next()
        if not data then return nil, err end
        total = total + #data
        if total > max_size then
            return nil, 'body too large'
        end
        chunk_count = chunk_count + 1
        if chunk_count % UI_YIELD_INTERVAL == 0 then
            pcall(function() UIManager:handleInput() end)
        end
        return data
    end
end
 

function HttpServer:_readBody(client, request, max_bytes)
    local limit = max_bytes or self.max_size
    local next_chunk = self:_bodyReader(client, request)
    local parts = {}
    local total = 0
    while true do
        local data, err = next_chunk()
        if not data then
            if err then return nil, err end
            break
        end
        total = total + #data
        if total > limit then return nil, 'body too large' end
        parts[#parts + 1] = data
    end
    return table.concat(parts)
end

function HttpServer:_sendAll(client, data)
    local total = #data
    local sent = 0
    local stalls = 0
    while sent < total do
        local last, err, partial = client:send(data, sent + 1)
        local now_sent = last or partial or sent
        if now_sent > sent then
            sent = now_sent
            stalls = 0
        else
            stalls = stalls + 1
            if err or stalls >= 3 then
                return nil, err or 'send stalled'
            end
        end
    end
    return sent
end

-- For plain-text responses
function HttpServer:_sendText(client, status, text)
    return self:_sendHttp(client, status, 'text/plain; charset=utf-8', text .. '\n') -- TODO inline
end

function HttpServer:_sendHttp(client, status, content_type, body, extra_headers)
    body = body or ''
    local parts = {
        'HTTP/1.1 ' .. status .. ' ' .. (STATUS_TEXTS[status] or 'OK') .. '\r\n',
        'Content-Type: ' .. content_type .. '\r\n',
        'Content-Length: ' .. #body .. '\r\n',
        'Connection: close\r\n',
    }
    if extra_headers then
        for key, value in pairs(extra_headers) do
            parts[#parts + 1] = key .. ': ' .. value .. '\r\n'
        end
    end
    parts[#parts + 1] = '\r\n'
    parts[#parts + 1] = body
    return self:_sendAll(client, table.concat(parts))
end

return HttpServer