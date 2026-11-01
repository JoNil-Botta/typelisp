# Bounded linked-binary scanner for the envelopes in compiler_lzss.tl.
# Keep v1 support: downloaded compilers can predate the v2 encoder.
# Output: streams, token bytes, static bytes, v1 streams, v2 streams, raw bytes.
scan_stage0_lzss() {
    scan_binary_bytes=$(wc -c < "$1" | tr -d ' ')
    od -An -v -tu1 "$1" | awk -v binary_size="$scan_binary_bytes" '
BEGIN {
    split("95 95 116 121 112 101 108 105 115 112 95 101 109 98 101 100 100 101 100 95 115 116 100 108 105 98 95 108 122 115 115 95 118 49 95 95", prefix)
    prefix_len = 36
    mode = "scan"
    # Prefix fallback preserves overlapping starts, e.g. ___typelisp... .
    for (i = 2; i <= prefix_len; i++) {
        j = fallback[i - 1]
        while (j > 0 && prefix[i] != prefix[j + 1]) j = fallback[j]
        if (prefix[i] == prefix[j + 1]) j++
        fallback[i] = j
    }
    # Fixed canonical models from compiler_lzss.tl, indexed by symbol.
    canonical("main", "ffffffffff9fffffffffffffffffffff5a8bfdba77ba867a778888888999a9aa" \
        "d9a9b9acc9edaaaaaea99bbbdfe8b9e87576657775b867666a66668887aefeff" \
        "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff" \
        "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff1")
    canonical("distance", "4cbca9876555444444444434")
    canonical("length", "3344445555555662")
}
function fail(message) {
    print "embedded stdlib LZSS at byte " frame_start ": " message > "/dev/stderr"
    bad = 1
    exit 1
}
function canonical(model, spec, symbol, width, code, i, key) {
    for (symbol = 0; symbol < length(spec); symbol++) {
        width = index("0123456789abcdef", substr(spec, symbol + 1, 1)) - 1
        lengths[model, symbol] = width
        counts[model, width]++
    }
    code = 0
    for (i = 1; i <= 15; i++) {
        code = (code + counts[model, i - 1]) * 2
        next_code[model, i] = code
    }
    for (symbol = 0; symbol < length(spec); symbol++) {
        width = lengths[model, symbol]
        key = model SUBSEP width SUBSEP next_code[model, width]++
        symbols[key] = symbol
    }
}
function reset_scan() {
    mode = "scan"
    prefix_index = 0
}
function finish_payload() {
    payload_count++
    versions[version]++
    compressed_total += compressed_bytes
    static_total += prefix_len + header_digits + 1 + compressed_bytes
    raw_total += raw_len
    reset_scan()
}
function emit_byte(value) {
    # A ring suffices: both token formats have a 4096-byte window.
    output[out_bytes % 4096] = value
    out_bytes++
}
function copy_match(distance, width, i) {
    if (distance > out_bytes) fail("backreference before output")
    if (width > raw_len - out_bytes) fail("token exceeds raw length")
    for (i = 0; i < width; i++)
        emit_byte(output[(out_bytes - distance) % 4096])
}
function next_symbol(model) {
    token_mode = model
    symbol_bits = 0
    symbol_code = 0
}
function prefix_matches(byte, slot) {
    return (slot == 34 ? byte == 49 || byte == 50 : byte == prefix[slot])
}
function v2_bit(value, key, symbol) {
    if (token_mode == "extra") {
        extra = extra * 2 + value
        if (--extra_left == 0) next_symbol("length")
        return
    }
    symbol_code = symbol_code * 2 + value
    symbol_bits++
    key = token_mode SUBSEP symbol_bits SUBSEP symbol_code
    if (!(key in symbols)) {
        if (symbol_bits == 15) fail("unassigned v2 code")
        return
    }
    symbol = symbols[key]
    if (token_mode == "main") {
        if (symbol < 256) {
            emit_byte(symbol)
            next_symbol("main")
        } else next_symbol("distance")
    } else if (token_mode == "distance") {
        bucket = symbol
        extra = 0
        extra_count = (bucket < 4 ? 0 : int(bucket / 2) - 1)
        extra_left = extra_count
        if (extra_left == 0) next_symbol("length")
        else token_mode = "extra"
    } else {
        distance = (bucket < 4 ? bucket : (2 + bucket % 2) * (2 ^ extra_count) + extra) + 1
        copy_match(distance, symbol + 3)
        next_symbol("main")
    }
}
{
    for (field = 1; field <= NF; field++) {
        byte = $field + 0
        position++
        if (mode == "scan") {
            while (prefix_index > 0 && !prefix_matches(byte, prefix_index + 1))
                prefix_index = fallback[prefix_index]
            if (prefix_matches(byte, prefix_index + 1)) {
                prefix_index++
                if (prefix_index == 34) version = byte - 48
            }
            if (prefix_index == prefix_len) {
                frame_start = position - prefix_len
                mode = "header"
                raw_len = 0
                header_digits = 0
            }
        } else if (mode == "header") {
            if (byte >= 48 && byte <= 57) {
                digit = byte - 48
                # A necessary expansion bound, also keeping arithmetic exact.
                expansion = (version == 1 ? 9 : 48)
                if (raw_len > int((binary_size * expansion - digit) / 10))
                    fail("impossible raw length")
                raw_len = raw_len * 10 + digit
                header_digits++
            } else if (byte == 0 && header_digits == 0) {
                # The runtime decoder also embeds NUL-terminated marker-only
                # strings. These are not frames; every decimal header is.
                reset_scan()
            } else if (byte == 10 && header_digits > 0) {
                compressed_bytes = 0
                out_bytes = 0
                if (raw_len == 0) finish_payload()
                else if (version == 1) mode = "flags"
                else {
                    mode = "v2"
                    next_symbol("main")
                }
            } else fail("malformed raw length")
        } else if (mode == "flags") {
            flags = byte
            compressed_bytes++
            flag_bit = 0
            mode = "token"
        } else if (mode == "token") {
            compressed_bytes++
            if (int(flags / (2 ^ flag_bit)) % 2 == 1) {
                emit_byte(byte)
                flag_bit++
                if (out_bytes == raw_len) finish_payload()
                else if (flag_bit == 8) mode = "flags"
            } else {
                reference_first = byte
                mode = "reference-second"
            }
        } else if (mode == "reference-second") {
            compressed_bytes++
            copy_match(int((reference_first * 256 + byte) / 16) + 1, byte % 16 + 3)
            flag_bit++
            if (out_bytes == raw_len) finish_payload()
            else if (flag_bit == 8) mode = "flags"
            else mode = "token"
        } else if (mode == "v2") {
            compressed_bytes++
            for (bit = 7; bit >= 0; bit--) {
                v2_bit(int(byte / (2 ^ bit)) % 2)
                if (out_bytes == raw_len) {
                    if (byte % (2 ^ bit) != 0) fail("nonzero v2 padding")
                    finish_payload()
                    break
                }
            }
        }
    }
}
END {
    if (!bad && mode != "scan") fail("truncated " mode)
    if (!bad) printf "%d %.0f %.0f %d %d %.0f\n", payload_count, compressed_total, static_total, versions[1], versions[2], raw_total
}
'
}
