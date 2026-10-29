#!/usr/bin/env sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$ROOT/scripts/lib-ci-compiler-artifact.sh"
work=${1:-$ROOT/target/exp/ci-compiler-artifact-selftest-$$}
cica_owned "$ROOT" "$work"
[ ! -e "$work" ] || cica_fail 'fixture root must be fresh'
mkdir -p "$work"
CICA_SCRATCH=$work/scratch
mkdir "$CICA_SCRATCH"
: > "$work/results.jsonl"
record_result() { cica_jq -cn --arg n "$1" --arg s "$2" '{case:$n,status:$s}' >> "$work/results.jsonl"; }
# Run the production CLI with a synthetic, independently specified Actions
# context. No test-only bypass exists in its verifier or publisher. A lane
# job's attempt and lane come from fixture_attempt and fixture_lane.
fixture_attempt=2
fixture_lane=
fixture_env() {
    env GITHUB_ACTIONS=true GITHUB_EVENT_NAME=pull_request GITHUB_SHA="$commit" \
      GITHUB_WORKFLOW_SHA="$commit" GITHUB_RUN_ID=1234 GITHUB_RUN_ATTEMPT="$fixture_attempt" \
      GITHUB_REPOSITORY=owner/repo GITHUB_WORKFLOW_REF=owner/repo/.github/workflows/ci.yml@refs/pull/1/merge \
      GITHUB_EVENT_PATH="$work/event.json" TYPELISP_CI_LANE="$fixture_lane" "$@"
}
fixture_cli() { fixture_env "$ROOT/scripts/ci-compiler-artifact.sh" "$@"; }
source=$work/source
mkdir -p "$source/src" "$source/stdlib" "$source/tests/integration" "$source/scripts"
printf '(define (main) : i64 42)\n' > "$source/src/main.tl"
printf '; fixture stdlib\n' > "$source/stdlib/prelude.tl"
printf 'fixture\n' > "$source/tests/data.txt"
printf 'fixture|all|0,1,2|src/main.tl|42|-|-|-|-\n' > "$source/tests/integration/native.manifest"
printf '*.tl text eol=lf\n*.sh text eol=lf\n' > "$source/.gitattributes"
# A small gate table with the real role producers, and its lane assignment:
# linux-1 isolates build-invariance with its consumer; both hosts duplicate
# only the bootstrap; fixture-gate-c needs (is checked against) gate-b.
cat > "$source/scripts/ci-gates.tsv" <<'EOF'
# fixture gate table
id	hosts	label	needs	compiler	memory	locks	command
fixture-self-test	all	fixture self-test	-	-	256	-	true
bootstrap-fixpoint	all	bootstrap fixpoint	-	-	256	-	true
stage2-opt1-opt2-build-invariance	linux	stage2 opt1/opt2 build-invariance	bootstrap-fixpoint	stage2	256	-	true
fixture-opt2-cli	all	fixture opt2 CLI	bootstrap-fixpoint,stage2-opt1-opt2-build-invariance@linux	stage2	256	-	true
fixture-gate-b	all	fixture gate b	bootstrap-fixpoint	stage2	256	-	true
fixture-gate-c	all	fixture gate c	bootstrap-fixpoint,fixture-gate-b	stage2	256	-	true
EOF
printf 'tool\thosts\tgates\tcheck\tinstall\n' > "$source/scripts/ci-host-tools.tsv"
cat > "$source/scripts/ci-lanes.tsv" <<'EOF'
# fixture lanes
id	linux	windows
fixture-self-test	linux-2	windows-2
bootstrap-fixpoint	linux-2+linux-1	windows-1+windows-2
stage2-opt1-opt2-build-invariance	linux-1	-
fixture-opt2-cli	linux-1	windows-2
fixture-gate-b	linux-2	windows-1
fixture-gate-c	linux-2	windows-1
EOF
cp "$ROOT/scripts/ci-compiler-artifacts.tsv" "$source/scripts/ci-compiler-artifacts.tsv"
cp "$ROOT/scripts/expand-integration-manifest.awk" "$source/scripts/expand-integration-manifest.awk"
CICA_ROOT=$ROOT
cica_recipes | cica_jq -r 'keys[]' > "$work/recipes"
while IFS= read -r recipe; do cp "$ROOT/$recipe" "$source/$recipe"; done < "$work/recipes"
git init -q "$source"
git -C "$source" add .
git -C "$source" -c user.name=fixture -c user.email=fixture@example.invalid commit -qm fixture
commit=$(git -C "$source" rev-parse HEAD)
tree=$(git -C "$source" rev-parse 'HEAD^{tree}')
source_real=$(CDPATH= cd -- "$source" && pwd -P)
cica_jq -nS --arg h "$commit" '{repository:{full_name:"owner/repo"},pull_request:{head:{sha:$h}}}' > "$work/event.json"
CICA_ROOT=$source
# Legacy golden vector, independently checked against the recovered #6883 helper.
golden=$(ci_compiler_artifact_key 1111111111111111111111111111111111111111111111111111111111111111 2222222222222222222222222222222222222222 linux linux-x86_64 '{root}' src,stdlib stdlib,src linux,unix 2 none baseline 'compile src/main.tl' 3333333333333333333333333333333333333333333333333333333333333333 compiler-assembly)
[ "$golden" = 5ece1550f75aff6115c39ab8301dc7ddc2e45bf953641f0658a63b4988d1919e ] || cica_fail 'legacy key changed'
record_result legacy-key-vector pass
cica_jq -nS '{producer_sha256:("1"*64),producer_identity:("2"*40),host:"linux",target:"linux-x86_64",cwd:"{root}",source_roots:"src,stdlib",stdlib_roots:"stdlib,src",cfg:"linux,unix",opt_level:"2",profile:"none",environment:"baseline",argv:"compile src/main.tl",source_set_sha256:("3"*64),output_kind:"compiler-assembly"}' > "$work/golden-fields.json"
[ "$(cica_key_json "$work/golden-fields.json")" = "$golden" ] || cica_fail 'JSON field key differs from canonical key'
record_result legacy-key-json-framing pass
# Two checkouts of one tree can have different raw source manifests. Each
# host must derive its own raw expected bytes rather than normalize oracles.
git -c core.autocrlf=false clone -q --no-hardlinks "$source" "$work/lf-checkout"
git -c core.autocrlf=true clone -q --no-hardlinks "$source" "$work/crlf-checkout"
CICA_ROOT=$work/lf-checkout
cica_sources > "$work/lf.sources"
CICA_ROOT=$work/crlf-checkout
cica_sources > "$work/crlf.sources"
if cmp -s "$work/lf.sources" "$work/crlf.sources"; then cica_fail 'cross-checkout fixture did not produce distinct bytes'; fi
[ "$(git -C "$work/lf-checkout" rev-parse 'HEAD^{tree}')" = "$(git -C "$work/crlf-checkout" rev-parse 'HEAD^{tree}')" ] || cica_fail 'fixture tree changed'
record_result cross-checkout-exact-bytes pass
CICA_ROOT=$source
cica_sources > "$work/sources"
# Exercise both coreutils output markers on every host. Fixture source files
# are LF bytes, so text and binary mode must give identical provenance.
real_sha=$(command -v sha256sum)
for mode in b t; do
    mkdir "$work/sha-$mode"
    cat > "$work/sha-$mode/sha256sum" <<EOF
