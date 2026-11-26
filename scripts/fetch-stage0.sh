#!/usr/bin/env sh
set -eu

# fetch-stage0.sh - download the published stage0 compiler for this host.
#
# Defaults to the mutable stage0-latest release, using release asset URLs rather
# than git tags so local tag state cannot make the "latest" pointer stale.
# --at-commit COMMIT instead selects the newest permanent generation built at or
# before that commit, for building old sources that a newer stage0 may reject.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

usage() {
    cat >&2 <<'EOF'
usage: scripts/fetch-stage0.sh [tag | --at-commit COMMIT] [output-dir]

Downloads the current host's stage0 compiler from a GitHub release. On Linux,
the script prefers the bundled stage0 asset and falls back to the legacy
single-file asset when the bundle is not present.

Options:
  --at-commit COMMIT
              download the newest permanent stage0-<date>-r<run> release built
              from COMMIT or an ancestor of it, so that stage0 can build that
              commit; never the mutable stage0-latest, which may have been
              rebuilt from a newer commit. Fails when no such release exists.

Defaults:
  tag:        ${TYPELISP_STAGE0_TAG:-stage0-latest}
  output-dir: ${TYPELISP_STAGE0_DIR:-target/stage0}
  repo:       ${TYPELISP_STAGE0_REPO:-JoNil-Botta/typelisp}

The downloaded binary is written as:
  target/stage0/typelisp      on Linux
  target/stage0/typelisp.exe  on Windows Git Bash/MSYS/Cygwin
EOF
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    usage
    exit 0
fi

AT_COMMIT=
if [ "${1:-}" = --at-commit ]; then
    [ "$#" -ge 2 ] || { usage; exit 2; }
    AT_COMMIT=$2
    shift 2
    [ "$#" -le 1 ] || { usage; exit 2; }
    TAG=
    OUT_DIR=${1:-${TYPELISP_STAGE0_DIR:-target/stage0}}
else
    [ "$#" -le 2 ] || { usage; exit 2; }
    TAG=${1:-${TYPELISP_STAGE0_TAG:-stage0-latest}}
    OUT_DIR=${2:-${TYPELISP_STAGE0_DIR:-target/stage0}}
fi
case "$AT_COMMIT" in
    "") ;;
    *[!0-9a-f]*)
        echo "--at-commit needs a lowercase 40-digit commit id: $AT_COMMIT" >&2
        exit 2
        ;;
    *)
        if [ "${#AT_COMMIT}" -ne 40 ]; then
            echo "--at-commit needs a lowercase 40-digit commit id: $AT_COMMIT" >&2
            exit 2
        fi
        ;;
esac
REQUESTED_TAG=$TAG
REQUIRE_SUMS=0
[ "$TAG" != stage0-latest ] || REQUIRE_SUMS=1
REPO=${TYPELISP_STAGE0_REPO:-JoNil-Botta/typelisp}
API_TOKEN=${TYPELISP_STAGE0_API_TOKEN:-${GH_TOKEN:-${GITHUB_TOKEN:-}}}

if [ -z "$AT_COMMIT" ]; then
    case "$TAG" in
        "")
            echo "stage0 tag must not be empty" >&2
            exit 2
            ;;
    esac
fi

case "$(uname -s)" in
    Linux*)
        SINGLE_ASSET=typelisp-stage0-linux
        BUNDLE_ASSET=${TYPELISP_STAGE0_BUNDLE_ASSET:-}
        OUTPUT=typelisp
        NEED_EXEC=1
        SYSROOT_TRIPLE=x86_64-unknown-linux-gnu
        ;;
    MINGW* | MSYS* | CYGWIN*)
        SINGLE_ASSET=typelisp-stage0-windows.exe
        BUNDLE_ASSET=
        OUTPUT=typelisp.exe
        NEED_EXEC=0
        SYSROOT_TRIPLE=x86_64-pc-windows-msvc
        ;;
    *)
        echo "stage0 fetch is unsupported on this host: $(uname -s)" >&2
        exit 1
        ;;
esac
SYSROOT_TLI_ASSET="typelisp-stdlib-$SYSROOT_TRIPLE.tli"
SYSROOT_LIB_ASSET="libstdlib-$SYSROOT_TRIPLE.a"

