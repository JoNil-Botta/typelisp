;; Native zero-dependency codegen-cases runner entry point.
;; Invoked by scripts/verify-codegen-cases.sh (cached under target/codegen-cases-runner/<key>).
(import stdlib.args)
(import stdlib.byte_buf)
(import stdlib.byte_buf_core as bbc)
(import stdlib.env)
(import stdlib.fs)
(import stdlib.io)
(import stdlib.str_cat)
(import stdlib.string)
(import stdlib.thread)
(import stdlib.vector)
(import (vector.vector String) as svec)
(import (vector.vector i64) as ivec)
(import analyzers)
(import exec)
(import parser)
(import regex)
(import util)

(defstruct VariantJob
  (case-idx i64)
  (target String)
  (opt String)
  (mode String)
  (each String)
  (needs-barrier bool))

(import (vector.vector VariantJob core) as jobvec)
(import (vector.vector exec.VariantResult core) as resvec)
(import (vector.vector thread.ThreadString core) as thvec)

;; Read-only wave context shared across worker threads (initialized before spawn,
;; never mutated while workers run).
(define wave-cfg : exec.RunnerConfig
  (exec.RunnerConfig
    ""
    ""
    ""
    "linux"
    "linux-x86_64"
    ""
    "lib"
    ".a"
    (svec.new)
    ""
    "auto"
    ""
    false
    ""
    ""
    ""
    "sh"))
(define wave-file : parser.ParsedFile
  (parser.empty-parsed-file))
(define wave-work-dir : String
  "")
(define wave-native-work-dir : String
  "")
(define wave-jobs : jobvec.Vec
  (jobvec.new))
(define wave-end-idx : i64
  0)
(define wave-next-idx : i64
  0)

(define (env-or [name : (& name str)] [fallback : (& fallback str)]) : String
  (match (env.get name)
    [(env.EnvSomeString v) v]
    [(env.EnvNoString) (string.copy fallback)]))

(define (env-nonempty-or [name : (& name str)] [fallback : (& fallback str)]) : String
  (match (env.get name)
    [(env.EnvSomeString v)
      (if (> (string.string-length (& v)) 0)
        v
        (string.copy fallback))]
    [(env.EnvNoString) (string.copy fallback)]))

(define (default-workers) : i64
  (let
    [raw : String (env-or "TYPELISP_CODEGEN_CASES_WORKERS" "")]
    (if (= (string.string-length (& raw)) 0)
      4
      (let
        [p : util.ParsedI64 (util.parse-u64-strict (& raw))]
        (if (and p.ok (>= p.value 1))
          p.value
          4)))))

;; Encode/decode VariantResult into a length-prefixed string so workers return results
;; safely via `thread.spawn-string` with zero raw pointer sharing across threads.
(define (encode-variant-result!
  [out : (&mut out bbc.ByteBufBuilder)]
  [r : (& r exec.VariantResult)]) : unit
  (bbc.byte-buf-builder-append-string
    out
    (str_cat.str-cat
      (string.int->string r.index)
      "\t"
      (string.int->string r.failures)
      "\t"
      (string.int->string r.rows)
      "\t"
      (string.int->string r.skipped)
      "\t"
      (string.int->string r.simd-native)
      "\t"
      (string.int->string r.simd-emulated)
      "\t"
      (string.int->string r.simd-skipped)
      "\t"
      (string.int->string (string.string-length (& r.stdout-log)))
      "\t"
      (string.int->string (string.string-length (& r.stderr-log)))
      "\n"))
  (bbc.byte-buf-builder-append-string out (string.copy (& r.stdout-log)))
  (bbc.byte-buf-builder-append-string out (string.copy (& r.stderr-log))))