#!/usr/bin/env sh
exec "$real_sha" -$mode "\$@"
EOF
    chmod +x "$work/sha-$mode/sha256sum"
    (PATH="$work/sha-$mode:$PATH"; export PATH; cica_sources) > "$work/source-mode-$mode"
    cmp -s "$work/sources" "$work/source-mode-$mode" || cica_fail 'coreutils digest marker changed source identity'
    record_result "source-sha256-marker-$mode" pass
done
mkdir "$work/missing-authorities"
if (CICA_ROOT=$work/missing-authorities; cica_inventory) > "$work/missing-inventory.stdout" 2> "$work/missing-inventory.stderr"; then cica_fail 'missing inventory accepted'; fi
record_result missing-inventory rejected
if (CICA_ROOT=$work/missing-authorities; cica_recipes) > "$work/missing-recipes.stdout" 2> "$work/missing-recipes.stderr"; then cica_fail 'missing recipes accepted'; fi
record_result missing-recipes rejected
cica_inventory > "$work/inventory.json"
cica_recipes > "$work/recipe-hashes.json"
# Stand-in producer executes only the --version/--producer-identity protocol.
# Its version is the real CLI format; fixture payloads are never executed.
mkdir -p "$source/target/bootstrap-fixpoint"
cat > "$source/target/bootstrap-fixpoint/stage2" <<EOF
#!/usr/bin/env sh
case "\$1" in
  --version) printf '%s\\n' 'typelisp $commit built unknown' ;;
  --producer-identity) printf '%s\\n' '$tree' ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$source/target/bootstrap-fixpoint/stage2"
printf 'fixture assembly\n' > "$source/target/bootstrap-fixpoint/stage3.s"

