#!/usr/bin/env sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT HUP INT TERM
mkdir "$work/bin"
printf 'verified stage0 fixture\n' > "$work/payload"
hash=$(sha256sum "$work/payload" | cut -d ' ' -f 1)
printf '%s  typelisp-stage0-linux\n%s  typelisp-stage0-windows.exe\n' "$hash" "$hash" > "$work/SHA256SUMS"
cat > "$work/bin/curl" <<'MOCK_CURL'
#!/usr/bin/env sh
set -eu
output=
write_status=0
url=
while [ "$#" -gt 0 ]; do
    case "$1" in
        -o) output=$2; shift ;;
        -w) write_status=1; shift ;;
        https://*) url=$1 ;;
    esac
    shift
done
printf '%s\n' "$url" >> "$FETCH_FIXTURE/calls"
record=$(jq -c --arg url "$url" '.[$url] // {status:404}' "$FETCH_FIXTURE/responses.json")
status=$(printf '%s' "$record" | jq -r .status)
first_status=$(printf '%s' "$record" | jq -r '.firstStatus // empty')
if [ -n "$first_status" ] && [ "$(grep -Fxc "$url" "$FETCH_FIXTURE/calls")" -eq 1 ]; then status=$first_status; fi
if [ "$write_status" -eq 1 ]; then printf '%s' "$status"; fi
[ "$status" = 200 ] || exit 22
file=$(printf '%s' "$record" | jq -r '.file // empty')
if [ -n "$file" ]; then
    cp "$FETCH_FIXTURE/$file" "$output"
else
    printf '%s' "$record" | jq -r .body > "$output"
fi
MOCK_CURL
chmod +x "$work/bin/curl"
real_jq=$(command -v jq)
cat > "$work/bin/jq" <<'MOCK_JQ'
#!/usr/bin/env sh
if [ "$FETCH_CRLF" = 1 ]; then
    for argument do
        case "$argument" in
            length|*@tsv*)
                "$FETCH_REAL_JQ" "$@" > "$FETCH_FIXTURE/jq-output" || exit "$?"
                awk '{ sub(/\r$/, ""); printf "%s\r\n", $0 }' "$FETCH_FIXTURE/jq-output"
                exit ;;
        esac
    done
fi
exec "$FETCH_REAL_JQ" "$@"
MOCK_JQ
chmod +x "$work/bin/jq"
cat > "$work/bin/sleep" <<'MOCK_SLEEP'
#!/usr/bin/env sh
printf '%s\n' "$1" >> "$FETCH_FIXTURE/sleeps"
MOCK_SLEEP
chmod +x "$work/bin/sleep"
cat > "$work/fetch.ps1" <<'MOCK_PS'
param($Fetcher, $Tag, $Destination)
function Start-Sleep {
    param([int] $Seconds)
    Add-Content -LiteralPath (Join-Path $env:FETCH_FIXTURE 'sleeps') -Value $Seconds
}
function Invoke-WebRequest {
    param([string] $Uri, [string] $OutFile, [switch] $UseBasicParsing)
    Add-Content -LiteralPath (Join-Path $env:FETCH_FIXTURE 'calls') -Value $Uri
    $Map = Get-Content -Raw -LiteralPath (Join-Path $env:FETCH_FIXTURE 'responses.json') | ConvertFrom-Json
    $Entry = $Map.PSObject.Properties[$Uri]
    $Status = if ($Entry) { $Entry.Value.status } else { 404 }
    if ($Entry -and $Entry.Value.PSObject.Properties['firstStatus'] -and
        @(Get-Content -LiteralPath (Join-Path $env:FETCH_FIXTURE 'calls') | Where-Object { $_ -ceq $Uri }).Count -eq 1) {
        $Status = $Entry.Value.firstStatus
    }
    if ($Status -ne 200) {
        $Response = [System.Net.Http.HttpResponseMessage]::new([System.Net.HttpStatusCode] $Status)
        throw [Microsoft.PowerShell.Commands.HttpResponseException]::new('fixture HTTP failure', $Response)
    }
    $Value = $Entry.Value
    if ($OutFile) {
        if ($Value.PSObject.Properties['file']) {
            Copy-Item -LiteralPath (Join-Path $env:FETCH_FIXTURE $Value.file) -Destination $OutFile
        } else {
            [System.IO.File]::WriteAllText($OutFile, $Value.body)
        }
    } else {
        [pscustomobject] @{ Content = $Value.body }
    }
}
& $Fetcher $Tag $Destination
MOCK_PS
repo=fixture/project
api=https://api.github.com/repos/$repo
base=https://github.com/$repo/releases/download
sha=0123456789abcdef0123456789abcdef01234567
good=stage0-20261018-120000-r100
bad=stage0-20261019-120000-r101
release=$(jq -n --arg tag "$good" --arg sha "$sha" '{tag_name:$tag,target_commitish:$sha,draft:false,prerelease:false,published_at:"2026-10-18T12:00:00Z",assets:[{name:"typelisp-stage0-linux",state:"uploaded",size:10},{name:"typelisp-stage0-windows.exe",state:"uploaded",size:10},{name:"SHA256SUMS",state:"uploaded",size:100}]}')
fetchers=sh
case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) command -v pwsh >/dev/null; fetchers='sh ps1' ;;
    *) if command -v pwsh >/dev/null 2>&1; then fetchers='sh ps1'; fi ;;
