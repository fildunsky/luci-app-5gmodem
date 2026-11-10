function esc(s, i,c,out) {
 out=""
 for(i=1;i<=length(s);i++) {
  c=substr(s,i,1)
  if(c=="\\" || c=="\"") out=out "\\" c
  else if(c=="\n") out=out "\\n"
  else if(c=="\r") out=out "\\r"
  else if(c=="\t") out=out "\\t"
  else if(c~/[[:cntrl:]]/) out=out " "
  else out=out c
 }
 return out
}
function unhex(s, i,a,b,out) {
 out=""; s=toupper(s)
 for(i=1;i<=length(s);i+=2) {
  a=index("0123456789ABCDEF",substr(s,i,1))-1
  b=index("0123456789ABCDEF",substr(s,i+1,1))-1
  out=out sprintf("%c",a*16+b)
 }
 return out
}
/^Row: [0-9]+ / {
 s=$0; sub(/^Row: [0-9]+ /,"",s); sub(/\r$/,"",s)
 delete fields
 n=split(s,parts,/, /)
 for(i=1;i<=n;i++) {
  p=index(parts[i],"="); if(p) fields[substr(parts[i],1,p-1)]=substr(parts[i],p+1)
 }
 id=fields["_id"]; read=fields["read"]
 if(id!~/^[0-9]+$/ || (id in seen) || read!~/^[01]$/) { bad=1; next }
 seen[id]=1; used++; if(read==0) unread++
 viewed=fields["seen"]; if(viewed!~/^[01]$/) viewed=read
 if(read==0 && viewed==0) unseen++
 if(count_only) next
 date=fields["date"]; sender=fields["address_hex"]; body=fields["body_hex"]
 if(sender=="null") sender=""
 if(body=="null") body=""
 if(date!~/^[0-9]+$/ || sender~/[^0-9A-Fa-f]/ || body~/[^0-9A-Fa-f]/ || length(sender)%2 || length(body)%2) { bad=1; next }
 rows[++messages]="{\"index\":" id ",\"sender\":\"" esc(unhex(sender)) "\",\"timestamp\":\"" strftime("%Y-%m-%d %H:%M",int(date/1000)) "\",\"reference\":0,\"part\":1,\"total\":1,\"content\":\"" esc(unhex(body)) "\",\"android_seen\":" viewed ",\"android_read\":" read ",\"read\":" read ",\"subscription_id\":\"" esc(fields["sub_id"]) "\"}"
 next
}
/^No result found\./ { next }
/^__5GM_SMS_END__/ { complete=1; next }
/[^[:space:]]/ { bad=1 }
END {
 if(!complete || bad) { print "{\"error\":\"Android SMS query failed\",\"read_only\":true}"; exit 1 }
 if(count_only) { printf "{\"used\":%d,\"unread\":%d,\"unseen\":%d,\"read_only\":true}\n",used,unread,unseen; exit }
 printf "{\"read_only\":true,\"msg\":["
 for(i=1;i<=messages;i++) printf "%s%s",(i>1 ? "," : ""),rows[i]
 print "]}"
}
