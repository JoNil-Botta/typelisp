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
# context. No test-only bypass exists in its verifier or publisher.
fixture_cli() {
    env GITHUB_ACTIONS=true GITHUB_EVENT_NAME=pull_request GITHUB_SHA="$commit" \
      GITHUB_WORKFLOW_SHA="$commit" GITHUB_RUN_ID=1234 GITHUB_RUN_ATTEMPT=2 \
      GITHUB_REPOSITORY=owner/repo GITHUB_WORKFLOW_REF=owner/repo/.github/workflows/ci.yml@refs/pull/1/merge \
      GITHUB_EVENT_PATH="$work/event.json" "$ROOT/scripts/ci-compiler-artifact.sh" "$@"
}
source=$work/source
mkdir -p "$source/src" "$source/stdlib" "$source/tests/integration" "$source/scripts"
printf '(define (main) : i64 42)\n' > "$source/src/main.tl"
printf '; fixture stdlib\n' > "$source/stdlib/prelude.tl"
printf 'fixture\n' > "$source/tests/data.txt"
printf 'fixture|all|0,1,2|src/main.tl|42|-|-|-|-\n' > "$source/tests/integration/native.manifest"
printf '*.tl text eol=lf\n*.sh text eol=lf\n' > "$source/.gitattributes"
printf 'fixture gate inventory\n' > "$source/scripts/ci-gates.tsv"
printf 'fixture role inventory\n' > "$source/scripts/ci-compiler-artifacts.tsv"
cp "$ROOT/scripts/expand-integration-manifest.awk" "$source/scripts/expand-integration-manifest.awk"
CICA_ROOT=$ROOT
cica_recipes | cica_jq -r 'keys[]' > "$work/recipes"
while IFS= read -r recipe; do cp "$ROOT/$recipe" "$source/$recipe"; done < "$work/recipes"
git init -q "$source"
git -C "$source" add .
git -C "$source" -c user.name=fixture -c user.email=fixture@example.invalid commit -qm fixture
commit=$(git -C "$source" rev-parse HEAD)
tree=$(git -C "$source" rev-parse 'HEAD^{tree}')
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
# Reuse the real recording path, then carry its complete version into the
# independently constructed complete bundle and normal publication/readback.
for host in linux windows; do
    CICA_HOST=$host
    case $host in linux) cfg='["linux","unix","target-linux","os-linux"]'; ext= ;; windows) cfg='["windows","target-windows","os-windows"]'; ext=.exe ;; esac
    dir=$source/target/$host
    mkdir -p "$dir/draft/roles/bootstrap-converged/payload"
    GITHUB_ACTIONS=true GITHUB_EVENT_NAME=pull_request GITHUB_SHA=$commit GITHUB_WORKFLOW_SHA=$commit \
      GITHUB_RUN_ID=1234 GITHUB_RUN_ATTEMPT=2 GITHUB_REPOSITORY=owner/repo \
      GITHUB_WORKFLOW_REF=owner/repo/.github/workflows/ci.yml@refs/pull/1/merge GITHUB_EVENT_PATH=$work/event.json \
      cica_context github > "$dir/draft/context.json"
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
    cica_generated > "$work/generated-paths"
    while IFS= read -r generated; do
        mkdir -p "$dir/draft/roles/bootstrap-converged/generated/$(dirname -- "$generated")"
        case $generated in
          */git-hash.txt) printf %s "$commit" ;;
          */tree-hash.txt) printf %s "$tree" ;;
          *) printf '%s\n' "fixture $generated" ;;
        esac > "$dir/draft/roles/bootstrap-converged/generated/$generated"
    done < "$work/generated-paths"
    cica_roles > "$work/host-roles"
    while IFS= read -r role; do
        base=$dir/draft/roles/$role
        mkdir -p "$base"
        cp "$work/sources" "$base/source-set.sha256"
        if [ "$role" = bootstrap-converged ]; then
            cica_jq -nS --arg c "$commit" --arg t "$tree" --argjson cfg "$cfg" --arg ext "$ext" --slurpfile r "$dir/draft/records/stage3.json" '
              {argv:(["{root}/target/bootstrap-fixpoint/stage2"+$ext,"compile","src/main.tl","-o","{root}/target/bootstrap-fixpoint/stage3.s","--target",(if $ext=="" then "linux" else "windows" end)+"-x86_64"] + [$cfg[]|"--cfg",.] + ["--cfg","compiler-build-identity","--cfg","embedded-stdlib-tlci","--stdlib-root","{root}/src","--opt-level","2"]),producer_version:$r[0].producer_version,producer_sha256:$r[0].producer_sha256,producer_identity:$t}' > "$work/record.json"
            assembly_sha=$(cica_sha "$source/target/bootstrap-fixpoint/stage3.s")
            cica_jq -nS --arg h "$assembly_sha" --arg t "$tree" --arg p "$(cica_jq -r .producer_sha256 "$work/record.json")" --argjson n "$(wc -c < "$source/target/bootstrap-fixpoint/stage3.s")" '
              {selected_stage:"stage3",fixpoint_pair:["stage2.s","stage3.s"],output_identity:$t,seed:{sha256:("4"*64),identity:("5"*40)},input_producer_sha256:$p,
               "stage2.s":{sha256:$h,bytes:$n},"stage3.s":{sha256:$h,bytes:$n},"stage3-embedded.s":{sha256:$h,bytes:$n},compile_receipt:{path:"{root}/target/bootstrap-fixpoint/stage3.s",sha256:$h,bytes:$n}}' > "$work/proof.json"
        else
            mkdir -p "$base/payload" "$base/inventory"
            printf 'fixture reference\n' > "$base/payload/reference.s"
            cica_corpus > "$base/inventory/corpus.txt"
            parent=$dir/draft/roles/bootstrap-converged/manifest.json
            cica_jq -nS --arg c "$commit" --arg t "$tree" --argjson cfg "$cfg" --arg p "$(cica_sha "$dir/draft/roles/bootstrap-converged/payload/compiler")" '
              {argv:(["{root}/target/bootstrap-fixpoint/stage3","compile","--batch","{root}/target/build-invariance/batches/opt2-built/opt1/chunks/entries.0000.txt","--target","linux-x86_64"]+[$cfg[]|"--cfg",.]+["--backend-mode","scalar","--opt-level","1","--stdlib-root","stdlib","--stdlib-root","src"]),producer_version:"typelisp "+$c+" built unknown",producer_sha256:$p,producer_identity:$t}' > "$work/record.json"
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
          $r[0].argv as $a | {producer_sha256:$r[0].producer_sha256,producer_identity:$r[0].producer_identity,host:$host,target:$host+"-x86_64",cwd:"{root}",source_roots:"src,stdlib,tests",stdlib_roots:(if $role=="bootstrap-converged" then "{root}/src" else "stdlib,src" end),cfg:([range(0;$a|length) as $i|select($a[$i]=="--cfg")|$a[$i+1]]|join(",")),opt_level:(if $role=="bootstrap-converged" then "2" else "1" end),profile:"none",environment:$e,argv:($a|tojson),source_set_sha256:$s,output_kind:(if $role=="bootstrap-converged" then "compiler-binary" else "compiler-assembly" end)}' > "$work/fields.json"
        cica_jq -nS --arg role "$role" --arg key "$(cica_key_json "$work/fields.json")" --slurpfile c "$dir/draft/context.json" --slurpfile f "$work/fields.json" --slurpfile files "$work/files.json" --slurpfile p "$work/proof.json" --slurpfile i "$work/inventory.json" \
          '{schema:3,contract:"ci-compiler-artifact",role:$role,context:$c[0],fields:$f[0],provenance_key:$key,files:$files[0],proof:$p[0],inventory:$i[0],packaging_ms:0}' > "$base/manifest.json"
    done < "$work/host-roles"
    fixture_cli seal "$source" "$dir" "$host" > "$work/$host.output"
    digest=$(cica_sha "$dir/complete/bundle.json")
    case $host in linux) name='Test + Integration'; host_name=Linux ;; windows) name='Test + Integration (windows-latest)'; host_name=Windows ;; esac
    cica_jq -nS --arg n "$name" --arg h "$commit" '{jobs:[{name:$n,run_id:1234,run_attempt:2,head_sha:$h,status:"completed",conclusion:"success",started_at:"2026-10-27T00:00:00Z",completed_at:"2026-10-27T00:00:10Z"}]}' > "$work/$host.jobs.json"
    cica_jq -nS --arg h "$commit" --arg n "ci-stage-envelope-$host_name-r1234-a2" '{artifacts:[{name:$n,expired:false,workflow_run:{id:1234,head_sha:$h},digest:"sha256:"+("9"*64),created_at:"2026-10-27T00:00:05Z"}]}' > "$work/$host.artifacts.json"
    fixture_cli verify "$source" "$dir/complete" "$host" "$digest" "$work/$host.jobs.json" "$work/$host.artifacts.json" > "$work/$host.result.json"
    record_result "complete-$host-real-version-record-seal-readback" pass