# build_lane HOST LANE ATTEMPT VARIANT: reuse the real recording path, then
# carry its complete version into an independently constructed draft that the
# production CLI seals, as the lane's job would after ci-verify.sh --gates.
# VARIANT base, other-seed, other-payload, other-seed-payload, timestamp
# (only the Windows COFF TimeDateStamp differs), missing-gate, missing-oracle
# or extra-gate (the receipt's plan differs from the assignment closure).
build_lane() {
    host=$1 lane=$2 attempt=$3 variant=$4
    CICA_HOST=$host
    case $host in linux) cfg='["linux","unix","target-linux","os-linux"]'; ext= ;; windows) cfg='["windows","target-windows","os-windows"]'; ext=.exe ;; esac
    dir=$source/target/lanes/$lane-a$attempt-$variant
    inputs=$source_real/target/lanes/$lane-a$attempt-$variant-inputs
    mkdir -p "$dir/draft/roles/bootstrap-converged/payload" "$dir/draft/lane" "$inputs"
    fixture_attempt=$attempt fixture_lane=$lane
    GITHUB_ACTIONS=true GITHUB_EVENT_NAME=pull_request GITHUB_SHA=$commit GITHUB_WORKFLOW_SHA=$commit \
      GITHUB_RUN_ID=1234 GITHUB_RUN_ATTEMPT=$attempt GITHUB_REPOSITORY=owner/repo \
      GITHUB_WORKFLOW_REF=owner/repo/.github/workflows/ci.yml@refs/pull/1/merge GITHUB_EVENT_PATH=$work/event.json \
      TYPELISP_CI_LANE=$lane cica_context github > "$dir/draft/context.json"
    owned=$(awk -F '\t' -v c="$([ "$host" = linux ] && echo 2 || echo 3)" -v l="$lane" '!/^#/ && $1 != "id" { split($c, p, "+"); if (p[1] == l) print $1 }' "$source/scripts/ci-lanes.tsv" | paste -sd, -)
    "$source/scripts/ci-verify.sh" --list-gates "$host" --gates "$owned" | sed 1d | cut -f 1 > "$dir/draft/lane/plan.txt"
    printf '%s\n' "$owned" | tr ',' '\n' > "$work/requested"
    case $variant in
      missing-gate) drop=fixture-gate-c ;;
      missing-oracle) drop=fixture-gate-b ;;
      *) drop= ;;
    esac
    if [ -n "$drop" ]; then
        grep -vxF "$drop" "$dir/draft/lane/plan.txt" > "$work/plan" || :; cp "$work/plan" "$dir/draft/lane/plan.txt"
        grep -vxF "$drop" "$work/requested" > "$work/requested-kept" || :; cp "$work/requested-kept" "$work/requested"
    fi
    if [ "$variant" = extra-gate ]; then
        printf 'fixture-unassigned-gate\n' >> "$dir/draft/lane/plan.txt"
        printf 'fixture-unassigned-gate\n' >> "$work/requested"
    fi
    LC_ALL=C sort -u "$work/requested" > "$dir/draft/lane/requested.txt"
    { printf 'id\tstatus\telapsed_s\n'; sed 's/$/	0	1/' "$dir/draft/lane/plan.txt"; } > "$inputs/results.tsv"
    { printf 'gate\tcase_or_chunk\tphase\telapsed_ms\texit\thost\n'
      printf 'ungated\tcompiler-envelope\tartifact-init\t10\t0\t%s\n' "$host"
      while IFS= read -r id; do
          label=$(awk -F '\t' -v id="$id" '$1 == id { print $3 }' "$source/scripts/ci-gates.tsv")
          printf '%s\tall\tgate\t1000\t0\t%s\n%s\tchunk-0\tcompile\t400\t0\t%s\n' "${label:-$id}" "$host" "${label:-$id}" "$host"
      done < "$dir/draft/lane/plan.txt"
      printf 'CI verification\tall\tpartial-verification\t%s\t0\t%s\n' "$((5000 + attempt))" "$host"; } > "$inputs/timing.tsv"
    cp "$work/sources" "$dir/draft/source-set.sha256"
    cica_jq -nS '{as:{sha256:("7"*64),version:"fixture"},ld:{sha256:("7"*64),version:"fixture"},clang:{sha256:("7"*64),version:"fixture"},"lld-link":{sha256:("7"*64),version:"fixture"}}' > "$dir/draft/toolchain.json"
    fixture_cli record "$source" "$dir" "$host" stage3 "$source/target/bootstrap-fixpoint/stage2" compile src/main.tl -o "$source/target/bootstrap-fixpoint/stage3.s" --target linux-x86_64 --cfg linux --cfg unix --cfg target-linux --cfg os-linux --cfg compiler-build-identity --cfg embedded-stdlib-tlci --stdlib-root "$source/src" --opt-level 2
    for payload in compiler previous-stage; do
        file=$dir/draft/roles/bootstrap-converged/payload/$payload
        dd if=/dev/zero of="$file" bs=128 count=1 2>/dev/null
        if [ "$host" = linux ]; then
            printf '\177ELF\002' | dd of="$file" bs=1 conv=notrunc 2>/dev/null
            printf '\076\000' | dd of="$file" bs=1 seek=18 conv=notrunc 2>/dev/null
        else
            printf 'MZ' | dd of="$file" bs=1 conv=notrunc 2>/dev/null
            printf '\100\000\000\000' | dd of="$file" bs=1 seek=60 conv=notrunc 2>/dev/null
            printf 'PE\000\000\144\206' | dd of="$file" bs=1 seek=64 conv=notrunc 2>/dev/null
        fi
    done
    compiler=$dir/draft/roles/bootstrap-converged/payload/compiler
    case $variant in
      other-payload | other-seed-payload) printf X | dd of="$compiler" bs=1 seek=100 conv=notrunc 2>/dev/null ;;
      timestamp) printf '\001\002\003\004' | dd of="$compiler" bs=1 seek=72 conv=notrunc 2>/dev/null ;;
    esac
    seed='{"sha256":"4444444444444444444444444444444444444444444444444444444444444444","identity":"5555555555555555555555555555555555555555"}'
    case $variant in
      other-seed | other-seed-payload) seed='{"sha256":"8888888888888888888888888888888888888888888888888888888888888888","identity":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}' ;;
    esac
    # The lane's ci-verify-*.path handoffs name exact copies of the payloads.
    cp "$compiler" "$inputs/compiler"
    cp "$dir/draft/roles/bootstrap-converged/payload/previous-stage" "$inputs/previous-stage"
    printf '%s\n' "$inputs/compiler" > "$source/target/ci-verify-stage2.path"
    printf '%s\n' "$inputs/previous-stage" > "$source/target/ci-verify-stage1.path"
    cica_generated > "$work/generated-paths"
    while IFS= read -r generated; do
        mkdir -p "$dir/draft/roles/bootstrap-converged/generated/$(dirname -- "$generated")"
        case $generated in
          */git-hash.txt) printf %s "$commit" ;;
          */tree-hash.txt) printf %s "$tree" ;;
          *) printf '%s\n' "fixture $generated" ;;
        esac > "$dir/draft/roles/bootstrap-converged/generated/$generated"
    done < "$work/generated-paths"
    cica_roles "$dir/draft/lane/plan.txt" > "$work/host-roles"
    while IFS= read -r role; do
        base=$dir/draft/roles/$role
        mkdir -p "$base"
        cp "$work/sources" "$base/source-set.sha256"
        if [ "$role" = bootstrap-converged ]; then
            cica_jq -nS --arg c "$commit" --arg t "$tree" --argjson cfg "$cfg" --arg ext "$ext" --slurpfile r "$dir/draft/records/stage3.json" '
              {argv:(["{root}/target/bootstrap-fixpoint/stage2"+$ext,"compile","src/main.tl","-o","{root}/target/bootstrap-fixpoint/stage3.s","--target",(if $ext=="" then "linux" else "windows" end)+"-x86_64"] + [$cfg[]|"--cfg",.] + ["--cfg","compiler-build-identity","--cfg","embedded-stdlib-tlci","--stdlib-root","{root}/src","--opt-level","2"]),producer_version:$r[0].producer_version,producer_sha256:$r[0].producer_sha256,producer_identity:$t,compiled_output:$r[0].compiled_output}' > "$work/record.json"
            assembly_sha=$(cica_sha "$source/target/bootstrap-fixpoint/stage3.s")
            cica_jq -nS --arg h "$assembly_sha" --arg t "$tree" --arg p "$(cica_jq -r .producer_sha256 "$work/record.json")" --argjson n "$(wc -c < "$source/target/bootstrap-fixpoint/stage3.s")" --argjson seed "$seed" '
              {selected_stage:"stage3",fixpoint_pair:["stage2.s","stage3.s"],output_identity:$t,seed:$seed,input_producer_sha256:$p,
               "stage2.s":{sha256:$h,bytes:$n},"stage3.s":{sha256:$h,bytes:$n},"stage3-embedded.s":{sha256:$h,bytes:$n},compile_receipt:{path:"{root}/target/bootstrap-fixpoint/stage3.s",sha256:$h,bytes:$n}}' > "$work/proof.json"
        else
            mkdir -p "$base/payload" "$base/inventory"
            printf 'fixture reference\n' > "$base/payload/reference.s"
            cica_corpus > "$base/inventory/corpus.txt"
            parent=$dir/draft/roles/bootstrap-converged/manifest.json
            cica_jq -nS --arg c "$commit" --arg t "$tree" --argjson cfg "$cfg" --arg p "$(cica_sha "$dir/draft/roles/bootstrap-converged/payload/compiler")" '
              {argv:(["{root}/target/bootstrap-fixpoint/stage3","compile","--batch","{root}/target/build-invariance/batches/opt2-built/opt1/chunks/entries.0000.txt","--target","linux-x86_64"]+[$cfg[]|"--cfg",.]+["--backend-mode","scalar","--opt-level","1","--stdlib-root","stdlib","--stdlib-root","src"]),producer_version:("typelisp "+$c+" built unknown"),producer_sha256:$p,producer_identity:$t}' > "$work/record.json"
            cica_jq -nS --slurpfile b "$parent" --slurpfile r "$work/record.json" --arg h "$(cica_sha "$base/payload/reference.s")" '
              {compared_output_sha256:$h,input_producer_sha256:$r[0].producer_sha256,seed:$b[0].proof.seed,parent_provenance_key:$b[0].provenance_key,batch_manifest:"src/main.tl|{root}/target/build-invariance/compare/opt2-built/selfhost_main_opt1.s\n"}' > "$work/proof.json"
        fi
        cica_jq -S '.+{variables_sha256:("6"*64),wrapper:[]}' "$work/record.json" > "$work/record-complete.json"
        cica_jq -S --slurpfile r "$work/record-complete.json" '.invocation_record=$r[0]' "$work/proof.json" > "$work/proof-complete.json"
        mv "$work/proof-complete.json" "$work/proof.json"
        cica_files "$base" | cica_jq -S 'del(."source-set.sha256")' > "$work/files.json"
        cica_jq -cnS --arg c "$commit" --slurpfile r "$work/record.json" --slurpfile tools "$dir/draft/toolchain.json" --slurpfile p "$work/proof.json" --slurpfile f "$work/files.json" --slurpfile recipes "$work/recipe-hashes.json" '
          {producer_commit:$c,producer_version:$r[0].producer_version,toolchain:$tools[0],seed:$p[0].seed,recipes:$recipes[0],variables_sha256:("6"*64),resource_wrapper:[],generated_inputs:($f[0]|with_entries(select(.key|startswith("generated/"))))}' > "$work/environment.json"
        cica_jq -nS --arg role "$role" --arg host "$host" --arg s "$(cica_sha "$work/sources")" --arg e "$(cat "$work/environment.json")" --slurpfile r "$work/record.json" '
          $r[0].argv as $a | {producer_sha256:$r[0].producer_sha256,producer_identity:$r[0].producer_identity,host:$host,target:($host+"-x86_64"),cwd:"{root}",source_roots:"src,stdlib,tests",stdlib_roots:(if $role=="bootstrap-converged" then "{root}/src" else "stdlib,src" end),cfg:([range(0;$a|length) as $i|select($a[$i]=="--cfg")|$a[$i+1]]|join(",")),opt_level:(if $role=="bootstrap-converged" then "2" else "1" end),profile:"none",environment:$e,argv:($a|tojson),source_set_sha256:$s,output_kind:(if $role=="bootstrap-converged" then "compiler-binary" else "compiler-assembly" end)}' > "$work/fields.json"
        cica_jq -nS --arg role "$role" --arg key "$(cica_key_json "$work/fields.json")" --slurpfile c "$dir/draft/context.json" --slurpfile f "$work/fields.json" --slurpfile files "$work/files.json" --slurpfile p "$work/proof.json" --slurpfile i "$work/inventory.json" \
          '{schema:4,contract:"ci-compiler-artifact",role:$role,context:$c[0],fields:$f[0],provenance_key:$key,files:$files[0],proof:$p[0],inventory:$i[0],packaging_ms:0}' > "$base/manifest.json"
    done < "$work/host-roles"
    fixture_cli seal "$source" "$dir" "$host" "$inputs/results.tsv" "$inputs/timing.tsv" > "$dir.output"
    fixture_attempt=2 fixture_lane=
}
# jobs_json OUT NAME|ATTEMPT|CONCLUSION|STARTED|COMPLETED|RUNNER...
jobs_json() {
    _jj_out=$1; shift
    printf '%s\n' "$@" | cica_jq -RsS --arg h "$commit" 'split("\n")|map(select(length>0)|split("|")|
      {name:.[0],run_id:1234,run_attempt:(.[1]|tonumber),head_sha:$h,status:"completed",conclusion:.[2],started_at:.[3],completed_at:.[4],runner_name:.[5]})|{jobs:.}' > "$_jj_out"
}
# artifacts_json OUT NAME|CREATED...
artifacts_json() {
    _aj_out=$1; shift
    printf '%s\n' "$@" | cica_jq -RsS --arg h "$commit" 'split("\n")|map(select(length>0)|split("|")|
      {name:.[0],expired:false,workflow_run:{id:1234,head_sha:$h},digest:("sha256:"+("9"*64)),created_at:.[1]})|{artifacts:.}' > "$_aj_out"
}
T0=2026-10-27T00:00:00Z T5=2026-10-27T00:00:05Z T10=2026-10-27T00:00:10Z
T20=2026-10-27T00:20:00Z T25=2026-10-27T00:20:05Z T30=2026-10-27T00:20:10Z
envelope() { printf 'ci-stage-envelope-%s-r1234-a%s' "$1" "$2"; }
for spec in linux:linux-1 linux:linux-2 windows:windows-1 windows:windows-2; do
    build_lane "${spec%%:*}" "${spec#*:}" 2 base
