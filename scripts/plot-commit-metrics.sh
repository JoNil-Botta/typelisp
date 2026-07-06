#!/usr/bin/env sh
set -eu

# scripts/plot-commit-metrics.sh - plot three per-commit metrics as one SVG.
#
# For every commit merged to main (each is exactly one merged PR that passed CI)
# this correlates three quantities and draws them as stacked time series:
#
#   1. stage0 linux binary size   - from the GitHub release artifact
#                                   (typelisp-stage0-linux), keyed by the merge
#                                   commit (bootstrap-stage0.yml runs on push).
#   2. self_compile/compile_cli_opt1 instruction count
#                                 - the committed cachegrind baseline value read
#                                   from perf/insn-exec-baseline.tsv at each commit.
#   3. PR CI wall-clock time      - duration of the ci.yml run (ci.yml runs on
#                                   pull_request, so it is keyed by the PR head
#                                   commit, joined back via the merge commit).
#
# The three sources are joined per commit through the merged PR:
#   release.target_commitish == pr.mergeCommit.oid   (binary size, insn)
#   ci_run.head_sha          == pr.headRefOid         (CI time)
# Only commits that have all three are plotted.
#
# By default the whole available history is scanned; the limit flags cap the
# scan for a faster/cheaper run.
#
# Requires: gh (authenticated), git, jq, awk. Reads the network; writes one SVG
# and a companion .tsv. Nothing in the repo is modified.

usage() {
  cat <<'EOF'
usage: scripts/plot-commit-metrics.sh [options]

  -o FILE          output SVG path (default: target/commit-metrics.svg)
                   a companion <FILE>.tsv with the joined data is also written.
  --pr-limit N     merged PRs to scan       (default: all available)
  --run-limit N    ci.yml runs to scan      (default: all available)
  --release-pages N release API pages (x100) (default: all available)
  --ma-window N    centered window (commits) for the CI-time moving average (default: 21)
  --no-fetch       do not run `git fetch origin main` first
  -h, --help       show this help

The limits default to scanning everything available so the plot covers the full
history; pass a positive value to any of them to cap that scan. The release
pager stops on its own at the first empty page, so --release-pages is only a
ceiling.

The script needs the merge commits present locally to read the baseline value,
so it runs `git fetch origin main` by default (updates only the remote-tracking
ref, never the working tree). Pass --no-fetch if commits are already present.
EOF
}

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

# 0 means "scan everything available" (the default); a positive value caps the
# scan. gh has no "all" switch, so an uncapped PR/run scan is expressed as a
# ceiling above any realistic history size.
ALL_CEIL=1000000
OUT=target/commit-metrics.svg
PR_LIMIT=0
RUN_LIMIT=0
REL_PAGES=0
MA_WINDOW=21
FETCH=1

while [ $# -gt 0 ]; do
  case "$1" in
    -o) OUT=$2; shift 2 ;;
    --pr-limit) PR_LIMIT=$2; shift 2 ;;
    --run-limit) RUN_LIMIT=$2; shift 2 ;;
    --release-pages) REL_PAGES=$2; shift 2 ;;
    --ma-window) MA_WINDOW=$2; shift 2 ;;
    --no-fetch) FETCH=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

for tool in gh git jq awk; do
  command -v "$tool" >/dev/null 2>&1 || { echo "error: '$tool' not found in PATH" >&2; exit 1; }
done

REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
TAB=$(printf '\t')

log() { echo "[plot-commit-metrics] $*" >&2; }

# Resolve the "0 = all" sentinels to the concrete values used for scanning.
pr_scan=$PR_LIMIT;   [ "$pr_scan" -eq 0 ]  && pr_scan=$ALL_CEIL
run_scan=$RUN_LIMIT; [ "$run_scan" -eq 0 ] && run_scan=$ALL_CEIL
rel_scan=$REL_PAGES; [ "$rel_scan" -eq 0 ] && rel_scan=$ALL_CEIL
pr_desc=$([ "$PR_LIMIT" -eq 0 ] && echo "all available" || echo "$PR_LIMIT")
run_desc=$([ "$RUN_LIMIT" -eq 0 ] && echo "all available" || echo "$RUN_LIMIT")
rel_desc=$([ "$REL_PAGES" -eq 0 ] && echo "all available" || echo "$REL_PAGES page(s)")

