#!/usr/bin/env bash
set -euo pipefail

# Only archives cross runs. Resolution, hashes and install state come from this
# runner, never from the cache. apt still authenticates the download-only plan.
export LC_ALL=C
root=$PWD/target/ci-linux-tools
cache=$root/packages
[[ ! -L $PWD/target && ! -L $root ]] || { echo 'package work directory must not be a symlink' >&2; exit 1; }
mkdir -p "$root"

now() { date +%s%3N; }
timed() {
    local phase=$1 start status=0
    shift
    start=$(now)
    "$@" || status=$?
    printf '%s\t%s\t%s\n' "$phase" "$(($(now) - start))" "$status" | tee -a "$root/timing.tsv"
    return "$status"
}
apt_get() {
    sudo apt-get -o APT::Get::AllowUnauthenticated=false \
        -o Acquire::AllowInsecureRepositories=false \
        -o Acquire::AllowDowngradeToInsecureRepositories=false "$@"
}
resolve() {
    local package version
    : > "$root/versions.tsv"
    specs=()
    for package in valgrind libc6-dbg; do
        version=$(apt-cache policy "$package:$arch" | awk '$1 == "Candidate:" { print $2 }')
        [[ -n $version && $version != '(none)' ]] || return 1
        printf '%s\t%s\t%s\n' "$package" "$version" "$arch" >> "$root/versions.tsv"
        specs+=("$package:$arch=$version")
    done
    # Force a strong hash; print-uris alone does not authenticate. The later
    # download-only apt invocation authenticates this same pinned plan before
    # any package is installed, including when every archive is already local.
    (cd "$root" && apt-get -o Acquire::ForceHash=SHA256 --print-uris download "${specs[@]}") > "$root/uris.txt"
    awk '
        NF != 4 || $2 !~ /^[A-Za-z0-9_.+%:~=-]+[.]deb$/ ||
        $3 !~ /^[0-9]+$/ || $4 !~ /^SHA256:[a-f0-9]+$/ || length($4) != 71 { exit 1 }
        { print substr($4, 8) "  " $2; n++ }
        END { if (n != 2) exit 1 }
    ' "$root/uris.txt" > "$root/SHA256SUMS" || return 1
    cat "$root/versions.tsv" "$root/uris.txt"
    {
        cat /etc/os-release
        printf '%s\n' "$arch" "${RUNNER_OS:?}" "${ImageOS:?}" "${ImageVersion:?}"
        cat "$root/versions.tsv" "$root/SHA256SUMS"
    } > "$root/identity.txt"
    key=linux-instruction-tools-v1-$(sha256sum "$root/identity.txt" | cut -d ' ' -f 1)
}
load_specs() {
    local package version architecture
    specs=()
    while IFS=$'\t' read -r package version architecture; do
        specs+=("$package:$architecture=$version")
    done < "$root/versions.tsv"
}
verify() {
    local directory=$1 hash filename
    [[ -d $directory && ! -L $directory ]] || return 1
    while read -r hash filename; do
        [[ -f $directory/$filename && ! -L $directory/$filename ]] || return 1
    done < "$root/SHA256SUMS"
    (cd "$directory" && sha256sum --check "$root/SHA256SUMS")
}
acquire() {
    apt_get -y --no-install-recommends --reinstall --download-only \
        -o "Dir::Cache::archives=$archives" install "${specs[@]}"
}

case ${1:-} in
    prepare)
        printf 'phase\telapsed_ms\texit\n' > "$root/timing.tsv"
        arch=$(dpkg --print-architecture)
        if ! timed resolution resolve; then
            timed index-refresh apt_get -o APT::Update::Error-Mode=any update
            timed resolution resolve
        fi
        printf 'key=%s\n' "$key" >> "${GITHUB_OUTPUT:?}"
        ;;
    install)
        arch=$(dpkg --print-architecture)
        load_specs
        # Fresh private staging avoids feeding extra or invalid cached files to
        # apt. Runner teardown owns cleanup; no cached scripts/state are used.
        archives=$(mktemp -d "${RUNNER_TEMP:?}/typelisp-linux-tools.XXXXXX")
        if timed cache-verification verify "$cache"; then
            while read -r hash filename; do
                cp -- "$cache/$filename" "$archives/$filename"
            done < "$root/SHA256SUMS"
            echo '[linux-tools] verified cache hit'
            printf 'cache-state\tverified-hit\n' > "$root/result.tsv"
        else
            echo '[linux-tools] cache missing or invalid; using trusted apt download'
            printf 'cache-state\tmiss-or-invalid\n' > "$root/result.tsv"
        fi
        if ! timed package-transfer acquire; then
            # Preserve the old evidence and retry with the runner's normal
            # authenticated index refresh, just like the previous install.
            cp "$root/uris.txt" "$root/uris-before-refresh.txt"
            timed index-refresh apt_get -o APT::Update::Error-Mode=any update
            timed resolution resolve
            archives=$(mktemp -d "${RUNNER_TEMP:?}/typelisp-linux-tools.XXXXXX")
            timed package-transfer acquire
        fi
        # apt verified the trusted index and transfer; independently check all
        # reused bytes again before the no-network installation.
        timed archive-verification verify "$archives"
        timed installation apt_get -y --no-install-recommends --no-download \
            -o APT::Keep-Downloaded-Packages=true \
            -o "Dir::Cache::archives=$archives" install "${specs[@]}"
        while IFS=$'\t' read -r package version architecture; do
            installed=$(dpkg-query -W -f='${Version}' "$package:$architecture")
            [[ $installed == "$version" ]] || { echo "wrong installed version: $package $installed != $version" >&2; exit 1; }
            printf 'installed\t%s\t%s\t%s\n' "$package" "$installed" "$architecture"
        done < "$root/versions.tsv"
        valgrind --version
        # Publish only the two verified archives, after successful installation.
        # Cache service failures never supply an installation result.
        if [[ -e $cache || -L $cache ]]; then
            mv -- "$cache" "$root/packages-before-install-$(date +%s%N)"
        fi
        mkdir "$cache"
        while read -r hash filename; do
            cp -- "$archives/$filename" "$cache/$filename"
        done < "$root/SHA256SUMS"
        key=linux-instruction-tools-v1-$(sha256sum "$root/identity.txt" | cut -d ' ' -f 1)
        printf 'key=%s\n' "$key" >> "${GITHUB_OUTPUT:?}"
        ;;
    *) echo 'usage: scripts/ci-linux-tools.sh prepare|install' >&2; exit 2 ;;
esac