(define (decode-worker-results!
  [payload : (& payload str)]
  [results : (&mut results resvec.Vec)]) : unit
  (let
    [n : i64 (string.string-length payload)]
    [pos : i64 0]
    (while (< pos n)
      (let
        [nl : i64 (util.index-of-byte-from payload pos 10)]
        (if (< nl 0)
          (set! pos n)
          (let
            [hdr : String (string.substring payload pos (- nl pos))]
            [cols : svec.Vec (util.split-by-sep (& hdr) "\t")]
            (if (< (svec.len (& cols)) 9)
              (set! pos n)
              (let
                [vidx : i64
                  (util.parse-i64-strict (svec.get (& cols) 0 "")).value]
                [fails : i64
                  (util.parse-i64-strict (svec.get (& cols) 1 "")).value]
                [rows : i64
                  (util.parse-i64-strict (svec.get (& cols) 2 "")).value]
                [skips : i64
                  (util.parse-i64-strict (svec.get (& cols) 3 "")).value]
                [sn : i64
                  (util.parse-i64-strict (svec.get (& cols) 4 "")).value]
                [se : i64
                  (util.parse-i64-strict (svec.get (& cols) 5 "")).value]
                [ss : i64
                  (util.parse-i64-strict (svec.get (& cols) 6 "")).value]
                [olen : i64
                  (util.parse-u64-strict (svec.get (& cols) 7 "")).value]
                [elen : i64
                  (util.parse-u64-strict (svec.get (& cols) 8 "")).value]
                [ostart : i64 (+ nl 1)]
                [estart : i64 (+ ostart olen)]
                [next-pos : i64 (+ estart elen)]
                (if (<= next-pos n)
                  (let
                    [out-s : String (string.substring payload ostart olen)]
                    [err-s : String (string.substring payload estart elen)]
                    (resvec.set-ref!
                      results
                      vidx
                      (exec.VariantResult
                        vidx
                        fails
                        rows
                        skips
                        sn
                        se
                        ss
                        out-s
                        err-s))
                    (set! pos next-pos))
                  (set! pos n))))))))))

;; Run one variant job inside a fresh scratch arena, cloning only its small encoded
;; VariantResult out to the caller's arena so 800+ variants never bloat RSS!
(define (run-job-in-scratch [jidx : i64]) : String
  (with-scratch
    (let
      [job : VariantJob
        (jobvec.get (& wave-jobs) jidx (VariantJob 0 "" "" "" "" false))]
      [cdef : parser.CaseDef
        (parser.parsed-cases-get (& wave-file) job.case-idx)]
      [r : exec.VariantResult
        (exec.run-single-variant
          (& wave-cfg)
          (& wave-file.file-path)
          (& wave-work-dir)
          (& wave-native-work-dir)
          (& cdef)
          (& job.target)
          (& job.opt)
          (& job.mode)
          (& job.each)
          jidx)]
      [buf : bbc.ByteBufBuilder (bbc.byte-buf-builder-new)]
      (encode-variant-result! (&mut buf) (& r))
      (bbc.byte-buf-builder-finish-string (& buf)))))

(define (worker-loop) : String
  (let
    [out : bbc.ByteBufBuilder (bbc.byte-buf-builder-new)]
    [done : bool false]
    (while (not done)
      (let
        [jidx : i64
          (unsafe
            (atomic-fetch-add! (ptr-addr-of wave-next-idx) 1))]
        (if (>= jidx wave-end-idx)
          (set! done true)
          (bbc.byte-buf-builder-append-string
            (&mut out)
            (run-job-in-scratch jidx)))))
    (bbc.byte-buf-builder-finish-string (& out))))

;; Run jobs [start, end) using up to `workers` threads, returning results in order.
(define (run-wave!
  [start : i64]
  [end : i64]
  [workers : i64]
  [results : (&mut results resvec.Vec)]) : unit
  (let
    [count : i64 (- end start)]
    (when
      (> count 0)
      (let
        [w : i64
          (if (< count workers)
            count
            workers)]
        (set! wave-next-idx start)
        (set! wave-end-idx end)
        (if (<= w 1)
          (let
            [i : i64 start]
            (while (< i end)
              (let
                [enc : String (run-job-in-scratch i)]
                (decode-worker-results! (& enc) results))
              (set! i (+ i 1))))
          (let
            [handles : thvec.Vec (thvec.with-capacity w)]
            [i : i64 0]
            (while (< i w)
              (match (thread.spawn-string
                (lambda () : String
                  (worker-loop)))
                [(thread.ThreadStringSpawnOk h)
                  (thvec.push-ref! (&mut handles) h)]
                [(thread.ThreadStringSpawnErr _)
                  ;; If thread spawn fails, drain remaining jobs on caller thread after loop
                  unit])
              (set! i (+ i 1)))
            ;; Also drain any remaining work if fewer threads spawned than requested
            (when
              (< (thvec.len (& handles)) w)
              (let
                [extra : String (worker-loop)]
                (decode-worker-results! (& extra) results)))
            (let
              [nh : i64 (thvec.len (& handles))]
              [k : i64 0]
              (while (< k nh)
                (let
                  [h : thread.ThreadString
                    (unsafe
                      (ptr-read (ptr-offset (__tl_array-data handles.slots) k)))]
                  (match (thread.join-string h)
                    [(thread.ThreadStringJoinOk payload)
                      (decode-worker-results! (& payload) results)]
                    [(thread.ThreadStringJoinErr _) unit]))
                (set! k (+ k 1))))))))))

