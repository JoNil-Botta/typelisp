;; format_cli_core.tl - Self-hosted `fmt` command logic.
;;
;; The formatter CLI logic, factored out of `format.tl` so both the retained
;; formatter compatibility/coverage driver and the unified `cli.tl` dispatcher
;; can run the `fmt` command without duplicating a `main`.
(import stdlib.io)
(import stdlib.string)
(import stdlib.vector)
(import (vector.vector String) as fmt_svec)
(import cli_option_core as cli_option)
(import "format_rules.tl")
(import "package_source_core.tl")

(defenum FmtConfig
  (File bool fmt_svec.Vec)
  (Package bool String bool))

(defenum ResultFmtConfig
  (Ok FmtConfig)
  (Err String))

(defenum ResultFmtWrite
  (Ok)
  (Err String))

(define (fmt-write-error-message [path : String] [error : io.IoError]) : String
  (string.append
    "fmt: failed to write "
    (string.append path (string.append ": " (io.error-message error)))))

(define (fmt-try-write-formatted-file [path : String] [formatted : String]) : ResultFmtWrite
  (match (io.try-write-file (& path) (& formatted))
    [(io.OkIoUnit) ResultFmtWrite.Ok]
    [(io.ErrIoUnit error)
      (ResultFmtWrite.Err (fmt-write-error-message path error))]))

(define (fmt-write-formatted-file [path : String] [formatted : String]) : i64
  (match (fmt-try-write-formatted-file path formatted)
    [(ResultFmtWrite.Ok) 0]
    [(ResultFmtWrite.Err message)
      (begin
        (io.print-error (string.append message "\n"))
        1)]))

(define (fmt-source-error-message [path : String] [err : FormatSourceError]) : String
  (let
    [span : FormatSourceSpan (format-source-error-span err)]
    (string.append
      path
      (string.append
        ":"
        (string.append
          (string.int->string (format-source-span-start-line span))
          (string.append
            ":"
            (string.append
              (string.int->string (format-source-span-start-col span))
              (string.append ": " (format-source-error-message err)))))))))

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
  (match (format-rules-render-source-width-result "(define x\n  ]" 80)
    [(ResultFormatString.Ok _) (io.panic "fmt parse unexpectedly succeeded")]
    [(ResultFormatString.Err err)
      (let
        [message : String (fmt-source-error-message "bad.tl" err)]
        (if (string.eq
          message
          "bad.tl:2:3: format cst: unexpected closing delimiter")
          unit
          (io.panic message)))]))

(define (fmt-malformed-int-error? [source : String]) : bool
  (match (format-rules-render-source-width-result source 80)
    [(ResultFormatString.Ok _) false]
    [(ResultFormatString.Err err)
      (string.eq
        (format-source-error-message err)
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
        current
        idx
        count
        cli_option.cli-common-option-stdlib-root)
        [(cli_option.CliCommonOption.Missing kind)
          (ResultFmtConfig.Err
            (cli_option.cli-common-option-missing-message "fmt" kind))]
        [(cli_option.CliCommonOption.Value _ _ next-idx)
          (fmt-parse-args next-idx count check paths manifest-path has-manifest)]
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
            [(fmt-flag? current)
              (ResultFmtConfig.Err (string.append "fmt: unknown flag " current))]
            [else
              (begin
                (fmt_svec.push (&mut paths) current)
                (fmt-parse-args
                  (+ idx 1)
                  count
                  check
                  paths
                  manifest-path
                  has-manifest))])]))))

(define (fmt-config-from [start : i64] [count : i64]) : ResultFmtConfig
  (fmt-parse-args start count false (fmt_svec.new) "" false))

;; --- unified diff for --check -----------------------------------------------
;;
;; #5671: `--check` named the file but not what was wrong with it, so a failing
;; CI log made the contributor reproduce the formatting locally to see it. The
;; formatted text is already in memory at the point of the report, so rendering
;; the diff needs no extra formatting work.
;;
;; The hunk is coalesced: common leading and trailing lines are trimmed and
;; everything between them is emitted as one `-` run followed by one `+` run.
;; That is a valid and deterministic unified diff, but it is not minimal -- two
;; distant edits in one file print as a single hunk spanning both. Formatter
;; edits are normally local, and a minimal diff would need an LCS pass over
;; files that reach tens of thousands of lines.
(define (fmt-diff-context) : i64
  3)

(define (fmt-split-lines-into
  [source : String]
  [start : i64]
  [lines : fmt_svec.Vec]) : fmt_svec.Vec
  (let
    [len : i64 (string.string-length source)]
    (if (> start len)
      lines
      (let
        [nl : i64 (string.index-of-byte source start (cast 10 : u8))]
        (if (< nl 0)
          (begin
            (fmt_svec.push
              (&mut lines)
              (string.substring source start (- len start)))
            lines)
          (begin
            (fmt_svec.push
              (&mut lines)
              (string.substring source start (- nl start)))
            (fmt-split-lines-into source (+ nl 1) lines)))))))