done

# Rebinding simulates a semantically substituted but internally hash-consistent
# bundle. The expected digest is supplied independently, exactly as a job output.
rebind() {
    m=$case_dir/roles/bootstrap-converged/manifest.json
    cica_jq -S .fields "$m" > "$work/changed-fields.json"
    cica_jq -S --arg key "$(cica_key_json "$work/changed-fields.json")" '.provenance_key=$key' "$m" > "$work/changed.json"
    mv "$work/changed.json" "$m"
    cica_jq -cn --arg h "$(cica_sha "$m")" '{"bootstrap-converged":$h}' > "$work/changed-roles.json"
    h=$(cica_sha "$case_dir/roles/build-invariance-opt1-reference/manifest.json")
    cica_jq -S --arg h "$h" '.+{"build-invariance-opt1-reference":$h}' "$work/changed-roles.json" > "$work/roles-rebound.json"
    cica_files "$case_dir" > "$work/files-rebound.json"
    cica_jq -S --slurpfile r "$work/roles-rebound.json" --slurpfile f "$work/files-rebound.json" '.roles=$r[0]|.files=$f[0]' "$case_dir/bundle.json" > "$work/bundle-rebound.json"
    mv "$work/bundle-rebound.json" "$case_dir/bundle.json"
}
CICA_HOST=linux
for name in identity producer-digest version-commit target cfg opt profile source-set inventory seed partial-fixpoint path-escape absolute-path corrupt-payload untrusted-root attempt-N-minus-1 producer-N-minus-1 producer-head failed-producer artifact-run old-artifact duplicate-artifact expired-artifact extra-payload missing-role partial-publication missing-payload symlink-escape; do
    case_dir=$source/target/negative-$name
    cp -R "$source/target/linux/complete" "$case_dir"
    cp "$work/linux.jobs.json" "$work/jobs-$name.json"
    cp "$work/linux.artifacts.json" "$work/artifacts-$name.json"
    filter=
    case $name in
      identity) filter='.fields.producer_identity=("e"*40)' ;;
      producer-digest) filter='.fields.producer_sha256=("f"*64)' ;;
      version-commit) filter='.fields.environment|=(fromjson|.producer_version="typelisp wrong built unknown"|tojson)' ;;
      target) filter='.fields.target="windows-x86_64"' ;;
      cfg) filter='.fields.cfg="wrong"' ;;
      opt) filter='.fields.opt_level="0"' ;;
      profile) filter='.fields.profile="profile"' ;;
      source-set) filter='.fields.source_set_sha256=("f"*64)' ;;
      inventory) filter='.inventory["scripts/ci-gates.tsv"]=("f"*64)' ;;
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
      extra-payload) printf extra > "$case_dir/roles/bootstrap-converged/payload/extra" ;;
      missing-role) cica_jq -S '.roles={}' "$case_dir/bundle.json" > "$work/changed.json"; mv "$work/changed.json" "$case_dir/bundle.json" ;;
      partial-publication) mkdir "$case_dir/uncommitted.publishing"; printf partial > "$case_dir/uncommitted.publishing/payload" ;;
      missing-payload) mv "$case_dir/roles/bootstrap-converged/payload/compiler" "$work/retained-missing-payload-compiler" ;;
      symlink-escape)
        case "$(uname -s)" in
          Linux*) ln -s "$work" "$case_dir/escape" ;;
          *) printf escape > "$case_dir/escape" ;;
        esac ;;
    esac
    if [ -n "$filter" ]; then
        m=$case_dir/roles/bootstrap-converged/manifest.json
        cica_jq -S "$filter" "$m" > "$work/changed.json"
        mv "$work/changed.json" "$m"
        rebind
    fi
    digest=$(cica_sha "$case_dir/bundle.json")
    [ "$name" != untrusted-root ] || digest=$(cica_sha "$source/target/linux/complete/bundle.json")
    if fixture_cli verify "$source" "$case_dir" linux "$digest" "$work/jobs-$name.json" "$work/artifacts-$name.json" > "$work/$name.stdout" 2> "$work/$name.stderr"; then
        cica_fail "accepted negative fixture: $name"
    fi
    record_result "$name" rejected
