local function present(value)
    if type(value) ~= "string" and type(value) ~= "number" then return nil end
    local text = tostring(value):match("^%s*(.-)%s*$")
    if text ~= "" and text ~= "-" and text ~= "--" then return text end
end

local function table_or_empty(value)
    return type(value) == "table" and value or {}
end

local function measurement(value)
    local text = present(value)
    if not text then return nil end
    text = text:gsub("%s+dBm$", ""):gsub("%s+dB$", "")
    if text:match("^[+-]?%d+%.?%d*$") then return text end
end

local function uint(value)
    local text = present(value)
    return text and text:match("^%d+$") or nil
end

local function operator_label(name, plmn, database)
    name = present(name)
    if name and not uint(name) then return name end
    if not plmn then return name end
    local file = io.open(database or "/usr/share/5gmodem/mccmnc.dat", "r")
    if not file then return name or plmn end
    local label
    for line in file:lines() do
        local code, brand = line:match("^(%d+);[^;]*;([^;\r\n]+)")
        if code == plmn then label = present(brand); break end
    end
    file:close()
    return label or name or plmn
end

local function operator_code(value)
    local text = uint(value)
    return text and text:match("^%d%d%d%d%d%d?$") or nil
end

local function hex(value)
    local text = present(value)
    return text and text:gsub("^0[xX]", ""):upper():match("^[%dA-F]+$") or nil
end

local function decimal(value, hexadecimal)
    local text = uint(value)
    if text then return text end
    local number = hexadecimal and tonumber(hexadecimal, 16)
    if number then return string.format("%.0f", number) end
end

local function band(value)
    local text = present(value)
    if text then return text:match("^[Bn]%d+$") end
end

local function width(value)
    local text = present(value)
    if text then return text:match("^(%d+%.?%d* MHz)$") end
end

local function modulation(value)
    local text = present(value)
    if text and text ~= "UNKNOWN" then return text end
end

local function cell_channel(cell)
    return uint(cell.ssb_arfcn) or uint(cell.arfcn) or decimal(nil, hex(cell.arfcn_hex))
end

local function read_line(path)
    local file = io.open(path, "r")
    if not file then return nil end
    local value = file:read("*l")
    file:close()
    return value
end

local thermal_zones = {
    "md_4g", "md_5g", "md_3g", "md_rf", "nrpa_ntc", "ltepa_ntc", "rf_ntc", "soc_max",
    "cpu_little0", "cpu_little1", "cpu_little2", "cpu_little3", "gpu0", "gpu1",
    "dramc", "soc_dram_ntc", "mmsys", "crystal", "pmic", "pmic_vcore", "pmic_vproc", "pmic_vgpu", "conn_gps"
}
local known_zone = {}
for _, name in ipairs(thermal_zones) do known_zone[name] = true end

local function modem_temperatures()
    local readings = {}
    for index = 0, 127 do
        local path = "/sys/class/thermal/thermal_zone" .. index .. "/"
        local name = read_line(path .. "type")
        if known_zone[name] and not readings[name] then
            local value = tonumber(read_line(path .. "temp"))
            if value and value >= -40000 and value <= 125000 then
                readings[name] = string.format("%.1f", value / 1000)
            end
        end
    end
    return readings
end

local function bytes_display(value)
    local size = tonumber(uint(value))
    if not size then return nil end
    for _, unit in ipairs({ "B", "KiB", "MiB", "GiB", "TiB" }) do
        if size < 1024 or unit == "TiB" then
            return string.format(unit == "B" and "%.0f %s" or "%.1f %s", size, unit)
        end
        size = size / 1024
    end
end

local function connection_uptime(iface, netdev)
    if not iface or not netdev then return nil end
    local connection = require("ubus").connect()
    if not connection then return nil end
    local ok, data = pcall(connection.call, connection, "network.interface." .. iface, "status", {})
    connection:close()
    if ok and type(data) == "table" and data.up == true and data.l3_device == netdev then
        return tonumber(uint(data.uptime))
    end