if [ "$FETCH" -eq 1 ]; then
  log "fetching origin main (so merge commits are readable) ..."
  git fetch origin main --quiet
fi

# --- 1. merged PRs: head sha (CI key) + merge sha (release/insn key) -----------
log "fetching $pr_desc merged PRs ..."
gh pr list --state merged --limit "$pr_scan" \
  --json number,headRefOid,mergeCommit \
  -q '.[] | select(.mergeCommit.oid != null) | [.headRefOid, .mergeCommit.oid] | @tsv' \
  > "$WORK/pr.tsv"
log "  merged PRs with a merge commit: $(wc -l < "$WORK/pr.tsv" | tr -d ' ')"

# --- 2. ci.yml runs: best (longest) successful wall-clock per head sha ---------
log "fetching $run_desc ci.yml runs ..."
gh run list --workflow ci.yml --limit "$run_scan" \
  --json headSha,conclusion,startedAt,updatedAt \
  -q '.[] | select(.conclusion=="success") | [.headSha,.startedAt,.updatedAt] | @tsv' \
  | awk -F'\t' '
      function ep(s,  Y,Mo,D,H,Mi,S,y,era,yoe,doy,doe,days) {
        Y=substr(s,1,4); Mo=substr(s,6,2); D=substr(s,9,2);
        H=substr(s,12,2); Mi=substr(s,15,2); S=substr(s,18,2);
        y=Y-(Mo<=2); era=int((y>=0?y:y-399)/400); yoe=y-era*400;
        doy=int((153*(Mo+(Mo>2?-3:9))+2)/5)+D-1;
        doe=yoe*365+int(yoe/4)-int(yoe/100)+doy;
        days=era*146097+doe-719468;
        return days*86400+H*3600+Mi*60+S;
      }
      { d=ep($3)-ep($2); if (d>=0 && d>best[$1]) best[$1]=d }
      END { for (k in best) printf "%s\t%d\n", k, best[k] }' \
  > "$WORK/ci_best.tsv"
log "  head commits with a successful CI duration: $(wc -l < "$WORK/ci_best.tsv" | tr -d ' ')"

# --- 3. releases: merge commit -> linux binary size ---------------------------
log "fetching release artifact sizes ($rel_desc) ..."
: > "$WORK/rel.tsv"
page=1
while [ "$page" -le "$rel_scan" ]; do
  n=$(gh api "repos/$REPO/releases?per_page=100&page=$page" \
        -q '.[] | [.target_commitish, (([.assets[]|select(.name=="typelisp-stage0-linux")|.size]|first)//"")] | @tsv' \
        2>/dev/null | tee -a "$WORK/rel.tsv" | wc -l | tr -d ' ')
  [ "$n" -eq 0 ] && break
  page=$((page+1))
done
log "  release rows: $(wc -l < "$WORK/rel.tsv" | tr -d ' ')"

# --- 4. join: PR head -> CI time, PR merge -> size, then add git date + insn ---
# merge_dur.tsv : mergeSha  ci_seconds   (only commits whose CI run we have)
awk -F'\t' 'FNR==NR{dur[$1]=$2;next} ($1 in dur){print $2"\t"dur[$1]}' \
  "$WORK/ci_best.tsv" "$WORK/pr.tsv" > "$WORK/merge_dur.tsv"
