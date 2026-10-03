;; test_cli_core.tl - Selfhost test command logic.
;;
;; Discovers source-owned `(test name body...)` declarations through the
;; selfhost loader, lowers them into private unit-returning functions plus a
;; generated `main`, then assembles, links, and runs that generated harness
;; directly. Imported files provide runtime declarations but do not contribute
;; their own tests to this source's harness. Normal compile paths ignore
;; `AstDecl.Test`.
(import compiler_owned_view as owned_view)
(import stdlib.arena)
(import stdlib.byte_buf)
(import stdlib.cpu)
(import stdlib.io)
(import stdlib.process)
(import stdlib.random)
(import stdlib.hashmap)
(import (hashmap.hashmap i64 i64) as tltest_name_map)
(import stdlib.vector)
(import (vector.vector String) as cli_svec)
(import cli_option_core as cli_option)
(import build_run_core)
(import compiler_ast_types as ast)
(import compiler_backend)
(import compiler_builtin_ids as cbi)
(import compiler_diagnostic as cdiag)
(import compiler_driver_core as driver)
(import compiler_intern as ci)
(import compiler_intern_state as cis)
(import compiler_cfg_core as cfg_core)
(import compiler_load)
(import compiler_lower as lower)
(import package_source_core)
(import compiler_optimize)
(import compiler_symbols as csym)
(import compiler_typecheck_api)
(import compiler_typecheck_core as tc_core)
(import stdlib.string)
(import source_text_core as source_text)
(import stdlib.str_cat_runtime as str_cat)
(import sym_i64_env)

(defenum TestMode
  (Run)
  (Check))

(defenum TestConfig
  (File
    String
    String
    compiler_backend.CompilerBackendMode
    cli_svec.Vec
    i64
    TestMode)
  (Batch
    cli_svec.Vec
    String
    compiler_backend.CompilerBackendMode
    cli_svec.Vec
    i64
    TestMode)
  (Package
    String
    bool
    String
    compiler_backend.CompilerBackendMode
    cli_svec.Vec
    i64
    TestMode))

(defenum ResultTestConfig
  (Ok TestConfig)
  (Err String))

(defenum TestMaybeString
  (No)
  (Some String))

(defenum ResultTestBatchPaths
  (Ok cli_svec.Vec)
  (Err String))

(defenum ResultTestSeed
  (Ok u64)
  (Err String))

(defenum InlineTestSelection
  (Run)
  (Ignored String)
  (SlowSkipped))

(defenum InlineTest
  (Case String String i64 i64 i64 String i64 i64 InlineTestSelection))

(defenum InlineCollect
  (Collect ast.AstDeclList ast.AstDeclPathList (__tl_dyn-array InlineTest)))

(defenum InlineHarness
  (Harness ast.AstProgram ast.AstDeclPathList i64))

(defenum InlineRuntimeDecls
  (Decls ast.AstDeclList ast.AstDeclPathList))

(defenum ResultTestPackageTotals
  (Ok i64 i64)
  (Failed i64 i64 i64)
  (Err i64))

(defenum ResultTestFileCheck
  (Ok i64)
  (Failed i64)
  (Err i64))

(define tltest-failed-count-offset : i64
  1000000000)
(define tltest-prefix-cache-stats : bool
  false)
(define tltest-list-only : bool
  false)
(define tltest-name-filter-set : bool
  false)
(define tltest-name-filter : String
  "")
(define tltest-name-exact-set : bool
  false)
(define tltest-name-exact : String
  "")
(define tltest-include-ignored : bool
  false)
(define tltest-include-slow : bool
  false)
(define tltest-shuffle : bool
  false)
(define tltest-seed-set : bool
  false)
(define tltest-seed : u64
  (cast 0 : u64))
(define tltest-user-cfg-slots : cli_svec.Vec
  (cli_svec.new))
(define tltest-user-cfg-len : i64
  0)

(define (tltest-user-cfg-reset!) : unit
  (set! tltest-user-cfg-slots (cli_svec.new))
  (set! tltest-user-cfg-len 0))

(define (tltest-user-cfg-push! [name : String]) : unit
  (cli_svec.push-ref! (&mut tltest-user-cfg-slots) name)
  (set! tltest-user-cfg-len (+ tltest-user-cfg-len 1)))

(define (tltest-selection-set?) : bool
  (or tltest-name-filter-set tltest-name-exact-set))

(define (tltest-seed-digit? [c : char]) : bool
  (and (>= c '0') (<= c '9')))

(define (tltest-parse-seed [text : String]) : ResultTestSeed
  (let
    [count : i64 (string.string-length text)]
    [index : i64 0]
    [value : u64 (cast 0 : u64)]
    [max-value : u64 (bit-not (cast 0 : u64))]
    [ok : bool (> count 0)]
    (while (and ok (< index count))
      (let
        [c : char (string.string-ref text index)]
        (if (tltest-seed-digit? c)
          (let
            [digit : u64 (cast (- (cast c : i64) (cast '0' : i64)) : u64)]
            (if (> value (/ (- max-value digit) (cast 10 : u64)))
              (set! ok false)
              (set! value (+ (* value (cast 10 : u64)) digit))))
          (set! ok false)))
      (set! index (+ index 1)))
    (if ok
      (Ok value)
      (Err "test: --seed expects an unsigned 64-bit decimal integer"))))

(define (tltest-u64-decimal [value : u64]) : String
  (let
    [digits : (__tl_dyn-array u8) (__tl_make-array u8 20)]
    [cursor : u64 value]
    [start : i64 20]
    [done : bool false]
    (while (not done)
      (let
        [digit : u64 (% cursor (cast 10 : u64))]
        (set! start (- start 1))
        (set! (array-ref digits start) (cast (+ digit (cast 48 : u64)) : u8))
        (set! cursor (/ cursor (cast 10 : u64)))
        (if (= cursor (cast 0 : u64))
          (set! done true)
          unit)))
    (unsafe
      (string-from-bytes
        (ptr-offset (ptr-cast (__tl_array-data digits) : (Ptr u8)) start)
        (- 20 start)))))

;; The generated harness is built after parsing, so its private helper/local
;; identities must not enter the source-symbol hash table. Cache one opaque id
;; per active intern pool and rebuild after file-state reset/state install.
(define tltest-synthetic-id-generation : i64
  -1)
(define tltest-synthetic-id-table-id : i64
  -1)
(define tltest-print-error-id-cache : i64
  -1)
(define tltest-write-id-cache : i64
  -1)
(define tltest-get-std-handle-id-cache : i64
  -1)
(define tltest-write-file-id-cache : i64
  -1)
(define tltest-fd-id-cache : i64
  -1)
(define tltest-buf-id-cache : i64
  -1)
(define tltest-handle-id-cache : i64
  -1)
(define tltest-ok-id-cache : i64
  -1)
(define tltest-text-id-cache : i64
  -1)
(define tltest-runtime-import-alias-id-cache : i64
  -1)

(define (tltest-synthetic-ids-current?) : bool
  (and
    (= tltest-synthetic-id-generation (ci.intern-generation))
    (= tltest-synthetic-id-table-id (ci.intern-active-table-id))))

(define (tltest-synthetic-ids-refresh!) : unit
  (cbi.compiler-builtin-refresh!)
  (unless
    (tltest-synthetic-ids-current?)
    (set!
      tltest-print-error-id-cache
      (ci.intern-generated-name "__tl_test_print_error"))
    (set! tltest-write-id-cache (ci.intern-generated-name "__tl_test_write"))
    (set!
      tltest-get-std-handle-id-cache
      (ci.intern-generated-name "__tl_test_get_std_handle"))
    (set!
      tltest-write-file-id-cache
      (ci.intern-generated-name "__tl_test_write_file"))
    (set! tltest-fd-id-cache (ci.intern-generated-name "fd"))
    (set! tltest-buf-id-cache (ci.intern-generated-name "buf"))
    (set! tltest-handle-id-cache (ci.intern-generated-name "handle"))
    (set! tltest-ok-id-cache (ci.intern-generated-name "ok"))
    (set! tltest-text-id-cache (ci.intern-generated-name "text"))
    (set!
      tltest-runtime-import-alias-id-cache
      (ci.intern-generated-name "__tl_test_runtime"))
    (set! tltest-synthetic-id-generation (ci.intern-generation))
    (set! tltest-synthetic-id-table-id (ci.intern-active-table-id))))

(define (tltest-main-id) : i64
  (cbi.compiler-builtin-refresh!)
  cbi.compiler-builtin-id-fix-main)

(define (tltest-empty-name-id) : i64
  (cbi.compiler-builtin-refresh!)
  cbi.compiler-builtin-id-fix-empty)

(define (tltest-n-id) : i64
  (cbi.compiler-builtin-refresh!)
  cbi.compiler-builtin-id-fix-n)

(define (tltest-print-error-id) : i64
  (tltest-synthetic-ids-refresh!)
  tltest-print-error-id-cache)

(define (tltest-write-id) : i64
  (tltest-synthetic-ids-refresh!)
  tltest-write-id-cache)

(define (tltest-get-std-handle-id) : i64
  (tltest-synthetic-ids-refresh!)
  tltest-get-std-handle-id-cache)

(define (tltest-write-file-id) : i64
  (tltest-synthetic-ids-refresh!)
  tltest-write-file-id-cache)

(define (tltest-fd-id) : i64
  (tltest-synthetic-ids-refresh!)
  tltest-fd-id-cache)

(define (tltest-buf-id) : i64
  (tltest-synthetic-ids-refresh!)
  tltest-buf-id-cache)

(define (tltest-handle-id) : i64
  (tltest-synthetic-ids-refresh!)
  tltest-handle-id-cache)

(define (tltest-ok-id) : i64
  (tltest-synthetic-ids-refresh!)
  tltest-ok-id-cache)

(define (tltest-text-id) : i64
  (tltest-synthetic-ids-refresh!)
  tltest-text-id-cache)

(define (tltest-runtime-suite-begin-id) : i64
  (ci.intern "runtime-test-suite-begin!"))

(define (tltest-runtime-case-begin-id) : i64
  (ci.intern "runtime-test-case-begin!"))

(define (tltest-runtime-case-finish-id) : i64
  (ci.intern "runtime-test-case-finish!"))

(define (tltest-runtime-suite-finish-id) : i64
  (ci.intern "runtime-test-suite-finish-with-skips"))

(define (tltest-runtime-import-alias-id) : i64
  (tltest-synthetic-ids-refresh!)
  tltest-runtime-import-alias-id-cache)

(define (tltest-runtime-call-id [leaf-id : i64]) : i64
  (cbi.compiler-builtin-refresh!)
  (ci.intern-generated-canonical-qualified-name
    (tc_core.tc-hygiene-global-context-name
      (ci.intern-str cbi.compiler-builtin-id-runtime-module)
      (ci.intern-str leaf-id))
    cbi.compiler-builtin-id-runtime-module
    leaf-id))

(define (tltest-unknown-target [value : String]) : String
  (str_cat.str-cat "test: unknown target " value ""))

(define (tltest-invalid-opt-level [value : String]) : String
  (str_cat.str-cat "test: invalid --opt-level " value "; expected 0, 1, or 2"))

(define (tltest-batch-paths-from-text-from
  [text : (& text str)]
  [start : i64]
  [n : i64]
  [paths : cli_svec.Vec]) : cli_svec.Vec
  (if (>= start n)
    paths
    (let
      [line-end : i64 (source_text.line-end text start)]
      [next-start : i64 (source_text.next-line-start text line-end)]
      (if (= start line-end)
        (tltest-batch-paths-from-text-from text next-start n paths)
        (tltest-batch-paths-from-text-from
          text
          next-start
          n
          (let
            [next-paths : cli_svec.Vec paths]
            (cli_svec.push-ref!
              (&mut next-paths)
              (string.substring text start (- line-end start)))
            next-paths))))))

(define (tltest-batch-paths-from-text [text : String]) : cli_svec.Vec
  (tltest-batch-paths-from-text-from
    text
    0
    (string.string-length text)
    (cli_svec.new)))

(define (tltest-batch-paths [list-path : String]) : ResultTestBatchPaths
  (match (io.try-read-file (& list-path))
    [(OkIoBytes contents)
      (ResultTestBatchPaths.Ok
        (tltest-batch-paths-from-text (byte_buf.to-string contents)))]
    [(ErrIoBytes error)
      (Err
        (str_cat.str-cat
          "test: failed to read --batch list file: "
          (io.error-message error)))]))

(define (tltest-config-finish
  [source : String]
  [has-source : bool]
  [manifest-path : String]
  [has-manifest : bool]
  [target : String]
  [mode : compiler_backend.CompilerBackendMode]
  [roots : cli_svec.Vec]
  [opt-level : i64]
  [test-mode : TestMode]
  [batch-list : TestMaybeString]) : ResultTestConfig
  (if (and tltest-seed-set (not tltest-shuffle))
    (Err "test: --seed requires --shuffle")
    (match batch-list
      [(Some list-path)
        (cond
          [(and tltest-list-only tltest-prefix-cache-stats)
            (Err "test: --prefix-cache-stats cannot be combined with --list")]
          [has-manifest
            (Err "test: cannot combine --batch with --manifest-path")]
          [has-source (Err "test: cannot combine input paths with --batch")]
          [else
            (match (tltest-batch-paths list-path)
              [(Ok paths)
                (if (cli_svec.is-empty? (& paths))
                  (Err "test: --batch list is empty")
                  (Ok
                    (TestConfig.Batch
                      paths
                      target
                      mode
                      roots
                      opt-level
                      test-mode)))]
              [(Err message) (Err message)])])]
      [(No)
        (if tltest-prefix-cache-stats
          (Err "test: --prefix-cache-stats requires --batch")
          (if has-source
            (if has-manifest
              (Err "test: cannot combine source path with --manifest-path")
              (Ok
                (TestConfig.File source target mode roots opt-level test-mode)))
            (Ok
              (TestConfig.Package
                manifest-path
                has-manifest
                target
                mode
                roots
                opt-level
                test-mode))))])))

(define (tltest-check-mode? [mode : TestMode]) : bool
  (match mode
    [(Check) true]
    [(Run) false]))

;; Parse the `test` config from arguments starting at `start` (the index of the
;; first argument after any subcommand name). `count` is `(arg-count)`.
(define (tltest-config-from [start : i64] [count : i64]) : ResultTestConfig
  (let
    [args : cli_option.CliArgs
      (cli_option.cli-args
        "test"
        "--stdlib-root <dir> --cfg <name> --target <target> --opt-level <0|1|2>
         --check --list --filter <substring> --exact <name> --include-ignored
         --include-slow --shuffle --seed <u64> --backend-mode <mode>
         --manifest-path <file> --batch <file> --prefix-cache-stats"
        start
        count)]
    [source : String ""]
    [has-source : bool false]
    [manifest-path : String ""]
    [has-manifest : bool false]
    [target : String (build_run_core.source-tool-default-target-name)]
    [mode : compiler_backend.CompilerBackendMode (Scalar)]
    [roots : cli_svec.Vec (cli_svec.new)]
    [has-opt-level : bool false]
    [opt-level : i64 (compiler_optimize.compiler-optimize-default-level)]
    [test-mode : TestMode Run]
    [batch-list : TestMaybeString (No)]
    (set! tltest-prefix-cache-stats false)
    (set! tltest-list-only false)
    (set! tltest-name-filter-set false)
    (set! tltest-name-filter "")
    (set! tltest-name-exact-set false)
    (set! tltest-name-exact "")
    (set! tltest-include-ignored false)
    (set! tltest-include-slow false)
    (set! tltest-shuffle false)
    (set! tltest-seed-set false)
    (set! tltest-seed (cast 0 : u64))
    (tltest-user-cfg-reset!)
    (while (cli_option.cli-args-next! (&mut args))
      (cond
        [(string.eq args.name "--stdlib-root")
          (cli_svec.push-ref! (&mut roots) (cli_option.cli-args-value (& args)))]
        [(string.eq args.name "--target")
          (let
            [value : String (cli_option.cli-args-value (& args))]
            (match (build_run_core.source-tool-target (string.copy (& value)))
              [(Ok _) (set! target value)]
              [(Err _)
                (cli_option.cli-args-fail!
                  (&mut args)
                  (tltest-unknown-target value))]))]
        [(string.eq args.name "--opt-level")
          (let
            [value : String (cli_option.cli-args-value (& args))]
            [level : i64 (cli_option.cli-option-opt-level (& value))]
            (cond
              [has-opt-level
                (cli_option.cli-args-fail!
                  (&mut args)
                  "test: --opt-level was provided more than once")]
              [(< level 0)
                (cli_option.cli-args-fail!
                  (&mut args)
                  (tltest-invalid-opt-level value))]
              [else
                (set! has-opt-level true)
                (set! opt-level level)]))]
        [(string.eq args.name "--cfg")
          (let
            [value : String (cli_option.cli-args-value (& args))]
            (if (= (string.string-length value) 0)
              (cli_option.cli-args-fail!
                (&mut args)
                "test: --cfg requires a non-empty value")
              (tltest-user-cfg-push! value)))]
        [(string.eq args.name "--check")
          (if tltest-list-only
            (cli_option.cli-args-fail!
              (&mut args)
              "test: cannot combine --check with --list")
            (set! test-mode Check))]
        [(string.eq args.name "--list")
          (cond
            [tltest-list-only
              (cli_option.cli-args-fail! (&mut args) "test: duplicate --list")]
            [(tltest-check-mode? test-mode)
              (cli_option.cli-args-fail!
                (&mut args)
                "test: cannot combine --check with --list")]
            [else (set! tltest-list-only true)])]
        [(or (string.eq args.name "--filter") (string.eq args.name "--exact"))
          (let
            [value : String (cli_option.cli-args-value (& args))]
            (cond
              [(tltest-selection-set?)
                (cli_option.cli-args-fail!
                  (&mut args)
                  "test: --filter and --exact are mutually exclusive and may appear only once")]
              [(string.eq args.name "--filter")
                (if (= (string.string-length value) 0)
                  (cli_option.cli-args-fail!
                    (&mut args)
                    "test: --filter requires a non-empty value")
                  (begin
                    (set! tltest-name-filter-set true)
                    (set! tltest-name-filter value)))]
              [(= (string.string-length value) 0)
                (cli_option.cli-args-fail!
                  (&mut args)
                  "test: --exact requires a non-empty value")]
              [else
                (set! tltest-name-exact-set true)
                (set! tltest-name-exact value)]))]
        [(string.eq args.name "--include-ignored")
          (if tltest-include-ignored
            (cli_option.cli-args-fail!
              (&mut args)
              "test: duplicate --include-ignored")
            (set! tltest-include-ignored true))]
        [(string.eq args.name "--include-slow")
          (if tltest-include-slow
            (cli_option.cli-args-fail!
              (&mut args)
              "test: duplicate --include-slow")
            (set! tltest-include-slow true))]
        [(string.eq args.name "--shuffle")
          (if tltest-shuffle
            (cli_option.cli-args-fail! (&mut args) "test: duplicate --shuffle")
            (set! tltest-shuffle true))]
        [(string.eq args.name "--seed")
          (if tltest-seed-set
            (cli_option.cli-args-fail! (&mut args) "test: duplicate --seed")
            (match (tltest-parse-seed (cli_option.cli-args-value (& args)))
              [(Err message) (cli_option.cli-args-fail! (&mut args) message)]
              [(Ok seed)
                (set! tltest-seed-set true)
                (set! tltest-seed seed)]))]
        [(string.eq args.name "--backend-mode")
          ;; The shared source-tool parser owns the accepted spellings, so
          ;; `test` cannot drift from build and run.
          (match (build_run_core.source-tool-backend-mode
            "test"
            (cli_option.cli-args-value (& args)))
            [(Ok selected-mode) (set! mode selected-mode)]
            [(Err message) (cli_option.cli-args-fail! (&mut args) message)])]
        [(string.eq args.name "--manifest-path")
          (if has-manifest
            (cli_option.cli-args-fail!
              (&mut args)
              "test: duplicate --manifest-path")
            (begin
              (set! manifest-path (cli_option.cli-args-value (& args)))
              (set! has-manifest true)))]
        [(string.eq args.name "--batch")
          (match batch-list
            [(Some _)
              (cli_option.cli-args-fail! (&mut args) "test: duplicate --batch")]
            [(No) (set! batch-list (Some (cli_option.cli-args-value (& args))))])]
        [(string.eq args.name "--prefix-cache-stats")
          (set! tltest-prefix-cache-stats true)]
        [(cli_option.cli-flag? args.arg)
          (cli_option.cli-args-fail-arg! (&mut args) "test: unknown flag ")]
        [has-source
          (cli_option.cli-args-fail!
            (&mut args)
            "test: accepts only one source file")]
        [else
          (set! source (string.copy (& args.arg)))
          (set! has-source true)]))
    (if args.failed
      (Err args.error)
      (tltest-config-finish
        source
        has-source
        manifest-path
        has-manifest
        target
        mode
        roots
        opt-level
        test-mode
        batch-list))))