end

local function carrier_values(carrier)
    return {
        band = band(carrier.band), bandwidth = width(carrier.bandwidth),
        pci = uint(carrier.pci), earfcn = cell_channel(carrier),
        rsrp = measurement(carrier.rsrp), rsrq = measurement(carrier.rsrq),
        sinr = measurement(carrier.sinr), rssi = measurement(carrier.rssi),
        mimo = uint(carrier.dl_mimo), mod = modulation(carrier.dl_modulation)
    }
end

local function carrier_band(carrier)
    if not carrier.band then return nil end
    return carrier.bandwidth and carrier.band .. " @ " .. carrier.bandwidth or carrier.band
end

local function sim_state(status)
    local pin = (present(status) or ""):upper()
    if pin == "READY" then return "ready" end
    if pin == "ABSENT" or pin == "SIM NOT INSERTED" or pin == "NOT INSERTED" then return "absent" end
    if pin:match(" PIN%d?$") or pin:match(" PUK%d?$") then return "locked" end
    return "unknown"
end

local function network_mode(status, anchor, secondary)
    local mode = (present(status.registration_mode) or present(status.rat) or ""):upper()
    if mode:find("NSA", 1, true) or (anchor == "LTE" and secondary == "NR") then return "5G NSA" end
    if mode:find("5G SA", 1, true) or anchor == "NR" then return "5G SA" end
    if anchor == "LTE" or mode:find("LTE", 1, true) or mode == "4G" then
        return secondary == "LTE" and "LTE-A" or "LTE"
    end
    if mode == "5G" or mode == "3G" or mode == "2G" then return mode end
end

