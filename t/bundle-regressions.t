use Test::Nginx::Socket::Lua 'no_plan';
use Cwd qw(cwd);

my $pwd = cwd();
our $HttpConfig = qq{
    lua_shared_dict locks 1m;
    lua_package_path "$pwd/lib/?.lua;$pwd/src/?.lua;;";
    lua_package_cpath "$pwd/?.so;;";
};

no_long_string();
run_tests();

__DATA__

=== TEST 1: expired owner cannot modify a successor lease
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local lock = require "resty.lock"
            local a = assert(lock:new("locks", {exptime=0.03, timeout=0}))
            local b = assert(lock:new("locks", {exptime=1, timeout=0}))
            assert(a:lock("owner"))
            ngx.sleep(0.05)
            assert(b:lock("owner"))
            local ok, err = a:expire(1)
            assert(not ok and err == "lock ownership lost")
            ok, err = a:unlock()
            assert(not ok and err == "lock ownership lost")
            local c = assert(lock:new("locks", {timeout=0}))
            ok, err = c:lock("owner")
            assert(not ok and err == "timeout")
            assert(b:unlock())
            assert(c:lock("owner"))
            assert(c:unlock())
            ngx.say("ok")
        }
    }
--- request
GET /t
--- response_body
ok
--- no_error_log
[error]