(define (tltest-decl-list-count [items : ast.AstDeclList]) : i64
  (let
    [cur : ast.AstDeclList items]
    [count : i64 0]
    [done : bool false]
    (while (not done)
      (match (ast.ast-decl-list-step cur)
        [(Nil) (set! done true)]
        [(Cons _ rest)
          (set! count (+ count 1))
          (set! cur rest)]))
    count))

(define (tltest-main-decl? [decl : ast.AstDecl]) : bool
  (match decl
    [(Def decl-meta name _ _) (= name (tltest-main-id))]
    [(DefFn decl-meta name _ _ _ _) (= name (tltest-main-id))]
    [(DefMacro decl-meta _ _ _ _) false]
    [(Unsafe inner-box)
      (let
        [inner : ast.AstDecl (deref inner-box)]
        (tltest-main-decl? inner))]
    [_ false]))

(define (tltest-source-line [span : ast.AstSourceSpan]) : i64
  (ast.ast-source-span-start-line span))

(define (tltest-private-name [idx : i64]) : String
  (str_cat.str-cat "__tl_inline_test_" (string.int->string idx)))

(define (tltest-private-call-id [module-id : i64] [private-id : i64]) : i64
  (if (= module-id (tltest-empty-name-id))
    private-id
    (ci.intern-generated-canonical-qualified-name
      (tc_core.tc-hygiene-global-context-name
        (ci.intern-syntax-name-text-or module-id "<structural-module>")
        (ci.intern-str private-id))
      module-id
      private-id)))

(define (tltest-owned-test-path?
  [target-path : (& target-path str)]
  [decl-path : (& decl-path str)]) : bool
  (string.eq target-path (compiler_load.compiler-load-normalize-path decl-path)))

(define (tltest-test-name-selected? [name : String]) : bool
  (if tltest-name-exact-set
    (string.eq name tltest-name-exact)
    (if tltest-name-filter-set
      (string.contains (& name) (& tltest-name-filter))
      true)))

(define (tltest-test-selection-with
  [metadata : ast.AstTestMetadata]
  [include-ignored : bool]
  [include-slow : bool]) : InlineTestSelection
  (match (ast.ast-test-metadata-ignore-reason metadata)
    [(Some reason)
      (if include-ignored
        (if (and (ast.ast-test-metadata-slow? metadata) (not include-slow))
          SlowSkipped
          Run)
        (Ignored reason))]
    [(No)
      (if (and (ast.ast-test-metadata-slow? metadata) (not include-slow))
        SlowSkipped
        Run)]))

(define (tltest-test-selection [metadata : ast.AstTestMetadata]) : InlineTestSelection
  (tltest-test-selection-with
    metadata
    tltest-include-ignored
    tltest-include-slow))

(define (tltest-xorshift64-next [value : u64]) : u64
  ;; xorshift64 (Marsaglia): the all-zero state is replaced by one documented
  ;; constant, then three fixed xor/shift steps produce a portable next state.
  (let
    [seeded : u64
      (if (= value (cast 0 : u64))
        (cast 88172645463325252 : u64)
        value)]
    [x1 : u64 (bit-xor seeded (shl seeded 13))]
    [x2 : u64 (bit-xor x1 (shr x1 7))]
    (bit-xor x2 (shl x2 17))))

(define (tltest-shuffle-initial-state [seed : u64]) : u64
  ;; Keep replay independent of absolute paths and host path separators.
  (bit-xor seed (cast 1469598103934665603 : u64)))

(define (tltest-shuffle-tests!
  [tests : (&mut tests (__tl_dyn-array InlineTest))]) : unit
  (if tltest-shuffle
    (let
      [state : u64 (tltest-shuffle-initial-state tltest-seed)]
      [index : i64 (- (array-length tests) 1)]
      (while (> index 0)
        (let
          [next-state : u64 (tltest-xorshift64-next state)]
          [other : i64 (cast (% next-state (cast (+ index 1) : u64)) : i64)]
          (set! state next-state)
          (if (= index other)
            unit
            (let
              [saved : InlineTest (clone (array-ref tests index))]
              (set! (array-ref tests index) (clone (array-ref tests other)))
              (set! (array-ref tests other) saved)))
          (set! index (- index 1)))))
    unit))

(define (tltest-shuffle-string-vec! [items : (&mut items cli_svec.Vec)]) : unit
  (if tltest-shuffle
    (let
      [state : u64 (tltest-shuffle-initial-state tltest-seed)]
      [index : i64 (- (cli_svec.len items) 1)]
      (while (> index 0)
        (let
          [next-state : u64 (tltest-xorshift64-next state)]
          [other : i64 (cast (% next-state (cast (+ index 1) : u64)) : i64)]
          [saved : String (clone (cli_svec.get items index ""))]
          (set! state next-state)
          (cli_svec.set-ref! items index (clone (cli_svec.get items other "")))
          (cli_svec.set-ref! items other saved)
          (set! index (- index 1)))))
    unit))

(define (tltest-collect-in
  [target-path : (& target-path str)]
  [decls : ast.AstDeclList]
  [paths : ast.AstDeclPathList]
  [runtime-decls : ast.AstDeclList]
  [runtime-paths : ast.AstDeclPathList]
  [tests : (__tl_dyn-array InlineTest)]) : InlineCollect
  (let
    [cur-decls : ast.AstDeclList decls]
    [cur-paths : ast.AstDeclPathList paths]
    [runtime-decls-out : ast.AstDeclList runtime-decls]
    [runtime-paths-out : ast.AstDeclPathList runtime-paths]
    [test-items : (__tl_dyn-array InlineTest) tests]
    [current-module : i64 (tltest-empty-name-id)]
    [done : bool false]
    (while (not done)
      (match (ast.ast-decl-list-step cur-decls)
        [(Nil) (set! done true)]
        [(Cons decl rest)
          (let
            [rest-decls : ast.AstDeclList rest]
            [decl-path : String
              (match (ast.ast-decl-path-list-step cur-paths)
                [(Cons path _) path]
                [(Nil) ""])]
            [decl-owner-id : i64
              (ast.ast-decl-path-list-owner-id (& cur-paths) 0 current-module)]
            [rest-paths : ast.AstDeclPathList
              (match (ast.ast-decl-path-list-step cur-paths)
                [(Cons _ path-rest)
                  (let
                    [path-rest : ast.AstDeclPathList path-rest]
                    path-rest)]
                [(Nil) (ast.ast-decl-path-list-new)])]
            (match (owned_view.compiler-owned-shared-view decl)
              [(Test name body-box metadata span)
                (if (and
                  (tltest-owned-test-path? target-path decl-path)
                  (tltest-test-name-selected? (ci.intern-str name)))
                  (let
                    [body : i64 body-box]
                    [test-count : i64 (array-length test-items)]
                    [private-name : String (tltest-private-name test-count)]
                    [private-id : i64
                      (ci.intern-generated-name
                        (owned_view.compiler-owned-shared-view private-name))]
                    (__tl_array-push!
                      test-items
                      (Case
                        (ci.intern-str name)
                        decl-path
                        current-module
                        (tltest-source-line span)
                        body
                        private-name
                        private-id
                        (tltest-private-call-id current-module private-id)
                        (tltest-test-selection metadata))))
                  unit)]
              [(Module name)
                (set! current-module name)
                (ast.ast-decl-list-push (&mut runtime-decls-out) decl)
                (ast.ast-decl-path-list-push-with-owner-id
                  (&mut runtime-paths-out)
                  decl-path
                  decl-owner-id)]
              [(Import decl-meta _)
                (ast.ast-decl-list-push (&mut runtime-decls-out) decl)
                (ast.ast-decl-path-list-push-with-owner-id
                  (&mut runtime-paths-out)
                  decl-path
                  decl-owner-id)]
              [(IncludeStr _ _) unit]
              [(IncludeStrComptime _ _) unit]
              [(IncludeStrLzss _ _) unit]
              [(IncludeBin _ _) unit]
              [_
                (unless
                  (tltest-main-decl?
                    (owned_view.compiler-owned-shared-view decl))
                  (ast.ast-decl-list-push (&mut runtime-decls-out) decl)
                  (ast.ast-decl-path-list-push-with-owner-id
                    (&mut runtime-paths-out)
                    decl-path
                    decl-owner-id))])
            (set! cur-decls rest-decls)
            (set! cur-paths rest-paths))]))
    (Collect runtime-decls-out runtime-paths-out test-items)))

(define (tltest-collect
  [source : (& source str)]
  [decls : ast.AstDeclList]
  [paths : ast.AstDeclPathList]) : InlineCollect
  (let
    [normalized : String (compiler_load.compiler-load-normalize-path source)]
    (match (tltest-collect-in
      normalized
      decls
      paths
      (ast.ast-decl-list-new)
      (ast.ast-decl-path-list-new)
      (__tl_make-array InlineTest 0))
      [(Collect runtime-decls runtime-paths tests)
        (tltest-shuffle-tests! (&mut tests))
        (Collect runtime-decls runtime-paths tests)])))

(define (tltest-list-line [test : InlineTest]) : String
  (match test
    [(Case name path _ line _ _ _ _ selection)
      (str_cat.str-cat
        name
        " "
        (tltest-location path line)
        " "
        (match selection
          [(Run) "[run]\n"]
          [(SlowSkipped) "[slow-skipped]\n"]
          [(Ignored reason) (str_cat.str-cat "[ignored: " reason "]\n")]))]))

(define (tltest-list-tests-from
  [tests : (__tl_dyn-array InlineTest)]
  [index : i64]) : i64
  (if (>= index (array-length tests))
    (array-length tests)
    (begin
      (io.print-format
        "{}"
        (tltest-list-line
          (owned_view.compiler-owned-array-element-shared-view tests index)))
      (tltest-list-tests-from tests (+ index 1)))))

(define (tltest-list-loaded
  [source : String]
  [decls : ast.AstDeclList]
  [paths : ast.AstDeclPathList]) : i64
  (match (tltest-collect source decls paths)
    [(Collect _ _ tests) (tltest-list-tests-from tests 0)]))

(define (tltest-list-summary-line [count : i64]) : String
  (str_cat.str-cat
    "TypeLisp tests listed: "
    (string.int->string count)
    " test(s)\n"))

(define (tltest-print-expr [text : String]) : i64
  (ast.ast-expr-call
    (ast.ast-node-push (Var (tltest-print-error-id)))
    (ast.ast-expr-cons
      (ast.ast-node-push
        (Literal
          (ast.ast-lit-generated-string
            (owned_view.compiler-owned-shared-view text))))
      (ast.ast-expr-cons
        (ast.ast-expr-cast
          (ast.ast-node-push
            (Literal (ast.ast-lit-int (string.string-length text))))
          (I32))
        (ast.ast-expr-list-new)))))

(define (tltest-call-expr-id [name-id : i64]) : i64
  (ast.ast-expr-call (ast.ast-node-push (Var name-id)) (ast.ast-expr-list-new)))

(define (tltest-runtime-call-expr-id [leaf-id : i64]) : i64
  (tltest-call-expr-id (tltest-runtime-call-id leaf-id)))

(define (tltest-runtime-suite-finish-expr
  [count : i64]
  [ignored : i64]
  [slow-skipped : i64]) : i64
  (ast.ast-expr-call
    (ast.ast-node-push
      (Var (tltest-runtime-call-id (tltest-runtime-suite-finish-id))))
    (ast.ast-expr-cons
      (ast.ast-node-push (Literal (ast.ast-lit-int count)))
      (ast.ast-expr-cons
        (ast.ast-node-push (Literal (ast.ast-lit-int ignored)))
        (ast.ast-expr-cons
          (ast.ast-node-push (Literal (ast.ast-lit-int slow-skipped)))
          (ast.ast-expr-list-new))))))

(define (tltest-location [path : String] [line : i64]) : String
  (if (string.eq path "")
    (str_cat.str-cat "<unknown>:" (string.int->string line))
    (str_cat.str-cat path ":" (string.int->string line))))

(define (tltest-running-line [test : InlineTest]) : String
  (match test
    [(Case name path _ line _ _ _ _ _)
      (str_cat.str-cat "test " name " " (tltest-location path line) "\n")]))

(define (tltest-ok-line [test : InlineTest]) : String
  (match test
    [(Case name _ _ _ _ _ _ _ _) (str_cat.str-cat "ok " name "\n")]))

(define (tltest-failed-line [test : InlineTest]) : String
  (match test
    [(Case name path _ line _ _ _ _ _)
      (str_cat.str-cat "FAILED " name " " (tltest-location path line) "\n")]))

(define (tltest-print-runtime-write-params) : ast.AstParamList
  (ast.ast-param-cons
    (ast.ast-param-id (tltest-fd-id) (I32) false)
    (ast.ast-param-cons
      (ast.ast-param-id (tltest-buf-id) (ast.ast-ty-ptr (U8)) false)
      (ast.ast-param-cons
        (ast.ast-param-id (tltest-n-id) (I32) false)
        (ast.ast-param-list-new)))))

(define (tltest-linux-write-ptr-arg) : i64
  (ast.ast-node-push
    (Unsafe
      (ast.ast-expr-cons
        (ast.ast-expr-cast
          (ast.ast-expr-ptr-to-int (ast.ast-node-push (Var (tltest-buf-id))))
          (I64))
        (ast.ast-expr-list-new)))))

(define (tltest-linux-write-syscall) : i64
  (ast.ast-node-push
    (Unsafe
      (ast.ast-expr-cons
        (ast.ast-expr-syscall
          (ast.ast-expr-cons
            (ast.ast-node-push (Literal (ast.ast-lit-int 1)))
            (ast.ast-expr-cons
              (ast.ast-expr-cast (ast.ast-node-push (Var (tltest-fd-id))) (I64))
              (ast.ast-expr-cons
                (tltest-linux-write-ptr-arg)
                (ast.ast-expr-cons
                  (ast.ast-expr-cast
                    (ast.ast-node-push (Var (tltest-n-id)))
                    (I64))
                  (ast.ast-expr-list-new))))))
        (ast.ast-expr-list-new)))))

(define (tltest-linux-print-runtime-write-decl) : ast.AstDecl
  (ast.ast-decl-def-fn-id
    (tltest-write-id)
    (tltest-print-runtime-write-params)
    (I32)
    (ast.ast-expr-cast (tltest-linux-write-syscall) (I32))))

(define (tltest-windows-get-std-handle-decl) : ast.AstDecl
  (ast.ast-decl-extern-id
    (tltest-get-std-handle-id)
    (Function)
    (Metadata
      (C)
      (ci.intern-id-from-renderable (ci.intern-generated-name "GetStdHandle"))
      (ast.ast-extern-link-input-list-new)
      (ast.ast-extern-metadata-flags true false)
      No)
    (ast.ast-ty-func (ast.ast-type-cons (I32) (ast.ast-type-list-new)) (I64))))

(define (tltest-windows-write-file-decl) : ast.AstDecl
  (ast.ast-decl-extern-id
    (tltest-write-file-id)
    (Function)
    (Metadata
      (C)
      (ci.intern-id-from-renderable (ci.intern-generated-name "WriteFile"))
      (ast.ast-extern-link-input-list-new)
      (ast.ast-extern-metadata-flags true false)
      No)
    (ast.ast-ty-func
      (ast.ast-type-cons
        (I64)
        (ast.ast-type-cons
          (ast.ast-ty-ptr (U8))
          (ast.ast-type-cons
            (I32)
            (ast.ast-type-cons
              (ast.ast-ty-mut-ptr (I32))
              (ast.ast-type-cons (I64) (ast.ast-type-list-new))))))
      (I32))))

(define (tltest-windows-get-stderr-handle-expr) : i64
  (ast.ast-expr-call
    (ast.ast-node-push (Var (tltest-get-std-handle-id)))
    (ast.ast-expr-cons
      (ast.ast-expr-cast
        (ast.ast-node-push (Literal (ast.ast-lit-int -12)))
        (I32))
      (ast.ast-expr-list-new))))