done
for unsafe in ../outside /outside 'C:/outside' 'a\..\outside'; do
    if cica_rel "$unsafe"; then cica_fail 'accepted unsafe path'; fi
    record_result "unsafe-path-$unsafe" rejected
done
if GITHUB_ACTIONS=true cica_context local > "$work/local-in-CI.stdout" 2> "$work/local-in-CI.stderr"; then cica_fail 'local fallback accepted in CI'; fi
record_result local-mode-forbidden-in-CI rejected
# A partial producer has no complete bundle and cannot be sealed.
mkdir -p "$source/target/partial/draft/roles/bootstrap-converged.publishing"
cp "$source/target/linux/complete/context.json" "$source/target/partial/draft/context.json"
if fixture_cli seal "$source" "$source/target/partial" linux > "$work/partial-seal.stdout" 2> "$work/partial-seal.stderr"; then cica_fail 'partial publication sealed'; fi
[ ! -e "$source/target/partial/complete" ] || cica_fail 'partial became complete'
record_result partial-seal rejected
cica_jq -sS '{schema:3,status:"pass",cases:.}' "$work/results.jsonl" > "$work/self-test.json"
printf 'ci-compiler-artifact self-tests passed: %s cases\n' "$(jq '.cases|length' "$work/self-test.json")"
