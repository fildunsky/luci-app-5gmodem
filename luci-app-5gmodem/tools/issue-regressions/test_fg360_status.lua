local normalize = assert(loadfile(assert(arg[1])))("fg360-status")

local status = {
    ok = true, cache_stale = false, cache_age = 3, sim_status = "READY",
    registration_mode = "LTE FDD", cell_rat = "LTE", signal_percent = 58,
    raw = { registration = "+C5GREG: 2,1" },
    rsrp = "-94 dBm", rsrq = "-11.5 dB", sinr = "7.5 dB", rssi = "-",
    serving_cells = { lte = {
        band = "B3", bandwidth = "20 MHz", pci = "10", ssb_arfcn = "1300",
        tac_hex = "0001", cell_hex = "0002"
    } },
    carriers = {
        { rat = "LTE", role = "LTE PCC", band = "B3", active = true, bandwidth = "20 MHz" },
        { rat = "LTE", role = "LTE SCC 1", band = "B7", active = true, bandwidth = "10 MHz",
          pci = "25", arfcn = "2850", rsrp = "-99 dBm", ul_ca = true },
        { rat = "LTE", role = "LTE SCC 2", band = "B1", active = false }
    },
    neighbors = { { rat = "LTE", pci = "20", ssb_arfcn = "3050", rsrp = "-102 dBm" } },
    rx_chains = {
        { rat = "LTE", role = "PCC", index = 0, level = -95, active = true },
        { rat = "LTE", role = "PCC", index = 1, level = -101, active = true },
        { rat = "NR", role = "PCC", index = 2, level = -103, active = true }
    },
    system = { temperature = "54.2 C" }
}

local result = normalize({ success = true, cellular = status }, { iface = "wan", netdev = "ccmni1" })
assert(result.iface == "wan" and result.netdev == "ccmni1" and result.protocol == "mipc")
assert(result.sim_state == "ready" and result.registration == "1")
assert(result.mode == "LTE-A | B3 + B7" and result.pband == "B3 @ 20 MHz")
assert(result.rsrp == "-94" and result.rsrq == "-11.5" and result.sinr == "7.5")
assert(result.rssi == nil and result.csq == nil and result.signal == "58")
assert(result.s1band == "B7 @ 10 MHz" and result.s1earfcn == "2850" and result.s1rsrp == "-99")
assert(result.s1state == "activated" and result.s2band == nil and result.ulcc == "B3+B7")
assert(result.tac_dec == "1" and result.cid_dec == "2" and result.cid_hex == "0002")
assert(result.neighbors[1].earfcn == "3050" and result.neighbors[1].rsrp == "-102")
assert(result.antports == "1:-95: 2:-101:" and result.rxdiv == "2rx")
assert(result.soc_temp == "54.2" and result.mtemp == nil)

local test_iccid = "00000000000000000001"
status.iccid = test_iccid
result = normalize(status, { phone_for_sim = function(iccid)
    assert(iccid == test_iccid)
    return "+0000000"
end })
assert(result.phone == "+0000000")
status.sim_status = "SIM PIN"
result = normalize(status, { phone_for_sim = function() error("locked SIM lookup") end })
assert(result.phone == nil)
status.iccid, status.sim_status = nil, "READY"

local database = os.tmpname()
local names = assert(io.open(database, "w"))
names:write("00101;Test;Home network\n00102;Test;Visited network\n")
names:close()
status.operator_name, status.serving_operator_code = "00102", "00102"
result = normalize(status, { operator_database = database })
assert(result.operator_name == "Visited network" and result.operator_mcc == "001" and result.operator_mnc == "02")
status.operator_name = "Broadcast name"
assert(normalize(status, { operator_database = database }).operator_name == "Broadcast name")
status.operator_name, status.operator_code, status.operator_source = "Home network", "00101", "sim_imsi"
result = normalize(status, { operator_database = database })
assert(result.operator_name == "Visited network" and result.home_operator == "Home network")
os.remove(database)
status.operator_name, status.operator_code, status.operator_source, status.serving_operator_code = nil, nil, nil, nil

result = normalize(status, { csq = "10", temperatures = { md_4g = "56.2", md_5g = "47.1" } })
assert(result.csq == "10" and result.rssi == "-93")
assert(result.mtemp == "56.2 &deg;C" and result.temps == "md_4g=56.2 md_5g=47.1")

status.ca_from_history = true
result = normalize(status, {})
assert(result.mode == "LTE | B3" and result.ca_from_history and result.s1band == nil)
status.ca_from_history = false
assert(normalize(status, { carrier = false }).s1band == nil)
status.ca_from_history = true

status.registration_mode, status.serving_cells.endc = "5G NSA", true
status.serving_cells.lte.rsrp = "-92 dBm"
status.serving_cells.nr = { band = "n78", pci = "50", ssb_arfcn = "640000", bandwidth = "80 MHz" }
status.rsrp = "-106 dBm"
result = normalize(status, { temperatures = { md_4g = "56.2", md_5g = "47.1" } })
assert(result.mode == "5G NSA | B3 + n78" and result.pci == "10" and result.rsrp == "-92")
assert(result.s1earfcn == "640000" and result.s1rsrp == "-106" and result.mtemp == "47.1 &deg;C")

status.cache_stale = true
result = normalize(status, {})
assert(result.cache_stale and result.age == "3" and result.sim_state == "ready")
assert(result.mode == nil and result.rsrp == nil and result.s1band == nil and result.antports == nil)
assert(result.neighbors == nil and result.tac_dec == nil)
status.sim_status = "SIM NOT INSERTED"
assert(normalize(status, {}).sim_state == "absent")
assert(normalize(status, {}).registration == "SIM not inserted")
assert(normalize({ success = false, cellular = status }, {}) == nil)