done
for lane in linux-1 linux-2 windows-1 windows-2; do
    host=${lane%-*}
    dir=$source/target/lanes/$lane-a2-base
    jobs_json "$work/$lane.jobs.json" "CI lane $lane|2|success|$T0|$T10|runner-$lane"
    artifacts_json "$work/$lane.artifacts.json" "$(envelope "$lane" 2)|$T5"
    fixture_cli verify "$source" "$dir/complete" "$host" "$(cica_sha "$dir/complete/bundle.json")" "$work/$lane.jobs.json" "$work/$lane.artifacts.json" "$lane" 2 > "$work/$lane.result.json"
    record_result "complete-$lane-real-version-record-seal-readback" pass
done

# The rare fallback must remain admissible too: stage3 produces stage4,
# stage3.s equals stage4.s, and the complete invocation receipt agrees.
CICA_HOST=windows
fallback=$source/target/windows-fallback
cp -R "$source/target/lanes/windows-1-a2-base/complete" "$fallback"
m=$fallback/roles/bootstrap-converged/manifest.json
cica_jq -S '
  .fields.argv|=(fromjson|.[0]="{root}/target/bootstrap-fixpoint/stage3.exe"|.[4]="{root}/target/bootstrap-fixpoint/stage4.s"|tojson) |
  .proof.selected_stage="stage4" | .proof.fixpoint_pair=["stage3.s","stage4.s"] |
  .proof["stage4.s"]=.proof["stage3.s"] | .proof.compile_receipt.path="{root}/target/bootstrap-fixpoint/stage4.s" |
  .proof.invocation_record.argv=(.fields.argv|fromjson) | .proof.invocation_record.compiled_output=.proof.compile_receipt' "$m" > "$work/fallback-manifest.json"
