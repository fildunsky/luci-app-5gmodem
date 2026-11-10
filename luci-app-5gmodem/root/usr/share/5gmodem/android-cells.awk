BEGIN { FS="|" }
function valid(v,lo,hi) { return v~/^[0-9]+$/ && v+0>=lo && v+0<=hi }
function str(k,v) { printf "%s\"%s\":\"%s\"",sep,k,v; sep="," }
function metric(k,v,lo,hi) { if(v~/^-?[0-9]+$/ && v+0>=lo && v+0<=hi) str(k,v) }
function matches(pci,ear) {
 return (wanted_pci=="" || wanted_pci==pci) && (wanted_ear=="" || wanted_ear==ear)
}
$1=="META" { now=$2; wanted_pci=$3; wanted_ear=$4; next }
$1=="IDENTITY" {
 if($2~/^[0-9]+$/ && length($2)>=5 && length($2)<=16) imsi=$2
 if($3~/^[0-9A-Fa-f]+$/ && length($3)>=10 && length($3)<=22) iccid=$3
 if($4~/^[0-9]+$/ && length($4)>=14 && length($4)<=17) imei=$4
 next
}
$1=="IMS" {
 if($2=="true" || $2=="false") volte=($2=="true" ? "1" : "0")
 if($3=="true" || $3=="false") wfc=($3=="true" ? "1" : "0")
 next
}
# 5G NR cell: only a fresh cell that is registered or reported as a serving cell is used.
$1=="CELL" && $4=="CellIdentityNr" {
 if(!valid($3,1,9999999999999999)) next
 age=(now-$3/1000000)/1000
 if(age<0 || age>30) next
 if($2!="true" && $21!~/^[12]$/) next
 if(!valid($9,0,1007) || !valid($16,0,3279165)) next
 nr_found=1; nr_pci=$9; nr_arfcn=$16; nr_band=$11; nr_rsrp=$18; nr_rsrq=$19; nr_sinr=$20; nr_age=age
 next
}
$1=="CAPABILITY" { if($2=="true" || $2=="false") { can_switch=($2=="true" ? "1" : "0"); capability=1 } }
$1=="SERVICE" {
 if($2=="CellIdentityLte" && matches($7,$8)) { rat="LTE"; ci=$3; tac=$5; primary=1 }
 else if(($2=="CellIdentityGsm" || $2=="CellIdentityWcdma" || $2=="CellIdentityTdscdma") && wanted_ear=="") { rat="3G"; ci=$4; lac=$6; primary=1 }
 next
}
$1=="CELL" {
 if($4!="CellIdentityLte" || !valid($3,1,9999999999999999)) next
 age=(now-$3/1000000)/1000
 if(age<0 || age>30) next
 if($2=="true" && !matches($9,$10)) next
 if(!valid($9,0,503) || !valid($10,0,262143)) next
 n++; serving[n]=($2=="true" ? "1" : "0"); pci[n]=$9; ear[n]=$10; band[n]=$11
 rssi[n]=$12; rsrp[n]=$13; rsrq[n]=$14; sinr[n]=$15; ages[n]=age
 if($2=="true") {
  primary=1; rat="LTE"; primary_age=age
  if(valid($5,0,268435455)) ci=$5
  if(valid($7,0,65535)) tac=$7
 }
}
END {
 if(!primary && imsi=="" && iccid=="" && imei=="" && !capability && volte=="" && !nr_found) exit 1
 if(!primary) { ci=""; tac=""; lac=""; n=0 }
 printf "{"; sep=""; str("android_cell_source",primary ? "telephony_api" : "identity_api")
 if(imsi!="") str("imsi",imsi)
 if(iccid!="") str("iccid",iccid)
 if(imei!="") str("imei",imei)
 if(capability) str("android_sim_switch",can_switch)
 if(volte!="") str("volte",volte)
 if(wfc!="") str("android_wfc",wfc)
 if(nr_found) {
  if(valid(nr_band,1,512)) str("nr_band","n" nr_band)
  str("nr_arfcn",nr_arfcn); str("nr_pci",nr_pci); str("nr_age",sprintf("%.1f",nr_age))
  metric("nr_rsrp",nr_rsrp,-156,-31); metric("nr_rsrq",nr_rsrq,-43,20); metric("nr_sinr",nr_sinr,-23,40)
 }
 if(valid(ci,0,268435455)) { str("cid_dec",ci); str("cid_hex",sprintf("%X",ci)); if(rat=="LTE") str("enbid",int(ci/256)) }
 if(rat=="LTE" && valid(tac,0,65535)) { str("tac_dec",tac); str("tac_hex",sprintf("%X",tac)); str("tac_d",tac); str("tac_h",sprintf("%X",tac)) }
 if(rat!="LTE" && valid(lac,0,65535)) { str("lac_dec",lac); str("lac_hex",sprintf("%X",lac)) }
 if(primary_age!="") str("android_cell_age",sprintf("%.1f",primary_age))
 printf ",\"neighbors\":["
 for(i=1;i<=n;i++) {
  printf "%s{",(i>1 ? "," : ""); sep=""
  str("serving",serving[i]); str("pci",pci[i]); str("earfcn",ear[i])
  if(valid(band[i],1,256)) str("band",band[i])
  metric("rssi",rssi[i],-113,-51); metric("rsrp",rsrp[i],-140,-43)
  metric("rsrq",rsrq[i],-34,3); metric("sinr",sinr[i],-20,30)
  str("age",sprintf("%.1f",ages[i])); printf "}"
 }
 print "]}"
}
