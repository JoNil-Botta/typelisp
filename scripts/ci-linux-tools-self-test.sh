#!/usr/bin/env bash
set -euo pipefail

# Exercise the shared installer without apt, sudo, downloads or host changes.
script=$PWD/scripts/ci-linux-tools.sh
mkdir -p target/exp
scratch=$(mktemp -d "$PWD/target/exp/linux-tools-test.XXXXXX")
case "$scratch" in
    "$PWD/target/exp/linux-tools-test."??????) ;;
    *) echo "unexpected package fixture scratch directory: $scratch" >&2; exit 1 ;;
esac
# Successful fixtures contain symlinks; remove them before clean --experiments
# inspects target/exp. Retain failed fixtures for diagnosis.
trap 'if [ "$?" -eq 0 ]; then rm -rf -- "${scratch:?}"; fi' EXIT
mkdir "$scratch/bin" "$scratch/trusted"
printf 'trusted valgrind\n' > "$scratch/trusted/valgrind.deb"
printf 'trusted debug symbols\n' > "$scratch/trusted/libc6-dbg.deb"
cat > "$scratch/bin/tool" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
tool=${0##*/}
version=${TOOLS_TEST_VERSION:-1}
if [[ -f $TOOLS_TEST_ROOT/refreshed ]]; then version=2; fi
printf '%s %s\n' "$tool" "$*" >> "$TOOLS_TEST_ROOT/calls"
case "$tool" in
    sudo) exec "$@" ;;
    dpkg) echo amd64 ;;
    apt-cache) printf '  Candidate: %s\n' "$version" ;;
    dpkg-query)
        [[ -f $TOOLS_TEST_ROOT/installed ]]
        echo "${TOOLS_TEST_INSTALLED_VERSION:-$version}"
        ;;
    valgrind)
        [[ -f $TOOLS_TEST_ROOT/installed ]]
        [[ ${TOOLS_TEST_BAD_TOOL:-no} != yes ]] || exit 19
        echo valgrind-3.22.0
        ;;
    apt-get)
        if [[ " $* " == *' --print-uris '* ]]; then
            for package in valgrind libc6-dbg; do
                hash=$(sha256sum "$TOOLS_TEST_TRUSTED/$package.deb" | cut -d ' ' -f 1)
                printf "'https://trusted.invalid/%s.deb' %s_%s_amd64.deb 99 SHA256:%s\n" \
                    "$package" "$package" "$version" "$hash"
            done
        elif [[ " $* " == *' update '* ]]; then
            [[ ${TOOLS_TEST_FAIL:-} != acquisition ]]
            : > "$TOOLS_TEST_ROOT/refreshed"
        else
            archives=
            for arg in "$@"; do
                case "$arg" in Dir::Cache::archives=*) archives=${arg#*=} ;; esac
            done
            [[ -n $archives ]]
            [[ " $* " == *" valgrind:amd64=$version "* ]]
            [[ " $* " == *" libc6-dbg:amd64=$version "* ]]
            [[ " $* " == *' APT::Get::AllowUnauthenticated=false '* ]]
            [[ " $* " == *' Acquire::AllowInsecureRepositories=false '* ]]
            [[ " $* " == *' Acquire::AllowDowngradeToInsecureRepositories=false '* ]]
            if [[ " $* " == *' --download-only '* ]]; then
                [[ ${TOOLS_TEST_FAIL:-} != acquisition ]] || exit 17
                if [[ ${TOOLS_TEST_FAIL:-} == stale-index && ! -f $TOOLS_TEST_ROOT/refreshed ]]; then exit 17; fi
                for package in valgrind libc6-dbg; do
                    dest=$archives/${package}_${version}_amd64.deb
                    if [[ -e $dest ]]; then
                        cmp "$TOOLS_TEST_TRUSTED/$package.deb" "$dest"
                    else
                        echo transfer >> "$TOOLS_TEST_ROOT/transfers"
                        cp "$TOOLS_TEST_TRUSTED/$package.deb" "$dest"
                    fi
                done
                if [[ ${TOOLS_TEST_CORRUPT_TRANSFER:-no} == yes ]]; then
                    echo corrupt > "$archives/valgrind_${version}_amd64.deb"
                fi
            else
                [[ " $* " == *' --no-download '* ]]
                [[ ${TOOLS_TEST_FAIL:-} != installation ]] || exit 18
                for package in valgrind libc6-dbg; do
                    cmp "$TOOLS_TEST_TRUSTED/$package.deb" "$archives/${package}_${version}_amd64.deb"
                done
                : > "$TOOLS_TEST_ROOT/installed"
            fi
        fi
        ;;
    *) exit 99 ;;
