;; format_cli_core.tl - Self-hosted `fmt` command logic.
;;
;; The formatter CLI logic, factored out of `format.tl` so both the retained
;; formatter compatibility/coverage driver and the unified `cli.tl` dispatcher
;; can run the `fmt` command without duplicating a `main`.
(import compiler_owned_view as owned_view)
(import stdlib.str_cat_runtime as str_cat)
(import stdlib.byte_buf)
(import stdlib.io)
(import stdlib.string)
(import stdlib.vector)
(import (vector.vector String) as fmt_svec)
(import cli_option_core as cli_option)
(import compiler_target_cfg_core as target_cfg)
(import format_tokens as tokens)
(import format_rules)
(import format_render_buf as fmt_buf)
(import package_source_core)

(defenum FmtConfig
  (File bool fmt_svec.Vec)
  (Package bool String bool))

(defenum ResultFmtConfig
  (Ok FmtConfig)
  (Err String))

(defenum ResultFmtWrite
  (Ok)
  (Err String))

(define fmt-cli-has-target : bool
  false)

(define (fmt-write-error-message [path : String] [error : io.IoError]) : String
  (str_cat.str-cat "fmt: failed to write " path ": " (io.error-message error)))

(define (fmt-try-write-formatted-file [path : String] [formatted : String]) : ResultFmtWrite
  (match (io.try-write-file (& path) (byte_buf.str-as-bytes (& formatted)))
    [(io.OkIoUnit) ResultFmtWrite.Ok]
    [(io.ErrIoUnit error)
      (ResultFmtWrite.Err (fmt-write-error-message path error))]))

(define (fmt-write-formatted-file [path : String] [formatted : String]) : i64
  (match (fmt-try-write-formatted-file path formatted)
    [(ResultFmtWrite.Ok) 0]
    [(ResultFmtWrite.Err message)
      (begin
        (io.print-error (str_cat.str-cat message "\n"))
        1)]))

(define (fmt-source-error-message
  [path : String]
  [err : tokens.FormatSourceError]) : String
  (let
    [span : tokens.FormatSourceSpan
      (tokens.format-source-error-span
        (owned_view.compiler-owned-shared-view err))]
    (str_cat.str-cat
      path
      ":"
      (string.int->string (tokens.format-source-span-start-line span))
      ":"
      (string.int->string (tokens.format-source-span-start-col span))
      ": "
      (tokens.format-source-error-message err))))

(test
  fmt-write-failure-diagnostic-includes-path-and-reason
  (match (fmt-try-write-formatted-file "" "(define x 1)\n")
    [(ResultFmtWrite.Ok) (io.panic "fmt write unexpectedly succeeded")]
    [(ResultFmtWrite.Err message)
      (if (string.eq message "fmt: failed to write : io: invalid path: ")
        unit
        (io.panic (string.copy message)))]))

(test
  fmt-parse-diagnostic-includes-path-line-and-column
  (match (format_rules.format-rules-render-source-width-result
    "(define x\n  ]"
    80)
    [(format_rules.ResultFormatString.Ok _)
      (io.panic "fmt parse unexpectedly succeeded")]
    [(format_rules.ResultFormatString.Err err)
      (let
        [message : String (fmt-source-error-message "bad.tl" err)]
        (if (string.eq
          message
          "bad.tl:2:3: format cst: unexpected closing delimiter")
          unit
          (io.panic message)))]))

(define (fmt-malformed-int-error? [source : String]) : bool
  (match (format_rules.format-rules-render-source-width-result source 80)
    [(format_rules.ResultFormatString.Ok _) false]
    [(format_rules.ResultFormatString.Err err)
      (string.eq
        (tokens.format-source-error-message err)
        "format lexer: malformed integer literal")]))

(test
  fmt-number-literal-diagnostics-preserved
  (if (and
    (fmt-malformed-int-error? "(define x 0x)")
    (fmt-malformed-int-error? "(define x 0xg)")
    (fmt-malformed-int-error? "(define x 0b)")
    (fmt-malformed-int-error? "(define x 0b2)"))
    unit
    (io.panic "fmt number literal diagnostics changed")))

(test
  fmt-check-diff-renders-a-unified-hunk
  (let
    [diff : String
      (fmt-unified-diff "t.tl" "(a)\n(b   c)\n(d)\n" "(a)\n(b c)\n(d)\n")]
    (if (string.eq
      diff
      "--- a/t.tl\n+++ b/t.tl\n@@ -1,4 +1,4 @@\n (a)\n-(b   c)\n+(b c)\n (d)\n \n")
      unit
      (io.panic (string.copy diff)))))

