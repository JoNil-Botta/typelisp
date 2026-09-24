# expand-integration-manifest.awk - one host's rows of tests/integration/native.manifest.
#
#   awk -v host=linux|windows -f scripts/expand-integration-manifest.awk tests/integration/native.manifest
#
# Merged row:   name|hosts|opt|source|exit|stdout|args|deps|extra[|suite-members]
# Emitted row:  name|source|exit|stdout|args|deps[|extra[|suite-members]]
# (the per-host format scripts/validate-integration-manifest.awk checks and
# scripts/verify-integration.sh runs).
#
# hosts is all, linux or windows. opt lists the levels a row runs at, in
# order: `-` is the batched default level and 0/1/2 a standalone
# `--opt-level N` compile (extra prefixed `opt-level:N+`). A row with several
# levels expands to `name` for `-` and `name_optN` for N; a row with one level
# keeps its name. extra is `-` for none. `$SRC` in extra is the staged source
# path the compiler reports: target/integration-verify/HOST/ROW/ROW.tl.

function fail(message) {
    printf "native.manifest line %d: %s\n", FNR, message > "/dev/stderr"
    failed = 1
    exit 1
}

BEGIN {
    FS = "|"
    if (host != "linux" && host != "windows") {
        print "expand-integration-manifest: host must be linux or windows" > "/dev/stderr"
        failed = 1
        exit 1
    }
}

{
    sub(/\r$/, "")
    if ($0 == "" || $0 ~ /^#/) next
    if (NF != 9 && NF != 10) fail("expected 9 fields, or 10 with suite members: " $0)
    name = $1
    hosts = $2
    if (hosts != "all" && hosts != "linux" && hosts != "windows") fail("invalid hosts for " name ": " hosts)
    if (hosts != "all" && hosts != host) next
    if ($3 == "") fail("empty opt list for " name)
    count = split($3, levels, ",")
    for (i = 1; i <= count; i++) {
        level = levels[i]
        if (level != "-" && level != "0" && level != "1" && level != "2") fail("invalid opt level for " name ": " level)
        row = (level == "-" || count == 1) ? name : name "_opt" level
        if (emitted[row]++) fail("duplicate expanded row " row)
        extra = ($9 == "-") ? "" : $9
        if (level != "-") extra = "opt-level:" level "+" extra
        gsub(/\$SRC/, "target/integration-verify/" host "/" row "/" row ".tl", extra)
        line = row "|" $4 "|" $5 "|" $6 "|" $7 "|" $8
        if (NF == 10) line = line "|" extra "|" $10
        else if (extra != "") line = line "|" extra
        print line
    }
}

END { if (failed) exit 1 }