if ! command -v curl >/dev/null 2>&1; then
    echo "stage0 fetch requires curl" >&2
    exit 1
fi

mkdir -p "$OUT_DIR"
TMP_DIR="$OUT_DIR/.stage0-download.$$"
rm -rf "$TMP_DIR"
mkdir -p "$TMP_DIR"
trap 'rm -rf "$TMP_DIR"' EXIT HUP INT TERM

SUMS_TMP="$TMP_DIR/SHA256SUMS"
SUMS_SELECTED="$TMP_DIR/SHA256SUMS.selected"
DEST="$OUT_DIR/$OUTPUT"
ASSET=
ASSET_TMP=
ASSET_KIND=single

download_asset() {
    asset=$1
    mark_missing=${2:-1}
    target="$TMP_DIR/$asset"
    if asset_status=$(curl -fsSL -w '%{http_code}' "$BASE_URL/$asset" -o "$target"); then
        if [ ! -s "$target" ]; then
            echo "[stage0] downloaded stage0 asset is empty (possibly mid-republish): $asset" >&2
            rm -f "$target"
            return 1
        fi
        ASSET=$asset
        ASSET_TMP=$target
        return 0
    fi
    if [ "$mark_missing" -eq 1 ] && [ "$asset_status" = 404 ]; then
        RELEASE_MISSING=1
    fi
    rm -f "$target"
    return 1
}

SYSROOT_TLI_TMP=
SYSROOT_LIB_TMP=
HAVE_SUMS=0

download_optional_asset() {
    opt_asset=$1
    opt_target="$TMP_DIR/$opt_asset"
    if opt_status=$(curl -fsSL -w '%{http_code}' "$BASE_URL/$opt_asset" -o "$opt_target" 2>/dev/null); then
        if [ ! -s "$opt_target" ]; then
            echo "[stage0] downloaded optional asset is empty (possibly mid-republish): $opt_asset" >&2
            rm -f "$opt_target"
            return 2
        fi
        return 0
    fi
    rm -f "$opt_target"
    if [ "$opt_status" = 404 ]; then
        return 1
    fi
    return 2
}

verify_optional_sum() {
    opt_asset=$1
    if [ "$HAVE_SUMS" -eq 1 ]; then
        if grep "  $opt_asset\$" "$SUMS_TMP" > "$SUMS_SELECTED"; then
            if ! (cd "$TMP_DIR" && sha256sum -c "$(basename "$SUMS_SELECTED")"); then
                CHECKSUM_MISMATCH=1
                echo "[stage0] SHA256SUMS verification failed for $opt_asset (republish in progress?)" >&2
                return 1
            fi
        fi
    fi
    return 0
}