local function normalize(status, options)
    status = table_or_empty(status)
    if status.success == false then return nil end
    status = table_or_empty(status.cellular or status)
    if status.ok ~= true then return nil end

    local age = tonumber(uint(status.cache_age))
    local stale = status.cache_stale ~= false or not age or options.signal == false
    local raw = table_or_empty(status.raw)
    local model = (present(raw.ati) or ""):match("Model:%s*(FG360[%w%-]*)")
    local output = {
        backend = "fg360", protocol = "mipc", iface_proto = "mipc", modem = "Fibocom " .. (model or "FG360"),
        path = "ccci", onbus = "1", iface = options.iface, netdev = options.netdev,
        cache_stale = stale, radio_age = age,
        age = age and tostring(age) or nil, ca_from_history = status.ca_from_history == true,
        firmware = present(status.baseband_version), sim_state = sim_state(status.sim_status),
        waiting_sim = false, conn_time = "-", imei = options.imei
    }
    local temperature = present(table_or_empty(status.system).temperature)
    output.soc_temp = temperature and measurement(temperature:gsub("%s+C$", "")) or nil
    local antenna = table_or_empty(status.antenna)
    if antenna.source == "physical_switch" and antenna.available == true then
        if antenna.mode == "internal" or antenna.mode == "external" or antenna.mode == "switching" then
            output.antenna_mode = antenna.mode
        end
    end
    if options.temperatures then
        local temperatures, values = options.temperatures, {}
        local mode = (present(status.registration_mode) or present(status.rat) or ""):upper()
        local nr = mode:find("5G", 1, true) or status.cell_rat == "NR"
        local preferred = nr and temperatures.md_5g or temperatures.md_4g
        preferred = preferred or temperatures.md_rf
        if preferred then output.mtemp = preferred .. " &deg;C" end
        for _, name in ipairs(thermal_zones) do
            if temperatures[name] then values[#values + 1] = name .. "=" .. temperatures[name] end
        end
        if #values > 0 then output.temps = table.concat(values, " ") end
    end

    if options.netdev then
        local prefix = "/sys/class/net/" .. options.netdev .. "/statistics/"
        output.rx = bytes_display(read_line(prefix .. "rx_bytes"))
        output.tx = bytes_display(read_line(prefix .. "tx_bytes"))
    end
    local uplink = table_or_empty(status.uplink)
    if status.network_connected == true and status.uplink_type == "cellular"
        and (not options.netdev or uplink.interface == options.netdev) then
        output.conn_status = "connected"
        output.ipaddr, output.ipaddr6 = present(status.ipv4), present(status.ipv6)
    end
    if output.sim_state == "absent" then output.registration = "SIM not inserted" end
    if output.sim_state == "ready" then
        local imsi, iccid = uint(status.imsi), uint(status.iccid)
        if imsi and #imsi >= 14 and #imsi <= 16 then output.imsi = imsi end
        if iccid and #iccid >= 18 and #iccid <= 22 then
            output.iccid = iccid
            if options.phone_for_sim then output.phone = options.phone_for_sim(iccid) end
        end
    end
    local duration = options.duration
    if duration then
        output.conn_status = "connected"
        output.conn_time_sec = tostring(duration)
        output.conn_time = string.format("%dd, %02d:%02d:%02d", math.floor(duration / 86400),
            math.floor(duration / 3600) % 24, math.floor(duration / 60) % 60, duration % 60)
    end
    if stale or output.sim_state == "absent" or output.sim_state == "locked" then return output end

    local cells = options.cell == false and {} or table_or_empty(status.serving_cells)
    local lte_cell, nr_cell = table_or_empty(cells.lte), table_or_empty(cells.nr)
    local anchor = cells.endc == true and next(lte_cell) and "LTE" or present(status.cell_rat)
    if anchor ~= "LTE" and anchor ~= "NR" then
        if next(nr_cell) then anchor = "NR" elseif next(lte_cell) then anchor = "LTE" end
    end
    local cell = anchor == "NR" and nr_cell or lte_cell
    local mixed = anchor == "LTE" and (cells.endc == true
        or (present(status.registration_mode) or ""):find("NSA", 1, true) ~= nil)
    local primary, secondary = {}, {}
    if options.carrier ~= false and status.ca_from_history ~= true then
        for _, item in ipairs(table_or_empty(status.carriers)) do
            local role = present(item.role) or ""
            if item.active == true and (item.rat == "LTE" or item.rat == "NR") then
                if role == item.rat .. " PCC" and item.rat == anchor then
                    primary = carrier_values(item)
                elseif role:find("SCC", 1, true) or (mixed and role == "NR PCC") then
                    local carrier = carrier_values(item)
                    carrier.rat, carrier.ul_ca = item.rat, item.ul_ca == true
                    carrier.anchor = role == "NR PCC"
                    if carrier.band then secondary[#secondary + 1] = carrier end
                end
            end
        end
    end

    local serving = carrier_values(cell)
    local same_rat = not mixed
    local cell_fresh = options.cell ~= false
    primary.band = serving.band or primary.band or (cell_fresh and band(status.band) or nil)
    primary.bandwidth = primary.bandwidth or serving.bandwidth or (cell_fresh and width(status.bandwidth) or nil)
    primary.pci = serving.pci or primary.pci or (cell_fresh and uint(status.pci) or nil)
    primary.earfcn = serving.earfcn or primary.earfcn or (cell_fresh and uint(status.arfcn) or nil)
    output.pband, output.bandwidth = carrier_band(primary), primary.bandwidth
    output.pci, output.earfcn = primary.pci, primary.earfcn
    output.pmimo, output.pmod = primary.mimo, primary.mod
    for _, key in ipairs({ "rsrp", "rsrq", "sinr", "rssi" }) do
        output[key] = (same_rat and measurement(status[key])) or serving[key] or primary[key]
    end

    if mixed and next(nr_cell) then
        local nr_anchor
        for _, item in ipairs(secondary) do
            if item.anchor then nr_anchor = item; break end
        end
        if not nr_anchor then
            nr_anchor = carrier_values(nr_cell)
            if nr_anchor.band then
                nr_anchor.rat = "NR"
                table.insert(secondary, 1, nr_anchor)
            end
        end
        for _, key in ipairs({ "rsrp", "rsrq", "sinr", "rssi" }) do
            nr_anchor[key] = measurement(status[key]) or nr_anchor[key] or measurement(nr_cell[key])
        end
    end

    local bands, upload = {}, {}
    if primary.band then bands[1], upload[1] = primary.band, primary.band end
    local extra_rat
    for i = 1, math.min(#secondary, 4) do
        local item = secondary[i]
        local prefix = "s" .. i
        output[prefix .. "band"] = carrier_band(item)
        output[prefix .. "state"] = "activated"
        for _, key in ipairs({ "pci", "earfcn", "rsrp", "rsrq", "sinr", "rssi", "mimo", "mod" }) do
            output[prefix .. key] = item[key]
        end
        bands[#bands + 1] = item.band
        if item.ul_ca then upload[#upload + 1] = item.band end
        if not extra_rat or item.rat == "NR" then extra_rat = item.rat end
    end
    if #upload > 1 then output.ulcc = table.concat(upload, "+") end
    local mode = network_mode(status, anchor, extra_rat)
    if mode then output.mode = #bands > 0 and mode .. " | " .. table.concat(bands, " + ") or mode end

    if cell_fresh then
        output.tac_hex = hex(cell.tac_hex) or hex(status.tac_hex)
        output.tac_dec = decimal(cell.tac or status.tac, output.tac_hex)
        output.tac_h, output.tac_d = output.tac_hex, output.tac_dec
        output.cid_hex = hex(cell.cell_hex) or hex(status.cell_id_hex)
        output.cid_dec = decimal(cell.cell_id or status.cell_id_decimal, output.cid_hex)
        if anchor == "LTE" then output.enbid = uint(status.base_station_id) end
    end
    local csq = tonumber(uint(options.csq or status.csq))
    if csq and csq <= 31 then
        output.csq = tostring(csq)
        output.rssi = output.rssi or tostring(-113 + 2 * csq)
    end
    local signal = tonumber(uint(status.signal_percent))
    if output.rsrp and signal and signal <= 100 then output.signal = tostring(signal) end
    output.cqi, output.ri = uint(status.cqi), uint(status.rank_dl)
    output.ims_registration = present(status.ims_registration)
    output.qos_5qi = uint(status.qos_5qi)
    output.ambrdl = (present(status.dl_sambr) or ""):match("^(%d+%.?%d*) Mbps$")
    output.ambrul = (present(status.ul_sambr) or ""):match("^(%d+%.?%d*) Mbps$")
    output.ca_active_count = #bands > 0 and #bands or nil
    output.ca_observed_max = tonumber(uint(status.ca_max_count))
    local reported = operator_code(status.operator_code)
    local operator = operator_code(status.serving_operator_code) or reported or operator_code(status.operator_name)
    local name = status.operator_name
    if status.operator_source == "sim_imsi" and reported and operator ~= reported then
        output.home_operator = operator_label(name, reported, options.operator_database)
        name = nil
    end
    output.operator_name = operator_label(name, operator, options.operator_database)
    if operator then
        output.operator_mcc, output.operator_mnc = operator:sub(1, 3), operator:sub(4)
    end
    local registration = (present(raw.registration) or ""):match("%+C5GREG:%s*%d+,(%d+)")
    if registration == "5" or status.roaming == "漫游" then
        output.registration, output.roaming = "5", "1"
    elseif registration == "1" or status.roaming == "本地注册" then
        output.registration, output.roaming = "1", "0"
    elseif output.conn_status == "connected" and output.sim_state == "ready" then
        output.registration = "1"
    end

    local neighbors = {}
    if cell_fresh then
        for _, item in ipairs(table_or_empty(status.neighbors)) do
            local pci, arfcn = uint(item.pci), cell_channel(item)
            if pci and arfcn and (item.rat == "LTE" or item.rat == "NR") then
                neighbors[#neighbors + 1] = {
                    rat = item.rat, band = band(item.band), pci = pci, earfcn = arfcn,
                    rsrp = measurement(item.rsrp), rsrq = measurement(item.rsrq),
                    sinr = measurement(item.sinr), rssi = measurement(item.rssi)
                }
            end
        end
    end
    if #neighbors > 0 then output.neighbors = neighbors end

    if options.rxchain ~= false then
        local ports, seen = {}, {}
        for _, chain in ipairs(table_or_empty(status.rx_chains)) do
            local index, level = tonumber(uint(chain.index)), tonumber(measurement(chain.level))
            if chain.rat == anchor and chain.role == "PCC" and chain.active == true and index
                and level and level > -160 and level < 0 and not seen[index] then
                ports[#ports + 1] = string.format("%d:%g:", index + 1, level)
                seen[index] = true
            end
        end
        if #ports > 0 then output.antports = table.concat(ports, " ") end
        if #ports == 2 or #ports == 4 then output.rxdiv = tostring(#ports) .. "rx" end
    end
    return output
end

local function cache_fresh(name, uptime, interval)
    if not uptime then return false end
    local root = os.getenv("FG360_STATUS_CACHE_DIR") or "/tmp/fg360-status-cache"
    local counters = read_line(root .. "/" .. name .. ".meta") or ""
    local last = tonumber(counters:match("^%d+ %d+ %d+ %d+ %d+ (%d+)"))
    return last ~= nil and last > 0 and uptime >= last and uptime - last <= interval * 2 + 5
end

local function phone_for_sim(iccid)
    local command = "/usr/share/5gmodem/fg360-sim.sh phone ccci " .. iccid .. " 2>/dev/null"
    local pipe = io.popen(command, "r")
    if not pipe then return nil end
    local phone = pipe:read("*l")
    pipe:close()
    if phone and phone:match("^%+?%d+$") then return phone end
end

local function run()
    local json = require "luci.jsonc"
    local options, status = {}, nil
    if arg[1] == "--stdin" then
        status = json.parse(io.read("*a"))
    else
        if os.getenv("FG360_STATUS_LIBRARY") ~= "1" then return false end
        for i, key in ipairs({ "iface", "netdev" }) do
            if arg[i] and arg[i] ~= "" then
                if not arg[i]:match("^[%w_][-%.%w_]*$") then return false end
                options[key] = arg[i]
            end
        end
        options.csq = arg[3]
        options.phone_for_sim = phone_for_sim
        options.duration = connection_uptime(options.iface, options.netdev)
        local stock = dofile("/usr/libexec/fg360-mea-webui/fg360_api.lua")
        if type(stock) ~= "table" or type(stock.status) ~= "function" then return false end
        status = stock.status()
        local settings = type(stock.settings) == "function" and table_or_empty(stock.settings()) or {}
        local uptime = tonumber((read_line("/proc/uptime") or ""):match("^[%d.]+"))
        local cell = tonumber(settings.cell) or 5
        options.signal = cache_fresh("signal", uptime, tonumber(settings.cellular) or 5)
        options.cell = cache_fresh("gtccinfo", uptime, cell)
        options.carrier = cache_fresh("carrier", uptime, cell)
        options.rxchain = cache_fresh("rxchain", uptime, cell)
        options.temperatures = modem_temperatures()
        local identity = io.open("/tmp/fg360-status-cache/imei", "r")
        if identity then
            for line in identity:lines() do
                local number = uint(line) or line:match("%+CGSN:%s*(%d+)")
                if number and #number == 15 then options.imei = number; break end
            end
            identity:close()
        end
    end
    local output = normalize(status, options)
    if not output then return false end
    io.write(json.stringify(output), "\n")
    return true
end

if ... == "fg360-status" then return normalize end
local ok, success = pcall(run)
if not ok or not success then os.exit(1) end
