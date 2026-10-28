#!/usr/bin/env sh
set -eu

# Run every entry-helper transcript row through the actual translator, without
# compiling anything. The setup-step `if !` context disables errexit, so a
# missing explicit guard would let ld or a later transcript step mask failure.
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
entry_root=${1:-"$ROOT/target/exp/linux-entry-transcripts"}
mkdir -p "$entry_root"
entry_work=$(mktemp -d "$entry_root/run.XXXXXX")
entry_work=$(CDPATH= cd -- "$entry_work" && pwd)
mkdir -p "$entry_work/bin"
entry_real_grep=$(command -v grep)
export entry_real_grep
awk '/^sh .*linux_entry_symbol_for_asm/ {print}' \
    "$ROOT/tests/codegen/integration-fixtures.cases" > "$entry_work/callers"
[ "$(wc -l < "$entry_work/callers")" -eq 11 ]
printf 'caller\tcontrol\ttiming\twant\tstatus\n' > "$entry_work/results.tsv"
cat > "$entry_work/bin/grep" <<'EOF'
#!/usr/bin/env sh
case "${2:-}" in
    '^_tl_start:$' | '^_start:$')
        printf 'grep:%s\n' "$2" >> "$entry_case/trace"
        case "$entry_control:$2" in
            first-error:'^_tl_start:$' | second-error:'^_start:$') exit 2 ;;
            tool-status:'^_tl_start:$') exit 23 ;;
        esac
        ;;
esac
exec "$entry_real_grep" "$@"
EOF
cat > "$entry_work/bin/as" <<'EOF'
#!/usr/bin/env sh
printf 'assemble\n' >> "$entry_case/trace"
EOF
cat > "$entry_work/bin/ld" <<'EOF'
#!/usr/bin/env sh
while [ "$#" -gt 0 ] && [ "$1" != -e ]; do shift; done
[ "$#" -ge 2 ] || exit 24
printf 'link:%s\n' "$2" >> "$entry_case/trace"
[ "$2" = "$entry_expected" ] || exit 24
[ "$entry_control" != link-error ] || exit 29
EOF
cat > "$entry_work/bin/compiler" <<'EOF'
#!/usr/bin/env sh
printf 'compiler\n' >> "$entry_case/trace"
exit 97
EOF
chmod +x "$entry_work/bin/grep" "$entry_work/bin/as" "$entry_work/bin/ld" "$entry_work/bin/compiler"
entry_index=0
while IFS= read -r entry_row; do
    entry_index=$((entry_index + 1))
    entry_asm=$(printf '%s\n' "$entry_row" | sed 's/.*linux_entry_symbol_for_asm "\([^"]*\)".*/\1/')
    for entry_control in modern legacy fallback first-error second-error tool-status link-error; do
        for entry_timing in 0 1; do
            entry_case="$entry_work/$entry_index-$entry_control-$entry_timing"
            mkdir -p "$entry_case"
            : > "$entry_case/trace"
            entry_expected=_tl_start
            entry_symbol=_tl_start
            entry_want=0
            case "$entry_control" in
                legacy | second-error) entry_symbol=_start; entry_expected=_start ;;
                fallback) entry_symbol= ;;
            esac
            case "$entry_control" in
                first-error | second-error) entry_want=2 ;;
                tool-status) entry_want=23 ;;
                link-error) entry_want=1 ;;
            esac
            # Keep each live row byte-for-byte, including its shell grouping,
            # while providing only its assembly input and captured fold path.
            {
                printf 'do none\ntarget -\nopt -\ncase entry-transcript\n'
                printf 'sh CCV_fold="{{dir}}/fold"\nfile %s\n' "$entry_asm"
                [ -z "$entry_symbol" ] || printf '%s:\n' "$entry_symbol"
                printf 'end-file\n%s\n' "$entry_row"
                printf 'sh printf "dependent\\n" >> "$entry_case/trace"\n'
            } > "$entry_case/input.cases"
            export entry_case entry_control entry_expected
            entry_status=0
            env PATH="$entry_work/bin:$PATH" TYPELISP_BIN="$entry_work/bin/compiler" \
                CODEGEN_CASES_WORKDIR="$entry_case/output" TYPELISP_CI_TIMING="$entry_timing" \
                TYPELISP_CI_TIMING_FILE="$entry_case/timing.tsv" \
                TYPELISP_CI_TIMING_GATE=entry-transcripts TYPELISP_CI_TIMING_HOST=linux \
                sh "$ROOT/scripts/verify-codegen-cases.sh" "$entry_case/input.cases" \
                > "$entry_case/stdout" 2> "$entry_case/stderr" || entry_status=$?
            printf '%s\t%s\t%s\t%s\t%s\n' "$entry_index" "$entry_control" \
                "$entry_timing" "$entry_want" "$entry_status" >> "$entry_work/results.tsv"
            [ "$entry_status" -eq "$entry_want" ] || {
                cat "$entry_case/stderr" >&2
                echo "FAIL: transcript $entry_case expected $entry_want, got $entry_status" >&2
                exit 1
            }
            # An assembler failure is not planted here; rows either assemble
            # once before selection or link two already assembled objects.
            : > "$entry_case/expected"
            case "$entry_row" in *'sh as '*) printf 'assemble\n' >> "$entry_case/expected" ;; esac
            printf 'grep:^_tl_start:$\n' >> "$entry_case/expected"
            case "$entry_control" in
                legacy | fallback | second-error) printf 'grep:^_start:$\n' >> "$entry_case/expected" ;;
            esac
            case "$entry_control" in
                first-error | second-error | tool-status) ;;
                *) printf 'link:%s\ndependent\n' "$entry_expected" >> "$entry_case/expected" ;;
            esac
            cmp "$entry_case/trace" "$entry_case/expected"
            # These setup statements are not timed steps in the translator.
            # Both timer modes must still preserve the fatal helper status.
            [ ! -e "$entry_case/timing.tsv" ]
        done
    done
done < "$entry_work/callers"
[ "$(wc -l < "$entry_work/results.tsv")" -eq 155 ]
echo "Linux entry transcript self-test passed (11 callers, 154 controls; $entry_work)"