;; ---------------------------------------------------------------- built-in --self-test
(define (assert-eq-bool [label : (& label str)] [got : bool] [want : bool]) : i64
  (if (!= got want)
    (begin
      (io.print-error
        (str_cat.str-cat "SELF-TEST FAIL: " (string.copy label) "\n"))
      1)
    0))

(define (assert-eq-str
  [label : (& label str)]
  [got : (& got str)]
  [want : (& want str)]) : i64
  (if (not (string.eq got want))
    (begin
      (io.print-error
        (str_cat.str-cat
          "SELF-TEST FAIL: "
          (string.copy label)
          " got=["
          (string.copy got)
          "] want=["
          (string.copy want)
          "]\n"))
      1)
    0))

(define (assert-eq-i64 [label : (& label str)] [got : i64] [want : i64]) : i64
  (if (!= got want)
    (begin
      (io.print-error
        (str_cat.str-cat
          "SELF-TEST FAIL: "
          (string.copy label)
          " got="
          (string.int->string got)
          " want="
          (string.int->string want)
          "\n"))
      1)
    0))

(define (run-self-test) : i64
  (let
    [fails : i64 0]
    ;; 1. Regex positive & negative tests: POSIX classes, {m,n}, |, ^/$, -i, capture group 1
    (set!
      fails
      (+
        fails
        (assert-eq-bool
          "re posix space"
          (regex.regex-match-text?
            "^[[:space:]]+movq"
            "    movq %rax, %rbx\n"
            false)
          true)))
    (set!
      fails
      (+
        fails
        (assert-eq-bool
          "re posix space neg"
          (regex.regex-match-text?
            "^[[:space:]]+movq"
            "movq %rax, %rbx\n"
            false)
          false)))
    (set!
      fails
      (+
        fails
        (assert-eq-bool
          "re {40} hex ok"
          (regex.regex-match-text?
            "^([0-9a-f]{40})$"
            "0123456789abcdef0123456789abcdef01234567\n"
            false)
          true)))
    (set!
      fails
      (+
        fails
        (assert-eq-bool
          "re {40} hex short"
          (regex.regex-match-text?
            "^([0-9a-f]{40})$"
            "0123456789abcdef0123456789abcdef0123456\n"
            false)
          false)))
    (set!
      fails
      (+
        fails
        (assert-eq-bool
          "re {40} hex long"
          (regex.regex-match-text?
            "^([0-9a-f]{40})$"
            "0123456789abcdef0123456789abcdef012345678\n"
            false)
          false)))
    (set!
      fails
      (+
        fails
        (assert-eq-bool
          "re {2,4} min"
          (regex.regex-match-text? "^a{2,4}$" "a\n" false)
          false)))
    (set!
      fails
      (+
        fails
        (assert-eq-bool
          "re {2,4} mid"
          (regex.regex-match-text? "^a{2,4}$" "aaa\n" false)
          true)))
    (set!
      fails
      (+
        fails
        (assert-eq-bool
          "re {2,4} max+1"
          (regex.regex-match-text? "^a{2,4}$" "aaaaa\n" false)
          false)))
    (set!
      fails
      (+
        fails
        (assert-eq-bool
          "re alt"
          (regex.regex-match-text?
            "^[[:space:]]+movq \\(%r(di|cx)\\), %rax$"
            "    movq (%rcx), %rax\n"
            false)
          true)))
    (set!
      fails
      (+
        fails
        (assert-eq-bool
          "re alt neg"
          (regex.regex-match-text?
            "^[[:space:]]+movq \\(%r(di|cx)\\), %rax$"
            "    movq (%rdx), %rax\n"
            false)
          false)))
    (set!
      fails
      (+
        fails
        (assert-eq-bool
          "re case-insensitive"
          (regex.regex-match-text?
            "error:.*unknown"
            "ERROR: Unknown flag\n"
            true)
          true)))
    (set!
      fails
      (+
        fails
        (assert-eq-bool
          "re case-sensitive neg"
          (regex.regex-match-text?
            "error:.*unknown"
            "ERROR: Unknown flag\n"
            false)
          false)))
    (set!
      fails
      (+
        fails
        (assert-eq-i64
          "re count per-line"
          (regex.regex-count-lines "^foo$" "foo\nbar\nfoo\nfoobar\n" false)
          2)))
    ;; Capture group 1 on tricky xmm12 pattern
    (let
      [prog : regex.RegexProg
        (regex.regex-compile
          "^[[:space:]]*movups[[:space:]]+\\(%rdi\\),[[:space:]]+(%xmm([0-9]|1[0-5]))([[:space:]].*)?$"
          false)]
      [line : String "    movups (%rdi), %xmm12"]
      [m : regex.RegexMatch (regex.regex-find-line (& prog) (& line))]
      (set!
        fails
        (+
          fails
          (assert-eq-bool "re capture xmm12 ok" (and m.matched m.g1-ok) true)))
      (when
        (and m.matched m.g1-ok)
        (set!
          fails
          (+
            fails
            (assert-eq-str
              "re capture xmm12 val"
              (string.substring (& line) m.g1-start (- m.g1-end m.g1-start))
              "%xmm12")))))
    ;; Capture group 1 on sha1
    (let
      [prog : regex.RegexProg (regex.regex-compile "^([0-9a-f]{40})$" false)]
      [line : String "deadbeef0123456789abcdef0123456789abcdef"]
      [m : regex.RegexMatch (regex.regex-find-line (& prog) (& line))]
      (set!
        fails
        (+
          fails
          (assert-eq-bool "re capture sha1 ok" (and m.matched m.g1-ok) true)))
      (when
        (and m.matched m.g1-ok)
        (set!
          fails
          (+
            fails
            (assert-eq-str
              "re capture sha1 val"
              (string.substring (& line) m.g1-start (- m.g1-end m.g1-start))
              (& line))))))
    ;; Glob tests
    (set!
      fails
      (+
        fails
        (assert-eq-bool
          "glob star"
          (util.glob-match? "secret-generation-*" "secret-generation-zero")
          true)))
    (set!
      fails
      (+
        fails
        (assert-eq-bool
          "glob star neg"
          (util.glob-match? "secret-generation-*" "secret-copy-transfer")
          false)))
    (set!
      fails
      (+ fails (assert-eq-bool "glob qmark" (util.glob-match? "?t" "et") true)))
    (set!
      fails
      (+
        fails
        (assert-eq-bool "glob qmark neg" (util.glob-match? "?t" "eet") false)))
    ;; Analyzer sanity test
    (let
      [sample : String
        "fn:\n    pushq %r12\n    subq $8, %rsp\n.L0:\n    jmp .L0\n    addq $8, %rsp\n    popq %r12\n    ret\n"]
      [m1 : analyzers.AnalyzerResult
        (analyzers.run-metric "self-loop-jmps" "" (& sample))]
      [m2 : analyzers.AnalyzerResult
        (analyzers.run-metric "csr-pushes" "" (& sample))]
      [m3 : analyzers.AnalyzerResult
        (analyzers.run-metric "frame-release" "" (& sample))]
      (set!
        fails
        (+ fails (assert-eq-str "analyzer self-loop" (& m1.value) "1")))
      (set!
        fails
        (+ fails (assert-eq-str "analyzer csr-pushes" (& m2.value) "1")))
      (set!
        fails
        (+ fails (assert-eq-str "analyzer frame-release" (& m3.value) "ok"))))
    ;; Windows path conversion tests (independent of host via slashes helpers)
    (set!
      fails
      (+
        fails
        (assert-eq-str
          "slashes-to-forward"
          (util.slashes-to-forward "D:\\a\\typelisp\\out.s")
          "D:/a/typelisp/out.s")))
    (set!
      fails
      (+
        fails
        (assert-eq-str
          "slashes-to-back"
          (util.slashes-to-back "D:/a/typelisp/out.obj")
          "D:\\a\\typelisp\\out.obj")))
    (if (= fails 0)
      (begin
        (io.stdout-write
          (byte_buf.str-as-bytes "[codegen-cases-runner] self-test passed\n"))
        0)
      (begin
        (io.print-error
          (str_cat.str-cat
            "[codegen-cases-runner] self-test failed: "
            (string.int->string fails)
            " failure(s)\n"))
        1))))

