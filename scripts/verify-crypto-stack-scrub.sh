#!/usr/bin/env sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"
. "$ROOT/scripts/lib-gate.sh"
gate_compiler
. "$ROOT/scripts/lib-native-link.sh"
native_link_detect_host
configure_toolchain
base=${CRYPTO_STACK_SCRUB_WORKDIR:-target/exp/crypto-stack-scrub}
mkdir -p "$base"
work=$(mktemp -d "$base/run.XXXXXX")
sha256sum -c tests/fixtures/crypto-aes/stack-residue-mutants.sha256
cat > "$work/inline-files.txt" <<'EOF'
stdlib/tests/crypto_aes_lifecycle_inline.tl
stdlib/tests/crypto_aes_kat_inline.tl
stdlib/tests/crypto_aes128_gcm_kat_inline.tl
stdlib/tests/crypto_aes128_gcm_inline.tl
stdlib/tests/crypto_aes_core_inline.tl
stdlib/tests/crypto_aes_fips_inline.tl
stdlib/tests/crypto_aes_work_inline.tl
EOF
sha256sum "$COMPILER" "$0" scripts/check-crypto-stack-scrub.sh \
    stdlib/crypto_aes_core.tl stdlib/crypto_aes128_gcm.tl \
    stdlib/crypto_ghash_core.tl stdlib/crypto_secret.tl \
    stdlib/crypto_stack_scrub.tl \
    tests/fixtures/crypto-aes/stack-residue.tl \
    tests/fixtures/crypto-aes/stack-residue-mutants.tsv > "$work/inputs.sha256"
while IFS= read -r input; do
    sha256sum "$input" >> "$work/inputs.sha256"
done < "$work/inline-files.txt"
printf 'target\topt\tmutant\texit\n' > "$work/results.tsv"
tab=$(printf '\t')