esac
for fetcher in $fetchers; do
    scenarios='public missing draft pagination full-page dangling-tag no-release bad-checksum fallback-bad-checksum repeated-bad-checksum repeated-bad-checksum-fallback-bad repeated-bad-checksum-explicit fallback-non-sticky widening-backoff no-sums explicit-tag explicit-no-sums case-variant alias-retry api-failure compare-failure moved-tag empty-asset'
    case "$(uname -s)" in
        Linux*) scenarios="$scenarios bundle-404-no-leak bundle-404-retry-ok" ;;
    esac
    [ "$fetcher" != sh ] || scenarios="$scenarios crlf-candidates crlf-pagination"
    for scenario in $scenarios; do
        out="$work/out-$fetcher-$scenario"
        mkdir "$out"
        case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) output=typelisp.exe ;; *) output=typelisp ;; esac
        printf 'previous compiler\n' > "$out/$output"
        chmod +x "$out/$output"
        cp "$out/$output" "$work/previous"
        : > "$work/calls"
        : > "$work/sleeps"
        page=$(printf '%s' "$release" | jq --arg bad "$bad" '[. + {tag_name:$bad,published_at:"2026-10-19T12:00:00Z"}, .]')
        [ "$scenario" != no-release ] || page='[]'
        if [ "$scenario" = full-page ]; then page=$(printf '%s' "$page" | jq '. + [range(98)|{draft:true}]'); fi
        if [ "$scenario" = draft ]; then page=$(printf '%s' "$page" | jq '. + [.[1] + {tag_name:"stage0-latest",draft:true}]'); fi
        compare=$(jq -n --arg sha "$sha" '{base_commit:{sha:$sha},status:"ahead"}')
        [ "$scenario" != moved-tag ] || compare='{"base_commit":{"sha":"bad"},"status":"ahead"}'
        jq -n --arg api "$api" --arg base "$base" --arg good "$good" --arg bad "$bad" --argjson page "$page" --argjson compare "$compare" '{
            ($api+"/releases?per_page=100&page=1"):{status:200,body:($page|tojson)},
            ($api+"/compare/"+$bad+"...main"):{status:200,body:"{\"base_commit\":{\"sha\":\"bad\"},\"status\":\"diverged\"}"},
            ($api+"/compare/"+$good+"...main"):{status:200,body:($compare|tojson)}
        }' > "$work/responses.json"
        for tag in stage0-latest "$good" pinned-public; do
            status=200
            if [ "$tag" = stage0-latest ]; then
                case "$scenario" in
                    public|bad-checksum|repeated-bad-checksum|repeated-bad-checksum-fallback-bad|fallback-non-sticky|widening-backoff|alias-retry|bundle-404-no-leak|bundle-404-retry-ok) ;;
                    *) status=404 ;;
                esac
            fi
            for asset in typelisp-stage0-linux typelisp-stage0-windows.exe SHA256SUMS; do
                file=payload
                [ "$asset" != SHA256SUMS ] || file=SHA256SUMS
                jq --arg url "$base/$tag/$asset" --argjson status "$status" --arg file "$file" '. + {($url):{status:$status,file:$file}}' "$work/responses.json" > "$work/next.json"
                mv "$work/next.json" "$work/responses.json"
            done
        done
        case "$scenario" in
            alias-retry)
                jq --arg api "$api" 'with_entries(if (.key|contains("/stage0-latest/")) and (.key|endswith("/typelisp-stage0-linux") or endswith("/typelisp-stage0-windows.exe")) then .value.firstStatus=404 else . end) | .[$api+"/releases?per_page=100&page=1"]={status:503}' "$work/responses.json" > "$work/next.json"
                mv "$work/next.json" "$work/responses.json" ;;
            fallback-non-sticky)
                jq --arg base "$base" --arg good "$good" 'with_entries(if (.key|contains("/stage0-latest/")) and (.key|endswith("/typelisp-stage0-linux") or endswith("/typelisp-stage0-windows.exe")) then .value.firstStatus=404 elif (.key|startswith($base+"/"+$good+"/")) then .value.status=503 else . end)' "$work/responses.json" > "$work/next.json"
                mv "$work/next.json" "$work/responses.json" ;;
            pagination|crlf-pagination)
                jq --arg api "$api" --argjson page "$page" '. + {($api+"/releases?per_page=100&page=1"):{status:200,body:([range(100)|{draft:true}]|tojson)},($api+"/releases?per_page=100&page=2"):{status:200,body:($page|tojson)}}' "$work/responses.json" > "$work/next.json"
                mv "$work/next.json" "$work/responses.json" ;;
            api-failure|compare-failure|dangling-tag)
                endpoint="$api/releases?per_page=100&page=1"
                response_status=503
                if [ "$scenario" != api-failure ]; then endpoint="$api/compare/$bad...main"; fi
                [ "$scenario" != dangling-tag ] || response_status=404
                jq --arg url "$endpoint" --argjson status "$response_status" '.[$url]={status:$status}' "$work/responses.json" > "$work/next.json"
                mv "$work/next.json" "$work/responses.json" ;;
            bad-checksum|fallback-bad-checksum|repeated-bad-checksum-fallback-bad|repeated-bad-checksum-explicit|empty-asset)
                printf 'corrupted\n' > "$work/corrupt"
                [ "$scenario" != empty-asset ] || : > "$work/corrupt"
                jq 'with_entries(if (.key|endswith("/typelisp-stage0-linux") or endswith("/typelisp-stage0-windows.exe")) then .value.file="corrupt" else . end)' "$work/responses.json" > "$work/next.json"
                mv "$work/next.json" "$work/responses.json" ;;
            repeated-bad-checksum)
                printf 'corrupted\n' > "$work/corrupt"
                jq 'with_entries(if (.key|contains("/stage0-latest/")) and (.key|endswith("/typelisp-stage0-linux") or endswith("/typelisp-stage0-windows.exe")) then .value.file="corrupt" else . end)' "$work/responses.json" > "$work/next.json"
                mv "$work/next.json" "$work/responses.json" ;;
            bundle-404-no-leak|widening-backoff)
                jq --arg base "$base" '.[$base+"/stage0-latest/SHA256SUMS"].status=503' "$work/responses.json" > "$work/next.json"
                mv "$work/next.json" "$work/responses.json" ;;
            bundle-404-retry-ok)
                jq --arg base "$base" '.[$base+"/stage0-latest/SHA256SUMS"].firstStatus=503' "$work/responses.json" > "$work/next.json"
                mv "$work/next.json" "$work/responses.json" ;;
            no-sums|explicit-no-sums)
                jq 'with_entries(if (.key|endswith("/SHA256SUMS")) then .value.status=404 else . end)' "$work/responses.json" > "$work/next.json"
                mv "$work/next.json" "$work/responses.json" ;;
        esac
        tag=stage0-latest
        [ "$scenario" != explicit-tag ] || tag=pinned-missing
        [ "$scenario" != explicit-no-sums ] || tag=pinned-public
        [ "$scenario" != repeated-bad-checksum-explicit ] || tag=pinned-public
        [ "$scenario" != case-variant ] || tag=STAGE0-LATEST
        attempts=1
        retry_delay=0
        case "$scenario" in
            alias-retry|fallback-non-sticky|repeated-bad-checksum-fallback-bad|repeated-bad-checksum-explicit|bundle-404-retry-ok) attempts=2 ;;
            repeated-bad-checksum) attempts=3 ;;
            widening-backoff) attempts=5; retry_delay=5 ;;
        esac
        bundle_asset=
        case "$scenario" in
            bundle-404-*) bundle_asset=typelisp-stage0-linux-bundle.tar.gz ;;
        esac
        force_crlf=0
        case "$scenario" in crlf-*) force_crlf=1 ;; esac
        status=0
        if [ "$fetcher" = sh ]; then
            PATH="$work/bin:$PATH" FETCH_FIXTURE="$work" FETCH_REAL_JQ="$real_jq" FETCH_CRLF="$force_crlf" TYPELISP_STAGE0_REPO="$repo" TYPELISP_STAGE0_BUNDLE_ASSET="$bundle_asset" TYPELISP_STAGE0_FETCH_ATTEMPTS="$attempts" TYPELISP_STAGE0_FETCH_RETRY_DELAY="$retry_delay" \
                sh "$ROOT/scripts/fetch-stage0.sh" "$tag" "$out" > "$work/result.log" 2>&1 || status=$?
        else
            FETCH_FIXTURE="$work" TYPELISP_STAGE0_REPO="$repo" TYPELISP_STAGE0_BUNDLE_ASSET="$bundle_asset" TYPELISP_STAGE0_FETCH_ATTEMPTS="$attempts" TYPELISP_STAGE0_FETCH_RETRY_DELAY="$retry_delay" \
                pwsh -NoProfile -File "$work/fetch.ps1" "$ROOT/scripts/fetch-stage0.ps1" "$tag" "$out" > "$work/result.log" 2>&1 || status=$?
        fi
        case "$scenario" in
            public|missing|draft|pagination|full-page|dangling-tag|explicit-no-sums|alias-retry|fallback-non-sticky|repeated-bad-checksum|bundle-404-retry-ok|crlf-candidates|crlf-pagination)
                if [ "$status" -ne 0 ] || ! cmp -s "$work/payload" "$out/$output"; then
                    cat "$work/result.log" >&2
                    echo "stage0 fetch $fetcher/$scenario failed" >&2
                    exit 1
                fi
                case "$scenario" in
                    public|explicit-no-sums|alias-retry|fallback-non-sticky|bundle-404-retry-ok) : ;;
                    *) grep -F "falling back to $repo@$good" "$work/result.log" >/dev/null ;;
                esac
                ;;
            *)
                if [ "$status" -eq 0 ] || ! cmp -s "$work/previous" "$out/$output" || [ ! -x "$out/$output" ]; then
                    cat "$work/result.log" >&2
                    echo "stage0 fetch $fetcher/$scenario accepted invalid release or replaced the destination" >&2
                    exit 1
                fi
                ;;
        esac
        if [ "$scenario" = repeated-bad-checksum ]; then
            case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) check_asset=typelisp-stage0-windows.exe ;; *) check_asset=typelisp-stage0-linux ;; esac
            latest_calls=$(grep -Fxc "$base/stage0-latest/$check_asset" "$work/calls" || true)
            if [ "$latest_calls" -ne "$attempts" ]; then
                cat "$work/calls" >&2
                echo "stage0 fetch $fetcher/$scenario did not exhaust stage0-latest retries before fallback (got $latest_calls, want $attempts)" >&2
                exit 1
            fi
        fi
        case "$scenario" in
            bundle-404-*)
                if ! grep -F "/stage0-latest/$bundle_asset" "$work/calls" >/dev/null; then
                    cat "$work/calls" >&2
                    echo "stage0 fetch $fetcher/$scenario did not exercise bundle asset download" >&2
                    exit 1
                fi ;;
        esac
        if [ "$scenario" = widening-backoff ]; then
            printf '5\n10\n20\n30\n' > "$work/expected-sleeps"
            if ! cmp -s "$work/expected-sleeps" "$work/sleeps"; then
                cat "$work/sleeps" >&2
                echo "stage0 fetch $fetcher/$scenario backoff schedule mismatch" >&2
                exit 1
            fi
        fi
        case "$scenario" in
            public|bad-checksum|repeated-bad-checksum-explicit|widening-backoff|bundle-404-no-leak|bundle-404-retry-ok|explicit-tag|explicit-no-sums|case-variant)
                if grep -F api.github.com "$work/calls" >/dev/null; then
                    echo "stage0 fetch $fetcher/$scenario unexpectedly selected another release" >&2
                    exit 1
                fi ;;
        esac
        for temp in "$out"/.stage0-download.*; do
            [ ! -e "$temp" ] || { echo "stage0 fetch left temporary state: $temp" >&2; exit 1; }
        done
        echo "stage0 fetch $fetcher/$scenario passed"
    done
