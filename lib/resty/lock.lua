-- Copyright (C) Yichun Zhang (agentzh)


local shdict = require "resty.core.shdict"  -- enforce this to avoid dead locks

local ffi = require "ffi"
local ffi_new = ffi.new
local shared = ngx.shared
local sleep = ngx.sleep
local log = ngx.log
local max = math.max
local min = math.min
local debug = ngx.config.debug
local setmetatable = setmetatable
local tonumber = tonumber
local worker_pid = ngx.worker.pid
local now = ngx.now
local owner_sequence = 0

local _M = { _VERSION = '0.09' }
local mt = { __index = _M }

local ERR = ngx.ERR
local FREE_LIST_REF = 0

-- FIXME: we don't need this when we have __gc metamethod support on Lua
--        tables.
local memo = {}
if debug then _M.memo = memo end


local function ref_obj(key)
    if key == nil then
        return -1
    end
    local ref = memo[FREE_LIST_REF]
    if ref and ref ~= 0 then
         memo[FREE_LIST_REF] = memo[ref]

    else
        ref = #memo + 1
    end
    memo[ref] = key

    -- print("ref key_id returned ", ref)
    return ref
end
if debug then _M.ref_obj = ref_obj end


local function unref_obj(ref)
    if ref >= 0 then
        memo[ref] = memo[FREE_LIST_REF]
        memo[FREE_LIST_REF] = ref
    end
end
if debug then _M.unref_obj = unref_obj end


local function gc_lock(cdata)
    local dict_id = tonumber(cdata.dict_id)
    local key_id = tonumber(cdata.key_id)

    -- print("key_id: ", key_id, ", key: ", memo[key_id], "dict: ",
    --       type(memo[cdata.dict_id]))
    if key_id > 0 then
        local ownership = memo[key_id]
        local key = ownership.key
        unref_obj(key_id)
        local dict = memo[dict_id]
        -- print("dict.delete type: ", type(dict.delete))
        local ok, err = dict:compare_expire(key, ownership.token)
        if not ok and err ~= "lock ownership lost" then
            log(ERR, 'failed to delete key "', key, '": ', err)
        end
        cdata.key_id = 0
    end

    unref_obj(dict_id)
end


local ctype = ffi.metatype("struct { int key_id; int dict_id; }",
                           { __gc = gc_lock })


function _M.new(_, dict_name, opts)
    local dict = shared[dict_name]
    if not dict then
        return nil, "dictionary not found"
    end
    if not shdict.has_atomic_ownership or not dict.compare_expire then
        return nil, "atomic ownership operations require an updated lua-resty-core and nginx"
    end

    local cdata = ffi_new(ctype)
    cdata.key_id = 0
    cdata.dict_id = ref_obj(dict)

    local timeout, exptime, step, ratio, max_step
    if opts then
        timeout = opts.timeout
        exptime = opts.exptime
        step = opts.step
        ratio = opts.ratio
        max_step = opts.max_step
    end

    if not exptime then
        exptime = 30
    end

    if timeout then
        timeout = min(timeout, exptime)

        if step then
            step = min(step, timeout)
        end
    end

    local self = {
        cdata = cdata,
        dict = dict,
        timeout = timeout or 5,
        exptime = exptime,
        step = step or 0.001,
        ratio = ratio or 2,
        max_step = max_step or 0.5,
    }
    setmetatable(self, mt)
    return self
end


function _M.lock(self, key)
    if not key then
        return nil, "nil key"
    end

    local dict = self.dict
    local cdata = self.cdata
    if cdata.key_id > 0 then
        return nil, "locked"
    end
    local exptime = self.exptime
    owner_sequence = owner_sequence + 1
    local token = worker_pid() .. ":" .. now() .. ":" .. owner_sequence
    local ok, err = dict:add(key, token, exptime)
    if ok then
        cdata.key_id = ref_obj({ key = key, token = token })
        self.key = key
        return 0
    end
    if err ~= "exists" then
        return nil, err
    end
    -- lock held by others
    local step = self.step
    local ratio = self.ratio
    local timeout = self.timeout
    local max_step = self.max_step
    local elapsed = 0
    while timeout > 0 do
        sleep(step)
        elapsed = elapsed + step
        timeout = timeout - step

        local ok, err = dict:add(key, token, exptime)
        if ok then
            cdata.key_id = ref_obj({ key = key, token = token })
            self.key = key
            return elapsed
        end

        if err ~= "exists" then
            return nil, err
        end

        if timeout <= 0 then
            break
        end

        step = min(max(0.001, step * ratio), timeout, max_step)
    end

    return nil, "timeout"
end


function _M.unlock(self)
    local dict = self.dict
    local cdata = self.cdata
    local key_id = tonumber(cdata.key_id)
    if key_id <= 0 then
        return nil, "unlocked"
    end

    local ownership = memo[key_id]
    local key = ownership.key
    unref_obj(key_id)
    cdata.key_id = 0

    local ok, err = dict:compare_expire(key, ownership.token)
    if not ok then
        return nil, err
    end
    cdata.key_id = 0

    return 1
end


function _M.expire(self, time)
    local dict = self.dict
    local cdata = self.cdata
    local key_id = tonumber(cdata.key_id)
    if key_id <= 0 then
        return nil, "unlocked"
    end

    if not time then
        time = self.exptime
    end

    local ownership = memo[key_id]
    local ok, err = dict:compare_expire(self.key, ownership.token, time)
    if not ok then
        return nil, err
    end

    return true
end


return _M
