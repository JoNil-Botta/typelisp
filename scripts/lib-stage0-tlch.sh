# Account catalog envelopes directly from the linked binary. Marker literals
# are ignored unless their bounded headers describe an envelope; a recognized
# index must then pass its complete structural and hash checks.
# Shares the single-pass scanner implementation in scripts/lib-stage0-lzss.sh.
# Output: envelopes, raw bytes, stream bytes, static bytes.
if ! command -v scan_stage0_payloads >/dev/null 2>&1; then
    . "${ROOT}/scripts/lib-stage0-lzss.sh"
fi

scan_stage0_tlch() {
    scan_stage0_payloads "$1" tlch
}