done

# --at-commit selects the newest permanent generation built at or before that
# commit, never the mutable stage0-latest (#9823).
at_commit=abcdef0123456789abcdef0123456789abcdef01
at_newer=stage0-20261019-120000-r101
at_ancestor=stage0-20261018-120000-r100
at_older=stage0-20261017-120000-r99
at_sha_newer=1111111111111111111111111111111111111111
at_sha_ancestor=2222222222222222222222222222222222222222
at_sha_older=3333333333333333333333333333333333333333
at_releases=$(jq -n \
    --arg newer "$at_newer" --arg ancestor "$at_ancestor" --arg older "$at_older" \
    --arg sha_newer "$at_sha_newer" --arg sha_ancestor "$at_sha_ancestor" --arg sha_older "$at_sha_older" '
    [{tag_name:$newer, target_commitish:$sha_newer, published_at:"2026-10-19T12:00:00Z"},
     {tag_name:$ancestor, target_commitish:$sha_ancestor, published_at:"2026-10-18T12:00:00Z"},
     {tag_name:$older, target_commitish:$sha_older, published_at:"2026-10-17T12:00:00Z"}] |
    map(. + {draft:false, prerelease:false,
        assets:[{name:"typelisp-stage0-linux",state:"uploaded",size:10},
                {name:"typelisp-stage0-windows.exe",state:"uploaded",size:10},
                {name:"SHA256SUMS",state:"uploaded",size:100}]})')
# The newest release is not an ancestor of the base; of the two ancestors the
# newer one must win. Only the two ancestors can be downloaded, so a wrong
# choice fails instead of merely fetching another tag.
at_responses() {
    jq -n --arg api "$api" --arg base "$base" --arg at "$at_commit" \
        --arg newer "$at_newer" --arg ancestor "$at_ancestor" --arg older "$at_older" \
        --arg sha_ancestor "$at_sha_ancestor" --arg sha_older "$at_sha_older" \
        --argjson releases "$at_releases" --arg mode "$1" '
    def entry($body): {status:200, body:($body|tojson)};
    {
      ($api+"/releases?per_page=100&page=1"):
        (if $mode == "api-failure" then {status:503} else entry($releases) end),
      ($api+"/compare/"+$newer+"..."+$at):
        entry({base_commit:{sha:"0000000000000000000000000000000000000000"},status:"diverged"}),
      ($api+"/compare/"+$ancestor+"..."+$at):
        entry({base_commit:{sha:$sha_ancestor},status:(if $mode == "none" then "diverged" else "ahead" end)}),
      ($api+"/compare/"+$older+"..."+$at):
        entry({base_commit:{sha:$sha_older},status:(if $mode == "none" then "behind" else "ahead" end)}),
      ($base+"/"+$ancestor+"/typelisp-stage0-linux"):{status:200,file:"payload"},
      ($base+"/"+$ancestor+"/typelisp-stage0-windows.exe"):{status:200,file:"payload"},
      ($base+"/"+$ancestor+"/SHA256SUMS"):{status:200,file:"SHA256SUMS"},
      ($base+"/"+$older+"/typelisp-stage0-linux"):{status:200,file:"payload"},
      ($base+"/"+$older+"/typelisp-stage0-windows.exe"):{status:200,file:"payload"},
      ($base+"/"+$older+"/SHA256SUMS"):{status:200,file:"SHA256SUMS"}
    }' > "$work/responses.json"
}
case "$(uname -s)" in MINGW* | MSYS* | CYGWIN*) at_output=typelisp.exe ;; *) at_output=typelisp ;; esac
for at_mode in choose none api-failure; do
    out="$work/at-$at_mode"
    mkdir "$out"
    printf 'previous compiler\n' > "$out/$at_output"
    chmod +x "$out/$at_output"
    : > "$work/calls"
    at_responses "$at_mode"
    status=0
    PATH="$work/bin:$PATH" FETCH_FIXTURE="$work" FETCH_REAL_JQ="$real_jq" FETCH_CRLF=0 \
        TYPELISP_STAGE0_REPO="$repo" TYPELISP_STAGE0_FETCH_ATTEMPTS=1 TYPELISP_STAGE0_FETCH_RETRY_DELAY=0 \
        sh "$ROOT/scripts/fetch-stage0.sh" --at-commit "$at_commit" "$out" > "$work/result.log" 2>&1 || status=$?
    case "$at_mode" in
        choose)
            if [ "$status" -ne 0 ] || ! cmp -s "$work/payload" "$out/$at_output"; then
                cat "$work/result.log" >&2
                echo "stage0 fetch sh/at-commit-$at_mode failed" >&2
                exit 1
            fi
            grep -F "newest permanent release at or before $at_commit is $at_ancestor" "$work/result.log" >/dev/null || {
                cat "$work/result.log" >&2
                echo "stage0 fetch sh/at-commit-$at_mode did not name the newest ancestor" >&2
                exit 1
            }
            grep -F "/$at_ancestor/typelisp" "$work/calls" >/dev/null || {
                cat "$work/calls" >&2
                echo "stage0 fetch sh/at-commit-$at_mode did not download the newest ancestor" >&2
                exit 1
            }
            if grep -E "/($at_newer|$at_older)/" "$work/calls" >/dev/null; then
                cat "$work/calls" >&2
                echo "stage0 fetch sh/at-commit-$at_mode downloaded another generation" >&2
                exit 1
            fi
            ;;
        *)
            if [ "$status" -eq 0 ] || ! cmp -s "$work/previous" "$out/$at_output" || [ ! -x "$out/$at_output" ]; then
                cat "$work/result.log" >&2
                echo "stage0 fetch sh/at-commit-$at_mode accepted an unusable selection" >&2
                exit 1
            fi
            if [ "$at_mode" = api-failure ]; then
                grep -F "cannot list permanent stage0 releases" "$work/result.log" >/dev/null || {
                    cat "$work/result.log" >&2
                    echo "stage0 fetch sh/at-commit-$at_mode hid the API failure" >&2
                    exit 1
                }
            else
                grep -F "refusing the mutable stage0-latest" "$work/result.log" >/dev/null || {
                    cat "$work/result.log" >&2
                    echo "stage0 fetch sh/at-commit-$at_mode did not explain the refusal" >&2
                    exit 1
                }
            fi
            if grep -F "/stage0-latest/" "$work/calls" >/dev/null; then
                cat "$work/calls" >&2
                echo "stage0 fetch sh/at-commit-$at_mode fell back to stage0-latest" >&2
                exit 1
            fi
            ;;
    esac
    for temp in "$out"/.stage0-download.*; do
        [ ! -e "$temp" ] || { echo "stage0 fetch left temporary state: $temp" >&2; exit 1; }
    done
    echo "stage0 fetch sh/at-commit-$at_mode passed"