cica_jq -S .fields "$work/fallback-manifest.json" > "$work/fallback-fields.json"
cica_jq -S --arg key "$(cica_key_json "$work/fallback-fields.json")" '.provenance_key=$key' "$work/fallback-manifest.json" > "$m"
cica_files "$fallback" > "$work/fallback-files.json"
cica_jq -S --arg h "$(cica_sha "$m")" --slurpfile f "$work/fallback-files.json" '.roles["bootstrap-converged"]=$h|.files=$f[0]' "$fallback/bundle.json" > "$work/fallback-bundle.json"
mv "$work/fallback-bundle.json" "$fallback/bundle.json"
fixture_cli verify "$source" "$fallback" windows "$(cica_sha "$fallback/bundle.json")" "$work/windows-1.jobs.json" "$work/windows-1.artifacts.json" windows-1 2 > "$work/windows-fallback.result.json"
record_result complete-stage4-fallback pass
# Rebinding simulates a semantically substituted but internally hash-consistent
# bundle. The expected digest is supplied independently, exactly as a job output.
rebind_files() {
    cica_files "$case_dir" > "$work/files-rebound.json"
    cica_jq -S --slurpfile f "$work/files-rebound.json" '.files=$f[0]' "$case_dir/bundle.json" > "$work/bundle-rebound.json"
    mv "$work/bundle-rebound.json" "$case_dir/bundle.json"
}
rebind() {
    m=$case_dir/roles/bootstrap-converged/manifest.json
    cica_jq -S .fields "$m" > "$work/changed-fields.json"
    cica_jq -S --arg key "$(cica_key_json "$work/changed-fields.json")" '.provenance_key=$key' "$m" > "$work/changed.json"
    mv "$work/changed.json" "$m"
    cica_jq -cn --arg h "$(cica_sha "$m")" '{"bootstrap-converged":$h}' > "$work/changed-roles.json"
    h=$(cica_sha "$case_dir/roles/build-invariance-opt1-reference/manifest.json")
    cica_jq -S --arg h "$h" '.+{"build-invariance-opt1-reference":$h}' "$work/changed-roles.json" > "$work/roles-rebound.json"
    cica_jq -S --slurpfile r "$work/roles-rebound.json" '.roles=$r[0]' "$case_dir/bundle.json" > "$work/bundle-roles.json"
    mv "$work/bundle-roles.json" "$case_dir/bundle.json"
    rebind_files
}
CICA_HOST=linux
for name in identity producer-digest version-commit target cfg opt profile source-set inventory seed partial-fixpoint path-escape absolute-path corrupt-payload untrusted-root attempt-N-minus-1 producer-N-minus-1 producer-head failed-producer artifact-run old-artifact duplicate-artifact expired-artifact extra-payload missing-role partial-publication missing-payload symlink-escape unsafe-extra-file unsafe-extra-tab absent-fixpoint-proof invocation-receipt-substitution \
    wrong-lane lane-rerun-not-copied lane-failed-gate lane-unplanned-result lane-request-outside-plan lane-handoff-substitution lane-missing-timing lane-missing-receipt; do
    case_dir=$source/target/negative-$name
    cp -R "$source/target/lanes/linux-1-a2-base/complete" "$case_dir"
    cp "$work/linux-1.jobs.json" "$work/jobs-$name.json"
    cp "$work/linux-1.artifacts.json" "$work/artifacts-$name.json"
    verify_lane=linux-1
    filter=
    lane_edit=
    case $name in
      identity) filter='.fields.producer_identity=("e"*40)' ;;
      producer-digest) filter='.fields.producer_sha256=("f"*64)' ;;
      version-commit) filter='.fields.environment|=(fromjson|.producer_version="typelisp wrong built unknown"|tojson)' ;;
      target) filter='.fields.target="windows-x86_64"' ;;
      cfg) filter='.fields.cfg="wrong"' ;;
      opt) filter='.fields.opt_level="0"' ;;
      profile) filter='.fields.profile="profile"' ;;
      source-set) filter='.fields.source_set_sha256=("f"*64)' ;;
      inventory) filter='.inventory["scripts/ci-lanes.tsv"]=("f"*64)' ;;
      seed) filter='.proof.seed.sha256=("f"*64)' ;;
      partial-fixpoint) filter='.proof["stage2.s"].sha256=("f"*64)' ;;
      path-escape) filter='.files["../outside"]={sha256:("f"*64),bytes:1}' ;;
      absolute-path) filter='.files["/outside"]={sha256:("f"*64),bytes:1}' ;;
      corrupt-payload) printf corrupt >> "$case_dir/roles/bootstrap-converged/payload/compiler" ;;
      untrusted-root) printf ' ' >> "$case_dir/bundle.json" ;;
      attempt-N-minus-1) cica_jq -S '.context.attempt=1' "$case_dir/bundle.json" > "$work/changed.json"; mv "$work/changed.json" "$case_dir/bundle.json" ;;
      producer-N-minus-1) cica_jq -S '.jobs[0].run_attempt=1' "$work/jobs-$name.json" > "$work/changed.json"; mv "$work/changed.json" "$work/jobs-$name.json" ;;
      producer-head) cica_jq -S '.jobs[0].head_sha=("f"*40)' "$work/jobs-$name.json" > "$work/changed.json"; mv "$work/changed.json" "$work/jobs-$name.json" ;;
      failed-producer) cica_jq -S '.jobs[0].conclusion="failure"' "$work/jobs-$name.json" > "$work/changed.json"; mv "$work/changed.json" "$work/jobs-$name.json" ;;
      artifact-run) cica_jq -S '.artifacts[0].workflow_run.id=1233' "$work/artifacts-$name.json" > "$work/changed.json"; mv "$work/changed.json" "$work/artifacts-$name.json" ;;
      old-artifact) cica_jq -S '.artifacts[0].created_at="2026-10-26T23:59:59Z"' "$work/artifacts-$name.json" > "$work/changed.json"; mv "$work/changed.json" "$work/artifacts-$name.json" ;;
      duplicate-artifact) cica_jq -S '.artifacts += .artifacts' "$work/artifacts-$name.json" > "$work/changed.json"; mv "$work/changed.json" "$work/artifacts-$name.json" ;;
      expired-artifact) cica_jq -S '.artifacts[0].expired=true' "$work/artifacts-$name.json" > "$work/changed.json"; mv "$work/changed.json" "$work/artifacts-$name.json" ;;
      unsafe-extra-tab) tab=$(printf '\t'); printf extra > "$case_dir/zz${tab}unexpected" ;;
      unsafe-extra-file) printf extra > "$case_dir/zz:unexpected" ;;
      absent-fixpoint-proof) filter='del(.proof["stage2.s"],.proof["stage3.s"],.proof["stage3-embedded.s"],.proof.compile_receipt.sha256,.proof.compile_receipt.bytes)' ;;
      invocation-receipt-substitution) filter='.proof.invocation_record.compiled_output.sha256=("f"*64)' ;;
      extra-payload) printf extra > "$case_dir/roles/bootstrap-converged/payload/extra" ;;
      missing-role) cica_jq -S '.roles={}' "$case_dir/bundle.json" > "$work/changed.json"; mv "$work/changed.json" "$case_dir/bundle.json" ;;
      partial-publication) mkdir "$case_dir/uncommitted.publishing"; printf partial > "$case_dir/uncommitted.publishing/payload" ;;
      missing-payload) mv "$case_dir/roles/bootstrap-converged/payload/compiler" "$work/retained-missing-payload-compiler" ;;
      symlink-escape)
        case "$(uname -s)" in
          Linux*) ln -s "$work" "$case_dir/escape" ;;
          *) printf escape > "$case_dir/escape" ;;
        esac ;;
      # Lane binding: another lane's name and artifact; a later attempt that
      # really re-ran the job (not a copy) leaves this attempt's envelope stale.
      wrong-lane)
        verify_lane=linux-2
        jobs_json "$work/jobs-$name.json" "CI lane linux-2|2|success|$T0|$T10|runner-linux-2"
        artifacts_json "$work/artifacts-$name.json" "$(envelope linux-2 2)|$T5" ;;
      lane-rerun-not-copied)
        jobs_json "$work/jobs-$name.json" "CI lane linux-1|2|success|$T0|$T10|runner-linux-1" "CI lane linux-1|3|success|$T20|$T30|runner-other" ;;
      lane-failed-gate) lane_edit='NR == 2 { $2 = 1 }' lane_file=results.tsv ;;
      lane-unplanned-result) lane_edit='{ print } END { print "fixture-gate-b\t0\t1" }' lane_file=results.tsv ;;
      lane-request-outside-plan) lane_edit='{ print } END { print "fixture-gate-b" }' lane_file=requested.txt ;;
      lane-handoff-substitution) lane_edit='$1 == "converged" { $2 = "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff" }' lane_file=handoffs.tsv ;;
      lane-missing-timing) mv "$case_dir/lane/timing.tsv" "$work/retained-missing-timing.tsv"; rebind_files ;;
      lane-missing-receipt) mv "$case_dir/lane/results.tsv" "$work/retained-missing-results.tsv"; rebind_files ;;
    esac
    if [ -n "$lane_edit" ]; then
        case $lane_edit in '{ print }'*) ;; *) lane_edit="$lane_edit { print }" ;; esac
        awk -F '\t' -v OFS='\t' "$lane_edit" "$case_dir/lane/$lane_file" > "$work/lane-edit"
        mv "$work/lane-edit" "$case_dir/lane/$lane_file"
        rebind_files
    fi
    if [ -n "$filter" ]; then
        m=$case_dir/roles/bootstrap-converged/manifest.json
        cica_jq -S "$filter" "$m" > "$work/changed.json"
        mv "$work/changed.json" "$m"
        rebind
    fi
    digest=$(cica_sha "$case_dir/bundle.json")
    [ "$name" != untrusted-root ] || digest=$(cica_sha "$source/target/lanes/linux-1-a2-base/complete/bundle.json")
    attempt=2
    [ "$name" != lane-rerun-not-copied ] || fixture_attempt=3
    if fixture_cli verify "$source" "$case_dir" linux "$digest" "$work/jobs-$name.json" "$work/artifacts-$name.json" "$verify_lane" "$attempt" > "$work/$name.stdout" 2> "$work/$name.stderr"; then
        cica_fail "accepted negative fixture: $name"
    fi
    fixture_attempt=2
    record_result "$name" rejected
