# Balanced TypeLisp defenum scanner used by check-zero-cons.sh.
#
# The scanner works on parsed parenthesis structure rather than spelling
# searches. A family is list-shaped when a variant stores a boxed nominal
# reference to its own family as a tail field and the enum has an empty
# terminator. Variants ending in Cons are also treated as list storage so the
# semantic reader pair remains visible until its dedicated dense migration.
#
# Recursive trees are not findings: a non-Cons variant with multiple self
# children is branching recursion. Unary wrappers without an empty terminator
# or without payload preceding the recursive edge are likewise not lists.

function clear_tokens(    i) {
    for (i in token_kind) {
        delete token_kind[i]
        delete token_value[i]
        delete token_line[i]
    }
    token_count = 0
}

function clear_queue(    i) {
    for (i in queue_text) {
        delete queue_text[i]
        delete queue_outer_line[i]
        delete queue_depth[i]
    }
    queue_count = 0
}

function add_token(kind, value, line) {
    token_count += 1
    token_kind[token_count] = kind
    token_value[token_count] = value
    token_line[token_count] = line
}

function add_embedded(text, outer_line, depth) {
    if (index(text, "(defenum") == 0) {
        return
    }
    queue_count += 1
    queue_text[queue_count] = text
    queue_outer_line[queue_count] = outer_line
    queue_depth[queue_count] = depth
}

function tokenize(text, source_outer_line, source_depth,
                  i, n, c, next_c, line, start_line, value) {
    clear_tokens()
    i = 1
    n = length(text)
    line = 1
    while (i <= n) {
        c = substr(text, i, 1)
        if (c == " " || c == "\t" || c == "\r") {
            i += 1
        } else if (c == "\n") {
            line += 1
            i += 1
        } else if (c == ";") {
            while (i <= n && substr(text, i, 1) != "\n") {
                i += 1
            }
        } else if (c == "(") {
            add_token("open", c, line)
            i += 1
        } else if (c == ")") {
            add_token("close", c, line)
            i += 1
        } else if (c == "\"") {
            start_line = line
            value = ""
            i += 1
            while (i <= n) {
                c = substr(text, i, 1)
                if (c == "\"") {
                    i += 1
                    break
                }
                if (c == "\\" && i < n) {
                    next_c = substr(text, i + 1, 1)
                    if (next_c == "n") {
                        value = value "\n"
                    } else if (next_c == "r") {
                        value = value "\r"
                    } else if (next_c == "t") {
                        value = value "\t"
                    } else {
                        value = value next_c
                    }
                    i += 2
                } else {
                    value = value c
                    if (c == "\n") {
                        line += 1
                    }
                    i += 1
                }
            }
            add_token("string", value, start_line)
            if (source_depth == 0) {
                add_embedded(value, start_line, 1)
            } else {
                add_embedded(value, source_outer_line, source_depth + 1)
            }
        } else {
            value = ""
            start_line = line
            while (i <= n) {
                c = substr(text, i, 1)
                if (c == " " || c == "\t" || c == "\r" || c == "\n" ||
                    c == "(" || c == ")" || c == "\"" || c == ";") {
                    break
                }
                value = value c
                i += 1
            }
            if (value != "") {
                add_token("atom", value, start_line)
            }
        }
    }
}

function form_end(start, limit,    depth, i) {
    if (token_kind[start] != "open") {
        return start
    }
    depth = 0
    for (i = start; i <= limit; i += 1) {
        if (token_kind[i] == "open") {
            depth += 1
        } else if (token_kind[i] == "close") {
            depth -= 1
            if (depth == 0) {
                return i
            }
        }
    }
    return limit
}

function nominal_base(name,    parts, count) {
    count = split(name, parts, ".")
    return parts[count]
}

function nominal_matches_at(at, family,    value) {
    if (token_kind[at] == "atom") {
        value = token_value[at]
        return value == family || nominal_base(value) == nominal_base(family)
    }
    if (token_kind[at] == "open" && token_kind[at + 1] == "atom") {
        value = token_value[at + 1]
        return value == family || nominal_base(value) == nominal_base(family)
    }
    return 0
}

function field_box_self_count(start, finish, family,
                              count, i, box_end) {
    count = 0
    for (i = start; i <= finish; i += 1) {
        if (token_kind[i] != "open" ||
            token_kind[i + 1] != "atom" ||
            token_value[i + 1] != "Box") {
            continue
        }
        box_end = form_end(i, finish)
        if (nominal_matches_at(i + 2, family)) {
            count += 1
        }
        i = box_end
    }
    return count
}

function name_ends_cons(name) {
    return tolower(name) ~ /cons$/
}

function fixture_direct_path(path) {
    return path ~ /^examples\// ||
        path ~ /^tests\// ||
        path ~ /^src\/tests\// ||
        path ~ /^src\/[^/]*_tests[.]tl$/
}

function record_finding(path, line, embedded_line, family, variants,
                        source_depth) {
    findings += 1
    if (source_depth == 0) {
        printf "%s:%d: zero-cons: %s stores boxed self-tail storage in %s\n",
            path, line, family, variants > "/dev/stderr"
    } else {
        printf "%s:%d: zero-cons: %s stores boxed self-tail storage in %s (embedded source line %d)\n",
            path, line, family, variants, embedded_line > "/dev/stderr"
    }
}