;; A file that is already formatted must not reach the diff path at all, but the
;; renderer still has to be total: with no differing lines the prefix consumes
;; everything and both `-` and `+` runs are empty.
(test
  fmt-check-diff-of-identical-text-has-no-changed-lines
  (let
    [diff : String (fmt-unified-diff "t.tl" "(a)\n(b)\n" "(a)\n(b)\n")]
    (if (and
      (not (string.contains (& diff) "-("))
      (not (string.contains (& diff) "+(")))
      unit
      (io.panic (string.copy diff)))))

(test
  fmt-check-diff-splits-distant-changes-into-separate-hunks
  (let
    [diff : String
      (fmt-unified-diff
        "t.tl"
        "(a)\n(b   c)\n(c)\n(d)\n(e)\n(f)\n(g)\n(h)\n(i)\n(j   k)\n(l)\n(m)\n(n)\n"
        "(a)\n(b c)\n(c)\n(d)\n(e)\n(f)\n(g)\n(h)\n(i)\n(j k)\n(l)\n(m)\n(n)\n")]
    (if (string.eq
      diff
      "--- a/t.tl\n+++ b/t.tl\n@@ -1,5 +1,5 @@\n (a)\n-(b   c)\n+(b c)\n (c)\n (d)\n (e)\n@@ -7,8 +7,8 @@\n (g)\n (h)\n (i)\n-(j   k)\n+(j k)\n (l)\n (m)\n (n)\n \n")
      unit
      (io.panic (string.copy diff)))))

(test
  fmt-check-diff-resynchronizes-after-an-inserted-line
  (let
    [diff : String
      (fmt-unified-diff
        "t.tl"
        "(a)\n(b)\n(c)\n(d)\n(e)\n"
        "(a)\n(b)\n(inserted)\n(c)\n(d)\n(e)\n")]
    (if (and
      (string.contains (& diff) "+(inserted)\n")
      (not (string.contains (& diff) "-(c)\n"))
      (not (string.contains (& diff) "+(c)\n")))
      unit
      (io.panic (string.copy diff)))))

(define (fmt-flag? [value : String]) : bool
  (and (> (string.string-length value) 0) (= (string.string-ref value 0) '-')))

(define (fmt-config-finish
  [check : bool]
  [paths : fmt_svec.Vec]
  [manifest-path : String]
  [has-manifest : bool]) : ResultFmtConfig
  (if (fmt_svec.is-empty? (& paths))
    (ResultFmtConfig.Ok (FmtConfig.Package check manifest-path has-manifest))
    (if has-manifest
      (ResultFmtConfig.Err
        "fmt: cannot combine input paths with --manifest-path")
      (ResultFmtConfig.Ok (FmtConfig.File check paths)))))

