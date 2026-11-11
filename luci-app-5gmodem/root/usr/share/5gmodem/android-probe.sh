#!/system/bin/sh

printf "__5GM_DEVICE__\n"
getprop ro.product.marketname
getprop ro.product.model
getprop ro.build.version.incremental
getprop gsm.version.baseband
getprop ro.product.manufacturer
printf "__5GM_REGISTRY__\n"
dumpsys telephony.registry
printf "__5GM_SUBS__\n"
_subs=$(dumpsys isub | sed -n "/Logical SIM slot [0-9]/p")
printf "%s\n" "$_subs"
printf "__5GM_NUMBERS__\n"
printf "%s\n" "$_subs" | while IFS= read -r _line; do
_sub=${_line##*subId=}
case "$_sub" in ""|*[!0-9]*) continue ;; esac
for _source in 1 2 3 4; do
_number=$(cmd phone get-phone-number "$_sub" "$_source" 2>/dev/null | grep -E "^\+?[0-9][0-9 ()-]{3,20}$" | head -1 | tr -d " ()\r-")
[ -n "$_number" ] && { printf "%s %s\n" "$_sub" "$_number"; break; }
done
done
printf "__5GM_BATTERY__\n"
dumpsys battery
printf "__5GM_THERMAL__\n"
dumpsys thermalservice
printf "__5GM_SENSORS__\n"
for _zone in /sys/class/thermal/thermal_zone*; do
{ read -r _name < "$_zone/type"; } 2>/dev/null || continue
{ read -r _temp < "$_zone/temp"; } 2>/dev/null || continue
printf "%s %s\n" "$_name" "$_temp"
done
printf "__5GM_TETHER__\n"
dumpsys tethering | grep "Current upstream interface(s):"
printf "__5GM_DATA__\n"
dumpsys connectivity | grep -E "NetworkAgentInfo[{].*MOBILE" | sed -E "s/ (DnsAddresses|Domains|Routes|MTU|ServerAddress|TcpBufferSizes|Wakeup)[^ ]*.*//" | cut -c1-500
printf "__5GM_END__\n"
