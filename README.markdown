Name
====

lua-resty-lock - Simple shm-based nonblocking lock API

Status
======

This library is still under early development and is still experimental.

Synopsis
========

    # nginx.conf

    http {
        lua_package_path "/path/to/lua-resty-lock/lib/?.lua;;";

        lua_shared_dict my_locks 100k;

        server {
            ...

            location = /t {
                content_by_lua '
                    local lock = require "resty.lock"
                    for i = 1, 2 do
                        local lock = lock:new("my_locks")

                        local elapsed, err = lock:lock("my_key")
                        ngx.say("lock: ", elapsed, ", ", err)

                        local ok, err = lock:unlock()
                        if not ok then
                            ngx.say("failed to unlock: ", err)
                        end
                        ngx.say("unlock: ", ok)
                    end
                ';
            }
        }
    }

Description
===========

This library implements a simple mutex lock in a similar way to ngx_proxy module's [proxy_cache_lock directive](http://nginx.org/en/docs/http/ngx_http_proxy_module.html#proxy_cache_lock).

Under the hood, this library uses [ngx_lua](http://wiki.nginx.org/HttpLuaModule) module's shared memory dictionaries. The lock waiting is nonblocking because we use stepwise [ngx.sleep](http://wiki.nginx.org/HttpLuaModule#ngx.sleep) to poll the lock periodically.

Methods
=======

To load this library,

1. you need to specify this library's path in ngx_lua's [lua_package_path](http://wiki.nginx.org/HttpLuaModule#lua_package_path) directive. For example, `lua_package_path "/path/to/lua-resty-lock/lib/?.lua;;";`.
2. you use `require` to load the library into a local Lua variable:

    local lock = require "resty.lock"

new
---
`syntax: obj = lock:new(dict_name)`

`syntax: obj = lock:new(dict_name, opts)`

Creates a new lock object instance by specifying the shared dictionary name (created by [lua_shared_dict](http://wiki.nginx.org/HttpLuaModule#lua_shared_dict)) and an optional options table `opts`.

The options table accepts the following options:

* `exptime`
Specifies expiration time (in seconds) for the lock entry in the shared memory dictionary. You can specify up to `0.001` seconds. Default to 30 (seconds). Even if the invoker does not call `unlock` or the object holding the lock is not GC'd, the lock will be released after this time. So deadlock won't happen even when the worker process holding the lock crashes.
* `timeout`
Specifies the maximal waiting time (in seconds) for the [lock](#lock) method calls on the current object instance. You can specify up to `0.001` seconds. Default to 5 (seconds). This option value cannot be bigger than `exptime`. This timeout is to prevent a [lock](#lock) method call from waiting forever.
* `step`
Specifies the initial step (in seconds) of sleeping when waiting for the lock. Default to `0.001` (seconds). When the [lock](#lock) method is waiting on a busy lock, it sleeps by steps. The step size is increased by a ratio (specified by the `ratio` option) until reaching the step size limit (specified by the `max_step` option).
* `ratio`
Specifies the step increasing ratio. Default to 2, that is, the step size doubles at each waiting iteration.
* `max_step`
Specifies the maximal step size (i.e., sleep interval, in seconds) allowed. See also the `step` and `ratio` options). Default to 0.5 (seconds).

lock
----
`syntax: elapsed, err = obj:lock(key)`

Tries to lock a key across all the Nginx worker processes in the current Nginx server instance. Different keys are different locks.

The length of the key string must not be larger than 65535 bytes.

Returns the waiting time (in seconds) if the lock is successfully acquired. Otherwise returns `nil` and a string describing the error.

The waiting time is not from the wallclock, but rather is from simply adding up all the waiting "steps". A nonzero `elapsed` return value indicates that someone else has just hold this lock. This is useful for [cache locks](#for-cache-locks).

When this method is waiting on fetching the lock, no operating system threads will be blocked and the current Lua "light thread" will be automatically yielded behind the scene.

It is strongly recommended to always call the [unlock()](#unlock) method to actively release the lock as soon as possible.

If the [unlock()](#unlock) method is never called after this method call, the lock will get released when
1. the current `resty.lock` object instance is collected automatically by the Lua GC.
2. the `exptime` for the lock entry is reached.

Common errors for this method call is
* "timeout"
: The timeout threshold specified by the `timeout` option of the [new](#new) method is exceeded.
* "locked"
: The current `resty.lock` object instance is already holding a lock (not necessarily of the same key).

Other possible errors are from ngx_lua's shared dictionary API.

unlock
------
`syntax: ok, err = obj:unlock()`

Releases the lock held by the current `resty.lock` object instance.

Returns `1` on success. Returns `nil` and a string describing the error otherwise.

If you call `unlock` when no lock is currently held, the error "unlocked" will be returned.

For Multiple Lua Light Threads
==============================

It is always a bad idea to share a single `resty.lock` object instance across multiple ngx_lua "light threads" because the object itself is stateful and is vulnerable to race conditions. It is highly recommended to always allocate a separate `resty.lock` object instance for each "light thread" that needs one.

For Cache Locks
===============

One common use case for this library is to limit concurrent backend queries for the same key when a cache miss happens. This usage is similar to the standard ngx_proxy module's [proxy_cache_lock](http://nginx.org/en/docs/http/ngx_http_proxy_module.html#proxy_cache_lock) directive.

The basic workflow for a cache lock is as follows:

1. Check the cache for a hit with the key. If a cache miss happens, proceed to step 2.
2. Instantiate a `resty.lock` object, call the [lock](#lock) method on the key, and check the 1st return value, i.e., the lock waiting time. If it is `nil`, handle the error. If it is `0`, then proceed to step 4. Otherwise it must be nonzero, then proceed to step 3.
3. Because the lock waiting is nonzero, it means some other Lua thread has just acquired the lock, which may have already put the value into the cache. So check the cache again for a hit. If it is still a miss, proceed to step 4; otherwise release the lock by calling [unlock](#unlock) and then return the cached value.
4. Query the backend (the data source) for the value, put the result into the cache, and then release the lock currently held by calling [unlock](#unlock).

Below is a kinda complete code example that demonstrates the idea.

    local resty_lock = require "resty.lock"
    local cache = ngx.shared.my_cache

    -- step 1:
    local val, err = cache:get(key)
    if val then
        ngx.say("result: ", val)
        return
    end

    if err then
        return fail("failed to get key from shm: ", err)
    end

    -- cache miss!
    -- step 2:
    local lock = resty_lock:new("my_locks")
    local elapsed, err = lock:lock(key)
    if not elapsed then
        return fail("failed to acquire the lock: ", err)
    end

    -- lock successfully acquired!

    if elapsed > 0 then
        -- step 3:
        -- someone might have already put the value into the cache
        -- so we check it here again:
        val, err = cache:get(key)
        if val then
            local ok, err = lock:unlock()
            if not ok then
                return fail("failed to unlock: ", err)
            end

            ngx.say("result: ", val)
            return
        end
    end

    --- step 4:
    local val = fetch_redis(key)
    if not val then
        local ok, err = lock:unlock()
        if not ok then
            return fail("failed to unlock: ", err)
        end

        -- FIXME: we should handle the backend miss more carefully
        -- here, like inserting a stub value into the cache.

        ngx.say("no value found")
        return
    end

    -- update the shm cache with the newly fetched value
    local ok, err = cache:set(key, val, 1)
    if not ok then
        local ok, err = lock:unlock()
        if not ok then
            return fail("failed to unlock: ", err)
        end

        return fail("failed to update shm cache: ", err)
    end

    local ok, err = lock:unlock()
    if not ok then
        return fail("failed to unlock: ", err)
    end

    ngx.say("result: ", val)

Here we assume that we use the ngx_lua shared memory dictionary to cache the Redis query results and we have the following configurations in `nginx.conf`:

    # you may want to change the dictionary size for your cases.
    lua_shared_dict my_cache 10m;
    lua_shared_dict my_locks 1m;

The `my_cache` dictionary is for the data cache while the `my_locks` dictionary is for `resty.lock` itself.

Several important things to note in the example above:

1. You need to release the lock as soon as possible, even when some other unrelated errors happen.
2. You need to update the cache with the result got from the backend *before* releasing the lock so other threads already waiting on the lock can get cached value when they get the lock afterwards.
3. When the backend returns no value at all, we should handle the case carefully by inserting some stub value into the cache.

Prerequisites
=============

* [LuaJIT](http://luajit.org) 2.0+
* [ngx_lua](http://wiki.nginx.org/HttpLuaModule) 0.8.10+

TODO
====

* We should simplify the current implementation when LuaJIT 2.1 gets support for `__gc` metamethod on normal Lua tables. Right now we are using an FFI cdata and a ref/unref memo table to work around this, which is rather ugly and a bit inefficient.

Community
=========

English Mailing List
--------------------

The [openresty-en](https://groups.google.com/group/openresty-en) mailing list is for English speakers.

Chinese Mailing List
--------------------

The [openresty](https://groups.google.com/group/openresty) mailing list is for Chinese speakers.

Bugs and Patches
================

Please report bugs or submit patches by

1. creating a ticket on the [GitHub Issue Tracker](http://github.com/agentzh/lua-resty-lock/issues),
1. or posting to the [OpenResty community](#community).

Author
======

Yichun "agentzh" Zhang (章亦春) <agentzh@gmail.com>, CloudFlare Inc.

Copyright and License
=====================

This module is licensed under the BSD license.

Copyright (C) 2013, by Yichun "agentzh" Zhang, CloudFlare Inc.

All rights reserved.

Redistribution and use in source and binary forms, with or without modification, are permitted provided that the following conditions are met:

* Redistributions of source code must retain the above copyright notice, this list of conditions and the following disclaimer.

* Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the following disclaimer in the documentation and/or other materials provided with the distribution.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

See Also
========
* the ngx_lua module: http://wiki.nginx.org/HttpLuaModule
* OpenResty: http://openresty.org
