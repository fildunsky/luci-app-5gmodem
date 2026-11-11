# Android radio selection: allowed network types and bands.
#
# Input: the line protocol printed by android-cells.dex "radio|set-*|reset-bands".
#   -v mode=json   (default) the band/mode JSON used by the LuCI frequency block
#   -v mode=caps   the modem's own band list, "1:..;2:..;3:..;6:.." (taken from a reset readback)
#   -v mode=mask   the Android network-type bitmask for -v want=<mode id>
#   -v mode=bands  "ran=b,b ran=b" arguments for -v sel_lte= -v sel_nsa= -v sel_3g= -v sel_2g= band lists
# -v caps="1:..;2:..;3:..;6:.."  cached modem band lists (a space separated list per RAT)
#   or "0:nobands": the phone does not answer the band API (BANDS_UNSUPPORTED), only the network mode is offered.
#   Android drops the network-type bits the hardware lacks, so 2G, 3G and NR are all offered in that case.
# -v model=<name>

# NetworkTypeBitMask bits (TelephonyManager): GSM family, UMTS family, LTE, NR.
function has(m, b) { return int(m / b) % 2 == 1 }
function any(m, a, n,  i) { n = split(a, parts, " "); for (i = 1; i <= n; i++) if (has(m, parts[i])) return 1; return 0 }
function str(s) { gsub(/\\/, "\\\\", s); gsub(/"/, "\\\"", s); gsub(/[[:cntrl:]]/, "", s); return s }

# GERAN band ids (AccessNetworkConstants.GeranBand) -> the nominal MHz shown to the user.
function gsm_mhz(id) {
 if (id == 1) return 380; if (id == 2) return 410; if (id == 3) return 450; if (id == 4) return 480
 if (id == 5) return 710; if (id == 6) return 750; if (id == 7) return 810; if (id == 8) return 850
 if (id == 9 || id == 10 || id == 11) return 900
 if (id == 12) return 1800; if (id == 13) return 1900
 return 0
}

function parse_caps(s,  n, i, kv, ran) {
 n = split(s, kv, ";")
 for (i = 1; i <= n; i++) {
  ran = kv[i]; sub(/:.*/, "", ran); sub(/^[^:]*:/, "", kv[i])
  if (ran ~ /^[01236]$/) cap[ran] = kv[i]
 }
}
function in_list(list, v,  n, i, p) {
 n = split(list, p, " ")
 for (i = 1; i <= n; i++) if (p[i] == v) return 1
 return 0
}
function sorted(list, out,  n, p, i, j, t, o) {
 n = split(list, p, " ")
 for (i = 1; i <= n; i++) for (j = i + 1; j <= n; j++) if (p[j] + 0 < p[i] + 0) { t = p[i]; p[i] = p[j]; p[j] = t }
 o = ""
 for (i = 1; i <= n; i++) if (p[i] != "" && (i == 1 || p[i] != p[i - 1])) o = o (o == "" ? "" : " ") p[i]
 return o
}
function arr_objs(list, prefix,  n, p, i, o) {
 n = split(list, p, " "); o = ""
 for (i = 1; i <= n; i++) o = o (i > 1 ? "," : "") "{\"band\":" p[i] (prefix != "" ? ",\"txt\":\"" prefix p[i] "\"" : "") "}"
 return o
}
function arr_nums(list,  n, p, i, o) {
 n = split(list, p, " "); o = ""
 for (i = 1; i <= n; i++) o = o (i > 1 ? "," : "") p[i]
 return o
}
# The user-facing GSM band number list (850/900/1800/1900...) for a RAN-1 id list.
function gsm_display(list,  n, p, i, m, seen, o) {
 n = split(list, p, " "); o = ""
 for (i = 1; i <= n; i++) { m = gsm_mhz(p[i]); if (m && !(m in seen)) { seen[m] = 1; o = o (o == "" ? "" : " ") m } }
 return sorted(o)
}
# Selected GSM display numbers -> the band ids this modem actually lists.
function gsm_ids(sel, avail,  n, p, i, j, a, na, o) {
 n = split(sel, p, " "); na = split(avail, a, " "); o = ""
 for (i = 1; i <= n; i++) for (j = 1; j <= na; j++) if (gsm_mhz(a[j]) == p[i] + 0) o = o (o == "" ? "" : ",") a[j]
 return o
}
function csv(list) { gsub(/ /, ",", list); return list }
function allowed_in(sel, avail,  n, p, i) {
 n = split(sel, p, " ")
 for (i = 1; i <= n; i++) if (p[i] !~ /^[0-9]+$/ || !in_list(avail, p[i])) return 0
 return n > 0
}

# Network type masks.
function g2mask() { return 1 + 2 + 32768 }
function g3mask() { return 4 + 128 + 256 + 512 + 16384 + 65536 }
function g4mask() { return 4096 + 262144 }
function nrmask() { return 524288 }

BEGIN {
 if (mode == "") mode = "json"
 parse_caps(caps)
}
/^SUB\|/ { sub_id = $0; sub(/^[^|]*\|/, "", sub_id); next }
/^WRITABLE\|/ { writable = ($0 == "WRITABLE|1"); have_writable = 1; next }
/^ALLOWED\|/ { allowed = $0; sub(/^[^|]*\|/, "", allowed); next }
/^RAT\|/ { rat = $0; sub(/^[^|]*\|/, "", rat); next }
/^BANDS_UNSUPPORTED\|/ { nobands = 1; next }
/^BANDS\|/ { split($0, f, "|"); live[f[2]] = f[3]; next }
/^ERROR\|/ { err = $0; sub(/^[^|]*\|/, "", err); next }
/^__5GM_RADIO_END__/ { complete = 1; next }

