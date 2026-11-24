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

;; Decode worker payload strictly, marking each decoded job index in `completed`
;; (indexed relative to `start`). Returns false if any record is malformed,
;; out-of-range, duplicated, or truncated.
(define (decode-worker-results!
  [start : i64]
  [end : i64]
  [payload : (& payload str)]
  [results : (&mut results resvec.Vec)]
  [completed : (&mut completed ivec.Vec)]) : bool
  (let
    [n : i64 (string.string-length payload)]
    [pos : i64 0]
    [ok : bool true]
    (while (and ok (< pos n))
      (let
        [nl : i64 (util.index-of-byte-from payload pos 10)]
        (if (< nl 0)
          (set! ok false)
          (let
            [hdr : String (string.substring payload pos (- nl pos))]
            [cols : svec.Vec (util.split-by-sep (& hdr) "\t")]
            (if (!= (svec.len (& cols)) 9)
              (set! ok false)
              (let
                [p0 : util.ParsedI64
                  (util.parse-i64-strict (svec.get (& cols) 0 ""))]
                [p1 : util.ParsedI64
                  (util.parse-i64-strict (svec.get (& cols) 1 ""))]
                [p2 : util.ParsedI64
                  (util.parse-i64-strict (svec.get (& cols) 2 ""))]
                [p3 : util.ParsedI64
                  (util.parse-i64-strict (svec.get (& cols) 3 ""))]
                [p4 : util.ParsedI64
                  (util.parse-i64-strict (svec.get (& cols) 4 ""))]
                [p5 : util.ParsedI64
                  (util.parse-i64-strict (svec.get (& cols) 5 ""))]
                [p6 : util.ParsedI64
                  (util.parse-i64-strict (svec.get (& cols) 6 ""))]
                [p7 : util.ParsedI64
                  (util.parse-u64-strict (svec.get (& cols) 7 ""))]
                [p8 : util.ParsedI64
                  (util.parse-u64-strict (svec.get (& cols) 8 ""))]
                (if (not
                  (and p0.ok p1.ok p2.ok p3.ok p4.ok p5.ok p6.ok p7.ok p8.ok))
                  (set! ok false)
                  (let
                    [vidx : i64 p0.value]
                    [olen : i64 p7.value]
                    [elen : i64 p8.value]
                    [ostart : i64 (+ nl 1)]
                    [estart : i64 (+ ostart olen)]
                    [next-pos : i64 (+ estart elen)]
                    (if (or
                      (< vidx start)
                      (>= vidx end)
                      (> next-pos n)
                      (!= (ivec.get completed (- vidx start) 0) 0))
                      (set! ok false)
                      (let
                        [out-s : String (string.substring payload ostart olen)]
                        [err-s : String (string.substring payload estart elen)]
                        (resvec.set-ref!
                          results
                          vidx
                          (exec.VariantResult
                            vidx
                            p1.value
                            p2.value
                            p3.value
                            p4.value
                            p5.value
                            p6.value
                            out-s
                            err-s))
                        (ivec.set-ref! completed (- vidx start) 1)
                        (set! pos next-pos)))))))))))
    ok))

;; Fail closed for any job in [start, end) that did not complete cleanly, or if
;; any worker join or payload decode reported an error.
(define (finalize-wave-results!
  [start : i64]
  [end : i64]
  [join-err : bool]
  [decode-err : bool]
  [completed : (& completed ivec.Vec)]
  [results : (&mut results resvec.Vec)]) : unit
  (let
    [count : i64 (- end start)]
    [missing : i64 0]
    [j : i64 0]
    (while (< j count)
      (when
        (= (ivec.get completed j 0) 0)
        (set! missing (+ missing 1))
        (let
          [vidx : i64 (+ start j)]
          [reason : String
            (cond
              [(and join-err decode-err)
                "worker join error and malformed worker payload"]
              [join-err "worker thread join failed"]
              [decode-err "truncated or malformed worker payload"]
              [else "worker exited without reporting job result"])]
          (resvec.set-ref!
            results
            vidx
            (exec.VariantResult
              vidx
              1
              0
              0
              0
              0
              0
              ""
              (str_cat.str-cat
                "FAIL: codegen-cases worker did not complete job "
                (string.int->string vidx)
                " ("
                reason
                ")\n")))))
      (set! j (+ j 1)))
    (when
      (and (> count 0) (= missing 0) (or join-err decode-err))
      (let
        [first : exec.VariantResult
          (resvec.get
            results
            start
            (exec.VariantResult start 0 0 0 0 0 0 "" ""))]
        [reason : String
          (if join-err
            "worker thread join failed"
            "truncated or malformed worker payload")]
        (resvec.set-ref!
          results
          start
          (exec.VariantResult
            first.index
            (+ first.failures 1)
            first.rows
            first.skipped
            first.simd-native
            first.simd-emulated
            first.simd-skipped
            first.stdout-log
            (str_cat.str-cat
              first.stderr-log
              "FAIL: codegen-cases wave error ("
              reason
              ")\n")))))))

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
        [completed : ivec.Vec (ivec.with-capacity count)]
        [ci : i64 0]
        [join-err : bool false]
        [decode-err : bool false]
        [w : i64
          (if (< count workers)
            count
            workers)]
        (while (< ci count)
          (ivec.push-ref! (&mut completed) 0)
          (set! ci (+ ci 1)))
        (set! wave-next-idx start)
        (set! wave-end-idx end)
        (if (<= w 1)
          (let
            [i : i64 start]
            (while (< i end)
              (let
                [enc : String (run-job-in-scratch i)]
                (when
                  (not
                    (decode-worker-results!
                      start
                      end
                      (& enc)
                      results
                      (&mut completed)))
                  (set! decode-err true)))
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
                (when
                  (not
                    (decode-worker-results!
                      start
                      end
                      (& extra)
                      results
                      (&mut completed)))
                  (set! decode-err true))))
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
                      (when
                        (not
                          (decode-worker-results!
                            start
                            end
                            (& payload)
                            results
                            (&mut completed)))
                        (set! decode-err true))]
                    [(thread.ThreadStringJoinErr _) (set! join-err true)]))
                (set! k (+ k 1))))))
        (finalize-wave-results!
          start
          end
          join-err
          decode-err
          (& completed)
          results)))))

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

