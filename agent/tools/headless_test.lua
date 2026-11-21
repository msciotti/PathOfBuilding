local P = "/root/pob-ai/packages/plugin-pob/pob-data"
package.path = P.."/src/?.lua;"..P.."/runtime/lua/?.lua;"..P.."/runtime/lua/?/init.lua;/root/pob-agent/?.lua;"..package.path
package.cpath = P.."/runtime/?.so;"..package.cpath
package.preload["lua-utf8"] = function() return {len=string.len,sub=string.sub,upper=string.upper,lower=string.lower,reverse=string.reverse,byte=string.byte,char=string.char,find=string.find,gmatch=string.gmatch,gsub=string.gsub,match=string.match} end
local cwd = P.."/src"
local f = io.popen("pwd"); f:close()
local Q=arg[1]; local LIM=tonumber(arg[2]) or 60; dofile(cwd.."/HeadlessWrapper.lua")
local AD = require("AgentData")
local t0=os.clock()
local idx = AD.build(data, build.spec and build.spec.tree)
print(string.format("index built: %d entries in %.2fs", #idx.list, os.clock()-t0))
for _, s in ipairs(AD.listSources(idx)) do io.write(s.src.."="..s.count.."  ") end
print("\n")
local q = Q or "poison immun"
local res, total = AD.search(idx, q, {limit=LIM})
print("query '"..q.."' total="..total)
for _, e in ipairs(res) do print(string.format("[%s] %s | %s", e.src, e.name or e.id, table.concat(e.lines," / "):sub(1,110))) end
