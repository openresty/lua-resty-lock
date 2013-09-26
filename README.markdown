Name
====

lua-resty-lock - Simple shm-based nonblocking locking API

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

For Cache Locks
===============

One common use case for this library is to limit concurrent backend queries for the same key when a cache miss happens. This usage is similar to the standard ngx_proxy module's [proxy_cache_lock](http://nginx.org/en/docs/http/ngx_http_proxy_module.html#proxy_cache_lock) directive.

The basic workflow for a cache lock is as follows:

1. Check the cache for a hit with the key. If a cache miss happens, proceed to step 2.
2. Instantiate a `resty.lock` object, call the [lock](#lock) method on the key, and check the 1st return value, i.e., the lock waiting time. If it is `nil`, handle the error. If it is `0`, then proceed to step 4. Otherwise it must be nonzero, then proceed to step 3.
3. Because the lock waiting is nonzero, it means some other Lua thread has just acquired the lock, which may have already put the value into the cache. So check the cache again for a hit. If it is still a miss, proceed to step 4; otherwise release the lock by calling [unlock](#unlock) and then return the cached value.
4. Query the backend (the data source) for the value, put the result into the cache, and then release the lock currently held by calling [unlock](#unlock).

Prerequisites
=============

* [LuaJIT](http://luajit.org) 2.0+
* [ngx_lua](http://wiki.nginx.org/HttpLuaModule) 0.8.10+

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