function inspect_defenum(start, finish, path, source_outer_line, source_depth,
                         family, i, variant_end, variant_name, field_index,
                         field_end, self_count, variant_self_count,
                         recursive_variants, recursive_variant_count,
                         has_zero, forced, branching, all_tail, payload_tail,
                         list_shaped, definition_line, consider) {
    if (token_kind[start + 2] != "atom") {
        return
    }
    family = token_value[start + 2]
    definition_line = token_line[start]
    enum_count += 1

    has_zero = 0
    forced = 0
    branching = 0
    all_tail = 1
    payload_tail = 0
    recursive_variant_count = 0
    recursive_variants = ""

    i = start + 3
    while (i < finish) {
        if (token_kind[i] != "open") {
            i += 1
            continue
        }
        variant_end = form_end(i, finish)
        if (token_kind[i + 1] != "atom" ||
            substr(token_value[i + 1], 1, 1) == ":") {
            i = variant_end + 1
            continue
        }
        variant_name = token_value[i + 1]
        field_index = 0
        variant_self_count = 0
        variant_has_payload = 0
        j = i + 2
        while (j < variant_end) {
            if (token_kind[j] == "close") {
                break
            }
            if (token_kind[j] == "open") {
                field_end = form_end(j, variant_end)
            } else {
                field_end = j
            }
            self_count = field_box_self_count(j, field_end, family)
            if (self_count > 0) {
                variant_self_count += self_count
                if (field_end < variant_end && field_index >= 0) {
                    self_field_index = field_index
                }
            } else {
                variant_has_payload = 1
            }
            field_index += 1
            j = field_end + 1
        }

        if (field_index == 0) {
            has_zero = 1
        }
        if (variant_self_count > 0) {
            recursive_variant_count += 1
            if (recursive_variants == "") {
                recursive_variants = variant_name
            } else {
                recursive_variants = recursive_variants ", " variant_name
            }
            if (name_ends_cons(variant_name)) {
                forced = 1
            } else if (variant_self_count > 1) {
                branching = 1
            }
            if (self_field_index != field_index - 1) {
                all_tail = 0
            }
            if (variant_has_payload) {
                payload_tail = 1
            }
        }
        i = variant_end + 1
    }

    if (recursive_variant_count == 0) {
        return
    }
    list_shaped = forced ||
        (has_zero && all_tail && payload_tail && !branching)
    if (!list_shaped) {
        return
    }

    consider = mode == "full" ||
        source_depth > 0 ||
        fixture_direct_path(path)
    if (!consider) {
        return
    }
    if (source_depth == 0) {
        record_finding(path,
            definition_line,
            definition_line,
            family,
            recursive_variants,
            source_depth)
    } else {
        record_finding(path,
            source_outer_line,
            definition_line,
            family,
            recursive_variants,
            source_depth)
    }
}

function inspect_tokens(path, source_outer_line, source_depth,
                        i, finish) {
    for (i = 1; i <= token_count - 1; i += 1) {
        if (token_kind[i] == "open" &&
            token_kind[i + 1] == "atom" &&
            token_value[i + 1] == "defenum") {
            finish = form_end(i, token_count)
            inspect_defenum(i,
                finish,
                path,
                source_outer_line,
                source_depth)
            i = finish
        }
    }
}

function analyze_file(path, text,    queue_index, depth, outer_line) {
    clear_queue()
    queue_count = 1
    queue_text[1] = text
    queue_outer_line[1] = 1
    queue_depth[1] = 0

    for (queue_index = 1; queue_index <= queue_count; queue_index += 1) {
        depth = queue_depth[queue_index]
        outer_line = queue_outer_line[queue_index]
        tokenize(queue_text[queue_index], outer_line, depth)
        inspect_tokens(path, outer_line, depth)
    }
}

BEGIN {
    if (mode != "full" && mode != "fixtures") {
        print "zero-cons: mode must be full or fixtures" > "/dev/stderr"
        exit 2
    }
    if (manifest == "") {
        print "zero-cons: missing scanner manifest" > "/dev/stderr"
        exit 2
    }

    file_count = 0
    manifest_status = getline path < manifest
    if (manifest_status < 0) {
        printf "zero-cons: cannot read manifest %s\n", manifest > "/dev/stderr"
        exit 2
    }
    while (manifest_status > 0) {
        if (path == "") {
            manifest_status = getline path < manifest
            continue
        }
        text = ""
        source_status = getline source_line < path
        if (source_status < 0) {
            printf "zero-cons: cannot read source %s\n", path > "/dev/stderr"
            exit 2
        }
        while (source_status > 0) {
            text = text source_line "\n"
            source_status = getline source_line < path
        }
        close(path)
        sub(/^[.]\//, "", path)
        analyze_file(path, text)
        file_count += 1
        manifest_status = getline path < manifest
    }
    close(manifest)

    if (findings > 0) {
        printf "zero-cons: %d list-shaped defenum finding(s) across %d TypeLisp files (%s mode)\n",
            findings, file_count, mode > "/dev/stderr"
        exit 1
    }
    printf "zero-cons: 0 findings across %d TypeLisp files and %d balanced defenum forms (%s mode)\n",
        file_count, enum_count, mode
    exit 0
}