(define (fmt-parse-args
  [idx : i64]
  [count : i64]
  [check : bool]
  [paths : fmt_svec.Vec]
  [manifest-path : String]
  [has-manifest : bool]) : ResultFmtConfig
  (if (>= idx count)
    (fmt-config-finish check paths manifest-path has-manifest)
    (let
      [current : String (io.arg idx)]
      (match (cli_option.cli-common-option-parse
        (owned_view.compiler-owned-shared-view current)
        idx
        count
        (bit-or
          cli_option.cli-common-option-stdlib-root
          (bit-or
            cli_option.cli-common-option-cfg
            cli_option.cli-common-option-target)))
        [(cli_option.CliCommonOption.Missing kind)
          (ResultFmtConfig.Err
            (cli_option.cli-common-option-missing-message "fmt" kind))]
        [(cli_option.CliCommonOption.Value kind value next-idx)
          (match kind
            [(cli_option.CliCommonOptionKind.Target)
              (if fmt-cli-has-target
                (ResultFmtConfig.Err
                  "fmt: --target was provided more than once")
                (match (target_cfg.compiler-target-cfg-parse value)
                  [(target_cfg.ResultCompilerTargetCfg.Ok _)
                    (begin
                      (set! fmt-cli-has-target true)
                      (fmt-parse-args
                        next-idx
                        count
                        check
                        paths
                        manifest-path
                        has-manifest))]
                  [(target_cfg.ResultCompilerTargetCfg.Err message)
                    (ResultFmtConfig.Err (str_cat.str-cat "fmt: " message))]))]
            [_
              ;; Formatting is CST-based and intentionally retains every cfg
              ;; branch; these options are accepted for source-tool CLI parity.
              (fmt-parse-args
                next-idx
                count
                check
                paths
                manifest-path
                has-manifest)])]
        [(cli_option.CliCommonOption.NotCommon)
          (cond
            [(string.eq current "--check")
              (fmt-parse-args
                (+ idx 1)
                count
                true
                paths
                manifest-path
                has-manifest)]
            [(string.eq current "--manifest-path")
              (if (>= (+ idx 1) count)
                (ResultFmtConfig.Err "fmt: --manifest-path requires a value")
                (if has-manifest
                  (ResultFmtConfig.Err "fmt: duplicate --manifest-path")
                  (fmt-parse-args
                    (+ idx 2)
                    count
                    check
                    paths
                    (io.arg (+ idx 1))
                    true)))]
            [(fmt-flag? (owned_view.compiler-owned-shared-view current))
              (ResultFmtConfig.Err
                (str_cat.str-cat "fmt: unknown flag " current))]
            [else
              (let
                [out : fmt_svec.Vec
                  (owned_view.compiler-owned-shared-view paths)]
                (begin
                  (fmt_svec.push-ref! (&mut out) current)
                  (fmt-parse-args
                    (+ idx 1)
                    count
                    check
                    out
                    manifest-path
                    has-manifest)))])]))))

(define (fmt-config-from [start : i64] [count : i64]) : ResultFmtConfig
  (begin
    (set! fmt-cli-has-target false)
    (fmt-parse-args start count false (fmt_svec.new) "" false)))

;; --- unified diff for --check -----------------------------------------------
;;
;; #5671: `--check` named the file but not what was wrong with it, so a failing
;; CI log made the contributor reproduce the formatting locally to see it. The
;; formatted text is already in memory at the point of the report, so rendering
;; the diff needs no extra formatting work.
;;
;; Diffing is deliberately bounded rather than using a whole-file LCS. Local
;; edits resynchronize on a short run of equal lines, and equal runs longer than
;; two context windows split hunks. Work is therefore linear in unchanged spans
;; and bounded by a small lookahead around each changed span; two distant edits
;; never materialize the compiler-sized interval between them.
(define (fmt-diff-context) : i64
  3)

(define (fmt-diff-lookahead) : i64
  64)

(define (fmt-diff-anchor-lines) : i64
  3)

(defenum FmtDiffSync
  (Found i64 i64)
  (Missing))

(defstruct FmtDiffHunk
  (src-start i64)
  (src-end i64)
  (dst-start i64)
  (dst-end i64)
  (next-src i64)
  (next-dst i64))

(defenum FmtDiffHunkStep
  (Done)
  (Found FmtDiffHunk))

(define (fmt-split-lines-into
  [source : String]
  [start : i64]
  [lines : (&mut lines fmt_svec.Vec)]) : unit
  (let
    [len : i64 (string.string-length source)]
    [cursor : i64 start]
    (begin
      (while (<= cursor len)
        (let
          [nl : i64 (string.index-of-byte source cursor (cast 10 : u8))]
          (if (< nl 0)
            (begin
              (fmt_svec.push-ref!
                lines
                (string.substring source cursor (- len cursor)))
              (set! cursor (+ len 1)))
            (begin
              (fmt_svec.push-ref!
                lines
                (string.substring source cursor (- nl cursor)))
              (set! cursor (+ nl 1))))))
      unit)))

(define (fmt-diff-line-eq?
  [src : (& source fmt_svec.Vec)]
  [src-index : i64]
  [src-end : i64]
  [dst : (& formatted fmt_svec.Vec)]
  [dst-index : i64]
  [dst-end : i64]) : bool
  (if (and (< src-index src-end) (< dst-index dst-end))
    (string.eq (fmt_svec.get src src-index "") (fmt_svec.get dst dst-index ""))
    false))