verify_rep_rejections() {
    input=$1
    opt_level=$2
    # The original store form remains a valid input to the residue gate.
    if ! awk '
        /^_tl_stdlib_crypto_stack_scrub_stdlib_crypto_stack_scrub_block_bang:$/ { block=1 }
        /^ *\.(size|seh_endproc|globl)( |$)/ { block=0 }
        block && /^    rep stosq$/ { found=1 }
        END { exit !found }
    ' "$input"; then return; fi
    for mutation in unknown-count out-of-frame nonzero-value unknown-value unknown-destination wrong-slot changed-stack backwards missing-wipe \
        octal-count nondecimal-count octal-frame octal-offset octal-spill octal-reload octal-chunks overwritten-spill preserved-spill; do
        output="$work/opt$opt_level-rep-$mutation"
        mkdir -p "$output"
        awk -v mutation="$mutation" -v target="$NL_BOOTSTRAP_TARGET" '
            /^_tl_stdlib_crypto_stack_scrub_stdlib_crypto_stack_scrub_block_bang:$/ { block=1 }
            /^ *\.(size|seh_endproc|globl)( |$)/ { block=0 }
            block && mutation=="octal-frame" && /^    (subq|addq) \$[1-9][0-9]*, %rsp$/ {
                sub(/\$/,"$0"); mutated=1
            }
            block && /^    leaq [0-9]+\(%rsp\), %r[a-z0-9]+$/ && !array_reg {
                array_reg=$3
                if (mutation=="octal-offset") {
                    sub(/leaq /,"leaq 0"); mutated=1
                }
            }
            block && /^    rep stosq$/ {
                if (mutation=="unknown-count") print "    movq %r10, %rcx"
                if (mutation=="out-of-frame") print "    movl $2147483647, %ecx"
                if (mutation=="nonzero-value") print "    movl $1, %eax"
                if (mutation=="unknown-value") print "    movq %r10, %rax"
                if (mutation=="unknown-destination") print "    movq %r10, %rdi"
                if (mutation=="wrong-slot") print "    leaq (%rsp), %rdi"
                if (mutation=="changed-stack") print "    subq $8, %rsp"
                if (mutation=="backwards") print "    std"
                if (mutation=="octal-count") print "    movl $0102, %ecx"
                if (mutation=="nondecimal-count") print "    movl $0x66, %ecx"
                # 104 lies inside the emitted block fill but sorts below both
                # of its current starting offsets (8 and 16) as a string.
                if (mutation ~ /^(octal-spill|octal-reload|overwritten-spill|preserved-spill)$/) {
                    slot=(mutation=="overwritten-spill" ? "104" : "0")
                    print "    movq %rdi, " (mutation=="octal-spill" ? "0" : "") slot "(%rsp)"
                }
                if (mutation !~ /^(missing-wipe|octal-frame|octal-offset|octal-chunks)$/) mutated=1
                filled=1
            }
            block && filled && mutation=="octal-chunks" && /^    movl \$1, %(esi|edx)$/ {
                sub(/\$1,/,"$01,"); mutated=1
            }
            block && filled && mutation=="missing-wipe" && /^    callq? / {
                print "    nop"; mutated=1; next
            }
            block && filled && slot!="" && /^    callq? / {
                arg=(target ~ /windows/ ? "%rcx" : $2 ~ /^"/ ? array_reg : "%rdi")
                if (!arg) exit 1
                print "    movq " (mutation=="octal-reload" ? "0" : "") slot "(%rsp), " arg
                slot=""
            }
            { print }
            END { if (!mutated) exit 1 }
        ' "$input" > "$output/input.s"
        if [ "$mutation" = preserved-spill ]; then
            scripts/check-crypto-stack-scrub.sh "$output/input.s" "$output" "$NL_BOOTSTRAP_TARGET" "$opt_level" 0 > "$output/stdout" 2> "$output/stderr"
            continue
        fi
        if scripts/check-crypto-stack-scrub.sh "$output/input.s" "$output" "$NL_BOOTSTRAP_TARGET" "$opt_level" 0 > "$output/stdout" 2> "$output/stderr" ||
            ! grep -Fq 'unproved REP STOSQ reclaim interval: block' "$output/stderr"; then
            echo "unproved REP STOSQ was not rejected: target=$NL_BOOTSTRAP_TARGET opt=$opt_level mutation=$mutation" >&2
            exit 1
        fi
    done
}

for opt in 1 2; do
    "$COMPILER" test --batch "$work/inline-files.txt" \
        --stdlib-root "$ROOT/stdlib" --opt-level "$opt"
    # Stack-residue probes inspect and rewrite emitted stdlib crypto bodies at
    # opt 1 and 2 rather than linking against libstdlib.a.
    "$COMPILER" compile tests/fixtures/crypto-aes/stack-residue.tl \
        --stdlib-root "$ROOT/stdlib" --no-prebuilt-stdlib \
        --target "$NL_BOOTSTRAP_TARGET" \
        --opt-level "$opt" -o "$work/opt$opt.s"
    verify_rep_rejections "$work/opt$opt.s" "$opt"
    while IFS="$tab" read -r name phase expected; do
        case "$name" in ''|\#*) continue ;; esac
        case "$phase" in 0|1|2|3|4|5|6|7|8|-1|-2|-3|-4|-5|-6|-7|-8) ;; *) echo 'invalid residue mutant phase' >&2; exit 1 ;; esac
        case "$name" in *[!a-z0-9-]*) echo 'invalid residue mutant name' >&2; exit 1 ;; esac
        output="$work/opt$opt-$name"
        scripts/check-crypto-stack-scrub.sh "$work/opt$opt.s" "$output" "$NL_BOOTSTRAP_TARGET" "$opt" "$phase"
        assemble_and_link crypto-stack-residue "$output/probe.s" "$output/probe.$NL_OBJ_EXT" "$output/probe$NL_BIN_EXT"
        status=0
        "$output/probe$NL_BIN_EXT" > "$output/stdout" 2> "$output/stderr" || status=$?
        printf '%s\t%s\t%s\t%s\n' "$NL_BOOTSTRAP_TARGET" "$opt" "$name" "$status" >> "$work/results.tsv"
        if [ "$status" != "$expected" ] || [ -s "$output/stdout" ] || [ -s "$output/stderr" ]; then
            echo "residue probe failed: target=$NL_BOOTSTRAP_TARGET opt=$opt mutant=$name exit=$status expected=$expected" >&2
            exit 1
        fi
    done < tests/fixtures/crypto-aes/stack-residue-mutants.tsv
done
echo "crypto stack residue coverage: both native optimization levels and 32 pinned negative probes passed ($work)"
