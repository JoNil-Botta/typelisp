# Validate one native-integration manifest against a newline-delimited catalog
# of repository-relative files.  Keeping parsing, duplicate detection, source
# lookup, and dependency resolution in this process avoids per-row utility
# launches on Windows.

function fail(message) {
    print message > "/dev/stderr"
    failed = 1
    exit 1
}

function base_name(path, value) {
    value = path
    sub(/^.*\//, "", value)
    sub(/\.tl$/, "", value)
    return value
}

function directory_name(path, value) {
    value = path
    if (value !~ /\//) {
        return "."
    }
    sub(/\/[^/]*$/, "", value)
    return value
}

function integration_source(path) {
    return path ~ /^tests\/integration\/.+\.tl$/
}

function file_contains(path, needle, line) {
    while ((getline line < path) > 0) {
        if (index(line, needle) != 0) {
            close(path)
            return 1
        }
    }
    close(path)
    return 0
}

function dependency_source(dep, source_dir, candidate) {
    if (dep ~ /^stdlib\// || dep ~ /^benchmarks\//) {
        return files[dep] ? dep : ""
    }
    if (dep == "sym_i64_env_core.tl") {
        return files["src/sym_i64_env.tl"] ? "src/sym_i64_env.tl" : ""
    }

    candidate = source_dir "/" dep
    if (files[candidate]) return candidate
    candidate = "src/" dep
    if (files[candidate]) return candidate
    candidate = "src/tests/" dep
    if (files[candidate]) return candidate
    candidate = "tests/integration/" dep
    if (files[candidate]) return candidate
    return ""
}

FILENAME == catalog {
    sub(/^\.\//, "")
    sub(/\r$/, "")
    files[$0] = 1
    next
}

{
    sub(/\r$/, "")
    line = $0
    if (line == "" || line ~ /^#/) next

    count = split(line, field, /\|/)
    if (count != 6 && count != 7 && count != 8) {
        fail("manifest line " FNR " must have 6 fields, 7 with an extra field, or 8 with suite members: " line)
    }

    name = field[1]
    source = field[2]
    want = field[3]
    deps = field[6]
    extra = count == 7 ? field[7] : ""
    if (count == 8) extra = field[7]
    suite_spec = count == 8 ? field[8] : ""

    if (name == "" || name !~ /^[A-Za-z0-9_]+$/) {
        fail("manifest line " FNR " has invalid case name: " name)
    }
    if (source == "" || source !~ /\.tl$/) {
        fail("manifest line " FNR " has invalid source path for " name ": " source)
    }
    if (source ~ /^\// || source ~ /\.\./) {
        fail("manifest line " FNR " has unsafe source path for " name ": " source)
    }
    if (want == "" || want !~ /^[0-9]+$/) {
        fail("manifest line " FNR " has invalid exit code for " name ": " want)
    }
    if (extra == "expected-stderr:") {
        fail("manifest line " FNR " has empty expected stderr for " name)
    }
    if (extra != "" && extra != "stage-stdlib" && extra !~ /^expected-stderr:.+/) {
        fail("manifest line " FNR " has invalid extra field for " name ": " extra)
    }
    if (suite_spec == "suite-members:") {
        fail("manifest line " FNR " has empty suite members for " name)
    }
    if (suite_spec != "" && suite_spec !~ /^suite-members:.+/) {
        fail("manifest line " FNR " has invalid suite members field for " name ": " suite_spec)
    }
    if (!files[source]) {
        fail("manifest line " FNR " names missing source for " name ": " source)
    }
    if (seen[name]++) {
        fail("manifest line " FNR " duplicates integration case " name)
    }
    manifest_source[source] = name

    if (suite_spec ~ /^suite-members:/) {
        members = substr(suite_spec, length("suite-members:") + 1)
        member_count = split(members, member, /[[:space:]]+/)
        for (i = 1; i <= member_count; i++) {
            resolved_member = dependency_source(member[i], directory_name(source))
            if (resolved_member == "") {
                fail("manifest line " FNR " names missing suite member for " name ": " member[i])
            }
            if (resolved_member !~ /^src\/tests\/.+_smoke\.tl$/) {
                fail("manifest line " FNR " has invalid suite member for " name ": " resolved_member)
            }
            if (!file_contains(root "/" resolved_member, "(define (main)")) {
                fail("manifest line " FNR " suite member has no main for " name ": " resolved_member)
            }
            if (!file_contains(root "/" source, base_name(resolved_member))) {
                fail("manifest line " FNR " suite source does not name member for " name ": " resolved_member)
            }
            if (suite_member_owner[resolved_member] != "") {
                fail("manifest line " FNR " duplicates suite member " resolved_member)
            }
            suite_member_owner[resolved_member] = name
        }
    }

    if (integration_source(source)) known[base_name(source)] = 1
    source_dir = directory_name(source)
    if (deps != "" && deps != "-") {
        dep_count = split(deps, dependency, /[[:space:]]+/)
        for (i = 1; i <= dep_count; i++) {
            dep = dependency[i]
            if (dep ~ /^\// || dep ~ /\.\./) {
                fail("manifest line " FNR " has unsafe dependency path for " name ": " dep)
            }
            resolved = dependency_source(dep, source_dir)
            if (resolved == "") {
                fail("manifest line " FNR " names missing dependency for " name ": " dep)
            }
            if (integration_source(resolved)) known[base_name(resolved)] = 1
        }
    }
}

END {
    if (failed) exit 1
    for (member_path in suite_member_owner) {
        if (manifest_source[member_path] != "") {
            fail("suite member is also a manifest source: " member_path)
        }
    }
    for (name in known) print name > known_out
}
