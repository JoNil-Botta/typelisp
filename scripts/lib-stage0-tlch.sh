# Account deployment envelopes directly from the linked binary. Marker literals
# are ignored unless their bounded headers describe a frame. A recognized v2
# index must then pass its complete structural/hash checks.
scan_stage0_tlch() {
    _tlch_size=$(wc -c < "$1" | tr -d ' ') || return 1
    od -An -v -tu1 "$1" | awk -v binary_size="$_tlch_size" '
BEGIN {
    split("95 95 116 121 112 101 108 105 115 112 95 101 109 98 101 100 100 101 100 95 115 116 100 108 105 98 95 116 108 99 104 95 118 49 95 95", prefix)
    mode="scan"; matched=0; position=0
}
function fail(message) {
    print "TLCH scanner: " message > "/dev/stderr"
    bad=1; exit 1
}
function reset() { mode="scan"; matched=0 }
function word(offset,    i,value) {
    value=0
    for (i=0;i<8;i++) value+=index_bytes[offset+i]*(2^(8*i))
    return value
}
function finish() {
    payloads++; raw_total+=raw; bitstream_total+=bit_bytes; static_total+=total
    reset()
}
function check_index(    count,i,r,name,nlen,body,expanded,bits,bytes,names,previous,previous_len,j,order,sum,cursor,hash) {
    count=word(52); names=4437+48*count; cursor=index_end; sum=0
    hash=1
    for (i=0;i<index_end;i++) hash=(hash*131+((i>=60 && i<68)?0:index_bytes[i]))%2147483647
    if (hash!=word(60)) fail("v2 index hash mismatch")
    for (i=0;i<count;i++) {
        r=4437+i*48; name=word(r); nlen=word(r+8); body=word(r+16)
        expanded=word(r+24); bits=word(r+32)
        if (word(r+40)>2147483647) fail("v2 invalid frame checksum")
        if (name!=names || nlen<0 || nlen>index_end-names ||
            (i==0 ? nlen!=0 : nlen==0) || expanded<176 ||
            expanded>268435456-sum || body!=cursor || bits<=0 ||
            bits>8*(binary_size-start-cursor)) fail("v2 invalid frame bounds")
        if (i>1) {
            order=0
            for (j=0;j<nlen && j<previous_len && order==0;j++)
                order=index_bytes[previous+j]-index_bytes[name+j]
            if (order==0) order=previous_len-nlen
            if (order>=0) fail("v2 unsorted or duplicate identity")
        }
        bytes=int(bits/8)+(bits%8!=0)
        cursor+=bytes; ends[i]=cursor-1; padding[i]=bits%8
        sum+=expanded; names+=nlen; previous=name; previous_len=nlen
    }
    if (names!=index_end || sum!=raw || cursor>binary_size-start)
        fail("v2 inconsistent index length")
    total=cursor; bit_bytes=cursor-index_end; remaining=bit_bytes; frame=0
}
{
    for (field=1;field<=NF;field++) {
        byte=$field+0
        if (mode=="scan") {
            if (byte==prefix[matched+1] || (matched==33 && byte==50)) {
                if (matched==33) version=byte-48
                matched++
            } else if (byte==prefix[1]) matched=1
            else matched=0
            if (matched==36) {
                start=position-35; relative=36; mode="header"
                for (i=0;i<36;i++) index_bytes[i]=prefix[i+1]
                index_bytes[33]=48+version
            }
        } else if (mode=="header") {
            index_bytes[relative++]=byte
            header_end=(version==1?52:68)
            if (relative==header_end) {
                raw=word(36)
                if (version==1) {
                    bits=word(44); bit_bytes=int(bits/8)+(bits%8!=0)
                    total=52+4369+bit_bytes; remaining=4369+bit_bytes
                    if (raw<=0 || raw>268435456 || bits<=0 || total>binary_size-start) reset()
                    else mode="body1"
                } else {
                    index_end=word(44); count=word(52)
                    if (raw<=0 || raw>268435456 || index_end<4485 ||
                        index_end>binary_size-start || count<1 ||
                        count>int((index_end-4437)/48)) reset()
                    else mode="index"
                }
            }
        } else if (mode=="index") {
            index_bytes[relative++]=byte
            if (relative==index_end) { check_index(); mode="body2" }
        } else if (mode=="body1") {
            if (--remaining==0) finish()
        } else if (mode=="body2") {
            if (relative==ends[frame]) {
                if (padding[frame]!=0 && byte%(2^(8-padding[frame]))!=0)
                    fail("v2 nonzero padding bits")
                frame++
            }
            relative++
            if (--remaining==0) finish()
        }
        position++
    }
}
END {
    if (bad) exit 1
    if (mode=="index" || mode=="body2") fail("truncated v2 envelope")
    printf "%d %.0f %.0f %.0f\n",payloads,raw_total,bitstream_total,static_total
}'
}