(define (self-test-find-case [pf : (& pf parser.ParsedFile)] [id : (& id str)]) : parser.CaseDef
  (let
    [n : i64 (parser.parsed-cases-len pf)]
    [i : i64 0]
    [found : parser.CaseDef (parser.parsed-cases-get pf 0)]
    [matched : bool false]
    (while (and (not matched) (< i n))
      (let
        [c : parser.CaseDef (parser.parsed-cases-get pf i)]
        (if (string.eq (& c.id) id)
          (begin
            (set! found c)
            (set! matched true))
          (set! i (+ i 1)))))
    found))

(define (self-test-run-case
  [cfg : (& cfg exec.RunnerConfig)]
  [pf : (& pf parser.ParsedFile)]
  [work-dir : (& work-dir str)]
  [id : (& id str)]) : exec.VariantResult
  (let
    [cdef : parser.CaseDef (self-test-find-case pf id)]
    (exec.run-single-variant
      cfg
      (& pf.file-path)
      work-dir
      work-dir
      (& cdef)
      "-"
      "-"
      "-"
      "-"
      0)))

(define (self-test-runner-fixes) : i64
  (let
    [fails : i64 0]
    [tmp-res : io.ResultIoString (fs.try-create-temp-dir "cc-runner-selftest")]
    (match tmp-res
      [(io.ErrIoString _)
        (io.print-error "SELF-TEST FAIL: could not create temp dir\n")
        1]
      [(io.OkIoString tmp-dir)
        (let
          [sh-bin : String (env-nonempty-or "TYPELISP_CODEGEN_CASES_SH" "sh")]
          [cfg : exec.RunnerConfig
            (exec.RunnerConfig
              (string.copy (& tmp-dir))
              (string.copy (& tmp-dir))
              ""
              (util.host-name)
              (str_cat.str-cat (util.host-name) "-x86_64")
              (if (util.host-is-windows?)
                ".exe"
                "")
              (if (util.host-is-windows?)
                ""
                "lib")
              (if (util.host-is-windows?)
                ".lib"
                ".a")
              (svec.new)
              ""
              "auto"
              ""
              false
              ""
              ""
              ""
              (string.copy (& sh-bin)))]
          [work-dir : String
            (str_cat.str-cat (string.copy (& tmp-dir)) "/work")]
          (util.ensure-dir! (& work-dir))
          ;; Finding 1: barrier analysis across setups, args, source, all row kinds,
          ;; {{native-work}}/, and pre-file mutations.
          (let
            [b-path : String
              (str_cat.str-cat (string.copy (& tmp-dir)) "/barrier.cases")]
            [b-text : String
              (str_cat.str-cat
                "file pre.tl\n(define (main) : i64 0)\nend-file\n\n"
                "case read-pre-source\nsource {{work}}/pre.tl\nstderr contains {{native-work}}/pre.tl:1:\n\n"
                "case read-pre-run\ndo none\nrun check \"{{work}}/pre.tl\"\n\n"
                "case nonpre-source\nsource {{work}}/other.tl\n\n"
                "case nonpre-args\nsource {{work}}/pre.tl\nargs --stdlib-root {{work}}/stdlib-root\n\n"
                "case nonpre-native-in\ndo none\nin file {{native-work}}/gen.txt\ncontains ok\n\n"
                "case nonpre-prefix-collision\nsource {{work}}/pre.tl.out\n\n"
                "case nonpre-run\ndo none\nrun check {{work}}/other.tl\n\n"
                "case nonpre-exec\ndo none\nexec cat {{work}}/other.tl\n\n"
                "case nonpre-same\ndo none\nsame {{work}}/other.tl {{dir}}/a\n\n"
                "case nonpre-test\ndo none\ntest -f {{work}}/other.tl\n\n"
                "case nonpre-cwd\ndo none\ncwd {{work}}/sub\n\n"
                "case setup-prefile\nsetup dummy {{work}}/pre.tl\ndo none\n\n"
                "case file-prefile\ndo none\nfile {{work}}/pre.tl\noverwrite\nend-file\n\n"
                "case sh-prefile\ndo none\nsh rm {{work}}/pre.tl\n\n"
                "case sh-native-prefile\ndo none\nsh rm {{native-work}}/pre.tl\n")]
            (util.write-file! (& b-path) (& b-text))
            (let
              [pf : parser.ParsedFile
                (parser.parse-cases-file (& b-path) (& tmp-dir) false)]
              (set!
                fails
                (+ fails (assert-eq-bool "barrier parse ok" pf.ok true)))
              (when
                pf.ok
                (set!
                  fails
                  (+
                    fails
                    (assert-eq-bool
                      "barrier read-pre-source"
                      (self-test-find-case (& pf) "read-pre-source").needs-barrier
                      false)))
                (set!
                  fails
                  (+
                    fails
                    (assert-eq-bool
                      "barrier read-pre-run"
                      (self-test-find-case (& pf) "read-pre-run").needs-barrier
                      false)))
                (set!
                  fails
                  (+
                    fails
                    (assert-eq-bool
                      "barrier nonpre-source"
                      (self-test-find-case (& pf) "nonpre-source").needs-barrier
                      true)))
                (set!
                  fails
                  (+
                    fails
                    (assert-eq-bool
                      "barrier nonpre-args"
                      (self-test-find-case (& pf) "nonpre-args").needs-barrier
                      true)))
                (set!
                  fails
                  (+
                    fails
                    (assert-eq-bool
                      "barrier nonpre-native-in"
                      (self-test-find-case (& pf) "nonpre-native-in").needs-barrier
                      true)))
                (set!
                  fails
                  (+
                    fails
                    (assert-eq-bool
                      "barrier nonpre-prefix-collision"
                      (self-test-find-case (& pf) "nonpre-prefix-collision").needs-barrier
                      true)))
                (set!
                  fails
                  (+
                    fails
                    (assert-eq-bool
                      "barrier nonpre-run"
                      (self-test-find-case (& pf) "nonpre-run").needs-barrier
                      true)))
                (set!
                  fails
                  (+
                    fails
                    (assert-eq-bool
                      "barrier nonpre-exec"
                      (self-test-find-case (& pf) "nonpre-exec").needs-barrier
                      true)))
                (set!
                  fails
                  (+
                    fails
                    (assert-eq-bool
                      "barrier nonpre-same"
                      (self-test-find-case (& pf) "nonpre-same").needs-barrier
                      true)))
                (set!
                  fails
                  (+
                    fails
                    (assert-eq-bool
                      "barrier nonpre-test"
                      (self-test-find-case (& pf) "nonpre-test").needs-barrier
                      true)))
                (set!
                  fails
                  (+
                    fails
                    (assert-eq-bool
                      "barrier nonpre-cwd"
                      (self-test-find-case (& pf) "nonpre-cwd").needs-barrier
                      true)))
                (set!
                  fails
                  (+
                    fails
                    (assert-eq-bool
                      "barrier setup-prefile"
                      (self-test-find-case (& pf) "setup-prefile").needs-barrier
                      true)))
                (set!
                  fails
                  (+
                    fails
                    (assert-eq-bool
                      "barrier file-prefile"
                      (self-test-find-case (& pf) "file-prefile").needs-barrier
                      true)))
                (set!
                  fails
                  (+
                    fails
                    (assert-eq-bool
                      "barrier sh-prefile"
                      (self-test-find-case (& pf) "sh-prefile").needs-barrier
                      true)))
                (set!
                  fails
                  (+
                    fails
                    (assert-eq-bool
                      "barrier sh-native-prefile"
                      (self-test-find-case (& pf) "sh-native-prefile").needs-barrier
                      true))))))
          ;; Finding 2: same-metric fails closed on unknown metrics / missing fns and splits NAME:ARG.
          (let
            [asm-a : String
              ".globl fn\nfn:\n    pushq %r12\n    pushq %r13\n    popq %r13\n    popq %r12\n    ret\n.size fn, .-fn\n"]
            [asm-b : String
              ".globl fn\nfn:\n    pushq %r12\n    popq %r12\n    ret\n.size fn, .-fn\n"]
            [a-file : String (str_cat.str-cat (string.copy (& tmp-dir)) "/a.s")]
            [b-file : String (str_cat.str-cat (string.copy (& tmp-dir)) "/b.s")]
            (util.write-file! (& a-file) (& asm-a))
            (util.write-file! (& b-file) (& asm-b))
            (set!
              fails
              (+
                fails
                (assert-eq-i64
                  "same-metric rejects unknown metric"
                  (exec.check-same-metric-asm
                    (& asm-a)
                    (& a-file)
                    "fn"
                    "nonexistent-metric")
                  1)))
            (set!
              fails
              (+
                fails
                (assert-eq-i64
                  "same-metric rejects missing fn"
                  (exec.check-same-metric-asm
                    (& asm-a)
                    (& a-file)
                    "no_such_fn"
                    "csr-pushes")
                  1)))
            (set!
              fails
              (+
                fails
                (assert-eq-i64
                  "same-metric NAME:ARG match"
                  (exec.check-same-metric-asm
                    (& asm-a)
                    (& a-file)
                    "fn"
                    "distinct:%r1[23]")
                  0)))
            (set!
              fails
              (+
                fails
                (assert-eq-i64
                  "same-metric NAME:ARG diff"
                  (exec.check-same-metric-asm
                    (& asm-a)
                    (& b-file)
                    "fn"
                    "distinct:%r1[23]")
                  1))))
          ;; Finding 3, 4a, 4b, 5: runtime execution checks via run-single-variant.
          (let
            [r-path : String
              (str_cat.str-cat (string.copy (& tmp-dir)) "/runtime.cases")]
            [r-text : String
              (str_cat.str-cat
                "case simd-native-unavail\ndo none\nexec simd_execute avx512 true\nexit 1\n\n"
                "case simd-native-unavail-fail\ndo none\nexec simd_execute avx512 true\nexit 0\n\n"
                "case simd-shell-unavail\ndo none\nexec simd_execute avx512 true && true\nexit 1\n\n"
                "case simd-scalar-ok\ndo none\nexec simd_execute scalar \""
                (string.copy (& sh-bin))
                "\" -c \"exit 0\"\nexit 0\n\n"
                "case exit-bad-int\ndo none\nexec \""
                (string.copy (& sh-bin))
                "\" -c \"exit 0\"\nexit 0a\n\n"
                "case not-match-bad-re\ndo none\nexec \""
                (string.copy (& sh-bin))
                "\" -c \"printf hello\"\nstdout not-match [unclosed\n\n"
                "case match-bad-re\ndo none\nexec \""
                (string.copy (& sh-bin))
                "\" -c \"printf hello\"\nstdout match [unclosed\n\n"
                "case count-bad-re\ndo none\nexec \""
                (string.copy (& sh-bin))
                "\" -c \"printf hello\"\nstdout count = 0 [unclosed\n\n"
                "case next-line-bad-re\ndo none\nexec \""
                (string.copy (& sh-bin))
                "\" -c \"printf 'a\\nb\\n'\"\nstdout after [unclosed\nnext-line b\n\n"
                "case capture-bad-re\ndo none\nexec \""
                (string.copy (& sh-bin))
                "\" -c \"printf hello\"\nstdout capture x [unclosed\n\n"
                "case sh-source-fail\ndo none\nfile bad.sh\nexit 1\nend-file\nsh . \"{{dir}}/bad.sh\"\n\n"
                "case sh-source-exec-fn\ndo none\nfile good.sh\ncc_st_fn() { printf 'sourced-fn-ok\\n'; }\nend-file\nsh . \"{{dir}}/good.sh\"\nexec cc_st_fn\nexit 0\nstdout is sourced-fn-ok\n\n"
                "case sh-mkdir-existing-fails\ndo none\nsh mkdir \"{{dir}}/d1\"\nsh mkdir \"{{dir}}/d1\"\n\n"
                "case sh-mkdir-p-ok\ndo none\nsh mkdir -p \"{{dir}}/d1\"\nsh mkdir -p \"{{dir}}/d1\"\n\n"
                "case sh-rm-r-missing-fails\ndo none\nsh rm -r \"{{dir}}/no-such-dir\"\n\n"
                "case sh-rm-rf-missing-ok\ndo none\nsh rm -rf \"{{dir}}/no-such-dir\"\n\n"
                "case sh-cp-exec-and-p\ndo none\nfile runme.sh\n#!/bin/sh\nexit 0\nend-file\nsh chmod +x \"{{dir}}/runme.sh\"\nsh cp \"{{dir}}/runme.sh\" \"{{dir}}/runme_copy.sh\"\nsh cp -p \"{{dir}}/runme.sh\" \"{{dir}}/runme_copy_p.sh\"\ntest -x \"{{dir}}/runme_copy.sh\"\ntest -x \"{{dir}}/runme_copy_p.sh\"\n\n"
                "case sh-mv-into-dir\ndo none\nfile item.txt\nhello\nend-file\nsh mkdir \"{{dir}}/dest\"\nsh mv \"{{dir}}/item.txt\" \"{{dir}}/dest\"\ntest -f \"{{dir}}/dest/item.txt\"\ntest ! -e \"{{dir}}/item.txt\"\n")]
            (util.write-file! (& r-path) (& r-text))
            (let
              [pf : parser.ParsedFile
                (parser.parse-cases-file (& r-path) (& tmp-dir) false)]
              (set!
                fails
                (+ fails (assert-eq-bool "runtime cases parse ok" pf.ok true)))
              (when
                pf.ok
                (set!
                  fails
                  (+
                    fails
                    (assert-eq-i64
                      "simd native unavailable exits 1"
                      (self-test-run-case
                        (& cfg)
                        (& pf)
                        (& work-dir)
                        "simd-native-unavail").failures
                      0)))
                (set!
                  fails
                  (+
                    fails
                    (assert-eq-i64
                      "simd native unavailable fails exit 0"
                      (self-test-run-case
                        (& cfg)
                        (& pf)
                        (& work-dir)
                        "simd-native-unavail-fail").failures
                      1)))
                (set!
                  fails
                  (+
                    fails
                    (assert-eq-i64
                      "simd shell unavailable exits 1"
                      (self-test-run-case
                        (& cfg)
                        (& pf)
                        (& work-dir)
                        "simd-shell-unavail").failures
                      0)))
                (set!
                  fails
                  (+
                    fails
                    (assert-eq-i64
                      "simd scalar native succeeds"
                      (self-test-run-case
                        (& cfg)
                        (& pf)
                        (& work-dir)
                        "simd-scalar-ok").failures
                      0)))
                (set!
                  fails
                  (+
                    fails
                    (assert-eq-i64
                      "exit 0a fails closed"
                      (self-test-run-case
                        (& cfg)
                        (& pf)
                        (& work-dir)
                        "exit-bad-int").failures
                      1)))
                (set!
                  fails
                  (+
                    fails
                    (assert-eq-i64
                      "not-match invalid regex fails closed"
                      (self-test-run-case
                        (& cfg)
                        (& pf)
                        (& work-dir)
                        "not-match-bad-re").failures
                      1)))
                (set!
                  fails
                  (+
                    fails
                    (assert-eq-i64
                      "match invalid regex fails closed"
                      (self-test-run-case
                        (& cfg)
                        (& pf)
                        (& work-dir)
                        "match-bad-re").failures
                      1)))
                (set!
                  fails
                  (+
                    fails
                    (assert-eq-i64
                      "count invalid regex fails closed"
                      (self-test-run-case
                        (& cfg)
                        (& pf)
                        (& work-dir)
                        "count-bad-re").failures
                      1)))
                (set!
                  fails
                  (+
                    fails
                    (assert-eq-i64
                      "next-line invalid regex fails closed"
                      (self-test-run-case
                        (& cfg)
                        (& pf)
                        (& work-dir)
                        "next-line-bad-re").failures
                      1)))
                (set!
                  fails
                  (+
                    fails
                    (assert-eq-i64
                      "capture invalid regex fails closed"
                      (self-test-run-case
                        (& cfg)
                        (& pf)
                        (& work-dir)
                        "capture-bad-re").failures
                      1)))
                (set!
                  fails
                  (+
                    fails
                    (assert-eq-i64
                      "sh . failing script fails"
                      (self-test-run-case
                        (& cfg)
                        (& pf)
                        (& work-dir)
                        "sh-source-fail").failures
                      1)))
                (set!
                  fails
                  (+
                    fails
                    (assert-eq-i64
                      "sh . enables sourced fn in exec"
                      (self-test-run-case
                        (& cfg)
                        (& pf)
                        (& work-dir)
                        "sh-source-exec-fn").failures
                      0)))
                (set!
                  fails
                  (+
                    fails
                    (assert-eq-i64
                      "sh mkdir without -p fails on existing"
                      (self-test-run-case
                        (& cfg)
                        (& pf)
                        (& work-dir)
                        "sh-mkdir-existing-fails").failures
                      1)))
                (set!
                  fails
                  (+
                    fails
                    (assert-eq-i64
                      "sh mkdir -p ok on existing"
                      (self-test-run-case
                        (& cfg)
                        (& pf)
                        (& work-dir)
                        "sh-mkdir-p-ok").failures
                      0)))
                (set!
                  fails
                  (+
                    fails
                    (assert-eq-i64
                      "sh rm -r without -f fails on missing"
                      (self-test-run-case
                        (& cfg)
                        (& pf)
                        (& work-dir)
                        "sh-rm-r-missing-fails").failures
                      1)))
                (set!
                  fails
                  (+
                    fails
                    (assert-eq-i64
                      "sh rm -rf ok on missing"
                      (self-test-run-case
                        (& cfg)
                        (& pf)
                        (& work-dir)
                        "sh-rm-rf-missing-ok").failures
                      0)))
                (set!
                  fails
                  (+
                    fails
                    (assert-eq-i64
                      "sh cp preserves executable and -p"
                      (self-test-run-case
                        (& cfg)
                        (& pf)
                        (& work-dir)
                        "sh-cp-exec-and-p").failures
                      0)))
                (set!
                  fails
                  (+
                    fails
                    (assert-eq-i64
                      "sh mv into existing dir"
                      (self-test-run-case
                        (& cfg)
                        (& pf)
                        (& work-dir)
                        "sh-mv-into-dir").failures
                      0))))))
          ;; Finding 4c: wave decode & join error fail-closed checks.
          (set!
            fails
            (+
              fails
              (assert-eq-i64
                "re invalid count returns -1"
                (regex.regex-count-lines "[unclosed" "abc\n" false)
                -1)))
          (let
            [res1 : resvec.Vec (resvec.with-capacity 2)]
            [done1 : ivec.Vec (ivec.with-capacity 2)]
            (resvec.push-ref!
              (&mut res1)
              (exec.VariantResult 0 0 0 0 0 0 0 "" ""))
            (resvec.push-ref!
              (&mut res1)
              (exec.VariantResult 1 0 0 0 0 0 0 "" ""))
            (ivec.push-ref! (&mut done1) 0)
            (ivec.push-ref! (&mut done1) 0)
            ;; Truncated payload (declares 10 bytes stdout, only provides 2)
            (let
              [ok-trunc : bool
                (decode-worker-results!
                  0
                  2
                  "0\t0\t1\t0\t0\t0\t0\t10\t0\nhi"
                  (&mut res1)
                  (&mut done1))]
              (set!
                fails
                (+
                  fails
                  (assert-eq-bool "wave decode truncated fails" ok-trunc false)))
              (finalize-wave-results!
                0
                2
                false
                (not ok-trunc)
                (& done1)
                (&mut res1))
              (set!
                fails
                (+
                  fails
                  (assert-eq-i64
                    "wave missing job 0 failed"
                    (resvec.get
                      (& res1)
                      0
                      (exec.VariantResult 0 0 0 0 0 0 0 "" "")).failures
                    1)))
              (set!
                fails
                (+
                  fails
                  (assert-eq-i64
                    "wave missing job 1 failed"
                    (resvec.get
                      (& res1)
                      1
                      (exec.VariantResult 0 0 0 0 0 0 0 "" "")).failures
                    1)))))
          (let
            [res2 : resvec.Vec (resvec.with-capacity 1)]
            [done2 : ivec.Vec (ivec.with-capacity 1)]
            (resvec.push-ref!
              (&mut res2)
              (exec.VariantResult 0 0 0 0 0 0 0 "" ""))
            (ivec.push-ref! (&mut done2) 0)
            (let
              [ok-bad : bool
                (decode-worker-results!
                  0
                  1
                  "0a\t0\t1\t0\t0\t0\t0\t0\t0\n"
                  (&mut res2)
                  (&mut done2))]
              (set!
                fails
                (+
                  fails
                  (assert-eq-bool "wave decode non-numeric fails" ok-bad false)))))
          (let
            [res3 : resvec.Vec (resvec.with-capacity 1)]
            [done3 : ivec.Vec (ivec.with-capacity 1)]
            (resvec.push-ref!
              (&mut res3)
              (exec.VariantResult 0 0 0 0 0 0 0 "" ""))
            (ivec.push-ref! (&mut done3) 0)
            (let
              [ok-good : bool
                (decode-worker-results!
                  0
                  1
                  "0\t0\t1\t0\t0\t0\t0\t0\t0\n"
                  (&mut res3)
                  (&mut done3))]
              (set!
                fails
                (+ fails (assert-eq-bool "wave decode valid ok" ok-good true)))
              ;; Simulated ThreadStringJoinErr must still fail the wave even if job 0 decoded.
              (finalize-wave-results! 0 1 true false (& done3) (&mut res3))
              (set!
                fails
                (+
                  fails
                  (assert-eq-i64
                    "wave join error fails wave"
                    (resvec.get
                      (& res3)
                      0
                      (exec.VariantResult 0 0 0 0 0 0 0 "" "")).failures
                    1)))))
          (util.rm-rf! (& tmp-dir))
          fails)])))