done
for unsafe in ../outside /outside 'C:/outside' 'a\..\outside'; do
    if cica_rel "$unsafe"; then cica_fail 'accepted unsafe path'; fi
    record_result "unsafe-path-$unsafe" rejected
done
if GITHUB_ACTIONS=true cica_context local > "$work/local-in-CI.stdout" 2> "$work/local-in-CI.stderr"; then cica_fail 'local fallback accepted in CI'; fi
record_result local-mode-forbidden-in-CI rejected
for lane in '' windows-1 linux-0 linux-1x; do
    if GITHUB_ACTIONS=true GITHUB_EVENT_NAME=pull_request GITHUB_SHA=$commit GITHUB_WORKFLOW_SHA=$commit \
      GITHUB_RUN_ID=1234 GITHUB_RUN_ATTEMPT=2 GITHUB_REPOSITORY=owner/repo \
      GITHUB_WORKFLOW_REF=owner/repo/.github/workflows/ci.yml@refs/pull/1/merge GITHUB_EVENT_PATH=$work/event.json \
      TYPELISP_CI_LANE=$lane cica_context github > "$work/lane-context.stdout" 2> "$work/lane-context.stderr"; then
        cica_fail "accepted producer lane '$lane' on linux"
    fi
    record_result "producer-lane-${lane:-missing}" rejected
done
# A partial producer has no complete bundle and cannot be sealed.
mkdir -p "$source/target/partial/draft/roles/bootstrap-converged.publishing" "$source/target/partial/draft/lane"
cp "$source/target/lanes/linux-1-a2-base/complete/context.json" "$source/target/partial/draft/context.json"
cp "$source/target/lanes/linux-1-a2-base/complete/lane/plan.txt" "$source/target/lanes/linux-1-a2-base/complete/lane/requested.txt" "$source/target/partial/draft/lane/"
partial_inputs=$source_real/target/lanes/linux-1-a2-base-inputs
if fixture_lane=linux-1 fixture_cli seal "$source" "$source/target/partial" linux "$partial_inputs/results.tsv" "$partial_inputs/timing.tsv" > "$work/partial-seal.stdout" 2> "$work/partial-seal.stderr"; then cica_fail 'partial publication sealed'; fi
[ ! -e "$source/target/partial/complete" ] || cica_fail 'partial became complete'
record_result partial-seal rejected
# A lane whose ci-verify.sh result is not a pass for every planned gate
# cannot seal a receipt.
mkdir -p "$source/target/failed-seal/draft/lane"
for f in context.json source-set.sha256 toolchain.json; do cp "$source/target/lanes/linux-2-a2-base/complete/$f" "$source/target/failed-seal/draft/"; done
cp "$source/target/lanes/linux-2-a2-base/complete/lane/plan.txt" "$source/target/lanes/linux-2-a2-base/complete/lane/requested.txt" "$source/target/failed-seal/draft/lane/"
failed_inputs=$source_real/target/failed-seal-inputs
mkdir -p "$failed_inputs"
awk -F '\t' -v OFS='\t' 'NR == 3 { $2 = "unfinished" } { print }' "$source_real/target/lanes/linux-2-a2-base-inputs/results.tsv" > "$failed_inputs/results.tsv"
if fixture_lane=linux-2 fixture_cli seal "$source" "$source/target/failed-seal" linux "$failed_inputs/results.tsv" - > "$work/failed-seal.stdout" 2> "$work/failed-seal.stderr"; then cica_fail 'failed lane sealed'; fi
record_result failed-gate-seal rejected

