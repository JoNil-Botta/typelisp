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
    if (count != 6 && count != 7) {
        fail("manifest line " FNR " must have 6 fields, or 7 with an extra field: " line)
    }

    name = field[1]
    source = field[2]
    want = field[3]
    deps = field[6]
    extra = count == 7 ? field[7] : ""

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
    if (extra != "" && extra !~ /^expected-stderr:.+/) {
        fail("manifest line " FNR " has invalid extra field for " name ": " extra)
    }
    if (!files[source]) {
        fail("manifest line " FNR " names missing source for " name ": " source)
    }
    if (seen[name]++) {
        fail("manifest line " FNR " duplicates integration case " name)
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
    for (name in known) print name > known_out
}
