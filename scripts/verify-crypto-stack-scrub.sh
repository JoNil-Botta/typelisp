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
for opt in 1 2; do
    "$COMPILER" test --batch "$work/inline-files.txt" \
        --stdlib-root "$ROOT/stdlib" --opt-level "$opt"
    "$COMPILER" compile tests/fixtures/crypto-aes/stack-residue.tl \
        --stdlib-root "$ROOT/stdlib" --target "$NL_BOOTSTRAP_TARGET" \
        --opt-level "$opt" -o "$work/opt$opt.s"
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