(define (tltest-windows-write-file-call) : i64
  (ast.ast-expr-call
    (ast.ast-node-push (Var (tltest-write-file-id)))
    (ast.ast-expr-cons
      (ast.ast-node-push (Var (tltest-handle-id)))
      (ast.ast-expr-cons
        (ast.ast-node-push (Var (tltest-buf-id)))
        (ast.ast-expr-cons
          (ast.ast-node-push (Var (tltest-n-id)))
          (ast.ast-expr-cons
            (ast.ast-node-push
              (PtrNull (ast.ty-node-push (ast.ast-ty-mut-ptr (I32)))))
            (ast.ast-expr-cons
              (ast.ast-node-push (Literal (ast.ast-lit-int 0)))
              (ast.ast-expr-list-new))))))))

(define (tltest-windows-write-body) : i64
  (ast.ast-expr-let
    (ast.ast-let-binding-cons
      (ast.ast-let-binding-id
        (tltest-handle-id)
        (Some (I64))
        (tltest-windows-get-stderr-handle-expr))
      (ast.ast-let-binding-cons
        (ast.ast-let-binding-id
          (tltest-ok-id)
          (Some (I32))
          (tltest-windows-write-file-call))
        (ast.ast-let-binding-list-new)))
    (ast.ast-expr-if
      (ast.ast-expr-binary
        (Eq)
        (ast.ast-node-push (Var (tltest-ok-id)))
        (ast.ast-expr-cast
          (ast.ast-node-push (Literal (ast.ast-lit-int 0)))
          (I32)))
      (ast.ast-expr-cast
        (ast.ast-node-push (Literal (ast.ast-lit-int -1)))
        (I32))
      (ast.ast-node-push (Var (tltest-n-id))))))

(define (tltest-windows-print-runtime-write-decl) : ast.AstDecl
  (ast.ast-decl-def-fn-id
    (tltest-write-id)
    (tltest-print-runtime-write-params)
    (I32)
    (tltest-windows-write-body)))

(define (tltest-print-runtime-write-decl
  [target : compiler_backend.CompilerBackendTarget]) : ast.AstDecl
  (match target
    [(Linux) (tltest-linux-print-runtime-write-decl)]
    [(Windows) (tltest-windows-print-runtime-write-decl)]))

(define (tltest-print-param-list) : ast.AstParamList
  (ast.ast-param-cons
    (ast.ast-param-id (tltest-text-id) (String) false)
    (ast.ast-param-cons
      (ast.ast-param-id (tltest-n-id) (I32) false)
      (ast.ast-param-list-new))))

(define (tltest-print-runtime-write-call) : i64
  (ast.ast-expr-call
    (ast.ast-node-push (Var (tltest-write-id)))
    (ast.ast-expr-cons
      (ast.ast-expr-cast
        (ast.ast-node-push (Literal (ast.ast-lit-int 2)))
        (I32))
      (ast.ast-expr-cons
        (ast.ast-node-push
          (Unsafe
            (ast.ast-expr-cons
              (ast.ast-expr-string-data
                (ast.ast-node-push (Var (tltest-text-id))))
              (ast.ast-expr-list-new))))
        (ast.ast-expr-cons
          (ast.ast-node-push (Var (tltest-n-id)))
          (ast.ast-expr-list-new))))))

(define (tltest-print-runtime-print-decl) : ast.AstDecl
  (ast.ast-decl-def-fn-id
    (tltest-print-error-id)
    (tltest-print-param-list)
    (Unit)
    (ast.ast-node-push
      (Begin
        (ast.ast-expr-cons
          (tltest-print-runtime-write-call)
          (ast.ast-expr-cons
            (ast.ast-node-push (Literal (Unit)))
            (ast.ast-expr-list-new)))))))

(define (tltest-program-with-print-runtime
  [program : ast.AstProgram]
  [target : compiler_backend.CompilerBackendTarget]) : ast.AstProgram
  (match program
    [(Program decls-box)
      (let
        [decls : ast.AstDeclList (deref decls-box)]
        (ast.ast-program
          (match target
            [(Linux)
              (ast.ast-decl-cons
                (tltest-print-runtime-write-decl target)
                (ast.ast-decl-cons (tltest-print-runtime-print-decl) decls))]
            [(Windows)
              (ast.ast-decl-cons
                (tltest-windows-get-std-handle-decl)
                (ast.ast-decl-cons
                  (tltest-windows-write-file-decl)
                  (ast.ast-decl-cons
                    (tltest-print-runtime-write-decl target)
                    (ast.ast-decl-cons (tltest-print-runtime-print-decl) decls))))])))]))

(define (tltest-paths-with-print-runtime-count
  [count : i64]
  [runtime-path-id : i64]
  [paths : ast.AstDeclPathList]) : ast.AstDeclPathList
  (if (<= count 0)
    paths
    (ast.ast-decl-path-list-prepend-builder-with-owner-id
      "<generated test runtime>"
      runtime-path-id
      (tltest-paths-with-print-runtime-count (- count 1) runtime-path-id paths))))

(define (tltest-paths-with-print-runtime
  [target : compiler_backend.CompilerBackendTarget]
  [paths : ast.AstDeclPathList]) : ast.AstDeclPathList
  (let
    [runtime-path-id : i64
      (ci.intern-generated-canonical-name "<generated test runtime>")]
    (match target
      [(Linux) (tltest-paths-with-print-runtime-count 2 runtime-path-id paths)]
      [(Windows)
        (tltest-paths-with-print-runtime-count 4 runtime-path-id paths)])))

(define (tltest-main-exprs-from
  [tests : (__tl_dyn-array InlineTest)]
  [index : i64]
  [out : ast.AstExprList]) : ast.AstExprList
  (if (< index 0)
    out
    (let
      [test : InlineTest
        (owned_view.compiler-owned-array-element-shared-view tests index)]
      (match (owned_view.compiler-owned-shared-view test)
        [(Case _ _ _ _ _ _ _ call-id selection)
          (match selection
            [(Run)
              (tltest-main-exprs-from
                tests
                (- index 1)
                (ast.ast-expr-cons
                  (tltest-runtime-call-expr-id (tltest-runtime-case-begin-id))
                  (ast.ast-expr-cons
                    (tltest-print-expr
                      (tltest-running-line
                        (owned_view.compiler-owned-shared-view test)))
                    (ast.ast-expr-cons
                      (tltest-call-expr-id call-id)
                      (ast.ast-expr-cons
                        (ast.ast-expr-if
                          (tltest-runtime-call-expr-id
                            (tltest-runtime-case-finish-id))
                          (tltest-print-expr
                            (tltest-failed-line
                              (owned_view.compiler-owned-shared-view test)))
                          (tltest-print-expr (tltest-ok-line test)))
                        out)))))]
            [_ (tltest-main-exprs-from tests (- index 1) out)])]))))

(define (tltest-selection-counts
  [tests : (& tests (__tl_dyn-array InlineTest))]
  [wanted : i64]) : i64
  (let
    [index : i64 0]
    [count : i64 0]
    (while (< index (array-length tests))
      (match (array-ref tests index)
        [(Case _ _ _ _ _ _ _ _ selection)
          (let
            [kind : i64
              (match selection
                [(Run) 0]
                [(Ignored _) 1]
                [(SlowSkipped) 2])]
            (if (= kind wanted)
              (set! count (+ count 1))
              unit))])
      (set! index (+ index 1)))
    count))

(define (tltest-ignored-count [tests : (& tests (__tl_dyn-array InlineTest))]) : i64
  (tltest-selection-counts tests 1))

(define (tltest-slow-skipped-count
  [tests : (& tests (__tl_dyn-array InlineTest))]) : i64
  (tltest-selection-counts tests 2))

(define (tltest-main-exprs [tests : (__tl_dyn-array InlineTest)]) : ast.AstExprList
  (let
    [count : i64 (array-length tests)]
    [ignored : i64 (tltest-ignored-count (& tests))]
    [slow-skipped : i64 (tltest-slow-skipped-count (& tests))]
    (ast.ast-expr-cons
      (tltest-runtime-call-expr-id (tltest-runtime-suite-begin-id))
      (tltest-main-exprs-from
        tests
        (- count 1)
        (ast.ast-expr-cons
          (tltest-runtime-suite-finish-expr count ignored slow-skipped)
          (ast.ast-expr-list-new))))))

(define (tltest-test-decls-onto
  [tests : (__tl_dyn-array InlineTest)]
  [index : i64]
  [out : ast.AstDeclList]) : ast.AstDeclList
  (if (< index 0)
    out
    (let
      [test : InlineTest
        (owned_view.compiler-owned-array-element-shared-view tests index)]
      (match test
        [(Case _ _ module-id _ body _ private-id _ _)
          (tltest-test-decls-onto
            tests
            (- index 1)
            (ast.ast-decl-list-prepend-builder
              (ast.ast-decl-module-id module-id)
              (ast.ast-decl-list-prepend-builder
                (ast.ast-decl-def-fn-id
                  private-id
                  (ast.ast-param-list-new)
                  (Unit)
                  body)
                out)))]))))

(define (tltest-main-decls [tests : (__tl_dyn-array InlineTest)]) : ast.AstDeclList
  (ast.ast-decl-cons
    (ast.ast-decl-module-id (tltest-empty-name-id))
    (ast.ast-decl-cons
      (Import
        (ast.ast-decl-meta-runtime-shared-view)
        (Spec
          (Module)
          "stdlib.runtime"
          (Some cbi.compiler-builtin-id-runtime-module)
          (Some (tltest-runtime-import-alias-id))
          (box (ast.ast-decl-span-fallback))))
      (ast.ast-decl-cons (tltest-main-decl tests) (ast.ast-decl-list-new)))))

(define (tltest-main-paths [source : String]) : ast.AstDeclPathList
  (ast.ast-decl-path-cons-with-owner-id
    (owned_view.compiler-owned-shared-view source)
    cbi.compiler-builtin-id-fix-empty
    (ast.ast-decl-path-cons-with-owner-id
      (owned_view.compiler-owned-shared-view source)
      cbi.compiler-builtin-id-fix-empty
      (ast.ast-decl-path-cons-with-owner-id
        source
        cbi.compiler-builtin-id-fix-empty
        (ast.ast-decl-path-list-new)))))

(define (tltest-generated-test-decls [tests : (__tl_dyn-array InlineTest)]) : ast.AstDeclList
  (tltest-test-decls-onto
    (owned_view.compiler-owned-shared-view tests)
    (- (array-length tests) 1)
    (tltest-main-decls tests)))

(define (tltest-generated-typecheck-decls [tests : (__tl_dyn-array InlineTest)]) : ast.AstDeclList
  (tltest-test-decls-onto
    (owned_view.compiler-owned-shared-view tests)
    (- (array-length tests) 1)
    (ast.ast-decl-list-new)))

(define (tltest-generated-test-paths
  [source : String]
  [tests : (__tl_dyn-array InlineTest)]) : ast.AstDeclPathList
  (tltest-test-paths-onto
    (owned_view.compiler-owned-shared-view tests)
    (- (array-length tests) 1)
    (tltest-main-paths source)))

(define (tltest-generated-typecheck-paths [tests : (__tl_dyn-array InlineTest)]) : ast.AstDeclPathList
  (tltest-test-paths-onto
    (owned_view.compiler-owned-shared-view tests)
    (- (array-length tests) 1)
    (ast.ast-decl-path-list-new)))

(define (tltest-test-paths-onto
  [tests : (__tl_dyn-array InlineTest)]
  [index : i64]
  [out : ast.AstDeclPathList]) : ast.AstDeclPathList
  (if (< index 0)
    out
    (let
      [test : InlineTest
        (owned_view.compiler-owned-array-element-shared-view tests index)]
      (match test
        [(Case _ path module-id _ _ _ _ _ _)
          (tltest-test-paths-onto
            tests
            (- index 1)
            (ast.ast-decl-path-list-prepend-builder-with-owner-id
              (owned_view.compiler-owned-shared-view path)
              module-id
              (ast.ast-decl-path-list-prepend-builder-with-owner-id
                path
                module-id
                out)))]))))

(define (tltest-main-decl [tests : (__tl_dyn-array InlineTest)]) : ast.AstDecl
  (ast.ast-decl-def-fn-id
    (tltest-main-id)
    (ast.ast-param-list-new)
    (I64)
    (ast.ast-node-push (Begin (tltest-main-exprs tests)))))

(define (tltest-reach-mark-name-id
  [names : tltest_name_map.Map]
  [name-id : i64]) : tltest_name_map.Map
  (let
    [result : tltest_name_map.Map names]
    [_inserted : bool
      (tltest_name_map.insert-if-absent-ref!
        (&mut result)
        (csym.compiler-symbol-name-id-key name-id)
        1)]
    result))

;; Source calls may carry module qualification or an import-alias dot path.
;; Runtime declarations use the bare source ID, so retain that parsed leaf ID
;; alongside the full structural identity without reconstructing any spelling.
(define (tltest-reach-name-source-base-id
  [session : cis.InternStructuralSessionHandle]
  [name-id : i64]) : i64
  (let
    ;; The initial syntax unwrap must use this owner too: a compatibility
    ;; classifier can mistake a colliding installed-pool ID for a macro global.
    [source-id : i64
      (if (cis.intern-structural-session-source-name-component-valid?
        session
        name-id)
        name-id
        (cis.intern-structural-session-syntax-source-name-id-or
          session
          name-id
          name-id))]
    [source-names : ci.InternSourceNameSessionHandle
      (cis.intern-structural-session-handle-source-names session)]
    (if (cis.intern-structural-session-source-name-component-valid?
      session
      source-id)
      (if (ci.intern-source-name-session-handle-qualified?
        source-names
        source-id)
        (ci.intern-source-name-session-handle-qualified-base-id
          source-names
          source-id)
        source-id)
      (match (cis.intern-structural-session-record-for-raw session source-id)
        [(Some record)
          (cond
            [(= record.kind (ci.intern-structural-kind-pair)) record.right-id]
            [(= record.kind (ci.intern-structural-kind-triple))
              (cis.intern-structural-key-raw
                (cis.intern-structural-session-composite-pair-key
                  session
                  record.middle-id
                  record.right-id))]
            [else source-id])]
        [(No) source-id]))))

(define (tltest-reach-name-dot-leaf-id
  [session : cis.InternStructuralSessionHandle]
  [name-id : i64]) : i64
  (let
    [base-id : i64 (tltest-reach-name-source-base-id session name-id)]
    [source-names : ci.InternSourceNameSessionHandle
      (cis.intern-structural-session-handle-source-names session)]
    (if (and
      (cis.intern-structural-session-source-name-component-valid?
        session
        base-id)
      (ci.intern-source-name-session-handle-dotted? source-names base-id))
      (ci.intern-source-name-session-handle-dotted-final-id
        source-names
        base-id)
      base-id)))

;; Before typechecking, a dotted name can project from global storage rather
;; than name an imported member. Retain its first source component as a possible
;; owner; keeping only the final leaf drops the global and its initializer.
(define (tltest-reach-mark-dotted-root
  [session : cis.InternStructuralSessionHandle]
  [names : tltest_name_map.Map]
  [name-id : i64]) : tltest_name_map.Map
  (let
    [source-names : ci.InternSourceNameSessionHandle
      (cis.intern-structural-session-handle-source-names session)]
    (if (and
      (cis.intern-structural-session-source-name-component-valid?
        session
        name-id)
      (ci.intern-source-name-session-handle-dotted? source-names name-id))
      (tltest-reach-mark-name-id
        names
        (ci.intern-source-name-session-handle-leading-dot-id
          source-names
          name-id))
      names)))

(define (tltest-reach-mark-source-name
  [session : cis.InternStructuralSessionHandle]
  [names : tltest_name_map.Map]
  [name-id : i64]) : tltest_name_map.Map
  (let
    [marked : tltest_name_map.Map (tltest-reach-mark-name-id names name-id)]
    [base-id : i64 (tltest-reach-name-source-base-id session name-id)]
    [with-slash-base : tltest_name_map.Map
      (if (not (= base-id name-id))
        (tltest-reach-mark-name-id marked base-id)
        marked)]
    [with-root : tltest_name_map.Map
      (tltest-reach-mark-dotted-root
        session
        with-slash-base
        (tltest-reach-name-source-base-id session name-id))]
    [leaf-id : i64 (tltest-reach-name-dot-leaf-id session name-id)]
    (if (= leaf-id base-id)
      with-root
      (tltest-reach-mark-name-id with-root leaf-id))))

(define (tltest-reachable-name-marked?
  [session : cis.InternStructuralSessionHandle]
  [names : (& names tltest_name_map.Map)]
  [name-id : i64]) : bool
  (let
    [key-id : i64 (csym.compiler-symbol-name-id-key name-id)]
    [base-id : i64 (tltest-reach-name-source-base-id session name-id)]
    [leaf-id : i64 (tltest-reach-name-dot-leaf-id session name-id)]
    (or
      (tltest_name_map.contains? (& names) key-id)
      (and
        (not (= base-id name-id))
        (tltest_name_map.contains?
          (& names)
          (csym.compiler-symbol-name-id-key base-id)))
      (and
        (not (= leaf-id base-id))
        (tltest_name_map.contains?
          (& names)
          (csym.compiler-symbol-name-id-key leaf-id))))))

(define (tltest-generated-comptime-decl? [decl : ast.AstDecl]) : bool
  (match (ast.ast-decl-generated-meta decl)
    [(Some _ _ _ _) true]
    [(No) false]))

(define (tltest-reach-mark-string-snapshot-runtime
  [names : tltest_name_map.Map]) : tltest_name_map.Map
  ;; Harness pruning runs before lowering emits raw `tl_substring` helper calls,
  ;; so keep the TypeLisp runtime body whenever a reachable test path may
  ;; synthesize a String snapshot or source substring call.
  (tltest-reach-mark-name-id names cbi.compiler-builtin-id-runtime-substring))

(define (tltest-reach-mark-atomic-runtime-for-call
  [session : cis.InternStructuralSessionHandle]
  [name-id : i64]
  [names : tltest_name_map.Map]) : tltest_name_map.Map
  ;; Inline harness pruning precedes lowering. Preserve exactly the TypeLisp
  ;; runtime export that a reachable public/wrapper atomic call can target.
  (let
    [helper-id : i64
      (lower.lower-runtime-prelude-string-helper-id session name-id)]
    (if (< helper-id 0)
      names
      (tltest-reach-mark-name-id names helper-id))))