;; Require three equal lines for an interior anchor so repeated blank or
;; delimiter-only lines do not resynchronize the streams spuriously. A shorter
;; run is sufficient only when it consumes both remaining tails.
(define (fmt-diff-sync-run?
  [src : (& source fmt_svec.Vec)]
  [src-index : i64]
  [src-end : i64]
  [dst : (& formatted fmt_svec.Vec)]
  [dst-index : i64]
  [dst-end : i64]) : bool
  (let
    [src-left : i64 (- src-end src-index)]
    [dst-left : i64 (- dst-end dst-index)]
    [available : i64
      (if (< src-left dst-left)
        src-left
        dst-left)]
    [anchor : i64 (fmt-diff-anchor-lines)]
    [count : i64
      (if (< available anchor)
        available
        anchor)]
    [terminal-short : bool
      (and
        (> count 0)
        (< count anchor)
        (= (+ src-index count) src-end)
        (= (+ dst-index count) dst-end))]
    [offset : i64 0]
    [same : bool (or (= count anchor) terminal-short)]
    (begin
      (while (and same (< offset count))
        (begin
          (if (string.eq
            (fmt_svec.get src (+ src-index offset) "")
            (fmt_svec.get dst (+ dst-index offset) ""))
            unit
            (set! same false))
          (set! offset (+ offset 1))))
      same)))

;; Search edit distance first, so a one-line insertion/deletion wins over a
;; larger replacement. The search area is capped independently of file size.
(define (fmt-diff-find-sync
  [src : (& source fmt_svec.Vec)]
  [src-index : i64]
  [src-end : i64]
  [dst : (& formatted fmt_svec.Vec)]
  [dst-index : i64]
  [dst-end : i64]) : FmtDiffSync
  (let
    [lookahead : i64 (fmt-diff-lookahead)]
    [src-left : i64 (- src-end src-index)]
    [dst-left : i64 (- dst-end dst-index)]
    [max-src : i64
      (if (< src-left lookahead)
        src-left
        lookahead)]
    [max-dst : i64
      (if (< dst-left lookahead)
        dst-left
        lookahead)]
    [distance : i64 1]
    [found : bool false]
    [found-src : i64 0]
    [found-dst : i64 0]
    (begin
      (while (and (not found) (<= distance (+ max-src max-dst)))
        (let
          [src-skip : i64
            (if (> distance max-dst)
              (- distance max-dst)
              0)]
          [src-limit : i64
            (if (< distance max-src)
              distance
              max-src)]
          (begin
            (while (and (not found) (<= src-skip src-limit))
              (let
                [dst-skip : i64 (- distance src-skip)]
                (begin
                  (if (fmt-diff-sync-run?
                    src
                    (+ src-index src-skip)
                    src-end
                    dst
                    (+ dst-index dst-skip)
                    dst-end)
                    (begin
                      (set! found true)
                      (set! found-src src-skip)
                      (set! found-dst dst-skip))
                    unit)
                  (set! src-skip (+ src-skip 1)))))
            (set! distance (+ distance 1)))))
      (if found
        (FmtDiffSync.Found found-src found-dst)
        (FmtDiffSync.Missing)))))

