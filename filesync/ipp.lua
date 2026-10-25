--- Pure-Lua IPP message encoder+decoder

local IPP = {}

local MAX_COLLECTION_DEPTH = 8
local DEFAULT_MAX_ATTRIBUTES = 1000

-- Delimiter (group) tags.
IPP.GROUP = {
    OPERATION = 0x01,
    JOB = 0x02,
    END = 0x03,
    PRINTER = 0x04,
    UNSUPPORTED = 0x05,
    SUBSCRIPTION = 0x06,
    EVENT_NOTIFICATION = 0x07,
    RESOURCE = 0x08,
    DOCUMENT = 0x09,
    SYSTEM = 0x0A,
}

-- Value tags.
IPP.TAG = {
    UNSUPPORTED = 0x10,
    UNKNOWN = 0x12,
    NOVALUE = 0x13,
    INTEGER = 0x21,
    BOOLEAN = 0x22,
    ENUM = 0x23,
    OCTETSTRING = 0x30,
    DATETIME = 0x31,
    RESOLUTION = 0x32,
    RANGE = 0x33,
    BEGCOLLECTION = 0x34,
    TEXTLANG = 0x35,
    NAMELANG = 0x36,
    ENDCOLLECTION = 0x37,
    TEXT = 0x41,
    NAME = 0x42,
    KEYWORD = 0x44,
    URI = 0x45,
    URISCHEME = 0x46,
    CHARSET = 0x47,
    NATURAL_LANGUAGE = 0x48,
    MIME = 0x49,
    MEMBERNAME = 0x4A,
}

IPP.OP = {
    PRINT_JOB = 0x0002,
    PRINT_URI = 0x0003,
    VALIDATE_JOB = 0x0004,
    CREATE_JOB = 0x0005,
    SEND_DOCUMENT = 0x0006,
    SEND_URI = 0x0007,
    CANCEL_JOB = 0x0008,
    GET_JOB_ATTRIBUTES = 0x0009,
    GET_JOBS = 0x000A,
    GET_PRINTER_ATTRIBUTES = 0x000B,
    HOLD_JOB = 0x000C,
    RELEASE_JOB = 0x000D,
    RESTART_JOB = 0x000E,
    PAUSE_PRINTER = 0x0010,
    RESUME_PRINTER = 0x0011,
    PURGE_JOBS = 0x0012,
    CANCEL_MY_JOBS = 0x0039,
    CLOSE_JOB = 0x003B,
    IDENTIFY_PRINTER = 0x003C,
}

IPP.STATUS = {
    SUCCESSFUL_OK = 0x0000,
    SUCCESSFUL_OK_IGNORED_OR_SUBSTITUTED_ATTRIBUTES = 0x0001,
    SUCCESSFUL_OK_CONFLICTING_ATTRIBUTES = 0x0002,
    CLIENT_ERROR_BAD_REQUEST = 0x0400,
    CLIENT_ERROR_FORBIDDEN = 0x0401,
    CLIENT_ERROR_NOT_AUTHENTICATED = 0x0402,
    CLIENT_ERROR_NOT_AUTHORIZED = 0x0403,
    CLIENT_ERROR_NOT_POSSIBLE = 0x0404,
    CLIENT_ERROR_TIMEOUT = 0x0405,
    CLIENT_ERROR_NOT_FOUND = 0x0406,
    CLIENT_ERROR_GONE = 0x0407,
    CLIENT_ERROR_REQUEST_ENTITY_TOO_LARGE = 0x0408,
    CLIENT_ERROR_REQUEST_VALUE_TOO_LONG = 0x0409,
    CLIENT_ERROR_DOCUMENT_FORMAT_NOT_SUPPORTED = 0x040A,
    CLIENT_ERROR_ATTRIBUTES_OR_VALUES_NOT_SUPPORTED = 0x040B,
    CLIENT_ERROR_URI_SCHEME_NOT_SUPPORTED = 0x040C,
    CLIENT_ERROR_CHARSET_NOT_SUPPORTED = 0x040D,
    CLIENT_ERROR_CONFLICTING_ATTRIBUTES = 0x040E,
    CLIENT_ERROR_COMPRESSION_NOT_SUPPORTED = 0x040F,
    CLIENT_ERROR_COMPRESSION_ERROR = 0x0410,
    CLIENT_ERROR_DOCUMENT_FORMAT_ERROR = 0x0411,
    CLIENT_ERROR_DOCUMENT_ACCESS_ERROR = 0x0412,
    SERVER_ERROR_INTERNAL_ERROR = 0x0500,
    SERVER_ERROR_OPERATION_NOT_SUPPORTED = 0x0501,
    SERVER_ERROR_SERVICE_UNAVAILABLE = 0x0502,
    SERVER_ERROR_VERSION_NOT_SUPPORTED = 0x0503,
    SERVER_ERROR_DEVICE_ERROR = 0x0504,
    SERVER_ERROR_TEMPORARY_ERROR = 0x0505,
    SERVER_ERROR_NOT_ACCEPTING_JOBS = 0x0506,
    SERVER_ERROR_BUSY = 0x0507,
    SERVER_ERROR_JOB_CANCELED = 0x0508,
}