(define (fmt-common-prefix-lines
  [a : fmt_svec.Vec]
  [b : fmt_svec.Vec]
  [idx : i64]) : i64
  (if (or (>= idx (fmt_svec.len (& a))) (>= idx (fmt_svec.len (& b))))
    idx
    (if (string.eq (fmt_svec.get (& a) idx "") (fmt_svec.get (& b) idx ""))
      (fmt-common-prefix-lines a b (+ idx 1))
      idx)))

;; Counts matching trailing lines, never letting the suffix run back into the
;; prefix -- otherwise an all-identical tail would double-count lines already
;; claimed by the prefix and produce a negative-length hunk.
(define (fmt-common-suffix-lines
  [a : fmt_svec.Vec]
  [b : fmt_svec.Vec]
  [prefix : i64]
  [count : i64]) : i64
  (let
    [alen : i64 (fmt_svec.len (& a))]
    [blen : i64 (fmt_svec.len (& b))]
    (if (or (>= (+ prefix count) alen) (>= (+ prefix count) blen))
      count
      (if (string.eq
        (fmt_svec.get (& a) (- alen (+ count 1)) "")
        (fmt_svec.get (& b) (- blen (+ count 1)) ""))
        (fmt-common-suffix-lines a b prefix (+ count 1))
        count))))

(define (fmt-diff-emit-range
  [lines : fmt_svec.Vec]
  [marker : String]
  [from : i64]
  [to : i64]
  [acc : String]) : String
  (if (>= from to)
    acc
    (fmt-diff-emit-range
      lines
      marker
      (+ from 1)
      to
      (string.append
        acc
        (string.append
          marker
          (string.append (fmt_svec.get (& lines) from "") "\n"))))))

(define (fmt-diff-hunk-header
  [src-start : i64]
  [src-count : i64]
  [dst-start : i64]
  [dst-count : i64]) : String
  (string.append
    "@@ -"
    (string.append
      (string.int->string src-start)
      (string.append
        ","
        (string.append
          (string.int->string src-count)
          (string.append
            " +"
            (string.append
              (string.int->string dst-start)
              (string.append
                ","
                (string.append (string.int->string dst-count) " @@\n")))))))))

(define (fmt-unified-diff
  [path : String]
  [source : String]
  [formatted : String]) : String
  (let
    [src : fmt_svec.Vec (fmt-split-lines-into source 0 (fmt_svec.new))]
    [dst : fmt_svec.Vec (fmt-split-lines-into formatted 0 (fmt_svec.new))]
    [slen : i64 (fmt_svec.len (& src))]
    [dlen : i64 (fmt_svec.len (& dst))]
    [prefix : i64 (fmt-common-prefix-lines src dst 0)]
    [suffix : i64 (fmt-common-suffix-lines src dst prefix 0)]
    [ctx : i64 (fmt-diff-context)]
    [start : i64
      (if (> (- prefix ctx) 0)
        (- prefix ctx)
        0)]
    [src-end : i64 (- slen suffix)]
    [dst-end : i64 (- dlen suffix)]
    [src-ctx-end : i64
      (if (< (+ src-end ctx) slen)
        (+ src-end ctx)
        slen)]
    [dst-ctx-end : i64
      (if (< (+ dst-end ctx) dlen)
        (+ dst-end ctx)
        dlen)]
    (string.append
      (string.append
        (string.append "--- a/" (string.append path "\n"))
        (string.append "+++ b/" (string.append path "\n")))
      (string.append
        (fmt-diff-hunk-header
          (+ start 1)
          (- src-ctx-end start)
          (+ start 1)
          (- dst-ctx-end start))
        (string.append
          (fmt-diff-emit-range src " " start prefix "")
          (string.append
            (fmt-diff-emit-range src "-" prefix src-end "")
            (string.append
              (fmt-diff-emit-range dst "+" prefix dst-end "")
              (fmt-diff-emit-range src " " src-end src-ctx-end ""))))))))

(define (fmt-format-file [check : bool] [path : String]) : i64
  (let
    [source : String (io.read-file path)]
    (match (format-rules-render-source-width-result source 80)
      [(ResultFormatString.Ok formatted)
        (if check
          (if (string.eq source formatted)
            0
            (begin
              (io.print-error
                (string.append
                  (string.append
                    "fmt: would reformat "
                    (string.append path "\n"))
                  (fmt-unified-diff path source formatted)))
              1))
          (if (string.eq source formatted)
            0
            (fmt-write-formatted-file path formatted)))]
      [(ResultFormatString.Err err)
        (begin
          (io.print-error
            (string.append (fmt-source-error-message path err) "\n"))
          1)])))

(define (fmt-files-from
  [check : bool]
  [paths : fmt_svec.Vec]
  [index : i64]
  [status : i64]) : i64
  (if (>= index (fmt_svec.len (& paths)))
    status
    (let
      [path : String (fmt_svec.get (& paths) index "")]
      [file-status : i64 (fmt-format-file check path)]
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
      [file-status : i64 (fmt-format-file check path)]
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
  (match (package-source-discover-for "fmt" manifest-path has-manifest)
    [(ResultPackageSourceSet.Err message)
      (begin
        (io.print-error (string.append message "\n"))
        1)]
    [(ResultPackageSourceSet.Ok source-set)
      (fmt-package-files check (struct-get source-set sources) 0)]))

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
        (io.print-error (string.append message "\n"))
        1)]))