# Download the host asset (Linux: bundle first, single fallback) plus the
# SHA256SUMS manifest, and verify them together. Returns non-zero on any
# transient miss so the caller can retry the whole download+verify as one unit.
#
# The mutable stage0-latest release is promoted from a fully uploaded draft on
# every push to main (see .github/workflows/bootstrap-stage0.yml). GitHub cannot
# atomically replace the old release/tag alias, so a concurrent fetch can still
# observe a brief 404 during the two API mutations or CDN propagation. Fetching
# the asset and SHA256SUMS together on every fresh attempt keeps that bounded
# cutover safe instead of failing the whole CI gate.
fetch_and_verify() {
    ASSET=
    ASSET_TMP=
    ASSET_KIND=single
    RELEASE_MISSING=0
    CHECKSUM_MISMATCH=0
    SYSROOT_TLI_TMP=
    SYSROOT_LIB_TMP=
    HAVE_SUMS=0

    if [ -n "$BUNDLE_ASSET" ]; then
        echo "[stage0] downloading $BUNDLE_ASSET from $REPO@$TAG"
        if download_asset "$BUNDLE_ASSET" 0; then
            ASSET_KIND=bundle
        else
            echo "[stage0] bundled Linux stage0 asset not present yet; trying $SINGLE_ASSET"
        fi
    fi

    if [ -z "$ASSET" ]; then
        echo "[stage0] downloading $SINGLE_ASSET from $REPO@$TAG"
        if ! download_asset "$SINGLE_ASSET"; then
            echo "[stage0] could not download $BASE_URL/$SINGLE_ASSET" >&2
            return 1
        fi
    fi

    if sums_status=$(curl -fsSL -w '%{http_code}' "$BASE_URL/SHA256SUMS" -o "$SUMS_TMP" 2>/dev/null); then
        HAVE_SUMS=1
        if ! command -v sha256sum >/dev/null 2>&1; then
            echo "SHA256SUMS is published but sha256sum is not available" >&2
            exit 1
        fi
        if ! grep "  $ASSET\$" "$SUMS_TMP" > "$SUMS_SELECTED"; then
            CHECKSUM_MISMATCH=1
            echo "[stage0] SHA256SUMS does not yet list $ASSET (republish in progress?)" >&2
            return 1
        fi
        if ! (cd "$TMP_DIR" && sha256sum -c "$(basename "$SUMS_SELECTED")"); then
            CHECKSUM_MISMATCH=1
            echo "[stage0] SHA256SUMS verification failed for $ASSET (republish in progress?)" >&2
            return 1
        fi
    else
        [ "$sums_status" != 404 ] || RELEASE_MISSING=1
        if [ "$REQUIRE_SUMS" -eq 1 ]; then
            echo "[stage0] SHA256SUMS is not visible for stage0-latest yet" >&2
            return 1
        fi
        echo "[stage0] warning: SHA256SUMS not found for $TAG; verified non-empty asset only" >&2
    fi

    # Download prebuilt stdlib sysroot assets when present in the release;
    # gracefully skip on older releases that predate sysroot publication.
    tli_rc=0
    download_optional_asset "$SYSROOT_TLI_ASSET" || tli_rc=$?
    lib_rc=0
    download_optional_asset "$SYSROOT_LIB_ASSET" || lib_rc=$?
    if [ "$tli_rc" -eq 0 ] && [ "$lib_rc" -eq 0 ]; then
        verify_optional_sum "$SYSROOT_TLI_ASSET" || return 1
        verify_optional_sum "$SYSROOT_LIB_ASSET" || return 1
        SYSROOT_TLI_TMP="$TMP_DIR/$SYSROOT_TLI_ASSET"
        SYSROOT_LIB_TMP="$TMP_DIR/$SYSROOT_LIB_ASSET"
    elif [ "$tli_rc" -eq 1 ] && [ "$lib_rc" -eq 1 ]; then
        # Absent on older releases; only fail if SHA256SUMS claims they exist.
        if [ "$HAVE_SUMS" -eq 1 ] &&
            grep -E "  ($SYSROOT_TLI_ASSET|$SYSROOT_LIB_ASSET)\$" "$SUMS_TMP" >/dev/null; then
            CHECKSUM_MISMATCH=1
            echo "[stage0] SHA256SUMS lists sysroot assets that are not visible yet (republish in progress?)" >&2
            return 1
        fi
    else
        echo "[stage0] inconsistent prebuilt stdlib sysroot download (tli=$tli_rc, lib=$lib_rc; republish in progress?)" >&2
        return 1
    fi

    return 0
}

# newest_permanent_release HEAD  ->  the newest published permanent generation
# (stage0-<date>-r<run>) whose tag commit is HEAD or an ancestor of it, so that
# compiler can still build HEAD. HEAD defaults to main.
# Permanent generations are appended to GitHub's newest-first release list.
# Continue past pages containing only drafts/unusable releases, but stop at the
# newest usable generation instead of draining the historical pagination cap.
# Compare the actual tag commit with HEAD, not just target_commitish metadata.
# Returns 2 when the release list or the comparison cannot be read.
# The listing calls are read-only; a CI token, when the caller has one, keeps
# them off the shared unauthenticated rate limit.
api_fetch() {
    if [ -n "$API_TOKEN" ]; then
        curl -fsSL -H "Authorization: Bearer $API_TOKEN" "$@"
    else
        curl -fsSL "$@"
    fi
}