(define (fmt-diff-next-hunk
  [src : (& source fmt_svec.Vec)]
  [dst : (& formatted fmt_svec.Vec)]
  [scan-src : i64]
  [scan-dst : i64]) : FmtDiffHunkStep
  (let
    [slen : i64 (fmt_svec.len src)]
    [dlen : i64 (fmt_svec.len dst)]
    [src-index : i64 scan-src]
    [dst-index : i64 scan-dst]
    [ctx : i64 (fmt-diff-context)]
    (begin
      (while (fmt-diff-line-eq? src src-index slen dst dst-index dlen)
        (begin
          (set! src-index (+ src-index 1))
          (set! dst-index (+ dst-index 1))))
      (if (and (>= src-index slen) (>= dst-index dlen))
        (FmtDiffHunkStep.Done)
        (let
          [src-start : i64
            (if (> src-index ctx)
              (- src-index ctx)
              0)]
          [dst-start : i64
            (if (> dst-index ctx)
              (- dst-index ctx)
              0)]
          [finished : bool false]
          [split : bool false]
          [src-end : i64 slen]
          [dst-end : i64 dlen]
          [next-src : i64 slen]
          [next-dst : i64 dlen]
          (begin
            (while (not finished)
              (if (fmt-diff-line-eq? src src-index slen dst dst-index dlen)
                (let
                  [common-src : i64 src-index]
                  [common-dst : i64 dst-index]
                  (begin
                    (while (fmt-diff-line-eq?
                      src
                      src-index
                      slen
                      dst
                      dst-index
                      dlen)
                      (begin
                        (set! src-index (+ src-index 1))
                        (set! dst-index (+ dst-index 1))))
                    (if (> (- src-index common-src) (* 2 ctx))
                      (begin
                        (set! src-end (+ common-src ctx))
                        (set! dst-end (+ common-dst ctx))
                        (set! next-src (+ common-src ctx))
                        (set! next-dst (+ common-dst ctx))
                        (set! split true)
                        (set! finished true))
                      (if (and (>= src-index slen) (>= dst-index dlen))
                        (set! finished true)
                        unit))))
                (match (fmt-diff-find-sync
                  src
                  src-index
                  slen
                  dst
                  dst-index
                  dlen)
                  [(FmtDiffSync.Found src-skip dst-skip)
                    (begin
                      (set! src-index (+ src-index src-skip))
                      (set! dst-index (+ dst-index dst-skip)))]
                  [(FmtDiffSync.Missing)
                    (let
                      [src-left : i64 (- slen src-index)]
                      [dst-left : i64 (- dlen dst-index)]
                      [lookahead : i64 (fmt-diff-lookahead)]
                      (begin
                        (set!
                          src-index
                          (+
                            src-index
                            (if (< src-left lookahead)
                              src-left
                              lookahead)))
                        (set!
                          dst-index
                          (+
                            dst-index
                            (if (< dst-left lookahead)
                              dst-left
                              lookahead)))
                        (if (and (>= src-index slen) (>= dst-index dlen))
                          (set! finished true)
                          unit)))])))
            (FmtDiffHunkStep.Found
              (FmtDiffHunk
                src-start
                src-end
                dst-start
                dst-end
                (if split
                  next-src
                  slen)
                (if split
                  next-dst
                  dlen)))))))))

(define (fmt-diff-emit-range-into!
  [lines : (& lines fmt_svec.Vec)]
  [marker : String]
  [from : i64]
  [to : i64]
  [buf : (&mut buf fmt_buf.FmtRenderBuf)]) : unit
  (let
    [index : i64 from]
    (while (< index to)
      (begin
        (fmt_buf.fmt-render-buf-append
          buf
          (owned_view.compiler-owned-shared-view marker))
        (fmt_buf.fmt-render-buf-append buf (fmt_svec.get lines index ""))
        (fmt_buf.fmt-render-buf-append buf "\n")
        (set! index (+ index 1))))))

(define (fmt-diff-emit-hunk-into!
  [src : (& source fmt_svec.Vec)]
  [dst : (& formatted fmt_svec.Vec)]
  [hunk : FmtDiffHunk]
  [buf : (&mut buf fmt_buf.FmtRenderBuf)]) : unit
  (let
    [src-index : i64 hunk.src-start]
    [dst-index : i64 hunk.dst-start]
    (while (or (< src-index hunk.src-end) (< dst-index hunk.dst-end))
      (if (fmt-diff-line-eq?
        src
        src-index
        hunk.src-end
        dst
        dst-index
        hunk.dst-end)
        (begin
          (fmt-diff-emit-range-into! src " " src-index (+ src-index 1) buf)
          (set! src-index (+ src-index 1))
          (set! dst-index (+ dst-index 1)))
        (match (fmt-diff-find-sync
          src
          src-index
          hunk.src-end
          dst
          dst-index
          hunk.dst-end)
          [(FmtDiffSync.Found src-skip dst-skip)
            (begin
              (fmt-diff-emit-range-into!
                src
                "-"
                src-index
                (+ src-index src-skip)
                buf)
              (fmt-diff-emit-range-into!
                dst
                "+"
                dst-index
                (+ dst-index dst-skip)
                buf)
              (set! src-index (+ src-index src-skip))
              (set! dst-index (+ dst-index dst-skip)))]
          [(FmtDiffSync.Missing)
            (let
              [src-left : i64 (- hunk.src-end src-index)]
              [dst-left : i64 (- hunk.dst-end dst-index)]
              [lookahead : i64 (fmt-diff-lookahead)]
              [src-next : i64
                (+
                  src-index
                  (if (< src-left lookahead)
                    src-left
                    lookahead))]
              [dst-next : i64
                (+
                  dst-index
                  (if (< dst-left lookahead)
                    dst-left
                    lookahead))]
              (begin
                ;; Keep probing after a bounded unmatched window. A whole-file
                ;; line-ending change can otherwise hide a short equal tail
                ;; beyond the first lookahead and render it as remove/add text
                ;; instead of the hunk's final unchanged context.
                (fmt-diff-emit-range-into! src "-" src-index src-next buf)
                (fmt-diff-emit-range-into! dst "+" dst-index dst-next buf)
                (set! src-index src-next)
                (set! dst-index dst-next)))])))))