END {
 if (mode == "mask") {
  nr_ok = (cap[0] == "nobands") || (((6 in cap) ? cap[6] : live[6]) != "")
  if (want == 1) m = g2mask() + g3mask() + g4mask() + (nr_ok ? nrmask() : 0)
  else if (want == 8) m = g2mask()
  else if (want == 2) m = g3mask()
  else if (want == 4) m = g4mask()
  else if (want == 20 && nr_ok) m = g4mask() + nrmask()
  else exit 1
  print m; exit 0
 }
 if (mode == "bands") {
  out = ""; provided = 0; full = 0; needed = 0
  for (ran = 1; ran <= 6; ran++) if ((ran in cap) && cap[ran] != "") needed++
  if (sel_lte != "") {
   if (!allowed_in(sel_lte, (3 in cap) ? cap[3] : live[3])) exit 2
   out = out " 3=" csv(sorted(sel_lte)); provided++; if (sorted(sel_lte) == sorted(cap[3])) full++
  }
  if (sel_nsa != "") {
   if (!allowed_in(sel_nsa, (6 in cap) ? cap[6] : live[6])) exit 2
   out = out " 6=" csv(sorted(sel_nsa)); provided++; if (sorted(sel_nsa) == sorted(cap[6])) full++
  }
  if (sel_3g != "") {
   if (!allowed_in(sel_3g, (2 in cap) ? cap[2] : live[2])) exit 2
   out = out " 2=" csv(sorted(sel_3g)); provided++; if (sorted(sel_3g) == sorted(cap[2])) full++
  }
  if (sel_2g != "") {
   ids = gsm_ids(sel_2g, (1 in cap) ? cap[1] : live[1])
   if (ids == "") exit 2
   out = out " 1=" ids; provided++; if (sorted(sel_2g) == gsm_display(cap[1])) full++
  }
  # Selecting everything the modem offers is the default state: ask for a reset instead of writing the whole list.
  if (needed > 0 && provided == needed && full == provided) { print "RESET"; exit 0 }
  sub(/^ /, "", out); print out; exit 0
 }
 if (!complete) exit 1
 if (err != "") exit 1
 if (mode == "caps") {
  if (nobands) { print "0:nobands"; exit 0 }
  out = ""
  for (ran = 1; ran <= 6; ran++) if ((ran in live) && live[ran] != "") out = out (out == "" ? "" : ";") ran ":" sorted(live[ran])
  print out; exit (out == "" ? 1 : 0)
 }
 # json: supported = the cached modem list (or the live list when the cache is unknown); enabled = live within it.
 nb = (nobands || cap[0] == "nobands")
 for (ran = 1; ran <= 6; ran++) {
  sup[ran] = ((ran in cap) && cap[ran] != "") ? cap[ran] : live[ran]
  en[ran] = ""
  n = split(live[ran], p, " ")
  for (i = 1; i <= n; i++) if (in_list(sup[ran], p[i])) en[ran] = en[ran] (en[ran] == "" ? "" : " ") p[i]
  sup[ran] = sorted(sup[ran]); en[ran] = sorted(en[ran])
 }
 # network mode
 g2 = any(allowed, "1 2 32768"); g3 = any(allowed, "4 128 256 512 16384 65536"); g4 = any(allowed, "4096 262144"); nr = has(allowed, 524288)
 cur = ""
 if (allowed != "") {
  if (g2 && g3 && g4) cur = 1
  else if (g4 && nr && !g2 && !g3) cur = 20
  else if (g4 && !nr && !g2 && !g3) cur = 4
  else if (g2 && !g3 && !g4 && !nr) cur = 8
  else if (g3 && !g2 && !g4 && !nr) cur = 2
 }
 modes = "{\"id\":\"1\",\"label\":\"Auto\"}"
 if (nb || sup[1] != "") modes = modes ",{\"id\":\"8\",\"label\":\"2G\"}"
 if (nb || sup[2] != "") modes = modes ",{\"id\":\"2\",\"label\":\"3G\"}"
 modes = modes ",{\"id\":\"4\",\"label\":\"4G\"}"
 if (nb || sup[6] != "") modes = modes ",{\"id\":\"20\",\"label\":\"4G/5G\"}"
 printf "{\"modem\":\"%s\",\"source\":\"android\",\"subscription_id\":\"%s\",\"readonly\":%d,\"currentmode\":\"%s\",\"allowed_types\":\"%s\",\"modes\":[%s]", \
  str(model), str(sub_id), ((have_writable && !writable) ? 1 : 0), cur, allowed, modes
 printf ",\"supported\":[%s],\"enabled\":[%s]", arr_objs(sup[3], "B"), arr_nums(en[3])
 if (sup[2] != "") printf ",\"supported3g\":[%s],\"enabled3g\":[%s]", arr_objs(sup[2], ""), arr_nums(en[2])
 if (sup[1] != "") printf ",\"supported2g\":[%s],\"enabled2g\":[%s]", arr_objs(gsm_display(sup[1]), ""), arr_nums(gsm_display(en[1]))
 if (sup[6] != "") printf ",\"supported5gnsa\":[%s],\"enabled5gnsa\":[%s]", arr_objs(sup[6], "n"), arr_nums(en[6])
 if (nb) printf ",\"nobandctl\":1"
 print "}"
}
