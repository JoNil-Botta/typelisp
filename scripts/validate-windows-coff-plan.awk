# Validate a `compile --batch --windows-coff-plan` result against its input.
# On success, emit one normalized row per artifact:
# source|kind|selected-path|reason|object-path|assembly-path|forced

BEGIN {
    FS = "|"
    OFS = "|"
    batch_file = ARGV[1]
    plan_file = ARGV[2]
}

function fail(message) {
    print message > "/dev/stderr"
    failed = 1
    exit 1
}

FILENAME == batch_file {
    if (NF != 3 && NF != 4) {
        fail("Windows COFF batch input line " FNR " must have 3 fields, or 4 with force-assembly")
    }
    if ($1 == "" || $2 == "" || $3 == "") {
        fail("Windows COFF batch input line " FNR " has an empty required field")
    }
    if ($2 == $3) {
        fail("Windows COFF batch input line " FNR " reuses one path for object and assembly")
    }
    if (NF == 4 && $4 != "force-assembly") {
        fail("Windows COFF batch input line " FNR " has an invalid fourth field: " $4)
    }

    input_count++
    source[input_count] = $1
    object_path[input_count] = $2
    assembly_path[input_count] = $3
    forced[input_count] = (NF == 4)
    next
}

FILENAME == plan_file {
    plan_count++
    if (plan_count > input_count) {
        fail("Windows COFF plan has more rows than its batch input")
    }
    if (NF != 4) {
        fail("Windows COFF plan line " FNR " must have 4 fields")
    }
    if ($1 != source[plan_count]) {
        fail("Windows COFF plan line " FNR " source mismatch: expected " source[plan_count] ", got " $1)
    }

    if ($2 == "coff-object") {
        if (forced[plan_count]) {
            fail("Windows COFF plan line " FNR " selected an object for a forced-assembly row")
        }
        if ($3 != object_path[plan_count]) {
            fail("Windows COFF plan line " FNR " selected the wrong object path")
        }
        if ($4 != "none") {
            fail("Windows COFF plan line " FNR " object reason must be none")
        }
    } else if ($2 == "assembly") {
        if ($3 != assembly_path[plan_count]) {
            fail("Windows COFF plan line " FNR " selected the wrong assembly path")
        }
        if ($4 == "" || $4 == "none") {
            fail("Windows COFF plan line " FNR " assembly reason must be explicit")
        }
        if (forced[plan_count] && $4 != "forced-assembly") {
            fail("Windows COFF plan line " FNR " lost its forced-assembly reason")
        }
        if (!forced[plan_count] && $4 == "forced-assembly") {
            fail("Windows COFF plan line " FNR " reported forced-assembly for an automatic row")
        }
    } else {
        fail("Windows COFF plan line " FNR " has an invalid artifact kind: " $2)
    }

    print $1, $2, $3, $4, object_path[plan_count], assembly_path[plan_count], (forced[plan_count] ? 1 : 0)
    next
}

END {
    if (failed) {
        exit 1
    }
    if (input_count == 0) {
        fail("Windows COFF batch input is empty")
    }
    if (plan_count != input_count) {
        fail("Windows COFF plan row count mismatch: expected " input_count ", got " plan_count)
    }
}
