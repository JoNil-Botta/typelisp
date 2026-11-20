# Bounded linked-binary scanner for the envelopes in compiler_lzss.tl.
# It decodes every source frame from the fixed model and requires the token
# stream to reproduce the declared raw length byte for byte.
# Output: streams, token bytes, static bytes, v3 streams, raw bytes.
scan_stage0_lzss() {
    scan_binary_bytes=$(wc -c < "$1" | tr -d ' ')
    od -An -v -tu1 "$1" | awk -v binary_size="$scan_binary_bytes" '
BEGIN {
    mode = "scan"
    final_pass = 0
    position_global = 0
    prefix_index = 0
    split("95 95 116 121 112 101 108 105 115 112 95 101 109 98 101 100 100 101 100 95 115 116 100 108 105 98 95 116 108 115 115 95 118 51 95 95", prefix)
    prefix_len = 36
    # Prefix fallback preserves overlapping starts, e.g. ___typelisp... .
    for (i = 2; i <= prefix_len; i++) {
        j = fallback[i - 1]
        while (j > 0 && prefix[i] != prefix[j + 1]) j = fallback[j]
        if (prefix[i] == prefix[j + 1]) j++
        fallback[i] = j
    }
    # The fixed model and literal classes of compiler_lzss.tl: one character
    # per code length, A + length.
    model = \
        "JJJJJJJJJJIJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJCJJJJJJJJJJJJJJJJ" \
        "JJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJIIIIIIIIIIII" \
        "IIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIII" \
        "IIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIJJJJJJJJJJJJIIIIIIIIIIIIIIIIIIIIIIIIIIIIII" \
        "IIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIII" \
        "IIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIII" \
        "IIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIILLLLLLLL" \
        "LLFLLLLLLLLLLLLLLLLLLLLLELLLLLLLFLLLLKKKKKKKKKKKKKKDKKKKKKKKKKKKKKKKKKKKKKKK" \
        "KKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKK" \
        "KKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKK" \
        "KKKKKKKKKKKKKKKKKKKKBIHHIKLLLLLLLLLLELLLLLLLLLLLLLLLLLLLLLELLLLLLLFLLLLLLLLL" \
        "LLLLLLLLLDLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLKKKKKKKKKKKKKKKKKKKKKKKKKK" \
        "KKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKK" \
        "KKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKBHHJKKPPPPPPPPPPPPPPPP" \
        "PPPPPPPPPPPPPPPPGPIOPPOKFPNLIILMGGHIIJIKJJHKLMNOPIJIKJJLLINLKKJJJPIIIJLKNPMG" \
        "PPPJGFGGHHGJIFKJHHHFHLGGGHIHKKKPOPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPP" \
        "PPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPOPPPPPPPPPPPPPPPPP" \
        "PPPPPPPPPPPPBJGIJPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPGOHOPPPLFPOMIJMMGGHIIJJKJJ" \
        "HKMNMPPIJIJJJKLJNLJKJJJOJIIJKKNNMGPPPKGFGGHGGJIFKJHHHGGLGGGHIHLLKNNPPPPPPPPP" \
        "PPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPP" \
        "PPPPPPPPPPPPPPPPNPPPPPPPPPPPPPPPPPPPPPPPPPPPPPBIGIIPOOOOOOOOOOJOOOONNNNNNNNN" \
        "NNNNNNNNFLKNNMNMMFMMKIHJEFEFEFEFFFKLNMMNNMMNMMLNMMNMMLMLMNMLMLMNMNNNNHKKJGGF" \
        "GGGNNNNNNNNNMNNNNNMNJNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNN" \
        "NNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNN" \
        "NNNNCEHIJNNNNNNNNNNNJNNNNNNNNNNNNNNNNNNNNNFLKNNNNKLFNMJIHKEFEFEFFFFFLLNMNNNN" \
        "MMLNLNNLNMMMLLNNMMMNMNNNMNNHKLIGGFGGFNNNNNNNNMNNNNNNNNJNNNNNNNNNNNNNNNNNNNNN" \
        "NNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNN" \
        "NNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNCEGHIMPPPPPPPPPPJPPPPPPPPPPPPPPPPPPPPP" \
        "EJKPPPPKPHPPIGHJJIJIJJIJIJJJPPPJPPLLPKLPPMPPKLLKLPLLLPPPPPPPPKPJIFHGFEGHGFPI" \
        "FGEFGKEFEGHHIHKPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPP" \
        "PPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPCIIJ" \
        "KPPPPPPPPPPPJPPPPPPPPPPPPPPPPPPPPPEJKPPPPKPHPPHGHKJJJIJJIJJJJJPPPJPPLLPLLPPP" \
        "PPLPMKLPPLLPPPPPPPPKPJIFHGFEGHGFLIFGEFGKEFEGIHIGKPPPPPPPPPPPPPPPPPPPPPPPPPPP" \
        "PPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPP" \
        "PPPPPPPPPPPPPPPPPPPPPPPPPPPPPPCIIKKPMMMMMMMMMMLMMMMMMMMMMMMMMMMMMMMMFMJMMMMK" \
        "LHMMIHIHKLLKKKIMMMKJMKMMMGIHHGHIJFLJHHHHGKHGGHJJIJLLMMMIIFJJIEKMGFMGGHFEHLFH" \
        "FFJJHIMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMM" \
        "MMMLMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMCIKLKMMMMMMM" \
        "MMMMMMMMMMMMMMMMMMMMMMMMMMFLJMMLMKLIMKIHIIKKKKKLJMMMKKMKLLMHIGHGHIIGLIHIHHGK" \
        "GGGIJJKKKLLMMIIFKIIEJMFFMGHHFEHKFGFFIKHHMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMM" \
        "MMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMM" \
        "MMMMMMMMMMMMMMMMMMMMMMCIJKLMPPPPPPOOOOHOOOOOOOOOOOOOOOOOOOOODJIJMKHKIGIGIHIJ" \
        "JIJKKLNLLMHJHGHNKKLLLKLLNKOMMJLKKMLKJMLMMNNKKHNIHGHGHHHJJGLJHHHHHKHGHIIIKLKM" \
        "NMNOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOONOOOO" \
        "OOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOBHHIJOPPPPPPPPPPHPPP" \
        "PPPPPPPPPPPPPPPPPPDJIHNKHLIGIHIHIJJIKKLMMLLMHJHGHMLKLLLKLMMKNMMKLKKMLKJMLMNP" \
        "NKKGNIHGHGHHHKJGLJHHHHHKHGHIJIKMKMNMNOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOO" \
        "OOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOO" \
        "OOOOOOOOOOOOOOBHHIIOMMLLLLLLLLELLLLLLLLLLLLLLLLLLLLLDKILLLLILJLLLLGKIIIKIIKI" \
        "JJLLLLKLLJIKKIKLKHLLLJKJJLJJJKILLLLLLJLLJIIHJGJJJHKKHJHKHLJGHKJJKKLLLLLLJLLL" \
        "LLLLLLLLLLLLLLLLKLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLL" \
        "LLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLBIJKKLLLLLLLLLLLELLLLLLLLLLL" \
        "LLLLLLLLLLDLILLLLLLJLLLLGKHIIJKJJKKJLLLKLLLKHJKIKLLIKLKLLJJLKKJLILLLLLKJLLJI" \
        "IHKHIIIHLJHKHIHLJGHJJIKLLLLLLLKLLLLLLLLLLLLLLLLLLLKLLLLLLLLLLLLLLLLLKLLLLLLL" \
        "LLLLLLLLJLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLL" \
        "LLLLLLBIHJKLGEDDEEEFEEEFEFFGFGGHHIIJJKLLJGKHIHGFFEEEEDEEEDFEFFGGIJLJNNNNNOON" \
        "NNNNNNNNNNNNNIMMNKIHHGGFFEFEFEFEFEEEFEFEFFGFHHJKJKPPPPPPPPPPOIMPPMOIHGGFFFFE" \
        "FEFEFEFEEEFEFEFGGHJJKJPPPPPPPPPPPJNPPMNLLHHFGFFEFEEEEEEEEEFEFFGGHHIIJJPPPPPP" \
        "PPOOO" \
        ""
    classes = \
        "0000000001177177777777777777777726666666666666763333333333666666655555555555" \
        "5555555555555556666464444444444444444444444444466667777777777777777777777777" \
        "7777777777777777777777777777777777777777777777777777777777777777777777777777" \
        "7777777777777777777777777777" \
        ""
    contexts = 16
    main_symbols = 262
    length_symbols = 29
    buckets = 4
    distance_symbols = 48
    max_bits = 15
    max_match = 258
    min_match = 3
    window = 16777216
    length_start = contexts * main_symbols
    distance_start = length_start + length_symbols
    for (i = 0; i < contexts; i++) build_table(i, i * main_symbols, main_symbols)
    build_table(16, length_start, length_symbols)
    for (i = 0; i < buckets; i++)
        build_table(17 + i, distance_start + i * distance_symbols, distance_symbols)
}
# Canonical decoding order: counts per length, then symbols by (length, symbol).
function build_table(table, start, n,    i, len, placed) {
    for (i = 1; i <= max_bits; i++) count[table, i] = 0
    for (i = 0; i < n; i++) {
        len = index("ABCDEFGHIJKLMNOP", substr(model, start + i + 1, 1)) - 1
        if (len < 0) fail("invalid model code length")
        if (len > 0) count[table, len]++
    }
    placed = 0
    for (i = 1; i <= max_bits; i++) { base[table, i] = placed; placed += count[table, i] }
    for (i = 0; i < n; i++)
        code_length[table, i] = \
            index("ABCDEFGHIJKLMNOP", substr(model, start + i + 1, 1)) - 1
    for (i = 1; i <= max_bits; i++) {
        placed = base[table, i]
        for (len = 0; len < n; len++)
            if (code_length[table, len] == i) symbol[table, placed++] = len
    }
}
function fail(message) {
    print "embedded stdlib LZSS at byte " frame_start ": " message > "/dev/stderr"
    bad = 1
    exit 1
}
function reset_scan() {
    mode = "scan"
    prefix_index = 0
}
function finish_payload() {
    payload_count++
    versions[3]++
    compressed_total += compressed_bytes
    static_total += prefix_len + header_digits + 1 + compressed_bytes
    raw_total += raw_len
    reset_scan()
}
# --- bit reader ---------------------------------------------------------------
function next_bit(    b) {
    if (bit_pos >= compressed_bytes * 8) {
        # The frame may simply need the next byte; the caller restores its
        # state and waits. A stream that really ends here fails in END.
        truncated = 1
        return 0
    }
    b = int(body[int(bit_pos / 8)] / (2 ^ (7 - bit_pos % 8))) % 2
    bit_pos++
    return b
}
function take_bits(n,    v) {
    v = 0
    while (n > 0) { v = v * 2 + next_bit(); n-- }
    return v
}
function read_symbol(table,    code, first, index_, len, count_len) {
    code = 0
    first = 0
    index_ = 0
    for (len = 1; len <= max_bits; len++) {
        code = code * 2 + next_bit()
        count_len = count[table, len]
        if (code - first < count_len)
            return symbol[table, base[table, len] + (code - first)]
        index_ += count_len
        first = (first + count_len) * 2
    }
    fail("unassigned huffman code")
}
function bit_length(value,    bits) {
    bits = 0
    while (value > 0) { value = int(value / 2); bits++ }
    return bits
}
function length_extra(slot) {
    if (slot < 8 || slot > 27) return 0
    return 1 + int((slot - 8) / 4)
}
function length_base(slot,    e) {
    if (slot < 8) return slot + 3
    if (slot > 27) return 258
    e = 1 + int((slot - 8) / 4)
    return 2 ^ (e + 2) + 3 + ((slot - 8) % 4) * (2 ^ e)
}
function length_bucket(match_len) {
    if (match_len <= 4) return 0
    if (match_len <= 8) return 1
    if (match_len <= 16) return 2
    return 3
}
function distance_extra(slot) {
    if (slot < 4) return 0
    return 1 + int((slot - 4) / 2)
}
function distance_base(slot,    e) {
    if (slot < 4) return slot + 1
    e = 1 + int((slot - 4) / 2)
    return 2 ^ (e + 1) + 1 + ((slot - 4) % 2) * (2 ^ e)
}
function context_of(position,    previous) {
    previous = (position > 0) ? out[position - 1] : 0
    return (substr(classes, previous + 1, 1) + 0) * 2 + position % 2
}
# Decode whole tokens while the stream holds more than any single token needs,
# so a frame can be resumed as its bytes arrive. Returns 1 when the body is
# complete, 0 when more bytes are needed, and fails on a broken stream.
function decode_available(    symbol_, kind, slot, extra, match_len, distance, dslot, i, saved) {
    # Decode one token at a time from a checkpoint: a token that runs past the
    # bytes received so far is undone and retried when the next byte arrives.
    while (position < raw_len) {
        saved_position = position
        saved_bits = bit_pos
        saved_rep0 = rep[0]; saved_rep1 = rep[1]
        saved_rep2 = rep[2]; saved_rep3 = rep[3]
        truncated = 0
        symbol_ = read_symbol(context_of(position))
        if (truncated) {
            position = saved_position
            bit_pos = saved_bits
            rep[0] = saved_rep0; rep[1] = saved_rep1
            rep[2] = saved_rep2; rep[3] = saved_rep3
            return 0
        }
        if (symbol_ < 256) {
            out[position] = symbol_
            position++
            continue
        }
        if (symbol_ >= 262) fail("invalid match symbol")
        kind = symbol_ - 256
        if (kind == 5) {
            # A repeat-0 match of length one carries no length or distance.
            distance = rep[0]
            if (distance <= 0 || distance > position || distance > window)
                fail("backreference before output")
            out[position] = out[position - distance]
            position++
            continue
        }
        slot = read_symbol(16)
        extra = take_bits(length_extra(slot))
        if (truncated) {
            position = saved_position
            bit_pos = saved_bits
            return 0
        }
        match_len = length_base(slot) + extra
        if (match_len < min_match || match_len > max_match) fail("invalid match length")
        if (position + match_len > raw_len) fail("token exceeds raw length")
        if (kind == 0) {
            dslot = read_symbol(17 + length_bucket(match_len))
            distance = distance_base(dslot) + take_bits(distance_extra(dslot))
            if (truncated) {
                position = saved_position
                bit_pos = saved_bits
                return 0
            }
        } else
            distance = rep[kind - 1]
        if (distance <= 0 || distance > position || distance > window)
            fail("backreference before output")
        if (kind == 0) {
            rep[3] = rep[2]; rep[2] = rep[1]; rep[1] = rep[0]; rep[0] = distance
        } else if (kind > 1) {
            for (i = kind - 1; i > 0; i--) rep[i] = rep[i - 1]
            rep[0] = distance
        }
        for (i = 0; i < match_len; i++) out[position + i] = out[position + i - distance]
        position += match_len
    }
    if (position < raw_len) return 0
    # The output is complete: the stream must end in the last body byte.
    expected = int((bit_pos + 7) / 8)
    if (compressed_bytes < expected) return 0
    if (compressed_bytes > expected) fail("trailing compressed bytes")
    if (bit_pos % 8 != 0 &&
        body[compressed_bytes - 1] % (2 ^ (8 - bit_pos % 8)) != 0)
        fail("nonzero padding bits")
    return 1
}
{
    for (field = 1; field <= NF; field++) {
        byte = $field + 0
        position_global++
        if (mode == "scan") {
            while (prefix_index > 0 && byte != prefix[prefix_index + 1])
                prefix_index = fallback[prefix_index]
            if (byte == prefix[prefix_index + 1]) prefix_index++
            if (prefix_index == prefix_len) {
                frame_start = position_global - prefix_len + 1
                mode = "header"
                raw_len = 0
                header_digits = 0
            }
        } else if (mode == "header") {
            if (byte >= 48 && byte <= 57) {
                digit = byte - 48
                if (raw_len > int((binary_size * 2064 - digit) / 10))
                    fail("impossible raw length")
                raw_len = raw_len * 10 + digit
                header_digits++
            } else if (byte == 0 && header_digits == 0) {
                # The runtime decoder also embeds NUL-terminated marker-only
                # strings. These are not frames; every decimal header is.
                reset_scan()
            } else if (byte == 10 && header_digits > 0) {
                compressed_bytes = 0
                position = 0
                bit_pos = 0
                delete out
                delete body
                delete out
                rep[0] = 1; rep[1] = 1; rep[2] = 1; rep[3] = 1
                if (raw_len == 0) finish_payload()
                else mode = "v3"
            } else fail("malformed raw length")
        } else if (mode == "v3") {
            body[compressed_bytes++] = byte
            if (compressed_bytes > binary_size - frame_start)
                fail("truncated token stream")
            if (decode_available()) finish_payload()
        }
    }
}
END {
    # The last tokens of a frame may leave fewer than a whole token worth of
    # bits, so finish the stream with whatever it holds.
    if (!bad && mode == "v3") {
        final_pass = 1
        if (decode_available()) finish_payload()
    }
    if (!bad && mode != "scan") fail("truncated " mode " frame")
    if (!bad) printf "%d %.0f %.0f %d %.0f\n", payload_count, compressed_total, static_total, versions[3], raw_total
}
'
}
