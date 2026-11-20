# Account catalog envelopes directly from the linked binary. Marker literals
# are ignored unless their bounded headers describe an envelope; a recognized
# index must then pass its complete structural and hash checks.
scan_stage0_tlch() {
    _tlch_size=$(wc -c < "$1" | tr -d ' ') || return 1
    od -An -v -tu1 "$1" | awk -v binary_size="$_tlch_size" '
BEGIN {
    split("95 95 116 121 112 101 108 105 115 112 95 101 109 98 101 100 100 101 100 95 115 116 100 108 105 98 95 116 108 99 105 95 118 51 95 95", prefix)
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
    payloads++; raw_total+=raw; bitstream_total+=stream; static_total+=total
    reset()
}
function check_index(    count,i,r,name,nlen,raw_offset,expanded,reserved,checksum,names,previous,previous_len,j,order,sum,cursor,hash) {
    count=word(52); names=4489+48*count; cursor=index_end; sum=0
    hash=1
    for (i=0;i<index_end;i++) hash=(hash*131+((i>=60 && i<68)?0:index_bytes[i]))%2147483647
    if (hash!=word(60)) fail("index hash mismatch")
    for (i=0;i<count;i++) {
        r=4489+i*48; name=word(r); nlen=word(r+8); raw_offset=word(r+16)
        expanded=word(r+24); reserved=word(r+32); checksum=word(r+40)
        if (reserved!=0) fail("invalid frame record")
        if (checksum<0 || checksum>2147483647) fail("invalid frame checksum")
        if (name!=names || nlen<0 || nlen>index_end-names ||
            (i==0 ? nlen!=0 : nlen==0) || expanded<176 ||
            expanded>268435456-sum || raw_offset!=sum)
            fail("invalid frame bounds")
        if (i>1) {
            order=0
            for (j=0;j<nlen && j<previous_len && order==0;j++)
                order=index_bytes[previous+j]-index_bytes[name+j]
            if (order==0) order=previous_len-nlen
            if (order>=0) fail("unsorted or duplicate identity")
        }
        sum+=expanded; names+=nlen; previous=name; previous_len=nlen
    }
    if (names!=index_end || sum!=raw || index_end+stream>binary_size-start)
        fail("inconsistent index length")
    total=index_end+stream
}
{
    for (field=1;field<=NF;field++) {
        byte=$field+0
        if (mode=="scan") {
            if (byte==prefix[matched+1]) {
                matched++
            } else if (byte==prefix[1]) matched=1
            else matched=0
            if (matched==36) {
                start=position-35; relative=36; mode="header"
                for (i=0;i<36;i++) index_bytes[i]=prefix[i+1]
            }
        } else if (mode=="header") {
            index_bytes[relative++]=byte
            if (relative==76) {
                raw=word(36); index_end=word(44); count=word(52); stream=word(68)
                if (raw<=0 || raw>268435456 || index_end<4489 ||
                    index_end>binary_size-start || count<1 || stream<1 ||
                    count>int((index_end-4489)/48)) reset()
                else mode="index"
            }
        } else if (mode=="index") {
            index_bytes[relative++]=byte
            if (relative==index_end) { check_index(); mode="stream"; remaining=stream }
        } else if (mode=="stream") {
            if (--remaining==0) finish()
        }
        position++
    }
}
END {
    if (bad) exit 1
    if (mode=="index" || mode=="stream" || mode=="header")
        fail("truncated envelope")
    printf "%d %.0f %.0f %.0f\n",payloads,raw_total,bitstream_total,static_total
}'
}