(define (tltest-reach-mark-lowered-runtime-for-call
  [session : cis.InternStructuralSessionHandle]
  [name-id : i64]
  [names : tltest_name_map.Map]) : tltest_name_map.Map
  (let
    [base-id : i64 (tc_core.tc-qualified-name-base-id name-id)]
    [runtime-names : tltest_name_map.Map
      (tltest-reach-mark-atomic-runtime-for-call session name-id names)]
    (cond
      [(or
          (= base-id cbi.compiler-builtin-id-clone)
          (= base-id cbi.compiler-builtin-id-runtime-substring)
          (= base-id (cbi.compiler-builtin-ctfe-ref 93)))
        (tltest-reach-mark-string-snapshot-runtime runtime-names)]
      [else runtime-names])))

(define (tltest-reach-mark-expr-list
  [session : cis.InternStructuralSessionHandle]
  [exprs : ast.AstExprList]
  [names : tltest_name_map.Map]) : tltest_name_map.Map
  (tltest-reach-mark-expr-list-at session exprs names 0))

(define (tltest-reach-mark-expr-list-at
  [session : cis.InternStructuralSessionHandle]
  [exprs : ast.AstExprList]
  [names : tltest_name_map.Map]
  [index : i64]) : tltest_name_map.Map
  (if (>= index (ast.ast-expr-list-len (& exprs)))
    names
    (let
      [head : i64 (ast.ast-expr-list-get (& exprs) index 0)]
      (tltest-reach-mark-expr-list-at
        session
        exprs
        (tltest-reach-mark-expr session head names)
        (+ index 1)))))

(define (tltest-reach-mark-children
  [session : cis.InternStructuralSessionHandle]
  [node-id : i64]
  [names : tltest_name_map.Map]) : tltest_name_map.Map
  (tltest-reach-mark-expr-list
    session
    (ast.ast-expr-child-ids (ast.ast-node-get node-id))
    names))

(define (tltest-reach-mark-expr
  [session : cis.InternStructuralSessionHandle]
  [node-id : i64]
  [names : tltest_name_map.Map]) : tltest_name_map.Map
  ;; The arms below mark names, the runtime helpers calls and closures need,
  ;; and the read for-owned slots; every other variant's children are marked
  ;; through the AstExpr child list.
  (match (ast.ast-node-get node-id)
    [(Var name) (tltest-reach-mark-source-name session names name)]
    [(Call func args)
      (let
        [called-names : tltest_name_map.Map
          (tltest-reach-mark-expr session func names)]
        [runtime-names : tltest_name_map.Map
          (match (ast.ast-expr-unspan (ast.ast-node-get func))
            [(Var name)
              (tltest-reach-mark-lowered-runtime-for-call
                session
                name
                called-names)]
            [_ called-names])]
        (tltest-reach-mark-expr-list session args runtime-names))]
    [(Lambda _)
      (tltest-reach-mark-children
        session
        node-id
        (tltest-reach-mark-string-snapshot-runtime names))]
    [(ForOwnedState payload)
      (tltest-reach-mark-expr
        session
        (ast.ast-for-owned-state-body (& payload))
        (tltest-reach-mark-expr
          session
          (ast.ast-for-owned-state-source (& payload))
          names))]
    [(ForOwnedStep payload)
      (let
        [source : i64 (ast.ast-for-owned-step-source-name (& payload))]
        [index : i64 (ast.ast-for-owned-step-index-name (& payload))]
        [expected-type : i64 (ast.ast-for-owned-step-expected-type (& payload))]
        [done : i64 (ast.ast-for-owned-step-done-name (& payload))]
        [body : i64 (ast.ast-for-owned-step-body (& payload))]
        (tltest-reach-mark-expr
          session
          body
          (tltest-reach-mark-expr
            session
            done
            (if (>= expected-type 0)
              (tltest-reach-mark-expr
                session
                expected-type
                (tltest-reach-mark-expr
                  session
                  index
                  (tltest-reach-mark-expr session source names)))
              (tltest-reach-mark-expr
                session
                index
                (tltest-reach-mark-expr session source names))))))]
    [(Set name value)
      (tltest-reach-mark-expr
        session
        value
        (tltest-reach-mark-source-name session names name))]
    [(WithEscape _ _)
      (tltest-reach-mark-children
        session
        node-id
        (tltest-reach-mark-string-snapshot-runtime names))]
    [(WithScratch _)
      (tltest-reach-mark-children
        session
        node-id
        (tltest-reach-mark-string-snapshot-runtime names))]
    [_ (tltest-reach-mark-children session node-id names)]))

(define (tltest-reach-mark-tests-from
  [session : cis.InternStructuralSessionHandle]
  [tests : (__tl_dyn-array InlineTest)]
  [index : i64]
  [names : tltest_name_map.Map]) : tltest_name_map.Map
  (if (< index 0)
    names
    (let
      [test : InlineTest
        (owned_view.compiler-owned-array-element-shared-view tests index)]
      (match test
        [(Case _ _ _ _ body _ _ _ _)
          (tltest-reach-mark-tests-from
            session
            tests
            (- index 1)
            (tltest-reach-mark-expr session body names))]))))

(define (tltest-reach-mark-tests
  [session : cis.InternStructuralSessionHandle]
  [tests : (__tl_dyn-array InlineTest)]
  [names : tltest_name_map.Map]) : tltest_name_map.Map
  (let
    [last-index : i64 (- (array-length tests) 1)]
    (tltest-reach-mark-tests-from session tests last-index names)))

(define (tltest-runtime-string-helper-impl-name-id? [name-id : i64]) : bool
  (or
    (= name-id cbi.compiler-builtin-id-runtime-int-to-string)
    (= name-id cbi.compiler-builtin-id-runtime-substring)
    (= name-id cbi.compiler-builtin-id-runtime-str-view)
    (= name-id cbi.compiler-builtin-id-string-concat)
    (= name-id cbi.compiler-builtin-id-runtime-string-concat3)
    (= name-id cbi.compiler-builtin-id-runtime-string-concat4)
    (= name-id cbi.compiler-builtin-id-runtime-string-concat5)
    (= name-id cbi.compiler-builtin-id-eq)))

(define (tltest-reach-mark-runtime-helper-root
  [decl : ast.AstDecl]
  [names : tltest_name_map.Map]) : tltest_name_map.Map
  (match decl
    [(DefFn decl-meta name _ _ _ _)
      (if (tltest-runtime-string-helper-impl-name-id? name)
        (tltest-reach-mark-name-id names name)
        names)]
    [(Unsafe inner-box)
      (let
        [inner : ast.AstDecl (deref inner-box)]
        (tltest-reach-mark-runtime-helper-root inner names))]
    [_ names]))

(define (tltest-reach-mark-runtime-helper-roots
  [decls : ast.AstDeclList]
  [names : tltest_name_map.Map]) : tltest_name_map.Map
  (let
    [cur : ast.AstDeclList decls]
    [result : tltest_name_map.Map names]
    [done : bool false]
    (while (not done)
      (match (ast.ast-decl-list-step cur)
        [(Nil) (set! done true)]
        [(Cons decl rest)
          (set! result (tltest-reach-mark-runtime-helper-root decl result))
          (set! cur rest)]))
    result))

(define (tltest-reach-mark-test-harness-runtime [names : tltest_name_map.Map]) : tltest_name_map.Map
  (tltest-reach-mark-name-id
    (tltest-reach-mark-name-id
      (tltest-reach-mark-name-id
        (tltest-reach-mark-name-id names (tltest-runtime-suite-begin-id))
        (tltest-runtime-case-begin-id))
      (tltest-runtime-case-finish-id))
    (tltest-runtime-suite-finish-id)))

(define (tltest-reach-mark-struct-cleanup
  [cleanup : ast.AstStructCleanup]
  [names : tltest_name_map.Map]) : tltest_name_map.Map
  (match cleanup
    [(Fn name)
      (tltest-reach-mark-name-id names (ci.intern-syntax-id-value name))]
    [(No) names]))

(define (tltest-reach-mark-enum-cleanup
  [cleanup : ast.AstEnumCleanup]
  [names : tltest_name_map.Map]) : tltest_name_map.Map
  (match cleanup
    [(Fn name)
      (tltest-reach-mark-name-id names (ci.intern-syntax-id-value name))]
    [(No) names]))

(define (tltest-reach-mark-field-cleanup
  [cleanup : ast.AstFieldCleanup]
  [names : tltest_name_map.Map]) : tltest_name_map.Map
  (match cleanup
    [(Fn name)
      (tltest-reach-mark-name-id names (ci.intern-syntax-id-value name))]
    [_ names]))

(define (tltest-reach-mark-field-cleanups
  [fields : ast.AstFieldDefList]
  [names : tltest_name_map.Map]) : tltest_name_map.Map
  (tltest-reach-mark-field-cleanups-at (& fields) names 0))

(define (tltest-reach-mark-field-cleanups-at
  [fields : (& fields ast.AstFieldDefList)]
  [names : tltest_name_map.Map]
  [index : i64]) : tltest_name_map.Map
  (if (>= index (ast.ast-field-def-list-len fields))
    names
    (match (ast.ast-field-def-list-get
      fields
      index
      (ast.ast-field-def-fallback))
      [(Def _ _ cleanup)
        (tltest-reach-mark-field-cleanups-at
          fields
          (tltest-reach-mark-field-cleanup cleanup names)
          (+ index 1))])))

(define (tltest-reach-mark-variant-payload-cleanup
  [cleanup : ast.AstVariantPayloadCleanup]
  [names : tltest_name_map.Map]) : tltest_name_map.Map
  (match cleanup
    [(Fn name)
      (tltest-reach-mark-name-id names (ci.intern-syntax-id-value name))]
    [_ names]))

(define (tltest-reach-mark-variant-payload-cleanups
  [cleanups : ast.AstVariantPayloadCleanupList]
  [names : tltest_name_map.Map]) : tltest_name_map.Map
  (tltest-reach-mark-variant-payload-cleanups-at (& cleanups) names 0))

(define (tltest-reach-mark-variant-payload-cleanups-at
  [cleanups : (& cleanups ast.AstVariantPayloadCleanupList)]
  [names : tltest_name_map.Map]
  [index : i64]) : tltest_name_map.Map
  (if (>= index (ast.ast-variant-payload-cleanup-list-len cleanups))
    names
    (tltest-reach-mark-variant-payload-cleanups-at
      cleanups
      (tltest-reach-mark-variant-payload-cleanup
        (ast.ast-variant-payload-cleanup-list-get
          cleanups
          index
          (ast.ast-variant-payload-cleanup-fallback))
        names)
      (+ index 1))))

(define (tltest-reach-mark-variant-cleanups
  [variants : ast.AstVariantDefList]
  [names : tltest_name_map.Map]) : tltest_name_map.Map
  (tltest-reach-mark-variant-cleanups-at (& variants) names 0))

(define (tltest-reach-mark-variant-cleanups-at
  [variants : (& variants ast.AstVariantDefList)]
  [names : tltest_name_map.Map]
  [index : i64]) : tltest_name_map.Map
  (if (>= index (ast.ast-variant-def-list-len variants))
    names
    (match (ast.ast-variant-def-list-get
      variants
      index
      (ast.ast-variant-def-fallback))
      [(Def _ _ cleanups)
        (tltest-reach-mark-variant-cleanups-at
          variants
          (tltest-reach-mark-variant-payload-cleanups cleanups names)
          (+ index 1))])))

(define (tltest-reach-mark-decl
  [session : cis.InternStructuralSessionHandle]
  [decl : ast.AstDecl]
  [names : tltest_name_map.Map]) : tltest_name_map.Map
  (match decl
    [(Def decl-meta name _ expr)
      (if (tltest-reachable-name-marked? session names name)
        (tltest-reach-mark-expr session expr names)
        names)]
    [(DefFn decl-meta name _ _ body metadata)
      (match (ast.ast-fn-metadata-export metadata)
        [(Export _)
          (tltest-reach-mark-expr
            session
            body
            (tltest-reach-mark-name-id names name))]
        [(No)
          (if (tltest-reachable-name-marked? session names name)
            (tltest-reach-mark-expr session body names)
            names)])]
    [(DefMacro decl-meta _ _ _ body)
      (tltest-reach-mark-expr session body names)]
    ;; A top-level declaration macro call stays unexpanded here and is always
    ;; kept (tltest-reachable-runtime-decl?). Its arguments are the caller's
    ;; references: a constant named only by `(gen-slots first ...)` must survive
    ;; pruning, or the expansion reads an unbound name.
    [(Import decl-meta (Spec (MacroDecls call _) _ _ _ _))
      (tltest-reach-mark-expr session call names)]
    [(Unsafe inner-box)
      (let
        [inner : ast.AstDecl (deref inner-box)]
        (tltest-reach-mark-decl session inner names))]
    [(DefStruct decl-meta _ _ cleanup fields)
      (tltest-reach-mark-field-cleanups
        fields
        (tltest-reach-mark-struct-cleanup cleanup names))]
    [(DefStructLifetimes decl-meta _ _ _ cleanup fields)
      (tltest-reach-mark-field-cleanups
        fields
        (tltest-reach-mark-struct-cleanup cleanup names))]
    [(DefEnum decl-meta _ cleanup variants)
      (tltest-reach-mark-variant-cleanups
        variants
        (tltest-reach-mark-enum-cleanup cleanup names))]
    [(DefEnumLifetimes decl-meta _ _ cleanup variants)
      (tltest-reach-mark-variant-cleanups
        variants
        (tltest-reach-mark-enum-cleanup cleanup names))]
    [_ names]))

(define (tltest-reach-mark-decls-from
  [session : cis.InternStructuralSessionHandle]
  [decls : ast.AstDeclList]
  [names : tltest_name_map.Map]) : tltest_name_map.Map
  (let
    [cur : ast.AstDeclList decls]
    [result : tltest_name_map.Map names]
    [done : bool false]
    (while (not done)
      (match (ast.ast-decl-list-step cur)
        [(Nil) (set! done true)]
        [(Cons decl rest)
          (set! result (tltest-reach-mark-decl session decl result))
          (set! cur rest)]))
    result))

