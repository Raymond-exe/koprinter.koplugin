--- IPP operation handlers (RFC 8011) for the print server plugin.
--- Pure logic: takes a decoded request message plus a context table and
--- returns a response message. No sockets, no KOReader imports, so it is
--- testable with busted on a PC.
---
--- Context (ctx):
---   printer_name  string, shown to clients
---   host          'host:port' the client used (from the HTTP Host header)
---   started_at    os.time() when the service started (for printer-up-time)
---   spool         Spool object (Print-Job); document = { initial, next_chunk, content_length } is the stream after the IPP attributes
---   on_job        optional function(job) called after a job is saved
---
--- Operations are registered in Ops.handlers; the operations-supported
--- attribute is generated from that table, so a new handler is advertised
--- automatically.

local base = (... or ''):match('^(.*)/[^/]*$')
local IPP = require(base and (base .. '/ipp') or 'ipp')

local T, G, S, OP = IPP.TAG, IPP.GROUP, IPP.STATUS, IPP.OP

local IPP_PATH = '/ipp/print'
local DOCUMENT_FORMATS = { 'application/pdf', 'application/octet-stream' }
local JOB_STATE_COMPLETED = 9

local Ops = {}
Ops.handlers = {}

-- Group keywords a client may put in requested-attributes. Names that match
-- neither an attribute we know nor one of these are reported as unsupported.
local GROUP_KEYWORDS = {
    ['all'] = true,
    ['printer-description'] = true,
    ['job-template'] = true,
    ['job-description'] = true,
    ['document-description'] = true,
    ['document-template'] = true,
    ['subscription-description'] = true,
    ['subscription-template'] = true,
    ['event-notification-description'] = true,
}

local MEDIA_A4 = { name = 'iso_a4_210x297mm', x = 21000, y = 29700 }
local MEDIA_LETTER = { name = 'na_letter_8.5x11in', x = 21590, y = 27940 }
local MEDIA = { MEDIA_A4, MEDIA_LETTER }

local function media_col(media)
    return IPP.collection(
        IPP.member('media-size', T.BEGCOLLECTION, IPP.collection(
            IPP.member('x-dimension', T.INTEGER, media.x),
            IPP.member('y-dimension', T.INTEGER, media.y))))
end