newest_permanent_release() {
    _npr_head=${1:-main}
    command -v jq >/dev/null 2>&1 || {
        echo "[stage0] permanent release selection requires jq" >&2
        return 2
    }
    api="https://api.github.com/repos/$REPO"
    stage0_cr=$(printf '\r')
    page=1
    while :; do
        api_fetch "$api/releases?per_page=100&page=$page" -o "$TMP_DIR/page.json" || return 2
        jq -e 'type == "array"' "$TMP_DIR/page.json" >/dev/null || return 2
        count=$(jq length "$TMP_DIR/page.json") || return 2
        count=${count%"$stage0_cr"}
        jq -r --arg asset "$SINGLE_ASSET" '
        map(select(.draft == false and .prerelease == false and
            (.published_at | type == "string" and length > 0) and
            (.tag_name | test("^stage0-[0-9]{8}-[0-9]{6}-r[0-9]+$")) and
            (.target_commitish | test("^[0-9a-f]{40}$")) and
            any(.assets[]; .name == $asset and .state == "uploaded" and .size > 0) and
            any(.assets[]; .name == "SHA256SUMS" and .state == "uploaded" and .size > 0))) |
        sort_by([.published_at, .tag_name]) | reverse[] | [.tag_name, .target_commitish] | @tsv
        ' "$TMP_DIR/page.json" > "$TMP_DIR/candidates" || return 2
        while read -r candidate_tag candidate_sha; do
            # Native Windows jq leaves CR on the final TSV field.
            candidate_sha=${candidate_sha%"$stage0_cr"}
            [ -n "$candidate_tag" ] || continue
            if ! compare_status=$(api_fetch -w '%{http_code}' "$api/compare/$candidate_tag...$_npr_head" -o "$TMP_DIR/compare.json"); then
                [ "$compare_status" != 404 ] || continue
                return 2
            fi
            if jq -e --arg sha "$candidate_sha" '
                .base_commit.sha == $sha and (.status == "ahead" or .status == "identical")
            ' "$TMP_DIR/compare.json" >/dev/null; then
                printf '%s\n' "$candidate_tag"
                return 0
            fi
        done < "$TMP_DIR/candidates"
        [ "$count" -eq 100 ] || break
        page=$((page + 1))
    done
    echo "[stage0] no published permanent release with $SINGLE_ASSET and SHA256SUMS was built from $_npr_head or an ancestor of it" >&2
    return 1
}

if [ -n "$AT_COMMIT" ]; then
    selection=0
    TAG=$(newest_permanent_release "$AT_COMMIT") || selection=$?
    case "$selection" in
        0) echo "[stage0] newest permanent release at or before $AT_COMMIT is $TAG" ;;
        1)
            echo "[stage0] no permanent stage0-<date>-r<run> release was built from $AT_COMMIT or an ancestor of it" >&2
            echo "[stage0] refusing the mutable stage0-latest: it may have been rebuilt from a newer commit" >&2
            exit 1
            ;;
        *)
            echo "[stage0] cannot list permanent stage0 releases from $REPO" >&2
            exit 1
            ;;
    esac
    # The selected release published SHA256SUMS with its assets; verify it.
    REQUIRE_SUMS=1
fi

BASE_URL="https://github.com/$REPO/releases/download/$TAG"

FETCH_ATTEMPTS=${TYPELISP_STAGE0_FETCH_ATTEMPTS:-6}
FETCH_RETRY_DELAY=${TYPELISP_STAGE0_FETCH_RETRY_DELAY:-5}
case "$FETCH_ATTEMPTS" in '' | *[!0-9]*) FETCH_ATTEMPTS=6 ;; esac
case "$FETCH_RETRY_DELAY" in '' | *[!0-9]*) FETCH_RETRY_DELAY=5 ;; esac

retry_delay_for_attempt() {
    _rdfa_attempt=$1
    _rdfa_delay=$FETCH_RETRY_DELAY
    if [ "$_rdfa_delay" -le 0 ]; then
        printf '0\n'
        return 0
    fi
    if [ -z "$AT_COMMIT" ] && [ "$TAG" = stage0-latest ]; then
        _rdfa_cap=30
        [ "$_rdfa_delay" -le "$_rdfa_cap" ] || _rdfa_cap=$_rdfa_delay
        _rdfa_i=1
        while [ "$_rdfa_i" -lt "$_rdfa_attempt" ] && [ "$_rdfa_delay" -lt "$_rdfa_cap" ]; do
            _rdfa_delay=$((_rdfa_delay * 2))
            _rdfa_i=$((_rdfa_i + 1))
        done
        [ "$_rdfa_delay" -le "$_rdfa_cap" ] || _rdfa_delay=$_rdfa_cap
    fi
    printf '%s\n' "$_rdfa_delay"
}

