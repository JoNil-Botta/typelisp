# Bounded linked-binary scanner for the envelopes in compiler_lzss.tl (LZSS
# source frames) and compiler_tlch.tl (TLCH catalog envelopes).
#
# `scan_stage0_payloads BINARY [both|lzss|tlch]` scans the binary once (jumping
# directly to the first marker offset when GNU grep -aobFU is available and
# stopping once all trailing markers are past) and decodes every requested
# envelope completely.
#
# Output:
#   lzss: streams token_bytes static_bytes v3_streams raw_bytes
#   tlch: envelopes raw_bytes stream_bytes static_bytes
#   both: the 5 LZSS counts followed by the 4 TLCH counts on one line

stage0_marker_span() {
    _sms_file=$1
    _sms_pattern=$2
    _sms_rc=0
    _sms_matches=$(LC_ALL=C grep -aobFU "$_sms_pattern" "$_sms_file" 2>/dev/null) || _sms_rc=$?
    if [ "$_sms_rc" -eq 1 ]; then
        printf 'none\n'
        return 0
    fi
    if [ "$_sms_rc" -ne 0 ]; then
        printf 'full\n'
        return 0
    fi
    printf '%s\n' "$_sms_matches" | awk -F ':' '
        NR == 1 { first = $1 }
        { last = $1 }
        END {
            if (NR == 0 || first !~ /^[0-9]+$/ || last !~ /^[0-9]+$/) print "full"
            else print first " " last
        }
    '
}