(defstruct ValidateExpandedResult
  (ok bool)
  (error String)
  (output String))

;; Parse all expanded .cases files, enforcing isolated per-file defaults/files
;; and global unique case-ID (and fixture-source in --list-fixtures mode).
(define (validate-expanded-files
  [files : (& files svec.Vec)]
  [root : (& root str)]
  [do-list : bool]
  [do-fixtures : bool]) : ValidateExpandedResult
  (let
    [seen-ids : svec.Vec (svec.new)]
    [seen-sources : svec.Vec (svec.new)]
    [out : bbc.ByteBufBuilder (bbc.byte-buf-builder-new)]
    [n : i64 (svec.len files)]
    [fi : i64 0]
    [ok : bool true]
    [err : String ""]
    (while (and ok (< fi n))
      (let
        [cfile : String (svec.get files fi "")]
        [pf : parser.ParsedFile
          (parser.parse-cases-file (& cfile) root do-fixtures)]
        (if (not pf.ok)
          (begin
            (set! ok false)
            (set! err pf.error))
          (if do-fixtures
            (let
              [flines : svec.Vec (util.split-lines (& pf.fixtures-output))]
              [nf : i64 (svec.len (& flines))]
              [li : i64 0]
              (while (and ok (< li nf))
                (let
                  [fline : String (svec.get (& flines) li "")]
                  (when
                    (> (string.string-length (& fline)) 0)
                    (let
                      [cols : svec.Vec (util.split-by-sep (& fline) "\t")]
                      (when
                        (= (svec.len (& cols)) 2)
                        (let
                          [fid : String (svec.get (& cols) 0 "")]
                          [fsrc : String (svec.get (& cols) 1 "")]
                          (cond
                            [(parser.svec-has? (& seen-ids) (& fid))
                              (set! ok false)
                              (set!
                                err
                                (str_cat.str-cat
                                  (string.copy (& cfile))
                                  ": duplicate case "
                                  fid))]
                            [(parser.svec-has? (& seen-sources) (& fsrc))
                              (set! ok false)
                              (set!
                                err
                                (str_cat.str-cat
                                  (string.copy (& cfile))
                                  ": duplicate fixture source: "
                                  fsrc))]
                            [else
                              (svec.push-ref! (&mut seen-ids) fid)
                              (svec.push-ref! (&mut seen-sources) fsrc)]))))))
                (set! li (+ li 1)))
              (when
                ok
                (bbc.byte-buf-builder-append-string
                  (&mut out)
                  (string.copy (& pf.fixtures-output)))))
            (let
              [nc : i64 (parser.parsed-cases-len (& pf))]
              [ci : i64 0]
              (while (and ok (< ci nc))
                (let
                  [cdef : parser.CaseDef (parser.parsed-cases-get (& pf) ci)]
                  (if (parser.svec-has? (& seen-ids) (& cdef.id))
                    (begin
                      (set! ok false)
                      (set!
                        err
                        (str_cat.str-cat
                          (string.copy (& cfile))
                          ":"
                          (string.int->string cdef.line)
                          ": duplicate case "
                          cdef.id)))
                    (svec.push-ref! (&mut seen-ids) (string.copy (& cdef.id)))))
                (set! ci (+ ci 1)))
              (when
                (and ok do-list)
                (bbc.byte-buf-builder-append-string
                  (&mut out)
                  (parser.render-list (& pf))))))))
      (set! fi (+ fi 1)))
    (ValidateExpandedResult ok err (bbc.byte-buf-builder-finish-string (& out)))))