;; Iterate the reachability marker to a fixpoint. The reachable-name set only
;; ever grows (marking is monotonic and dedup'd), so a pass that adds no new
;; names means we have converged and can stop. `fuel` (the decl count) stays as
;; a safety bound, but convergence normally takes only a handful of passes
;; rather than `fuel` full-program walks.
(define (tltest-reach-fixed
  [session : cis.InternStructuralSessionHandle]
  [decls : ast.AstDeclList]
  [fuel : i64]
  [names : tltest_name_map.Map]) : tltest_name_map.Map
  (let
    [remaining : i64 fuel]
    [result : tltest_name_map.Map names]
    [done : bool false]
    (while (and (not done) (> remaining 0))
      (let
        [before : i64 (tltest_name_map.len (& result))]
        [next : tltest_name_map.Map
          (tltest-reach-mark-decls-from
            session
            (owned_view.compiler-owned-shared-view decls)
            (owned_view.compiler-owned-shared-view result))]
        (set! result next)
        (if (= (tltest_name_map.len (& result)) before)
          (set! done true)
          (set! remaining (- remaining 1)))))
    result))

(define (tltest-reachable-names
  [session : cis.InternStructuralSessionHandle]
  [decls : ast.AstDeclList]
  [tests : (__tl_dyn-array InlineTest)]) : tltest_name_map.Map
  (let
    [decl-count : i64
      (tltest-decl-list-count (owned_view.compiler-owned-shared-view decls))]
    (tltest-reach-fixed
      session
      (owned_view.compiler-owned-shared-view decls)
      decl-count
      (tltest-reach-mark-runtime-helper-roots
        decls
        (tltest-reach-mark-test-harness-runtime
          (tltest-reach-mark-tests
            session
            tests
            (tltest_name_map.with-capacity 64)))))))

(define (tltest-reachable-runtime-decl?
  [session : cis.InternStructuralSessionHandle]
  [decl : ast.AstDecl]
  [names : (& names tltest_name_map.Map)]) : bool
  (match decl
    [(Def decl-meta name _ _)
      (tltest-reachable-name-marked? session names name)]
    [(DefFn decl-meta name _ _ _ metadata)
      (let
        [marked : bool (tltest-reachable-name-marked? session names name)]
        (match (ast.ast-fn-metadata-export metadata)
          [(Export _) true]
          [(No) marked]))]
    [(Extern decl-meta name _ _ _)
      (tltest-reachable-name-marked? session names name)]
    [(DefMacro decl-meta _ _ _ _) true]
    [(Unsafe inner-box)
      (let
        [inner : ast.AstDecl (deref inner-box)]
        (tltest-reachable-runtime-decl? session inner names))]
    [_ true]))

(define (tltest-prune-runtime-decls-in
  [session : cis.InternStructuralSessionHandle]
  [decls : ast.AstDeclList]
  [paths : ast.AstDeclPathList]
  [target-path : String]
  [names : tltest_name_map.Map]
  [out-decls : ast.AstDeclList]
  [out-paths : ast.AstDeclPathList]) : InlineRuntimeDecls
  (let
    [cur-decls : ast.AstDeclList decls]
    [cur-paths : ast.AstDeclPathList paths]
    [result-decls : ast.AstDeclList out-decls]
    [result-paths : ast.AstDeclPathList out-paths]
    [done : bool false]
    (while (not done)
      (match (ast.ast-decl-list-step cur-decls)
        [(Nil) (set! done true)]
        [(Cons decl rest)
          (match (ast.ast-decl-path-list-step cur-paths)
            [(Nil)
              (set! cur-decls rest)
              (set! cur-paths (ast.ast-decl-path-list-new))]
            [(Cons decl-path path-rest)
              (let
                [decl-owner-id : i64
                  (ast.ast-decl-path-list-owner-id
                    (& cur-paths)
                    0
                    cbi.compiler-builtin-id-fix-empty)]
                ;; Keep imported generated helpers: macro-expanded bodies can
                ;; reference them in ways the lightweight source reachability walk
                ;; cannot always see. Local generated helpers and ordinary imported
                ;; functions/values still go through reachability pruning so tiny
                ;; inline harnesses stay small.
                (when
                  (or
                    (tltest-reachable-runtime-decl?
                      session
                      (owned_view.compiler-owned-shared-view decl)
                      names)
                    (and
                      (not (tltest-owned-test-path? target-path decl-path))
                      (tltest-generated-comptime-decl?
                        (owned_view.compiler-owned-shared-view decl))))
                  (ast.ast-decl-list-push (&mut result-decls) decl)
                  (ast.ast-decl-path-list-push-with-owner-id
                    (&mut result-paths)
                    decl-path
                    decl-owner-id))
                (set! cur-decls rest)
                (set! cur-paths path-rest))])]))
    (Decls result-decls result-paths)))

(define (tltest-prune-runtime-decls
  [session : cis.InternStructuralSessionHandle]
  [source : (& source str)]
  [decls : ast.AstDeclList]
  [paths : ast.AstDeclPathList]
  [tests : (__tl_dyn-array InlineTest)]) : InlineRuntimeDecls
  (tltest-prune-runtime-decls-in
    session
    (owned_view.compiler-owned-shared-view decls)
    paths
    (compiler_load.compiler-load-normalize-path source)
    (tltest-reachable-names session decls tests)
    (ast.ast-decl-list-new)
    (ast.ast-decl-path-list-new)))

(define (tltest-build-harness-with-session
  [session : cis.InternStructuralSessionHandle]
  [source : String]
  [decls : ast.AstDeclList]
  [paths : ast.AstDeclPathList]) : InlineHarness
  (match (tltest-collect source decls paths)
    [(Collect runtime-decls runtime-paths tests)
      (match (tltest-prune-runtime-decls
        session
        source
        runtime-decls
        runtime-paths
        (owned_view.compiler-owned-shared-view tests))
        [(Decls pruned-decls pruned-paths)
          (let
            [count : i64 (array-length tests)]
            (Harness
              (ast.ast-program
                (compiler_load.compiler-load-decl-list-append
                  pruned-decls
                  (tltest-generated-test-decls
                    (owned_view.compiler-owned-shared-view tests))))
              (compiler_load.compiler-load-decl-path-list-append
                pruned-paths
                (tltest-generated-test-paths source tests))
              count))])]))

;; Standalone tltest runs serially. Keep the active-session capture at this
;; outer adapter; every reachability predicate below it receives and validates
;; the resulting explicit capability.
(define (tltest-active-structural-session) : cis.InternStructuralSessionHandle
  (cis.intern-structural-session-handle-from-source-names
    (ci.intern-source-name-session-capture-active-handle)))

(define (tltest-build-harness
  [source : String]
  [decls : ast.AstDeclList]
  [paths : ast.AstDeclPathList]) : InlineHarness
  (tltest-build-harness-with-session
    (tltest-active-structural-session)
    source
    decls
    paths))

(define (tltest-inline-typecheck-cfgs [cfgs : sym_i64_env.SymI64Env]) : sym_i64_env.SymI64Env
  (cfg_core.compiler-cfg-enable cfgs "test"))

(define (tltest-inline-typecheck-program
  [decls : ast.AstDeclList]
  [tests : (__tl_dyn-array InlineTest)]) : ast.AstProgram
  (ast.ast-program
    (compiler_load.compiler-load-decl-list-append
      decls
      (tltest-generated-typecheck-decls tests))))

(define (tltest-inline-typecheck-paths
  [paths : ast.AstDeclPathList]
  [tests : (__tl_dyn-array InlineTest)]) : ast.AstDeclPathList
  (compiler_load.compiler-load-decl-path-list-append
    paths
    (tltest-generated-typecheck-paths tests)))

(define (tltest-inline-typecheck-loaded
  [source : String]
  [decls : ast.AstDeclList]
  [paths : ast.AstDeclPathList]
  [roots : cli_svec.Vec]
  [cfgs : sym_i64_env.SymI64Env]
  [cache-scope-prefix : String]) : i64
  (match (tltest-collect source decls paths)
    [(Collect runtime-decls runtime-paths tests)
      (let
        [count : i64 (array-length tests)]
        (if (= count 0)
          0
          (match (tltest-prune-runtime-decls
            (tltest-active-structural-session)
            source
            runtime-decls
            runtime-paths
            (owned_view.compiler-owned-shared-view tests))
            [(Decls pruned-decls pruned-paths)
              (let
                [legacy-roots : cli_svec.Vec roots]
                (match (compiler_typecheck_api.typecheck-compiler-program-with-paths-cache
                  (tltest-inline-typecheck-program
                    pruned-decls
                    (owned_view.compiler-owned-shared-view tests))
                  (tltest-inline-typecheck-paths pruned-paths tests)
                  (owned_view.compiler-owned-shared-view legacy-roots)
                  cfgs
                  (compiler_typecheck_api.compiler-typecheck-prefix-cache-scope
                    cache-scope-prefix
                    legacy-roots
                    cfgs))
                  [(ResultCompilerTypecheck.Ok _) 0]
                  [(ResultCompilerTypecheck.Err diag)
                    (io.print-error
                      (driver.compiler-driver-render-source-diagnostic
                        (tltest-diagnostic-with-source-fallback
                          source
                          (cdiag.compiler-diagnostic-list-first (deref diag)))))
                    1]))])))]))

(define (tltest-inline-stdlib-source?
  [source : (& source str)]
  [roots : cli_svec.Vec]) : bool
  (let
    [normalized : String (compiler_load.compiler-load-normalize-path source)]
    [stdlib-path : String
      (if (compiler_load.compiler-load-stdlib-import? normalized)
        normalized
        (compiler_load.compiler-load-stdlib-owned-path-from-roots
          normalized
          roots))]
    (compiler_load.compiler-load-stdlib-import? stdlib-path)))

(define (tltest-inline-clear-load-only-caches!) : unit
  (compiler_load.compiler-load-program-cache-clear!)
  (compiler_load.compiler-load-runtime-prelude-cache-clear!)
  (tc_core.tc-prefix-snapshot-cache-clear!))

(define (tltest-inline-clear-load-caches!) : unit
  (tltest-inline-clear-load-only-caches!)
  (driver.compiler-driver-reset-analysis-state!))

(define (tltest-inline-reset-load-state!) : unit
  ;; Inline preflight runs after ordinary check/doctest phases in some CLI
  ;; commands. Drop cached loaded ASTs so the test-cfg load cannot reuse decl
  ;; nodes owned by a previous phase. Reset AST/type pools between package
  ;; sources to keep large packages bounded, but keep interns live because
  ;; callers may have already constructed cfg maps and path strings.
  (tltest-inline-clear-load-caches!)
  (compiler_load.compiler-load-session-reset-pools!)
  (driver.compiler-driver-reset-analysis-state!))

(define (tltest-inline-typecheck-file-with-cfg
  [source : String]
  [roots : cli_svec.Vec]
  [cfgs : sym_i64_env.SymI64Env]
  [cache-scope-prefix : String]) : i64
  (if (or
    (tltest-inline-stdlib-source? source (clone roots))
    (not (io.file-exists? (owned_view.compiler-owned-shared-view source)))
    (not
      (tltest-source-has-inline-tests?
        (owned_view.compiler-owned-shared-view source))))
    0
    (let
      [test-cfgs : sym_i64_env.SymI64Env (tltest-inline-typecheck-cfgs cfgs)]
      [legacy-roots : cli_svec.Vec (clone roots)]
      (tltest-inline-reset-load-state!)
      (match (driver.compiler-driver-load-file-with-runtime
        (owned_view.compiler-owned-shared-view source)
        legacy-roots
        test-cfgs)
        [(Ok decls paths _ _)
          (tltest-inline-typecheck-loaded
            source
            decls
            paths
            roots
            test-cfgs
            cache-scope-prefix)]
        [(Err diag)
          (io.print-error
            (driver.compiler-driver-render-source-diagnostic
              (tltest-diagnostic-with-source-fallback source (deref diag))))
          1]))))

(define (tltest-inline-typecheck-package-source-with-cfg
  [source : String]
  [roots : cli_svec.Vec]
  [manifest-dir : String]
  [package-owner : String]
  [deps : compiler_load.CompilerPkgDeps]
  [cfgs : sym_i64_env.SymI64Env]
  [cache-scope-prefix : String]) : i64
  (if (tltest-source-has-inline-tests?
    (owned_view.compiler-owned-shared-view source))
    (let
      [test-cfgs : sym_i64_env.SymI64Env (tltest-inline-typecheck-cfgs cfgs)]
      [legacy-roots : cli_svec.Vec (clone roots)]
      (match (driver.compiler-driver-load-package-file-with-runtime-owned-cfg
        (owned_view.compiler-owned-shared-view source)
        (owned_view.compiler-owned-shared-view legacy-roots)
        (owned_view.compiler-owned-shared-view manifest-dir)
        (owned_view.compiler-owned-shared-view package-owner)
        deps
        true
        test-cfgs)
        [(Ok decls paths _ _)
          (tltest-inline-typecheck-loaded
            (compiler_load.compiler-load-package-owned-path
              package-owner
              manifest-dir
              legacy-roots
              source)
            decls
            paths
            roots
            test-cfgs
            cache-scope-prefix)]
        [(Err diag)
          (io.print-error
            (driver.compiler-driver-render-source-diagnostic
              (tltest-diagnostic-with-source-fallback source (deref diag))))
          1]))
    0))

(define (tltest-inline-typecheck-package-source-scoped
  [source : String]
  [roots : cli_svec.Vec]
  [manifest-dir : String]
  [package-owner : String]
  [deps : compiler_load.CompilerPkgDeps]
  [cfg-names : cfg_core.CompilerCfgSnapshot]
  [cache-scope-prefix : String]) : i64
  (let
    [home : arena.Arena (arena.current)]
    (with-scratch
      (tltest-inline-clear-load-only-caches!)
      (driver.compiler-driver-reset-file-state!)
      (compiler_load.compiler-load-session-state-dependency-surfaces-release!
        (compiler_load.compiler-load-active-session-state-shared-view))
      (ci.intern-persistent-arena-reset!)
      (compiler_load.compiler-load-transfer-frontend-handoff!)
      (let
        [pools : ast.AstNodePoolContext
          (driver.compiler-driver-state-new-checked-lower-pools)]
        [_install : unit (ast.ast-node-pool-context-install! pools)]
        [status : i64
          (tltest-inline-typecheck-package-source-with-cfg
            source
            roots
            manifest-dir
            package-owner
            deps
            (cfg_core.compiler-cfg-snapshot-to-env cfg-names)
            cache-scope-prefix)]
        [retired : ast.AstNodePoolContext
          (ast.ast-node-pool-context-capture-active)]
        ;; Retire all references before returning pool storage. Replacement
        ;; session/cache carriers must live outside the entry scratch arena.
        (in-arena
          home
          (tltest-inline-clear-load-only-caches!)
          (driver.compiler-driver-reset-file-state!)
          (compiler_load.compiler-load-session-state-dependency-surfaces-release!
            (compiler_load.compiler-load-active-session-state-shared-view))
          (driver.compiler-driver-state-destroy-uncommitted-pools! retired)
          (ci.intern-persistent-arena-reset!)
          (compiler_load.compiler-load-transfer-frontend-handoff!))
        status))))

(define (tltest-inline-typecheck-package-sources-from
  [sources : cli_svec.Vec]
  [index : i64]
  [roots : cli_svec.Vec]
  [manifest-dir : String]
  [package-owner : String]
  [deps : compiler_load.CompilerPkgDeps]
  [cfgs : sym_i64_env.SymI64Env]
  [cache-scope-prefix : String]) : i64
  (let
    [count : i64 (cli_svec.len (& sources))]
    [cursor : i64 index]
    [status : i64 0]
    [cfg-names : cfg_core.CompilerCfgSnapshot
      (cfg_core.compiler-cfg-snapshot-from-env cfgs)]
    (while (and (= status 0) (< cursor count))
      (let
        [source : String (cli_svec.get (& sources) cursor "")]
        [has-inline-tests : bool
          (tltest-source-has-inline-tests?
            (owned_view.compiler-owned-shared-view source))]
        (if has-inline-tests
          (set!
            status
            (tltest-inline-typecheck-package-source-scoped
              (owned_view.compiler-owned-shared-view source)
              (owned_view.compiler-owned-shared-view roots)
              (owned_view.compiler-owned-shared-view manifest-dir)
              (owned_view.compiler-owned-shared-view package-owner)
              (owned_view.compiler-owned-shared-view deps)
              (owned_view.compiler-owned-shared-view cfg-names)
              (owned_view.compiler-owned-shared-view cache-scope-prefix)))
          (set! status 0))
        (if (= status 0)
          unit
          (io.print-error
            (str_cat.str-cat "test: package inline preflight failed: " source)))
        (set! cursor (+ cursor 1))))
    (tltest-inline-clear-load-only-caches!)
    (driver.compiler-driver-reset-file-state!)
    status))

(define (tltest-inline-typecheck-package-sources-with-cfg
  [sources : cli_svec.Vec]
  [roots : cli_svec.Vec]
  [manifest-dir : String]
  [package-owner : String]
  [deps : compiler_load.CompilerPkgDeps]
  [cfgs : sym_i64_env.SymI64Env]
  [cache-scope-prefix : String]) : i64
  (tltest-inline-typecheck-package-sources-from
    sources
    0
    roots
    manifest-dir
    package-owner
    deps
    cfgs
    cache-scope-prefix))

(define (tltest-user-cfgs-from [index : i64] [cfgs : sym_i64_env.SymI64Env]) : sym_i64_env.SymI64Env
  (if (>= index tltest-user-cfg-len)
    cfgs
    (tltest-user-cfgs-from
      (+ index 1)
      (cfg_core.compiler-cfg-enable
        cfgs
        (cli_svec.get (& tltest-user-cfg-slots) index "")))))

(define (tltest-cfgs [backend-target : compiler_backend.CompilerBackendTarget]) : sym_i64_env.SymI64Env
  (tltest-user-cfgs-from
    0
    (cfg_core.compiler-cfg-enable
      (driver.compiler-driver-target-cfgs
        backend-target
        (cfg_core.compiler-cfg-empty))
      "test")))

(define (tltest-check-only
  [program : ast.AstProgram]
  [paths : ast.AstDeclPathList]
  [count : i64]
  [target : compiler_backend.CompilerBackendTarget]
  [roots : cli_svec.Vec]) : i64
  (let
    [legacy-roots : cli_svec.Vec (clone roots)]
    (match (compiler_typecheck_api.typecheck-compiler-program-with-paths-cache
      (tltest-program-with-print-runtime program target)
      (tltest-paths-with-print-runtime target paths)
      (owned_view.compiler-owned-shared-view legacy-roots)
      (tltest-cfgs target)
      (compiler_typecheck_api.compiler-typecheck-prefix-cache-scope
        "typecheck-prefix-test-cli"
        legacy-roots
        (tltest-cfgs target)))
      [(ResultCompilerTypecheck.Ok _)
        (io.print-format
          "{}"
          (str_cat.str-cat
            "TypeLisp test typecheck passed: "
            (string.int->string count)
            " test(s)\n"))
        0]
      [(ResultCompilerTypecheck.Err diag)
        (io.print-error
          (driver.compiler-driver-render-source-diagnostic
            (cdiag.compiler-diagnostic-list-first (deref diag))))
        1])))

(define (tltest-stderr-ends-with-newline? [text : String]) : bool
  (let
    [n : i64 (string.string-length text)]
    (if (= n 0)
      true
      (let
        [last : char (string.string-ref text (- n 1))]
        (or (= last '\n') (= last '\r'))))))

(define (tltest-report-child-status [output : process.ProcessOutput]) : unit
  (if (tltest-stderr-ends-with-newline? (process.output-stderr output))
    unit
    (io.print-error "\n"))
  (io.print-error
    (str_cat.str-cat
      "typelisp test: test executable exited with exit status: "
      (string.int->string (process.output-status output))
      "\n")))

(define (tltest-diagnostic-with-source-fallback
  [source : String]
  [diag : cdiag.CompilerDiagnostic]) : cdiag.CompilerDiagnostic
  (cdiag.compiler-diagnostic-with-fallback-path diag source))

(define (tltest-executable-spawn-detail [bin-path : String]) : String
  (match (build_run_core.source-tool-try-file-exists? bin-path)
    [(OkIoBool exists)
      (if exists
        "test executable exists; child-process spawn failed"
        "test executable is missing after link")]
    [(ErrIoBool error)
      (str_cat.str-cat
        "could not inspect test executable: "
        (io.error-message error))]))

(define (tltest-run-executable-error-message
  [bin-path : String]
  [temp-dir : String]
  [error : process.ProcessError]) : String
  (str_cat.str-cat
    "Error: failed to run test executable '"
    (owned_view.compiler-owned-shared-view bin-path)
    "': "
    (process.error-message error)
    " ("
    (tltest-executable-spawn-detail bin-path)
    "); preserving test artifacts in '"
    temp-dir
    "'\n"))

(define (tltest-stdlib-env-fixture-source? [source : String]) : bool
  (let
    [normalized : String (compiler_load.compiler-load-normalize-path source)]
    (or
      (string.eq normalized "stdlib/env.tl")
      (string.eq normalized "stdlib/tests/env_api.tl"))))

(define (tltest-stdlib-env-fixture-path
  [target : compiler_backend.CompilerBackendTarget]) : String
  (if (compiler_backend.compiler-backend-target-windows? target)
    "one;two;three"
    "one:two:three"))

(define (tltest-stdlib-env-fixture-env
  [target : compiler_backend.CompilerBackendTarget]) : process.ProcessEnvList
  (process.env-cons
    "TYPELISP_STDLIB_TEST_EMPTY"
    ""
    (process.env-cons
      "TYPELISP_STDLIB_TEST_VALUE"
      "env-value-854"
      (process.env-cons
        "TYPELISP_STDLIB_TEST_PATH"
        (tltest-stdlib-env-fixture-path target)
        (process.env-empty)))))

;; Test harnesses use the driver's target/backend mode pairing, just like
;; compile/build/run. A target-neutral Scalar lower mode misses target ABI
;; rules, including Win64's caller copy for by-value aggregates (#8009).
(define (tltest-harness-lower-mode
  [target : compiler_backend.CompilerBackendTarget]
  [backend-mode : compiler_backend.CompilerBackendMode]) : lower.CompilerLowerMode
  (driver.compiler-driver-lower-mode-for-target target backend-mode))

(define (tltest-run-harness-in-temp-with-lower-state
  [lower-state : lower.CompilerLowerState]
  [source : String]
  [entry-path : String]
  [program : ast.AstProgram]
  [paths : ast.AstDeclPathList]
  [roots : cli_svec.Vec]
  [target : compiler_backend.CompilerBackendTarget]
  [opt-level : i64]
  [backend-mode : compiler_backend.CompilerBackendMode]
  [inline-harness : bool]
  [temp-dir : String]) : i64
  (let
    [files : build_run_core.SourceToolTempFiles
      (build_run_core.source-tool-temp-files temp-dir source target)]
    [legacy-roots : cli_svec.Vec (clone roots)]
    ;; Generated inline harnesses reserve status 1 for recoverable assertion
    ;; failures, so a harness that cannot be built, cannot start, or aborts or
    ;; traps maps to status 2. Integration programs keep their historical 0/1
    ;; normalization.
    [failed : i64
      (if inline-harness
        2
        1)]
    (match (lower.lower-compiler-program-with-decl-paths-mode-cache-and-state
      lower-state
      entry-path
      program
      paths
      (tltest-harness-lower-mode target backend-mode)
      (owned_view.compiler-owned-shared-view legacy-roots)
      (tltest-cfgs target)
      (compiler_typecheck_api.compiler-typecheck-prefix-cache-scope
        "typecheck-prefix-test-cli"
        legacy-roots
        (tltest-cfgs target)))
      [(Ok ir spans)
        (match (build_run_core.source-tool-link-and-run
          (build_run_core.SourceToolLinkRequest
            (owned_view.compiler-owned-shared-view source)
            (Lowered ir spans)
            target
            opt-level
            backend-mode
            (build_run_core.source-tool-link-inputs-empty)
            (owned_view.compiler-owned-shared-view files)
            "test: failed to write assembly artifact")
          (process.args-empty)
          (if (tltest-stdlib-env-fixture-source? source)
            (tltest-stdlib-env-fixture-env target)
            (process.env-empty))
          false)
          [(LinkFailed message)
            (io.print-error message)
            (build_run_core.source-tool-clean-temp-files files true)
            failed]
          [(Ran output)
            (let
              [status : i64 (process.output-status output)]
              (driver.compiler-driver-reset-analysis-state!)
              (build_run_core.source-tool-forward-output output)
              (if (or (= status 0) (and inline-harness (= status 1)))
                unit
                (tltest-report-child-status output))
              (build_run_core.source-tool-clean-temp-files files true)
              (cond
                [(= status 0) 0]
                [(and inline-harness (= status 1)) 1]
                [else failed]))]
          ;; Keep the artifacts of a harness that would not start.
          [(SpawnFailed error)
            (driver.compiler-driver-reset-analysis-state!)
            (io.print-error
              (tltest-run-executable-error-message files.bin files.dir error))
            failed])]
      [(Err diag)
        (io.print-error
          (driver.compiler-driver-render-source-diagnostic
            (tltest-diagnostic-with-source-fallback source (deref diag))))
        (build_run_core.source-tool-clean-temp-files files true)
        failed])))

(define (tltest-run-harness-in-temp
  [source : String]
  [entry-path : String]
  [program : ast.AstProgram]
  [paths : ast.AstDeclPathList]
  [roots : cli_svec.Vec]
  [target : compiler_backend.CompilerBackendTarget]
  [opt-level : i64]
  [backend-mode : compiler_backend.CompilerBackendMode]
  [inline-harness : bool]
  [temp-dir : String]) : i64
  (let
    [lower-state : lower.CompilerLowerState (lower.compiler-lower-state-new)]
    [status : i64
      (tltest-run-harness-in-temp-with-lower-state
        lower-state
        source
        entry-path
        program
        paths
        roots
        target
        opt-level
        backend-mode
        inline-harness
        temp-dir)]
    (lower.compiler-lower-state-reset! lower-state)
    (lower.compiler-lower-arena-state-release!
      (lower.compiler-lower-state-arenas lower-state))
    status))

(define (tltest-run-direct-with-entry
  [source : String]
  [entry-path : String]
  [program : ast.AstProgram]
  [paths : ast.AstDeclPathList]
  [roots : cli_svec.Vec]
  [target : String]
  [opt-level : i64]
  [backend-mode : compiler_backend.CompilerBackendMode]
  [inline-harness : bool]) : i64
  (match (build_run_core.source-tool-target
    (owned_view.compiler-owned-shared-view target))
    [(Err _)
      (io.print-error (tltest-unknown-target target))
      1]
    [(Ok backend-target)
      (match (build_run_core.source-tool-create-temp-dir "typelisp-test")
        [(Ok temp-dir)
          (tltest-run-harness-in-temp
            source
            entry-path
            (tltest-program-with-print-runtime program backend-target)
            (tltest-paths-with-print-runtime backend-target paths)
            roots
            backend-target
            opt-level
            backend-mode
            inline-harness
            temp-dir)]
        [(Err message)
          (io.print-error
            (str_cat.str-cat "test: failed to create temp dir: " message))
          1])]))

(define (tltest-run-direct
  [source : String]
  [program : ast.AstProgram]
  [paths : ast.AstDeclPathList]
  [roots : cli_svec.Vec]
  [target : String]
  [opt-level : i64]
  [backend-mode : compiler_backend.CompilerBackendMode]) : i64
  (tltest-run-direct-with-entry
    (owned_view.compiler-owned-shared-view source)
    source
    program
    paths
    roots
    target
    opt-level
    backend-mode
    true))

(define (tltest-no-tests-check
  [decls : ast.AstDeclList]
  [paths : ast.AstDeclPathList]
  [roots : cli_svec.Vec]
  [target : compiler_backend.CompilerBackendTarget]) : i64
  (let
    [legacy-roots : cli_svec.Vec (clone roots)]
    (match (compiler_typecheck_api.typecheck-compiler-program-with-paths-cache
      (ast.ast-program decls)
      paths
      (owned_view.compiler-owned-shared-view legacy-roots)
      (tltest-cfgs target)
      (compiler_typecheck_api.compiler-typecheck-prefix-cache-scope
        "typecheck-prefix-test-cli"
        legacy-roots
        (tltest-cfgs target)))
      [(ResultCompilerTypecheck.Ok _)
        (io.print-format "{}" "TypeLisp test typecheck passed: 0 test(s)\n")
        0]
      [(ResultCompilerTypecheck.Err diag)
        (io.print-error
          (driver.compiler-driver-render-source-diagnostic
            (cdiag.compiler-diagnostic-list-first (deref diag))))
        1])))

(define (tltest-no-tests-run
  [source : String]
  [target : String]
  [program : ast.AstProgram]
  [paths : ast.AstDeclPathList]
  [roots : cli_svec.Vec]
  [opt-level : i64]
  [backend-mode : compiler_backend.CompilerBackendMode]) : i64
  ;; `test --check` owns source typechecking. Run the zero-test harness built
  ;; from the pruned runtime declarations so backend-emitted allocator calls
  ;; still have their exported abort handlers; the harness replaces the source
  ;; `main` with the generated zero-test runner.
  (tltest-run-direct source program paths roots target opt-level backend-mode))

(define (tltest-source-prefix-space? [c : char]) : bool
  (or (= c ' ') (= c '\t')))

(define (tltest-source-line-break? [c : char]) : bool
  (or (= c '\n') (= c '\r')))

(define (tltest-inline-marker-boundary?
  [source : (& source str)]
  [idx : i64]
  [n : i64]) : bool
  (if (>= idx n)
    true
    (let
      [c : char (string.string-ref source idx)]
      (or
        (tltest-source-prefix-space? c)
        (tltest-source-line-break? c)
        (= c ')')))))

(define (tltest-inline-marker-at?
  [source : (& source str)]
  [idx : i64]
  [n : i64]) : bool
  (and
    (<= (+ idx 5) n)
    (= (string.string-ref source idx) '(')
    (= (string.string-ref source (+ idx 1)) 't')
    (= (string.string-ref source (+ idx 2)) 'e')
    (= (string.string-ref source (+ idx 3)) 's')
    (= (string.string-ref source (+ idx 4)) 't')
    (tltest-inline-marker-boundary? source (+ idx 5) n)))

(define (tltest-source-has-inline-tests-from
  [source : (& source str)]
  [idx : i64]
  [n : i64]
  [line-open : bool]) : bool
  (let
    [i : i64 idx]
    [open : bool line-open]
    [found : bool false]
    (while (and (not found) (< i n))
      (let
        [c : char (string.string-ref source i)]
        (cond
          [(and open (tltest-source-line-break? c))
            (set! i (+ i 1))
            (set! open true)]
          [(and open (tltest-source-prefix-space? c))
            (set! i (+ i 1))
            (set! open true)]
          [(and open (tltest-inline-marker-at? source i n)) (set! found true)]
          [(tltest-source-line-break? c)
            (set! i (+ i 1))
            (set! open true)]
          [else
            (set! i (+ i 1))
            (set! open false)])))
    found))

(define (tltest-source-has-inline-tests? [source : String]) : bool
  (with-scratch
    (let
      [text : String (byte_buf.to-string (io.read-file source))]
      (tltest-source-has-inline-tests-from
        text
        0
        (string.string-length text)
        true))))

(define (tltest-package-tests-prefix [manifest-dir : String]) : String
  (str_cat.str-cat
    (compiler_load.compiler-load-normalize-path
      (package_source_core.package-source-root-join manifest-dir "tests"))
    "/"))

(define (tltest-package-test-source?
  [source : (& source str)]
  [tests-prefix : (& tests-prefix str)]) : bool
  (source_text.starts-with?
    (compiler_load.compiler-load-normalize-path source)
    tests-prefix))

(define (tltest-package-tests-subdir-prefix
  [tests-prefix : String]
  [name : String]) : String
  (str_cat.str-cat tests-prefix name "/"))

(define (tltest-package-manifest-managed-integration? [tests-prefix : String]) : bool
  (let
    [integration-prefix : String
      (tltest-package-tests-subdir-prefix tests-prefix "integration")]
    (io.file-exists? (str_cat.str-cat integration-prefix "native.manifest"))))

(define (tltest-package-manifest-managed-integration-source-with?
  [normalized : (& normalized str)]
  [tests-prefix : String]
  [manifest-managed : bool]) : bool
  (and
    manifest-managed
    (source_text.starts-with?
      normalized
      (tltest-package-tests-subdir-prefix tests-prefix "integration"))))

(define (tltest-package-manifest-managed-integration-source?
  [normalized : (& normalized str)]
  [tests-prefix : String]) : bool
  (tltest-package-manifest-managed-integration-source-with?
    normalized
    (owned_view.compiler-owned-shared-view tests-prefix)
    (tltest-package-manifest-managed-integration? tests-prefix)))

(define (tltest-package-reserved-fixture-source?
  [source : String]
  [tests-prefix : String]) : bool
  (let
    [normalized : String (compiler_load.compiler-load-normalize-path source)]
    (or
      (tltest-package-manifest-managed-integration-source?
        normalized
        (owned_view.compiler-owned-shared-view tests-prefix))
      (source_text.starts-with?
        normalized
        (tltest-package-tests-subdir-prefix
          (owned_view.compiler-owned-shared-view tests-prefix)
          "format_golden"))
      (source_text.starts-with?
        normalized
        (tltest-package-tests-subdir-prefix
          (owned_view.compiler-owned-shared-view tests-prefix)
          "golden"))
      (source_text.starts-with?
        normalized
        (tltest-package-tests-subdir-prefix
          (owned_view.compiler-owned-shared-view tests-prefix)
          "inline"))
      (source_text.starts-with?
        normalized
        (tltest-package-tests-subdir-prefix
          (owned_view.compiler-owned-shared-view tests-prefix)
          "no-libc"))
      (source_text.starts-with?
        normalized
        (tltest-package-tests-subdir-prefix
          (owned_view.compiler-owned-shared-view tests-prefix)
          "public-tools"))
      (source_text.starts-with?
        normalized
        (tltest-package-tests-subdir-prefix
          (owned_view.compiler-owned-shared-view tests-prefix)
          "safety"))
      (source_text.starts-with?
        normalized
        (tltest-package-tests-subdir-prefix
          (owned_view.compiler-owned-shared-view tests-prefix)
          "spmd"))
      (source_text.starts-with?
        normalized
        (tltest-package-tests-subdir-prefix tests-prefix "tlci")))))

(define (tltest-package-integration-source?
  [source : String]
  [tests-prefix : String]) : bool
  (not (tltest-package-reserved-fixture-source? source tests-prefix)))

(define (tltest-decls-have-main? [decls : ast.AstDeclList]) : bool
  (match (ast.ast-decl-list-step decls)
    [(Nil) false]
    [(Cons decl rest)
      (if (tltest-main-decl? decl)
        true
        (tltest-decls-have-main? rest))]))

(define (tltest-package-source-line [source : String] [count : i64]) : String
  (str_cat.str-cat
    "TypeLisp test file: "
    source
    " ("
    (string.int->string count)
    " test(s))\n"))

(define (tltest-package-summary-line
  [mode : TestMode]
  [file-count : i64]
  [test-count : i64]) : String
  (if tltest-list-only
    (str_cat.str-cat
      "TypeLisp package tests listed: "
      (string.int->string test-count)
      " test(s) in "
      (string.int->string file-count)
      " file(s)\n")
    (match mode
      [(Check)
        (str_cat.str-cat
          "TypeLisp package test typecheck passed: "
          (string.int->string test-count)
          " test(s) in "
          (string.int->string file-count)
          " file(s)\n")]
      [(Run)
        (str_cat.str-cat
          "TypeLisp package tests passed: "
          (string.int->string test-count)
          " test(s) in "
          (string.int->string file-count)
          " file(s)\n")])))

(define (tltest-package-run-one
  [source : String]
  [target : String]
  [roots : cli_svec.Vec]
  [opt-level : i64]
  [backend-mode : compiler_backend.CompilerBackendMode]
  [test-mode : TestMode]
  [backend-target : compiler_backend.CompilerBackendTarget]
  [decls : ast.AstDeclList]
  [paths : ast.AstDeclPathList]) : ResultTestPackageTotals
  (match (tltest-build-harness
    (owned_view.compiler-owned-shared-view source)
    (owned_view.compiler-owned-shared-view decls)
    (owned_view.compiler-owned-shared-view paths))
    [(Harness program harness-paths count)
      (if tltest-list-only
        (let
          [listed : i64 (tltest-list-loaded source decls paths)]
          (Ok
            (if (= listed 0)
              0
              1)
            listed))
        (if (= count 0)
          (begin
            (if (tltest-selection-set?)
              unit
              (io.print-error
                (str_cat.str-cat
                  "test: discovered inline test marker but no inline tests in "
                  source
                  "\n")))
            (if (tltest-selection-set?)
              (Ok 0 0)
              (Err 1)))
          (begin
            (io.print-format
              "{}"
              (tltest-package-source-line
                (owned_view.compiler-owned-shared-view source)
                count))
            (let
              [status : i64
                (match test-mode
                  [(Check)
                    (tltest-check-only
                      program
                      harness-paths
                      count
                      backend-target
                      roots)]
                  [(Run)
                    (tltest-run-direct
                      source
                      program
                      harness-paths
                      roots
                      target
                      opt-level
                      backend-mode)])]
              (if (= status 0)
                (Ok 1 count)
                (if (and (= status 1) (not (tltest-check-mode? test-mode)))
                  (Failed 1 count 1)
                  (Err status)))))))]))

(define (tltest-package-integration-line [source : String]) : String
  (str_cat.str-cat "TypeLisp integration test file: " source "\n"))

(define (tltest-package-integration-selected? [source : (& source str)]) : bool
  (if tltest-name-exact-set
    (string.eq source tltest-name-exact)
    (if tltest-name-filter-set
      (string.contains source (& tltest-name-filter))
      true)))

(define (tltest-package-selected-integration-sources
  [sources : cli_svec.Vec]
  [tests-prefix : String]) : cli_svec.Vec
  (let
    [selected : cli_svec.Vec (cli_svec.new)]
    [index : i64 0]
    (while (< index (cli_svec.len (& sources)))
      (let
        [source : String (cli_svec.get (& sources) index "")]
        (if (and
          (tltest-package-integration-source?
            (owned_view.compiler-owned-shared-view source)
            (owned_view.compiler-owned-shared-view tests-prefix))
          (tltest-package-integration-selected? source))
          (cli_svec.push-ref! (&mut selected) source)
          unit)
        (set! index (+ index 1))))
    (tltest-shuffle-string-vec! (&mut selected))
    selected))

(define (tltest-package-integration-missing-main [source : String]) : String
  (str_cat.str-cat "test: integration test file has no main: " source "\n"))

(define (tltest-package-integration-check
  [source : String]
  [decls : ast.AstDeclList]
  [paths : ast.AstDeclPathList]
  [roots : cli_svec.Vec]
  [target : compiler_backend.CompilerBackendTarget]) : ResultTestPackageTotals
  (io.print-format
    "{}"
    (tltest-package-integration-line
      (owned_view.compiler-owned-shared-view source)))
  (if (tltest-decls-have-main? (owned_view.compiler-owned-shared-view decls))
    (let
      [legacy-roots : cli_svec.Vec (clone roots)]
      (match (compiler_typecheck_api.typecheck-compiler-program-with-paths-cache
        (ast.ast-program decls)
        paths
        (owned_view.compiler-owned-shared-view legacy-roots)
        (tltest-cfgs target)
        (compiler_typecheck_api.compiler-typecheck-prefix-cache-scope
          "typecheck-prefix-test-cli"
          legacy-roots
          (tltest-cfgs target)))
        [(ResultCompilerTypecheck.Ok _) (Ok 1 1)]
        [(ResultCompilerTypecheck.Err diag)
          (io.print-error
            (driver.compiler-driver-render-source-diagnostic
              (cdiag.compiler-diagnostic-list-first (deref diag))))
          (Err 1)]))
    (begin
      (io.print-error (tltest-package-integration-missing-main source))
      (Err 1))))

(define (tltest-package-integration-run
  [source : String]
  [target : String]
  [roots : cli_svec.Vec]
  [opt-level : i64]
  [backend-mode : compiler_backend.CompilerBackendMode]
  [decls : ast.AstDeclList]
  [paths : ast.AstDeclPathList]) : ResultTestPackageTotals
  (io.print-format
    "{}"
    (tltest-package-integration-line
      (owned_view.compiler-owned-shared-view source)))
  (if (tltest-decls-have-main? (owned_view.compiler-owned-shared-view decls))
    (let
      [status : i64
        (tltest-run-direct-with-entry
          source
          ""
          (ast.ast-program decls)
          paths
          roots
          target
          opt-level
          backend-mode
          false)]
      (if (= status 0)
        (Ok 1 1)
        (Err status)))
    (begin
      (io.print-error (tltest-package-integration-missing-main source))
      (Err 1))))

(define (tltest-package-run-integration-source
  [source : String]
  [target : String]
  [roots : cli_svec.Vec]
  [opt-level : i64]
  [backend-mode : compiler_backend.CompilerBackendMode]
  [test-mode : TestMode]
  [backend-target : compiler_backend.CompilerBackendTarget]
  [manifest-dir : String]
  [package-owner : String]
  [deps : compiler_load.CompilerPkgDeps]) : ResultTestPackageTotals
  (if (tltest-package-integration-selected? source)
    (if tltest-list-only
      (begin
        (io.print-format "{}" (str_cat.str-cat source "\n"))
        (Ok 1 1))
      (match (driver.compiler-driver-load-package-file-with-runtime-owned-cfg
        (owned_view.compiler-owned-shared-view source)
        (owned_view.compiler-owned-shared-view roots)
        manifest-dir
        package-owner
        deps
        true
        (tltest-cfgs backend-target))
        [(Ok decls paths _ _)
          (match test-mode
            [(Check)
              (tltest-package-integration-check
                source
                decls
                paths
                roots
                backend-target)]
            [(Run)
              (tltest-package-integration-run
                source
                target
                roots
                opt-level
                backend-mode
                decls
                paths)])]
        [(Err diag)
          (io.print-error
            (str_cat.str-cat "test: integration test source failed: " source))
          (io.print-error
            (driver.compiler-driver-render-source-diagnostic (deref diag)))
          (Err 1)]))
    (Ok 0 0)))

;; A test entry borrows its inputs from the caller and owns every temporary
;; compiler carrier. Serial selectors are a scoped compatibility bridge: they
;; are restored before the entry owner is destroyed, including failure exits.
(defstruct TlTestEntry
  (owner arena.Arena)
  (parent-load compiler_load.CompilerLoadSessionState)
  (parent-default compiler_load.CompilerLoadSessionState)
  (parent-job tc_core.TcJobState))

(define (tltest-entry-new) : TlTestEntry
  (let
    [owner : arena.Arena (arena.make)]
    [parent-load : compiler_load.CompilerLoadSessionState
      (compiler_load.compiler-load-serial-test-session-state)]
    [parent-default : compiler_load.CompilerLoadSessionState
      (compiler_load.compiler-load-global-array-element-shared-view
        compiler_load.compiler-load-default-session-state
        0)]
    [parent-job : tc_core.TcJobState (tc_core.tc-serial-job-state)]
    [entry-load : compiler_load.CompilerLoadSessionState
      (in-arena
        owner
        (compiler_load.compiler-load-standalone-session-state-new))]
    [entry-job : tc_core.TcJobState (in-arena owner (tc_core.tc-job-state-new))]
    [pools : ast.AstNodePoolContext
      (driver.compiler-driver-state-new-checked-lower-pools)]
    (compiler_load.compiler-load-default-session-state-set!
      (owned_view.compiler-owned-shared-view entry-load))
    (compiler_load.compiler-load-session-state-use! entry-load)
    (compiler_load.compiler-load-session-cache-enable!)
    (compiler_load.compiler-load-session-program-cache-disable!)
    (tc_core.tc-serial-job-state-set!
      (owned_view.compiler-owned-shared-view entry-job))
    (ast.ast-node-pool-context-install! pools)
    (TlTestEntry owner parent-load parent-default parent-job)))

(define (tltest-entry-finish [entry : TlTestEntry] [result : i64]) : i64
  (in-arena
    entry.owner
    (let
      [pools : ast.AstNodePoolContext
        (ast.ast-node-pool-context-capture-active)]
      ;; Reset walkers can inspect entry-owned values. Their replacement
      ;; empty carriers also belong here; no selector retains them below.
      (driver.compiler-driver-reset-file-state!)
      (compiler_load.compiler-load-session-state-dotted-path-cache-reset!
        (compiler_load.compiler-load-serial-test-session-state))
      (compiler_load.compiler-load-session-fresh-reset!)
      (tc_core.tc-job-state-retire-owned-storage! (tc_core.tc-serial-job-state))
      (driver.compiler-driver-state-destroy-uncommitted-pools! pools)))
  (tc_core.tc-serial-job-state-set! entry.parent-job)
  (compiler_load.compiler-load-default-session-state-set! entry.parent-default)
  (if (array-ref entry.parent-load.intern-state-ready 0)
    (compiler_load.compiler-load-session-state-use-with-intern-state!
      entry.parent-load
      (owned_view.compiler-owned-array-element-shared-view
        entry.parent-load.intern-state
        0))
    (compiler_load.compiler-load-session-state-use! entry.parent-load))
  (unsafe
    (arena.destroy entry.owner))
  result)

(define (tltest-package-run-integration-source-isolated-count
  [source : String]
  [target : String]
  [roots : cli_svec.Vec]
  [opt-level : i64]
  [backend-mode : compiler_backend.CompilerBackendMode]
  [test-mode : TestMode]
  [backend-target : compiler_backend.CompilerBackendTarget]
  [manifest-dir : String]
  [package-owner : String]
  [deps : compiler_load.CompilerPkgDeps]) : i64
  (let
    [entry : TlTestEntry (tltest-entry-new)]
    [entry-result : i64
      (in-arena
        entry.owner
        (driver.compiler-driver-reset-file-state!)
        (match (tltest-package-run-integration-source
          source
          target
          roots
          opt-level
          backend-mode
          test-mode
          backend-target
          manifest-dir
          package-owner
          deps)
          [(Err status) (- 0 status)]
          [(Failed _ tests _) (- 0 (+ tltest-failed-count-offset tests))]
          [(Ok _ tests) tests]))]
    (tltest-entry-finish entry entry-result)))

(define (tltest-package-run-source
  [source : String]
  [target : String]
  [roots : cli_svec.Vec]
  [opt-level : i64]
  [backend-mode : compiler_backend.CompilerBackendMode]
  [test-mode : TestMode]
  [backend-target : compiler_backend.CompilerBackendTarget]
  [manifest-dir : String]
  [package-owner : String]
  [deps : compiler_load.CompilerPkgDeps]) : ResultTestPackageTotals
  (if (tltest-source-has-inline-tests?
    (owned_view.compiler-owned-shared-view source))
    (let
      [legacy-roots : cli_svec.Vec (clone roots)]
      (match (driver.compiler-driver-load-package-file-with-runtime-owned-cfg
        (owned_view.compiler-owned-shared-view source)
        (owned_view.compiler-owned-shared-view legacy-roots)
        (owned_view.compiler-owned-shared-view manifest-dir)
        (owned_view.compiler-owned-shared-view package-owner)
        deps
        true
        (tltest-cfgs backend-target))
        [(Ok decls paths _ _)
          (let
            [owned-source : String
              (compiler_load.compiler-load-package-owned-path
                package-owner
                manifest-dir
                legacy-roots
                source)]
            (tltest-package-run-one
              owned-source
              target
              roots
              opt-level
              backend-mode
              test-mode
              backend-target
              decls
              paths))]
        [(Err diag)
          (io.print-error
            (str_cat.str-cat "test: package source failed: " source))
          (io.print-error
            (driver.compiler-driver-render-source-diagnostic (deref diag)))
          (Err 1)]))
    (Ok 0 0)))

(define (tltest-package-run-source-isolated-count
  [source : String]
  [target : String]
  [roots : cli_svec.Vec]
  [opt-level : i64]
  [backend-mode : compiler_backend.CompilerBackendMode]
  [test-mode : TestMode]
  [backend-target : compiler_backend.CompilerBackendTarget]
  [manifest-dir : String]
  [package-owner : String]
  [deps : compiler_load.CompilerPkgDeps]) : i64
  (let
    [entry : TlTestEntry (tltest-entry-new)]
    [entry-result : i64
      (in-arena
        entry.owner
        (driver.compiler-driver-reset-file-state!)
        (match (tltest-package-run-source
          source
          target
          roots
          opt-level
          backend-mode
          test-mode
          backend-target
          manifest-dir
          package-owner
          deps)
          [(Err status) (- 0 status)]
          [(Failed _ tests _) (- 0 (+ tltest-failed-count-offset tests))]
          [(Ok _ tests) tests]))]
    (tltest-entry-finish entry entry-result)))

(define (tltest-package-run-sources-from
  [sources : cli_svec.Vec]
  [index : i64]
  [tests-prefix : (& tests-prefix str)]
  [target : String]
  [roots : cli_svec.Vec]
  [opt-level : i64]
  [backend-mode : compiler_backend.CompilerBackendMode]
  [test-mode : TestMode]
  [backend-target : compiler_backend.CompilerBackendTarget]
  [manifest-dir : String]
  [package-owner : String]
  [deps : compiler_load.CompilerPkgDeps]
  [file-count : i64]
  [test-count : i64]
  [failed-file-count : i64]) : ResultTestPackageTotals
  (if (>= index (cli_svec.len (& sources)))
    (if (= failed-file-count 0)
      (Ok file-count test-count)
      (Failed file-count test-count failed-file-count))
    (let
      [source : String (cli_svec.get (& sources) index "")]
      (if (tltest-package-test-source? source tests-prefix)
        (tltest-package-run-sources-from
          sources
          (+ index 1)
          tests-prefix
          target
          roots
          opt-level
          backend-mode
          test-mode
          backend-target
          manifest-dir
          package-owner
          deps
          file-count
          test-count
          failed-file-count)
        (let
          [source-tests : i64
            (tltest-package-run-source-isolated-count
              source
              (owned_view.compiler-owned-shared-view target)
              (owned_view.compiler-owned-shared-view roots)
              opt-level
              backend-mode
              test-mode
              backend-target
              (owned_view.compiler-owned-shared-view manifest-dir)
              (owned_view.compiler-owned-shared-view package-owner)
              (owned_view.compiler-owned-shared-view deps))]
          (if (<= source-tests (- 0 tltest-failed-count-offset))
            (let
              [failed-tests : i64
                (- (- 0 source-tests) tltest-failed-count-offset)]
              (tltest-package-run-sources-from
                sources
                (+ index 1)
                tests-prefix
                target
                roots
                opt-level
                backend-mode
                test-mode
                backend-target
                manifest-dir
                package-owner
                deps
                (+ file-count 1)
                (+ test-count failed-tests)
                (+ failed-file-count 1)))
            (if (< source-tests 0)
              (Err (- 0 source-tests))
              (tltest-package-run-sources-from
                sources
                (+ index 1)
                tests-prefix
                target
                roots
                opt-level
                backend-mode
                test-mode
                backend-target
                manifest-dir
                package-owner
                deps
                (if (= source-tests 0)
                  file-count
                  (+ file-count 1))
                (+ test-count source-tests)
                failed-file-count))))))))

(define (tltest-package-run-sources
  [sources : cli_svec.Vec]
  [tests-prefix : (& tests-prefix str)]
  [target : String]
  [roots : cli_svec.Vec]
  [opt-level : i64]
  [backend-mode : compiler_backend.CompilerBackendMode]
  [test-mode : TestMode]
  [backend-target : compiler_backend.CompilerBackendTarget]
  [manifest-dir : String]
  [package-owner : String]
  [deps : compiler_load.CompilerPkgDeps]
  [file-count : i64]
  [test-count : i64]) : ResultTestPackageTotals
  (tltest-package-run-sources-from
    sources
    0
    tests-prefix
    target
    roots
    opt-level
    backend-mode
    test-mode
    backend-target
    manifest-dir
    package-owner
    deps
    file-count
    test-count
    0))

(define (tltest-package-run-integration-sources-from
  [sources : cli_svec.Vec]
  [index : i64]
  [tests-prefix : String]
  [target : String]
  [roots : cli_svec.Vec]
  [opt-level : i64]
  [backend-mode : compiler_backend.CompilerBackendMode]
  [test-mode : TestMode]
  [backend-target : compiler_backend.CompilerBackendTarget]
  [manifest-dir : String]
  [package-owner : String]
  [deps : compiler_load.CompilerPkgDeps]
  [file-count : i64]
  [test-count : i64]
  [failed-file-count : i64]) : ResultTestPackageTotals
  (if (>= index (cli_svec.len (& sources)))
    (if (= failed-file-count 0)
      (Ok file-count test-count)
      (Failed file-count test-count failed-file-count))
    (let
      [source : String (cli_svec.get (& sources) index "")]
      (if (tltest-package-integration-source?
        (owned_view.compiler-owned-shared-view source)
        (owned_view.compiler-owned-shared-view tests-prefix))
        (let
          [source-tests : i64
            (tltest-package-run-integration-source-isolated-count
              source
              (owned_view.compiler-owned-shared-view target)
              (owned_view.compiler-owned-shared-view roots)
              opt-level
              backend-mode
              test-mode
              backend-target
              (owned_view.compiler-owned-shared-view manifest-dir)
              (owned_view.compiler-owned-shared-view package-owner)
              (owned_view.compiler-owned-shared-view deps))]
          (if (<= source-tests (- 0 tltest-failed-count-offset))
            (let
              [failed-tests : i64
                (- (- 0 source-tests) tltest-failed-count-offset)]
              (tltest-package-run-integration-sources-from
                sources
                (+ index 1)
                tests-prefix
                target
                roots
                opt-level
                backend-mode
                test-mode
                backend-target
                manifest-dir
                package-owner
                deps
                (+ file-count 1)
                (+ test-count failed-tests)
                (+ failed-file-count 1)))
            (if (< source-tests 0)
              (Err (- 0 source-tests))
              (tltest-package-run-integration-sources-from
                sources
                (+ index 1)
                tests-prefix
                target
                roots
                opt-level
                backend-mode
                test-mode
                backend-target
                manifest-dir
                package-owner
                deps
                (if (= source-tests 0)
                  file-count
                  (+ file-count 1))
                (+ test-count source-tests)
                failed-file-count))))
        (tltest-package-run-integration-sources-from
          sources
          (+ index 1)
          tests-prefix
          target
          roots
          opt-level
          backend-mode
          test-mode
          backend-target
          manifest-dir
          package-owner
          deps
          file-count
          test-count
          failed-file-count)))))

(define (tltest-package-run-integration-sources
  [sources : cli_svec.Vec]
  [tests-prefix : String]
  [target : String]
  [roots : cli_svec.Vec]
  [opt-level : i64]
  [backend-mode : compiler_backend.CompilerBackendMode]
  [test-mode : TestMode]
  [backend-target : compiler_backend.CompilerBackendTarget]
  [manifest-dir : String]
  [package-owner : String]
  [deps : compiler_load.CompilerPkgDeps]
  [file-count : i64]
  [test-count : i64]) : ResultTestPackageTotals
  (let
    [selected-sources : cli_svec.Vec
      (tltest-package-selected-integration-sources
        sources
        (owned_view.compiler-owned-shared-view tests-prefix))]
    (tltest-package-run-integration-sources-from
      selected-sources
      0
      tests-prefix
      target
      roots
      opt-level
      backend-mode
      test-mode
      backend-target
      manifest-dir
      package-owner
      deps
      file-count
      test-count
      0)))

(define (tltest-package-failed-summary-line
  [file-count : i64]
  [test-count : i64]
  [failed-file-count : i64]) : String
  (str_cat.str-cat
    "TypeLisp package tests failed: "
    (string.int->string failed-file-count)
    " of "
    (string.int->string file-count)
    " file(s) failed; "
    (string.int->string test-count)
    " test(s)\n"))

(define (tltest-package-finish
  [test-mode : TestMode]
  [file-count : i64]
  [test-count : i64]
  [failed-file-count : i64]) : i64
  (if (= failed-file-count 0)
    (begin
      (io.print-format
        "{}"
        (tltest-package-summary-line test-mode file-count test-count))
      0)
    (begin
      (io.print-format
        "{}"
        (tltest-package-failed-summary-line
          file-count
          test-count
          failed-file-count))
      1)))

(define (tltest-run-package-integrations
  [integration-sources : cli_svec.Vec]
  [tests-prefix : String]
  [target : String]
  [roots : cli_svec.Vec]
  [opt-level : i64]
  [backend-mode : compiler_backend.CompilerBackendMode]
  [test-mode : TestMode]
  [backend-target : compiler_backend.CompilerBackendTarget]
  [manifest-dir : String]
  [package-owner : String]
  [deps : compiler_load.CompilerPkgDeps]
  [inline-file-count : i64]
  [inline-test-count : i64]
  [inline-failed-file-count : i64]) : i64
  (match (tltest-package-run-integration-sources
    integration-sources
    tests-prefix
    target
    roots
    opt-level
    backend-mode
    test-mode
    backend-target
    manifest-dir
    package-owner
    deps
    0
    0)
    [(Err status) status]
    [(Failed
        integration-file-count
        integration-test-count
        integration-failed-file-count)
      (tltest-package-finish
        test-mode
        (+ inline-file-count integration-file-count)
        (+ inline-test-count integration-test-count)
        (+ inline-failed-file-count integration-failed-file-count))]
    [(Ok integration-file-count integration-test-count)
      (tltest-package-finish
        test-mode
        (+ inline-file-count integration-file-count)
        (+ inline-test-count integration-test-count)
        inline-failed-file-count)]))

(define (tltest-run-package
  [manifest-path : String]
  [has-manifest : bool]
  [target : String]
  [roots : cli_svec.Vec]
  [opt-level : i64]
  [backend-mode : compiler_backend.CompilerBackendMode]
  [test-mode : TestMode]) : i64
  (match (build_run_core.source-tool-target
    (owned_view.compiler-owned-shared-view target))
    [(Err _)
      (io.print-error (tltest-unknown-target target))
      1]
    [(Ok backend-target)
      (match (package_source_core.package-source-discover-for
        "test"
        manifest-path
        has-manifest)
        [(Err message)
          (io.print-error message)
          1]
        [(Ok source-set)
          (let
            [manifest : compiler_load.CompilerPkgManifest
              (owned_view.compiler-owned-shared-view source-set.manifest)]
            [manifest-dir : String
              (owned_view.compiler-owned-shared-view source-set.manifest-dir)]
            [package-owner : String manifest.name]
            [tests-prefix : String
              (tltest-package-tests-prefix
                (owned_view.compiler-owned-shared-view manifest-dir))]
            (match (package_source_core.package-source-discover-tests-for
              "test"
              (owned_view.compiler-owned-shared-view source-set))
              [(Err message)
                (io.print-error message)
                1]
              [(Ok integration-sources)
                (match (tltest-package-run-sources
                  source-set.sources
                  tests-prefix
                  (owned_view.compiler-owned-shared-view target)
                  (owned_view.compiler-owned-shared-view roots)
                  opt-level
                  backend-mode
                  test-mode
                  backend-target
                  (owned_view.compiler-owned-shared-view manifest-dir)
                  (owned_view.compiler-owned-shared-view package-owner)
                  (owned_view.compiler-owned-shared-view manifest.deps)
                  0
                  0)
                  [(Err status) status]
                  [(Failed
                      inline-file-count
                      inline-test-count
                      inline-failed-file-count)
                    (tltest-run-package-integrations
                      integration-sources
                      tests-prefix
                      target
                      roots
                      opt-level
                      backend-mode
                      test-mode
                      backend-target
                      manifest-dir
                      package-owner
                      manifest.deps
                      inline-file-count
                      inline-test-count
                      inline-failed-file-count)]
                  [(Ok inline-file-count inline-test-count)
                    (tltest-run-package-integrations
                      integration-sources
                      tests-prefix
                      target
                      roots
                      opt-level
                      backend-mode
                      test-mode
                      backend-target
                      manifest-dir
                      package-owner
                      manifest.deps
                      inline-file-count
                      inline-test-count
                      0)])]))])]))

(define (tltest-check-file-loaded
  [source : String]
  [decls : ast.AstDeclList]
  [paths : ast.AstDeclPathList]
  [backend-target : compiler_backend.CompilerBackendTarget]
  [roots : cli_svec.Vec]) : ResultTestFileCheck
  (match (tltest-build-harness
    (owned_view.compiler-owned-shared-view source)
    (owned_view.compiler-owned-shared-view decls)
    (owned_view.compiler-owned-shared-view paths))
    [(Harness program harness-paths count)
      (io.print-format
        "{}"
        (tltest-package-source-line
          (owned_view.compiler-owned-shared-view source)
          count))
      (if tltest-list-only
        (Ok (tltest-list-loaded source decls paths))
        (let
          [status : i64
            (if (= count 0)
              (tltest-no-tests-check decls paths roots backend-target)
              (tltest-check-only
                program
                harness-paths
                count
                backend-target
                roots))]
          (if (= status 0)
            (Ok count)
            (Err status))))]))

(define (tltest-check-file-source
  [source : String]
  [roots : cli_svec.Vec]
  [backend-target : compiler_backend.CompilerBackendTarget]) : ResultTestFileCheck
  (match (driver.compiler-driver-load-file-with-runtime
    (owned_view.compiler-owned-shared-view source)
    (owned_view.compiler-owned-shared-view roots)
    (tltest-cfgs backend-target))
    [(Ok decls paths _ _)
      (tltest-check-file-loaded source decls paths backend-target roots)]
    [(Err diag)
      (io.print-error
        (driver.compiler-driver-render-source-diagnostic (deref diag)))
      (Err 1)]))

(define (tltest-run-file-loaded
  [source : String]
  [target : String]
  [roots : cli_svec.Vec]
  [opt-level : i64]
  [backend-mode : compiler_backend.CompilerBackendMode]
  [decls : ast.AstDeclList]
  [paths : ast.AstDeclPathList]) : ResultTestFileCheck
  (match (tltest-build-harness
    (owned_view.compiler-owned-shared-view source)
    decls
    paths)
    [(Harness program harness-paths count)
      (io.print-format
        "{}"
        (tltest-package-source-line
          (owned_view.compiler-owned-shared-view source)
          count))
      (let
        [status : i64
          (if (= count 0)
            (tltest-no-tests-run
              source
              target
              program
              harness-paths
              roots
              opt-level
              backend-mode)
            (tltest-run-direct
              source
              program
              harness-paths
              roots
              target
              opt-level
              backend-mode))]
        (if (= status 0)
          (Ok count)
          (if (and (> count 0) (= status 1))
            (Failed count)
            (Err status))))]))

(define (tltest-run-file-source
  [source : String]
  [target : String]
  [roots : cli_svec.Vec]
  [opt-level : i64]
  [backend-mode : compiler_backend.CompilerBackendMode]
  [backend-target : compiler_backend.CompilerBackendTarget]) : ResultTestFileCheck
  (match (driver.compiler-driver-load-file-with-runtime
    (owned_view.compiler-owned-shared-view source)
    (owned_view.compiler-owned-shared-view roots)
    (tltest-cfgs backend-target))
    [(Ok decls paths _ _)
      (tltest-run-file-loaded
        source
        target
        roots
        opt-level
        backend-mode
        decls
        paths)]
    [(Err diag)
      (io.print-error
        (driver.compiler-driver-render-source-diagnostic (deref diag)))
      (Err 1)]))

(define (tltest-batch-summary-line [file-count : i64] [test-count : i64]) : String
  (if tltest-list-only
    (str_cat.str-cat
      "TypeLisp test batch listed: "
      (string.int->string test-count)
      " test(s) in "
      (string.int->string file-count)
      " file(s)\n")
    (str_cat.str-cat
      "TypeLisp test batch typecheck passed: "
      (string.int->string test-count)
      " test(s) in "
      (string.int->string file-count)
      " file(s)\n")))

(define (tltest-batch-run-summary-line
  [file-count : i64]
  [test-count : i64]
  [failed-file-count : i64]) : String
  (if (= failed-file-count 0)
    (str_cat.str-cat
      "TypeLisp test batch passed: "
      (string.int->string test-count)
      " test(s) in "
      (string.int->string file-count)
      " file(s)\n")
    (str_cat.str-cat
      "TypeLisp test batch failed: "
      (string.int->string failed-file-count)
      " of "
      (string.int->string file-count)
      " file(s) failed; "
      (string.int->string test-count)
      " test(s)\n")))

(define (tltest-run-batch-check-path
  [source : String]
  [roots : cli_svec.Vec]
  [backend-target : compiler_backend.CompilerBackendTarget]) : i64
  (let
    [entry : TlTestEntry (tltest-entry-new)]
    [entry-result : i64
      (in-arena
        entry.owner
        (match (tltest-check-file-source source roots backend-target)
          [(Err status) (- 0 status)]
          [(Failed count) (- 0 (+ tltest-failed-count-offset count))]
          [(Ok count) count]))]
    (tltest-entry-finish entry entry-result)))

(define (tltest-run-batch-check-paths-from
  [paths : cli_svec.Vec]
  [index : i64]
  [roots : cli_svec.Vec]
  [backend-target : compiler_backend.CompilerBackendTarget]
  [file-count : i64]
  [test-count : i64]) : i64
  (let
    [count : i64 (cli_svec.len (& paths))]
    [cursor : i64 index]
    [files : i64 file-count]
    [tests : i64 test-count]
    [status : i64 0]
    (while (and (= status 0) (< cursor count))
      (let
        [source : String (cli_svec.get (& paths) cursor "")]
        ;; Match compile --batch: isolate each entry in a destroyable scratch
        ;; arena. Lexical arena rewind keeps overflow chunks retired until the
        ;; owning arena is destroyed, so destroying the entry arena is
        ;; required for long one-process batches to stay bounded.
        [entry-result : i64
          (tltest-run-batch-check-path
            (owned_view.compiler-owned-shared-view source)
            (owned_view.compiler-owned-shared-view roots)
            backend-target)]
        (if (< entry-result 0)
          (begin
            (io.print-error
              (str_cat.str-cat "test: batch source failed: " source))
            (io.print-error "\n")
            (set! status (- 0 entry-result)))
          (begin
            (set! files (+ files 1))
            (set! tests (+ tests entry-result))
            (set! cursor (+ cursor 1))))))
    (if (= status 0)
      (begin
        (io.print-format "{}" (tltest-batch-summary-line files tests))
        0)
      status)))

(define (tltest-run-batch-check-paths
  [paths : cli_svec.Vec]
  [roots : cli_svec.Vec]
  [backend-target : compiler_backend.CompilerBackendTarget]
  [file-count : i64]
  [test-count : i64]) : i64
  (tltest-run-batch-check-paths-from
    paths
    0
    roots
    backend-target
    file-count
    test-count))

(define (tltest-run-batch-check
  [paths : cli_svec.Vec]
  [target : String]
  [roots : cli_svec.Vec]) : i64
  (compiler_load.compiler-load-session-cache-enable!)
  (compiler_load.compiler-load-session-program-cache-disable!)
  (driver.compiler-driver-reset-file-state!)
  (match (build_run_core.source-tool-target
    (owned_view.compiler-owned-shared-view target))
    [(Err _)
      (io.print-error (tltest-unknown-target target))
      1]
    [(Ok backend-target)
      (let
        [status : i64
          (begin
            (if tltest-prefix-cache-stats
              (tc_core.tc-prefix-snapshot-cache-clear!)
              unit)
            (tltest-run-batch-check-paths paths roots backend-target 0 0))]
        (if tltest-prefix-cache-stats
          (tc_core.tc-prefix-snapshot-cache-print-stats "test-check-batch")
          unit)
        status)]))

(define (tltest-run-batch-run-path
  [source : String]
  [target : String]
  [roots : cli_svec.Vec]
  [opt-level : i64]
  [backend-mode : compiler_backend.CompilerBackendMode]
  [backend-target : compiler_backend.CompilerBackendTarget]) : i64
  ;; Keep every entry's loader pools, harness AST, lowered IR, backend scratch,
  ;; and captured child output inside one destroyable arena. Only the scalar
  ;; test count crosses the boundary.
  (let
    [entry : TlTestEntry (tltest-entry-new)]
    [entry-result : i64
      (in-arena
        entry.owner
        (match (tltest-run-file-source
          source
          target
          roots
          opt-level
          backend-mode
          backend-target)
          [(Err status) (- 0 status)]
          [(Failed count) (- 0 (+ tltest-failed-count-offset count))]
          [(Ok count) count]))]
    (tltest-entry-finish entry entry-result)))

(define (tltest-run-batch-run-paths
  [paths : cli_svec.Vec]
  [target : String]
  [roots : cli_svec.Vec]
  [opt-level : i64]
  [backend-mode : compiler_backend.CompilerBackendMode]
  [backend-target : compiler_backend.CompilerBackendTarget]) : i64
  (let
    [count : i64 (cli_svec.len (& paths))]
    [cursor : i64 0]
    [files : i64 0]
    [tests : i64 0]
    [failed-files : i64 0]
    [fatal-status : i64 0]
    (while (and (= fatal-status 0) (< cursor count))
      (let
        [source : String (cli_svec.get (& paths) cursor "")]
        [entry-result : i64
          (tltest-run-batch-run-path
            (owned_view.compiler-owned-shared-view source)
            (owned_view.compiler-owned-shared-view target)
            (owned_view.compiler-owned-shared-view roots)
            opt-level
            backend-mode
            backend-target)]
        (if (<= entry-result (- 0 tltest-failed-count-offset))
          (begin
            (set! files (+ files 1))
            (set!
              tests
              (+ tests (- (- 0 entry-result) tltest-failed-count-offset)))
            (set! failed-files (+ failed-files 1))
            (set! cursor (+ cursor 1)))
          (if (< entry-result 0)
            (begin
              (io.print-error
                (str_cat.str-cat "\ntest: batch source failed: " source))
              (io.print-error "\n")
              (set! fatal-status (- 0 entry-result)))
            (begin
              (set! files (+ files 1))
              (set! tests (+ tests entry-result))
              (set! cursor (+ cursor 1)))))))
    (if (= fatal-status 0)
      (begin
        (io.print-format
          "{}"
          (tltest-batch-run-summary-line files tests failed-files))
        (if (= failed-files 0)
          0
          1))
      fatal-status)))

(define (tltest-run-batch-run
  [paths : cli_svec.Vec]
  [target : String]
  [roots : cli_svec.Vec]
  [opt-level : i64]
  [backend-mode : compiler_backend.CompilerBackendMode]) : i64
  (compiler_load.compiler-load-session-cache-enable!)
  (compiler_load.compiler-load-session-program-cache-disable!)
  (driver.compiler-driver-reset-file-state!)
  (match (build_run_core.source-tool-target
    (owned_view.compiler-owned-shared-view target))
    [(Err _)
      (io.print-error (tltest-unknown-target target))
      1]
    [(Ok backend-target)
      (if tltest-prefix-cache-stats
        (tc_core.tc-prefix-snapshot-cache-clear!)
        unit)
      (let
        [status : i64
          (tltest-run-batch-run-paths
            paths
            target
            roots
            opt-level
            backend-mode
            backend-target)]
        (if tltest-prefix-cache-stats
          (tc_core.tc-prefix-snapshot-cache-print-stats "test-run-batch")
          unit)
        status)]))

(define (tltest-prepare-shuffle!) : bool
  (if tltest-shuffle
    (begin
      (if tltest-seed-set
        unit
        (match (random.system-seed)
          [(OkSystemSeed seed)
            (set! tltest-seed (cast seed : u64))
            (set! tltest-seed-set true)]
          [(ErrSystemSeed error)
            (match error
              [(RandomSystemSeedUnavailable message)
                (let
                  [rendered : String (str_cat.str-cat "test: " message "\n")]
                  (io.print-error (& rendered)))])
            (return false)]))
      (io.print-format
        "{}"
        (str_cat.str-cat
          "TypeLisp test shuffle seed: "
          (tltest-u64-decimal tltest-seed)
          "\n"))
      true)
    true))

(define (tltest-run-config-ready [config : TestConfig]) : i64
  (match config
    [(File source target backend-mode roots opt-level test-mode)
      (match (build_run_core.source-tool-target
        (owned_view.compiler-owned-shared-view target))
        [(Err _)
          (io.print-error (tltest-unknown-target target))
          1]
        [(Ok backend-target)
          (match (driver.compiler-driver-load-file-with-runtime
            (owned_view.compiler-owned-shared-view source)
            (owned_view.compiler-owned-shared-view roots)
            (tltest-cfgs backend-target))
            [(Ok decls paths _ _)
              (if tltest-list-only
                (let
                  [count : i64 (tltest-list-loaded source decls paths)]
                  (io.print-format "{}" (tltest-list-summary-line count))
                  0)
                (match (tltest-build-harness
                  (owned_view.compiler-owned-shared-view source)
                  (owned_view.compiler-owned-shared-view decls)
                  (owned_view.compiler-owned-shared-view paths))
                  [(Harness program harness-paths count)
                    (if (= count 0)
                      (match test-mode
                        [(Check)
                          (tltest-no-tests-check
                            decls
                            paths
                            roots
                            backend-target)]
                        [(Run)
                          (tltest-no-tests-run
                            source
                            target
                            program
                            harness-paths
                            roots
                            opt-level
                            backend-mode)])
                      (match test-mode
                        [(Check)
                          (tltest-check-only
                            program
                            harness-paths
                            count
                            backend-target
                            roots)]
                        [(Run)
                          (tltest-run-direct
                            source
                            program
                            harness-paths
                            roots
                            target
                            opt-level
                            backend-mode)]))]))]
            [(Err diag)
              (io.print-error
                (driver.compiler-driver-render-source-diagnostic (deref diag)))
              1])])]
    [(Batch paths target backend-mode roots opt-level test-mode)
      (if tltest-list-only
        (tltest-run-batch-check paths target roots)
        (match test-mode
          [(Check) (tltest-run-batch-check paths target roots)]
          [(Run)
            (tltest-run-batch-run paths target roots opt-level backend-mode)]))]
    [(Package
        manifest-path
        has-manifest
        target
        backend-mode
        roots
        opt-level
        test-mode)
      (tltest-run-package
        manifest-path
        has-manifest
        target
        roots
        opt-level
        backend-mode
        test-mode)]))

;; Host-ISA policy for executing SIMD harnesses: the same CPUID-plus-OS-state
;; contract the SPMD gates use (`stdlib.cpu`; AVX-512 means F+BW+DQ). The
;; capabilities are parameters so the refusal is testable on every host.
(define (tltest-host-isa-refusal
  [backend-mode : compiler_backend.CompilerBackendMode]
  [runs-avx2 : bool]
  [runs-avx512 : bool]) : TestMaybeString
  (match backend-mode
    [(Scalar) (No)]
    [(Avx2)
      (if runs-avx2
        (No)
        (Some
          "test: backend mode avx2 cannot run on this host: AVX2 with OS ymm state is required; use --check, --list, or another --backend-mode"))]
    [(Avx512)
      (if runs-avx512
        (No)
        (Some
          "test: backend mode avx512 cannot run on this host: AVX-512 F, BW, and DQ with OS zmm state are required; use --check, --list, or another --backend-mode"))]))

;; `--check` and `--list` never execute a harness, so they accept every mode
;; on every host and never probe the CPU.
(define (tltest-backend-mode-executes?
  [backend-mode : compiler_backend.CompilerBackendMode]
  [test-mode : TestMode]
  [list-only : bool]) : bool
  (and
    (not (compiler_backend.compiler-backend-mode-scalar? backend-mode))
    (not list-only)
    (not (tltest-check-mode? test-mode))))

;; A run is refused once per process, before any compilation, instead of
;; trapping on the first vector instruction of some harness.
(define (tltest-host-isa-permits?
  [backend-mode : compiler_backend.CompilerBackendMode]
  [test-mode : TestMode]) : bool
  (if (tltest-backend-mode-executes? backend-mode test-mode tltest-list-only)
    (match (tltest-host-isa-refusal
      backend-mode
      (cpu.runs-avx2?)
      (cpu.runs-avx512?))
      [(No) true]
      [(Some message)
        (io.print-error message)
        false])
    true))

(define (tltest-config-host-isa-permits? [config : TestConfig]) : bool
  (match config
    [(File _ _ backend-mode _ _ test-mode)
      (tltest-host-isa-permits? backend-mode test-mode)]
    [(Batch _ _ backend-mode _ _ test-mode)
      (tltest-host-isa-permits? backend-mode test-mode)]
    [(Package _ _ _ backend-mode _ _ test-mode)
      (tltest-host-isa-permits? backend-mode test-mode)]))

(define (tltest-run-config [config : TestConfig]) : i64
  (if (tltest-config-host-isa-permits?
    (owned_view.compiler-owned-shared-view config))
    (if (tltest-prepare-shuffle!)
      (tltest-run-config-ready config)
      1)
    1))

;; Run the `test` command over arguments starting at `start`.
(define (tltest-run-from [start : i64] [count : i64]) : i64
  (match (tltest-config-from start count)
    [(Ok config) (tltest-run-config config)]
    [(Err message)
      (io.print-error message)
      1]))