# The lane aggregator (scripts/ci-lane.sh aggregate), the required check of a
# host, runs the copied production scripts in the fixture checkout.
fixture_aggregate() { fixture_env "$source/scripts/ci-lane.sh" aggregate "$@"; }
# aggregate_case NAME pass|rejected HOST RESULT JOBS ARTIFACTS LANE=BUNDLE-DIR@ATTEMPT...
# Each bundle is downloaded under its lane's envelope name for that attempt;
# its digest file line is the bundle's own digest unless DIGEST_OVERRIDE is set.
aggregate_case() {
    _ac_name=$1 _ac_expect=$2 _ac_host=$3 _ac_result=$4 _ac_jobs=$5 _ac_arts=$6
    shift 6
    _ac_root=$source/target/aggregate/$_ac_name
    mkdir -p "$_ac_root/downloads"
    : > "$_ac_root/digests.tsv"
    for _ac_spec in "$@"; do
        _ac_lane=${_ac_spec%%=*} _ac_rest=${_ac_spec#*=}
        _ac_dir=${_ac_rest%@*} _ac_attempt=${_ac_rest##*@}
        if [ "$_ac_dir" != none ]; then
            cp -R "$_ac_dir" "$_ac_root/downloads/$(envelope "$_ac_lane" "$_ac_attempt")"
            printf '%s\t%s\n' "$_ac_lane" "$(cica_sha "$_ac_dir/bundle.json")" >> "$_ac_root/digests.tsv"
        fi
    done
    [ -z "${DIGEST_OVERRIDE:-}" ] || printf '%s\n' "$DIGEST_OVERRIDE" > "$_ac_root/digests.tsv"
    if fixture_aggregate "$_ac_host" "$_ac_result" "$_ac_root/downloads" "$_ac_jobs" "$_ac_arts" "$_ac_root/digests.tsv" "$_ac_root/out" \
        > "$_ac_root/stdout" 2> "$_ac_root/stderr"; then
        [ "$_ac_expect" = pass ] || cica_fail "aggregator accepted negative fixture: $_ac_name"
    else
        [ "$_ac_expect" = rejected ] || { sed 's/^/  /' "$_ac_root/stderr" >&2; cica_fail "aggregator rejected positive fixture: $_ac_name"; }
    fi
    record_result "aggregate-$_ac_name" "$_ac_expect"
}
L=$source/target/lanes
lj1="CI lane linux-1|2|success|$T0|$T10|runner-linux-1"
lj2="CI lane linux-2|2|success|$T0|$T10|runner-linux-2"
wj1="CI lane windows-1|2|success|$T0|$T10|runner-windows-1"
wj2="CI lane windows-2|2|success|$T0|$T10|runner-windows-2"
agg="Test + Integration|2|success|$T20|$T30|runner-aggregate"
jobs_json "$work/agg.jobs.json" "$lj1" "$lj2" "$wj1" "$wj2" "$agg"
artifacts_json "$work/agg.artifacts.json" "$(envelope linux-1 2)|$T5" "$(envelope linux-2 2)|$T5" "$(envelope windows-1 2)|$T5" "$(envelope windows-2 2)|$T5"
base_linux="linux-1=$L/linux-1-a2-base/complete@2 linux-2=$L/linux-2-a2-base/complete@2"
base_windows="windows-1=$L/windows-1-a2-base/complete@2 windows-2=$L/windows-2-a2-base/complete@2"
# shellcheck disable=SC2086
aggregate_case linux pass linux success "$work/agg.jobs.json" "$work/agg.artifacts.json" $base_linux
out=$source/target/aggregate/linux/out
# The merged artifact keeps the ci-timing format: each gate's rows once, from
# its owning lane, and exactly one complete-verification row (slowest lane).
[ "$(grep -c '	complete-verification	' "$out/linux.tsv")" = 1 ] && [ "$(grep -c 'partial-verification' "$out/linux.tsv")" = 0 ] &&
    [ "$(grep -c '^bootstrap fixpoint	all	gate	' "$out/linux.tsv")" = 1 ] && [ "$(grep -c '	all	gate	' "$out/linux.tsv")" = 6 ] &&
    grep -q '^CI verification	all	complete-verification	5002	0	linux$' "$out/linux.tsv" || cica_fail 'merged timing differs from the contract'
cica_jq -e '.status=="pass" and .gates==6 and (.lanes|length)==2 and (.lanes|map(.attempt)|unique)==[2] and
  (.lanes[]|select(.lane=="linux-1")|.duplicates)==["bootstrap-fixpoint"] and (.seeds|length)==1' "$out/coverage.json" > /dev/null || cica_fail 'coverage proof incomplete'
record_result aggregate-merged-timing-and-proof pass
# shellcheck disable=SC2086
aggregate_case windows pass windows success "$work/agg.jobs.json" "$work/agg.artifacts.json" $base_windows
for result in failure cancelled skipped ''; do
    # shellcheck disable=SC2086
    aggregate_case "lanes-result-${result:-missing}" rejected linux "$result" "$work/agg.jobs.json" "$work/agg.artifacts.json" $base_linux
done
for conclusion in failure cancelled skipped; do
    jobs_json "$work/lane-$conclusion.jobs.json" "CI lane linux-1|2|$conclusion|$T0|$T10|runner-linux-1" "$lj2" "$agg"
    # shellcheck disable=SC2086
    aggregate_case "lane-$conclusion" rejected linux success "$work/lane-$conclusion.jobs.json" "$work/agg.artifacts.json" $base_linux
done
jobs_json "$work/omitted-lane.jobs.json" "$lj1" "$agg"
# shellcheck disable=SC2086
aggregate_case omitted-lane-job rejected linux success "$work/omitted-lane.jobs.json" "$work/agg.artifacts.json" $base_linux
aggregate_case omitted-lane-envelope rejected linux success "$work/agg.jobs.json" "$work/agg.artifacts.json" "linux-1=$L/linux-1-a2-base/complete@2"
jobs_json "$work/duplicate-lane.jobs.json" "$lj1" "$lj1" "$lj2" "$agg"
# shellcheck disable=SC2086
aggregate_case duplicate-lane-job rejected linux success "$work/duplicate-lane.jobs.json" "$work/agg.artifacts.json" $base_linux
for variant in missing-gate missing-oracle extra-gate; do
    build_lane linux linux-2 2 "$variant"
    aggregate_case "receipt-$variant" rejected linux success "$work/agg.jobs.json" "$work/agg.artifacts.json" \
        "linux-1=$L/linux-1-a2-base/complete@2" "linux-2=$L/linux-2-a2-$variant/complete@2"
done
# Wrong host, lane or head; corrupt and partial envelopes; a substituted digest.
aggregate_case wrong-host rejected linux success "$work/agg.jobs.json" "$work/agg.artifacts.json" \
    "linux-1=$L/linux-1-a2-base/complete@2" "linux-2=$L/windows-1-a2-base/complete@2"
aggregate_case swapped-lanes rejected linux success "$work/agg.jobs.json" "$work/agg.artifacts.json" \
    "linux-1=$L/linux-2-a2-base/complete@2" "linux-2=$L/linux-1-a2-base/complete@2"
cica_jq -nS --arg h "$commit" '{repository:{full_name:"owner/repo"},pull_request:{head:{sha:("f"*40)}}}' > "$work/event-other-head.json"
cp "$work/event.json" "$work/event-tested-head.json"
cp "$work/event-other-head.json" "$work/event.json"
# shellcheck disable=SC2086
aggregate_case wrong-head rejected linux success "$work/agg.jobs.json" "$work/agg.artifacts.json" $base_linux
cp "$work/event-tested-head.json" "$work/event.json"
cp -R "$L/linux-2-a2-base/complete" "$L/linux-2-corrupt"
printf corrupt >> "$L/linux-2-corrupt/roles/bootstrap-converged/payload/compiler"
aggregate_case corrupt-envelope rejected linux success "$work/agg.jobs.json" "$work/agg.artifacts.json" \
    "linux-1=$L/linux-1-a2-base/complete@2" "linux-2=$L/linux-2-corrupt@2"
cp -R "$L/linux-2-a2-base/complete" "$L/linux-2-partial"
mv "$L/linux-2-partial/lane/timing.tsv" "$work/retained-partial-timing.tsv"
aggregate_case partial-envelope rejected linux success "$work/agg.jobs.json" "$work/agg.artifacts.json" \
    "linux-1=$L/linux-1-a2-base/complete@2" "linux-2=$L/linux-2-partial@2"
DIGEST_OVERRIDE="linux-1	$(cica_sha "$L/linux-1-a2-base/complete/bundle.json")
linux-2	$(cica_sha "$L/linux-1-a2-base/complete/bundle.json")"
# shellcheck disable=SC2086
aggregate_case substituted-digest rejected linux success "$work/agg.jobs.json" "$work/agg.artifacts.json" $base_linux
DIGEST_OVERRIDE=
# One converged compiler: a seed race (another stage0 seed) is allowed only
# with an equal compiler; a different compiler is a determinism defect.
build_lane linux linux-2 2 other-seed
aggregate_case seed-race-equal-compiler pass linux success "$work/agg.jobs.json" "$work/agg.artifacts.json" \
    "linux-1=$L/linux-1-a2-base/complete@2" "linux-2=$L/linux-2-a2-other-seed/complete@2"
cica_jq -e '(.seeds|length)==2' "$source/target/aggregate/seed-race-equal-compiler/out/coverage.json" > /dev/null || cica_fail 'seed race not recorded'
build_lane linux linux-2 2 other-payload
aggregate_case stage2-mismatch rejected linux success "$work/agg.jobs.json" "$work/agg.artifacts.json" \
    "linux-1=$L/linux-1-a2-base/complete@2" "linux-2=$L/linux-2-a2-other-payload/complete@2"
build_lane linux linux-2 2 other-seed-payload
aggregate_case seed-race-other-compiler rejected linux success "$work/agg.jobs.json" "$work/agg.artifacts.json" \
    "linux-1=$L/linux-1-a2-base/complete@2" "linux-2=$L/linux-2-a2-other-seed-payload/complete@2"
build_lane windows windows-2 2 timestamp
aggregate_case windows-link-timestamp-only pass windows success "$work/agg.jobs.json" "$work/agg.artifacts.json" \
    "windows-1=$L/windows-1-a2-base/complete@2" "windows-2=$L/windows-2-a2-timestamp/complete@2"
build_lane windows windows-2 2 other-payload
aggregate_case windows-stage2-mismatch rejected windows success "$work/agg.jobs.json" "$work/agg.artifacts.json" \
    "windows-1=$L/windows-1-a2-base/complete@2" "windows-2=$L/windows-2-a2-other-payload/complete@2"
# "Re-run failed jobs": linux-1 ran in attempt 1 and was copied into attempt
# 2; linux-2 failed in attempt 1 and re-ran. Each binds to its executed
# attempt. A lane that really re-ran leaves its older envelope stale.
build_lane linux linux-1 1 base
jobs_json "$work/rerun.jobs.json" "CI lane linux-1|1|success|$T0|$T10|runner-linux-1" "CI lane linux-2|1|failure|$T0|$T10|runner-linux-2" \
    "Test + Integration|1|failure|$T10|$T10|runner-aggregate-1" \
    "CI lane linux-1|2|success|$T0|$T10|runner-linux-1" "CI lane linux-2|2|success|$T20|$T30|runner-linux-2b" "$agg"
artifacts_json "$work/rerun.artifacts.json" "$(envelope linux-1 1)|$T5" "$(envelope linux-2 2)|$T25"
aggregate_case partial-rerun-bound-to-executed-attempts pass linux success "$work/rerun.jobs.json" "$work/rerun.artifacts.json" \
    "linux-1=$L/linux-1-a1-base/complete@1" "linux-2=$L/linux-2-a2-base/complete@2"
aggregate_case partial-rerun-without-executed-envelope rejected linux success "$work/rerun.jobs.json" "$work/rerun.artifacts.json" \
    "linux-1=$L/linux-1-a2-base/complete@2" "linux-2=$L/linux-2-a2-base/complete@2"
jobs_json "$work/stale.jobs.json" "CI lane linux-1|1|success|$T0|$T10|runner-linux-1" "CI lane linux-1|2|success|$T20|$T30|runner-linux-1b" \
    "CI lane linux-2|2|success|$T20|$T30|runner-linux-2" "$agg"
artifacts_json "$work/stale.artifacts.json" "$(envelope linux-1 1)|$T5" "$(envelope linux-1 2)|$T25" "$(envelope linux-2 2)|$T25"
aggregate_case stale-attempt-envelope rejected linux success "$work/stale.jobs.json" "$work/stale.artifacts.json" \
    "linux-1=$L/linux-1-a1-base/complete@1" "linux-2=$L/linux-2-a2-base/complete@2"
aggregate_case stale-envelope-renamed rejected linux success "$work/stale.jobs.json" "$work/stale.artifacts.json" \
    "linux-1=$L/linux-1-a1-base/complete@2" "linux-2=$L/linux-2-a2-base/complete@2"
# The assignment itself fails closed: unassigned, doubly assigned, unknown,
# undeclared duplicate, stale declaration, a third lane, a gate on a host it
# does not run on. Each variant is checked, then the file is restored.
lane_check_case() {
    _lc_name=$1 _lc_awk=$2
    awk -F '\t' -v OFS='\t' "$_lc_awk" "$source/scripts/ci-lanes.tsv" > "$work/ci-lanes.variant"
    cp "$work/ci-lanes.variant" "$source/scripts/ci-lanes.tsv"
    if "$source/scripts/ci-lane.sh" check > "$work/check-$_lc_name.stdout" 2> "$work/check-$_lc_name.stderr"; then
        git -C "$source" checkout -q -- scripts/ci-lanes.tsv
        cica_fail "accepted lane assignment variant: $_lc_name"
    fi
    git -C "$source" checkout -q -- scripts/ci-lanes.tsv
    record_result "assignment-$_lc_name" rejected
}
"$source/scripts/ci-lane.sh" check > "$work/check-base.stdout"
record_result assignment-base pass
lane_check_case unassigned-gate '$1 != "fixture-gate-c"'
lane_check_case doubly-assigned '{ print } $1 == "fixture-gate-c" { print }'
lane_check_case unknown-gate '{ print } END { print "fixture-unknown-gate", "linux-2", "windows-1" }'
lane_check_case undeclared-duplicate '$1 == "bootstrap-fixpoint" { $2 = "linux-2" } { print }'
lane_check_case stale-duplicate-declaration '$1 == "fixture-self-test" { $2 = "linux-2+linux-1" } { print }'
lane_check_case moved-need-undeclared '$1 == "fixture-gate-c" { $2 = "linux-1" } { print }'
lane_check_case third-lane '$1 == "fixture-self-test" { $2 = "linux-3" } { print }'
lane_check_case wrong-host-lane '$1 == "fixture-gate-b" { $2 = "windows-1" } { print }'
lane_check_case gate-not-on-host '$1 == "stage2-opt1-opt2-build-invariance" { $3 = "windows-2" } { print }'
# setup: three build-invariance workers only where nothing can run beside it.
fixture_setup() { "$source/scripts/ci-lane.sh" setup "$1" | sed -n "s/^$2=//p"; }
[ "$(fixture_setup linux-1 build_invariance_workers)" = 3 ] && [ -z "$(fixture_setup linux-2 build_invariance_workers)" ] &&
    [ "$(fixture_setup linux-1 gates)" = stage2-opt1-opt2-build-invariance,fixture-opt2-cli ] || cica_fail 'lane setup changed'
awk -F '\t' -v OFS='\t' '$1 == "fixture-self-test" { $2 = "linux-1" } $1 == "bootstrap-fixpoint" { $2 = "linux-1+linux-2" } { print }' \
    "$source/scripts/ci-lanes.tsv" > "$work/ci-lanes.shared"
cp "$work/ci-lanes.shared" "$source/scripts/ci-lanes.tsv"
shared_workers=$(fixture_setup linux-1 build_invariance_workers)
git -C "$source" checkout -q -- scripts/ci-lanes.tsv
[ -z "$shared_workers" ] || cica_fail 'three workers granted to a lane that is not isolated'
record_result setup-three-workers-only-when-isolated pass
cica_jq -sS '{schema:4,status:"pass",cases:.}' "$work/results.jsonl" > "$work/self-test.json"
printf 'ci-compiler-artifact self-tests passed: %s cases\n' "$(jq '.cases|length' "$work/self-test.json")"
