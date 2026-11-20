# Account catalog envelopes directly from the linked binary. Marker literals
# are ignored unless their bounded headers describe an envelope; a recognized
# index must then pass its complete structural and hash checks.
# Output: envelopes, raw bytes, stream bytes, static bytes.
scan_stage0_tlch() {
    _tlch_size=$(wc -c < "$1" | tr -d ' ') || return 1
    od -An -v -tu1 "$1" | awk -v binary_size="$_tlch_size" '
BEGIN {
    split("95 95 116 121 112 101 108 105 115 112 95 101 109 98 101 100 100 101 100 95 115 116 100 108 105 98 95 116 108 99 105 95 118 51 95 95", prefix)
    # 36-byte marker + six u64 header fields + the stored model.
    model_start = 84
    model_bytes = 4413
    group_bytes = 32
    record_bytes = 48
    mode = "scan"; matched = 0; position = 0
}
function fail(message) {
    print "TLCH scanner: " message > "/dev/stderr"
    bad = 1; exit 1
}
function reset() { mode = "scan"; matched = 0 }
function word(offset,    i, value) {
    value = 0
    for (i = 0; i < 8; i++) value += index_bytes[offset + i] * (2 ^ (8 * i))
    return value
}
function finish() {
    envelopes++; raw_total += raw; stream_total += stream
    static_total += index_end + stream
    reset()
}
# Group g holds frame 0 alone, then sixteen frames at a time.
function group_of(frame_index) {
    return frame_index <= 0 ? 0 : 1 + int((frame_index - 1) / 16)
}
function group_first(group) {
    return group <= 0 ? 0 : 1 + (group - 1) * 16
}
function check_index(    count, groups, directory, i, record, name, name_len,
                         raw_offset, expanded, group, checksum, names, previous,
                         previous_len, j, order, sum, hash, stream_cursor,
                         raw_cursor, stream_off, stream_len, group_raw_off,
                         group_raw_len) {
    count = word(52); groups = word(76)
    directory = model_start + model_bytes + group_bytes * groups
    names = directory + record_bytes * count
    if (groups != (count <= 1 ? 1 : 2 + int((count - 2) / 16)))
        fail("invalid group count")
    hash = 1
    for (i = 0; i < index_end; i++)
        hash = (hash * 131 + ((i >= 60 && i < 68) ? 0 : index_bytes[i])) % 2147483647
    if (hash != word(60)) fail("index hash mismatch")
    stream_cursor = 0; raw_cursor = 0
    for (i = 0; i < groups; i++) {
        record = model_start + model_bytes + i * group_bytes
        stream_off = word(record); stream_len = word(record + 8)
        group_raw_off = word(record + 16); group_raw_len = word(record + 24)
        if (stream_len < 1 || stream_off != stream_cursor ||
            stream_off + stream_len > stream || group_raw_len < 0 ||
            group_raw_off != raw_cursor || group_raw_off + group_raw_len > raw ||
            (i == 0 && group_raw_len == 0))
            fail("invalid group table")
        stream_cursor += stream_len
        raw_cursor += group_raw_len
    }
    if (stream_cursor != stream || raw_cursor != raw)
        fail("group ranges do not cover the stream")
    sum = 0
    previous = 0; previous_len = 0
    for (i = 0; i < count; i++) {
        record = directory + i * record_bytes
        name = word(record); name_len = word(record + 8)
        raw_offset = word(record + 16); expanded = word(record + 24)
        group = word(record + 32); checksum = word(record + 40)
        if (checksum < 0 || checksum > 2147483647) fail("invalid frame checksum")
        if (group != group_of(i)) fail("invalid frame group")
        if (name != names || name_len < 0 || name_len > index_end - names ||
            (i == 0 ? name_len != 0 : name_len == 0) || expanded < 176 ||
            expanded > 268435456 - sum || raw_offset != sum)
            fail("invalid frame bounds")
        if (i > 1) {
            order = 0
            for (j = 0; j < name_len && j < previous_len && order == 0; j++)
                order = index_bytes[previous + j] - index_bytes[name + j]
            if (order == 0) order = previous_len - name_len
            if (order >= 0) fail("unsorted or duplicate identity")
        }
        sum += expanded
        names += name_len
        previous = name
        previous_len = name_len
    }
    if (names != index_end || sum != raw || index_end + stream > binary_size - start)
        fail("inconsistent index length")
}
{
    for (field = 1; field <= NF; field++) {
        byte = $field + 0
        if (mode == "scan") {
            if (byte == prefix[matched + 1]) matched++
            else if (byte == prefix[1]) matched = 1
            else matched = 0
            if (matched == 36) {
                start = position - 35; relative = 36; mode = "header"
                for (i = 0; i < 36; i++) index_bytes[i] = prefix[i + 1]
            }
        } else if (mode == "header") {
            index_bytes[relative++] = byte
            if (relative == model_start) {
                raw = word(36); index_end = word(44); count = word(52)
                stream = word(68); groups = word(76)
                if (raw <= 0 || raw > 268435456 || index_end < 4497 ||
                    index_end > binary_size - start || count < 1 || stream < 1 ||
                    groups < 1 || groups > count ||
                    count > int((index_end - 4497) / record_bytes)) reset()
                else mode = "index"
            }
        } else if (mode == "index") {
            index_bytes[relative++] = byte
            if (relative == index_end) {
                check_index()
                mode = "stream"; remaining = stream
            }
        } else if (mode == "stream") {
            if (--remaining == 0) finish()
        }
        position++
    }
}
END {
    if (bad) exit 1
    if (mode != "scan") fail("truncated envelope")
    printf "%d %.0f %.0f %.0f\n", envelopes, raw_total, stream_total, static_total
}'
}
