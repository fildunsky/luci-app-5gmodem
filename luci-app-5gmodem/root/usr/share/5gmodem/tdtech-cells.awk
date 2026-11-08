function number(v) { return v ~ /^-?[0-9]+([.][0-9]+)?$/ }
function measure(v,lo,hi,invalid) {
	if (!number(v) || v == invalid) return ""
	if (v < lo || v > hi) v /= 8
	return (v >= lo && v <= hi) ? sprintf("%g",v) : ""
}
function hex(v, n,i,c) {
	v = toupper(v); sub(/^0X/,"",v)
	if (v !~ /^[0-9A-F]+$/ || length(v) > 3) return -1
	n = 0
	for (i=1;i<=length(v);i++) { c=index("0123456789ABCDEF",substr(v,i,1))-1; n=n*16+c }
	return n
}
function emit(rat,ch,pci,rp,rq,sn,rssi) {
	if (n >= 32) return
	if (ch !~ /^[0-9]+$/ || pci !~ /^[0-9]+$/ || pci > (rat == "NR" ? 1007 : 503)) return
	if (kind == "neighbors") {
		printf "%s{\"band\":\"\",\"rat\":\"%s\",\"earfcn\":\"%s\",\"pci\":\"%s\",\"rsrp\":\"%s\",\"rsrq\":\"%s\",\"sinr\":\"%s\",\"rssi\":\"%s\",\"serving\":0}", (n++ ? "," : ""),rat,ch,pci,rp,rq,sn,rssi
	} else printf "%s|%s|%s|%s|%s|%s|%s\n",rat,ch,pci,rp,rq,sn,rssi
}
{
	gsub(/[\r" ]/,"")
}
kind == "neighbors" && /^\^MONNC:LTE,/ && NF >= 7 {
	emit("LTE",$3,$4,measure($5,-144,-28,-1256),measure($6,-44,3,-348),"",measure($7,-130,0,32767))
}
kind == "neighbors" && /^\^MONNC:NR,/ && NF >= 7 {
	emit("NR",$3,hex($4),measure($5,-156,-31,-1256),measure($6,-43,20,-348),measure($7,-23,40,-188),"")
}
kind != "neighbors" && /^\^MONSSC:NR,/ && NF >= 7 {
	emit("NR",$3,hex($4),measure($5,-156,-31,-1256),measure($6,-43,20,-348),measure($7,-23,40,-188),"")
}
kind != "neighbors" && /^\^CASCELLINFO:/ && NF >= 13 {
	emit("LTE",$9,$3,measure($5,-144,-28,-1256),measure($6,-44,3,-348),"",measure($4,-130,0,32767))
}