(define (self-test-directory-loading) : i64
  (let
    [fails : i64 0]
    [tmp-res : io.ResultIoString (fs.try-create-temp-dir "cc-dir-selftest")]
    (match tmp-res
      [(io.ErrIoString _)
        (io.print-error
          "SELF-TEST FAIL: could not create dir self-test temp dir\n")
        1]
      [(io.OkIoString tmp-dir)
        (let
          [valid-dir : String
            (str_cat.str-cat (string.copy (& tmp-dir)) "/valid.d")]
          [dup-dir : String
            (str_cat.str-cat (string.copy (& tmp-dir)) "/dup.d")]
          [stray-dir : String
            (str_cat.str-cat (string.copy (& tmp-dir)) "/stray.d")]
          [nested-dir : String
            (str_cat.str-cat (string.copy (& tmp-dir)) "/nested.d")]
          [empty-dir : String
            (str_cat.str-cat (string.copy (& tmp-dir)) "/empty.d")]
          [fix-dir : String
            (str_cat.str-cat (string.copy (& tmp-dir)) "/fixtures.d")]
          [fix-dup-dir : String
            (str_cat.str-cat (string.copy (& tmp-dir)) "/fixtures-dup.d")]
          [tests-dir : String
            (str_cat.str-cat (string.copy (& tmp-dir)) "/tests")]
          (util.ensure-dir! (& valid-dir))
          (util.ensure-dir! (& dup-dir))
          (util.ensure-dir! (& stray-dir))
          (util.ensure-dir!
            (& (str_cat.str-cat (string.copy (& nested-dir)) "/sub")))
          (util.ensure-dir! (& empty-dir))
          (util.ensure-dir! (& fix-dir))
          (util.ensure-dir! (& fix-dup-dir))
          (util.ensure-dir! (& tests-dir))
          ;; Valid directory: b before a on disk, must sort LC_ALL=C and isolate defaults.
          (util.write-file!
            (& (str_cat.str-cat (string.copy (& valid-dir)) "/02-second.cases"))
            "case second-case\nsource tests/b.tl\n")
          (util.write-file!
            (& (str_cat.str-cat (string.copy (& valid-dir)) "/01-first.cases"))
            "opt 1\ncase first-case\nsource tests/a.tl\n")
          (let
            [in-v : svec.Vec (svec.new)]
            (svec.push-ref! (&mut in-v) (string.copy (& valid-dir)))
            (let
              [exp : util.CaseInputsResult (util.expand-case-inputs (& in-v))]
              (set!
                fails
                (+ fails (assert-eq-bool "dir expand valid ok" exp.ok true)))
              (set!
                fails
                (+
                  fails
                  (assert-eq-i64
                    "dir expand valid count"
                    (svec.len (& exp.files))
                    2)))
              (when
                (and exp.ok (= (svec.len (& exp.files)) 2))
                (set!
                  fails
                  (+
                    fails
                    (assert-eq-str
                      "dir expand sorted 0"
                      (svec.get (& exp.files) 0 "")
                      (&
                        (str_cat.str-cat
                          (string.copy (& valid-dir))
                          "/01-first.cases")))))
                (set!
                  fails
                  (+
                    fails
                    (assert-eq-str
                      "dir expand sorted 1"
                      (svec.get (& exp.files) 1 "")
                      (&
                        (str_cat.str-cat
                          (string.copy (& valid-dir))
                          "/02-second.cases")))))
                (let
                  [vr : ValidateExpandedResult
                    (validate-expanded-files
                      (& exp.files)
                      (& tmp-dir)
                      true
                      false)]
                  [want : String
                    (str_cat.str-cat
                      (string.copy (& valid-dir))
                      "/01-first.cases first-case [linux-x86_64 1 -]\n"
                      (string.copy (& valid-dir))
                      "/02-second.cases second-case [linux-x86_64 2 -]\n")]
                  (set!
                    fails
                    (+
                      fails
                      (assert-eq-bool
                        "dir validate isolated defaults ok"
                        vr.ok
                        true)))
                  (set!
                    fails
                    (+
                      fails
                      (assert-eq-str
                        "dir validate list output"
                        (& vr.output)
                        (& want))))))))
          ;; Global duplicate case-ID across two files in one directory.
          (util.write-file!
            (& (str_cat.str-cat (string.copy (& dup-dir)) "/a.cases"))
            "case shared-id\nsource tests/a.tl\n")
          (util.write-file!
            (& (str_cat.str-cat (string.copy (& dup-dir)) "/b.cases"))
            "case shared-id\nsource tests/b.tl\n")
          (let
            [in-v : svec.Vec (svec.new)]
            (svec.push-ref! (&mut in-v) (string.copy (& dup-dir)))
            (let
              [exp : util.CaseInputsResult (util.expand-case-inputs (& in-v))]
              (set!
                fails
                (+ fails (assert-eq-bool "dup dir expand ok" exp.ok true)))
              (when
                exp.ok
                (let
                  [vr : ValidateExpandedResult
                    (validate-expanded-files
                      (& exp.files)
                      (& tmp-dir)
                      true
                      false)]
                  (set!
                    fails
                    (+
                      fails
                      (assert-eq-bool
                        "dup case across files rejected"
                        vr.ok
                        false)))))))
          ;; Stray non-.cases entry rejected.
          (util.write-file!
            (& (str_cat.str-cat (string.copy (& stray-dir)) "/a.cases"))
            "case ok-a\nsource tests/a.tl\n")
          (util.write-file!
            (& (str_cat.str-cat (string.copy (& stray-dir)) "/notes.txt"))
            "stray\n")
          (let
            [in-v : svec.Vec (svec.new)]
            (svec.push-ref! (&mut in-v) (string.copy (& stray-dir)))
            (let
              [exp : util.CaseInputsResult (util.expand-case-inputs (& in-v))]
              (set!
                fails
                (+ fails (assert-eq-bool "stray dir rejected" exp.ok false)))))
          ;; Nested directory rejected.
          (util.write-file!
            (& (str_cat.str-cat (string.copy (& nested-dir)) "/a.cases"))
            "case ok-a\nsource tests/a.tl\n")
          (let
            [in-v : svec.Vec (svec.new)]
            (svec.push-ref! (&mut in-v) (string.copy (& nested-dir)))
            (let
              [exp : util.CaseInputsResult (util.expand-case-inputs (& in-v))]
              (set!
                fails
                (+ fails (assert-eq-bool "nested dir rejected" exp.ok false)))))
          ;; Empty directory rejected.
          (let
            [in-v : svec.Vec (svec.new)]
            (svec.push-ref! (&mut in-v) (string.copy (& empty-dir)))
            (let
              [exp : util.CaseInputsResult (util.expand-case-inputs (& in-v))]
              (set!
                fails
                (+ fails (assert-eq-bool "empty dir rejected" exp.ok false)))))
          ;; --list-fixtures across directory + global duplicate fixture-source rejection.
          (util.write-file!
            (& (str_cat.str-cat (string.copy (& tests-dir)) "/f1.tl"))
            "(define (main) : i64 0)\n")
          (util.write-file!
            (& (str_cat.str-cat (string.copy (& tests-dir)) "/f2.tl"))
            "(define (main) : i64 0)\n")
          (util.write-file!
            (& (str_cat.str-cat (string.copy (& fix-dir)) "/a.cases"))
            "do none\ncase fix-a\nsource tests/f1.tl\n")
          (util.write-file!
            (& (str_cat.str-cat (string.copy (& fix-dir)) "/b.cases"))
            "do none\ncase fix-b\nsource tests/f2.tl\n")
          (let
            [in-v : svec.Vec (svec.new)]
            (svec.push-ref! (&mut in-v) (string.copy (& fix-dir)))
            (let
              [exp : util.CaseInputsResult (util.expand-case-inputs (& in-v))]
              (when
                exp.ok
                (let
                  [vr : ValidateExpandedResult
                    (validate-expanded-files
                      (& exp.files)
                      (& tmp-dir)
                      true
                      true)]
                  (set!
                    fails
                    (+
                      fails
                      (assert-eq-bool "fixtures dir valid ok" vr.ok true)))
                  (set!
                    fails
                    (+
                      fails
                      (assert-eq-str
                        "fixtures dir output"
                        (& vr.output)
                        "fix-a\ttests/f1.tl\nfix-b\ttests/f2.tl\n")))))))
          (util.write-file!
            (& (str_cat.str-cat (string.copy (& fix-dup-dir)) "/a.cases"))
            "do none\ncase fix-a\nsource tests/f1.tl\n")
          (util.write-file!
            (& (str_cat.str-cat (string.copy (& fix-dup-dir)) "/b.cases"))
            "do none\ncase fix-b\nsource tests/f1.tl\n")
          (let
            [in-v : svec.Vec (svec.new)]
            (svec.push-ref! (&mut in-v) (string.copy (& fix-dup-dir)))
            (let
              [exp : util.CaseInputsResult (util.expand-case-inputs (& in-v))]
              (when
                exp.ok
                (let
                  [vr : ValidateExpandedResult
                    (validate-expanded-files
                      (& exp.files)
                      (& tmp-dir)
                      true
                      true)]
                  (set!
                    fails
                    (+
                      fails
                      (assert-eq-bool
                        "fixtures dup source rejected"
                        vr.ok
                        false)))))))
          (util.rm-rf! (& tmp-dir))
          fails)])))

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
    (set!
      fails
      (+
        fails
        (assert-eq-str
          "to-msys-posix-path"
          (util.to-msys-posix-path "D:\\a\\typelisp\\bin")
          "/d/a/typelisp/bin")))
    (set!
      fails
      (+
        fails
        (assert-eq-str
          "to-msys-posix-path-fwd"
          (util.to-msys-posix-path "C:/Program Files/Git")
          "/c/Program Files/Git")))
    (set!
      fails
      (+
        fails
        (assert-eq-str
          "normalize-win-path-env-drive"
          (util.normalize-windows-path-env
            "D:/a/typelisp/bin:C:\\Program Files\\LLVM\\bin;C:\\Windows")
          "D:/a/typelisp/bin;C:\\Program Files\\LLVM\\bin;C:\\Windows")))
    (set!
      fails
      (+
        fails
        (assert-eq-str
          "normalize-win-path-env-msys"
          (util.normalize-windows-path-env "/d/a/typelisp/bin:/c/Windows")
          "D:/a/typelisp/bin;C:/Windows")))
    (set!
      fails
      (+
        fails
        (assert-eq-str
          "msys-path-tmp-dir"
          (util.msys-path-to-windows
            "/tmp/typelisp-public-doc-nopkg.abc123"
            "/d/a/typelisp"
            "D:/a/typelisp"
            "C:/Users/runneradmin/AppData/Local/Temp/"
            "C:/Program Files/Git/")
          "C:/Users/runneradmin/AppData/Local/Temp/typelisp-public-doc-nopkg.abc123")))
    (set!
      fails
      (+
        fails
        (assert-eq-str
          "msys-path-tmp-exact"
          (util.msys-path-to-windows
            "/tmp"
            ""
            ""
            "C:/Users/runneradmin/AppData/Local/Temp"
            "")
          "C:/Users/runneradmin/AppData/Local/Temp")))
    (set!
      fails
      (+
        fails
        (assert-eq-str
          "msys-path-drive"
          (util.msys-path-to-windows
            "/d/a/typelisp/out.s"
            ""
            ""
            "C:/Users/runneradmin/AppData/Local/Temp"
            "C:/Program Files/Git")
          "D:/a/typelisp/out.s")))
    (set!
      fails
      (+
        fails
        (assert-eq-str
          "msys-path-dev-null"
          (util.msys-path-to-windows
            "/dev/null"
            ""
            ""
            "C:/Users/runneradmin/AppData/Local/Temp"
            "C:/Program Files/Git")
          "NUL")))
    (set!
      fails
      (+
        fails
        (assert-eq-str
          "msys-path-usr-bin"
          (util.msys-path-to-windows
            "/usr/bin/env"
            ""
            ""
            "C:/Users/runneradmin/AppData/Local/Temp"
            "C:/Program Files/Git")
          "C:/Program Files/Git/usr/bin/env")))
    (set!
      fails
      (+
        fails
        (assert-eq-str
          "msys-path-root-prefix"
          (util.msys-path-to-windows
            "/d/a/typelisp/src/main.tl"
            "/d/a/typelisp"
            "D:/a/typelisp"
            "C:/Users/runneradmin/AppData/Local/Temp"
            "C:/Program Files/Git")
          "D:/a/typelisp/src/main.tl")))
    (set!
      fails
      (+
        fails
        (assert-eq-str
          "msys-path-non-msys-unchanged"
          (util.msys-path-to-windows
            "/OUT:foo.exe"
            ""
            ""
            "C:/Users/runneradmin/AppData/Local/Temp"
            "C:/Program Files/Git")
          "/OUT:foo.exe")))
    (set! fails (+ fails (self-test-runner-fixes)))
    (set! fails (+ fails (self-test-directory-loading)))
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
                [expanded-res : util.CaseInputsResult
                  (util.expand-case-inputs (& parsed.positionals))]
                (if (not expanded-res.ok)
                  (begin
                    (io.print-error (str_cat.str-cat expanded-res.error "\n"))
                    2)
                  (let
                    [val-res : ValidateExpandedResult
                      (validate-expanded-files
                        (& expanded-res.files)
                        (& root)
                        do-list
                        do-fixtures)]
                    (if (not val-res.ok)
                      (begin
                        (io.print-error (str_cat.str-cat val-res.error "\n"))
                        2)
                      (if do-list
                        (begin
                          (io.stdout-write
                            (byte_buf.str-as-bytes (& val-res.output)))
                          0)
                        (let
                          [expanded-n : i64 (svec.len (& expanded-res.files))]
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
                          (while (and (= fatal-exit 0) (< fi expanded-n))
                            (let
                              [cfile : String
                                (svec.get (& expanded-res.files) fi "")]
                              [pf : parser.ParsedFile
                                (parser.parse-cases-file
                                  (& cfile)
                                  (& root)
                                  false)]
                              (if (not pf.ok)
                                (begin
                                  (io.print-error
                                    (str_cat.str-cat pf.error "\n"))
                                  (set! fatal-exit 2))
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
                                  [pre-vars : util.VarTable
                                    (util.var-table-new)]
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
                                          (parser.parsed-pre-files-get
                                            (& pf)
                                            pi)]
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
                                                                        (&
                                                                          cfile))
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
                                      (set!
                                        wave-native-work-dir
                                        native-work-dir)
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
                                              (+
                                                total-simd-native
                                                r.simd-native))
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
                                          (set! ji (+ ji 1))))))))
                              (set! fi (+ fi 1))))
                          (cond
                            [(!= fatal-exit 0) fatal-exit]
                            [(= total-selected 0)
                              (io.print-error
                                (str_cat.str-cat
                                  "[codegen-cases] no case matches --only "
                                  only-glob
                                  "\n"))
                              1]
                            [(and
                              (>
                                (string.string-length
                                  (& wave-cfg.simd-mode-filter))
                                0)
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
                              0]))))))))))])))