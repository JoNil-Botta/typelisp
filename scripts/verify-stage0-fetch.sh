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
cat > "$work/fetch.ps1" <<'MOCK_PS'
param($Fetcher, $Tag, $Destination)
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
    scenarios='public missing draft pagination full-page dangling-tag no-release bad-checksum fallback-bad-checksum no-sums explicit-tag explicit-no-sums case-variant alias-retry api-failure compare-failure moved-tag empty-asset'
    [ "$fetcher" != sh ] || scenarios="$scenarios crlf-candidates crlf-pagination"
    for scenario in $scenarios; do
        out="$work/out-$fetcher-$scenario"
        mkdir "$out"
        case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) output=typelisp.exe ;; *) output=typelisp ;; esac
        printf 'previous compiler\n' > "$out/$output"
        cp "$out/$output" "$work/previous"
        : > "$work/calls"
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
            if [ "$tag" = stage0-latest ] && [ "$scenario" != public ] && [ "$scenario" != bad-checksum ] && [ "$scenario" != alias-retry ]; then status=404; fi
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
            bad-checksum|fallback-bad-checksum|empty-asset)
                printf 'corrupted\n' > "$work/corrupt"
                [ "$scenario" != empty-asset ] || : > "$work/corrupt"
                jq 'with_entries(if (.key|endswith("/typelisp-stage0-linux") or endswith("/typelisp-stage0-windows.exe")) then .value.file="corrupt" else . end)' "$work/responses.json" > "$work/next.json"
                mv "$work/next.json" "$work/responses.json" ;;
            no-sums|explicit-no-sums)
                jq 'with_entries(if (.key|endswith("/SHA256SUMS")) then .value.status=404 else . end)' "$work/responses.json" > "$work/next.json"
                mv "$work/next.json" "$work/responses.json" ;;
        esac
        tag=stage0-latest
        [ "$scenario" != explicit-tag ] || tag=pinned-missing
        [ "$scenario" != explicit-no-sums ] || tag=pinned-public
        [ "$scenario" != case-variant ] || tag=STAGE0-LATEST
        attempts=1
        [ "$scenario" != alias-retry ] || attempts=2
        force_crlf=0
        case "$scenario" in crlf-*) force_crlf=1 ;; esac
        status=0
        if [ "$fetcher" = sh ]; then
            PATH="$work/bin:$PATH" FETCH_FIXTURE="$work" FETCH_REAL_JQ="$real_jq" FETCH_CRLF="$force_crlf" TYPELISP_STAGE0_REPO="$repo" TYPELISP_STAGE0_FETCH_ATTEMPTS="$attempts" TYPELISP_STAGE0_FETCH_RETRY_DELAY=0 \
                sh "$ROOT/scripts/fetch-stage0.sh" "$tag" "$out" > "$work/result.log" 2>&1 || status=$?
        else
            FETCH_FIXTURE="$work" TYPELISP_STAGE0_REPO="$repo" TYPELISP_STAGE0_FETCH_ATTEMPTS="$attempts" TYPELISP_STAGE0_FETCH_RETRY_DELAY=0 \
                pwsh -NoProfile -File "$work/fetch.ps1" "$ROOT/scripts/fetch-stage0.ps1" "$tag" "$out" > "$work/result.log" 2>&1 || status=$?
        fi
        case "$scenario" in
            public|missing|draft|pagination|full-page|dangling-tag|explicit-no-sums|alias-retry|crlf-candidates|crlf-pagination)
                if [ "$status" -ne 0 ] || ! cmp -s "$work/payload" "$out/$output"; then
                    cat "$work/result.log" >&2
                    echo "stage0 fetch $fetcher/$scenario failed" >&2
                    exit 1
                fi
                case "$scenario" in
                    public|explicit-no-sums|alias-retry) : ;;
                    *) grep -F "falling back to $repo@$good" "$work/result.log" >/dev/null ;;
                esac
                ;;
            *)
                if [ "$status" -eq 0 ] || ! cmp -s "$work/previous" "$out/$output"; then
                    cat "$work/result.log" >&2
                    echo "stage0 fetch $fetcher/$scenario accepted invalid release or replaced the destination" >&2
                    exit 1
                fi
                ;;
        esac
        case "$scenario" in
            public|bad-checksum|explicit-tag|explicit-no-sums|case-variant)
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
