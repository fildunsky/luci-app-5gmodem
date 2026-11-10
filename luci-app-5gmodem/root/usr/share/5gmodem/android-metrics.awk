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
 t=substr(s,RSTART+RLENGTH); sub(/,.*/,"",t); return t
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
/^__5GM_/ { section=$0; line=0; next }
section=="__5GM_DEVICE__" {
 line++; if(line==1) market=$0; if(line==2) model=$0; if(line==3) firmware=$0; if(line==4) baseband=$0; next
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
   if(type==0 && name~/^CPU[0-9]+$/ && (cpu=="" || t+0>cpu+0)) cpu=t
   if(type==3 && name=="skin") skin=t
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
 chosen=""
 for(i in seen) if(active!="" && subid[i]==active) chosen=i
 if(chosen=="" || signal[chosen]=="") exit 1
 printf "{"; sep=""
 str("backend","android"); str("protocol","Android (ADB)"); str("no_at","1"); str("age","0")
 str("path",path); str("vidpid",vidpid); str("onbus","1")
 fw=baseband
 n=split(baseband,parts,",")
 if(n>=2) { fw=parts[1]; for(i=2;i<=n;i++) if(parts[i]!=parts[1]) fw=fw " / " parts[i] }
 str("modem",market!="" ? market : model); str("firmware",fw!="" ? fw : firmware)
 if(fw!="" && firmware!="") str("android_build",firmware)
 str("iface",iface); str("ipaddr",ip); str("netdev",netdev)
 str("tether","android"); str("tether_state",netdev!="" ? "ready" : "no_netdev")
 str("android_adb","ready"); str("android_upstream",upstream); str("sampled_at",sampled_at)
 str("android_data_subscription",active); str("android_slot",chosen)
 str("simslot","SIM " chosen+1)
 sim(chosen)
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
