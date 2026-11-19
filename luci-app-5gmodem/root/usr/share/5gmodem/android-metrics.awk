function esc(s, i,c,out) {
 out=""
 for(i=1;i<=length(s);i++) {
  c=substr(s,i,1)
  if(c~/[[:cntrl:]]/) continue
  if(c=="\\" || c=="\"") out=out "\\"
  out=out c
 }
 return out
}
function str(k,v) { printf "%s\"%s\":\"%s\"", sep,k,esc(v); sep="," }
function val(s,k, t) {
 if (!match(s,"(^|[ {,:])" k "=")) return ""
 t=substr(s,RSTART+RLENGTH); sub(/[[:space:],}].*$/, "", t); sub(/\].*$/, "", t); return t
}
function num(v,lo,hi) { return v ~ /^-?[0-9]+([.][0-9]+)?$/ && v+0>=lo && v+0<=hi }
function operator(s, t) {
 if (!match(s,/mOperatorAlphaLong=/)) return ""
 t=substr(s,RSTART+RLENGTH); sub(/,.*/,"",t)
 if(t=="null") return ""
 return t
}
# The marketing name when the firmware has one (Xiaomi 17); otherwise the model code, with the maker in front of it
# ("Samsung SM-G991B") so that a list of uplinks says what the device is.
function device_name(  b) {
 if(market!="") return market
 b=brand; gsub(/^[[:space:]]+|[[:space:]]+$/,"",b)
 if(b=="" || b!~/^[A-Za-z0-9 ._-]+$/ || index(tolower(model),tolower(b))==1) return model
 return toupper(substr(b,1,1)) substr(b,2) " " model
}
function metric(k,v,lo,hi) { if(num(v,lo,hi)) str(k,v) }
function bandwidths(s, t,n,p,i,out) {
 if(!match(s,/mCellBandwidths=\[[0-9, ]*\]/)) return ""
 t=substr(s,RSTART+17,RLENGTH-18); n=split(t,p,/, */); out=""
 for(i=1;i<=n;i++) if(num(p[i],1,400000)) out=out (out=="" ? "" : " ") p[i]
 return out
}
function sim(i, l,n,s,p,r,t,b,j,records,count,band,widths,total) {
 str("slot",i); str("subscription_id",subid[i]); s=service[i]
 str("operator_name",operator(s))
 str("mcc",val(s,"mMcc")); str("mnc",val(s,"mMnc"))
 str("operator_mcc",val(s,"mMcc")); str("operator_mnc",val(s,"mMnc"))
 str("data_state",state[i])
 if(phone[subid[i]]!="") str("phone",phone[subid[i]])
 if(val(s,"isUsingCarrierAggregation")=="true") str("android_ca","1")
 else if(val(s,"isUsingCarrierAggregation")=="false") str("android_ca","0")
 t=s; sub(/^.*domain=PS transportType=WWAN /,"",t)
 if(t!=s) {
  r=val(t,"networkRegistrationState")
  str("registration",r=="HOME" ? "1" : r=="ROAMING" ? "5" : "0")
  str("mode",val(t,"accessNetworkTechnology"))
 }
 l=signal[i]
 if(val(t,"accessNetworkTechnology")=="LTE" && match(l,/mLte=CellSignalStrengthLte:/)) {
  l=substr(l,RSTART); sub(/,mNr=.*/,"",l)
  metric("rssi",val(l,"rssi"),-113,-51); metric("rsrp",val(l,"rsrp"),-140,-43)
  b=val(l,"rssi"); if(num(b,-113,-51)) { str("csq",int((b+113)/2)); str("csq_source","rssi") }
  metric("rsrq",val(l,"rsrq"),-34,3); metric("sinr",val(l,"rssnr"),-20,30)
  n=val(l,"level"); if(num(n,0,4)) str("signal",n*25)
  n=val(l,"ta"); if(num(n,0,1282)) { str("ta",n); if(n+0>0) str("bs_distance",int(n*78.125+0.5)) }
  metric("cqi",val(l,"cqi"),0,15)
 }
 widths=bandwidths(s)
 if(val(s,"isUsingCarrierAggregation")=="true" && widths!="") {
  count=split(widths,records," "); total=0
  for(j=1;j<=count;j++) total+=records[j]
  if(count>1) { str("android_ca_carriers",count); str("android_ca_bandwidth",total/1000) }
 }
 if(val(t,"accessNetworkTechnology")=="LTE") {
  metric("earfcn",val(s,"mChannelNumber"),0,262143)
  p=physical[i]
  if(match(p,/mConnectionStatus=PrimaryServing/)) {
   p=substr(p,RSTART); sub(/\}.*/,"",p)
   metric("pci",val(p,"mPhysicalCellId"),0,503)
   b=val(p,"mCellBandwidthDownlinkKhz")
   if(num(b,1,20000)) str("bandwidth",b/1000)
  }
  count=0
  n=split(physical[i],records,/\{/)
  for(j=2;j<=n;j++) {
   p=records[j]
   if(val(p,"mConnectionStatus")!="SecondaryServing" || val(p,"mNetworkType")!="LTE" || count>=4) continue
   count++; band=val(p,"mBand"); b=val(p,"mCellBandwidthDownlinkKhz")
   if(num(band,1,256)) str("s" count "band","B" band (num(b,1,20000) ? " @" b/1000 "MHz" : ""))
   b=val(p,"mDownlinkChannelNumber"); if(num(b,1,262143)) str("s" count "earfcn",b)
   metric("s" count "pci",val(p,"mPhysicalCellId"),0,503)
   str("s" count "state","activated")
  }
 }
}
function legacy_lte_cells(  cells, valid, cell, stamp, age, pci, ci, tac, count, serving, i, n, asu) {
 n=split(legacy_cells,cells,/CellInfoLte:/)
 for(i=2;i<=n && count<16;i++) {
  cell=cells[i]; stamp=val(cell,"mTimeStamp"); sub(/ns$/,"",stamp)
  if(!num(stamp,1,9999999999999999) || !num(legacy_uptime,0,99999999)) continue
  age=legacy_uptime-stamp/1000000000
  pci=val(cell,"mPci")
  if(age< -1 || age>20 || !num(pci,0,503)) continue
  valid[++count]=cell
  if(!serving && val(cell,"mRegistered")=="YES") serving=count
 }
 if(!serving) return ""
 cell=valid[serving]
 ci=val(cell,"mCi")
 if(num(legacy_web["cid"],1,268435455) && ci!=legacy_web["cid"]) return ""
 str("android_cell_source","radio_log")
 metric("pci",val(cell,"mPci"),0,503)
 tac=val(cell,"mTac")
 if(num(tac,0,65535)) {
  str("tac_dec",tac); str("tac_hex",sprintf("%X",tac)); str("tac_d",tac); str("tac_h",sprintf("%X",tac))
 }
 printf ",\"neighbors\":["
 for(i=1;i<=count;i++) {
  cell=valid[i]
  printf "%s{",i==1 ? "" : ","; sep=""
  str("serving",i==serving ? "1" : "0")
  str("pci",val(cell,"mPci"))
  metric("rsrp",val(cell,"rsrp"),-140,-44); metric("rsrq",val(cell,"rsrq"),-34,-3)
  asu=val(cell,"ss"); if(num(asu,0,31)) str("rssi",2*asu-113)
  printf "}"
 }
 printf "]"; sep=","
 return ci
}
function legacy_json(  fields, report, asu, csq, sinr, temps, ci, iccid, slot, slots, i, n) {
 if(legacy[1]!="msm8916" || legacy[2]!="19" || legacy_signal=="") return 0
 report=legacy_signal; sub(/^.*SignalStrength:[[:space:]]*/,"",report)
 n=split(report,fields,/[[:space:]]+/)
 printf "{"; sep=""
 str("backend","android"); str("protocol","Android (ADB)"); str("no_at","1")
 if(legacy_web_ready) { printf "%s\"msm_web\":true",sep; sep="," }
 slot=legacy_web["slot"]
 slots=legacy_web["slots"]; if(slots!~/^[123]$/) slots=0
 str("android_adb","ready")
 if(slot~/^[012]$/ && (!slots || slot<slots)) {
  str("android_slot",slot); str("simslot","SIM " (slot+1))
 } else slot=-1
 str("android_sim_switch",slot>=0 && slots>1 && legacy_web["simlock"]=="false" ? "1" : "0")
 str("path",path); str("vidpid",vidpid); str("onbus","1"); str("age","0")
 str("modem","MSM8916"); str("firmware",legacy[3])
 if(slot>=0 && slots>1) {
  printf ",\"android_sims\":["
  for(i=0;i<slots;i++) {
   printf "%s{",i==0 ? "" : ","; sep=""
   str("slot",i)
   if(i==slot) str("sim_state",legacy[4]=="READY" ? "ready" : legacy[4]=="ABSENT" ? "absent" : "unknown")
   printf "}"
  }
  printf "]"; sep=","
 }
 str("iface",iface); str("ipaddr",ip); str("netdev",netdev)
 str("tether","android"); str("tether_state",netdev!="" ? "ready" : "no_netdev")
 str("sampled_at",sampled_at); str("data_state",legacy_data)
 str("mode",legacy[5]); str("operator_name",legacy[6])
 if(legacy[7]~/^[0-9]+$/ && length(legacy[7])>=5 && length(legacy[7])<=6) {
  str("operator_mcc",substr(legacy[7],1,3)); str("operator_mnc",substr(legacy[7],4))
 }
 if(legacy[4]=="ABSENT") { str("registration","SIM not inserted"); str("sim_state","absent") }
 else if(legacy[4]=="READY") {
  str("sim_state","ready")
  if(legacy_reg ~ /^[0-9]+ 0 (home|roaming) /) str("registration",legacy_reg ~ /^[0-9]+ 0 roaming / ? "5" : "1")
 }
 else if(legacy[4]~/^(PIN|PUK)_REQUIRED$/) str("sim_state","locked")
 if(legacy[5]=="LTE") {
  for(i=1;i<=12 && fields[i]~/^-?[0-9]+$/;i++) {}
  if(n>=12 && i==13) {
   asu=fields[8]; metric("rsrp",fields[9],-140,-44); metric("rsrq",fields[10],-34,-3)
   sinr=fields[11]; if(num(sinr,-200,300)) str("sinr",sinr/10)
   metric("cqi",fields[12],0,15)
  }
  if(legacy[4]=="READY") {
   ci=legacy_lte_cells()
   if(!num(ci,1,268435455)) ci=legacy_web["cid"]
   if(num(ci,1,268435455) && ci~/^[0-9]+$/) {
    str("cid_dec",ci); str("cid_hex",sprintf("%X",ci)); str("enbid",int(ci/256))
   }
  }
 } else if(legacy[5]~/^(GPRS|EDGE|UMTS|HSDPA|HSUPA|HSPA|HSPA[+])$/) {
  asu=fields[1]
 }
 if(num(asu,0,31)) { csq=asu+0; str("csq",csq); str("csq_source","rssi"); str("rssi",2*csq-113); str("signal",int(csq*100/31+0.5)) }
 if(legacy_web["IMEI"]~/^[0-9]+$/ && length(legacy_web["IMEI"])==15) str("imei",legacy_web["IMEI"])
 if(legacy[4]=="READY") {
  if(legacy_web["IMSI"]~/^[0-9]+$/ && length(legacy_web["IMSI"])==15) str("imsi",legacy_web["IMSI"])
  iccid=legacy_web["ICCID"]; sub(/[Ff]$/,"",iccid)
  if(iccid~/^[0-9]+$/ && length(iccid)>=18 && length(iccid)<=22) str("iccid",iccid)
 }
 metric("battery",battery,0,100)
 str("battery_charging",charging)
 if(bat!="") temps="bat=" bat
 if(legacy_cpu!="") temps=temps (temps=="" ? "" : " ") "cpu=" legacy_cpu
 if(legacy_pmic!="") temps=temps (temps=="" ? "" : " ") "pmic=" legacy_pmic
 if(temps!="") str("temps",temps)
 print "}"
 return 1
}
/^__5GM_/ { section=$0; line=0; next }
section=="__5GM_LEGACY__" {
 line++
 if(line<=7) legacy[line]=$0
 else if(/^[[:space:]]*mSignalStrength=SignalStrength:/) legacy_signal=$0
 else if(/^[[:space:]]*mDataConnectionState=/) { legacy_data=$0; sub(/^.*=/,"",legacy_data) }
 else if(/^[[:space:]]*mServiceState=/) { legacy_reg=$0; sub(/^[^=]*=/,"",legacy_reg) }
 else if($1=="level:" && num($2,0,100)) battery=$2
 else if($1=="temperature:" && num($2,-400,1000)) bat=$2/10
 else if($1=="status:") charging=($2==2 ? "1" : "0")
 next
}
section=="__5GM_LEGACY_THERMAL__" {
 if($1~/^tsens_tz_sensor[0-9]+$/ && num($2,-40,125) && (legacy_cpu=="" || $2+0>legacy_cpu)) legacy_cpu=$2+0
 if($1=="pm8916_tz" && num($2,-40000,125000)) legacy_pmic=$2/1000
 next
}
section=="__5GM_LEGACY_WEB__" {
 if(++line==1) legacy_web_ready=($0=="web 1")
 else if(legacy_web_ready) legacy_web[$1]=$2
 next
}
section=="__5GM_LEGACY_CELLS__" {
 if(++line==1) legacy_uptime=$1
 else if(/< RIL_REQUEST_GET_CELL_INFO_LIST \[/) legacy_cells=$0
 next
}
section=="__5GM_DEVICE__" {
 line++; if(line==1) market=$0; if(line==2) model=$0; if(line==3) firmware=$0; if(line==4) baseband=$0; if(line==5) brand=$0; next
}
section=="__5GM_REGISTRY__" {
 if($0~/^  Phone Id=[0-9]+/) { slot=$0; sub(/^.*=/,"",slot); slot+=0; seen[slot]=1 }
 if($0~/^    mServiceState=/) service[slot]=$0
 if($0~/^    mSignalStrength=/) signal[slot]=$0
 if($0~/^    mPhysicalChannelConfigs=/) physical[slot]=$0
 if($0~/^    mDataConnectionState=/) state[slot]=val($0,"mDataConnectionState")
 if($0~/^  mActiveDataSubId=/) active=val($0,"mActiveDataSubId")
 next
}
section=="__5GM_SUBS__" && /Logical SIM slot [0-9]+: subId=[0-9]+/ {
 s=$0; sub(/^.*Logical SIM slot /,"",s); split(s,a,":"); subid[a[1]]=val($0,"subId"); next
}
section=="__5GM_NUMBERS__" && $1~/^[0-9]+$/ && $2~/^\+?[0-9]+$/ && length($2)>=4 && length($2)<=20 { phone[$1]=$2; next }
section=="__5GM_BATTERY__" {
 if($1=="voltage:" && num($2,2000,6000)) bat_mv=$2
 if($1=="health:" && $2~/^[1-7]$/) bat_health=$2
 if($1=="temperature:" && num($2,-400,1000)) bat=$2/10
 if($1=="level:" && num($2,0,100)) battery=$2
 if($1=="status:") charging=($2==2 ? "1" : "0")
 next
}
section=="__5GM_SENSORS__" {
 name=$1
 if(name!~/^[A-Za-z0-9_.-]+$/ || name~/(hw.trip|bcl|ibat|vbat)/ || !num($2,-40000,150000)) next
 t=$2/1000
 if(!(name in sensors)) sensor_order[++sensor_count]=name
 sensors[name]=t
 if(name~/^mdmss[-_]/ && (modem_temp=="" || t>modem_temp)) modem_temp=t
 if(name~/^gpuss-/ && (gpu=="" || t>gpu)) gpu=t
 if(name~/^pa_therm/ && (pa=="" || t>pa)) pa=t
 if(name~/^pm.*_tz$/ && (pmic=="" || t>pmic)) pmic=t
 if(name=="wifi_therm") wifi=t
 if(name=="charger_therm") charger=t
 if(name=="quiet_therm") board=t
 next
}
section=="__5GM_THERMAL__" {
 if($1=="Thermal" && $2=="Status:" && $3~/^[0-6]$/) thermal=$3
 if(/Current temperatures from HAL:/) current=1
 else if(current && !/^[[:space:]]*Temperature\{/) current=0
 if(current && /Temperature\{/) {
  s=$0; sub(/^.*Temperature\{/,"",s); t=val(s,"mValue"); type=val(s,"mType"); name=val(s,"mName")
  if(num(t,-40,150)) {
   if(type==0 && (name~/^CPU[0-9]+$/ || name=="AP") && (cpu=="" || t+0>cpu+0)) cpu=t
   if(type==3 && tolower(name)=="skin") skin=t
   if(type==5 && (hal_pa=="" || t+0>hal_pa+0)) hal_pa=t
  }
 }
 next
}
section=="__5GM_TETHER__" && /Current upstream interface\(s\):/ {
 upstream=$0; sub(/^.*\[/,"",upstream); sub(/\].*$/,"",upstream)
}
section=="__5GM_DATA__" && /InterfaceName: / {
 d=$0; ifn=d; sub(/^.*InterfaceName: /,"",ifn); sub(/[ ,].*$/,"",ifn)
 x=""; if(match(d,/extra: [^}]*\}/)) x=substr(d,RSTART+7,RLENGTH-8)
 addrs=""; if(match(d,/LinkAddresses: \[[^]]*\]/)) addrs=substr(d,RSTART+16,RLENGTH-17)
 if(ifn ~ /^[A-Za-z0-9_.-]+$/) { apn_of[ifn]=x; addr_of[ifn]=addrs }
 next
}
END {
 if(section!="__5GM_END__") exit 1
 if(1 in legacy) { if(legacy_json()) exit 0; exit 1 }
 chosen=""
 for(i in seen) if(active!="" && subid[i]==active) chosen=i
 if(chosen=="" || signal[chosen]=="") exit 1
 printf "{"; sep=""
 str("backend","android"); str("protocol","Android (ADB)"); str("no_at","1"); str("age","0")
 str("path",path); str("vidpid",vidpid); str("onbus","1")
 fw=baseband
 n=split(baseband,parts,",")
 if(n>=2) { fw=parts[1]; for(i=2;i<=n;i++) if(parts[i]!=parts[1]) fw=fw " / " parts[i] }
 str("modem",device_name()); str("firmware",fw!="" ? fw : firmware)
 if(fw!="" && firmware!="") str("android_build",firmware)
 str("iface",iface); str("ipaddr",ip); str("netdev",netdev)
 str("tether","android"); str("tether_state",netdev!="" ? "ready" : "no_netdev")
 str("android_adb","ready"); str("android_upstream",upstream); str("sampled_at",sampled_at)
 str("android_data_subscription",active); str("android_slot",chosen)
 str("simslot","SIM " chosen+1)
 sim(chosen)
 if(pa=="" && hal_pa!="") pa=hal_pa
 temps=""; if(bat!="") temps="bat=" bat
 if(cpu!="") temps=temps " cpu=" cpu
 if(skin!="") temps=temps " skin=" skin
 if(modem_temp!="") { temps=temps " modem=" modem_temp; str("mtemp",modem_temp " &deg;C") }
 if(gpu!="") temps=temps " gpu=" gpu
 if(pa!="") temps=temps " pa=" pa
 if(pmic!="") temps=temps " pmic=" pmic
 if(wifi!="") temps=temps " wifi=" wifi
 if(charger!="") temps=temps " charger=" charger
 if(board!="") temps=temps " board=" board
 str("temps",temps); metric("battery",battery,0,100); str("battery_charging",charging)
 if(bat_mv!="") str("battery_voltage",bat_mv)
 if(bat_health!="") str("battery_health",bat_health)
 if(thermal!="") str("thermal_status",thermal)
 iface_now=upstream; sub(/,.*$/,"",iface_now); gsub(/[[:space:]]/,"",iface_now)
 if(iface_now in apn_of) {
  if(apn_of[iface_now] ~ /^[A-Za-z0-9._-]{1,63}$/ && toupper(apn_of[iface_now])!="IMS") str("iface_apn",apn_of[iface_now])
  addrs=addr_of[iface_now]; v4=(addrs ~ /[0-9]+[.][0-9]+[.][0-9]+[.][0-9]+\//); v6=0
  n=split(addrs,parts,/, */)
  for(i=1;i<=n;i++) if(parts[i] ~ /:/ && parts[i] !~ /^fe80:/) v6=1
  if(v4 && v6) str("iface_pdptype","ipv4v6"); else if(v4) str("iface_pdptype","ipv4"); else if(v6) str("iface_pdptype","ipv6")
 }
 printf ",\"temperature_sensors\":["
 for(j=1;j<=sensor_count;j++) { name=sensor_order[j]; printf "%s{\"name\":\"%s\",\"value\":%s}",(j>1 ? "," : ""),esc(name),sensors[name] }
 printf "]"
 printf ",\"android_sims\":["; comma=""
 for(i=0;i<8;i++) if(i in seen) { printf "%s{",comma; sep=""; sim(i); printf "}"; comma="," }
 print "]}"
}
