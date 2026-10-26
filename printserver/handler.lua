--- Glue between the HTTP layer (httpserver.lua) and the IPP layer
--- (ipp.lua, ops.lua, spool.lua). Install it with:
---
---   local Handler = require('<plugin folder>/handler')
---   server.ipp_handler = Handler.new({
---       port = server.port,
---       printer_name = 'Kindle PDF Printer',
---       save_dir = '/mnt/us/documents',
---       on_job = function(job) ... end,
---   })
---
--- HTTP-level problems (unreadable, truncated or malformed IPP) get an HTTP
--- error. Everything else, including IPP errors such as an unsupported
--- operation, is an HTTP 200 whose body is an IPP response (RFC 8010).
---
--- config: printer_name, port, save_dir, max_size, min_free, use_job_name,
--- on_job, spool (inject a prepared Spool, mainly for tests).

local base = (... or ''):match('^(.*)/[^/]*$')
local function sibling(name)
    return require(base and (base .. '/' .. name) or name)
end

local IPP = sibling('ipp')
local Ops = sibling('ops')
local Spool = sibling('spool')
local logger = require('logger')

local Handler = {}

-- The IPP attributes of any request are small. Refuse to buffer more than
-- this while waiting for them to complete.
local MAX_IPP_HEADER_SIZE = 64 * 1024

-- When a job is rejected before its document is read, read and discard up to
-- this much of the upload first. Closing a socket with unread data makes the
-- client see a connection reset instead of our IPP error.
local MAX_DRAIN_SIZE = 2 * 1024 * 1024

function Handler.new(config)
    config = config or {}
    local spool = config.spool or Spool.new({
        dir = config.save_dir,
        max_size = config.max_size,
        min_free = config.min_free,
        use_job_name = config.use_job_name,
    })
    if spool.cleanup then spool:cleanup() end -- drop temp files from an interrupted run

    local ctx = {
        printer_name = config.printer_name or 'Kindle PDF Printer',
        port = config.port or 631,
        started_at = os.time(),
        spool = spool,
        on_job = config.on_job,
    }

    return function(server, client, request)
        local next_chunk = server:_bodyReader(client, request)

        -- Read until the IPP attributes decode; the rest is the document.
        local buffer = ''
        local msg, next_pos
        local body_ended = false
        while not msg do
            local chunk, read_err = next_chunk()
            if chunk then
                buffer = buffer .. chunk
            elseif read_err then
                logger.warn('Print server: could not read body:', read_err)
                if read_err == 'body too large' then
                    server:_sendText(client, 413, 'Payload Too Large')
                else
                    server:_sendText(client, 400, 'Bad Request')
                end
                return
            else
                body_ended = true
            end

            local decoded, result = IPP.decode(buffer)
            if decoded then
                msg, next_pos = decoded, result
            elseif result ~= 'truncated' then
                logger.warn('Print server: bad request:', result)
                server:_sendText(client, 400, 'Bad Request')
                return
            elseif body_ended or #buffer > MAX_IPP_HEADER_SIZE then
                logger.warn('Print server: incomplete or oversized IPP header')
                server:_sendText(client, 400, 'Bad Request')
                return
            end
        end

        -- Track whether the operation read the document to its end.
        local document_done = body_ended
        local function tracked_next_chunk()
            local chunk, err = next_chunk()
            if not chunk then document_done = true end
            return chunk, err
        end

        -- Answer with the host the client used so printer-uri-supported and
        -- printer-more-info point back at the right address.
        local request_ctx = setmetatable({
            host = request.headers['host'] or ('localhost:' .. tostring(ctx.port)),
            document = {
                initial = buffer:sub(next_pos),
                next_chunk = tracked_next_chunk,
                content_length = request.content_length,
            },
        }, { __index = ctx })

        if not config.max_size and server.max_size then
            spool.max_size = server.max_size
        end

        local ok, resp = pcall(Ops.dispatch, msg, request_ctx)
        if not ok then
            logger.warn('printserver IPP: handler error:', resp)
            resp = IPP.new_response(msg, IPP.STATUS.SERVER_ERROR_INTERNAL_ERROR,
                'internal error')
        end

        if not document_done then
            local drained = 0
            while drained < MAX_DRAIN_SIZE do
                local chunk = tracked_next_chunk()
                if not chunk then break end
                drained = drained + #chunk
            end
        end

        local encoded_ok, bytes = pcall(IPP.encode, resp)
        if not encoded_ok then
            logger.warn('printserver IPP: could not encode response:', bytes)
            server:_sendText(client, 500, 'Internal Server Error')
            return
        end

        logger.info('printserver IPP:', IPP.op_name(msg.code), '->', IPP.status_name(resp.code))
        server:_sendHttp(client, 200, 'application/ipp', bytes)
    end
end

return Handler