(define (fmt-diff-hunk-header
  [src-start : i64]
  [src-count : i64]
  [dst-start : i64]
  [dst-count : i64]) : String
  (str_cat.str-cat
    "@@ -"
    (string.int->string src-start)
    ","
    (string.int->string src-count)
    " +"
    (string.int->string dst-start)
    ","
    (string.int->string dst-count)
    " @@\n"))

(define (fmt-unified-diff
  [path : String]
  [source : String]
  [formatted : String]) : String
  (let
    [src : fmt_svec.Vec (fmt_svec.new)]
    [_src-lines : unit (fmt-split-lines-into source 0 (&mut src))]
    [dst : fmt_svec.Vec (fmt_svec.new)]
    [_dst-lines : unit (fmt-split-lines-into formatted 0 (&mut dst))]
    [scan-src : i64 0]
    [scan-dst : i64 0]
    [finished : bool false]
    [buf : fmt_buf.FmtRenderBuf (fmt_buf.fmt-render-buf-new)]
    (begin
      (fmt_buf.fmt-render-buf-append (&mut buf) "--- a/")
      (fmt_buf.fmt-render-buf-append
        (&mut buf)
        (owned_view.compiler-owned-shared-view path))
      (fmt_buf.fmt-render-buf-append (&mut buf) "\n+++ b/")
      (fmt_buf.fmt-render-buf-append (&mut buf) path)
      (fmt_buf.fmt-render-buf-append (&mut buf) "\n")
      (while (not finished)
        (match (fmt-diff-next-hunk (& src) (& dst) scan-src scan-dst)
          [(FmtDiffHunkStep.Done) (set! finished true)]
          [(FmtDiffHunkStep.Found hunk)
            (begin
              (fmt_buf.fmt-render-buf-append
                (&mut buf)
                (fmt-diff-hunk-header
                  (+ hunk.src-start 1)
                  (- hunk.src-end hunk.src-start)
                  (+ hunk.dst-start 1)
                  (- hunk.dst-end hunk.dst-start)))
              (fmt-diff-emit-hunk-into! (& src) (& dst) hunk (&mut buf))
              (set! scan-src hunk.next-src)
              (set! scan-dst hunk.next-dst))]))
      (fmt_buf.fmt-render-buf-string buf))))

(define (fmt-diff-large-fixture [formatted : bool]) : String
  (let
    [buf : fmt_buf.FmtRenderBuf (fmt_buf.fmt-render-buf-new)]
    [index : i64 0]
    (begin
      (while (< index 4096)
        (begin
          (fmt_buf.fmt-render-buf-append
            (&mut buf)
            (if (and (not formatted) (or (= index 8) (= index 4088)))
              (str_cat.str-cat
                "(define  value-"
                (string.int->string index)
                "  0)\n")
              (str_cat.str-cat
                "(define value-"
                (string.int->string index)
                " 0)\n")))
          (set! index (+ index 1))))
      (fmt_buf.fmt-render-buf-string buf))))

(test
  fmt-check-diff-output-is-bounded-by-changes-not-distance
  (let
    [diff : String
      (fmt-unified-diff
        "large.tl"
        (fmt-diff-large-fixture false)
        (fmt-diff-large-fixture true))]
    (if (and
      (< (string.string-length diff) 4096)
      (string.contains (& diff) "-(define  value-8  0)\n")
      (string.contains (& diff) "-(define  value-4088  0)\n")
      (not (string.contains (& diff) "value-2048")))
      unit
      (io.panic (string.copy diff)))))

(define (fmt-diff-long-replacement-fixture [prefix : String]) : String
  (let
    [buf : fmt_buf.FmtRenderBuf (fmt_buf.fmt-render-buf-new)]
    [index : i64 0]
    (begin
      (while (< index 70)
        (begin
          (fmt_buf.fmt-render-buf-append
            (&mut buf)
            (str_cat.str-cat
              (owned_view.compiler-owned-shared-view prefix)
              (string.int->string index)
              "\n"))
          (set! index (+ index 1))))
      (fmt_buf.fmt-render-buf-append (&mut buf) "tail\n")
      (fmt_buf.fmt-render-buf-string buf))))