local SUPPORTED_VERSIONS = {
    ['1.0'] = true, ['1.1'] = true,
    ['2.0'] = true, ['2.1'] = true, ['2.2'] = true,
}

-- Reverse lookups for logging.
local STATUS_NAMES = {}
local OP_NAMES = {}
for key, code in pairs(IPP.OP) do
    -- PRINT_JOB -> Print-Job
    local name = key:lower():gsub('_', '-'):gsub('(%a)(%w*)', function(a, b)
        return a:upper() .. b
    end)
    OP_NAMES[code] = name
end
for key, code in pairs(IPP.STATUS) do
    -- SUCCESSFUL_OK -> successful-ok
    STATUS_NAMES[code] = key:lower():gsub('_', '-')
end

function IPP.op_name(code)
    return OP_NAMES[code] or string.format('0x%04x', code)
end

function IPP.status_name(code)
    return STATUS_NAMES[code] or string.format('0x%04x', code)
end



----------------------------------------------------------------------
-- Message / Group objects
----------------------------------------------------------------------

local Group = {}
Group.__index = Group

--- Append an attribute. Extra arguments are additional values of the same
--- attribute (a 1setOf), all sharing `tag`.
function Group:add(name, tag, ...)
    local attr = { name = name, tag = tag, values = { ... } }
    self.attrs[#self.attrs + 1] = attr
    return attr
end

local Message = {}
Message.__index = Message

function Message:add_group(tag)
    local group = setmetatable({ tag = tag, attrs = {} }, Group)
    self.groups[#self.groups + 1] = group
    return group
end

--- First attribute called `name` in the first group with `group_tag`.
function Message:get(group_tag, name)
    for _, group in ipairs(self.groups) do
        if group.tag == group_tag then
            for _, attr in ipairs(group.attrs) do
                if attr.name == name then return attr end
            end
        end
    end
    return nil
end

--- First value of that attribute, or nil.
function Message:first(group_tag, name)
    local attr = self:get(group_tag, name)
    if attr then return attr.values[1] end
    return nil
end

function IPP.new_message(fields)
    fields = fields or {}
    return setmetatable({
        version = fields.version or { 1, 1 },
        code = fields.code or 0,
        request_id = fields.request_id or 0,
        groups = {},
    }, Message)
end

--- Collection helpers for encoding.
--- member('media-size', TAG.INTEGER, 21000) -> a member with its values.
function IPP.member(name, tag, ...)
    return { name = name, tag = tag, values = { ... } }
end

--- collection(member, member, ...) -> a collection value.
function IPP.collection(...)
    return { members = { ... } }
end

--- Build an 11-byte IPP dateTime (UTC) from an epoch time.
function IPP.datetime(epoch)
    local t = os.date('!*t', epoch or os.time())
    local year = t.year
    return string.char(math.floor(year / 256) % 256, year % 256,
        t.month, t.day, t.hour, t.min, t.sec, 0)
        .. '+' .. string.char(0, 0)
end



----------------------------------------------------------------------
-- Decoding
----------------------------------------------------------------------

local T = IPP.TAG

local function truncated()
    error({ kind = 'truncated' }, 0)
end

local function malformed(reason)
    error({ kind = 'malformed', reason = reason }, 0)
end

local function read_u8(r)
    local b = r.data:byte(r.pos)
    if not b then truncated() end
    r.pos = r.pos + 1
    return b
end

local function read_u16(r)
    local a, b = r.data:byte(r.pos, r.pos + 1)
    if not b then truncated() end
    r.pos = r.pos + 2
    return a * 256 + b
end

local function read_u32(r)
    local a, b, c, d = r.data:byte(r.pos, r.pos + 3)
    if not d then truncated() end
    r.pos = r.pos + 4
    return ((a * 256 + b) * 256 + c) * 256 + d
end

local function read_bytes(r, n)
    local s = r.data:sub(r.pos, r.pos + n - 1)
    if #s < n then truncated() end
    r.pos = r.pos + n
    return s
end

--- Signed 32-bit integer from 4 bytes of `s` starting at `i`.
local function str_to_i32(s, i)
    local a, b, c, d = s:byte(i, i + 3)
    local n = ((a * 256 + b) * 256 + c) * 256 + d
    if n >= 2147483648 then n = n - 4294967296 end
    return n
end

--- Text/name with language: u16 lang length, lang, u16 text length, text.
local function decode_with_language(raw)
    local lang_len = (raw:byte(1) or 0) * 256 + (raw:byte(2) or 0)
    if #raw < 4 + lang_len then malformed('text with language too short') end
    local lang = raw:sub(3, 2 + lang_len)
    local text_len = (raw:byte(3 + lang_len) or 0) * 256 + (raw:byte(4 + lang_len) or 0)
    if #raw < 4 + lang_len + text_len then malformed('text with language too short') end
    return { lang = lang, text = raw:sub(5 + lang_len, 4 + lang_len + text_len) }
end

local function decode_value(tag, raw)
    if tag == T.INTEGER or tag == T.ENUM then
        if #raw ~= 4 then malformed('integer must be 4 bytes') end
        return str_to_i32(raw, 1)
    elseif tag == T.BOOLEAN then
        if #raw ~= 1 then malformed('boolean must be 1 byte') end
        return raw ~= '\0'
    elseif tag == T.RESOLUTION then
        if #raw ~= 9 then malformed('resolution must be 9 bytes') end
        return { x = str_to_i32(raw, 1), y = str_to_i32(raw, 5), units = raw:byte(9) }
    elseif tag == T.RANGE then
        if #raw ~= 8 then malformed('range must be 8 bytes') end
        return { lower = str_to_i32(raw, 1), upper = str_to_i32(raw, 5) }
    elseif tag == T.TEXTLANG or tag == T.NAMELANG then
        return decode_with_language(raw)
    end
    -- Strings, keywords, URIs, dateTime, octetString, out-of-band: raw bytes.
    return raw
end

local parse_collection

--- Read one value record's tag-specific payload; collections recurse.
local function read_value(r, tag, raw, depth)
    if tag == T.BEGCOLLECTION then
        return parse_collection(r, depth + 1)
    end
    return decode_value(tag, raw)
end

--- Parse collection members after a begCollection record, up to its
--- endCollection record (RFC 3382).
function parse_collection(r, depth)
    if depth > MAX_COLLECTION_DEPTH then malformed('collections nested too deeply') end
    local members = {}
    local member
    while true do
        local tag = read_u8(r)
        local name_len = read_u16(r)
        read_bytes(r, name_len) -- member records carry an empty name
        local raw = read_bytes(r, read_u16(r))
        if tag == T.ENDCOLLECTION then
            return { members = members }
        elseif tag == T.MEMBERNAME then
            member = { name = raw, tags = {}, values = {} }
            members[#members + 1] = member
        else
            if not member then malformed('collection value before member name') end
            member.tags[#member.tags + 1] = tag
            member.values[#member.values + 1] = read_value(r, tag, raw, depth)
        end
    end
end

local function parse_message(data, max_attributes)
    local r = { data = data, pos = 1 }
    local major = read_u8(r)
    local minor = read_u8(r)
    local code = read_u16(r)
    local request_id = read_u32(r)

    local msg = IPP.new_message({
        version = { major, minor }, code = code, request_id = request_id,
    })

    local group, attr
    local count = 0
    while true do
        local tag = read_u8(r)
        if tag == IPP.GROUP.END then
            return msg, r.pos
        elseif tag < 0x10 then
            group = msg:add_group(tag)
            attr = nil
        else
            if not group then malformed('attribute outside a group') end
            local name_len = read_u16(r)
            local name = read_bytes(r, name_len)
            local raw = read_bytes(r, read_u16(r))
            local value = read_value(r, tag, raw, 0)
            if name_len == 0 then
                if not attr then malformed('additional value without an attribute') end
            else
                count = count + 1
                if count > max_attributes then malformed('too many attributes') end
                attr = { name = name, tags = {}, values = {} }
                group.attrs[#group.attrs + 1] = attr
            end
            attr.tags[#attr.tags + 1] = tag
            attr.values[#attr.values + 1] = value
        end
    end
end

--- Decode an IPP message from the start of `data`.
--- Returns msg, next_pos on success; nil, 'truncated' when more bytes are
--- needed; nil, 'malformed: <reason>' when the data can never be valid.
--- opts.max_attributes caps the attribute count (default 1000).
function IPP.decode(data, opts)
    local max_attributes = (opts and opts.max_attributes) or DEFAULT_MAX_ATTRIBUTES
    local ok, msg, next_pos = pcall(parse_message, data, max_attributes)
    if ok then return msg, next_pos end
    local err = msg
    if type(err) == 'table' then
        if err.kind == 'truncated' then return nil, 'truncated' end
        return nil, 'malformed: ' .. tostring(err.reason)
    end
    return nil, 'malformed: internal error: ' .. tostring(err)
end



----------------------------------------------------------------------
-- Encoding
----------------------------------------------------------------------

local function pack_u16(n)
    return string.char(math.floor(n / 256) % 256, n % 256)
end

--- 4 bytes, big-endian; accepts -2^31 .. 2^32-1.
local function pack_u32(n)
    if type(n) ~= 'number' then error('IPP encode: expected a number, got ' .. type(n), 0) end
    n = math.floor(n)
    if n < -2147483648 or n > 4294967295 then error('IPP encode: integer out of range', 0) end
    if n < 0 then n = n + 4294967296 end
    return string.char(math.floor(n / 16777216) % 256, math.floor(n / 65536) % 256,
        math.floor(n / 256) % 256, n % 256)
end

local function encode_value(tag, v)
    if tag == T.INTEGER or tag == T.ENUM then
        return pack_u32(v)
    elseif tag == T.BOOLEAN then
        return v and '\1' or '\0'
    elseif tag == T.RESOLUTION then
        return pack_u32(v.x or v[1]) .. pack_u32(v.y or v[2])
            .. string.char(v.units or v[3] or 3)
    elseif tag == T.RANGE then
        return pack_u32(v.lower or v[1]) .. pack_u32(v.upper or v[2])
    elseif tag == T.TEXTLANG or tag == T.NAMELANG then
        local lang = v.lang or v[1]
        local text = v.text or v[2]
        return pack_u16(#lang) .. lang .. pack_u16(#text) .. text
    elseif tag == T.UNSUPPORTED or tag == T.UNKNOWN or tag == T.NOVALUE then
        return ''
    end
    if type(v) ~= 'string' then
        error('IPP encode: expected a string value for tag ' .. tag, 0)
    end
    return v
end

local function put_record(parts, tag, name, raw)
    if #name > 65535 or #raw > 65535 then error('IPP encode: field too long', 0) end
    parts[#parts + 1] = string.char(tag) .. pack_u16(#name) .. name .. pack_u16(#raw) .. raw
end

--- Emit one attribute (or collection member): `name` goes on the first
--- value only. `tags` is a per-value tag list (decoded attrs) or nil, in
--- which case every value uses `default_tag`.
local function put_values(parts, name, tags, values, default_tag)
    local n = #values
    if n == 0 then
        -- No values: emit an out-of-band record.
        local oob = (default_tag == T.UNSUPPORTED or default_tag == T.UNKNOWN) and default_tag
            or T.NOVALUE
        put_record(parts, oob, name, '')
        return
    end
    for i = 1, n do
        local tag = (tags and tags[i]) or default_tag
        local record_name = (i == 1) and name or ''
        local v = values[i]
        if tag == T.BEGCOLLECTION then
            put_record(parts, tag, record_name, '')
            for _, member in ipairs(v.members) do
                put_record(parts, T.MEMBERNAME, '', member.name)
                put_values(parts, '', member.tags, member.values, member.tag)
            end
            put_record(parts, T.ENDCOLLECTION, '', '')
        else
            put_record(parts, tag, record_name, encode_value(tag, v))
        end
    end
end

--- Serialize a message built with IPP.new_message / IPP.new_response (or one
--- returned by IPP.decode) to its wire format.
function IPP.encode(msg)
    local version = msg.version or { 1, 1 }
    local parts = {
        string.char(version[1], version[2]) .. pack_u16(msg.code)
            .. pack_u32(msg.request_id or 0),
    }
    for _, group in ipairs(msg.groups) do
        parts[#parts + 1] = string.char(group.tag)
        for _, attr in ipairs(group.attrs) do
            put_values(parts, attr.name, attr.tags, attr.values, attr.tag)
        end
    end
    parts[#parts + 1] = string.char(IPP.GROUP.END)
    return table.concat(parts)
end

--- Start a response to `request`: copies the request id, uses the request's
--- version when supported (else 1.1), and opens the operation-attributes
--- group with the two mandatory first attributes. `status_message` is
--- optional human-readable text.
function IPP.new_response(request, status_code, status_message)
    local version = request and request.version or { 1, 1 }
    if not SUPPORTED_VERSIONS[version[1] .. '.' .. version[2]] then
        version = { 1, 1 }
    end
    local resp = IPP.new_message({
        version = { version[1], version[2] },
        code = status_code,
        request_id = request and request.request_id or 0,
    })
    local group = resp:add_group(IPP.GROUP.OPERATION)
    group:add('attributes-charset', T.CHARSET, 'utf-8')
    group:add('attributes-natural-language', T.NATURAL_LANGUAGE, 'en')
    if status_message then
        group:add('status-message', T.TEXT, status_message)
    end
    return resp
end



----------------------------------------------------------------------
-- Request validation
----------------------------------------------------------------------

--- Check the parts every request must satisfy (RFC 8011 section 4.1.4):
--- a supported version and an operation-attributes group that starts with
--- attributes-charset then attributes-natural-language, in utf-8 or us-ascii.
--- Returns nil when the request is acceptable, else a status code and a
--- short message to put in the response. A zero request id is tolerated.
function IPP.validate_request(msg)
    local S = IPP.STATUS
    if not SUPPORTED_VERSIONS[msg.version[1] .. '.' .. msg.version[2]] then
        return S.SERVER_ERROR_VERSION_NOT_SUPPORTED, 'IPP version not supported'
    end
    local group = msg.groups[1]
    if not group or group.tag ~= IPP.GROUP.OPERATION then
        return S.CLIENT_ERROR_BAD_REQUEST, 'missing operation attributes'
    end
    local charset, language = group.attrs[1], group.attrs[2]
    if not charset or charset.name ~= 'attributes-charset'
        or not language or language.name ~= 'attributes-natural-language' then
        return S.CLIENT_ERROR_BAD_REQUEST,
            'attributes-charset and attributes-natural-language must come first'
    end
    local cs = (charset.values[1] or ''):lower()
    if cs ~= 'utf-8' and cs ~= 'us-ascii' then
        return S.CLIENT_ERROR_CHARSET_NOT_SUPPORTED, 'charset not supported'
    end
    return nil
end

IPP.Message = Message
IPP.Group = Group

return IPP