esac
EOF
chmod +x "$scratch/bin/tool"
for tool in sudo apt-get apt-cache dpkg dpkg-query valgrind; do
    ln -s tool "$scratch/bin/$tool"
done
export PATH="$scratch/bin:$PATH" TOOLS_TEST_TRUSTED="$scratch/trusted"
export RUNNER_OS=Linux ImageOS=ubuntu24 ImageVersion=test-image

run_case() (
    local name=$1 seed=$2 expected=$3 status=0
    shift 3
    export TOOLS_TEST_ROOT="$scratch/$name"
    mkdir -p "$TOOLS_TEST_ROOT/runner-temp"
    cd "$TOOLS_TEST_ROOT"
    export RUNNER_TEMP="$TOOLS_TEST_ROOT/runner-temp" GITHUB_OUTPUT="$TOOLS_TEST_ROOT/output"
    bash "$script" prepare > prepare.log 2>&1
    case "$seed" in
        hit | corrupt | stale | missing | symlink)
            mkdir target/ci-linux-tools/packages
            for package in valgrind libc6-dbg; do
                cp "$TOOLS_TEST_TRUSTED/$package.deb" "target/ci-linux-tools/packages/${package}_1_amd64.deb"
            done
            if [[ $seed == corrupt ]]; then
                echo corrupt > target/ci-linux-tools/packages/valgrind_1_amd64.deb
            elif [[ $seed == stale ]]; then
                echo stale > target/ci-linux-tools/packages/valgrind_1_amd64.deb
                echo stale > target/ci-linux-tools/packages/libc6-dbg_1_amd64.deb
            elif [[ $seed == missing || $seed == symlink ]]; then
                mv target/ci-linux-tools/packages/libc6-dbg_1_amd64.deb missing-archive
                if [[ $seed == symlink ]]; then
                    ln -s "$TOOLS_TEST_TRUSTED/libc6-dbg.deb" target/ci-linux-tools/packages/libc6-dbg_1_amd64.deb
                fi
            fi
            ;;
    esac
    env "$@" bash "$script" install > install.log 2>&1 || status=$?
    if [[ $expected == success ]]; then
        [[ $status == 0 ]]
        [[ -f installed ]]
        [[ $(wc -l < output) == 2 ]]
        if [[ $seed == hit ]]; then
            [[ ! -f transfers ]]
            grep -q 'verified-hit' target/ci-linux-tools/result.tsv
        else
            [[ $(wc -l < transfers) == 2 ]]
            grep -q 'miss-or-invalid' target/ci-linux-tools/result.tsv
        fi
        if [[ $name == stale-index ]]; then
            [[ -f refreshed ]]
            [[ $(sort -u output | wc -l) == 2 ]]
            grep -q $'libc6-dbg\t2\tamd64' target/ci-linux-tools/versions.tsv
        fi
    else
        [[ $status != 0 ]]
        [[ $(wc -l < output) == 1 ]]
        [[ ! -d target/ci-linux-tools/packages || $seed != miss ]]
    fi
    printf '[linux-tools self-test] %s passed\n' "$name"
)

run_case hit hit success
run_case miss miss success
run_case stale stale success
run_case corrupt corrupt success
run_case missing missing success
run_case symlink symlink success
run_case stale-index miss success TOOLS_TEST_FAIL=stale-index
run_case acquisition miss failure TOOLS_TEST_FAIL=acquisition
run_case installation miss failure TOOLS_TEST_FAIL=installation
run_case version-mismatch miss failure TOOLS_TEST_INSTALLED_VERSION=wrong
run_case unusable-tool miss failure TOOLS_TEST_BAD_TOOL=yes
run_case archive-authentication miss failure TOOLS_TEST_CORRUPT_TRANSFER=yes

# Neither the image nor the exact resolved version can share a key.
key=$(sed -n 's/^key=//p' "$scratch/hit/output" | head -1)
for change in image version; do
    (
        export TOOLS_TEST_ROOT="$scratch/key-$change"
        mkdir "$TOOLS_TEST_ROOT"
        cd "$TOOLS_TEST_ROOT"
        export GITHUB_OUTPUT="$TOOLS_TEST_ROOT/output"
        if [[ $change == image ]]; then export ImageVersion=other-image
        else export TOOLS_TEST_VERSION=2; fi
        bash "$script" prepare > prepare.log 2>&1
        [[ $(sed -n 's/^key=//p' output) != "$key" ]]
    )
done
echo '[linux-tools self-test] image and version invalidation passed'