(test
  fmt-check-diff-resynchronizes-after-a-long-replacement
  (let
    [diff : String
      (fmt-unified-diff
        "long.tl"
        (fmt-diff-long-replacement-fixture "old-")
        (fmt-diff-long-replacement-fixture "new-"))]
    (if (and
      (string.contains (& diff) " tail\n")
      (not (string.contains (& diff) "-tail\n"))
      (not (string.contains (& diff) "+tail\n")))
      unit
      (io.panic (string.copy diff)))))

(define (fmt-format-file [check : bool] [path : String]) : i64
  (let
    [source : String
      (byte_buf.to-string
        (io.read-file (owned_view.compiler-owned-shared-view path)))]
    (match (format_rules.format-rules-render-source-width-result
      (owned_view.compiler-owned-shared-view source)
      80)
      [(format_rules.ResultFormatString.Ok formatted)
        (if check
          (if (string.eq
            (owned_view.compiler-owned-shared-view source)
            formatted)
            0
            (begin
              (io.print-error
                (str_cat.str-cat
                  "fmt: would reformat "
                  (owned_view.compiler-owned-shared-view path)
                  "\n"
                  (fmt-unified-diff
                    (owned_view.compiler-owned-shared-view path)
                    (owned_view.compiler-owned-shared-view source)
                    formatted)))
              1))
          (if (string.eq
            (owned_view.compiler-owned-shared-view source)
            formatted)
            0
            (fmt-write-formatted-file path formatted)))]
      [(format_rules.ResultFormatString.Err err)
        (begin
          (io.print-error
            (str_cat.str-cat (fmt-source-error-message path err) "\n"))
          1)])))

;; Parsing and rendering retain a complete CST and document tree. Reclaim that
;; scratch state after each file so multi-file formatter invocations do not grow
;; the process-lifetime arena with the size of the whole corpus.
(define (fmt-format-file-scoped [check : bool] [path : String]) : i64
  (with-arena file-arena (fmt-format-file check path)))

(define (fmt-files-from
  [check : bool]
  [paths : fmt_svec.Vec]
  [index : i64]
  [status : i64]) : i64
  (if (>= index (fmt_svec.len (& paths)))
    status
    (let
      [path : String (fmt_svec.get (& paths) index "")]
      [file-status : i64 (fmt-format-file-scoped check path)]
      (fmt-files-from
        check
        paths
        (+ index 1)
        (if (= status 0)
          file-status
          status)))))

(define (fmt-files [check : bool] [paths : fmt_svec.Vec] [status : i64]) : i64
  (fmt-files-from check paths 0 status))

(define (fmt-package-files-from
  [check : bool]
  [paths : fmt_svec.Vec]
  [index : i64]
  [status : i64]) : i64
  (if (>= index (fmt_svec.len (& paths)))
    status
    (let
      [path : String (fmt_svec.get (& paths) index "")]
      [file-status : i64 (fmt-format-file-scoped check path)]
      (fmt-package-files-from
        check
        paths
        (+ index 1)
        (if (= status 0)
          file-status
          status)))))

(define (fmt-package-files [check : bool] [paths : fmt_svec.Vec] [status : i64]) : i64
  (fmt-package-files-from check paths 0 status))

(define (fmt-package
  [check : bool]
  [manifest-path : String]
  [has-manifest : bool]) : i64
  (match (package_source_core.package-source-discover-for
    "fmt"
    manifest-path
    has-manifest)
    [(package_source_core.ResultPackageSourceSet.Err message)
      (begin
        (io.print-error (str_cat.str-cat message "\n"))
        1)]
    [(package_source_core.ResultPackageSourceSet.Ok source-set)
      (fmt-package-files check source-set.sources 0)]))

;; Run the `fmt` command over arguments starting at `start` (the index of the
;; first argument after any subcommand name); `count` is `(arg-count)`.
(define (fmt-run-from [start : i64] [count : i64]) : i64
  (match (fmt-config-from start count)
    [(ResultFmtConfig.Ok config)
      (match config
        [(FmtConfig.File check paths) (fmt-files check paths 0)]
        [(FmtConfig.Package check manifest-path has-manifest)
          (fmt-package check manifest-path has-manifest)])]
    [(ResultFmtConfig.Err message)
      (begin
        (io.print-error (str_cat.str-cat message "\n"))
        1)]))