--- Sorted list of the operation ids we have handlers for.
local function supported_operations()
    local ops = {}
    for code in pairs(Ops.handlers) do ops[#ops + 1] = code end
    table.sort(ops)
    return ops
end

--- Build the printer's attribute catalog for one request.
--- Each entry: { set = 'printer-description' | 'job-template', name, tag,
--- values, explicit_only (not part of 'all') }.
local function build_catalog(ctx)
    local entries = {}
    local function add(set, name, tag, ...)
        entries[#entries + 1] = { set = set, name = name, tag = tag, values = { ... } }
        return entries[#entries]
    end
    local function add_list(set, name, tag, list)
        entries[#entries + 1] = { set = set, name = name, tag = tag, values = list }
        return entries[#entries]
    end

    local D, J = 'printer-description', 'job-template'
    local uri = 'ipp://' .. ctx.host .. IPP_PATH
    local up_time = os.time() - (ctx.started_at or os.time())
    if up_time < 1 then up_time = 1 end

    add(D, 'charset-configured', T.CHARSET, 'utf-8')
    add(D, 'charset-supported', T.CHARSET, 'utf-8')
    add(D, 'color-supported', T.BOOLEAN, false)
    add(D, 'compression-supported', T.KEYWORD, 'none')
    add(D, 'document-format-default', T.MIME, 'application/pdf')
    add(D, 'document-format-preferred', T.MIME, 'application/pdf')
    add_list(D, 'document-format-supported', T.MIME, DOCUMENT_FORMATS)
    add(D, 'generated-natural-language-supported', T.NATURAL_LANGUAGE, 'en')
    add(D, 'ipp-versions-supported', T.KEYWORD, '1.1', '2.0')
    add(D, 'job-creation-attributes-supported', T.KEYWORD,
        'copies', 'media', 'orientation-requested', 'print-color-mode',
        'print-quality', 'sides')
    add(D, 'media-col-default', T.BEGCOLLECTION, media_col(MEDIA_A4))
    do
        local ready = {}
        for i, media in ipairs(MEDIA) do ready[i] = media_col(media) end
        add_list(D, 'media-col-ready', T.BEGCOLLECTION, ready)
        local database = {}
        for i, media in ipairs(MEDIA) do database[i] = media_col(media) end
        add_list(D, 'media-col-database', T.BEGCOLLECTION, database).explicit_only = true
    end
    add(D, 'multiple-document-jobs-supported', T.BOOLEAN, false)
    add(D, 'natural-language-configured', T.NATURAL_LANGUAGE, 'en')
    add_list(D, 'operations-supported', T.ENUM, supported_operations())
    add(D, 'pdl-override-supported', T.KEYWORD, 'not-attempted')
    add(D, 'printer-current-time', T.DATETIME, IPP.datetime())
    add(D, 'printer-info', T.TEXT, ctx.printer_name)
    add(D, 'printer-is-accepting-jobs', T.BOOLEAN, true)
    add(D, 'printer-location', T.TEXT, '')
    add(D, 'printer-make-and-model', T.TEXT, 'KOReader Kindle PDF Printer')
    add(D, 'printer-more-info', T.URI, 'http://' .. ctx.host .. IPP_PATH)
    add(D, 'printer-name', T.NAME, ctx.printer_name)
    add(D, 'printer-state', T.ENUM, 3) -- idle
    add(D, 'printer-state-reasons', T.KEYWORD, 'none')
    add(D, 'printer-up-time', T.INTEGER, up_time)
    add(D, 'printer-uri-supported', T.URI, uri)
    add(D, 'queued-job-count', T.INTEGER, 0)
    add(D, 'uri-authentication-supported', T.KEYWORD, 'none')
    add(D, 'uri-security-supported', T.KEYWORD, 'none')

    add(J, 'copies-default', T.INTEGER, 1)
    add(J, 'copies-supported', T.RANGE, { lower = 1, upper = 1 })
    add(J, 'finishings-default', T.ENUM, 3) -- none
    add(J, 'finishings-supported', T.ENUM, 3)
    add(J, 'media-default', T.KEYWORD, MEDIA_A4.name)
    add(J, 'media-ready', T.KEYWORD, MEDIA_A4.name, MEDIA_LETTER.name)
    add(J, 'media-supported', T.KEYWORD, MEDIA_A4.name, MEDIA_LETTER.name)
    add(J, 'orientation-requested-default', T.ENUM, 3) -- portrait
    add(J, 'orientation-requested-supported', T.ENUM, 3)
    add(J, 'print-color-mode-default', T.KEYWORD, 'monochrome')
    add(J, 'print-color-mode-supported', T.KEYWORD, 'monochrome')
    add(J, 'print-quality-default', T.ENUM, 4) -- normal
    add(J, 'print-quality-supported', T.ENUM, 4)
    add(J, 'printer-resolution-default', T.RESOLUTION, { x = 300, y = 300, units = 3 })
    add(J, 'printer-resolution-supported', T.RESOLUTION, { x = 300, y = 300, units = 3 })
    add(J, 'sides-default', T.KEYWORD, 'one-sided')
    add(J, 'sides-supported', T.KEYWORD, 'one-sided')

    return entries
end

--- Apply a requested-attributes list to the catalog.
--- `requested` is a list of keywords, or nil meaning 'all'.
--- Returns the selected entries (catalog order) and a list of requested
--- names we do not know.
local function select_attributes(entries, requested)
    local known = {}
    for _, entry in ipairs(entries) do known[entry.name] = true end

    local all, groups, names = false, {}, {}
    local unsupported = {}
    if not requested or #requested == 0 then
        all = true
    else
        local seen = {}
        for _, keyword in ipairs(requested) do
            if keyword == 'all' then
                all = true
            elseif GROUP_KEYWORDS[keyword] then
                groups[keyword] = true
            elseif known[keyword] then
                names[keyword] = true
            elseif not seen[keyword] then
                seen[keyword] = true
                unsupported[#unsupported + 1] = keyword
            end
        end
    end

    local selected = {}
    for _, entry in ipairs(entries) do
        local wanted = names[entry.name]
            or groups[entry.set]
            or (all and not entry.explicit_only)
        if wanted then selected[#selected + 1] = entry end
    end
    return selected, unsupported
end

--- Get-Printer-Attributes (RFC 8011 section 4.2.5).
Ops.handlers[OP.GET_PRINTER_ATTRIBUTES] = function(msg, ctx)
    local entries = build_catalog(ctx)
    local requested = msg:get(G.OPERATION, 'requested-attributes')
    local selected, unsupported = select_attributes(entries, requested and requested.values)

    local status = S.SUCCESSFUL_OK
    if #unsupported > 0 then
        status = S.SUCCESSFUL_OK_IGNORED_OR_SUBSTITUTED_ATTRIBUTES
    end
    local resp = IPP.new_response(msg, status)

    local group = resp:add_group(G.PRINTER)
    for _, entry in ipairs(selected) do
        group.attrs[#group.attrs + 1] = {
            name = entry.name, tag = entry.tag, values = entry.values,
        }
    end

    if #unsupported > 0 then
        local unsupported_group = resp:add_group(G.UNSUPPORTED)
        for _, name in ipairs(unsupported) do
            unsupported_group:add(name, T.UNSUPPORTED)
        end
    end
    return resp
end

local function is_supported_format(format)
    format = format:lower()
    for _, supported in ipairs(DOCUMENT_FORMATS) do
        if supported == format then return true end
    end
    return false
end

--- An error response that also names the offending attribute in the
--- unsupported-attributes group.
local function unsupported_response(msg, status, message, name, tag, value)
    local resp = IPP.new_response(msg, status, message)
    if name then
        resp:add_group(G.UNSUPPORTED):add(name, tag, value)
    end
    return resp
end

--- Check the operation attributes shared by Validate-Job and Print-Job.
--- Returns nil when fine, else status, message, name, tag, value.
local function check_document_attributes(msg)
    local format = msg:first(G.OPERATION, 'document-format')
    if format and not is_supported_format(format) then
        return S.CLIENT_ERROR_DOCUMENT_FORMAT_NOT_SUPPORTED,
            'document format not supported', 'document-format', T.MIME, format
    end
    local compression = msg:first(G.OPERATION, 'compression')
    if compression and compression ~= 'none' then
        return S.CLIENT_ERROR_COMPRESSION_NOT_SUPPORTED,
            'compression not supported', 'compression', T.KEYWORD, compression
    end
    return nil
end

local function text_of(value)
    if type(value) == 'table' then return value.text end
    return value
end

--- Translate a Spool failure into an IPP error response.
local function spool_failure(msg, kind, declared_format)
    if kind == 'not-pdf' then
        if declared_format and declared_format:lower() == 'application/pdf' then
            return IPP.new_response(msg, S.CLIENT_ERROR_DOCUMENT_FORMAT_ERROR,
                'document is not a valid PDF')
        end
        return unsupported_response(msg, S.CLIENT_ERROR_DOCUMENT_FORMAT_NOT_SUPPORTED,
            'only PDF documents are accepted', 'document-format', T.MIME,
            declared_format or 'application/octet-stream')
    elseif kind == 'too-large' then
        return IPP.new_response(msg, S.CLIENT_ERROR_REQUEST_ENTITY_TOO_LARGE,
            'document is too large')
    elseif kind == 'no-space' then
        return IPP.new_response(msg, S.SERVER_ERROR_TEMPORARY_ERROR,
            'not enough free space on the device')
    elseif kind == 'read-failed' then
        return IPP.new_response(msg, S.CLIENT_ERROR_BAD_REQUEST, 'upload interrupted')
    end
    return IPP.new_response(msg, S.SERVER_ERROR_INTERNAL_ERROR, 'could not store the document')
end

--- Validate-Job (RFC 8011 section 4.2.3): check without printing.
Ops.handlers[OP.VALIDATE_JOB] = function(msg)
    local status, message, name, tag, value = check_document_attributes(msg)
    if status then
        return unsupported_response(msg, status, message, name, tag, value)
    end
    return IPP.new_response(msg, S.SUCCESSFUL_OK)
end

--- Print-Job (RFC 8011 section 4.2.1): save the PDF; the job is complete
--- as soon as the file is in place.
Ops.handlers[OP.PRINT_JOB] = function(msg, ctx)
    local status, message, name, tag, value = check_document_attributes(msg)
    if status then
        return unsupported_response(msg, status, message, name, tag, value)
    end
    if not ctx.spool or not ctx.document then
        return IPP.new_response(msg, S.SERVER_ERROR_INTERNAL_ERROR, 'printing is not available')
    end

    local job_name = text_of(msg:first(G.OPERATION, 'job-name'))
    local declared_format = msg:first(G.OPERATION, 'document-format')
    local job, kind = ctx.spool:save(ctx.document, {
        job_name = job_name,
        expected = ctx.document.content_length,
    })
    if not job then
        return spool_failure(msg, kind, declared_format)
    end

    if ctx.on_job then
        pcall(ctx.on_job, { id = job.id, path = job.path, name = job.name,
            bytes = job.bytes, job_name = job_name })
    end

    local resp = IPP.new_response(msg, S.SUCCESSFUL_OK)
    local group = resp:add_group(G.JOB)
    group:add('job-id', T.INTEGER, job.id)
    group:add('job-uri', T.URI, 'ipp://' .. ctx.host .. IPP_PATH .. '/' .. job.id)
    group:add('job-state', T.ENUM, JOB_STATE_COMPLETED)
    group:add('job-state-reasons', T.KEYWORD, 'job-completed-successfully')
    return resp
end

--- Validate a decoded request and run its operation handler. Always
--- returns a response message (errors become IPP status codes).
function Ops.dispatch(msg, ctx)
    local status, message = IPP.validate_request(msg)
    if status then
        return IPP.new_response(msg, status, message)
    end
    local handler = Ops.handlers[msg.code]
    if not handler then
        return IPP.new_response(msg, S.SERVER_ERROR_OPERATION_NOT_SUPPORTED,
            'operation not supported')
    end
    return handler(msg, ctx)
end

return Ops