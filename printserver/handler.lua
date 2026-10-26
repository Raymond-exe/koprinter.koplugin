--- Glue between the HTTP layer (httpserver.lua) and the IPP layer
--- (ipp.lua, ops.lua). Install it with:
---
---   local Handler = require('printserver/handler')
---   server.ipp_handler = Handler.new({ port = server.port, printer_name = 'Kindle PDF Printer' })
---
--- HTTP-level problems (unreadable, truncated or malformed IPP) get an HTTP
--- error. Everything else, including IPP errors such as an unsupported
--- operation, is an HTTP 200 whose body is an IPP response (RFC 8010).

local IPP = require('printserver/ipp')
local Ops = require('printserver/ops')
local logger = require('logger')

local Handler = {}

-- Step 4 reads whole bodies into memory, which is fine for the small
-- non-document operations. Print-Job (Step 5) must stream the document
-- instead of reading it here.
local MAX_REQUEST_SIZE = 64 * 1024

function Handler.new(config)
    config = config or {}
    local ctx = {
        printer_name = config.printer_name or 'Kindle PDF Printer',
        port = config.port or 6310,
        started_at = os.time(),
    }

    return function(server, client, request)
        local body, read_err = server:_readBody(client, request, MAX_REQUEST_SIZE)
        if not body then
            logger.warn('printserver IPP: could not read body:', read_err)
            if read_err == 'body too large' then
                server:_sendText(client, 413, 'Payload Too Large')
            else
                server:_sendText(client, 400, 'Bad Request')
            end
            return
        end

        local msg, decode_err = IPP.decode(body)
        if not msg then
            logger.warn('printserver IPP: bad request:', decode_err)
            server:_sendText(client, 400, 'Bad Request')
            return
        end

        -- Answer with the host the client used so printer-uri-supported and
        -- printer-more-info point back at the right address.
        local request_ctx = setmetatable({
            host = request.headers['host'] or ('localhost:' .. tostring(ctx.port)),
        }, { __index = ctx })

        local ok, resp = pcall(Ops.dispatch, msg, request_ctx)
        if not ok then
            logger.warn('printserver IPP: handler error:', resp)
            resp = IPP.new_response(msg, IPP.STATUS.SERVER_ERROR_INTERNAL_ERROR,
                'internal error')
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