done

case "$(uname -s)" in
    Linux*)
        out="$work/concurrent output"
        mkdir "$out"
        : > "$work/calls"
        : > "$work/publication-observations"
        jq -n --arg base "$base" '{
            ($base+"/stage0-latest/typelisp-stage0-linux"):{status:200,file:"payload"},
            ($base+"/stage0-latest/SHA256SUMS"):{status:200,file:"SHA256SUMS"}
        }' > "$work/responses.json"
        real_mv=$(command -v mv)
        cat > "$work/bin/mv" <<'OBSERVE_PUBLICATION'
#!/usr/bin/env sh
set -eu
"$FETCH_REAL_MV" "$@"
for destination do :; done
if [ "$destination" = "$FETCH_PUBLICATION_DEST" ]; then
    # Observe the published file before the installer can change it again.
    if [ -s "$destination" ] && [ -x "$destination" ] && cmp -s "$FETCH_FIXTURE/payload" "$destination"; then
        printf 'ready\n' >> "$FETCH_FIXTURE/publication-observations"
    else
        printf 'not-ready\n' >> "$FETCH_FIXTURE/publication-observations"
    fi
fi
OBSERVE_PUBLICATION
        chmod +x "$work/bin/mv"
        concurrent_fetch() {
            PATH="$work/bin:$PATH" FETCH_FIXTURE="$work" FETCH_REAL_JQ="$real_jq" FETCH_CRLF=0 \
                FETCH_REAL_MV="$real_mv" FETCH_PUBLICATION_DEST="$out/typelisp" \
                TYPELISP_STAGE0_REPO="$repo" TYPELISP_STAGE0_FETCH_ATTEMPTS=1 TYPELISP_STAGE0_FETCH_RETRY_DELAY=0 \
                sh "$ROOT/scripts/fetch-stage0.sh" stage0-latest "$out"
        }
        concurrent_fetch > "$work/first.log" 2>&1 & first=$!
        concurrent_fetch > "$work/second.log" 2>&1 & second=$!
        first_status=0
        wait "$first" || first_status=$?
        second_status=0
        wait "$second" || second_status=$?
        printf 'ready\nready\n' > "$work/expected-publications"
        if [ "$first_status" -ne 0 ] || [ "$second_status" -ne 0 ] || \
            ! cmp -s "$work/expected-publications" "$work/publication-observations"; then
            cat "$work/first.log" "$work/second.log" "$work/publication-observations" >&2
            echo "stage0 fetch sh/concurrent-publication exposed an unusable compiler" >&2
            exit 1
        fi
        cmp "$work/payload" "$out/typelisp"
        [ -x "$out/typelisp" ]
        for temp in "$out"/.stage0-download.*; do
            [ ! -e "$temp" ] || { echo "stage0 fetch left temporary state: $temp" >&2; exit 1; }
        done
        echo "stage0 fetch sh/concurrent-publication passed"

        out="$work/permission failure"
        mkdir "$out"
        cp "$work/previous" "$out/typelisp"
        chmod +x "$out/typelisp"
        cat > "$work/bin/chmod" <<'DENY_PERMISSION'
#!/usr/bin/env sh
exit 73
DENY_PERMISSION
        chmod +x "$work/bin/chmod"
        status=0
        concurrent_fetch > "$work/permission.log" 2>&1 || status=$?
        if [ "$status" -eq 0 ] || ! cmp -s "$work/previous" "$out/typelisp" || [ ! -x "$out/typelisp" ]; then
            cat "$work/permission.log" >&2
            echo "stage0 fetch sh/permission-failure replaced the usable compiler" >&2
            exit 1
        fi
        for temp in "$out"/.stage0-download.*; do
            [ ! -e "$temp" ] || { echo "stage0 fetch left temporary state: $temp" >&2; exit 1; }
        done
        echo "stage0 fetch sh/permission-failure passed"
        ;;
esac
