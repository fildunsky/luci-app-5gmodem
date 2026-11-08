function hex(s,    i,n,c) {
	n=0
	for(i=1;i<=length(s);i++) { c=index("0123456789ABCDEF",substr(s,i,1))-1; if(c<0) { bad=1; return 0 }; n=n*16+c }
	return n
}
function utf(c) {
	if(c<32 || c==127 || c>=55296 && c<=57343 || c>=65534) { bad=1; return "" }
	if(c<128) return sprintf("%c",c)
	if(c<2048) return sprintf("%c%c",192+int(c/64),128+c%64)
	return sprintf("%c%c%c",224+int(c/4096),128+int(c/64)%64,128+c%64)
}
function gsm(c,    n) {
	if(c==27) {
		if(pos>end) { bad=1; return "" }
		n=b[pos++]
		if(!(n in ext)) { bad=1; return "" }
		return utf(ext[n])
	}
	if(c<32) return utf(low[c+1])
	if(c in special) return utf(special[c])
	return utf(c)
}
BEGIN {
	split("64 163 36 165 232 233 249 236 242 199 10 216 248 13 197 229 916 95 934 915 923 937 928 936 931 920 926 27 198 230 223 201",low," ")
	special[36]=164;special[64]=161;special[91]=196;special[92]=214;special[93]=209;special[94]=220;special[95]=167;special[96]=191;special[123]=228;special[124]=246;special[125]=241;special[126]=252;special[127]=224
	ext[20]=94;ext[40]=123;ext[41]=125;ext[47]=92;ext[60]=91;ext[61]=126;ext[62]=93;ext[64]=124;ext[101]=8364
}
{
	h=toupper($0)
	if(h !~ /^[0-9A-F]+$/ || length(h)%2 || length(h)<4) exit
	n=length(h)/2
	for(i=1;i<=n;i++) b[i]=hex(substr(h,2*i-1,2))
	pos=2;end=n;out=""
	if(b[pos]==128) {
		pos++
		while(pos<=end) {
			if(b[pos]==255 && (pos==end || b[pos+1]==255)) break
			if(pos+1>end) { bad=1; break }
			out=out utf(b[pos]*256+b[pos+1]);pos+=2
		}
	} else {
		base=0; compressed=0
		if(b[pos]==129 || b[pos]==130) {
			mode=b[pos++];count=b[pos++]
			if(mode==129) base=b[pos++]*128
			else { base=b[pos]*256+b[pos+1];pos+=2 }
			end=pos+count-1;compressed=1
			if(end>n || pos>n+1) bad=1
		}
		while(!bad && pos<=end) {
			c=b[pos++]
			if(!compressed && c==255) break
			if(c>=128) {
				if(!compressed) { bad=1; break }
				out=out utf(base+c-128)
			} else out=out gsm(c)
		}
	}
	if(!bad) { sub(/^ +/,"",out);sub(/ +$/,"",out);printf "%s",out }
	exit
}