scan_stage0_payloads() {
    _scan_file=$1
    _scan_mode=${2:-both}
    case "$_scan_mode" in
        lzss) _scan_pattern='__typelisp_embedded_stdlib_tlss_v3__' ;;
        tlch) _scan_pattern='__typelisp_embedded_stdlib_tlci_v4__' ;;
        both) _scan_pattern='__typelisp_embedded_stdlib_tl' ;;
        *)
            echo "unknown stage0 payload scan mode: $_scan_mode" >&2
            return 2
            ;;
    esac
    _scan_binary_bytes=$(wc -c < "$_scan_file" | tr -d ' ') || return 1
    _scan_span=$(stage0_marker_span "$_scan_file" "$_scan_pattern")
    if [ "$_scan_span" = none ]; then
        case "$_scan_mode" in
            lzss) printf '0 0 0 0 0\n' ;;
            tlch) printf '0 0 0 0\n' ;;
            both) printf '0 0 0 0 0 0 0 0 0\n' ;;
        esac
        return 0
    fi
    if [ "$_scan_span" = full ]; then
        _scan_start_offset=0
        _scan_stop_after=-1
    else
        _scan_start_offset=${_scan_span%% *}
        _scan_last_offset=${_scan_span##* }
        _scan_stop_after=$((_scan_last_offset + 36))
    fi
    od -An -v -tu1 -j "$_scan_start_offset" "$_scan_file" | awk \
        -v binary_size="$_scan_binary_bytes" \
        -v start_offset="$_scan_start_offset" \
        -v stop_after="$_scan_stop_after" \
        -v scan_mode="$_scan_mode" '
BEGIN {
    do_lzss = (scan_mode == "both" || scan_mode == "lzss")
    do_tlch = (scan_mode == "both" || scan_mode == "tlch")
    position_global = start_offset
    tlch_position = start_offset

    if (do_lzss) {
        mode = "scan"
        final_pass = 0
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
        bit_div[0] = 128; bit_div[1] = 64; bit_div[2] = 32; bit_div[3] = 16
        bit_div[4] = 8;   bit_div[5] = 4;  bit_div[6] = 2;  bit_div[7] = 1
        for (i = 0; i < 256; i++) cls_ctx[i] = (substr(classes, i + 1, 1) + 0) * 2
        for (i = 0; i < length_symbols; i++) {
            len_extra_tbl[i] = length_extra(i)
            len_base_tbl[i] = length_base(i)
        }
        for (i = 0; i < distance_symbols; i++) {
            dist_extra_tbl[i] = distance_extra(i)
            dist_base_tbl[i] = distance_base(i)
        }
    }

    if (do_tlch) {
        split("95 95 116 121 112 101 108 105 115 112 95 101 109 98 101 100 100 101 100 95 115 116 100 108 105 98 95 116 108 99 105 95 118 52 95 95", tlch_prefix)
        # 36-byte marker + six u64 header fields + the stored model.
        tlch_model_start = 84
        tlch_model_bytes = 4413
        tlch_group_bytes = 32
        tlch_record_bytes = 80
        tlch_mode = "scan"
        tlch_matched = 0
    }
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
function tlch_fail(message) {
    print "TLCH scanner: " message > "/dev/stderr"
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
# --- LZSS bit reader ----------------------------------------------------------
function next_bit(    b) {
    if (bit_pos >= compressed_bytes * 8) {
        # The frame may simply need the next byte; the caller restores its
        # state and waits. A stream that really ends here fails in END.
        truncated = 1
        return 0
    }
    b = int(body[int(bit_pos / 8)] / bit_div[bit_pos % 8]) % 2
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
    return cls_ctx[previous] + position % 2
}
# Decode whole tokens while the stream holds more than any single token needs,
# so a frame can be resumed as its bytes arrive. Returns 1 when the body is
# complete, 0 when more bytes are needed, and fails on a broken stream.
function decode_available(    symbol_, kind, slot, extra, match_len, distance, dslot, i) {
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
        extra = take_bits(len_extra_tbl[slot])
        if (truncated) {
            position = saved_position
            bit_pos = saved_bits
            return 0
        }
        match_len = len_base_tbl[slot] + extra
        if (match_len < min_match || match_len > max_match) fail("invalid match length")
        if (position + match_len > raw_len) fail("token exceeds raw length")
        if (kind == 0) {
            dslot = read_symbol(17 + length_bucket(match_len))
            distance = dist_base_tbl[dslot] + take_bits(dist_extra_tbl[dslot])
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
# --- TLCH index validator -----------------------------------------------------
function tlch_reset() { tlch_mode = "scan"; tlch_matched = 0 }
function tlch_word(offset,    i, value) {
    value = 0
    for (i = 0; i < 8; i++) value += tlch_index_bytes[offset + i] * (2 ^ (8 * i))
    return value
}
function tlch_finish() {
    tlch_envelopes++; tlch_raw_total += tlch_raw; tlch_stream_total += tlch_stream
    tlch_static_total += tlch_index_end + tlch_stream
    tlch_reset()
}
function tlch_check_index(    tcount, groups, directory, i, record, name, name_len,
                              raw_offset, expanded, group, checksum, names, previous,
                              previous_len, j, order, sum, hash, stream_cursor,
                              raw_cursor, stream_off, stream_len, group_raw_off,
                              group_raw_len, group_frames, expected_group) {
    tcount = tlch_word(52); groups = tlch_word(76)
    directory = tlch_model_start + tlch_model_bytes + tlch_group_bytes * groups
    names = directory + tlch_record_bytes * tcount
    hash = 1
    for (i = 0; i < tlch_index_end; i++)
        hash = (hash * 131 + ((i >= 60 && i < 68) ? 0 : tlch_index_bytes[i])) % 2147483647
    if (hash != tlch_word(60)) tlch_fail("index hash mismatch")
    stream_cursor = 0; raw_cursor = 0
    for (i = 0; i < groups; i++) {
        record = tlch_model_start + tlch_model_bytes + i * tlch_group_bytes
        stream_off = tlch_word(record); stream_len = tlch_word(record + 8)
        group_raw_off = tlch_word(record + 16); group_raw_len = tlch_word(record + 24)
        if (stream_len < 1 || stream_off != stream_cursor ||
            stream_off + stream_len > tlch_stream || group_raw_len < 0 ||
            group_raw_off != raw_cursor || group_raw_off + group_raw_len > tlch_raw ||
            (i == 0 && group_raw_len == 0))
            tlch_fail("invalid group table")
        stream_cursor += stream_len
        raw_cursor += group_raw_len
    }
    if (stream_cursor != tlch_stream || raw_cursor != tlch_raw)
        tlch_fail("group ranges do not cover the stream")
    sum = 0
    previous = 0; previous_len = 0
    group_frames = 0
    for (i = 0; i < tcount; i++) {
        record = directory + i * tlch_record_bytes
        name = tlch_word(record); name_len = tlch_word(record + 8)
        raw_offset = tlch_word(record + 16); expanded = tlch_word(record + 24)
        group = tlch_word(record + 32); checksum = tlch_word(record + 40)
        if (checksum < 0 || checksum > 2147483647) tlch_fail("invalid frame checksum")
        # Frame zero stands alone. The first departure from group 1 fixes the
        # width for all ordinary groups, with a possibly shorter last group.
        if (i > 1 && group_frames == 0 && group != 1) group_frames = i - 1
        expected_group = i == 0 ? 0 : 1
        if (group_frames != 0) expected_group += int((i - 1) / group_frames)
        if (group != expected_group || group >= groups) tlch_fail("invalid frame group")
        if (name != names || name_len < 0 || name_len > tlch_index_end - names ||
            (i == 0 ? name_len != 0 : name_len == 0) || expanded < 176 ||
            expanded > 268435456 - sum || raw_offset != sum)
            tlch_fail("invalid frame bounds")
        if (i > 1) {
            order = 0
            for (j = 0; j < name_len && j < previous_len && order == 0; j++)
                order = tlch_index_bytes[previous + j] - tlch_index_bytes[name + j]
            if (order == 0) order = previous_len - name_len
            if (order >= 0) tlch_fail("unsorted or duplicate identity")
        }
        sum += expanded
        names += name_len
        previous = name
        previous_len = name_len
    }
    # With a single ordinary group, only its actual width is observable.
    if (group_frames == 0) group_frames = tcount - 1
    if (groups != (tcount == 1 ? 1 : 2 + int((tcount - 2) / group_frames)))
        tlch_fail("invalid group count")
    if (names != tlch_index_end || sum != tlch_raw || tlch_index_end + tlch_stream > binary_size - tlch_start)
        tlch_fail("inconsistent index length")
}
{
    if (stop_after >= 0 && position_global > stop_after &&
        (!do_lzss || (mode == "scan" && prefix_index == 0)) &&
        (!do_tlch || (tlch_mode == "scan" && tlch_matched == 0))) {
        exit 0
    }
    if ((!do_lzss || (mode == "scan" && prefix_index == 0)) &&
        (!do_tlch || (tlch_mode == "scan" && tlch_matched == 0)) &&
        index($0, "95") == 0) {
        position_global += NF
        tlch_position += NF
        next
    }
    for (field = 1; field <= NF; field++) {
        byte = $field + 0
        position_global++
        if (do_lzss) {
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
        if (do_tlch) {
            if (tlch_mode == "scan") {
                if (byte == tlch_prefix[tlch_matched + 1]) tlch_matched++
                else if (byte == tlch_prefix[1]) tlch_matched = 1
                else tlch_matched = 0
                if (tlch_matched == 36) {
                    tlch_start = tlch_position - 35; tlch_relative = 36; tlch_mode = "header"
                    for (i = 0; i < 36; i++) tlch_index_bytes[i] = tlch_prefix[i + 1]
                }
            } else if (tlch_mode == "header") {
                tlch_index_bytes[tlch_relative++] = byte
                if (tlch_relative == tlch_model_start) {
                    tlch_raw = tlch_word(36); tlch_index_end = tlch_word(44); tlch_count = tlch_word(52)
                    tlch_stream = tlch_word(68); tlch_groups = tlch_word(76)
                    if (tlch_raw <= 0 || tlch_raw > 268435456 || tlch_index_end < 4497 ||
                        tlch_index_end > binary_size - tlch_start || tlch_count < 1 || tlch_stream < 1 ||
                        tlch_groups < 1 || tlch_groups > tlch_count ||
                        tlch_count > int((tlch_index_end - 4497) / tlch_record_bytes)) tlch_reset()
                    else tlch_mode = "index"
                }
            } else if (tlch_mode == "index") {
                tlch_index_bytes[tlch_relative++] = byte
                if (tlch_relative == tlch_index_end) {
                    tlch_check_index()
                    tlch_mode = "stream"; tlch_remaining = tlch_stream
                }
            } else if (tlch_mode == "stream") {
                if (--tlch_remaining == 0) tlch_finish()
            }
            tlch_position++
        }
    }
}
END {
    if (bad) exit 1
    if (do_lzss) {
        # The last tokens of a frame may leave fewer than a whole token worth of
        # bits, so finish the stream with whatever it holds.
        if (mode == "v3") {
            final_pass = 1
            if (decode_available()) finish_payload()
        }
        if (mode != "scan") fail("truncated " mode " frame")
    }
    if (do_tlch) {
        if (tlch_mode != "scan") tlch_fail("truncated envelope")
    }
    if (scan_mode == "lzss") {
        printf "%d %.0f %.0f %d %.0f\n", payload_count, compressed_total, static_total, versions[3], raw_total
    } else if (scan_mode == "tlch") {
        printf "%d %.0f %.0f %.0f\n", tlch_envelopes, tlch_raw_total, tlch_stream_total, tlch_static_total
    } else {
        printf "%d %.0f %.0f %d %.0f %d %.0f %.0f %.0f\n", \
            payload_count, compressed_total, static_total, versions[3], raw_total, \
            tlch_envelopes, tlch_raw_total, tlch_stream_total, tlch_static_total
    }
}
'
}

# Output: streams, token bytes, static bytes, v3 streams, raw bytes.
scan_stage0_lzss() {
    scan_stage0_payloads "$1" lzss
}