try_permanent_fallback() {
    _tpf_reason=$1
    if ! fallback_tag=$(newest_permanent_release main); then
        return 1
    fi
    echo "[stage0] $REQUESTED_TAG $_tpf_reason; falling back to $REPO@$fallback_tag" >&2
    _tpf_saved_tag=$TAG
    _tpf_saved_base_url=$BASE_URL
    TAG=$fallback_tag
    BASE_URL="https://github.com/$REPO/releases/download/$TAG"
    rm -rf "$TMP_DIR"
    mkdir -p "$TMP_DIR"
    if fetch_and_verify; then
        return 0
    fi
    TAG=$_tpf_saved_tag
    BASE_URL=$_tpf_saved_base_url
    rm -rf "$TMP_DIR"
    mkdir -p "$TMP_DIR"
    return 1
}

attempt=1
checksum_mismatches=0
while :; do
    if fetch_and_verify; then
        break
    fi
    if [ "$CHECKSUM_MISMATCH" -eq 1 ]; then
        checksum_mismatches=$((checksum_mismatches + 1))
    fi
    if [ -z "$AT_COMMIT" ] && [ "$TAG" = stage0-latest ] && [ "$RELEASE_MISSING" -eq 1 ]; then
        if try_permanent_fallback "unavailable"; then
            break
        fi
    fi
    if [ "$attempt" -ge "$FETCH_ATTEMPTS" ]; then
        if [ -z "$AT_COMMIT" ] && [ "$TAG" = stage0-latest ] && [ "$checksum_mismatches" -ge 2 ]; then
            if try_permanent_fallback "had repeated SHA256SUMS mismatches"; then
                break
            fi
        fi
        echo "failed to fetch a consistent stage0 from $REPO@$TAG after $attempt attempt(s)" >&2
        echo "(the release may be mid-republish, or the asset is genuinely missing)" >&2
        exit 1
    fi
    retry_delay=$(retry_delay_for_attempt "$attempt")
    echo "[stage0] attempt $attempt/$FETCH_ATTEMPTS did not yield a consistent release (likely a republish in progress); retrying in ${retry_delay}s" >&2
    attempt=$((attempt + 1))
    rm -rf "$TMP_DIR"
    mkdir -p "$TMP_DIR"
    if [ "$retry_delay" -gt 0 ]; then
        sleep "$retry_delay"
    fi
done

# Publish a ready-to-execute asset so concurrent readers need no repair window.
if [ "$NEED_EXEC" -eq 1 ]; then
    chmod +x "$ASSET_TMP"
fi
mv "$ASSET_TMP" "$DEST"

if [ ! -s "$DEST" ]; then
    echo "stage0 compiler is empty after install: $DEST" >&2
    exit 1
fi
if [ "$NEED_EXEC" -eq 1 ] && [ ! -x "$DEST" ]; then
    echo "stage0 compiler is not executable after install: $DEST" >&2
    exit 1
fi

SYSROOT_DIR="$OUT_DIR/lib/$SYSROOT_TRIPLE"
if [ -n "$SYSROOT_TLI_TMP" ] && [ -n "$SYSROOT_LIB_TMP" ]; then
    mkdir -p "$SYSROOT_DIR"
    mv "$SYSROOT_TLI_TMP" "$SYSROOT_DIR/stdlib.tli"
    mv "$SYSROOT_LIB_TMP" "$SYSROOT_DIR/libstdlib.a"
    echo "[stage0] installed sysroot in $SYSROOT_DIR"
else
    rm -f "$SYSROOT_DIR/stdlib.tli" "$SYSROOT_DIR/libstdlib.a"
fi

echo "[stage0] installed $DEST"