;; ---------------------------------------------------------------- main
(define (usage-error) : i64
  (io.print-error
    "usage: scripts/verify-codegen-cases.sh [--list | --list-fixtures] [--only CASE-GLOB] FILE.cases...\n")
  2)

(define (main) : i64
  (let
    [specs : args.ArgsOptionSpecList
      (args.option-spec-cons
        (args.flag-option "list" "list" "")
        (args.option-spec-cons
          (args.flag-option "list-fixtures" "list-fixtures" "")
          (args.option-spec-cons
            (args.flag-option "self-test" "self-test" "")
            (args.option-spec-cons
              (args.value-option "only" "only" "")
              (args.option-spec-empty)))))]
    (match (args.parse-argv specs 1)
      [(args.ErrArgsParsed _) (usage-error)]
      [(args.OkArgsParsed parsed)
        (if (args.option-present? (& parsed) "self-test")
          (run-self-test)
          (let
            [do-list : bool (args.option-present? (& parsed) "list")]
            [do-fixtures : bool
              (args.option-present? (& parsed) "list-fixtures")]
            [only-glob : String (args.option-value-or (& parsed) "only" "*")]
            [nfiles : i64 (svec.len (& parsed.positionals))]
            (when do-fixtures (set! do-list true))
            (if (= nfiles 0)
              (usage-error)
              (let
                [cwd-fallback : String
                  (match (fs.try-current-dir)
                    [(io.OkIoString d) d]
                    [(io.ErrIoString _) "."])]
                [root : String
                  (env-nonempty-or
                    "TYPELISP_CODEGEN_CASES_ROOT"
                    (& cwd-fallback))]
                [native-root : String
                  (env-nonempty-or
                    "TYPELISP_CODEGEN_CASES_NATIVE_ROOT"
                    (& root))]
                [compiler : String
                  (env-or "TYPELISP_CODEGEN_CASES_COMPILER" "")]
                [host : String
                  (env-nonempty-or
                    "TYPELISP_CODEGEN_CASES_HOST"
                    (util.host-name))]
                [host-target : String
                  (str_cat.str-cat (string.copy (& host)) "-x86_64")]
                [exe-ext : String
                  (if (string.eq (& host) "windows")
                    ".exe"
                    "")]
                [lib-prefix : String
                  (if (string.eq (& host) "windows")
                    ""
                    "lib")]
                [lib-suffix : String
                  (if (string.eq (& host) "windows")
                    ".lib"
                    ".a")]
                [isas-raw : String
                  (env-or "TYPELISP_CODEGEN_CASES_NATIVE_ISAS" "")]
                [native-isas : svec.Vec (util.split-words-blank (& isas-raw))]
                [sde-bin : String (env-or "TYPELISP_SDE_BIN" "")]
                [sde-policy : String
                  (env-nonempty-or "TYPELISP_AVX512_EXECUTION" "auto")]
                [simd-filter : String (env-or "TYPELISP_SIMD_MODE_FILTER" "")]
                [timing-file : String (env-or "TYPELISP_CI_TIMING_FILE" "")]
                [timing-on : bool
                  (and
                    (string.eq (env-or "TYPELISP_CI_TIMING" "0") "1")
                    (> (string.string-length (& timing-file)) 0))]
                [timing-gate : String
                  (env-nonempty-or "TYPELISP_CI_TIMING_GATE" "ungated")]
                [timing-host : String
                  (env-nonempty-or "TYPELISP_CI_TIMING_HOST" "unknown")]
                [sh-bin : String
                  (env-nonempty-or "TYPELISP_CODEGEN_CASES_SH" "sh")]
                [work-root : String
                  (env-nonempty-or
                    "CODEGEN_CASES_WORKDIR"
                    (str_cat.str-cat
                      (string.copy (& root))
                      "/target/codegen-cases"))]
                [work-suffix : String
                  (if (string.eq (& only-glob) "*")
                    ""
                    (str_cat.str-cat
                      ".only-"
                      (util.sanitize-only-suffix (& only-glob))))]
                [workers : i64 (default-workers)]
                [total-failures : i64 0]
                [total-rows : i64 0]
                [total-skipped : i64 0]
                [total-selected : i64 0]
                [total-mode-selected : i64 0]
                [total-simd-native : i64 0]
                [total-simd-emulated : i64 0]
                [total-simd-skipped : i64 0]
                [fi : i64 0]
                [fatal-exit : i64 0]
                (set!
                  wave-cfg
                  (exec.RunnerConfig
                    (string.copy (& root))
                    (string.copy (& native-root))
                    compiler
                    host
                    host-target
                    exe-ext
                    lib-prefix
                    lib-suffix
                    native-isas
                    sde-bin
                    sde-policy
                    simd-filter
                    timing-on
                    timing-file
                    timing-gate
                    timing-host
                    sh-bin))
                (while (and (= fatal-exit 0) (< fi nfiles))
                  (let
                    [cfile : String (svec.get (& parsed.positionals) fi "")]
                    (if (not (util.is-regular-file? (& cfile)))
                      (begin
                        (io.print-error
                          (str_cat.str-cat "missing case file: " cfile "\n"))
                        (set! fatal-exit 2))
                      (let
                        [pf : parser.ParsedFile
                          (parser.parse-cases-file
                            (& cfile)
                            (& root)
                            do-fixtures)]
                        (if (not pf.ok)
                          (begin
                            (io.print-error (str_cat.str-cat pf.error "\n"))
                            (set! fatal-exit 2))
                          (cond
                            [do-fixtures
                              (io.stdout-write
                                (byte_buf.str-as-bytes (& pf.fixtures-output)))]
                            [do-list
                              (let
                                [listing : String (parser.render-list (& pf))]
                                (io.stdout-write
                                  (byte_buf.str-as-bytes (& listing))))]
                            [else
                              (let
                                [base-name : String
                                  (util.path-basename-strip-cases (& cfile))]
                                [work-dir : String
                                  (str_cat.str-cat
                                    (string.copy (& work-root))
                                    "/"
                                    base-name
                                    (string.copy (& work-suffix)))]
                                [native-work-dir : String
                                  (util.to-native-path
                                    (& work-dir)
                                    (& root)
                                    (& native-root))]
                                [pre-vars : util.VarTable (util.var-table-new)]
                                (util.rm-rf! (& work-dir))
                                (util.ensure-dir! (& work-dir))
                                (io.stdout-write
                                  (byte_buf.str-as-bytes
                                    (str_cat.str-cat
                                      "[codegen-cases] "
                                      (string.copy (& cfile))
                                      "\n")))
                                ;; Write pre-case file blocks once relative to {{work}}
                                (util.var-table-set!
                                  (&mut pre-vars)
                                  "root"
                                  (& root))
                                (util.var-table-set!
                                  (&mut pre-vars)
                                  "native-root"
                                  (& native-root))
                                (util.var-table-set!
                                  (&mut pre-vars)
                                  "work"
                                  (& work-dir))
                                (util.var-table-set!
                                  (&mut pre-vars)
                                  "native-work"
                                  (& native-work-dir))
                                (util.var-table-set!
                                  (&mut pre-vars)
                                  "host"
                                  (& wave-cfg.host))
                                (util.var-table-set!
                                  (&mut pre-vars)
                                  "host-target"
                                  (& wave-cfg.host-target))
                                (util.var-table-set!
                                  (&mut pre-vars)
                                  "exe"
                                  (& wave-cfg.exe-ext))
                                (util.var-table-set!
                                  (&mut pre-vars)
                                  "lib-prefix"
                                  (& wave-cfg.lib-prefix))
                                (util.var-table-set!
                                  (&mut pre-vars)
                                  "lib-suffix"
                                  (& wave-cfg.lib-suffix))
                                (util.var-table-set!
                                  (&mut pre-vars)
                                  "compiler"
                                  (& wave-cfg.compiler))
                                (let
                                  [npf : i64
                                    (parser.parsed-pre-files-len (& pf))]
                                  [pi : i64 0]
                                  (while (< pi npf)
                                    (let
                                      [fb : parser.FileBlock
                                        (parser.parsed-pre-files-get (& pf) pi)]
                                      (exec.write-file-block!
                                        (& pre-vars)
                                        (& work-dir)
                                        (& fb.path)
                                        (& fb.flags)
                                        (& fb.content)))
                                    (set! pi (+ pi 1))))
                                ;; Build variant job list (applying --only, hosts, and SIMD_MODE_FILTER)
                                (let
                                  [jobs : jobvec.Vec (jobvec.new)]
                                  [nc : i64 (parser.parsed-cases-len (& pf))]
                                  [ci : i64 0]
                                  (while (< ci nc)
                                    (let
                                      [cdef : parser.CaseDef
                                        (parser.parsed-cases-get (& pf) ci)]
                                      (when
                                        (util.glob-match?
                                          (& only-glob)
                                          (& cdef.id))
                                        (set!
                                          total-selected
                                          (+ total-selected 1))
                                        (if (not
                                          (or
                                            (exec.word-in-list?
                                              "all"
                                              (& cdef.hosts))
                                            (exec.word-in-list?
                                              (& wave-cfg.host)
                                              (& cdef.hosts))))
                                          (io.stdout-write
                                            (byte_buf.str-as-bytes
                                              (str_cat.str-cat
                                                "[codegen-cases] skip "
                                                (string.copy (& cdef.id))
                                                " (hosts: "
                                                (string.copy (& cdef.hosts))
                                                ")\n")))
                                          (let
                                            [ts : svec.Vec
                                              (util.split-words-blank
                                                (& cdef.target))]
                                            [os : svec.Vec
                                              (util.split-words-blank
                                                (& cdef.opt))]
                                            [ms : svec.Vec
                                              (util.split-words-blank
                                                (& cdef.mode))]
                                            [es : svec.Vec
                                              (util.split-words-blank
                                                (& cdef.each))]
                                            [nt : i64 (svec.len (& ts))]
                                            [no : i64 (svec.len (& os))]
                                            [nm : i64 (svec.len (& ms))]
                                            [ne : i64 (svec.len (& es))]
                                            [ti : i64 0]
                                            (while (< ti nt)
                                              (let
                                                [t : String
                                                  (svec.get (& ts) ti "")]
                                                [oi : i64 0]
                                                (while (< oi no)
                                                  (let
                                                    [o : String
                                                      (svec.get (& os) oi "")]
                                                    [mi : i64 0]
                                                    (while (< mi nm)
                                                      (let
                                                        [m : String
                                                          (svec.get
                                                            (& ms)
                                                            mi
                                                            "")]
                                                        [ei : i64 0]
                                                        (while (< ei ne)
                                                          (let
                                                            [e : String
                                                              (svec.get
                                                                (& es)
                                                                ei
                                                                "")]
                                                            (if (not
                                                              (exec.simd-mode-selected?
                                                                (& wave-cfg)
                                                                (& m)))
                                                              (when
                                                                (string.eq
                                                                  (& m)
                                                                  "-")
                                                                (set!
                                                                  total-failures
                                                                  (+
                                                                    total-failures
                                                                    1))
                                                                (io.print-error
                                                                  (str_cat.str-cat
                                                                    "FAIL "
                                                                    (string.copy
                                                                      (& cfile))
                                                                    ":"
                                                                    (string.int->string
                                                                      cdef.line)
                                                                    " "
                                                                    (string.copy
                                                                      (&
                                                                        cdef.id))
                                                                    " ["
                                                                    (exec.variant-name-of
                                                                      (& t)
                                                                      (& o)
                                                                      (& m)
                                                                      (& e))
                                                                    "]: cannot determine the backend mode under TYPELISP_SIMD_MODE_FILTER="
                                                                    (string.copy
                                                                      (&
                                                                        wave-cfg.simd-mode-filter))
                                                                    "\n")))
                                                              (begin
                                                                (set!
                                                                  total-mode-selected
                                                                  (+
                                                                    total-mode-selected
                                                                    1))
                                                                (jobvec.push-ref!
                                                                  (&mut jobs)
                                                                  (VariantJob
                                                                    ci
                                                                    (string.copy
                                                                      (& t))
                                                                    (string.copy
                                                                      (& o))
                                                                    (string.copy
                                                                      (& m))
                                                                    e
                                                                    cdef.needs-barrier)))))
                                                          (set! ei (+ ei 1))))
                                                      (set! mi (+ mi 1))))
                                                  (set! oi (+ oi 1))))
                                              (set! ti (+ ti 1)))))))
                                    (set! ci (+ ci 1)))
                                  ;; Publish read-only wave state and execute in barrier-respecting parallel waves
                                  (let
                                    [njobs : i64 (jobvec.len (& jobs))]
                                    [results : resvec.Vec
                                      (resvec.with-capacity njobs)]
                                    [ri : i64 0]
                                    (while (< ri njobs)
                                      (resvec.push-ref!
                                        (&mut results)
                                        (exec.VariantResult
                                          ri
                                          0
                                          0
                                          0
                                          0
                                          0
                                          0
                                          ""
                                          ""))
                                      (set! ri (+ ri 1)))
                                    (set! wave-file pf)
                                    (set! wave-work-dir work-dir)
                                    (set! wave-native-work-dir native-work-dir)
                                    (set! wave-jobs jobs)
                                    (let
                                      [wi : i64 0]
                                      (while (< wi njobs)
                                        (let
                                          [cur-job : VariantJob
                                            (jobvec.get
                                              (& wave-jobs)
                                              wi
                                              (VariantJob 0 "" "" "" "" false))]
                                          (if cur-job.needs-barrier
                                            (begin
                                              (run-wave!
                                                wi
                                                (+ wi 1)
                                                1
                                                (&mut results))
                                              (set! wi (+ wi 1)))
                                            (let
                                              [wj : i64 (+ wi 1)]
                                              (while (and
                                                (< wj njobs)
                                                (not
                                                  (jobvec.get
                                                    (& wave-jobs)
                                                    wj
                                                    (VariantJob
                                                      0
                                                      ""
                                                      ""
                                                      ""
                                                      ""
                                                      false)).needs-barrier))
                                                (set! wj (+ wj 1)))
                                              (run-wave!
                                                wi
                                                wj
                                                workers
                                                (&mut results))
                                              (set! wi wj))))))
                                    ;; Flush outputs in deterministic job order and aggregate counters
                                    (let
                                      [ji : i64 0]
                                      (while (< ji njobs)
                                        (let
                                          [r : exec.VariantResult
                                            (resvec.get
                                              (& results)
                                              ji
                                              (exec.VariantResult
                                                0
                                                0
                                                0
                                                0
                                                0
                                                0
                                                0
                                                ""
                                                ""))]
                                          (when
                                            (>
                                              (string.string-length
                                                (& r.stderr-log))
                                              0)
                                            (io.print-error (& r.stderr-log)))
                                          (when
                                            (>
                                              (string.string-length
                                                (& r.stdout-log))
                                              0)
                                            (io.stdout-write
                                              (byte_buf.str-as-bytes
                                                (& r.stdout-log))))
                                          (set!
                                            total-failures
                                            (+ total-failures r.failures))
                                          (set!
                                            total-rows
                                            (+ total-rows r.rows))
                                          (set!
                                            total-skipped
                                            (+ total-skipped r.skipped))
                                          (set!
                                            total-simd-native
                                            (+ total-simd-native r.simd-native))
                                          (set!
                                            total-simd-emulated
                                            (+
                                              total-simd-emulated
                                              r.simd-emulated))
                                          (set!
                                            total-simd-skipped
                                            (+
                                              total-simd-skipped
                                              r.simd-skipped)))
                                        (set! ji (+ ji 1)))))))]))))
                    (set! fi (+ fi 1))))
                (cond
                  [(!= fatal-exit 0) fatal-exit]
                  [do-list 0]
                  [(= total-selected 0)
                    (io.print-error
                      (str_cat.str-cat
                        "[codegen-cases] no case matches --only "
                        only-glob
                        "\n"))
                    1]
                  [(and
                    (> (string.string-length (& wave-cfg.simd-mode-filter)) 0)
                    (= total-mode-selected 0))
                    (io.print-error
                      (str_cat.str-cat
                        "[codegen-cases] TYPELISP_SIMD_MODE_FILTER="
                        (string.copy (& wave-cfg.simd-mode-filter))
                        " selected no case variant\n"))
                    1]
                  [(> total-failures 0)
                    (io.print-error
                      (str_cat.str-cat
                        "[codegen-cases] FAILED: "
                        (string.int->string total-failures)
                        " failure(s); "
                        (string.int->string total-rows)
                        " expectation(s) checked, "
                        (string.int->string total-skipped)
                        " skipped\n"))
                    1]
                  [else
                    (io.stdout-write
                      (byte_buf.str-as-bytes
                        (str_cat.str-cat
                          "[simd-execution] codegen-cases avx512 executed="
                          (string.int->string
                            (+ total-simd-native total-simd-emulated))
                          " native="
                          (string.int->string total-simd-native)
                          " emulated="
                          (string.int->string total-simd-emulated)
                          " skipped="
                          (string.int->string total-simd-skipped)
                          "\n")))
                    (io.stdout-write
                      (byte_buf.str-as-bytes
                        (str_cat.str-cat
                          "[codegen-cases] passed: "
                          (string.int->string total-rows)
                          " expectation(s) checked, "
                          (string.int->string total-skipped)
                          " skipped\n")))
                    0])))))])))