--- Spool: turns an incoming document stream into a PDF file, saved to documents folder.
--- 
--- Fail conditions: 'not-pdf', 'too-large', 'no-space', 'read-failed', 'write-failed'.

local Spool = {}
Spool.__index = Spool

local DEFAULT_DIR = '/mnt/us/documents'
local DEFAULT_MAX_SIZE = 50 * 1024 * 1024
local DEFAULT_MIN_FREE = 5 * 1024 * 1024
local HEAD_SIZE = 1024 -- PDF readers accept the header anywhere in the first KB
local MAX_NAME_LENGTH = 40

local function shell_quote(s)
    return "'" .. s:gsub("'", "'\\''") .. "'"
end

local function file_exists(path)
    local f = io.open(path, 'rb')
    if f then
        f:close()
        return true
    end
    return false
end

--- True when `dir` exists and we can create files in it.
local function dir_writable(dir)
    local probe = dir .. '/.printserver-probe'
    local f = io.open(probe, 'wb')
    if not f then return false end
    f:close()
    os.remove(probe)
    return true
end

local function ensure_dir(dir)
    if dir_writable(dir) then return true end
    os.execute('mkdir -p ' .. shell_quote(dir))
    return dir_writable(dir)
end

--- Sibling of the documents folder, so the temp file shares its filesystem and the final rename is atomic.
local function default_tmp_dir(dir)
    local parent = dir:match('^(.*)/[^/]+/*$')
    if parent and parent ~= '' then
        return parent .. '/.printserver-tmp'
    end
    return dir .. '/.printserver-tmp'
end

--- Returns free bytes on the filesystem holding `dir`, or nil when unknown.
local function default_free_space(dir)
    local ok, util = pcall(require, 'util')
    if ok and type(util) == 'table' and util.diskUsage then
        local ok_usage, usage = pcall(util.diskUsage, dir)
        if ok_usage and type(usage) == 'table' and type(usage.available) == 'number' then
            return usage.available
        end
    end
    return nil
end

--- Make a job name safe for a FAT filesystem
function Spool.sanitize(name)
    name = tostring(name or '')
    name = name:gsub('%.[pP][dD][fF]$', '')
    name = name:gsub('[^%w%._%-]', '_')
    name = name:gsub('_+', '_')
    name = name:gsub('^[%._%-]+', '')
    name = name:gsub('[%._%-]+$', '')
    return name:sub(1, MAX_NAME_LENGTH)
end

--- config: dir, tmp_dir, max_size, min_free (0 disables the space margin),
--- use_job_name (name files after the print job), free_space(dir) -> bytes
--- or nil, clock() -> epoch seconds (all optional).
function Spool.new(config)
    config = config or {}
    local self = setmetatable({}, Spool)
    self.dir = (config.dir or DEFAULT_DIR):gsub('/+$', '')
    self.tmp_dir = config.tmp_dir or default_tmp_dir(self.dir)
    self.max_size = config.max_size or DEFAULT_MAX_SIZE
    self.min_free = config.min_free or DEFAULT_MIN_FREE
    self.use_job_name = config.use_job_name or false
    self.free_space = config.free_space or default_free_space
    self.clock = config.clock or os.time
    self.last_job_id = 0
    return self
end

--- Delete leftover temp files from an interrupted run.
function Spool:cleanup()
    local ok = pcall(function()
        local p = io.popen('ls -1A ' .. shell_quote(self.tmp_dir) .. ' 2>/dev/null')
        if not p then return end
        for name in p:lines() do
            if name:match('%.part$') then
                os.remove(self.tmp_dir .. '/' .. name)
            end
        end
        p:close()
    end)
    return ok
end

function Spool:_file_name(job_name, job_id)
    local stamp = self.clock()
    local base
    local clean = self.use_job_name and job_name and Spool.sanitize(job_name) or ''
    if clean ~= '' then
        base = string.format('%s-%d-%d', clean, stamp, job_id)
    else
        base = string.format('print-%d-%d', stamp, job_id)
    end
    local name = base .. '.pdf'
    local n = 1
    while file_exists(self.dir .. '/' .. name) do
        n = n + 1
        name = string.format('%s-%d.pdf', base, n)
    end
    return name
end

--- Save one document. `document` = { initial, next_chunk }.
--- opts: job_name (string), expected (declared size in bytes, if known).
--- Returns { id, path, name, bytes } or nil, kind, detail.
function Spool:save(document, opts)
    opts = opts or {}

    if not (ensure_dir(self.dir) and ensure_dir(self.tmp_dir)) then
        return nil, 'write-failed', 'cannot create spool folders'
    end

    local expected = opts.expected or 0
    if expected > self.max_size then
        return nil, 'too-large', 'declared size exceeds the limit'
    end
    local free = self.free_space(self.dir)
    if free and free < expected + self.min_free then
        return nil, 'no-space', 'not enough free space'
    end

    local next_chunk = document.next_chunk or function() return nil end
    local head = document.initial or ''
    local ended = false

    -- Read until we can judge the header (or the body ends).
    while #head < HEAD_SIZE and not ended do
        local chunk, err = next_chunk()
        if chunk then
            head = head .. chunk
        elseif err then
            return nil, err == 'body too large' and 'too-large' or 'read-failed', err
        else
            ended = true
        end
    end
    if not head:sub(1, HEAD_SIZE):find('%PDF-', 1, true) then
        return nil, 'not-pdf', 'missing %PDF- header'
    end

    self.last_job_id = self.last_job_id + 1
    local job_id = self.last_job_id
    local name = self:_file_name(opts.job_name, job_id)
    local tmp_path = self.tmp_dir .. '/' .. name .. '.part'
    local final_path = self.dir .. '/' .. name

    local file, open_err = io.open(tmp_path, 'wb')
    if not file then
        return nil, 'write-failed', tostring(open_err)
    end

    local total = 0
    local function fail(kind, detail)
        file:close()
        os.remove(tmp_path)
        return nil, kind, detail
    end
    local function write(data)
        total = total + #data
        if total > self.max_size then return 'too-large', 'document exceeds the limit' end
        local wrote, write_err = file:write(data)
        if not wrote then return 'write-failed', tostring(write_err) end
        return nil
    end

    local kind, detail = write(head)
    if kind then return fail(kind, detail) end

    while not ended do
        local chunk, err = next_chunk()
        if chunk then
            kind, detail = write(chunk)
            if kind then return fail(kind, detail) end
        elseif err then
            return fail(err == 'body too large' and 'too-large' or 'read-failed', err)
        else
            ended = true
        end
    end

    local flushed, flush_err = file:flush()
    if not flushed then return fail('write-failed', tostring(flush_err)) end
    local closed, close_err = file:close()
    if not closed then
        os.remove(tmp_path)
        return nil, 'write-failed', tostring(close_err)
    end

    local renamed, rename_err = os.rename(tmp_path, final_path)
    if not renamed then
        os.remove(tmp_path)
        return nil, 'write-failed', tostring(rename_err)
    end

    return { id = job_id, path = final_path, name = name, bytes = total }
end

return Spool
