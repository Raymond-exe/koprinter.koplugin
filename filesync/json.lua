--- Shared JSON encoder/decoder for the FileSync plugin.
--- Provides minimal recursive-descent JSON parsing and table-to-JSON encoding.
--- Used by httpserver.lua and updater.lua.

local JSON = {}

--- Escape special characters in a string for JSON output.
--- @param s string: the raw string to escape
--- @return string: the escaped string (without surrounding quotes)
function JSON.escapeString(s)
    local result = {}
    for i = 1, #s do
        local b = string.byte(s, i)
        if b == 34 then         -- "
            result[#result + 1] = '\\"'
        elseif b == 92 then     -- \
            result[#result + 1] = '\\\\'
        elseif b == 47 then     -- /
            result[#result + 1] = '\\/'
        elseif b == 8 then      -- backspace
            result[#result + 1] = '\\b'
        elseif b == 12 then     -- form feed
            result[#result + 1] = '\\f'
        elseif b == 10 then     -- newline
            result[#result + 1] = '\\n'
        elseif b == 13 then     -- carriage return
            result[#result + 1] = '\\r'
        elseif b == 9 then      -- tab
            result[#result + 1] = '\\t'
        elseif b < 32 then      -- other control chars
            result[#result + 1] = string.format("\\u%04x", b)
        else
            result[#result + 1] = string.char(b)
        end
    end
    return table.concat(result)
end

--- Encode a Lua value as a JSON string.
--- Handles strings, numbers, booleans, nil, and tables (arrays and objects).
--- @param value any: the Lua value to encode
--- @return string: the JSON representation
function JSON.encode(value)
    local t = type(value)
    if t == "nil" then
        return "null"
    elseif t == "boolean" then
        return value and "true" or "false"
    elseif t == "number" then
        -- Guard against nan/inf which are not valid JSON
        if value ~= value then return "0" end -- NaN
        if value == math.huge or value == -math.huge then return "0" end
        return tostring(value)
    elseif t == "string" then
        return '"' .. JSON.escapeString(value) .. '"'
    elseif t == "table" then
        -- Check if it's an array
        if #value > 0 or next(value) == nil then
            local is_array = true
            local max_idx = 0
            for k, _ in pairs(value) do
                if type(k) ~= "number" or k < 1 or k ~= math.floor(k) then
                    is_array = false
                    break
                end
                if k > max_idx then max_idx = k end
            end
            if is_array and max_idx == #value then
                local items = {}
                for i = 1, #value do
                    table.insert(items, JSON.encode(value[i]))
                end
                return "[" .. table.concat(items, ",") .. "]"
            end
        end
        -- Object
        local items = {}
        for k, v in pairs(value) do
            table.insert(items, '"' .. JSON.escapeString(tostring(k)) .. '":' .. JSON.encode(v))
        end
        return "{" .. table.concat(items, ",") .. "}"
    end
    return "null"
end

--- Decode a JSON string into a Lua value.
--- Uses a simple recursive descent parser.
--- @param str string: the JSON string to parse
--- @return any: the decoded Lua value, or nil on parse error
function JSON.decode(str)
    if not str or str == "" then return nil end
    local pos = 1

    local function skip_whitespace()
        while pos <= #str and str:sub(pos, pos):match("%s") do
            pos = pos + 1
        end
    end

    local parse_value -- forward declaration

    local function parse_string()
        if str:sub(pos, pos) ~= '"' then return nil end
        pos = pos + 1
        local result = {}
        while pos <= #str do
            local c = str:sub(pos, pos)
            if c == '"' then
                pos = pos + 1
                return table.concat(result)
            elseif c == '\\' then
                pos = pos + 1
                local esc = str:sub(pos, pos)
                if esc == '"' or esc == '\\' or esc == '/' then
                    table.insert(result, esc)
                elseif esc == 'n' then table.insert(result, '\n')
                elseif esc == 'r' then table.insert(result, '\r')
                elseif esc == 't' then table.insert(result, '\t')
                elseif esc == 'b' then table.insert(result, '\b')
                elseif esc == 'f' then table.insert(result, '\f')
                elseif esc == 'u' then
                    local hex = str:sub(pos + 1, pos + 4)
                    local code = tonumber(hex, 16)
                    if code then
                        if code < 128 then
                            table.insert(result, string.char(code))
                        end
                    end
                    pos = pos + 4
                end
                pos = pos + 1
            else
                table.insert(result, c)
                pos = pos + 1
            end
        end
        return nil
    end

    local function parse_number()
        local start = pos
        if str:sub(pos, pos) == '-' then pos = pos + 1 end
        while pos <= #str and str:sub(pos, pos):match("%d") do pos = pos + 1 end
        if pos <= #str and str:sub(pos, pos) == '.' then
            pos = pos + 1
            while pos <= #str and str:sub(pos, pos):match("%d") do pos = pos + 1 end
        end
        if pos <= #str and str:sub(pos, pos):lower() == 'e' then
            pos = pos + 1
            if pos <= #str and (str:sub(pos, pos) == '+' or str:sub(pos, pos) == '-') then
                pos = pos + 1
            end
            while pos <= #str and str:sub(pos, pos):match("%d") do pos = pos + 1 end
        end
        return tonumber(str:sub(start, pos - 1))
    end

    local function parse_object()
        pos = pos + 1 -- skip '{'
        skip_whitespace()
        local obj = {}
        if str:sub(pos, pos) == '}' then
            pos = pos + 1
            return obj
        end
        while true do
            skip_whitespace()
            local key = parse_string()
            if not key then return nil end
            skip_whitespace()
            if str:sub(pos, pos) ~= ':' then return nil end
            pos = pos + 1
            skip_whitespace()
            local val = parse_value()
            obj[key] = val
            skip_whitespace()
            if str:sub(pos, pos) == '}' then
                pos = pos + 1
                return obj
            end
            if str:sub(pos, pos) ~= ',' then return nil end
            pos = pos + 1
        end
    end

    local function parse_array()
        pos = pos + 1 -- skip '['
        skip_whitespace()
        local arr = {}
        if str:sub(pos, pos) == ']' then
            pos = pos + 1
            return arr
        end
        while true do
            skip_whitespace()
            local val = parse_value()
            table.insert(arr, val)
            skip_whitespace()
            if str:sub(pos, pos) == ']' then
                pos = pos + 1
                return arr
            end
            if str:sub(pos, pos) ~= ',' then return nil end
            pos = pos + 1
        end
    end

    parse_value = function()
        skip_whitespace()
        local c = str:sub(pos, pos)
        if c == '"' then return parse_string()
        elseif c == '{' then return parse_object()
        elseif c == '[' then return parse_array()
        elseif c == 't' then
            if str:sub(pos, pos + 3) == "true" then
                pos = pos + 4
                return true
            end
        elseif c == 'f' then
            if str:sub(pos, pos + 4) == "false" then
                pos = pos + 5
                return false
            end
        elseif c == 'n' then
            if str:sub(pos, pos + 3) == "null" then
                pos = pos + 4
                return nil
            end
        elseif c == '-' or c:match("%d") then
            return parse_number()
        end
        return nil
    end

    local ok, result = pcall(parse_value)
    if ok then return result end
    return nil
end

return JSON
