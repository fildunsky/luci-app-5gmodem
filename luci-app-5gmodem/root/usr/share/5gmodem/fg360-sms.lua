local json = require "luci.jsonc"
local unpack = table.unpack or unpack
local modem = "127.0.0.1:17171"
local sms_paths = {
    "/usr/libexec/fg360-mea-webui/sms_fg360_tcp.lua",
    "/usr/libexec/fg360-mea-webui/sms_fg360_tcp",
    "/opt/mea-root/compat/sms_fg360_tcp.lua"
}

local function quote(value)
    return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local function run(executable, ...)
    local command = quote(executable)
    for _, value in ipairs({ ... }) do command = command .. " " .. quote(value) end
    local pipe = io.popen(command .. " 2>/dev/null && printf '\\n__5GM_OK\\n'", "r")
    if not pipe then return nil end
    local output = pipe:read("*a")
    pipe:close()
    return output:match("^(.*)\n__5GM_OK\n$")
end

local function stock_call(action, ...)
    for _, path in ipairs(sms_paths) do
        local file = io.open(path, "r")
        if file then
            file:close()
            local output = run(path, action, modem, ...)
            return output and json.parse(output)
        end
    end
end

local function prepare_send()
    local output = run("/usr/share/fg360-modem/fg360_at_debug.sh", modem, "AT+CGSMS=2")
    return output and ("\n" .. output:gsub("\r", "")):match("\nOK%s*$") ~= nil
end

local function references(ref)
    if type(ref) ~= "string" or ref == "" or ref:match("^|") or ref:match("|$") or ref:find("||", 1, true) then
        return nil
    end
    local refs = {}
    for token in ref:gmatch("[^|]+") do
        if not token:match("^[A-Z][A-Z]:%d+$") then return nil end
        refs[#refs + 1] = token
    end
    return refs
end

-- Storage indices can be shared by different stores and reused after deletion.
-- Include the full stock reference and message identity so a stale UI selection
-- cannot be resolved by slot number alone. Decimal strings preserve all bits.
local function message_id(ref, number, date, content)
    local identity = table.concat({ ref, number, date, content }, "\0")
    local hash = 0
    for i = 1, #identity do
        hash = (hash * 257 + identity:byte(i)) % 8796093022151
    end
    return string.format("%.0f", hash + 1)
end

local function timestamp(date)
    local year, month, day, hour, minute, zone = date:match(
        "^(%d%d)/(%d%d)/(%d%d),(%d%d):(%d%d):%d%d([+-]%d%d)$")
    if not year then return date end
    return "20" .. year .. "-" .. month .. "-" .. day .. " " .. hour .. ":" .. minute, tonumber(zone) * 15
end

local function stock_list(call)
    local result = call("list")
    if type(result) ~= "table" or result.ok ~= true or type(result.messages) ~= "table" or
        type(result.capacity) ~= "number" or result.capacity <= 0 or type(result.used) ~= "number" then
        return nil
    end

    local list = { msg = {}, used = result.used, capacity = result.capacity, store = result.store }
    local by_id = {}
    for _, message in ipairs(result.messages) do
        local refs = references(message.ref)
        if refs then
            local number = tostring(message.number or "")
            local date = tostring(message.date or "")
            local content = tostring(message.text or "")
            local id = message_id(message.ref, number, date, content)
            -- Fail closed if two messages map to the same UI index.
            if by_id[id] then return nil end
            local time, zone = timestamp(date)
            by_id[id] = refs
            list.msg[#list.msg + 1] = {
                index = id, sender = number, timestamp = time, tz = zone, content = content,
                native_read = message.status ~= "REC UNREAD" and 1 or 0
            }
        end
    end
    return list, by_id
end

local function valid_recipient(number)
    local digits = number:gsub("^%+", "")
    return #digits >= 5 and #digits <= 20 and digits:match("^%d+$") ~= nil
end

local function valid_text(body)
    if body == "" or body:find("%z") then return false end
    local units, bytes = 0, 0
    for char in body:gmatch("[\1-\127\194-\244][\128-\191]*") do
        bytes = bytes + #char
        units = units + (#char == 4 and 2 or 1)
    end
    return bytes == #body and units <= 70
end

local function accepted(result)
    return type(result) == "table" and result.ok == true
end

local function handle(call, prepare, action, ...)
    local args = { ... }
    if action == "send" then
        if not valid_recipient(args[1] or "") then return nil, "Invalid SMS recipient" end
        if not valid_text(args[2] or "") then return nil, "SMS text must fit in 70 UTF-16 code units" end
        if not prepare() then return nil, "Could not prepare the FG360 SMS bearer" end
        local result = call("send", args[1], args[2])
        if not accepted(result) then
            local error_text = type(result) == "table" and tostring(result.error or "") or ""
            local code = error_text:match("ERROR:%s*(%d+)")
            return nil, code and ("FG360 refused SMS (error " .. code .. ")") or "FG360 did not confirm SMS delivery to the network"
        end
        return { success = true }
    end

    if action ~= "list" and action ~= "markread" and action ~= "delete" then
        return nil, "Unsupported FG360 SMS operation"
    end
    local list, by_id = stock_list(call)
    if not list then return nil, "FG360 SMS inbox is unavailable" end
    if action == "list" then return list end

    if action == "delete" and args[1] == "all" then
        args = {}
        for _, message in ipairs(list.msg) do args[#args + 1] = message.index end
    end

    local ok, failed, mark_refs = {}, {}, {}
    for _, id in ipairs(args) do
        local refs = by_id[id]
        if not refs then
            failed[#failed + 1] = id
        elseif action == "markread" then
            for _, ref in ipairs(refs) do mark_refs[#mark_refs + 1] = ref end
        elseif accepted(call("delete", table.concat(refs, "|"))) then
            ok[#ok + 1] = id
        else
            failed[#failed + 1] = id
        end
        by_id[id] = nil
    end
    if action == "markread" then
        if #failed > 0 or (#mark_refs > 0 and not accepted(call("markread", unpack(mark_refs)))) then
            return nil, "FG360 did not mark the selected messages read"
        end
        return { success = true }
    end
    return { success = #failed == 0, ok = ok, failed = failed }
end

if arg and arg[0] and arg[0]:match("fg360%-sms%.lua$") then
    local result, reason = handle(stock_call, prepare_send, arg[1], unpack(arg, 2))
    if result and result.msg and #result.msg == 0 then
        result.msg = nil
        print('{"msg":[],' .. json.stringify(result):sub(2))
    else
        print(json.stringify(result or { error = reason }))
    end
    if not result then os.exit(1) end
end

return { handle = handle }