# merge_dur_sz.tsv : mergeSha  ci_seconds  size   (only commits with a release)
awk -F'\t' 'FNR==NR{ if($2!="" && !($1 in sz)) sz[$1]=$2; next }
            ($1 in sz){ print $1"\t"$2"\t"sz[$1] }' \
  "$WORK/rel.tsv" "$WORK/merge_dur.tsv" > "$WORK/merge_dur_sz.tsv"

# Add committer date + the baseline instruction count read at each commit.
: > "$WORK/rows.tsv"
have_insn=0; no_insn=0; no_commit=0
while IFS="$TAB" read -r msha dur sz; do
  if ! cdate=$(git show -s --format=%ct "$msha" 2>/dev/null); then
    no_commit=$((no_commit+1)); continue
  fi
  insn=$(git show "$msha:perf/insn-exec-baseline.tsv" 2>/dev/null \
         | awk -F'\t' '$1=="self_compile/compile_cli_opt1"{print $2; exit}')
  if [ -z "$insn" ]; then no_insn=$((no_insn+1)); continue; fi
  have_insn=$((have_insn+1))
  printf '%s\t%s\t%s\t%s\t%s\n' \
    "$cdate" "$sz" "$insn" "$dur" "$(printf '%.10s' "$msha")" >> "$WORK/rows.tsv"
done < "$WORK/merge_dur_sz.tsv"

sort -n "$WORK/rows.tsv" > "$WORK/joined.tsv"
N=$(wc -l < "$WORK/joined.tsv" | tr -d ' ')
log "join funnel: CI+size candidates=$(wc -l < "$WORK/merge_dur_sz.tsv" | tr -d ' ')" \
    "-> with insn=$have_insn (missing insn=$no_insn, commit not local=$no_commit)"
if [ "$N" -eq 0 ]; then
  echo "error: no commits had all three metrics; widen --pr-limit/--run-limit/--release-pages or drop --no-fetch" >&2
  exit 1
fi
log "commits with all three metrics: $N"

# Companion data file.
mkdir -p "$(dirname "$OUT")"
TSV_OUT="${OUT%.svg}.tsv"
{ printf 'commit_unixtime\tbinary_size_bytes\tinsn_count\tci_seconds\tcommit\n'; cat "$WORK/joined.tsv"; } > "$TSV_OUT"

