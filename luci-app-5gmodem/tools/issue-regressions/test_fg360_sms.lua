package.loaded["luci.jsonc"] = {}
local adapter = dofile(arg[1] or "root/usr/share/5gmodem/fg360-sms.lua")

local snapshot = {
    ok = true, store = "SM", used = 4, capacity = 64,
    messages = {
        { ref = "SM:1|SM:2", status = "REC UNREAD", number = "+10000000000",
          date = "26/01/02,12:34:56+12", text = "first\nsecond" },
        { ref = "ME:2", status = "REC READ", number = "+10000000000",
          date = "26/01/02,12:34:56-08", text = "stored" }
    }
}

local actions = {}
local function stock(verb, ...)
    actions[#actions + 1] = { verb, ... }
    if verb == "list" then return snapshot end
    return { ok = true }
end

local function prepare()
    actions[#actions + 1] = { "prepare" }
    return true
end

local list = assert(adapter.handle(stock, prepare, "list"))
assert(#actions == 1 and actions[1][1] == "list")
assert(#list.msg == 2 and list.capacity == 64 and list.used == 4)
assert(list.msg[1].timestamp == "2026-01-02 12:34" and list.msg[1].tz == 180)
assert(list.msg[2].tz == -120 and list.msg[2].native_read == 1)
local first, second = list.msg[1].index, list.msg[2].index
assert(first:match("^%d+$") and first ~= second and list.msg[1].native_read == 0)

actions = {}
assert(adapter.handle(stock, prepare, "markread", first))
assert(#actions == 2 and actions[2][1] == "markread")
assert(actions[2][2] == "SM:1" and actions[2][3] == "SM:2")

actions = {}
local deleted = assert(adapter.handle(stock, prepare, "delete", first))
assert(deleted.success and deleted.ok[1] == first)
assert(#actions == 2 and actions[2][1] == "delete" and actions[2][2] == "SM:1|SM:2")

actions = {}
snapshot.messages[1].text = "different message in the same slots"
local stale = assert(adapter.handle(stock, prepare, "delete", first))
assert(stale.success == false and stale.failed[1] == first and #actions == 1)

actions = {}
local body = "Unicode ☀ and 'quotes'"
assert(adapter.handle(stock, prepare, "send", "+10000000000", body))
assert(#actions == 2 and actions[1][1] == "prepare")
assert(actions[2][1] == "send" and actions[2][2] == "+10000000000" and actions[2][3] == body)

actions = {}
assert(not adapter.handle(stock, prepare, "send", "00000", string.rep("😀", 36)))
assert(not adapter.handle(stock, prepare, "send", "+000;000", "text"))
assert(#actions == 0)

snapshot.capacity = 0
assert(not adapter.handle(stock, prepare, "list"))
assert(not adapter.handle(stock, prepare, "delete", "all"))

print("FG360 SMS adapter tests passed")
