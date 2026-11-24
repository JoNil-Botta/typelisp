;; Variant executor: actions, native/fallback shell steps, assertions, and plugins.
(import stdlib.byte_buf_core as bbc)
(import stdlib.env)
(import stdlib.fs)
(import stdlib.io)
(import stdlib.process)
(import stdlib.str_cat)
(import stdlib.string)
(import stdlib.time)
(import stdlib.vector)
(import (vector.vector String) as svec)
(import (vector.vector i64) as ivec)
(import analyzers)
(import parser)
(import regex)
(import util)

;; Shared immutable run configuration (initialized before spawning threads).
(defstruct RunnerConfig
  (root String)
  (native-root String)
  (compiler String)
  (host String)
  (host-target String)
  (exe-ext String)
  (lib-prefix String)
  (lib-suffix String)
  (native-isas svec.Vec)
  (sde-bin String)
  (sde-policy String)
  (simd-mode-filter String)
  (ci-timing-enabled bool)
  (ci-timing-file String)
  (ci-timing-gate String)
  (ci-timing-host String)
  (sh-bin String))

;; Per-variant execution result returned to the main thread for deterministic printing.
(defstruct VariantResult
  (index i64)
  (failures i64)
  (rows i64)
  (skipped i64)
  (simd-native i64)
  (simd-emulated i64)
  (simd-skipped i64)
  (stdout-log String)
  (stderr-log String))