# --- 5. render SVG ------------------------------------------------------------
cat > "$WORK/svg.awk" <<'SVGAWK'
function ep_ymd(e,  days,z,era,doe,yoe,y,doy,mp,d,m) {
  days=int(e/86400); z=days+719468;
  era=int((z>=0?z:z-146096)/146097);
  doe=z-era*146097;
  yoe=int((doe-int(doe/1460)+int(doe/36524)-int(doe/146096))/365);
  y=yoe+era*400;
  doy=doe-(365*yoe+int(yoe/4)-int(yoe/100));
  mp=int((5*doy+2)/153);
  d=doy-int((153*mp+2)/5)+1;
  m=mp+(mp<10?3:-9);
  y=y+(m<=2);
  return sprintf("%04d-%02d-%02d", y, m, d);
}
function hms(e,  s,H,Mi) { s=e%86400; H=int(s/3600); Mi=int((s%3600)/60); return sprintf("%02d:%02d",H,Mi) }
function fmtv(p,v,  s) {
  if (p==0) return sprintf("%.2f MiB", v/1048576);
  if (p==1) return sprintf("%.2f G", v/1000000000);
  s=int(v+0.5); return sprintf("%dm%02ds", int(s/60), s%60);
}
function xof(e) { if (dmax==dmin) return (plotLeft+plotRight)/2; return plotLeft+plotW*(e-dmin)/(dmax-dmin) }
function yof(p,v) { if (hiv[p]==lov[p]) return (plotTop+plotBot)/2; return plotBot-plotH*(v-lov[p])/(hiv[p]-lov[p]) }
{ i=++N; dt[i]=$1+0; m[0,i]=$2+0; m[1,i]=$3+0; m[2,i]=$4+0; sh[i]=$5 }
END {
  # One shared plot box: shared x (time) and shared horizontal gridlines, three
  # series each normalised to its own min/max so they overlap. insn count gets
  # its own RED axis on the left; binary size (blue) and CI time (green) share a
  # single right axis, their tick numbers interleaved (every other row, in the
  # matching colour) so the two scales cost one column instead of two. A rolling
  # average of the CI time is overlaid on the CI (green) scale.
  if (MAWIN+0 < 1) MAWIN=21;
  W=1200; ML=150;
  plotLeft=ML; plotRight=W-110; plotW=plotRight-plotLeft;
  plotTop=116; plotH=384; plotBot=plotTop+plotH;
  H=plotBot+96;

  dmin=dt[1]; dmax=dt[1];
  for (p=0;p<3;p++){ mn[p]=1e308; mx[p]=-1e308 }
  for (i=1;i<=N;i++){
    if (dt[i]<dmin) dmin=dt[i]; if (dt[i]>dmax) dmax=dt[i];
    for (p=0;p<3;p++){ if (m[p,i]<mn[p]) mn[p]=m[p,i]; if (m[p,i]>mx[p]) mx[p]=m[p,i] }
  }
  for (p=0;p<3;p++){ r=mx[p]-mn[p]; if (r==0) r=(mx[p]==0?1:mx[p]*0.1); lov[p]=mn[p]-0.08*r; hiv[p]=mx[p]+0.08*r }

  # centered moving average of the CI time series (metric 2)
  h=int(MAWIN/2);
  for (i=1;i<=N;i++){
    s=0; c=0; lo=i-h; if (lo<1) lo=1; hi=i+h; if (hi>N) hi=N;
    for (j=lo;j<=hi;j++){ s+=m[2,j]; c++ }
    ma[i]=s/c;
  }

  col[0]="#1f77b4"; col[1]="#d62728"; col[2]="#2ca02c"; macol="#0a5f2a";

  printf("<svg xmlns='http://www.w3.org/2000/svg' width='%d' height='%d' font-family='monospace' font-size='12'>\n", W, H);
  printf("<rect width='100%%' height='100%%' fill='white'/>\n");
  printf("<text x='%d' y='30' font-size='18' font-weight='bold'>typelisp commit metrics &#8212; %d commits, shared timeline</text>\n", ML, N);
  printf("<text x='%d' y='50' fill='#666'>x = merge-commit date &#183; each point = one merged PR that passed CI &#183; %s to %s</text>\n", ML, ep_ymd(dmin), ep_ymd(dmax));

  # legend (2 rows x 2)
  lgx[0]=ML;     lgy[0]=74; lgc[0]=col[1]; lgt[0]="insn count (G) - left axis";
  lgx[1]=ML+372; lgy[1]=74; lgc[1]=col[0]; lgt[1]="binary size (MiB) - right axis";
  lgx[2]=ML;     lgy[2]=92; lgc[2]=col[2]; lgt[2]="PR CI time (m:ss) - right axis";
  lgx[3]=ML+372; lgy[3]=92; lgc[3]=macol;  lgt[3]=sprintf("CI time moving avg (w=%d)", MAWIN);
  for (e=0;e<4;e++){
    printf("<rect x='%d' y='%d' width='22' height='10' fill='%s'/>\n", lgx[e], lgy[e]-9, lgc[e]);
    printf("<text x='%d' y='%d' fill='%s' font-weight='bold'>%s</text>\n", lgx[e]+28, lgy[e], lgc[e], lgt[e]);
  }

  # plot frame
  printf("<rect x='%d' y='%d' width='%d' height='%d' fill='#fafafa' stroke='#cccccc'/>\n", plotLeft, plotTop, plotW, plotH);

  GL=6;
  # shared horizontal gridlines
  for (g=0;g<=GL;g++){ f=g/GL; yy=plotBot-plotH*f;
    printf("<line x1='%d' y1='%.1f' x2='%d' y2='%.1f' stroke='#e8e8e8'/>\n", plotLeft, yy, plotRight, yy) }
  # vertical date gridlines + shared x labels
  K=6;
  for (k=0;k<=K;k++){ tv=dmin+(dmax-dmin)*k/K; xx=xof(tv);
    printf("<line x1='%.1f' y1='%d' x2='%.1f' y2='%d' stroke='#efefef'/>\n", xx, plotTop, xx, plotBot);
    printf("<text x='%.1f' y='%d' text-anchor='middle' fill='#555555'>%s</text>\n", xx, plotBot+18, ep_ymd(tv));
    printf("<text x='%.1f' y='%d' text-anchor='middle' fill='#999999'>%s</text>\n", xx, plotBot+32, hms(tv)) }

  # LEFT axis: insn count (metric 1), red, every row labelled
  printf("<line x1='%d' y1='%d' x2='%d' y2='%d' stroke='%s' stroke-width='1.4'/>\n", plotLeft, plotTop, plotLeft, plotBot, col[1]);
  for (g=0;g<=GL;g++){ f=g/GL; yy=plotBot-plotH*f; val=lov[1]+(hiv[1]-lov[1])*f;
    printf("<line x1='%d' y1='%.1f' x2='%d' y2='%.1f' stroke='%s'/>\n", plotLeft-5, yy, plotLeft, yy, col[1]);
    printf("<text x='%d' y='%.1f' text-anchor='end' fill='%s'>%s</text>\n", plotLeft-8, yy+4, col[1], fmtv(1,val)) }

  # RIGHT axis: shared by binary size (metric 0, blue) and CI time (metric 2, green),
  # tick numbers interleaved by row - even rows blue, odd rows green
  printf("<line x1='%d' y1='%d' x2='%d' y2='%d' stroke='#aaaaaa' stroke-width='1.4'/>\n", plotRight, plotTop, plotRight, plotBot);
  for (g=0;g<=GL;g++){ f=g/GL; yy=plotBot-plotH*f;
    mp=(g%2==0)?0:2; val=lov[mp]+(hiv[mp]-lov[mp])*f;
    printf("<line x1='%d' y1='%.1f' x2='%d' y2='%.1f' stroke='%s'/>\n", plotRight, yy, plotRight+5, yy, col[mp]);
    printf("<text x='%d' y='%.1f' text-anchor='start' fill='%s'>%s</text>\n", plotRight+8, yy+4, col[mp], fmtv(mp,val)) }

  # raw series (CI drawn lighter so the moving average reads on top)
  for (p=0;p<3;p++){
    pts=""; sw=(p==2)?1.1:1.7; op=(p==2)?0.5:1.0;
    for (i=1;i<=N;i++){ pts=pts sprintf("%s%.1f,%.1f", (i==1?"":" "), xof(dt[i]), yof(p,m[p,i])) }
    printf("<polyline points='%s' fill='none' stroke='%s' stroke-width='%.1f' stroke-opacity='%.2f'/>\n", pts, col[p], sw, op);
    for (i=1;i<=N;i++){ printf("<circle cx='%.1f' cy='%.1f' r='1.7' fill='%s' fill-opacity='%.2f'/>\n", xof(dt[i]), yof(p,m[p,i]), col[p], op) }
  }
  # CI moving-average line, on the CI (green) scale
  pts="";
  for (i=1;i<=N;i++){ pts=pts sprintf("%s%.1f,%.1f", (i==1?"":" "), xof(dt[i]), yof(2,ma[i])) }
  printf("<polyline points='%s' fill='none' stroke='%s' stroke-width='2.6'/>\n", pts, macol);

  printf("</svg>\n");
}
SVGAWK

awk -v MAWIN="$MA_WINDOW" -f "$WORK/svg.awk" "$WORK/joined.tsv" > "$OUT"

log "wrote $OUT"
log "wrote $TSV_OUT"
echo "$OUT"