;; Mutable per-variant execution state (lives entirely inside one variant's arena).
(defstruct VariantState
  (file-path String)
  (work-dir String)
  (native-work-dir String)
  (case-id String)
  (case-line i64)
  (variant-name String)
  (target String)
  (opt String)
  (mode String)
  (each String)
  (dir String)
  (native-dir String)
  (cwd String)
  (step-id String)
  (step-n i64)
  (failed bool)
  (failures i64)
  (rows i64)
  (skipped i64)
  (simd-native i64)
  (simd-emulated i64)
  (simd-skipped i64)
  (ran bool)
  (exit-code i64)
  (asm-path String)
  (asm-text String)
  (has-asm bool)
  (out-path String)
  (out-text String)
  (err-path String)
  (err-text String)
  (subject-text String)
  (has-subject bool)
  (bad-subject i64)
  (source-path String)
  (flags svec.Vec)
  (flags-key String)
  (vars util.VarTable)
  (sourced-scripts svec.Vec)
  (stdout-buf bbc.ByteBufBuilder)
  (stderr-buf bbc.ByteBufBuilder))

;; Process-wide atomic spinlocks for compile cache & CI timing file appends.
(define cache-spinlock : i64
  0)
(define timing-spinlock : i64
  0)

(unsafe
  (define (spinlock-acquire! [word : (MutPtr i64)]) : unit
    (while (!=
      (unsafe
        (atomic-cas! word 0 1))
      0)
      unit)))

(unsafe
  (define (spinlock-release! [word : (MutPtr i64)]) : unit
    (unsafe
      (atomic-store! word 0))))

(define (cache-lock!) : unit
  (unsafe
    (spinlock-acquire! (ptr-addr-of cache-spinlock))))

(define (cache-unlock!) : unit
  (unsafe
    (spinlock-release! (ptr-addr-of cache-spinlock))))

(define (timing-lock!) : unit
  (unsafe
    (spinlock-acquire! (ptr-addr-of timing-spinlock))))

(define (timing-unlock!) : unit
  (unsafe
    (spinlock-release! (ptr-addr-of timing-spinlock))))

(define (log-out! [st : (&mut st VariantState)] [line : String]) : unit
  (bbc.byte-buf-builder-append-string (&mut st.stdout-buf) line)
  (bbc.byte-buf-builder-push (&mut st.stdout-buf) (cast 10 : u8)))

(define (log-err! [st : (&mut st VariantState)] [line : String]) : unit
  (bbc.byte-buf-builder-append-string (&mut st.stderr-buf) line)
  (bbc.byte-buf-builder-push (&mut st.stderr-buf) (cast 10 : u8)))

(define (quote-lines-err! [st : (&mut st VariantState)] [text : (& text str)]) : unit
  (let
    [lines : svec.Vec (util.split-lines text)]
    [n : i64 (svec.len (& lines))]
    [i : i64 0]
    (while (< i n)
      (log-err! st (str_cat.str-cat "    " (svec.get (& lines) i "")))
      (set! i (+ i 1)))))

(define (record-fail!
  [st : (&mut st VariantState)]
  [line : i64]
  [msg : (& msg str)]) : unit
  (set! st.failures (+ st.failures 1))
  (set! st.failed true)
  (let
    [step-part : String
      (if (> (string.string-length (& st.step-id)) 0)
        (str_cat.str-cat " " (string.copy (& st.step-id)))
        "")]
    (log-err!
      st
      (str_cat.str-cat
        "FAIL "
        (string.copy (& st.file-path))
        ":"
        (string.int->string line)
        " "
        (string.copy (& st.case-id))
        " ["
        (string.copy (& st.variant-name))
        "]"
        step-part
        ": "
        (string.copy msg)))))

;; ---------------------------------------------------------------- SIMD / SDE
(define (isa-native? [cfg : (& cfg RunnerConfig)] [isa : (& isa str)]) : bool
  (if (or (string.eq isa "-") (string.eq isa "scalar"))
    true
    (let
      [n : i64 (svec.len (& cfg.native-isas))]
      [i : i64 0]
      [found : bool false]
      (while (and (not found) (< i n))
        (if (string.eq (svec.get (& cfg.native-isas) i "") isa)
          (set! found true)
          (set! i (+ i 1))))
      found)))

;; Returns "native", "sde", or "unavailable".
(define (simd-execution-mode [cfg : (& cfg RunnerConfig)] [mode : (& mode str)]) : String
  (cond
    [(or (string.eq mode "-") (string.eq mode "scalar")) "native"]
    [(and
        (not
          (and (string.eq mode "avx512") (string.eq (& cfg.sde-policy) "sde")))
        (isa-native? cfg mode))
      "native"]
    [(and
        (string.eq mode "avx512")
        (> (string.string-length (& cfg.sde-bin)) 0))
      "sde"]
    [else "unavailable"]))

(define (simd-mode-selected? [cfg : (& cfg RunnerConfig)] [mode : (& mode str)]) : bool
  (if (= (string.string-length (& cfg.simd-mode-filter)) 0)
    true
    (let
      [words : svec.Vec (util.split-words-blank (& cfg.simd-mode-filter))]
      [n : i64 (svec.len (& words))]
      [i : i64 0]
      [found : bool false]
      (while (and (not found) (< i n))
        (if (string.eq (svec.get (& words) i "") mode)
          (set! found true)
          (set! i (+ i 1))))
      found)))

(define (simd-record-label!
  [cfg : (& cfg RunnerConfig)]
  [st : (&mut st VariantState)]
  [label : (& label str)]
  [mode : (& mode str)]) : unit
  (when
    (string.eq mode "avx512")
    (let
      [exec-mode : String (simd-execution-mode cfg mode)]
      (cond
        [(string.eq (& exec-mode) "native")
          (set! st.simd-native (+ st.simd-native 1))]
        [(string.eq (& exec-mode) "sde")
          (set! st.simd-emulated (+ st.simd-emulated 1))]
        [else (set! st.simd-skipped (+ st.simd-skipped 1))])
      (let
        [sde-tag : String
          (if (> (string.string-length (& cfg.sde-bin)) 0)
            " sde-version=10.13.1"
            "")]
        (log-out!
          st
          (str_cat.str-cat
            "[simd-execution] "
            (string.copy label)
            " isa="
            (string.copy mode)
            " execution="
            exec-mode
            sde-tag))))))

(define (simd-record!
  [cfg : (& cfg RunnerConfig)]
  [st : (&mut st VariantState)]) : unit
  (let
    [mode : String (string.copy (& st.mode))]
    [label : String
      (str_cat.str-cat
        (string.copy (& st.case-id))
        " ["
        (string.copy (& st.variant-name))
        "]")]
    (simd-record-label! cfg st (& label) (& mode))))

;; ---------------------------------------------------------------- process execution
(defstruct ProcResult
  (exit-code i64)
  (stdout String)
  (stderr String))

(define (run-process-direct
  [executable : (& executable str)]
  [argv : (& argv svec.Vec)]
  [cwd : (& cwd str)]
  [env-names : (& env-names svec.Vec)]
  [env-values : (& env-values svec.Vec)]
  [has-stdin : bool]
  [stdin-text : (& stdin-text str)]) : ProcResult
  (let
    [resolved : String (util.resolve-executable executable)]
    (if (= (string.string-length (& resolved)) 0)
      (ProcResult
        127
        ""
        (str_cat.str-cat "command not found: " (string.copy executable) "\n"))
      (let
        [cmd : process.ProcessCommand
          (process.command-from-argv-vec resolved argv)]
        (when
          (> (string.string-length cwd) 0)
          (let
            [norm-cwd : String
              (if (util.host-is-windows?)
                (util.to-native-path cwd "" "")
                (string.copy cwd))]
            (set! cmd (process.command-with-cwd cmd norm-cwd))))
        (let
          [ne : i64 (svec.len env-names)]
          (when
            (> ne 0)
            (let
              [ev : process.ProcessEnvVec (process.env-vec-with-capacity ne)]
              [i : i64 0]
              (while (< i ne)
                (process.env-vec-append!
                  (&mut ev)
                  (svec.get env-names i "")
                  (svec.get env-values i ""))
                (set! i (+ i 1)))
              (set! cmd (process.command-with-env-vec cmd (& ev))))))
        (when
          has-stdin
          (set! cmd (process.command-with-stdin cmd (string.copy stdin-text))))
        (match (process.output cmd)
          [(process.OkProcessOutput out)
            (ProcResult
              (process.output-status (& out))
              (process.output-stdout (& out))
              (process.output-stderr (& out)))]
          [(process.ErrProcessOutput err)
            (ProcResult
              127
              ""
              (str_cat.str-cat
                "spawn failed: "
                (process.error-message err)
                "\n"))])))))

(define (record-ci-timing!
  [cfg : (& cfg RunnerConfig)]
  [case-id : (& case-id str)]
  [phase : (& phase str)]
  [elapsed-ms : i64]
  [exit-code : i64]) : unit
  (when
    cfg.ci-timing-enabled
    (let
      [row : String
        (str_cat.str-cat
          (string.copy (& cfg.ci-timing-gate))
          "\t"
          (string.copy case-id)
          "\t"
          (string.copy phase)
          "\t"
          (string.int->string elapsed-ms)
          "\t"
          (string.int->string exit-code)
          "\t"
          (string.copy (& cfg.ci-timing-host))
          "\n")]
      (timing-lock!)
      (util.append-file-ignore! (& cfg.ci-timing-file) (& row))
      (timing-unlock!)
      unit)))

(define (save-step-io!
  [st : (&mut st VariantState)]
  [step-name : (& step-name str)]
  [res : ProcResult]) : unit
  (let
    [out-p : String
      (str_cat.str-cat
        (string.copy (& st.dir))
        "/"
        (string.copy step-name)
        ".stdout")]
    [err-p : String
      (str_cat.str-cat
        (string.copy (& st.dir))
        "/"
        (string.copy step-name)
        ".stderr")]
    (util.write-file! (& out-p) (& res.stdout))
    (util.write-file! (& err-p) (& res.stderr))
    (set! st.out-path out-p)
    (set! st.out-text res.stdout)
    (set! st.err-path err-p)
    (set! st.err-text res.stderr)
    (set! st.exit-code res.exit-code)))

(define (run-action-cmd!
  [st : (&mut st VariantState)]
  [step-name : (& step-name str)]
  [exe : (& exe str)]
  [argv : (& argv svec.Vec)]) : unit
  (let
    [res : ProcResult
      (run-process-direct exe argv "" (& (svec.new)) (& (svec.new)) false "")]
    (save-step-io! st step-name res)))

(define (quote-st-out-err! [st : (&mut st VariantState)]) : unit
  (let
    [txt : String (string.copy (& st.out-text))]
    (quote-lines-err! st (& txt))))

(define (quote-st-err-err! [st : (&mut st VariantState)]) : unit
  (let
    [txt : String (string.copy (& st.err-text))]
    (quote-lines-err! st (& txt))))

(define (quote-st-subject-err! [st : (&mut st VariantState)]) : unit
  (let
    [txt : String (string.copy (& st.subject-text))]
    (quote-lines-err! st (& txt))))

(define (require-step! [st : (&mut st VariantState)] [what : (& what str)]) : bool
  (if (= st.exit-code 0)
    true
    (begin
      (record-fail!
        st
        st.case-line
        (str_cat.str-cat
          (string.copy what)
          " failed (exit "
          (string.int->string st.exit-code)
          ")"))
      (log-err! st "  stdout:")
      (quote-st-out-err! st)
      (log-err! st "  stderr:")
      (quote-st-err-err! st)
      false)))

;; ---------------------------------------------------------------- actions
(define (variant-name-of
  [target : (& target str)]
  [opt : (& opt str)]
  [mode : (& mode str)]
  [each : (& each str)]) : String
  (let
    [out : String ""]
    (when (not (string.eq target "-")) (set! out (string.copy target)))
    (when
      (not (string.eq opt "-"))
      (set!
        out
        (if (> (string.string-length (& out)) 0)
          (str_cat.str-cat out "-o" (string.copy opt))
          (str_cat.str-cat "o" (string.copy opt)))))
    (when
      (not (string.eq mode "-"))
      (set!
        out
        (if (> (string.string-length (& out)) 0)
          (str_cat.str-cat out "-" (string.copy mode))
          (string.copy mode))))
    (when
      (not (string.eq each "-"))
      (set!
        out
        (if (> (string.string-length (& out)) 0)
          (str_cat.str-cat out "-" (string.copy each))
          (string.copy each))))
    (if (= (string.string-length (& out)) 0)
      "default"
      out)))

(define (build-compile-argv
  [st : (& st VariantState)]
  [out-asm : (& out-asm str)]) : svec.Vec
  (let
    [argv : svec.Vec (svec.new)]
    (svec.push-ref! (&mut argv) "compile")
    (svec.push-ref! (&mut argv) (string.copy (& st.source-path)))
    (let
      [n : i64 (svec.len (& st.flags))]
      [i : i64 0]
      (while (< i n)
        (svec.push-ref! (&mut argv) (svec.get (& st.flags) i ""))
        (set! i (+ i 1))))
    (svec.push-ref! (&mut argv) "-o")
    (svec.push-ref! (&mut argv) (string.copy out-asm))
    argv))

(define (do-compile!
  [cfg : (& cfg RunnerConfig)]
  [st : (&mut st VariantState)]
  [suffix : (& suffix str)]) : unit
  (let
    [asm-p : String (str_cat.str-cat (string.copy (& st.dir)) "/out.s")]
    [key-input : String
      (str_cat.str-cat
        (string.copy (& st.source-path))
        "|"
        (string.copy (& st.flags-key))
        "|"
        (string.copy suffix))]
    [key : String (util.fnv1a-hex (& key-input))]
    [cache-dir : String
      (str_cat.str-cat (string.copy (& st.work-dir)) "/.cache")]
    [cache-s : String
      (str_cat.str-cat
        (string.copy (& cache-dir))
        "/"
        (string.copy (& key))
        ".s")]
    [cache-out : String
      (str_cat.str-cat
        (string.copy (& cache-dir))
        "/"
        (string.copy (& key))
        ".stdout")]
    [cache-err : String
      (str_cat.str-cat
        (string.copy (& cache-dir))
        "/"
        (string.copy (& key))
        ".stderr")]
    [hit : bool false]
    (set! st.asm-path (string.copy (& asm-p)))
    (when
      (= (string.string-length suffix) 0)
      (cache-lock!)
      (when
        (util.is-regular-file? (& cache-s))
        (let
          [rs : util.ReadFileResult (util.read-file-result (& cache-s))]
          [ro : util.ReadFileResult (util.read-file-result (& cache-out))]
          [re : util.ReadFileResult (util.read-file-result (& cache-err))]
          (when
            (and rs.ok ro.ok re.ok)
            (util.write-file! (& asm-p) (& rs.text))
            (set! st.asm-text rs.text)
            (set! st.has-asm true)
            (save-step-io! st "compile" (ProcResult 0 ro.text re.text))
            (set! hit true))))
      (cache-unlock!))
    (when
      (not hit)
      (log-err!
        st
        (str_cat.str-cat
          "[codegen-cases] compile "
          (string.copy (& st.case-id))
          " ["
          (string.copy (& st.variant-name))
          "]"))
      (let
        [argv : svec.Vec (build-compile-argv st (& asm-p))]
        [step-name : String (str_cat.str-cat "compile" (string.copy suffix))]
        (run-action-cmd! st (& step-name) (& cfg.compiler) (& argv))
        (when
          (= st.exit-code 0)
          (let
            [ra : util.ReadFileResult (util.read-file-result (& asm-p))]
            (when
              ra.ok
              (set! st.asm-text ra.text)
              (set! st.has-asm true)
              (when
                (= (string.string-length suffix) 0)
                (cache-lock!)
                (when
                  (not (util.is-regular-file? (& cache-s)))
                  (util.ensure-dir! (& cache-dir))
                  (let
                    [tmp-s : String
                      (str_cat.str-cat
                        (string.copy (& cache-s))
                        ".tmp."
                        (string.copy (& st.case-id)))]
                    [tmp-o : String
                      (str_cat.str-cat
                        (string.copy (& cache-out))
                        ".tmp."
                        (string.copy (& st.case-id)))]
                    [tmp-e : String
                      (str_cat.str-cat
                        (string.copy (& cache-err))
                        ".tmp."
                        (string.copy (& st.case-id)))]
                    (util.write-file! (& tmp-o) (& st.out-text))
                    (util.write-file! (& tmp-e) (& st.err-text))
                    (util.write-file! (& tmp-s) (& st.asm-text))
                    (util.rename-ignore! (& tmp-o) (& cache-out))
                    (util.rename-ignore! (& tmp-e) (& cache-err))
                    (util.rename-ignore! (& tmp-s) (& cache-s))
                    unit))
                (cache-unlock!)))))))))

(define (linux-entry-symbol [asm-text : (& asm-text str)]) : String
  (let
    [lines : svec.Vec (util.split-lines asm-text)]
    [n : i64 (svec.len (& lines))]
    [has-tl-start : bool false]
    [has-start : bool false]
    [i : i64 0]
    (while (< i n)
      (let
        [l : String (svec.get (& lines) i "")]
        (cond
          [(string.eq (& l) "_tl_start:") (set! has-tl-start true)]
          [(string.eq (& l) "_start:") (set! has-start true)]
          [else unit]))
      (set! i (+ i 1)))
    (if has-tl-start
      "_tl_start"
      (if has-start
        "_start"
        "_tl_start"))))

(define (do-assemble!
  [cfg : (& cfg RunnerConfig)]
  [st : (&mut st VariantState)]) : bool
  (let
    [as-target : String
      (if (string.eq (& st.target) "-")
        (string.copy (& cfg.host-target))
        (string.copy (& st.target)))]
    (if (string.eq (& cfg.host) "linux")
      (if (string.eq (& as-target) "linux-x86_64")
        (let
          [argv : svec.Vec (svec.new)]
          (svec.push-ref! (&mut argv) (string.copy (& st.asm-path)))
          (svec.push-ref! (&mut argv) "-o")
          (svec.push-ref!
            (&mut argv)
            (str_cat.str-cat (string.copy (& st.dir)) "/out.o"))
          (run-action-cmd! st "assemble" "as" (& argv))
          (require-step! st "GNU as"))
        (if (string.eq (& as-target) "windows-x86_64")
          (if (= (string.string-length (util.resolve-executable "clang")) 0)
            true
            (let
              [argv : svec.Vec (svec.new)]
              (svec.push-ref! (&mut argv) "--target=x86_64-pc-windows-msvc")
              (svec.push-ref! (&mut argv) "-c")
              (svec.push-ref! (&mut argv) (string.copy (& st.asm-path)))
              (svec.push-ref! (&mut argv) "-o")
              (svec.push-ref!
                (&mut argv)
                (str_cat.str-cat (string.copy (& st.dir)) "/out.obj"))
              (run-action-cmd! st "assemble" "clang" (& argv))
              (require-step! st "clang (Windows assembly)")))
          true))
      ;; Windows host
      (if (= (string.string-length (util.resolve-executable "clang")) 0)
        (begin
          (record-fail!
            st
            st.case-line
            "clang is required to assemble on Windows")
          false)
        (let
          [triple : String
            (if (string.eq (& as-target) "linux-x86_64")
              "x86_64-unknown-linux-gnu"
              "x86_64-pc-windows-msvc")]
          [argv : svec.Vec (svec.new)]
          (svec.push-ref! (&mut argv) (str_cat.str-cat "--target=" triple))
          (svec.push-ref! (&mut argv) "-c")
          (svec.push-ref! (&mut argv) (string.copy (& st.asm-path)))
          (svec.push-ref! (&mut argv) "-o")
          (svec.push-ref!
            (&mut argv)
            (str_cat.str-cat (string.copy (& st.dir)) "/out.obj"))
          (run-action-cmd! st "assemble" "clang" (& argv))
          (require-step! st (str_cat.str-cat "clang (" as-target " assembly)")))))))

(define (execute-program!
  [cfg : (& cfg RunnerConfig)]
  [st : (&mut st VariantState)]
  [bin-path : (& bin-path str)]) : unit
  (simd-record! cfg st)
  (let
    [exec-mode : String (simd-execution-mode cfg (& st.mode))]
    (if (string.eq (& exec-mode) "sde")
      (let
        [argv : svec.Vec (svec.new)]
        (svec.push-ref! (&mut argv) "-spr")
        (svec.push-ref! (&mut argv) "--")
        (svec.push-ref! (&mut argv) (string.copy bin-path))
        (run-action-cmd! st "run" (& cfg.sde-bin) (& argv)))
      (run-action-cmd! st "run" bin-path (& (svec.new))))))

(define (do-compiler-run!
  [cfg : (& cfg RunnerConfig)]
  [st : (&mut st VariantState)]) : bool
  (let
    [exec-mode : String (simd-execution-mode cfg (& st.mode))]
    (if (string.eq (& exec-mode) "unavailable")
      false
      (if (string.eq (& exec-mode) "sde")
        (let
          [bin : String
            (str_cat.str-cat
              (string.copy (& st.dir))
              "/program"
              (string.copy (& cfg.exe-ext)))]
          [argv : svec.Vec (svec.new)]
          (svec.push-ref! (&mut argv) "build")
          (svec.push-ref! (&mut argv) (string.copy (& st.source-path)))
          (let
            [n : i64 (svec.len (& st.flags))]
            [i : i64 0]
            (while (< i n)
              (svec.push-ref! (&mut argv) (svec.get (& st.flags) i ""))
              (set! i (+ i 1))))
          (svec.push-ref! (&mut argv) "-o")
          (svec.push-ref! (&mut argv) (string.copy (& bin)))
          (run-action-cmd! st "build" (& cfg.compiler) (& argv))
          (if (not (require-step! st "build"))
            false
            (begin
              (execute-program! cfg st (& bin))
              true)))
        (begin
          (simd-record! cfg st)
          (let
            [argv : svec.Vec (svec.new)]
            (svec.push-ref! (&mut argv) "run")
            (svec.push-ref! (&mut argv) (string.copy (& st.source-path)))
            (let
              [n : i64 (svec.len (& st.flags))]
              [i : i64 0]
              (while (< i n)
                (svec.push-ref! (&mut argv) (svec.get (& st.flags) i ""))
                (set! i (+ i 1))))
            (run-action-cmd! st "run" (& cfg.compiler) (& argv))
            true))))))

(define (do-case-action!
  [cfg : (& cfg RunnerConfig)]
  [st : (&mut st VariantState)]
  [cdef : (& cdef parser.CaseDef)]) : bool
  (set! st.ran true)
  (cond
    [(string.eq (& cdef.do-action) "none")
      (set! st.exit-code 0)
      true]
    [(string.eq (& cdef.do-action) "compile")
      (do-compile! cfg st "")
      (if (or (not cdef.has-exit) (= st.exit-code 0))
        (if (not (require-step! st "compile"))
          false
          (let
            [saved-out-path : String (string.copy (& st.out-path))]
            [saved-out-text : String (string.copy (& st.out-text))]
            [saved-err-path : String (string.copy (& st.err-path))]
            [saved-err-text : String (string.copy (& st.err-text))]
            [ok : bool true]
            (when
              cdef.assemble
              (when (not (do-assemble! cfg st)) (set! ok false)))
            (when
              (and ok cdef.repeatable)
              (let
                [first-s : String
                  (str_cat.str-cat (string.copy (& st.dir)) "/first.s")]
                [first-text : String (string.copy (& st.asm-text))]
                (util.write-file! (& first-s) (& first-text))
                (do-compile! cfg st "repeat")
                (if (not (require-step! st "repeat compile"))
                  (set! ok false)
                  (when
                    (not (string.eq (& first-text) (& st.asm-text)))
                    (record-fail!
                      st
                      st.case-line
                      "two compilations produced different assembly")
                    (set! ok false)))))
            (when
              ok
              (set! st.out-path saved-out-path)
              (set! st.out-text saved-out-text)
              (set! st.err-path saved-err-path)
              (set! st.err-text saved-err-text)
              (set! st.exit-code 0))
            ok))
        true)]
    [(string.eq (& cdef.do-action) "check")
      (let
        [exp-args : String (util.expand-vars (& st.vars) (& cdef.args))]
        [words : svec.Vec (util.split-words-blank (& exp-args))]
        [argv : svec.Vec (svec.new)]
        (svec.push-ref! (&mut argv) "check")
        (svec.push-ref! (&mut argv) (string.copy (& st.source-path)))
        (let
          [n : i64 (svec.len (& words))]
          [i : i64 0]
          (while (< i n)
            (svec.push-ref! (&mut argv) (svec.get (& words) i ""))
            (set! i (+ i 1))))
        (run-action-cmd! st "check" (& cfg.compiler) (& argv))
        true)]
    [(string.eq (& cdef.do-action) "tl-run")
      (if (string.eq (simd-execution-mode cfg (& st.mode)) "unavailable")
        (begin
          (set! st.ran false)
          (simd-record! cfg st)
          true)
        (do-compiler-run! cfg st))]
    [(or
        (string.eq (& cdef.do-action) "build")
        (string.eq (& cdef.do-action) "build-run"))
      (let
        [bin : String (str_cat.str-cat (string.copy (& st.dir)) "/program")]
        [bin-exe : String (str_cat.str-cat (string.copy (& bin)) ".exe")]
        [argv : svec.Vec (svec.new)]
        (log-err!
          st
          (str_cat.str-cat
            "[codegen-cases] build "
            (string.copy (& st.case-id))
            " ["
            (string.copy (& st.variant-name))
            "]"))
        (svec.push-ref! (&mut argv) "build")
        (svec.push-ref! (&mut argv) (string.copy (& st.source-path)))
        (let
          [n : i64 (svec.len (& st.flags))]
          [i : i64 0]
          (while (< i n)
            (svec.push-ref! (&mut argv) (svec.get (& st.flags) i ""))
            (set! i (+ i 1))))
        (svec.push-ref! (&mut argv) "-o")
        (svec.push-ref! (&mut argv) (string.copy (& bin)))
        (run-action-cmd! st "build" (& cfg.compiler) (& argv))
        (if (not (require-step! st "build"))
          false
          (let
            [has-bin : bool (util.is-executable? (& bin))]
            [has-exe : bool (util.is-executable? (& bin-exe))]
            (cond
              [(not (or has-bin has-exe))
                (record-fail! st st.case-line "build produced no executable")
                false]
              [(string.eq (& cdef.do-action) "build") true]
              [(string.eq (simd-execution-mode cfg (& st.mode)) "unavailable")
                (set! st.ran false)
                (simd-record! cfg st)
                true]
              [else
                (execute-program!
                  cfg
                  st
                  (if has-bin
                    (& bin)
                    (& bin-exe)))
                true]))))]
    [(string.eq (& cdef.do-action) "link-run")
      (do-compile! cfg st "")
      (cond
        [(not (require-step! st "compile")) false]
        [(string.eq (simd-execution-mode cfg (& st.mode)) "unavailable")
          (set! st.ran false)
          (simd-record! cfg st)
          true]
        [(string.eq (& cfg.host) "linux")
          (let
            [obj : String (str_cat.str-cat (string.copy (& st.dir)) "/out.o")]
            [bin : String (str_cat.str-cat (string.copy (& st.dir)) "/program")]
            [as-argv : svec.Vec (svec.new)]
            (svec.push-ref! (&mut as-argv) (string.copy (& st.asm-path)))
            (svec.push-ref! (&mut as-argv) "-o")
            (svec.push-ref! (&mut as-argv) (string.copy (& obj)))
            (run-action-cmd! st "assemble" "as" (& as-argv))
            (if (not (require-step! st "GNU as"))
              false
              (let
                [entry : String (linux-entry-symbol (& st.asm-text))]
                [ld-argv : svec.Vec (svec.new)]
                (svec.push-ref! (&mut ld-argv) obj)
                (svec.push-ref! (&mut ld-argv) "-o")
                (svec.push-ref! (&mut ld-argv) (string.copy (& bin)))
                (svec.push-ref! (&mut ld-argv) "-static")
                (svec.push-ref! (&mut ld-argv) "-e")
                (svec.push-ref! (&mut ld-argv) entry)
                (run-action-cmd! st "link" "ld" (& ld-argv))
                (if (not (require-step! st "GNU ld"))
                  false
                  (begin
                    (execute-program! cfg st (& bin))
                    true)))))]
        [else
          ;; Windows: `typelisp compile` with `target -` emits Linux ELF assembly
          ;; for asm-shape checks, while Windows execution uses `typelisp run`
          ;; (or `typelisp build` + SDE) so MSVC/Windows SDK discovery and
          ;; host-target codegen match the compiler contract.
          (do-compiler-run! cfg st)])]
    [else
      (record-fail!
        st
        st.case-line
        (str_cat.str-cat "unknown action: " (string.copy (& cdef.do-action))))
      false]))

;; ---------------------------------------------------------------- simple POSIX command tokenizer
(defstruct ShellParse
  (native-ok bool)
  (tokens svec.Vec)
  (has-stdin bool)
  (stdin-file String))

;; Parse a simple shell command (single/double quotes, {{var}} expansion with exact
;; unquoted word-splitting, $ENV lookup, optional trailing `< file`).
;; Sets native-ok=false if complex shell syntax is encountered.
(define (parse-simple-shell [vars : (& vars util.VarTable)] [raw : (& raw str)]) : ShellParse
  (let
    [n : i64 (string.string-length raw)]
    [tokens : svec.Vec (svec.new)]
    [cur : bbc.ByteBufBuilder (bbc.byte-buf-builder-new)]
    [has-cur : bool false]
    [in-sq : bool false]
    [in-dq : bool false]
    [need-sh : bool false]
    [has-stdin : bool false]
    [stdin-file : String ""]
    [expect-stdin : bool false]
    [i : i64 0]
    (while (and (not need-sh) (< i n))
      (let
        [b : i64 (util.byte-at raw i)]
        (cond
          [in-sq
            (if (= b 39)
              (set! in-sq false)
              (bbc.byte-buf-builder-push (&mut cur) (cast b : u8)))
            (set! i (+ i 1))]
          [in-dq
            (cond
              [(= b 34)
                (set! in-dq false)
                (set! i (+ i 1))]
              [(= b 92)
                ;; Backslash inside double quotes only escapes " \ $ ` newline
                (if (< (+ i 1) n)
                  (let
                    [nb : i64 (util.byte-at raw (+ i 1))]
                    (if (or (= nb 34) (= nb 92) (= nb 36) (= nb 96))
                      (begin
                        (bbc.byte-buf-builder-push (&mut cur) (cast nb : u8))
                        (set! i (+ i 2)))
                      (begin
                        (bbc.byte-buf-builder-push (&mut cur) (cast 92 : u8))
                        (set! i (+ i 1)))))
                  (set! need-sh true))]
              [(and (= b 123) (< (+ i 1) n) (= (util.byte-at raw (+ i 1)) 123))
                ;; {{name}} inside double quotes: expand verbatim (no word-split)
                (let
                  [close : i64 (util.index-of-str-from raw "}}" (+ i 2))]
                  (if (< close 0)
                    (begin
                      (bbc.byte-buf-builder-push (&mut cur) (cast b : u8))
                      (set! i (+ i 1)))
                    (let
                      [vname : String
                        (string.substring raw (+ i 2) (- close (+ i 2)))]
                      (if (util.valid-var-name? (& vname))
                        (begin
                          (bbc.byte-buf-builder-append-string
                            (&mut cur)
                            (util.var-table-get vars (& vname)))
                          (set! i (+ close 2)))
                        (begin
                          (bbc.byte-buf-builder-append-string
                            (&mut cur)
                            (string.substring raw i (- (+ close 2) i)))
                          (set! i (+ close 2)))))))]
              [(= b 36)
                ;; $VAR inside double quotes (reject $(, ${, etc.)
                (if (and
                  (< (+ i 1) n)
                  (or
                    (util.is-alpha-byte? (util.byte-at raw (+ i 1)))
                    (= (util.byte-at raw (+ i 1)) 95)))
                  (let
                    [j : i64 (+ i 1)]
                    (while (and
                      (< j n)
                      (or
                        (util.is-alnum-byte? (util.byte-at raw j))
                        (= (util.byte-at raw j) 95)))
                      (set! j (+ j 1)))
                    (let
                      [ename : String
                        (string.substring raw (+ i 1) (- j (+ i 1)))]
                      [eval-v : String
                        (match (env.get (& ename))
                          [(env.EnvSomeString v) v]
                          [(env.EnvNoString) ""])]
                      (bbc.byte-buf-builder-append-string (&mut cur) eval-v)
                      (set! i j)))
                  (set! need-sh true))]
              [(= b 96) (set! need-sh true)]
              [else
                (bbc.byte-buf-builder-push (&mut cur) (cast b : u8))
                (set! i (+ i 1))])]
          ;; Unquoted
          [(util.is-blank-byte? b)
            (when
              has-cur
              (let
                [tok : String (bbc.byte-buf-builder-finish-string (& cur))]
                (if expect-stdin
                  (begin
                    (set! stdin-file tok)
                    (set! has-stdin true)
                    (set! expect-stdin false))
                  (svec.push-ref! (&mut tokens) tok))
                (set! cur (bbc.byte-buf-builder-new))
                (set! has-cur false)))
            (set! i (+ i 1))]
          [(= b 39)
            (set! in-sq true)
            (set! has-cur true)
            (set! i (+ i 1))]
          [(= b 34)
            (set! in-dq true)
            (set! has-cur true)
            (set! i (+ i 1))]
          [(= b 92)
            (if (< (+ i 1) n)
              (begin
                (bbc.byte-buf-builder-push
                  (&mut cur)
                  (cast (util.byte-at raw (+ i 1)) : u8))
                (set! has-cur true)
                (set! i (+ i 2)))
              (set! need-sh true))]
          [(= b 60)
            ;; '<' stdin redirection
            (if (or
              has-stdin
              expect-stdin
              (and (< (+ i 1) n) (= (util.byte-at raw (+ i 1)) 60)))
              (set! need-sh true)
              (begin
                (when
                  has-cur
                  (svec.push-ref!
                    (&mut tokens)
                    (bbc.byte-buf-builder-finish-string (& cur)))
                  (set! cur (bbc.byte-buf-builder-new))
                  (set! has-cur false))
                (set! expect-stdin true)
                (set! i (+ i 1))))]
          [(or
              (= b 124)
              (= b 38)
              (= b 59)
              (= b 62)
              (= b 96)
              (= b 40)
              (= b 41)
              (= b 10))
            (set! need-sh true)]
          [(and (= b 123) (< (+ i 1) n) (= (util.byte-at raw (+ i 1)) 123))
            ;; Unquoted {{name}}: expand AND word-split on spaces/tabs!
            (let
              [close : i64 (util.index-of-str-from raw "}}" (+ i 2))]
              (if (< close 0)
                (begin
                  (bbc.byte-buf-builder-push (&mut cur) (cast b : u8))
                  (set! has-cur true)
                  (set! i (+ i 1)))
                (let
                  [vname : String
                    (string.substring raw (+ i 2) (- close (+ i 2)))]
                  (if (util.valid-var-name? (& vname))
                    (let
                      [val : String (util.var-table-get vars (& vname))]
                      [vlen : i64 (string.string-length (& val))]
                      [vi : i64 0]
                      (while (< vi vlen)
                        (let
                          [vb : i64 (util.byte-at (& val) vi)]
                          (if (util.is-blank-byte? vb)
                            (when
                              has-cur
                              (let
                                [tok : String
                                  (bbc.byte-buf-builder-finish-string (& cur))]
                                (if expect-stdin
                                  (begin
                                    (set! stdin-file tok)
                                    (set! has-stdin true)
                                    (set! expect-stdin false))
                                  (svec.push-ref! (&mut tokens) tok))
                                (set! cur (bbc.byte-buf-builder-new))
                                (set! has-cur false)))
                            (begin
                              (bbc.byte-buf-builder-push
                                (&mut cur)
                                (cast vb : u8))
                              (set! has-cur true))))
                        (set! vi (+ vi 1)))
                      (set! i (+ close 2)))
                    (begin
                      (bbc.byte-buf-builder-append-string
                        (&mut cur)
                        (string.substring raw i (- (+ close 2) i)))
                      (set! has-cur true)
                      (set! i (+ close 2)))))))]
          [(= b 36)
            ;; Unquoted $VAR -> complex if special, else simple env lookup
            (set! need-sh true)]
          [else
            (bbc.byte-buf-builder-push (&mut cur) (cast b : u8))
            (set! has-cur true)
            (set! i (+ i 1))])))
    (when (or in-sq in-dq) (set! need-sh true))
    (when
      (and (not need-sh) has-cur)
      (let
        [tok : String (bbc.byte-buf-builder-finish-string (& cur))]
        (if expect-stdin
          (begin
            (set! stdin-file tok)
            (set! has-stdin true)
            (set! expect-stdin false))
          (svec.push-ref! (&mut tokens) tok))))
    (when expect-stdin (set! need-sh true))
    (ShellParse (not need-sh) tokens has-stdin stdin-file)))

;; Build the env arrays carrying CCV_* + standard runner vars for sh -c fallback.
(defstruct EnvPairs
  (names svec.Vec)
  (values svec.Vec))

(define (build-shell-env
  [cfg : (& cfg RunnerConfig)]
  [st : (& st VariantState)]
  [posix-paths : bool]) : EnvPairs
  (let
    [use-posix : bool (and posix-paths (util.host-is-windows?))]
    [names : svec.Vec (svec.new)]
    [values : svec.Vec (svec.new)]
    [nv : i64 (svec.len (& st.vars.keys))]
    [i : i64 0]
    (while (< i nv)
      (let
        [k : String (svec.get (& st.vars.keys) i "")]
        [v : String (svec.get (& st.vars.values) i "")]
        [out-v : String
          (if (and
            use-posix
            (or
              (string.eq (& k) "root")
              (string.eq (& k) "work")
              (string.eq (& k) "dir")))
            (util.to-msys-posix-path (& v))
            v)]
        (svec.push-ref! (&mut names) (str_cat.str-cat "CCV_" k))
        (svec.push-ref! (&mut values) out-v))
      (set! i (+ i 1)))
    (svec.push-ref! (&mut names) "ROOT")
    (svec.push-ref!
      (&mut values)
      (if use-posix
        (util.to-msys-posix-path (& cfg.root))
        (string.copy (& cfg.root))))
    (svec.push-ref! (&mut names) "COMPILER")
    (svec.push-ref! (&mut values) (string.copy (& cfg.compiler)))
    (svec.push-ref! (&mut names) "CC_HOST")
    (svec.push-ref! (&mut values) (string.copy (& cfg.host)))
    (svec.push-ref! (&mut names) "CC_WORK")
    (svec.push-ref!
      (&mut values)
      (if use-posix
        (util.to-msys-posix-path (& st.work-dir))
        (string.copy (& st.work-dir))))
    (svec.push-ref! (&mut names) "CV_DIR")
    (svec.push-ref! (&mut values) (string.copy (& st.dir)))
    (svec.push-ref! (&mut names) "CV_ASM")
    (svec.push-ref! (&mut values) (string.copy (& st.asm-path)))
    (svec.push-ref! (&mut names) "CV_TARGET")
    (svec.push-ref! (&mut values) (string.copy (& st.target)))
    (svec.push-ref! (&mut names) "CV_OPT")
    (svec.push-ref! (&mut values) (string.copy (& st.opt)))
    (svec.push-ref! (&mut names) "CV_MODE")
    (svec.push-ref! (&mut values) (string.copy (& st.mode)))
    (svec.push-ref! (&mut names) "SIMDEX_SDE_BIN")
    (svec.push-ref! (&mut values) (string.copy (& cfg.sde-bin)))
    (svec.push-ref! (&mut names) "SIMDEX_POLICY")
    (svec.push-ref! (&mut values) (string.copy (& cfg.sde-policy)))
    (svec.push-ref! (&mut names) "SIMDEX_AVX512_MODE")
    (svec.push-ref! (&mut values) (simd-execution-mode cfg "avx512"))
    (EnvPairs names values)))

(define (shell-helper-prelude) : String
  (str_cat.str-cat
    "set -f\n"
    "cc_native_path() { if [ \"$CC_HOST\" = windows ] && command -v cygpath >/dev/null 2>&1; then cygpath -m \"$1\"; else printf '%s\\n' \"$1\"; fi; }\n"
    "cc_link_static() { as \"$1\" -o \"$2.o\" && ld \"$2.o\" -o \"$2\" -static -e _tl_start; }\n"
    "cc_dir_link() { if [ \"$CC_HOST\" = windows ]; then TYPELISP_TEST_JUNCTION_LINK=$(cygpath -aw \"$1\") TYPELISP_TEST_JUNCTION_TARGET=$(cygpath -aw \"$2\") powershell.exe -NoLogo -NoProfile -NonInteractive -Command '$null = New-Item -ItemType Junction -Path $env:TYPELISP_TEST_JUNCTION_LINK -Target $env:TYPELISP_TEST_JUNCTION_TARGET' >/dev/null; else ln -s \"$2\" \"$1\"; fi; }\n"
    "cc_dir_unlink() { if [ \"$CC_HOST\" = windows ]; then TYPELISP_TEST_JUNCTION_LINK=$(cygpath -aw \"$1\") powershell.exe -NoLogo -NoProfile -NonInteractive -Command '[System.IO.Directory]::Delete($env:TYPELISP_TEST_JUNCTION_LINK)' >/dev/null; else rm \"$1\"; fi; }\n"
    "linux_entry_symbol_for_asm() { for _s in _tl_start _start; do if grep -q \"^${_s}:$\" \"$1\"; then printf '%s\\n' \"$_s\"; return 0; else _st=$?; [ \"$_st\" -eq 1 ] || return \"$_st\"; fi; done; printf '%s\\n' _tl_start; }\n"
    "fail() { printf '%s\\n' \"$*\" >&2; exit 1; }\n"
    "cc_wait() { _cw_pid=$1; if [ -f \"$CV_DIR/.bg_pid_$_cw_pid\" ]; then _cw_rc_file=$(cat \"$CV_DIR/.bg_pid_$_cw_pid\"); while [ ! -f \"$_cw_rc_file\" ]; do if ! kill -0 \"$_cw_pid\" 2>/dev/null && [ ! -f \"$_cw_rc_file\" ]; then return 127; fi; sleep 0.05; done; _cw_rc=$(cat \"$_cw_rc_file\"); return \"$_cw_rc\"; fi; wait \"$_cw_pid\"; }\n"
    "simd_execute() { _m=$1; shift; if [ \"$_m\" = avx512 ] && [ -n \"$SIMDEX_SDE_BIN\" ] && [ \"$SIMDEX_AVX512_MODE\" = sde ]; then \"$SIMDEX_SDE_BIN\" -spr -- \"$@\"; else \"$@\"; fi; }\n"))

;; Find all CCV_<name>= identifiers referenced in a shell snippet so we sync them back.
(define (find-assigned-ccv-vars [text : (& text str)]) : svec.Vec
  (let
    [out : svec.Vec (svec.new)]
    [n : i64 (string.string-length text)]
    [pos : i64 0]
    [done : bool false]
    (while (not done)
      (let
        [hit : i64 (util.index-of-str-from text "CCV_" pos)]
        (if (< hit 0)
          (set! done true)
          (let
            [start : i64 (+ hit 4)]
            [j : i64 start]
            (while (and
              (< j n)
              (or
                (util.is-alnum-byte? (util.byte-at text j))
                (= (util.byte-at text j) 95)))
              (set! j (+ j 1)))
            (when
              (and (> j start) (< j n) (= (util.byte-at text j) 61))
              (let
                [vname : String (string.substring text start (- j start))]
                [seen : bool false]
                [k : i64 0]
                [on : i64 (svec.len (& out))]
                (while (and (not seen) (< k on))
                  (if (string.eq (svec.get (& out) k "") (& vname))
                    (set! seen true)
                    (set! k (+ k 1))))
                (when (not seen) (svec.push-ref! (&mut out) vname))))
            (set! pos j)))))
    out))

;; Rewrite `<cmd> & CCV_<var>=$!` so background exit codes survive across sh invocations,
;; and rewrite `wait "` to `cc_wait "` so cross-row waits work in every POSIX shell.
(define (rewrite-bg-and-wait [body : (& body str)]) : String
  (let
    [bg-pos : i64 (util.index-of-str-from body " & CCV_" 0)]
    (if (and (>= bg-pos 0) (util.ends-with? body "=$!"))
      (let
        [blen : i64 (string.string-length body)]
        [cmd-part : String (string.substring body 0 bg-pos)]
        [var-part : String
          (string.substring body (+ bg-pos 7) (- (- blen 3) (+ bg-pos 7)))]
        (str_cat.str-cat
          "_cc_bg_rc=\"$CV_DIR/.bg_rc_"
          (string.copy (& var-part))
          "_$$\"; rm -f \"$_cc_bg_rc\" \"$_cc_bg_rc.tmp\"; "
          "( "
          cmd-part
          "; _cc_r=$?; printf '%s\\n' \"$_cc_r\" > \"$_cc_bg_rc.tmp\" && mv \"$_cc_bg_rc.tmp\" \"$_cc_bg_rc\" ) </dev/null >/dev/null 2>&1 & "
          "CCV_"
          (string.copy (& var-part))
          "=$!; printf '%s\\n' \"$_cc_bg_rc\" > \"$CV_DIR/.bg_pid_${CCV_"
          var-part
          "}\""))
      (if (>= (util.index-of-str-from body "wait \"" 0) 0)
        (let
          [n : i64 (string.string-length body)]
          [out : bbc.ByteBufBuilder
            (bbc.byte-buf-builder-with-capacity (+ n 16))]
          [pos : i64 0]
          [done : bool false]
          (while (not done)
            (let
              [hit : i64 (util.index-of-str-from body "wait \"" pos)]
              (if (< hit 0)
                (begin
                  (bbc.byte-buf-builder-append-string
                    (&mut out)
                    (string.substring body pos (- n pos)))
                  (set! done true))
                (let
                  [is-word-start : bool
                    (or
                      (= hit 0)
                      (let
                        [pb : i64 (util.byte-at body (- hit 1))]
                        (or
                          (= pb 32)
                          (= pb 9)
                          (= pb 59)
                          (= pb 10)
                          (= pb 38)
                          (= pb 124))))]
                  (when
                    (> hit pos)
                    (bbc.byte-buf-builder-append-string
                      (&mut out)
                      (string.substring body pos (- hit pos))))
                  (if is-word-start
                    (bbc.byte-buf-builder-append-string (&mut out) "cc_wait \"")
                    (bbc.byte-buf-builder-append-string (&mut out) "wait \""))
                  (set! pos (+ hit 6))))))
          (bbc.byte-buf-builder-finish-string (& out)))
        (string.copy body)))))

(define (run-sh-fallback!
  [cfg : (& cfg RunnerConfig)]
  [st : (&mut st VariantState)]
  [script-body : (& script-body str)]
  [cwd : (& cwd str)]
  [sync-vars : bool]) : ProcResult
  (let
    [ep : EnvPairs (build-shell-env cfg st (not sync-vars))]
    [rewritten : String
      (if sync-vars
        (rewrite-bg-and-wait script-body)
        (string.copy script-body))]
    [assigned : svec.Vec
      (if sync-vars
        (find-assigned-ccv-vars (& rewritten))
        (svec.new))]
    [nvar : i64 (svec.len (& assigned))]
    [var-file : String (str_cat.str-cat (string.copy (& st.dir)) "/.sh_vars")]
    [full : bbc.ByteBufBuilder (bbc.byte-buf-builder-new)]
    (bbc.byte-buf-builder-append-string (&mut full) (shell-helper-prelude))
    (let
      [nsrc : i64 (svec.len (& st.sourced-scripts))]
      [si : i64 0]
      (while (< si nsrc)
        (bbc.byte-buf-builder-append-string
          (&mut full)
          (str_cat.str-cat
            ". \""
            (svec.get (& st.sourced-scripts) si "")
            "\"\n"))
        (set! si (+ si 1))))
    (bbc.byte-buf-builder-append-string (&mut full) "{\n")
    (bbc.byte-buf-builder-append-string (&mut full) rewritten)
    (bbc.byte-buf-builder-append-string (&mut full) "\n}\n_cc_rc=$?\n")
    (when
      (> nvar 0)
      (bbc.byte-buf-builder-append-string
        (&mut full)
        ": > \"$CV_DIR/.sh_vars\"\n")
      (let
        [k : i64 0]
        (while (< k nvar)
          (let
            [vn : String (svec.get (& assigned) k "")]
            (bbc.byte-buf-builder-append-string
              (&mut full)
              (str_cat.str-cat
                "_cc_v=\"${CCV_"
                (string.copy (& vn))
                "-}\"; printf '%s\\t%d\\n%s\\n' '"
                vn
                "' \"${#_cc_v}\" \"$_cc_v\" >> \"$CV_DIR/.sh_vars\"\n")))
          (set! k (+ k 1)))))
    (bbc.byte-buf-builder-append-string (&mut full) "exit $_cc_rc\n")
    (let
      [script-text : String (bbc.byte-buf-builder-finish-string (& full))]
      [script-file : String
        (str_cat.str-cat (string.copy (& st.dir)) "/.sh_cmd")]
      [argv : svec.Vec (svec.new)]
      ;; On Windows, pass the script via a file instead of `-c` to avoid
      ;; CreateProcessA command-line quoting/newline/length edge cases.
      (if (util.host-is-windows?)
        (begin
          (util.write-file! (& script-file) (& script-text))
          (svec.push-ref! (&mut argv) (string.copy (& script-file))))
        (begin
          (svec.push-ref! (&mut argv) "-c")
          (svec.push-ref! (&mut argv) script-text)))
      (let
        [res : ProcResult
          (run-process-direct
            (& cfg.sh-bin)
            (& argv)
            cwd
            (& ep.names)
            (& ep.values)
            false
            "")]
        (when
          (util.host-is-windows?)
          (util.remove-file-ignore! (& script-file)))
        (when
          (and (> nvar 0) (util.is-regular-file? (& var-file)))
          (let
            [rf : util.ReadFileResult (util.read-file-result (& var-file))]
            (when
              rf.ok
              (let
                [tlen : i64 (string.string-length (& rf.text))]
                [pos : i64 0]
                (while (< pos tlen)
                  (let
                    [nl : i64 (util.index-of-byte-from (& rf.text) pos 10)]
                    (if (< nl 0)
                      (set! pos tlen)
                      (let
                        [hdr : String
                          (util.strip-cr
                            (string.substring (& rf.text) pos (- nl pos)))]
                        [tab : i64 (util.index-of-byte-from (& hdr) 0 9)]
                        (if (< tab 0)
                          (set! pos (+ nl 1))
                          (let
                            [vname : String (string.substring (& hdr) 0 tab)]
                            [len-s : String
                              (string.substring
                                (& hdr)
                                (+ tab 1)
                                (- (string.string-length (& hdr)) (+ tab 1)))]
                            [vlen : i64 (util.parse-u64-strict (& len-s)).value]
                            [vstart : i64 (+ nl 1)]
                            (if (<= (+ vstart vlen) tlen)
                              (let
                                [raw-vval : String
                                  (string.substring (& rf.text) vstart vlen)]
                                [vval : String
                                  (util.normalize-sh-synced-var
                                    (& raw-vval)
                                    (& cfg.root)
                                    (& cfg.native-root))]
                                (util.var-table-set!
                                  (&mut st.vars)
                                  (& vname)
                                  (& vval))
                                (set! pos (+ vstart vlen 1)))
                              (set! pos tlen)))))))))))
          (util.remove-file-ignore! (& var-file))
          unit)
        res))))

;; ---------------------------------------------------------------- step execution (run / exec / sh / test / same / file)
(define (exec-step-row!
  [cfg : (& cfg RunnerConfig)]
  [st : (&mut st VariantState)]
  [is-run : bool]
  [raw : (& raw str)]) : unit
  (set! st.step-n (+ st.step-n 1))
  (set! st.has-subject false)
  (set! st.subject-text "")
  (set! st.bad-subject 0)
  (set! st.ran true)
  (let
    [t0 : i64
      (if cfg.ci-timing-enabled
        (time.ms-or (time.monotonic-ms) 0)
        0)]
    [sp : ShellParse (parse-simple-shell (& st.vars) raw)]
    [res : ProcResult (ProcResult 0 "" "")]
    [use-native : bool
      (and
        sp.native-ok
        (or (not sp.has-stdin) (not (util.host-is-windows?)))
        (or is-run (> (svec.len (& sp.tokens)) 0)))]
    (if use-native
      (let
        [stdin-text : String ""]
        [stdin-ok : bool true]
        (when
          sp.has-stdin
          (let
            [rf : util.ReadFileResult (util.read-file-result (& sp.stdin-file))]
            (if rf.ok
              (set! stdin-text rf.text)
              (set! stdin-ok false))))
        (if (not stdin-ok)
          (set!
            res
            (ProcResult
              1
              ""
              (str_cat.str-cat "cannot open stdin file: " sp.stdin-file "\n")))
          (if is-run
            (set!
              res
              (run-process-direct
                (& cfg.compiler)
                (& sp.tokens)
                (& st.cwd)
                (& (svec.new))
                (& (svec.new))
                sp.has-stdin
                (& stdin-text)))
            ;; exec: handle leading `env K=V ... CMD ARGS` and `simd_execute MODE CMD ARGS` natively
            (let
              [nt : i64 (svec.len (& sp.tokens))]
              [env-names : svec.Vec (svec.new)]
              [env-values : svec.Vec (svec.new)]
              [idx : i64 0]
              [handled-env : bool false]
              (when
                (and (> nt 1) (string.eq (svec.get (& sp.tokens) 0 "") "env"))
                (set! idx 1)
                (set! handled-env true)
                (let
                  [more : bool true]
                  (while (and more (< idx nt))
                    (let
                      [tok : String (svec.get (& sp.tokens) idx "")]
                      [eq-pos : i64 (util.index-of-byte-from (& tok) 0 61)]
                      (if (and
                        (> eq-pos 0)
                        (not (util.starts-with? (& tok) "-")))
                        (let
                          [ename : String (string.substring (& tok) 0 eq-pos)]
                          [raw-eval : String
                            (string.substring
                              (& tok)
                              (+ eq-pos 1)
                              (- (string.string-length (& tok)) (+ eq-pos 1)))]
                          [eff-eval : String
                            (if (and
                              (util.host-is-windows?)
                              (string.eq (& ename) "PATH"))
                              (util.normalize-windows-path-env (& raw-eval))
                              raw-eval)]
                          (svec.push-ref! (&mut env-names) ename)
                          (svec.push-ref! (&mut env-values) eff-eval)
                          (set! idx (+ idx 1)))
                        (set! more false))))))
              (when
                (and (not handled-env) (> nt 0))
                ;; Check leading VAR=VAL assignments without `env`
                (let
                  [more : bool true]
                  (while (and more (< idx nt))
                    (let
                      [tok : String (svec.get (& sp.tokens) idx "")]
                      [eq-pos : i64 (util.index-of-byte-from (& tok) 0 61)]
                      (if (and
                        (> eq-pos 0)
                        (util.valid-var-name?
                          (string.substring (& tok) 0 eq-pos)))
                        (let
                          [ename : String (string.substring (& tok) 0 eq-pos)]
                          [raw-eval : String
                            (string.substring
                              (& tok)
                              (+ eq-pos 1)
                              (- (string.string-length (& tok)) (+ eq-pos 1)))]
                          [eff-eval : String
                            (if (and
                              (util.host-is-windows?)
                              (string.eq (& ename) "PATH"))
                              (util.normalize-windows-path-env (& raw-eval))
                              raw-eval)]
                          (svec.push-ref! (&mut env-names) ename)
                          (svec.push-ref! (&mut env-values) eff-eval)
                          (set! idx (+ idx 1)))
                        (set! more false))))))
              (if (>= idx nt)
                (set! use-native false)
                (let
                  [cmd-exe : String (svec.get (& sp.tokens) idx "")]
                  (if (string.eq (& cmd-exe) "simd_execute")
                    (if (< (+ idx 2) nt)
                      (set! use-native false)
                      (let
                        [smode : String (svec.get (& sp.tokens) (+ idx 1) "")]
                        [real-exe : String
                          (svec.get (& sp.tokens) (+ idx 2) "")]
                        [real-args : svec.Vec (svec.new)]
                        [k : i64 (+ idx 3)]
                        (while (< k nt)
                          (svec.push-ref!
                            (&mut real-args)
                            (svec.get (& sp.tokens) k ""))
                          (set! k (+ k 1)))
                        (if (string.eq
                          (simd-execution-mode cfg (& smode))
                          "sde")
                          (let
                            [sde-args : svec.Vec (svec.new)]
                            (svec.push-ref! (&mut sde-args) "-spr")
                            (svec.push-ref! (&mut sde-args) "--")
                            (svec.push-ref! (&mut sde-args) real-exe)
                            (let
                              [j : i64 0]
                              [rn : i64 (svec.len (& real-args))]
                              (while (< j rn)
                                (svec.push-ref!
                                  (&mut sde-args)
                                  (svec.get (& real-args) j ""))
                                (set! j (+ j 1))))
                            (set!
                              res
                              (run-process-direct
                                (& cfg.sde-bin)
                                (& sde-args)
                                (& st.cwd)
                                (& env-names)
                                (& env-values)
                                sp.has-stdin
                                (& stdin-text))))
                          (set!
                            res
                            (run-process-direct
                              (& real-exe)
                              (& real-args)
                              (& st.cwd)
                              (& env-names)
                              (& env-values)
                              sp.has-stdin
                              (& stdin-text))))))
                    (if (or
                      (and handled-env (util.starts-with? (& cmd-exe) "-"))
                      (and (util.host-is-windows?) (string.eq (& cmd-exe) "sh")))
                      ;; `env -u ...` / `env -i ...` or Windows `exec sh ...` ->
                      ;; route via sh fallback so cfg.sh-bin and MSYS2 POSIX paths apply.
                      (set! use-native false)
                      (let
                        [real-args : svec.Vec (svec.new)]
                        [k : i64 (+ idx 1)]
                        (while (< k nt)
                          (svec.push-ref!
                            (&mut real-args)
                            (svec.get (& sp.tokens) k ""))
                          (set! k (+ k 1)))
                        ;; If PATH was overridden in env, resolve executable against overridden PATH!
                        (let
                          [eff-exe : String (string.copy (& cmd-exe))]
                          [ei : i64 0]
                          [en : i64 (svec.len (& env-names))]
                          (while (< ei en)
                            (when
                              (string.eq (svec.get (& env-names) ei "") "PATH")
                              (let
                                [ov-path : String
                                  (svec.get (& env-values) ei "")]
                                [found-p : String
                                  (util.resolve-executable-in-path
                                    (& cmd-exe)
                                    (& ov-path))]
                                (when
                                  (> (string.string-length (& found-p)) 0)
                                  (set! eff-exe found-p))))
                            (set! ei (+ ei 1)))
                          (set!
                            res
                            (run-process-direct
                              (& eff-exe)
                              (& real-args)
                              (& st.cwd)
                              (& env-names)
                              (& env-values)
                              sp.has-stdin
                              (& stdin-text)))))))))))))
      unit)
    (when
      (not use-native)
      (let
        [shellified : String (util.shellify-vars raw)]
        [cmd-line : String
          (if is-run
            (str_cat.str-cat "\"$COMPILER\" " shellified)
            shellified)]
        [cwd-copy : String (string.copy (& st.cwd))]
        (set! res (run-sh-fallback! cfg st (& cmd-line) (& cwd-copy) false))))
    (when
      cfg.ci-timing-enabled
      (let
        [t1 : i64 (time.ms-or (time.monotonic-ms) t0)]
        [elapsed : i64
          (if (>= t1 t0)
            (- t1 t0)
            0)]
        (record-ci-timing! cfg (& st.case-id) "step" elapsed res.exit-code)))
    (let
      [step-name : String
        (str_cat.str-cat "step" (string.int->string st.step-n))]
      (save-step-io! st (& step-name) res)
      (util.var-table-set! (&mut st.vars) "stdout" (& st.out-path))
      (util.var-table-set! (&mut st.vars) "stderr" (& st.err-path))
      (util.var-table-set!
        (&mut st.vars)
        "status"
        (string.int->string st.exit-code)))))

;; Write a `file [-n|-x] PATH` block (pre-case or in-case).
(define (write-file-block!
  [vars : (& vars util.VarTable)]
  [base-dir : (& base-dir str)]
  [raw-path : (& raw-path str)]
  [flags : (& flags str)]
  [content : (& content str)]) : unit
  (let
    [exp-path : String (util.expand-vars vars raw-path)]
    [full-path : String (util.resolve-path (& exp-path) base-dir)]
    [expand? : bool (>= (util.index-of-byte-from flags 0 120) 0)]
    [no-nl? : bool (>= (util.index-of-byte-from flags 0 110) 0)]
    [text : String
      (if expand?
        (let
          [lines : svec.Vec (util.split-lines content)]
          [n : i64 (svec.len (& lines))]
          [out : bbc.ByteBufBuilder (bbc.byte-buf-builder-new)]
          [i : i64 0]
          (while (< i n)
            (bbc.byte-buf-builder-append-string
              (&mut out)
              (util.expand-vars vars (svec.get (& lines) i "")))
            (bbc.byte-buf-builder-push (&mut out) (cast 10 : u8))
            (set! i (+ i 1)))
          (bbc.byte-buf-builder-finish-string (& out)))
        (string.copy content))]
    (when
      no-nl?
      (let
        [end : i64 (string.string-length (& text))]
        (while (and (> end 0) (= (util.byte-at (& text) (- end 1)) 10))
          (set! end (- end 1)))
        (set! text (string.substring (& text) 0 end))))
    (util.write-file! (& full-path) (& text))
    unit))

;; Try executing a single simple `sh` command natively. Returns -1 if shell fallback needed, 0 ok, 1 fail.
(define (try-native-sh-cmd!
  [cfg : (& cfg RunnerConfig)]
  [st : (&mut st VariantState)]
  [raw : (& raw str)]) : i64
  (let
    [sp : ShellParse (parse-simple-shell (& st.vars) raw)]
    (if (or (not sp.native-ok) sp.has-stdin)
      -1
      (let
        [nt : i64 (svec.len (& sp.tokens))]
        (if (= nt 0)
          0
          (let
            [head : String (svec.get (& sp.tokens) 0 "")]
            (cond
              [(string.eq (& head) ":") 0]
              [(string.eq (& head) ".")
                (if (!= nt 2)
                  -1
                  (let
                    [spath : String (svec.get (& sp.tokens) 1 "")]
                    (if (util.is-regular-file? (& spath))
                      (begin
                        (svec.push-ref! (&mut st.sourced-scripts) spath)
                        0)
                      1)))]
              [(string.eq (& head) "mkdir")
                (let
                  [i : i64 1]
                  [ok : bool true]
                  (while (and ok (< i nt))
                    (let
                      [arg : String (svec.get (& sp.tokens) i "")]
                      (when
                        (not (string.eq (& arg) "-p"))
                        (when (not (util.mkdir-all! (& arg))) (set! ok false))))
                    (set! i (+ i 1)))
                  (if ok
                    0
                    1))]
              [(string.eq (& head) "rm")
                (let
                  [i : i64 1]
                  [force : bool false]
                  [rec : bool false]
                  [ok : bool true]
                  (while (< i nt)
                    (let
                      [arg : String (svec.get (& sp.tokens) i "")]
                      (cond
                        [(string.eq (& arg) "-rf")
                          (set! force true)
                          (set! rec true)]
                        [(string.eq (& arg) "-fr")
                          (set! force true)
                          (set! rec true)]
                        [(string.eq (& arg) "-r") (set! rec true)]
                        [(string.eq (& arg) "-f") (set! force true)]
                        [(util.starts-with? (& arg) "-") (set! ok false)]
                        [else
                          (if rec
                            (util.rm-rf! (& arg))
                            (if (util.file-exists? (& arg))
                              (let
                                [narg : String (util.win-fs-path (& arg))]
                                (match (fs.try-remove-file-if-exists (& narg))
                                  [(io.OkIoUnit) unit]
                                  [(io.ErrIoUnit _)
                                    (when (not force) (set! ok false))]))
                              (when (not force) (set! ok false))))]))
                    (set! i (+ i 1)))
                  (if ok
                    0
                    1))]
              [(string.eq (& head) "cp")
                (let
                  [rec : bool false]
                  [paths : svec.Vec (svec.new)]
                  [i : i64 1]
                  [unknown-flag : bool false]
                  (while (< i nt)
                    (let
                      [arg : String (svec.get (& sp.tokens) i "")]
                      (cond
                        [(or
                            (string.eq (& arg) "-r")
                            (string.eq (& arg) "-R")
                            (string.eq (& arg) "-rp"))
                          (set! rec true)]
                        [(util.starts-with? (& arg) "-")
                          (set! unknown-flag true)]
                        [else (svec.push-ref! (&mut paths) arg)]))
                    (set! i (+ i 1)))
                  (if (or unknown-flag (!= (svec.len (& paths)) 2))
                    -1
                    (let
                      [src : String (svec.get (& paths) 0 "")]
                      [dst : String (svec.get (& paths) 1 "")]
                      [final-dst : String
                        (if (util.is-dir? (& dst))
                          (let
                            [slash : i64 (- (string.string-length (& src)) 1)]
                            (while (and
                              (>= slash 0)
                              (!= (util.byte-at (& src) slash) 47)
                              (!= (util.byte-at (& src) slash) 92))
                              (set! slash (- slash 1)))
                            (str_cat.str-cat
                              (string.copy (& dst))
                              "/"
                              (string.substring
                                (& src)
                                (+ slash 1)
                                (- (string.string-length (& src)) (+ slash 1)))))
                          (string.copy (& dst)))]
                      (if rec
                        (if (util.copy-recursive-ok? (& src) (& final-dst))
                          0
                          1)
                        (if (util.copy-file-ok? (& src) (& final-dst))
                          0
                          1)))))]
              [(string.eq (& head) "mv")
                (if (!= nt 3)
                  -1
                  (let
                    [src : String
                      (util.win-fs-path (svec.get (& sp.tokens) 1 ""))]
                    [dst : String
                      (util.win-fs-path (svec.get (& sp.tokens) 2 ""))]
                    (match (fs.try-rename (& src) (& dst))
                      [(io.OkIoUnit) 0]
                      [(io.ErrIoUnit _) 1])))]
              [(string.eq (& head) "cmp")
                (if (and
                  (= nt 4)
                  (string.eq (svec.get (& sp.tokens) 1 "") "-s"))
                  (if (util.files-equal?
                    (svec.get (& sp.tokens) 2 "")
                    (svec.get (& sp.tokens) 3 ""))
                    0
                    1)
                  -1)]
              [(string.eq (& head) "simd_execution_record")
                (if (!= nt 3)
                  -1
                  (let
                    [lbl : String (svec.get (& sp.tokens) 1 "")]
                    [smode : String (svec.get (& sp.tokens) 2 "")]
                    (simd-record-label! cfg st (& lbl) (& smode))
                    0))]
              [(string.eq (& head) "cc_link_static")
                (if (!= nt 3)
                  -1
                  (let
                    [asm : String (svec.get (& sp.tokens) 1 "")]
                    [bin : String (svec.get (& sp.tokens) 2 "")]
                    [obj : String (str_cat.str-cat (string.copy (& bin)) ".o")]
                    [as-a : svec.Vec (svec.new)]
                    (svec.push-ref! (&mut as-a) asm)
                    (svec.push-ref! (&mut as-a) "-o")
                    (svec.push-ref! (&mut as-a) (string.copy (& obj)))
                    (let
                      [r1 : ProcResult
                        (run-process-direct
                          "as"
                          (& as-a)
                          ""
                          (& (svec.new))
                          (& (svec.new))
                          false
                          "")]
                      (if (!= r1.exit-code 0)
                        1
                        (let
                          [ld-a : svec.Vec (svec.new)]
                          (svec.push-ref! (&mut ld-a) obj)
                          (svec.push-ref! (&mut ld-a) "-o")
                          (svec.push-ref! (&mut ld-a) bin)
                          (svec.push-ref! (&mut ld-a) "-static")
                          (svec.push-ref! (&mut ld-a) "-e")
                          (svec.push-ref! (&mut ld-a) "_tl_start")
                          (let
                            [r2 : ProcResult
                              (run-process-direct
                                "ld"
                                (& ld-a)
                                ""
                                (& (svec.new))
                                (& (svec.new))
                                false
                                "")]
                            (if (= r2.exit-code 0)
                              0
                              1)))))))]
              [(or (string.eq (& head) "git") (string.eq (& head) "as"))
                (let
                  [args : svec.Vec (svec.new)]
                  [k : i64 1]
                  (while (< k nt)
                    (svec.push-ref! (&mut args) (svec.get (& sp.tokens) k ""))
                    (set! k (+ k 1)))
                  (let
                    [r : ProcResult
                      (run-process-direct
                        (& head)
                        (& args)
                        ""
                        (& (svec.new))
                        (& (svec.new))
                        false
                        "")]
                    (if (= r.exit-code 0)
                      0
                      1)))]
              [else
                ;; Check if all tokens are pure CCV_x=val assignments!
                (let
                  [all-ccv : bool true]
                  [k : i64 0]
                  (while (and all-ccv (< k nt))
                    (let
                      [tok : String (svec.get (& sp.tokens) k "")]
                      [eq-p : i64 (util.index-of-byte-from (& tok) 0 61)]
                      (if (and
                        (util.starts-with? (& tok) "CCV_")
                        (> eq-p 4)
                        (util.valid-var-name?
                          (string.substring (& tok) 4 (- eq-p 4))))
                        (set! k (+ k 1))
                        (set! all-ccv false))))
                  (if all-ccv
                    (begin
                      (let
                        [j : i64 0]
                        (while (< j nt)
                          (let
                            [tok : String (svec.get (& sp.tokens) j "")]
                            [eq-p : i64 (util.index-of-byte-from (& tok) 0 61)]
                            [vn : String
                              (string.substring (& tok) 4 (- eq-p 4))]
                            [vv : String
                              (string.substring
                                (& tok)
                                (+ eq-p 1)
                                (- (string.string-length (& tok)) (+ eq-p 1)))]
                            (util.var-table-set! (&mut st.vars) (& vn) (& vv)))
                          (set! j (+ j 1))))
                      0)
                    -1))])))))))

(define (exec-sh-row!
  [cfg : (& cfg RunnerConfig)]
  [st : (&mut st VariantState)]
  [line : i64]
  [raw : (& raw str)]) : unit
  (let
    [rc : i64 (try-native-sh-cmd! cfg st raw)]
    (cond
      [(= rc 0) unit]
      [(= rc 1)
        (record-fail! st line (str_cat.str-cat "sh failed: " (string.copy raw)))]
      [else
        (let
          [shellified : String (util.shellify-vars raw)]
          [res : ProcResult (run-sh-fallback! cfg st (& shellified) "" true)]
          (when
            (!= res.exit-code 0)
            (record-fail!
              st
              line
              (str_cat.str-cat "sh failed: " (string.copy raw)))))])))

;; Native `test` predicate evaluation with sh fallback for exotic forms.
(define (eval-unary-test [flag : (& flag str)] [arg : (& arg str)]) : i64
  (cond
    [(string.eq flag "-f")
      (if (util.is-regular-file? arg)
        1
        0)]
    [(string.eq flag "-d")
      (if (util.is-dir? arg)
        1
        0)]
    [(string.eq flag "-e")
      (if (util.file-exists? arg)
        1
        0)]
    [(string.eq flag "-s")
      (if (util.file-nonempty? arg)
        1
        0)]
    [(string.eq flag "-x")
      (if (util.is-executable? arg)
        1
        0)]
    [(string.eq flag "-n")
      (if (> (string.string-length arg) 0)
        1
        0)]
    [(string.eq flag "-z")
      (if (= (string.string-length arg) 0)
        1
        0)]
    [else -1]))

(define (exec-test-row!
  [cfg : (& cfg RunnerConfig)]
  [st : (&mut st VariantState)]
  [line : i64]
  [raw : (& raw str)]) : unit
  (set! st.rows (+ st.rows 1))
  (let
    [sp : ShellParse (parse-simple-shell (& st.vars) raw)]
    [verdict : i64 -1]
    (when
      (and sp.native-ok (not sp.has-stdin))
      (let
        [nt : i64 (svec.len (& sp.tokens))]
        (cond
          [(= nt 2)
            (set!
              verdict
              (eval-unary-test
                (svec.get (& sp.tokens) 0 "")
                (svec.get (& sp.tokens) 1 "")))]
          [(and (= nt 3) (string.eq (svec.get (& sp.tokens) 0 "") "!"))
            (let
              [u : i64
                (eval-unary-test
                  (svec.get (& sp.tokens) 1 "")
                  (svec.get (& sp.tokens) 2 ""))]
              (when
                (>= u 0)
                (set!
                  verdict
                  (if (= u 0)
                    1
                    0))))]
          [(= nt 3)
            (let
              [a : String (svec.get (& sp.tokens) 0 "")]
              [op : String (svec.get (& sp.tokens) 1 "")]
              [b : String (svec.get (& sp.tokens) 2 "")]
              (cond
                [(string.eq (& op) "=")
                  (set!
                    verdict
                    (if (string.eq (& a) (& b))
                      1
                      0))]
                [(string.eq (& op) "!=")
                  (set!
                    verdict
                    (if (not (string.eq (& a) (& b)))
                      1
                      0))]
                [(or
                    (string.eq (& op) "-eq")
                    (string.eq (& op) "-ne")
                    (string.eq (& op) "-gt")
                    (string.eq (& op) "-ge")
                    (string.eq (& op) "-lt")
                    (string.eq (& op) "-le"))
                  (let
                    [pa : util.ParsedI64 (util.parse-i64-strict (& a))]
                    [pb : util.ParsedI64 (util.parse-i64-strict (& b))]
                    (when
                      (and pa.ok pb.ok)
                      (set!
                        verdict
                        (cond
                          [(string.eq (& op) "-eq")
                            (if (= pa.value pb.value)
                              1
                              0)]
                          [(string.eq (& op) "-ne")
                            (if (!= pa.value pb.value)
                              1
                              0)]
                          [(string.eq (& op) "-gt")
                            (if (> pa.value pb.value)
                              1
                              0)]
                          [(string.eq (& op) "-ge")
                            (if (>= pa.value pb.value)
                              1
                              0)]
                          [(string.eq (& op) "-lt")
                            (if (< pa.value pb.value)
                              1
                              0)]
                          [else
                            (if (<= pa.value pb.value)
                              1
                              0)]))))]
                [else unit]))]
          [else unit])))
    (when
      (< verdict 0)
      (let
        [script : String (str_cat.str-cat "[ " (util.shellify-vars raw) " ]")]
        [res : ProcResult (run-sh-fallback! cfg st (& script) "" false)]
        (set!
          verdict
          (if (= res.exit-code 0)
            1
            0))))
    (when
      (= verdict 0)
      (record-fail! st line (str_cat.str-cat "test failed: " (string.copy raw))))))

(define (exec-same-row!
  [cfg : (& cfg RunnerConfig)]
  [st : (&mut st VariantState)]
  [line : i64]
  [raw : (& raw str)]) : unit
  (set! st.rows (+ st.rows 1))
  (let
    [sp : ShellParse (parse-simple-shell (& st.vars) raw)]
    (if (and sp.native-ok (= (svec.len (& sp.tokens)) 2))
      (let
        [f1 : String (svec.get (& sp.tokens) 0 "")]
        [f2 : String (svec.get (& sp.tokens) 1 "")]
        (when
          (not (util.files-equal? (& f1) (& f2)))
          (record-fail! st line (str_cat.str-cat "files differ: " f1 " " f2))))
      (let
        [script : String (str_cat.str-cat "cmp -s " (util.shellify-vars raw))]
        [res : ProcResult (run-sh-fallback! cfg st (& script) "" false)]
        (when
          (!= res.exit-code 0)
          (record-fail!
            st
            line
            (str_cat.str-cat "files differ: " (string.copy raw))))))))

;; ---------------------------------------------------------------- plugins (check / setup)
;; Apply `s/OLD/NEW/g` or `s/OLD/NEW/` replacement.
(define (apply-simple-sed [text : (& text str)] [expr : (& expr str)]) : String
  (if (and (>= (string.string-length expr) 4) (= (util.byte-at expr 0) 115))
    (let
      [delim : i64 (util.byte-at expr 1)]
      [p1 : i64 (util.index-of-byte-from expr 2 delim)]
      [p2 : i64
        (if (>= p1 0)
          (util.index-of-byte-from expr (+ p1 1) delim)
          -1)]
      (if (< p2 0)
        (string.copy text)
        (let
          [old : String (string.substring expr 2 (- p1 2))]
          [new : String (string.substring expr (+ p1 1) (- p2 (+ p1 1)))]
          [glob : bool
            (and
              (< (+ p2 1) (string.string-length expr))
              (= (util.byte-at expr (+ p2 1)) 103))]
          [olen : i64 (string.string-length (& old))]
          (if (= olen 0)
            (string.copy text)
            (let
              [out : bbc.ByteBufBuilder (bbc.byte-buf-builder-new)]
              [lines : svec.Vec (util.split-lines text)]
              [nl : i64 (svec.len (& lines))]
              [li : i64 0]
              (while (< li nl)
                (let
                  [line : String (svec.get (& lines) li "")]
                  [llen : i64 (string.string-length (& line))]
                  [pos : i64 0]
                  [replaced : bool false]
                  [done : bool false]
                  (while (not done)
                    (let
                      [hit : i64
                        (if (and replaced (not glob))
                          -1
                          (util.index-of-str-from (& line) (& old) pos))]
                      (if (< hit 0)
                        (begin
                          (bbc.byte-buf-builder-append-string
                            (&mut out)
                            (string.substring (& line) pos (- llen pos)))
                          (set! done true))
                        (begin
                          (when
                            (> hit pos)
                            (bbc.byte-buf-builder-append-string
                              (&mut out)
                              (string.substring (& line) pos (- hit pos))))
                          (bbc.byte-buf-builder-append-string
                            (&mut out)
                            (string.copy (& new)))
                          (set! pos (+ hit olen))
                          (set! replaced true)))))
                  (bbc.byte-buf-builder-push (&mut out) (cast 10 : u8)))
                (set! li (+ li 1)))
              (bbc.byte-buf-builder-finish-string (& out)))))))
    (string.copy text)))

(define (plugin-ispc-case-tsv!
  [cfg : (& cfg RunnerConfig)]
  [st : (&mut st VariantState)]
  [args : (& args svec.Vec)]) : i64
  (if (< (svec.len args) 10)
    1
    (let
      [file-rel : String (svec.get args 0 "")]
      [case-name : String (svec.get args 1 "")]
      [lane-type : String (svec.get args 2 "")]
      [tl-sym : String (svec.get args 3 "")]
      [ispc-sym : String (svec.get args 4 "")]
      [arg-spec : String (svec.get args 5 "")]
      [reps : String (svec.get args 6 "")]
      [exits-csv : String (svec.get args 7 "")]
      [up-path : String (svec.get args 8 "")]
      [up-fn : String (svec.get args 9 "")]
      [full : String (str_cat.str-cat (string.copy (& cfg.root)) "/" file-rel)]
      [rf : util.ReadFileResult (util.read-file-result (& full))]
      (if (not rf.ok)
        (begin
          (log-err! st (str_cat.str-cat "  missing " full))
          1)
        (let
          [header : String
            "schema\tcase\tmode\ttypelisp_status\ttypelisp_diagnostic\tispc_status\tispc_diagnostic\tispc_target\tgang_width\tlane_type\ttypelisp_source\ttypelisp_symbol\tispc_source\tispc_symbol\tdriver\targuments\trepetitions\texpected_exit\tupstream_tag\tupstream_commit\tupstream_path\tupstream_function\tlicense"]
          [scalar-diag : String
            "ISPC v1.31.0 has no width-1 CPU target; smallest generic target is generic-i32x4"]
          [commit : String "c6adb4f86f5678ce6c41951b1e2b59f727455697"]
          [exits : svec.Vec (util.split-by-sep (& exits-csv) ",")]
          [want-scalar : String
            (str_cat.str-cat
              "unsupported\t"
              scalar-diag
              "\tnone\t1\t"
              (svec.get (& exits) 0 ""))]
          [want-avx2 : String
            (str_cat.str-cat
              "supported\t\tavx2-i32x8\t8\t"
              (svec.get (& exits) 1 ""))]
          [want-avx512 : String
            (str_cat.str-cat
              "supported\t\tavx512skx-x16\t16\t"
              (svec.get (& exits) 2 ""))]
          [lines : svec.Vec (util.split-lines (& rf.text))]
          [nl : i64 (svec.len (& lines))]
          [bad : bool false]
          [seen-scalar : i64 0]
          [seen-avx2 : i64 0]
          [seen-avx512 : i64 0]
          [i : i64 0]
          (while (< i nl)
            (let
              [line : String (util.strip-cr (svec.get (& lines) i ""))]
              (if (= i 0)
                (when
                  (not (string.eq (& line) (& header)))
                  (log-err! st "  invalid case.tsv header")
                  (set! bad true))
                (let
                  [cols : svec.Vec (util.split-by-sep (& line) "\t")]
                  (when
                    (or
                      (!= (svec.len (& cols)) 23)
                      (not
                        (string.eq
                          (svec.get (& cols) 0 "")
                          "typelisp-ispc-case-v1"))
                      (not (string.eq (svec.get (& cols) 1 "") (& case-name)))
                      (not (string.eq (svec.get (& cols) 3 "") "supported"))
                      (not (string.eq (svec.get (& cols) 4 "") ""))
                      (not (string.eq (svec.get (& cols) 9 "") (& lane-type)))
                      (not (string.eq (svec.get (& cols) 10 "") "bench.tl"))
                      (not (string.eq (svec.get (& cols) 11 "") (& tl-sym)))
                      (not (string.eq (svec.get (& cols) 12 "") "kernel.ispc"))
                      (not (string.eq (svec.get (& cols) 13 "") (& ispc-sym)))
                      (not (string.eq (svec.get (& cols) 14 "") "driver.c"))
                      (not (string.eq (svec.get (& cols) 15 "") (& arg-spec)))
                      (not (string.eq (svec.get (& cols) 16 "") (& reps)))
                      (not (string.eq (svec.get (& cols) 18 "") "v1.31.0"))
                      (not (string.eq (svec.get (& cols) 19 "") (& commit)))
                      (not (string.eq (svec.get (& cols) 20 "") (& up-path)))
                      (not (string.eq (svec.get (& cols) 21 "") (& up-fn)))
                      (not (string.eq (svec.get (& cols) 22 "") "BSD-3-Clause")))
                    (log-err!
                      st
                      (str_cat.str-cat
                        "  invalid case.tsv row "
                        (string.int->string (+ i 1))))
                    (set! bad true))
                  (let
                    [m : String (svec.get (& cols) 2 "")]
                    [sig : String
                      (str_cat.str-cat
                        (svec.get (& cols) 5 "")
                        "\t"
                        (svec.get (& cols) 6 "")
                        "\t"
                        (svec.get (& cols) 7 "")
                        "\t"
                        (svec.get (& cols) 8 "")
                        "\t"
                        (svec.get (& cols) 17 ""))]
                    (cond
                      [(string.eq (& m) "scalar")
                        (set! seen-scalar (+ seen-scalar 1))
                        (when
                          (not (string.eq (& sig) (& want-scalar)))
                          (log-err!
                            st
                            (str_cat.str-cat
                              "  invalid scalar target, width or exit in case.tsv row "
                              (string.int->string (+ i 1))))
                          (set! bad true))]
                      [(string.eq (& m) "avx2")
                        (set! seen-avx2 (+ seen-avx2 1))
                        (when
                          (not (string.eq (& sig) (& want-avx2)))
                          (log-err!
                            st
                            (str_cat.str-cat
                              "  invalid avx2 target, width or exit in case.tsv row "
                              (string.int->string (+ i 1))))
                          (set! bad true))]
                      [(string.eq (& m) "avx512")
                        (set! seen-avx512 (+ seen-avx512 1))
                        (when
                          (not (string.eq (& sig) (& want-avx512)))
                          (log-err!
                            st
                            (str_cat.str-cat
                              "  invalid avx512 target, width or exit in case.tsv row "
                              (string.int->string (+ i 1))))
                          (set! bad true))]
                      [else unit])))))
            (set! i (+ i 1)))
          (when
            (or
              (!= nl 4)
              (!= seen-scalar 1)
              (!= seen-avx2 1)
              (!= seen-avx512 1))
            (log-err!
              st
              "  case.tsv needs exactly one scalar, avx2 and avx512 row")
            (set! bad true))
          (if bad
            1
            0))))))

(define (plugin-for-copy-mutation!
  [cfg : (& cfg RunnerConfig)]
  [args : (& args svec.Vec)]) : i64
  (if (< (svec.len args) 1)
    1
    (let
      [dir : String (svec.get args 0 "")]
      [src-path : String
        (str_cat.str-cat (string.copy (& cfg.root)) "/stdlib/core_macros.tl")]
      [rf : util.ReadFileResult (util.read-file-result (& src-path))]
      (if (not rf.ok)
        1
        (let
          [lines : svec.Vec (util.split-lines (& rf.text))]
          [n : i64 (svec.len (& lines))]
          [out : bbc.ByteBufBuilder (bbc.byte-buf-builder-new)]
          [copying : bool false]
          [renamed : bool false]
          [done : bool false]
          [i : i64 0]
          (bbc.byte-buf-builder-append-string
            (&mut out)
            "(import stdlib.comptime)\n\n")
          (while (and (not done) (< i n))
            (let
              [line : String (svec.get (& lines) i "")]
              (when
                (util.starts-with? (& line) "(defmacro (for ")
                (set! copying true))
              (if (and copying (string.eq (& line) "(cfg"))
                (set! done true)
                (when
                  copying
                  (let
                    [emitted : String
                      (if (and
                        (not renamed)
                        (util.starts-with? (& line) "(defmacro (for "))
                        (begin
                          (set! renamed true)
                          (str_cat.str-cat
                            "(defmacro (for-copy "
                            (string.substring
                              (& line)
                              15
                              (- (string.string-length (& line)) 15))))
                        line)]
                    (bbc.byte-buf-builder-append-string (&mut out) emitted)
                    (bbc.byte-buf-builder-push (&mut out) (cast 10 : u8))))))
            (set! i (+ i 1)))
          (util.ensure-dir! (& dir))
          (let
            [dst : String (str_cat.str-cat dir "/for_copy_macros.tl")]
            (if (util.write-file-ok?
              (& dst)
              (bbc.byte-buf-builder-finish-string (& out)))
              0
              1)))))))

(define (plugin-c-oracle!
  [cfg : (& cfg RunnerConfig)]
  [st : (&mut st VariantState)]
  [args : (& args svec.Vec)]) : i64
  (if (< (svec.len args) 3)
    1
    (let
      [driver-rel : String (svec.get args 0 "")]
      [want-exit : i64 (util.parse-i64-strict (svec.get args 1 "")).value]
      [cflags-csv : String (svec.get args 2 "")]
      [cc-bin : String
        (match (env.get "CC")
          [(env.EnvSomeString v)
            (if (> (string.string-length (& v)) 0)
              v
              "clang")]
          [(env.EnvNoString) "clang"])]
      [resolved-cc : String (util.resolve-executable (& cc-bin))]
      (if (= (string.string-length (& resolved-cc)) 0)
        (begin
          (log-err! st (str_cat.str-cat "  C compiler not found: " cc-bin))
          1)
        (let
          [cflags : svec.Vec (util.split-by-sep (& cflags-csv) ",")]
          [out-bin : String
            (str_cat.str-cat
              (string.copy (& st.dir))
              "/c-oracle"
              (string.copy (& cfg.exe-ext)))]
          [cc-argv : svec.Vec (svec.new)]
          [i : i64 0]
          [ncf : i64 (svec.len (& cflags))]
          (while (< i ncf)
            (let
              [f : String (svec.get (& cflags) i "")]
              (when
                (> (string.string-length (& f)) 0)
                (svec.push-ref! (&mut cc-argv) f)))
            (set! i (+ i 1)))
          (svec.push-ref!
            (&mut cc-argv)
            (str_cat.str-cat (string.copy (& cfg.root)) "/" driver-rel))
          (svec.push-ref! (&mut cc-argv) "-o")
          (svec.push-ref! (&mut cc-argv) (string.copy (& out-bin)))
          (let
            [cr : ProcResult
              (run-process-direct
                (& resolved-cc)
                (& cc-argv)
                ""
                (& (svec.new))
                (& (svec.new))
                false
                "")]
            (if (!= cr.exit-code 0)
              (begin
                (quote-lines-err! st (& cr.stderr))
                1)
              (let
                [rr : ProcResult
                  (run-process-direct
                    (& out-bin)
                    (& (svec.new))
                    ""
                    (& (svec.new))
                    (& (svec.new))
                    false
                    "")]
                (if (or
                  (!= rr.exit-code want-exit)
                  (> (string.string-length (& rr.stdout)) 0)
                  (> (string.string-length (& rr.stderr)) 0))
                  (begin
                    (log-err!
                      st
                      (str_cat.str-cat
                        "  C oracle exited "
                        (string.int->string rr.exit-code)
                        " (expected "
                        (string.int->string want-exit)
                        ", silent)"))
                    (quote-lines-err! st (& rr.stderr))
                    1)
                  0)))))))))

(define (plugin-ispc-driver!
  [cfg : (& cfg RunnerConfig)]
  [st : (&mut st VariantState)]
  [args : (& args svec.Vec)]) : i64
  (if (< (svec.len args) 6)
    1
    (let
      [case-dir : String (svec.get args 0 "")]
      [ispc-target : String (svec.get args 1 "")]
      [gate : String (svec.get args 2 "")]
      [want-exit : i64 (util.parse-i64-strict (svec.get args 3 "")).value]
      [cflags-csv : String (svec.get args 4 "")]
      [sym-spec : String (svec.get args 5 "")]
      [ispc-bin : String
        (match (env.get "ISPC_BIN")
          [(env.EnvSomeString v)
            (if (> (string.string-length (& v)) 0)
              v
              (util.resolve-executable "ispc"))]
          [(env.EnvNoString) (util.resolve-executable "ispc")])]
      (if (= (string.string-length (& ispc-bin)) 0)
        (begin
          (log-out!
            st
            (str_cat.str-cat
              "[codegen-cases] optional ISPC "
              ispc-target
              " check skipped (set ISPC_BIN to ISPC v1.31.0)"))
          2)
        (let
          [ver-argv : svec.Vec (svec.new)]
          (svec.push-ref! (&mut ver-argv) "--version")
          (let
            [vr : ProcResult
              (run-process-direct
                (& ispc-bin)
                (& ver-argv)
                ""
                (& (svec.new))
                (& (svec.new))
                false
                "")]
            [ver-combined : String (str_cat.str-cat vr.stdout vr.stderr)]
            [ver-lines : svec.Vec (util.split-lines (& ver-combined))]
            [ver-line1 : String (svec.get (& ver-lines) 0 "")]
            (if (< (util.index-of-str-from (& ver-line1) "1.31.0" 0) 0)
              (begin
                (log-err!
                  st
                  (str_cat.str-cat "  ISPC v1.31.0 required: " ispc-bin))
                1)
              (let
                [gate-status : i64 0]
                (cond
                  [(util.starts-with? (& gate) "isa:")
                    (let
                      [req-isa : String
                        (string.substring
                          (& gate)
                          4
                          (- (string.string-length (& gate)) 4))]
                      (when
                        (not (isa-native? cfg (& req-isa)))
                        (log-out!
                          st
                          (str_cat.str-cat
                            "[codegen-cases] optional ISPC "
                            (string.copy (& ispc-target))
                            " check skipped (host lacks "
                            req-isa
                            ")"))
                        (set! gate-status 2)))]
                  [(util.starts-with? (& gate) "env:")
                    (let
                      [rest : String
                        (string.substring
                          (& gate)
                          4
                          (- (string.string-length (& gate)) 4))]
                      [colon : i64 (util.index-of-byte-from (& rest) 0 58)]
                      [vname : String (string.substring (& rest) 0 colon)]
                      [req-isa : String
                        (string.substring
                          (& rest)
                          (+ colon 1)
                          (- (string.string-length (& rest)) (+ colon 1)))]
                      [vval : String
                        (match (env.get (& vname))
                          [(env.EnvSomeString v) v]
                          [(env.EnvNoString) "0"])]
                      (if (not (string.eq (& vval) "1"))
                        (set! gate-status 2)
                        (when
                          (not (isa-native? cfg (& req-isa)))
                          (log-err!
                            st
                            (str_cat.str-cat
                              "  "
                              vname
                              "=1 requested ISPC "
                              (string.copy (& ispc-target))
                              " but the host cannot run "
                              req-isa))
                          (set! gate-status 1))))]
                  [else unit])
                (if (!= gate-status 0)
                  gate-status
                  (let
                    [cc-bin : String
                      (match (env.get "CC")
                        [(env.EnvSomeString v)
                          (if (> (string.string-length (& v)) 0)
                            v
                            "clang")]
                        [(env.EnvNoString) "clang"])]
                    [resolved-cc : String (util.resolve-executable (& cc-bin))]
                    (if (= (string.string-length (& resolved-cc)) 0)
                      (begin
                        (log-err!
                          st
                          (str_cat.str-cat "  C compiler not found: " cc-bin))
                        1)
                      (let
                        [out-dir : String
                          (str_cat.str-cat
                            (string.copy (& st.dir))
                            "/ispc-"
                            (string.copy (& ispc-target)))]
                        [obj : String
                          (str_cat.str-cat
                            (string.copy (& out-dir))
                            "/kernel.o")]
                        [hdr : String
                          (str_cat.str-cat
                            (string.copy (& out-dir))
                            "/kernel_ispc.h")]
                        [drv : String
                          (str_cat.str-cat
                            (string.copy (& out-dir))
                            "/driver"
                            (string.copy (& cfg.exe-ext)))]
                        [ia : svec.Vec (svec.new)]
                        (util.ensure-dir! (& out-dir))
                        (svec.push-ref!
                          (&mut ia)
                          (str_cat.str-cat
                            (string.copy (& cfg.root))
                            "/"
                            (string.copy (& case-dir))
                            "/kernel.ispc"))
                        (svec.push-ref! (&mut ia) "-O2")
                        (svec.push-ref! (&mut ia) "--arch=x86-64")
                        (svec.push-ref!
                          (&mut ia)
                          (str_cat.str-cat
                            "--target="
                            (string.copy (& ispc-target))))
                        (svec.push-ref! (&mut ia) "-o")
                        (svec.push-ref! (&mut ia) (string.copy (& obj)))
                        (svec.push-ref!
                          (&mut ia)
                          (str_cat.str-cat "--header-outfile=" hdr))
                        (let
                          [ir : ProcResult
                            (run-process-direct
                              (& ispc-bin)
                              (& ia)
                              ""
                              (& (svec.new))
                              (& (svec.new))
                              false
                              "")]
                          (if (!= ir.exit-code 0)
                            (begin
                              (quote-lines-err! st (& ir.stderr))
                              1)
                            (let
                              [ca : svec.Vec (svec.new)]
                              [cflags : svec.Vec
                                (util.split-by-sep (& cflags-csv) ",")]
                              [ci : i64 0]
                              [ncf : i64 (svec.len (& cflags))]
                              (while (< ci ncf)
                                (let
                                  [f : String (svec.get (& cflags) ci "")]
                                  (when
                                    (> (string.string-length (& f)) 0)
                                    (svec.push-ref! (&mut ca) f)))
                                (set! ci (+ ci 1)))
                              (svec.push-ref!
                                (&mut ca)
                                (str_cat.str-cat "-I" (string.copy (& out-dir))))
                              (svec.push-ref!
                                (&mut ca)
                                (str_cat.str-cat
                                  (string.copy (& cfg.root))
                                  "/"
                                  (string.copy (& case-dir))
                                  "/driver.c"))
                              (svec.push-ref! (&mut ca) (string.copy (& obj)))
                              (svec.push-ref! (&mut ca) "-o")
                              (svec.push-ref! (&mut ca) (string.copy (& drv)))
                              (let
                                [cr : ProcResult
                                  (run-process-direct
                                    (& resolved-cc)
                                    (& ca)
                                    ""
                                    (& (svec.new))
                                    (& (svec.new))
                                    false
                                    "")]
                                (if (!= cr.exit-code 0)
                                  (begin
                                    (quote-lines-err! st (& cr.stderr))
                                    1)
                                  (let
                                    [rr : ProcResult
                                      (run-process-direct
                                        (& drv)
                                        (& (svec.new))
                                        ""
                                        (& (svec.new))
                                        (& (svec.new))
                                        false
                                        "")]
                                    (if (or
                                      (!= rr.exit-code want-exit)
                                      (> (string.string-length (& rr.stdout)) 0)
                                      (> (string.string-length (& rr.stderr)) 0))
                                      (begin
                                        (log-err!
                                          st
                                          (str_cat.str-cat
                                            "  ISPC "
                                            ispc-target
                                            " driver exited "
                                            (string.int->string rr.exit-code)
                                            " (expected "
                                            (string.int->string want-exit)
                                            ", silent)"))
                                        (quote-lines-err! st (& rr.stderr))
                                        1)
                                      (let
                                        [sym-ok : bool true]
                                        (cond
                                          [(util.starts-with?
                                              (& sym-spec)
                                              "nm:")
                                            (let
                                              [pref : String
                                                (string.substring
                                                  (& sym-spec)
                                                  3
                                                  (-
                                                    (string.string-length
                                                      (& sym-spec))
                                                    3))]
                                              [na : svec.Vec (svec.new)]
                                              (svec.push-ref!
                                                (&mut na)
                                                "--defined-only")
                                              (svec.push-ref! (&mut na) obj)
                                              (let
                                                [nr : ProcResult
                                                  (run-process-direct
                                                    "nm"
                                                    (& na)
                                                    ""
                                                    (& (svec.new))
                                                    (& (svec.new))
                                                    false
                                                    "")]
                                                [nlines : svec.Vec
                                                  (util.split-lines
                                                    (& nr.stdout))]
                                                [nn : i64 (svec.len (& nlines))]
                                                [ni : i64 0]
                                                [hit : bool false]
                                                (while (and (not hit) (< ni nn))
                                                  (let
                                                    [w : svec.Vec
                                                      (util.split-words-blank
                                                        (svec.get
                                                          (& nlines)
                                                          ni
                                                          ""))]
                                                    (when
                                                      (and
                                                        (>= (svec.len (& w)) 3)
                                                        (util.starts-with?
                                                          (svec.get (& w) 2 "")
                                                          (& pref)))
                                                      (set! hit true)))
                                                  (set! ni (+ ni 1)))
                                                (when
                                                  (not hit)
                                                  (log-err!
                                                    st
                                                    (str_cat.str-cat
                                                      "  ISPC "
                                                      (string.copy
                                                        (& ispc-target))
                                                      " internal kernel symbol "
                                                      pref
                                                      "* missing"))
                                                  (set! sym-ok false))))]
                                          [(util.starts-with?
                                              (& sym-spec)
                                              "asm:")
                                            (let
                                              [pref : String
                                                (string.substring
                                                  (& sym-spec)
                                                  4
                                                  (-
                                                    (string.string-length
                                                      (& sym-spec))
                                                    4))]
                                              [kasm : String
                                                (str_cat.str-cat
                                                  out-dir
                                                  "/kernel.s")]
                                              [aa : svec.Vec (svec.new)]
                                              (svec.push-ref!
                                                (&mut aa)
                                                (str_cat.str-cat
                                                  (string.copy (& cfg.root))
                                                  "/"
                                                  case-dir
                                                  "/kernel.ispc"))
                                              (svec.push-ref! (&mut aa) "-O2")
                                              (svec.push-ref!
                                                (&mut aa)
                                                "--arch=x86-64")
                                              (svec.push-ref!
                                                (&mut aa)
                                                (str_cat.str-cat
                                                  "--target="
                                                  (string.copy (& ispc-target))))
                                              (svec.push-ref!
                                                (&mut aa)
                                                "--emit-asm")
                                              (svec.push-ref! (&mut aa) "-o")
                                              (svec.push-ref!
                                                (&mut aa)
                                                (string.copy (& kasm)))
                                              (let
                                                [ar : ProcResult
                                                  (run-process-direct
                                                    (& ispc-bin)
                                                    (& aa)
                                                    ""
                                                    (& (svec.new))
                                                    (& (svec.new))
                                                    false
                                                    "")]
                                                [rf : util.ReadFileResult
                                                  (util.read-file-result
                                                    (& kasm))]
                                                [pat : String
                                                  (str_cat.str-cat
                                                    "^"
                                                    (string.copy (& pref))
                                                    "[A-Za-z0-9_]*:")]
                                                (when
                                                  (or
                                                    (!= ar.exit-code 0)
                                                    (not rf.ok)
                                                    (not
                                                      (regex.regex-match-text?
                                                        (& pat)
                                                        (& rf.text)
                                                        false)))
                                                  (log-err!
                                                    st
                                                    (str_cat.str-cat
                                                      "  ISPC "
                                                      (string.copy
                                                        (& ispc-target))
                                                      " internal kernel label "
                                                      pref
                                                      "* missing"))
                                                  (set! sym-ok false))))]
                                          [else unit])
                                        (if sym-ok
                                          (begin
                                            (log-out!
                                              st
                                              (str_cat.str-cat
                                                "[codegen-cases] ISPC "
                                                ispc-target
                                                " driver passed"))
                                            0)
                                          1)))))))))))))))))))))

;; Run a named plugin (`check` or `setup`). Returns 0 pass, 1 fail, 2 skip.
(define (run-plugin!
  [cfg : (& cfg RunnerConfig)]
  [st : (&mut st VariantState)]
  [spec : (& spec str)]) : i64
  (let
    [raw-words : svec.Vec (util.split-words-blank spec)]
    [nw : i64 (svec.len (& raw-words))]
    (if (= nw 0)
      1
      (let
        [name : String (svec.get (& raw-words) 0 "")]
        [args : svec.Vec (svec.new)]
        [i : i64 1]
        (while (< i nw)
          (svec.push-ref!
            (&mut args)
            (util.expand-vars (& st.vars) (svec.get (& raw-words) i "")))
          (set! i (+ i 1)))
        (cond
          [(string.eq (& name) "asm-equals")
            (if (< (svec.len (& args)) 2)
              1
              (let
                [other-p : String (svec.get (& args) 0 "")]
                [sed-expr : String (svec.get (& args) 1 "")]
                [rf : util.ReadFileResult (util.read-file-result (& other-p))]
                (if (not rf.ok)
                  (begin
                    (log-err!
                      st
                      (str_cat.str-cat "  asm-equals: missing " other-p))
                    1)
                  (let
                    [expected : String
                      (apply-simple-sed (& rf.text) (& sed-expr))]
                    (if (string.eq (& expected) (& st.asm-text))
                      0
                      1)))))]
          [(string.eq (& name) "same-metric")
            (if (< (svec.len (& args)) 3)
              1
              (let
                [other-p : String (svec.get (& args) 0 "")]
                [label : String (svec.get (& args) 1 "")]
                [aname : String (svec.get (& args) 2 "")]
                [rf : util.ReadFileResult (util.read-file-result (& other-p))]
                (if (not rf.ok)
                  1
                  (let
                    [mine-fn : analyzers.AnalyzerResult
                      (analyzers.extract-fn (& st.asm-text) (& label) "fn")]
                    [other-fn : analyzers.AnalyzerResult
                      (analyzers.extract-fn (& rf.text) (& label) "fn")]
                    [mine-m : analyzers.AnalyzerResult
                      (analyzers.run-metric (& aname) "" (& mine-fn.value))]
                    [other-m : analyzers.AnalyzerResult
                      (analyzers.run-metric (& aname) "" (& other-fn.value))]
                    (if (string.eq (& mine-m.value) (& other-m.value))
                      0
                      (begin
                        (log-err!
                          st
                          (str_cat.str-cat
                            "  same-metric "
                            aname
                            " of "
                            label
                            ": "
                            mine-m.value
                            " here, "
                            other-m.value
                            " in "
                            other-p))
                        1))))))]
          [(string.eq (& name) "git-grep-absent")
            (if (< (svec.len (& args)) 2)
              1
              (let
                [ga : svec.Vec (svec.new)]
                (svec.push-ref! (&mut ga) "-C")
                (svec.push-ref! (&mut ga) (string.copy (& cfg.root)))
                (svec.push-ref! (&mut ga) "grep")
                (svec.push-ref! (&mut ga) "-n")
                (svec.push-ref! (&mut ga) "-E")
                (svec.push-ref! (&mut ga) (svec.get (& args) 0 ""))
                (svec.push-ref! (&mut ga) "--")
                (let
                  [k : i64 1]
                  [na : i64 (svec.len (& args))]
                  (while (< k na)
                    (svec.push-ref! (&mut ga) (svec.get (& args) k ""))
                    (set! k (+ k 1))))
                (let
                  [gr : ProcResult
                    (run-process-direct
                      "git"
                      (& ga)
                      ""
                      (& (svec.new))
                      (& (svec.new))
                      false
                      "")]
                  (if (= gr.exit-code 0)
                    (begin
                      (quote-lines-err! st (& gr.stdout))
                      1)
                    0))))]
          [(string.eq (& name) "for-copy-mutation")
            (plugin-for-copy-mutation! cfg (& args))]
          [(string.eq (& name) "files-exist")
            (if (< (svec.len (& args)) 1)
              1
              (let
                [dir : String (svec.get (& args) 0 "")]
                [k : i64 1]
                [na : i64 (svec.len (& args))]
                [rc : i64 0]
                (while (< k na)
                  (let
                    [fname : String (svec.get (& args) k "")]
                    [full : String
                      (str_cat.str-cat
                        (string.copy (& cfg.root))
                        "/"
                        (string.copy (& dir))
                        "/"
                        (string.copy (& fname)))]
                    (when
                      (not (util.is-regular-file? (& full)))
                      (log-err!
                        st
                        (str_cat.str-cat
                          "  missing "
                          (string.copy (& dir))
                          "/"
                          fname))
                      (set! rc 1)))
                  (set! k (+ k 1)))
                rc))]
          [(string.eq (& name) "ispc-case-tsv")
            (plugin-ispc-case-tsv! cfg st (& args))]
          [(string.eq (& name) "c-oracle") (plugin-c-oracle! cfg st (& args))]
          [(string.eq (& name) "ispc-driver")
            (plugin-ispc-driver! cfg st (& args))]
          [else
            (log-err! st (str_cat.str-cat "  unknown plugin: " name))
            1])))))

;; ---------------------------------------------------------------- row expectations
(define (begin-row! [st : (&mut st VariantState)]) : bool
  (cond
    [(= st.bad-subject 0)
      (set! st.rows (+ st.rows 1))
      true]
    [(= st.bad-subject 2)
      (set! st.skipped (+ st.skipped 1))
      false]
    [else false]))

(define (need-subject! [st : (&mut st VariantState)] [line : i64]) : bool
  (if st.has-subject
    true
    (if st.has-asm
      (begin
        (set! st.subject-text (string.copy (& st.asm-text)))
        (set! st.has-subject true)
        true)
      (begin
        (record-fail! st line "no subject selected")
        false))))

(define (compare-metric
  [got : (& got str)]
  [op : (& op str)]
  [want : (& want str)]) : bool
  (cond
    [(string.eq op "=") (string.eq got want)]
    [(or (string.eq op ">=") (string.eq op "<="))
      (let
        [pg : util.ParsedI64 (util.parse-u64-strict got)]
        [pw : util.ParsedI64 (util.parse-u64-strict want)]
        (if (and pg.ok pw.ok)
          (if (string.eq op ">=")
            (>= pg.value pw.value)
            (<= pg.value pw.value))
          false))]
    [else false]))

(define (contains-fixed-grep? [text : (& text str)] [needle : (& needle str)]) : bool
  (if (= (string.string-length needle) 0)
    (> (string.string-length text) 0)
    (>= (util.index-of-str-from text needle 0) 0)))

(define (count-fixed-lines [text : (& text str)] [needle : (& needle str)]) : i64
  (let
    [lines : svec.Vec (util.split-lines text)]
    [n : i64 (svec.len (& lines))]
    [count : i64 0]
    [i : i64 0]
    (while (< i n)
      (when
        (>= (util.index-of-str-from (svec.get (& lines) i "") needle 0) 0)
        (set! count (+ count 1)))
      (set! i (+ i 1)))
    count))

(define (fn-exists-in-asm? [st : (& st VariantState)] [label : (& label str)]) : bool
  (if (not st.has-asm)
    false
    (let
      [want : String (str_cat.str-cat (string.copy label) ":")]
      [lines : svec.Vec (util.split-lines (& st.asm-text))]
      [n : i64 (svec.len (& lines))]
      [i : i64 0]
      [found : bool false]
      (while (and (not found) (< i n))
        (if (string.eq (svec.get (& lines) i "") (& want))
          (set! found true)
          (set! i (+ i 1))))
      found)))

(define (word-in-list? [word : (& word str)] [list-str : (& list-str str)]) : bool
  (let
    [words : svec.Vec (util.split-words-blank list-str)]
    [n : i64 (svec.len (& words))]
    [i : i64 0]
    [found : bool false]
    (while (and (not found) (< i n))
      (if (string.eq (svec.get (& words) i "") word)
        (set! found true)
        (set! i (+ i 1))))
    found))

(define (execute-rows!
  [cfg : (& cfg RunnerConfig)]
  [st : (&mut st VariantState)]
  [cdef : (& cdef parser.CaseDef)]) : unit
  (let
    [nr : i64 (parser.case-rows-len cdef)]
    ;; If-block nesting stacks (max depth 32 is plenty)
    [cond-stack : (__tl_dyn-array i64) (__tl_make-array i64 64)]
    [parent-active : (__tl_dyn-array i64) (__tl_make-array i64 64)]
    [depth : i64 0]
    [active : bool true]
    [idx : i64 0]
    (while (< idx nr)
      (let
        [r : parser.CaseRow (parser.case-rows-get cdef idx)]
        (cond
          [(or
            (= r.kind parser.rk-if-fn)
            (= r.kind parser.rk-if-no-fn)
            (= r.kind parser.rk-if-mode)
            (= r.kind parser.rk-if-host)
            (= r.kind parser.rk-if-isa))
            (set!
              (array-ref parent-active depth)
              (if active
                1
                0))
            (let
              [ok : bool
                (if (not active)
                  false
                  (let
                    [arg : String (util.expand-vars (& st.vars) (& r.a))]
                    (cond
                      [(= r.kind parser.rk-if-fn)
                        (fn-exists-in-asm? st (& arg))]
                      [(= r.kind parser.rk-if-no-fn)
                        (not (fn-exists-in-asm? st (& arg)))]
                      [(= r.kind parser.rk-if-mode)
                        (word-in-list? (& st.mode) (& arg))]
                      [(= r.kind parser.rk-if-host)
                        (word-in-list? (& cfg.host) (& arg))]
                      [else (isa-native? cfg (& arg))])))]
              (set!
                (array-ref cond-stack depth)
                (if ok
                  1
                  0))
              (set! depth (+ depth 1))
              (set! active (and active ok)))]
          [(= r.kind parser.rk-else)
            (let
              [d : i64 (- depth 1)]
              [p-act : bool (= (array-ref parent-active d) 1)]
              [c-ok : bool (= (array-ref cond-stack d) 1)]
              (set! active (and p-act (not c-ok))))]
          [(= r.kind parser.rk-end-if)
            (set! depth (- depth 1))
            (set! active (= (array-ref parent-active depth) 1))]
          [(not active) unit]
          [(= r.kind parser.rk-run) (exec-step-row! cfg st true (& r.a))]
          [(= r.kind parser.rk-exec) (exec-step-row! cfg st false (& r.a))]
          [(= r.kind parser.rk-sh) (exec-sh-row! cfg st r.line (& r.a))]
          [(= r.kind parser.rk-cwd)
            (if (string.eq (& r.a) "-")
              (set! st.cwd "")
              (let
                [exp : String (util.expand-vars (& st.vars) (& r.a))]
                (set! st.cwd (util.resolve-path (& exp) (& st.dir)))))]
          [(= r.kind parser.rk-step)
            (set! st.step-id (util.expand-vars (& st.vars) (& r.a)))]
          [(= r.kind parser.rk-file)
            (write-file-block! (& st.vars) (& st.dir) (& r.a) (& r.b) (& r.c))]
          [(= r.kind parser.rk-test) (exec-test-row! cfg st r.line (& r.a))]
          [(= r.kind parser.rk-same) (exec-same-row! cfg st r.line (& r.a))]
          [(= r.kind parser.rk-in)
            (let
              [arg : String (util.expand-vars (& st.vars) (& r.b))]
              (set! st.bad-subject 0)
              (cond
                [(string.eq (& r.a) "asm")
                  (if st.has-asm
                    (begin
                      (set! st.subject-text (string.copy (& st.asm-text)))
                      (set! st.has-subject true))
                    (begin
                      (record-fail! st r.line "no assembly for this action")
                      (set! st.bad-subject 1)))]
                [(or (string.eq (& r.a) "stdout") (string.eq (& r.a) "stderr"))
                  (if (not st.ran)
                    (set! st.bad-subject 2)
                    (begin
                      (set!
                        st.subject-text
                        (if (string.eq (& r.a) "stdout")
                          (string.copy (& st.out-text))
                          (string.copy (& st.err-text))))
                      (set! st.has-subject true)))]
                [(string.eq (& r.a) "file")
                  (let
                    [full : String (util.resolve-path (& arg) (& cfg.root))]
                    [rf : util.ReadFileResult (util.read-file-result (& full))]
                    (if rf.ok
                      (begin
                        (set! st.subject-text rf.text)
                        (set! st.has-subject true))
                      (begin
                        (record-fail!
                          st
                          r.line
                          (str_cat.str-cat "missing file " arg))
                        (set! st.bad-subject 1))))]
                [(or (string.eq (& r.a) "fn") (string.eq (& r.a) "fn-globl"))
                  (if (not st.has-asm)
                    (begin
                      (record-fail!
                        st
                        r.line
                        (str_cat.str-cat "missing function label " arg))
                      (set! st.bad-subject 1))
                    (let
                      [ext : analyzers.AnalyzerResult
                        (analyzers.extract-fn (& st.asm-text) (& arg) (& r.a))]
                      (if ext.ok
                        (begin
                          (set! st.subject-text ext.value)
                          (set! st.has-subject true))
                        (begin
                          (record-fail!
                            st
                            r.line
                            (str_cat.str-cat "missing function label " arg))
                          (set! st.bad-subject 1)))))]
                [else
                  (record-fail!
                    st
                    r.line
                    (str_cat.str-cat "unknown subject: " r.a))
                  (set! st.bad-subject 1)]))]
          [(= r.kind parser.rk-narrow)
            (when
              (and (= st.bad-subject 0) (need-subject! st r.line))
              (let
                [spec : String (util.expand-vars (& st.vars) (& r.a))]
                [colon : i64 (util.index-of-byte-from (& spec) 0 58)]
                [wname : String
                  (if (>= colon 0)
                    (string.substring (& spec) 0 colon)
                    (string.copy (& spec)))]
                [warg : String
                  (if (>= colon 0)
                    (string.substring
                      (& spec)
                      (+ colon 1)
                      (- (string.string-length (& spec)) (+ colon 1)))
                    "")]
                [res : analyzers.AnalyzerResult
                  (analyzers.run-window (& wname) (& warg) (& st.subject-text))]
                (if (not res.ok)
                  (begin
                    (record-fail!
                      st
                      r.line
                      (str_cat.str-cat "window " spec " failed"))
                    (set! st.bad-subject 1))
                  (if (= (string.string-length (& res.value)) 0)
                    (begin
                      (record-fail!
                        st
                        r.line
                        (str_cat.str-cat "window " spec " is empty"))
                      (set! st.bad-subject 1))
                    (set! st.subject-text res.value)))))]
          [(= r.kind parser.rk-exit)
            (if (not st.ran)
              (set! st.skipped (+ st.skipped 1))
              (begin
                (set! st.rows (+ st.rows 1))
                (let
                  [want : String (string.copy (& r.a))]
                  [ok-pick : bool true]
                  (when
                    (>= (util.index-of-byte-from (& want) 0 61) 0)
                    (let
                      [words : svec.Vec (util.split-words-blank (& want))]
                      [nw : i64 (svec.len (& words))]
                      [pref : String
                        (str_cat.str-cat (string.copy (& st.mode)) "=")]
                      [pick : String ""]
                      [wi : i64 0]
                      (while (< wi nw)
                        (let
                          [w : String (svec.get (& words) wi "")]
                          (when
                            (util.starts-with? (& w) (& pref))
                            (set!
                              pick
                              (string.substring
                                (& w)
                                (string.string-length (& pref))
                                (-
                                  (string.string-length (& w))
                                  (string.string-length (& pref)))))))
                        (set! wi (+ wi 1)))
                      (if (= (string.string-length (& pick)) 0)
                        (let
                          [msg : String
                            (str_cat.str-cat
                              "no expected exit status for mode "
                              (string.copy (& st.mode)))]
                          (record-fail! st r.line (& msg))
                          (set! ok-pick false))
                        (set! want pick))))
                  (when
                    ok-pick
                    (if (string.eq (& want) "nonzero")
                      (when
                        (= st.exit-code 0)
                        (record-fail!
                          st
                          r.line
                          "exited 0, expected a nonzero status"))
                      (let
                        [wn : i64 (util.parse-i64-strict (& want)).value]
                        (when
                          (!= st.exit-code wn)
                          (record-fail!
                            st
                            r.line
                            (str_cat.str-cat
                              "exited "
                              (string.int->string st.exit-code)
                              ", expected "
                              want))
                          (log-err! st "  stderr:")
                          (quote-st-err-err! st))))))))]
          [(= r.kind parser.rk-contains)
            (when
              (and (begin-row! st) (need-subject! st r.line))
              (let
                [needle : String (util.expand-vars (& st.vars) (& r.a))]
                (when
                  (not (contains-fixed-grep? (& st.subject-text) (& needle)))
                  (record-fail!
                    st
                    r.line
                    (str_cat.str-cat "missing text: " needle)))))]
          [(= r.kind parser.rk-is)
            (when
              (and (begin-row! st) (need-subject! st r.line))
              (let
                [want : String (util.expand-vars (& st.vars) (& r.a))]
                [want-nl : String (str_cat.str-cat (string.copy (& want)) "\n")]
                (when
                  (not (string.eq (& st.subject-text) (& want-nl)))
                  (record-fail!
                    st
                    r.line
                    (str_cat.str-cat "expected exactly: " want))
                  (quote-st-subject-err! st))))]
          [(= r.kind parser.rk-not-contains)
            (when
              (and (begin-row! st) (need-subject! st r.line))
              (let
                [needle : String (util.expand-vars (& st.vars) (& r.a))]
                (when
                  (contains-fixed-grep? (& st.subject-text) (& needle))
                  (record-fail!
                    st
                    r.line
                    (str_cat.str-cat "contains forbidden text: " needle)))))]
          [(= r.kind parser.rk-contains-any)
            (when
              (and (begin-row! st) (need-subject! st r.line))
              (let
                [alts : svec.Vec (util.split-by-sep (& r.a) " || ")]
                [na : i64 (svec.len (& alts))]
                [ai : i64 0]
                [hit : bool false]
                (while (and (not hit) (< ai na))
                  (let
                    [cand : String
                      (util.expand-vars (& st.vars) (svec.get (& alts) ai ""))]
                    (when
                      (contains-fixed-grep? (& st.subject-text) (& cand))
                      (set! hit true)))
                  (set! ai (+ ai 1)))
                (when
                  (not hit)
                  (record-fail!
                    st
                    r.line
                    (str_cat.str-cat "missing all of: " r.a))
                  (quote-st-subject-err! st))))]
          [(= r.kind parser.rk-order)
            (when
              (and (begin-row! st) (need-subject! st r.line))
              (let
                [alts : svec.Vec (util.split-by-sep (& r.a) " || ")]
                [lines : svec.Vec (util.split-lines (& st.subject-text))]
                [nl : i64 (svec.len (& lines))]
                [na : i64 (svec.len (& alts))]
                [prev : i64 0]
                [ai : i64 0]
                [failed-ord : bool false]
                (while (and (not failed-ord) (< ai na))
                  (let
                    [needle : String
                      (util.expand-vars (& st.vars) (svec.get (& alts) ai ""))]
                    [found-line : i64 0]
                    [li : i64 0]
                    (while (and (= found-line 0) (< li nl))
                      (when
                        (>=
                          (util.index-of-str-from
                            (svec.get (& lines) li "")
                            (& needle)
                            0)
                          0)
                        (set! found-line (+ li 1)))
                      (set! li (+ li 1)))
                    (if (or (= found-line 0) (<= found-line prev))
                      (begin
                        (record-fail!
                          st
                          r.line
                          (str_cat.str-cat "out of order or missing: " needle))
                        (set! failed-ord true))
                      (set! prev found-line)))
                  (set! ai (+ ai 1)))))]
          [(or (= r.kind parser.rk-match) (= r.kind parser.rk-match-i))
            (when
              (and (begin-row! st) (need-subject! st r.line))
              (let
                [pat : String (util.expand-vars (& st.vars) (& r.a))]
                [ci : bool (= r.kind parser.rk-match-i)]
                (when
                  (not (regex.regex-match-text? (& pat) (& st.subject-text) ci))
                  (record-fail!
                    st
                    r.line
                    (str_cat.str-cat "missing regex: " pat)))))]
          [(or (= r.kind parser.rk-not-match) (= r.kind parser.rk-not-match-i))
            (when
              (and (begin-row! st) (need-subject! st r.line))
              (let
                [pat : String (util.expand-vars (& st.vars) (& r.a))]
                [ci : bool (= r.kind parser.rk-not-match-i)]
                (when
                  (regex.regex-match-text? (& pat) (& st.subject-text) ci)
                  (record-fail!
                    st
                    r.line
                    (str_cat.str-cat "contains forbidden regex: " pat)))))]
          [(or (= r.kind parser.rk-count) (= r.kind parser.rk-count-fixed))
            (when
              (and (begin-row! st) (need-subject! st r.line))
              (let
                [pat : String (util.expand-vars (& st.vars) (& r.b))]
                [got : i64
                  (if (= r.kind parser.rk-count)
                    (regex.regex-count-lines (& pat) (& st.subject-text) false)
                    (count-fixed-lines (& st.subject-text) (& pat)))]
                [got-s : String (string.int->string got)]
                [want-s : String (string.int->string r.n)]
                (when
                  (not (compare-metric (& got-s) (& r.a) (& want-s)))
                  (record-fail!
                    st
                    r.line
                    (str_cat.str-cat
                      "expected "
                      r.a
                      " "
                      want-s
                      " match(es) of ["
                      pat
                      "], got "
                      got-s)))))]
          [(= r.kind parser.rk-next-line)
            (when
              (and (begin-row! st) (need-subject! st r.line))
              (let
                [p1 : String (util.expand-vars (& st.vars) (& r.a))]
                [p2 : String (util.expand-vars (& st.vars) (& r.b))]
                [re1 : regex.RegexProg (regex.regex-compile (& p1) false)]
                [re2 : regex.RegexProg (regex.regex-compile (& p2) false)]
                [lines : svec.Vec (util.split-lines (& st.subject-text))]
                [nl : i64 (svec.len (& lines))]
                [found-first : bool false]
                [ok-next : bool false]
                [li : i64 0]
                (while (and (not found-first) (< li nl))
                  (if (regex.regex-match-line?
                    (& re1)
                    (svec.get (& lines) li ""))
                    (begin
                      (set! found-first true)
                      (when
                        (< (+ li 1) nl)
                        (set!
                          ok-next
                          (regex.regex-match-line?
                            (& re2)
                            (svec.get (& lines) (+ li 1) "")))))
                    (set! li (+ li 1))))
                (when
                  (not ok-next)
                  (record-fail!
                    st
                    r.line
                    (str_cat.str-cat
                      "expected /"
                      p2
                      "/ on the line after /"
                      p1
                      "/")))))]
          [(or (= r.kind parser.rk-empty) (= r.kind parser.rk-not-empty))
            (when
              (and (begin-row! st) (need-subject! st r.line))
              (if (= r.kind parser.rk-empty)
                (when
                  (> (string.string-length (& st.subject-text)) 0)
                  (record-fail! st r.line "expected empty output")
                  (quote-st-subject-err! st))
                (when
                  (= (string.string-length (& st.subject-text)) 0)
                  (record-fail! st r.line "expected non-empty output"))))]
          [(= r.kind parser.rk-metric)
            (when
              (and (begin-row! st) (need-subject! st r.line))
              (let
                [spec : String (util.expand-vars (& st.vars) (& r.a))]
                [want : String (util.expand-vars (& st.vars) (& r.c))]
                [colon : i64 (util.index-of-byte-from (& spec) 0 58)]
                [mname : String
                  (if (>= colon 0)
                    (string.substring (& spec) 0 colon)
                    (string.copy (& spec)))]
                [marg : String
                  (if (>= colon 0)
                    (string.substring
                      (& spec)
                      (+ colon 1)
                      (- (string.string-length (& spec)) (+ colon 1)))
                    "")]
                [res : analyzers.AnalyzerResult
                  (analyzers.run-metric (& mname) (& marg) (& st.subject-text))]
                [got : String
                  (if res.ok
                    res.value
                    "analyzer-error")]
                (when
                  (not (compare-metric (& got) (& r.b) (& want)))
                  (record-fail!
                    st
                    r.line
                    (str_cat.str-cat
                      "metric "
                      spec
                      ": expected "
                      r.b
                      " "
                      want
                      ", got "
                      got)))))]
          [(= r.kind parser.rk-capture)
            (when
              (and (begin-row! st) (need-subject! st r.line))
              (let
                [pat : String (util.expand-vars (& st.vars) (& r.b))]
                [prog : regex.RegexProg (regex.regex-compile (& pat) false)]
                [lines : svec.Vec (util.split-lines (& st.subject-text))]
                [nl : i64 (svec.len (& lines))]
                [val : String ""]
                [found : bool false]
                [li : i64 0]
                (while (and (not found) (< li nl))
                  (let
                    [line : String (svec.get (& lines) li "")]
                    [m : regex.RegexMatch
                      (regex.regex-find-line (& prog) (& line))]
                    (when
                      m.matched
                      (set! found true)
                      (when
                        m.g1-ok
                        (let
                          [prefix : String
                            (string.substring (& line) 0 m.start)]
                          [g1 : String
                            (string.substring
                              (& line)
                              m.g1-start
                              (- m.g1-end m.g1-start))]
                          [suffix : String
                            (string.substring
                              (& line)
                              m.end
                              (- (string.string-length (& line)) m.end))]
                          (set! val (str_cat.str-cat prefix g1 suffix))))))
                  (set! li (+ li 1)))
                (util.var-table-set! (&mut st.vars) (& r.a) (& val))
                (when
                  (= (string.string-length (& val)) 0)
                  (record-fail!
                    st
                    r.line
                    (str_cat.str-cat "capture " r.a ": no line matches " pat)))))]
          [(= r.kind parser.rk-check)
            (when
              (begin-row! st)
              (let
                [rc : i64 (run-plugin! cfg st (& r.a))]
                (cond
                  [(= rc 0) unit]
                  [(= rc 2)
                    (set! st.rows (- st.rows 1))
                    (set! st.skipped (+ st.skipped 1))]
                  [else
                    (let
                      [words : svec.Vec (util.split-words-blank (& r.a))]
                      [pname : String (svec.get (& words) 0 "")]
                      (record-fail!
                        st
                        r.line
                        (str_cat.str-cat "check " pname " failed")))])))]
          [else unit]))
      (set! idx (+ idx 1)))))

;; Execute one complete variant (intended to run inside its own scratch arena!).
(define (run-single-variant
  [cfg : (& cfg RunnerConfig)]
  [file-path : (& file-path str)]
  [work-dir : (& work-dir str)]
  [native-work-dir : (& native-work-dir str)]
  [cdef : (& cdef parser.CaseDef)]
  [target : (& target str)]
  [opt : (& opt str)]
  [mode : (& mode str)]
  [each : (& each str)]
  [variant-idx : i64]) : VariantResult
  (let
    [vname : String (variant-name-of target opt mode each)]
    [dir : String
      (if (string.eq (& vname) "default")
        (str_cat.str-cat (string.copy work-dir) "/" (string.copy (& cdef.id)))
        (str_cat.str-cat
          (string.copy work-dir)
          "/"
          (string.copy (& cdef.id))
          "/"
          (string.copy (& vname))))]
    [native-dir : String
      (util.to-native-path (& dir) (& cfg.root) (& cfg.native-root))]
    [st : VariantState
      (VariantState
        (string.copy file-path)
        (string.copy work-dir)
        (string.copy native-work-dir)
        (string.copy (& cdef.id))
        cdef.line
        (string.copy (& vname))
        (string.copy target)
        (string.copy opt)
        (string.copy mode)
        (string.copy each)
        (string.copy (& dir))
        (string.copy (& native-dir))
        ""
        ""
        0
        false
        0
        0
        0
        0
        0
        0
        true
        0
        ""
        ""
        false
        (str_cat.str-cat (string.copy (& dir)) "/none.stdout")
        ""
        (str_cat.str-cat (string.copy (& dir)) "/none.stderr")
        ""
        ""
        false
        0
        ""
        (svec.new)
        ""
        (util.var-table-new)
        (svec.new)
        (bbc.byte-buf-builder-new)
        (bbc.byte-buf-builder-new))]
    (util.rm-rf! (& dir))
    (util.ensure-dir! (& dir))
    (util.write-file! (& st.out-path) "")
    (util.write-file! (& st.err-path) "")
    ;; Populate built-in {{...}} variables
    (util.var-table-set! (&mut st.vars) "root" (& cfg.root))
    (util.var-table-set! (&mut st.vars) "native-root" (& cfg.native-root))
    (util.var-table-set! (&mut st.vars) "work" work-dir)
    (util.var-table-set! (&mut st.vars) "native-work" native-work-dir)
    (util.var-table-set! (&mut st.vars) "dir" (& dir))
    (util.var-table-set! (&mut st.vars) "native-dir" (& native-dir))
    (util.var-table-set! (&mut st.vars) "target" target)
    (util.var-table-set! (&mut st.vars) "opt" opt)
    (util.var-table-set! (&mut st.vars) "mode" mode)
    (util.var-table-set! (&mut st.vars) "each" each)
    (util.var-table-set! (&mut st.vars) "host" (& cfg.host))
    (util.var-table-set! (&mut st.vars) "host-target" (& cfg.host-target))
    (util.var-table-set! (&mut st.vars) "exe" (& cfg.exe-ext))
    (util.var-table-set! (&mut st.vars) "lib-prefix" (& cfg.lib-prefix))
    (util.var-table-set! (&mut st.vars) "lib-suffix" (& cfg.lib-suffix))
    (util.var-table-set! (&mut st.vars) "compiler" (& cfg.compiler))
    ;; Resolve source path
    (when
      (> (string.string-length (& cdef.source)) 0)
      (let
        [exp-src : String (util.expand-vars (& st.vars) (& cdef.source))]
        (set! st.source-path (util.resolve-path (& exp-src) (& cfg.root)))))
    ;; Build compiler flags vector & cache key string
    (let
      [fk : bbc.ByteBufBuilder (bbc.byte-buf-builder-new)]
      (when
        (not (string.eq target "-"))
        (svec.push-ref! (&mut st.flags) "--target")
        (svec.push-ref! (&mut st.flags) (string.copy target))
        (bbc.byte-buf-builder-append-string (&mut fk) " --target ")
        (bbc.byte-buf-builder-append-string (&mut fk) (string.copy target)))
      (when
        (not (string.eq opt "-"))
        (svec.push-ref! (&mut st.flags) "--opt-level")
        (svec.push-ref! (&mut st.flags) (string.copy opt))
        (bbc.byte-buf-builder-append-string (&mut fk) " --opt-level ")
        (bbc.byte-buf-builder-append-string (&mut fk) (string.copy opt)))
      (when
        (not (string.eq mode "-"))
        (svec.push-ref! (&mut st.flags) "--backend-mode")
        (svec.push-ref! (&mut st.flags) (string.copy mode))
        (bbc.byte-buf-builder-append-string (&mut fk) " --backend-mode ")
        (bbc.byte-buf-builder-append-string (&mut fk) (string.copy mode)))
      (let
        [exp-args : String (util.expand-vars (& st.vars) (& cdef.args))]
        [aw : svec.Vec (util.split-words-blank (& exp-args))]
        [na : i64 (svec.len (& aw))]
        [ai : i64 0]
        (while (< ai na)
          (let
            [w : String (svec.get (& aw) ai "")]
            (svec.push-ref! (&mut st.flags) (string.copy (& w)))
            (bbc.byte-buf-builder-push (&mut fk) (cast 32 : u8))
            (bbc.byte-buf-builder-append-string (&mut fk) w))
          (set! ai (+ ai 1))))
      (set! st.flags-key (bbc.byte-buf-builder-finish-string (& fk))))
    ;; Run setup plugins
    (let
      [setup-ok : bool true]
      [ns : i64 (svec.len (& cdef.setups))]
      [si : i64 0]
      (while (and setup-ok (< si ns))
        (when
          (!= (run-plugin! cfg (&mut st) (svec.get (& cdef.setups) si "")) 0)
          (record-fail! (&mut st) cdef.line "setup failed")
          (set! setup-ok false))
        (set! si (+ si 1)))
      (when
        setup-ok
        (when
          (do-case-action! cfg (&mut st) cdef)
          (if (and (not cdef.has-exit) st.ran (!= st.exit-code 0))
            (begin
              (record-fail!
                (&mut st)
                cdef.line
                (str_cat.str-cat
                  (string.copy (& cdef.do-action))
                  " exited "
                  (string.int->string st.exit-code)
                  ", expected 0"))
              (log-err! (&mut st) "  stderr:")
              (quote-st-err-err! (&mut st)))
            (execute-rows! cfg (&mut st) cdef)))))
    (when
      (not st.failed)
      (if st.ran
        (log-out!
          (&mut st)
          (str_cat.str-cat
            "[codegen-cases] PASS "
            (string.copy (& cdef.id))
            " ["
            vname
            "]"))
        (log-out!
          (&mut st)
          (str_cat.str-cat
            "[codegen-cases] PASS "
            (string.copy (& cdef.id))
            " ["
            vname
            "] (run skipped: host cannot execute "
            (string.copy mode)
            ")"))))
    (VariantResult
      variant-idx
      st.failures
      st.rows
      st.skipped
      st.simd-native
      st.simd-emulated
      st.simd-skipped
      (bbc.byte-buf-builder-finish-string (& st.stdout-buf))
      (bbc.byte-buf-builder-finish-string (& st.stderr-buf)))))