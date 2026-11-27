;; test_cli_core.tl - Selfhost test command logic.
;;
;; Discovers source-owned `(test name body...)` declarations through the
;; selfhost loader, lowers them into private unit-returning functions plus a
;; generated `main`, then assembles, links, and runs that generated harness
;; directly. Imported files provide runtime declarations but do not contribute
;; their own tests to this source's harness. Normal compile paths ignore
;; `AstDecl.Test`.
(import stdlib.clone as clone_gen)
(import compiler_backend_program_facts as be_facts)
(import compiler_backend_state as be_state)
(import stdlib.iterator)
(import compiler_owned_view as owned_view)
(import stdlib.arena)
(import stdlib.byte_buf)
(import stdlib.cpu)
(import stdlib.fs)
(import stdlib.io)
(import stdlib.process)
(import stdlib.random)
(import stdlib.hashmap)
(import (hashmap.hashmap i64 i64) as tltest_name_map)
(import stdlib.vector)
(import (vector.vector String) as cli_svec)
(import cli_option_core as cli_option)
(import compiler_ir_types as ir)
(import compiler_target_cfg_core as target_cfg)
(import build_run_core)
(import compiler_ast_types as ast)
(import compiler_builtin_ids as cbi)
(import compiler_check_core)
(import compiler_diagnostic as cdiag)
(import compiler_driver_core as driver)
(import tli_cli_core as tli_cli)
(import compiler_intern as ci)
(import compiler_intern_state as cis)
(import compiler_cfg_core as cfg_core)
(import compiler_load)
(import compiler_dependency_tlci)
(import compiler_lower as lower)
(import package_source_core)
(import compiler_profile_state as profile_state)
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
  (File String String be_state.CompilerBackendMode cli_svec.Vec i64 TestMode)
  (Batch
    cli_svec.Vec
    String
    be_state.CompilerBackendMode
    cli_svec.Vec
    i64
    TestMode)
  (Package
    String
    bool
    String
    be_state.CompilerBackendMode
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

(clone_gen.gen-clone InlineTestSelection)

(defenum InlineTest
  (Case String String i64 i64 i64 i64 String i64 i64 InlineTestSelection))

(clone_gen.gen-clone InlineTest)

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
(define tltest-combined : bool
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

(define (tltest-user-cfg-reset!) : unit
  (set! tltest-user-cfg-slots (cli_svec.new)))

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
      (+= index 1))
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
        (-= start 1)
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
      (Ok (tltest-batch-paths-from-text (byte_buf.to-string contents)))]
    [(ErrIoBytes error)
      (Err
        (str_cat.str-cat
          "test: failed to read --batch list file: "
          (io.error-message error)))]))

(define (tltest-combined-config-error
  [combined : bool]
  [has-batch : bool]
  [list-only : bool]
  [test-mode : TestMode]) : TestMaybeString
  (if (not combined)
    (No)
    (cond
      [(not has-batch) (Some "test: --combined requires --batch")]
      [list-only (Some "test: --combined cannot be combined with --list")]
      [(tltest-check-mode? test-mode)
        (Some "test: --combined cannot be combined with --check")]
      [else (No)])))

(define (tltest-config-finish
  [source : String]
  [has-source : bool]
  [manifest-path : String]
  [has-manifest : bool]
  [target : String]
  [mode : be_state.CompilerBackendMode]
  [roots : cli_svec.Vec]
  [opt-level : i64]
  [test-mode : TestMode]
  [batch-list : TestMaybeString]) : ResultTestConfig
  (if (and tltest-seed-set (not tltest-shuffle))
    (Err "test: --seed requires --shuffle")
    (match batch-list
      [(Some list-path)
        (match (tltest-combined-config-error
          tltest-combined
          true
          tltest-list-only
          test-mode)
          [(Some message) (Err message)]
          [(No)
            (cond
              [(and tltest-list-only tltest-prefix-cache-stats)
                (Err
                  "test: --prefix-cache-stats cannot be combined with --list")]
              [has-manifest
                (Err "test: cannot combine --batch with --manifest-path")]
              [has-source (Err "test: cannot combine input paths with --batch")]
              [else
                (let
                  [paths (try (tltest-batch-paths list-path))]
                  (if (cli_svec.is-empty? (& paths))
                    (Err "test: --batch list is empty")
                    (Ok (Batch paths target mode roots opt-level test-mode))))])])]
      [(No)
        (if tltest-prefix-cache-stats
          (Err "test: --prefix-cache-stats requires --batch")
          (match (tltest-combined-config-error
            tltest-combined
            false
            tltest-list-only
            test-mode)
            [(Some message) (Err message)]
            [(No)
              (if has-source
                (if has-manifest
                  (Err "test: cannot combine source path with --manifest-path")
                  (let
                    [source-roots : cli_svec.Vec
                      (tltest-source-roots (& source) roots)]
                    (Ok
                      (File source target mode source-roots opt-level test-mode))))
                (Ok
                  (Package
                    manifest-path
                    has-manifest
                    target
                    mode
                    roots
                    opt-level
                    test-mode)))]))])))

;; Testing a module of the implicit prelude reads the prelude from that file
;; rather than the test-blanked embedded copy (#8813).
(define (tltest-source-roots [source : (& source str)] [roots : cli_svec.Vec]) : cli_svec.Vec
  (compiler_load.compiler-load-roots-with-implicit-prelude-source source roots))

(define (tltest-check-mode? [mode : TestMode]) : bool
  (match mode
    [(Check) true]
    [(Run) false]))

;; Parse the `test` config from arguments starting at `start` (the index of the
;; first argument after any subcommand name). `count` is `(arg-count)`.
(define (tltest-config-from [start : i64] [count : i64]) : ResultTestConfig
  (let
    [options : cli_option.CliCompileOptions (cli_option.cli-compile-options)]
    [args : cli_option.CliArgs
      (cli_option.cli-args
        "test"
        (str_cat.str-cat
          "--stdlib-root <dir> --cfg <name> --target <target> --debug|-g|--backtrace --opt-level <0|1|2|s> -Os
           --check --list --filter <substring> --exact <name> --include-ignored
           --include-slow --shuffle --seed <u64> --backend-mode <mode>
           --manifest-path <file> --batch <file> --combined --prefix-cache-stats "
          (tli_cli.tli-sysroot-cli-options))
        start
        count)]
    [sysroot : tli_cli.TliSysrootOptions (tli_cli.tli-sysroot-options)]
    [source : String ""]
    [has-source : bool false]
    [manifest-path : String ""]
    [has-manifest : bool false]
    [test-mode : TestMode Run]
    [batch-list : TestMaybeString (No)]
    (tli_cli.tli-reset-active-sysroot-options!)
    (set! tltest-prefix-cache-stats false)
    (set! tltest-combined false)
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
        [(tli_cli.tli-sysroot-option! (&mut sysroot) (&mut args)) unit]
        [(cli_option.cli-compile-option! (&mut options) (&mut args)) unit]
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
        [(string.eq args.name "--combined")
          (if tltest-combined
            (cli_option.cli-args-fail! (&mut args) "test: duplicate --combined")
            (set! tltest-combined true))]
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
    (set! tltest-user-cfg-slots options.cfgs)
    (unless
      args.failed
      (ir.compiler-debug-info-set-enabled! options.debug)
      (tli_cli.tli-set-active-sysroot-options! (& sysroot)))
    (if args.failed
      (Err args.error)
      (tltest-config-finish
        source
        has-source
        manifest-path
        has-manifest
        (cli_option.cli-option-target-name options.target)
        (build_run_core.source-tool-backend-mode
          (cli_option.cli-compile-options-backend-mode
            options.backend-mode
            options.has-backend-mode
            options.opt-level))
        options.stdlib-roots
        options.opt-level
        test-mode
        batch-list))))

(define (tltest-main-decl? [decl : (& ast.AstDecl)]) : bool
  (match decl
    [(or (Def _ name _ _) (DefFn _ name _ _ _ _)) (= name (tltest-main-id))]
    [(Unsafe inner-box) (tltest-main-decl? inner-box)]
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
              [saved : InlineTest
                (clone-inline-test (& (array-ref tests index)))]
              (set!
                (array-ref tests index)
                (clone-inline-test (& (array-ref tests other))))
              (set! (array-ref tests other) saved)))
          (-= index 1))))
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
          [saved : String (string.copy (& (cli_svec.get items index "")))]
          (set! state next-state)
          (cli_svec.set-ref!
            items
            index
            (string.copy (& (cli_svec.get items other ""))))
          (cli_svec.set-ref! items other saved)
          (-= index 1))))
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
            [decl-prov-id : i64
              (ast.ast-decl-path-list-provenance-id
                (& cur-paths)
                0
                decl-owner-id)]
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
                      (ci.intern-generated-name (& private-name))]
                    (__tl_array-push!
                      test-items
                      (Case
                        (ci.intern-str name)
                        decl-path
                        current-module
                        decl-prov-id
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
                (ast.ast-decl-path-list-push-with-owner-and-provenance-id
                  (&mut runtime-paths-out)
                  decl-path
                  decl-owner-id
                  decl-prov-id)]
              [(Import decl-meta _)
                (ast.ast-decl-list-push (&mut runtime-decls-out) decl)
                (ast.ast-decl-path-list-push-with-owner-and-provenance-id
                  (&mut runtime-paths-out)
                  decl-path
                  decl-owner-id
                  decl-prov-id)]
              [(or (IncludeStr _ _) (IncludeStrComptime _ _)
                   (IncludeStrLzss _ _) (IncludeBin _ _))
                unit]
              [_
                (unless
                  (tltest-main-decl? (& decl))
                  (ast.ast-decl-list-push (&mut runtime-decls-out) decl)
                  (ast.ast-decl-path-list-push-with-owner-and-provenance-id
                    (&mut runtime-paths-out)
                    decl-path
                    decl-owner-id
                    decl-prov-id))])
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
    [(Case name path _ _ line _ _ _ _ selection)
      (str_cat.str-cat
        name
        " "
        (tltest-location (& path) line)
        " "
        (match selection
          [(Run) "[run]\n"]
          [(SlowSkipped) "[slow-skipped]\n"]
          [(Ignored reason) (str_cat.str-cat "[ignored: " reason "]\n")]))]))

(define (tltest-list-tests-from [tests : (__tl_dyn-array InlineTest)]) : i64
  (for [index (iterator.range 0 (array-length tests))]
    (io.print-format
      "{}"
      (tltest-list-line
        (owned_view.compiler-owned-array-element-shared-view tests index)))
    unit)
  (array-length tests))

(define (tltest-list-loaded
  [source : String]
  [decls : ast.AstDeclList]
  [paths : ast.AstDeclPathList]) : i64
  (match (tltest-collect source decls paths)
    [(Collect _ _ tests) (tltest-list-tests-from tests)]))

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
      (&
        (ast.ast-expr-cons
          (ast.ast-expr-cast
            (ast.ast-node-push
              (Literal (ast.ast-lit-int (string.string-length text))))
            (& (I32)))
          (& (ast.ast-expr-list-new)))))))

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
      (&
        (ast.ast-expr-cons
          (ast.ast-node-push (Literal (ast.ast-lit-int ignored)))
          (&
            (ast.ast-expr-cons
              (ast.ast-node-push (Literal (ast.ast-lit-int slow-skipped)))
              (& (ast.ast-expr-list-new)))))))))

(define (tltest-location [path : (& path str)] [line : i64]) : String
  (if (string.eq path "")
    (str_cat.str-cat "<unknown>:" (string.int->string line))
    (str_cat.str-cat (string.copy path) ":" (string.int->string line))))

(define (tltest-running-line [test : (& InlineTest)]) : String
  (match test
    [(Case name path _ _ line _ _ _ _ _)
      (str_cat.str-cat
        "test "
        (string.copy name)
        " "
        (tltest-location path line)
        "\n")]))

(define (tltest-ok-line [test : (& InlineTest)]) : String
  (match test
    [(Case name _ _ _ _ _ _ _ _ _)
      (str_cat.str-cat "ok " (string.copy name) "\n")]))

(define (tltest-failed-line [test : (& InlineTest)]) : String
  (match test
    [(Case name path _ _ line _ _ _ _ _)
      (str_cat.str-cat
        "FAILED "
        (string.copy name)
        " "
        (tltest-location path line)
        "\n")]))

(define (tltest-print-runtime-write-params) : ast.AstParamList
  (ast.ast-param-cons
    (& (ast.ast-param-id (tltest-fd-id) (I32) false))
    (&
      (ast.ast-param-cons
        (& (ast.ast-param-id (tltest-buf-id) (ast.ast-ty-ptr (& (U8))) false))
        (&
          (ast.ast-param-cons
            (& (ast.ast-param-id (tltest-n-id) (I32) false))
            (& (ast.ast-param-list-new))))))))

(define (tltest-linux-write-ptr-arg) : i64
  (ast.ast-node-push
    (Unsafe
      (ast.ast-expr-cons
        (ast.ast-expr-cast
          (ast.ast-expr-ptr-to-int (ast.ast-node-push (Var (tltest-buf-id))))
          (& (I64)))
        (& (ast.ast-expr-list-new))))))

(define (tltest-linux-write-syscall) : i64
  (ast.ast-node-push
    (Unsafe
      (ast.ast-expr-cons
        (ast.ast-expr-syscall
          (ast.ast-expr-cons
            (ast.ast-node-push (Literal (ast.ast-lit-int 1)))
            (&
              (ast.ast-expr-cons
                (ast.ast-expr-cast
                  (ast.ast-node-push (Var (tltest-fd-id)))
                  (& (I64)))
                (&
                  (ast.ast-expr-cons
                    (tltest-linux-write-ptr-arg)
                    (&
                      (ast.ast-expr-cons
                        (ast.ast-expr-cast
                          (ast.ast-node-push (Var (tltest-n-id)))
                          (& (I64)))
                        (& (ast.ast-expr-list-new))))))))))
        (& (ast.ast-expr-list-new))))))

(define (tltest-linux-print-runtime-write-decl) : ast.AstDecl
  (ast.ast-decl-def-fn-id
    (tltest-write-id)
    (tltest-print-runtime-write-params)
    (I32)
    (ast.ast-expr-cast (tltest-linux-write-syscall) (& (I32)))))

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
    (ast.ast-ty-func
      (ast.ast-type-cons (& (I32)) (& (ast.ast-type-list-new)))
      (& (I64)))))

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
        (& (I64))
        (&
          (ast.ast-type-cons
            (& (ast.ast-ty-ptr (& (U8))))
            (&
              (ast.ast-type-cons
                (& (I32))
                (&
                  (ast.ast-type-cons
                    (& (ast.ast-ty-mut-ptr (& (I32))))
                    (&
                      (ast.ast-type-cons (& (I64)) (& (ast.ast-type-list-new)))))))))))
      (& (I32)))))

(define (tltest-windows-get-stderr-handle-expr) : i64
  (ast.ast-expr-call
    (ast.ast-node-push (Var (tltest-get-std-handle-id)))
    (ast.ast-expr-cons
      (ast.ast-expr-cast
        (ast.ast-node-push (Literal (ast.ast-lit-int -12)))
        (& (I32)))
      (& (ast.ast-expr-list-new)))))

(define (tltest-windows-write-file-call) : i64
  (ast.ast-expr-call
    (ast.ast-node-push (Var (tltest-write-file-id)))
    (ast.ast-expr-cons
      (ast.ast-node-push (Var (tltest-handle-id)))
      (&
        (ast.ast-expr-cons
          (ast.ast-node-push (Var (tltest-buf-id)))
          (&
            (ast.ast-expr-cons
              (ast.ast-node-push (Var (tltest-n-id)))
              (&
                (ast.ast-expr-cons
                  (ast.ast-node-push
                    (PtrNull
                      (ast.ty-node-push (& (ast.ast-ty-mut-ptr (& (I32)))))))
                  (&
                    (ast.ast-expr-cons
                      (ast.ast-node-push (Literal (ast.ast-lit-int 0)))
                      (& (ast.ast-expr-list-new)))))))))))))

(define (tltest-windows-write-body) : i64
  (ast.ast-expr-let
    (ast.ast-let-binding-cons
      (&
        (ast.ast-let-binding-id
          (tltest-handle-id)
          (Some (I64))
          (tltest-windows-get-stderr-handle-expr)))
      (&
        (ast.ast-let-binding-cons
          (&
            (ast.ast-let-binding-id
              (tltest-ok-id)
              (Some (I32))
              (tltest-windows-write-file-call)))
          (& (ast.ast-let-binding-list-new)))))
    (ast.ast-expr-if
      (ast.ast-expr-binary
        (Eq)
        (ast.ast-node-push (Var (tltest-ok-id)))
        (ast.ast-expr-cast
          (ast.ast-node-push (Literal (ast.ast-lit-int 0)))
          (& (I32))))
      (ast.ast-expr-cast
        (ast.ast-node-push (Literal (ast.ast-lit-int -1)))
        (& (I32)))
      (ast.ast-node-push (Var (tltest-n-id))))))

(define (tltest-windows-print-runtime-write-decl) : ast.AstDecl
  (ast.ast-decl-def-fn-id
    (tltest-write-id)
    (tltest-print-runtime-write-params)
    (I32)
    (tltest-windows-write-body)))

(define (tltest-print-runtime-write-decl
  [target : be_state.CompilerBackendTarget]) : ast.AstDecl
  (match target
    [(Linux) (tltest-linux-print-runtime-write-decl)]
    [(Windows) (tltest-windows-print-runtime-write-decl)]))

(define (tltest-print-param-list) : ast.AstParamList
  (ast.ast-param-cons
    (& (ast.ast-param-id (tltest-text-id) (String) false))
    (&
      (ast.ast-param-cons
        (& (ast.ast-param-id (tltest-n-id) (I32) false))
        (& (ast.ast-param-list-new))))))

(define (tltest-print-runtime-write-call) : i64
  (ast.ast-expr-call
    (ast.ast-node-push (Var (tltest-write-id)))
    (ast.ast-expr-cons
      (ast.ast-expr-cast
        (ast.ast-node-push (Literal (ast.ast-lit-int 2)))
        (& (I32)))
      (&
        (ast.ast-expr-cons
          (ast.ast-node-push
            (Unsafe
              (ast.ast-expr-cons
                (ast.ast-expr-string-data
                  (ast.ast-node-push (Var (tltest-text-id))))
                (& (ast.ast-expr-list-new)))))
          (&
            (ast.ast-expr-cons
              (ast.ast-node-push (Var (tltest-n-id)))
              (& (ast.ast-expr-list-new)))))))))

(define (tltest-print-runtime-print-decl) : ast.AstDecl
  (ast.ast-decl-def-fn-id
    (tltest-print-error-id)
    (tltest-print-param-list)
    (Unit)
    (ast.ast-node-push
      (Begin
        (ast.ast-expr-cons
          (tltest-print-runtime-write-call)
          (&
            (ast.ast-expr-cons
              (ast.ast-node-push (Literal (Unit)))
              (& (ast.ast-expr-list-new)))))))))

(define (tltest-program-with-print-runtime
  [program : ast.AstProgram]
  [target : be_state.CompilerBackendTarget]) : ast.AstProgram
  (match program
    [(Program decls-box)
      (let
        [decls : ast.AstDeclList (deref decls-box)]
        (ast.ast-program
          (match target
            [(Linux)
              (ast.ast-decl-cons
                (& (tltest-print-runtime-write-decl target))
                (&
                  (ast.ast-decl-cons
                    (& (tltest-print-runtime-print-decl))
                    (& decls))))]
            [(Windows)
              (ast.ast-decl-cons
                (& (tltest-windows-get-std-handle-decl))
                (&
                  (ast.ast-decl-cons
                    (& (tltest-windows-write-file-decl))
                    (&
                      (ast.ast-decl-cons
                        (& (tltest-print-runtime-write-decl target))
                        (&
                          (ast.ast-decl-cons
                            (& (tltest-print-runtime-print-decl))
                            (& decls))))))))])))]))

;; Generated runtime, main and combined harness declarations are not physically
;; present in any source file, so their provenance lane names the synthetic
;; harness source instead of borrowing a module id or a display path id.
(define (tltest-generated-harness-provenance-id) : i64
  (ci.intern-generated-canonical-name "<generated test harness>"))

(define (tltest-paths-with-print-runtime-count
  [count : i64]
  [runtime-path-id : i64]
  [paths : ast.AstDeclPathList]) : ast.AstDeclPathList
  (if (<= count 0)
    paths
    (ast.ast-decl-path-list-prepend-builder-with-owner-and-provenance-id
      "<generated test runtime>"
      runtime-path-id
      (tltest-generated-harness-provenance-id)
      (tltest-paths-with-print-runtime-count (- count 1) runtime-path-id paths))))

(define (tltest-paths-with-print-runtime
  [target : be_state.CompilerBackendTarget]
  [paths : ast.AstDeclPathList]) : ast.AstDeclPathList
  (let
    [runtime-path-id : i64
      (ci.intern-generated-canonical-name "<generated test runtime>")]
    (match target
      [(Linux) (tltest-paths-with-print-runtime-count 2 runtime-path-id paths)]
      [(Windows)
        (tltest-paths-with-print-runtime-count 4 runtime-path-id paths)])))

(define (tltest-main-exprs-from
  [tests : (& (__tl_dyn-array InlineTest))]
  [index : i64]
  [out : ast.AstExprList]) : ast.AstExprList
  (if (< index 0)
    out
    (match (& (array-ref tests index))
      [(Case _ _ _ _ _ _ _ _ call-id selection)
        (match selection
          [(Run)
            (tltest-main-exprs-from
              tests
              (- index 1)
              (ast.ast-expr-cons
                (tltest-runtime-call-expr-id (tltest-runtime-case-begin-id))
                (&
                  (ast.ast-expr-cons
                    (tltest-print-expr
                      (tltest-running-line (& (array-ref tests index))))
                    (&
                      (ast.ast-expr-cons
                        (tltest-call-expr-id call-id)
                        (&
                          (ast.ast-expr-cons
                            (ast.ast-expr-if
                              (tltest-runtime-call-expr-id
                                (tltest-runtime-case-finish-id))
                              (tltest-print-expr
                                (tltest-failed-line (& (array-ref tests index))))
                              (tltest-print-expr
                                (tltest-ok-line (& (array-ref tests index)))))
                            (& out)))))))))]
          [_ (tltest-main-exprs-from tests (- index 1) out)])])))

(define (tltest-selection-counts
  [tests : (& tests (__tl_dyn-array InlineTest))]
  [wanted : i64]) : i64
  (let
    [count : i64 0]
    (for [index (iterator.range 0 (array-length tests))]
      (match (owned_view.compiler-owned-element-view tests index)
        [(Case _ _ _ _ _ _ _ _ _ selection)
          (let
            [kind : i64
              (match selection
                [(Run) 0]
                [(Ignored _) 1]
                [(SlowSkipped) 2])]
            (if (= kind wanted)
              (+= count 1)
              unit))]))
    count))

(define (tltest-ignored-count [tests : (& tests (__tl_dyn-array InlineTest))]) : i64
  (tltest-selection-counts tests 1))

(define (tltest-slow-skipped-count
  [tests : (& tests (__tl_dyn-array InlineTest))]) : i64
  (tltest-selection-counts tests 2))

(define (tltest-main-exprs [tests : (& (__tl_dyn-array InlineTest))]) : ast.AstExprList
  (let
    [count : i64 (array-length tests)]
    [ignored : i64 (tltest-ignored-count tests)]
    [slow-skipped : i64 (tltest-slow-skipped-count tests)]
    (ast.ast-expr-cons
      (tltest-runtime-call-expr-id (tltest-runtime-suite-begin-id))
      (&
        (tltest-main-exprs-from
          tests
          (- count 1)
          (ast.ast-expr-cons
            (tltest-runtime-suite-finish-expr count ignored slow-skipped)
            (& (ast.ast-expr-list-new))))))))

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
        [(Case _ _ module-id _ _ body _ private-id _ _)
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
    (& (ast.ast-decl-module-id (tltest-empty-name-id)))
    (&
      (ast.ast-decl-cons
        (&
          (Import
            (ast.ast-decl-meta-runtime-shared-view)
            (Spec
              (Module)
              "stdlib.runtime"
              (Some cbi.compiler-builtin-id-runtime-module)
              (Some (tltest-runtime-import-alias-id))
              (box (ast.ast-decl-span-fallback)))))
        (&
          (ast.ast-decl-cons
            (& (tltest-main-decl tests))
            (& (ast.ast-decl-list-new))))))))

(define (tltest-main-paths [source : String]) : ast.AstDeclPathList
  (ast.ast-decl-path-cons-with-owner-and-provenance-id
    (owned_view.compiler-owned-shared-view source)
    cbi.compiler-builtin-id-fix-empty
    (tltest-generated-harness-provenance-id)
    (ast.ast-decl-path-cons-with-owner-and-provenance-id
      (owned_view.compiler-owned-shared-view source)
      cbi.compiler-builtin-id-fix-empty
      (tltest-generated-harness-provenance-id)
      (ast.ast-decl-path-cons-with-owner-and-provenance-id
        source
        cbi.compiler-builtin-id-fix-empty
        (tltest-generated-harness-provenance-id)
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
        [(Case _ path module-id provenance-id _ _ _ _ _ _)
          (tltest-test-paths-onto
            tests
            (- index 1)
            (ast.ast-decl-path-list-prepend-builder-with-owner-and-provenance-id
              (owned_view.compiler-owned-shared-view path)
              module-id
              provenance-id
              (ast.ast-decl-path-list-prepend-builder-with-owner-and-provenance-id
                path
                module-id
                provenance-id
                out)))]))))

(define (tltest-main-decl [tests : (__tl_dyn-array InlineTest)]) : ast.AstDecl
  (ast.ast-decl-def-fn-id
    (tltest-main-id)
    (ast.ast-param-list-new)
    (I64)
    (ast.ast-node-push (Begin (tltest-main-exprs (& tests))))))

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

(define (tltest-generated-comptime-decl? [decl : (& ast.AstDecl)]) : bool
  (match (ast.ast-decl-generated-meta decl)
    [(Some _ _ _ _) true]
    [(No) false]))

(define (tltest-reach-mark-string-snapshot-runtime
  [names : tltest_name_map.Map]) : tltest_name_map.Map
  ;; Harness pruning runs before lowering emits raw `tl_substring` helper calls,
  ;; so keep the TypeLisp runtime body whenever a reachable test path may
  ;; synthesize a String snapshot or source substring call.
  (tltest-reach-mark-name-id names cbi.compiler-builtin-id-runtime-substring))

;; Generated-module imports and declaration macro calls resolve owner-written
;; `eq-<name>`/`hash-<name>` hooks by reflection after pruning. Mark a sentinel
;; so those hooks and their callees survive pruning.
(define (tltest-reach-mark-owner-eq-hash-hooks [names : tltest_name_map.Map]) : tltest_name_map.Map
  (tltest-reach-mark-name-id names (ci.intern "__tl-owner-eq-hash")))

;: Return whether NAME-ID spells an owner equality or hash hook.
(define (tltest-owner-eq-hash-hook-name? [name-id : i64]) : bool
  (let
    [name : String (ci.intern-str name-id)]
    (or
      (string.is-string-prefix-at (& name) "eq-" 0)
      (string.is-string-prefix-at (& name) "hash-" 0))))

;; Harness pruning runs before macro expansion expands `with-scratch`,
;; `with-escape`, or `clone.deep` into calls to owner-written `clone-<name>`
;; hooks. Mark a sentinel so those hooks and their callees survive pruning.
(define (tltest-reach-mark-clone-out-hooks [names : tltest_name_map.Map]) : tltest_name_map.Map
  (tltest-reach-mark-name-id names (ci.intern "__tl-clone-out")))

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
    [clone-names : tltest_name_map.Map
      (if (string.eq
        (ci.intern-str (tltest-reach-name-dot-leaf-id session name-id))
        "deep")
        (tltest-reach-mark-clone-out-hooks runtime-names)
        runtime-names)]
    (cond
      [(or
          (= base-id cbi.compiler-builtin-id-runtime-substring)
          (= base-id (cbi.compiler-builtin-ctfe-ref 93)))
        (tltest-reach-mark-string-snapshot-runtime clone-names)]
      [else clone-names])))

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
          (match (ast.ast-expr-unspan (& (ast.ast-node-get func)))
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
    [(or (WithEscape _ _) (WithScratch _))
      (tltest-reach-mark-children
        session
        node-id
        (tltest-reach-mark-clone-out-hooks
          (tltest-reach-mark-string-snapshot-runtime names)))]
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
    [_ (tltest-reach-mark-children session node-id names)]))

(define (tltest-reach-mark-tests
  [session : cis.InternStructuralSessionHandle]
  [tests : (& (__tl_dyn-array InlineTest))]
  [names : tltest_name_map.Map]) : tltest_name_map.Map
  (let
    [result : tltest_name_map.Map names]
    [count : i64 (array-length tests)]
    (for [i (iterator.range 0 count)]
      (let
        [body : i64
          (match (& (array-ref tests i))
            [(Case _ _ _ _ _ b _ _ _ _) b])]
        (set! result (tltest-reach-mark-expr session body result))))
    result))

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
    [(or (DefFn _ name _ _ _ _) (Extern _ name _ _ _))
      (if (tltest-runtime-string-helper-impl-name-id? name)
        (tltest-reach-mark-name-id names name)
        names)]
    [(Unsafe inner-box)
      (let
        [inner : ast.AstDecl (deref inner-box)]
        (tltest-reach-mark-runtime-helper-root inner names))]
    [_ names]))

(define (tltest-reach-mark-runtime-helper-roots
  [decls : (& ast.AstDeclList)]
  [names : tltest_name_map.Map]) : tltest_name_map.Map
  (let
    [result : tltest_name_map.Map names]
    [count : i64 (ast.ast-decl-list-len decls)]
    (for [i (iterator.range 0 count)]
      (let
        [decl : ast.AstDecl
          (ast.ast-decl-list-get
            decls
            i
            (ast.ast-decl-module-id cbi.compiler-builtin-id-fix-empty))]
        (set! result (tltest-reach-mark-runtime-helper-root decl result))))
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
      (match (ast.ast-fn-metadata-export (& metadata))
        [(Export _)
          (tltest-reach-mark-expr
            session
            body
            (tltest-reach-mark-name-id names name))]
        [(No)
          (if (tltest-reachable-name-marked? session names name)
            (tltest-reach-mark-expr session body names)
            (if (or
              (and
                (tltest-reachable-name-marked?
                  session
                  names
                  (ci.intern "__tl-clone-out"))
                (string.is-string-prefix-at (& (ci.intern-str name)) "clone-" 0))
              (and
                (tltest-reachable-name-marked?
                  session
                  names
                  (ci.intern "__tl-owner-eq-hash"))
                (tltest-owner-eq-hash-hook-name? name)))
              (tltest-reach-mark-expr
                session
                body
                (tltest-reach-mark-name-id names name))
              names))])]
    [(DefDispatch _ _ variants)
      ;; Dispatch declarations survive harness pruning even when uncalled.
      ;; Typechecking needs every variant; the fixpoint follows their bodies.
      (let
        [result : tltest_name_map.Map names]
        [index : i64 0]
        (while (< index (ast.ast-dispatch-variant-list-len (& variants)))
          (match (ast.ast-dispatch-variant-list-get
            (& variants)
            index
            (ast.ast-dispatch-variant-fallback))
            [(Variant _ name)
              (set! result (tltest-reach-mark-source-name session result name))])
          (+= index 1))
        result)]
    ;; Selected imports are retained even when no selected test uses them.
    ;; Keep their targets and let the fixpoint follow initializer/body deps.
    [(Import _ (Spec (ModuleItem item) _ _ _ _))
      (tltest-reach-mark-name-id names item)]
    ;; A top-level declaration macro call stays unexpanded here and is always
    ;; kept (tltest-reachable-runtime-decl?). Its arguments are the caller's
    ;; references: a constant named only by `(gen-slots first ...)` must survive
    ;; pruning, or the expansion reads an unbound name.
    ;; A generated-module import such as `(eq.eq T)`, `(hash.hash T)` or a
    ;; collection family, and a declaration macro call such as
    ;; `(hash.gen T)` or `(eq.gen T)`, resolve nominal owner hooks by
    ;; module-value reflection during expansion, after pruning.
    [(or (Import _ (Spec (Macro body _) _ _ _ _))
         (Import _ (Spec (MacroDecls body _) _ _ _ _)))
      (tltest-reach-mark-expr
        session
        body
        (tltest-reach-mark-owner-eq-hash-hooks names))]
    [(DefMacro _ _ _ _ body) (tltest-reach-mark-expr session body names)]
    [(Unsafe inner-box)
      (let
        [inner : ast.AstDecl (deref inner-box)]
        (tltest-reach-mark-decl session inner names))]
    [(or (DefStruct _ _ _ cleanup fields)
         (DefStructLifetimes _ _ _ _ cleanup fields))
      (tltest-reach-mark-field-cleanups
        fields
        (tltest-reach-mark-struct-cleanup cleanup names))]
    [(or (DefEnum _ _ cleanup variants)
         (DefEnumLifetimes _ _ _ cleanup variants))
      (tltest-reach-mark-variant-cleanups
        variants
        (tltest-reach-mark-enum-cleanup cleanup names))]
    [_ names]))

(define (tltest-reach-mark-decls-from
  [session : cis.InternStructuralSessionHandle]
  [decls : (& ast.AstDeclList)]
  [names : tltest_name_map.Map]) : tltest_name_map.Map
  (let
    [result : tltest_name_map.Map names]
    [count : i64 (ast.ast-decl-list-len decls)]
    (for [i (iterator.range 0 count)]
      (let
        [decl : ast.AstDecl
          (ast.ast-decl-list-get
            decls
            i
            (ast.ast-decl-module-id cbi.compiler-builtin-id-fix-empty))]
        (set! result (tltest-reach-mark-decl session decl result))))
    result))

;; Iterate the reachability marker to a fixpoint. The reachable-name set only
;; ever grows (marking is monotonic and dedup'd), so a pass that adds no new
;; names means we have converged and can stop. `fuel` (the decl count) stays as
;; a safety bound, but convergence normally takes only a handful of passes
;; rather than `fuel` full-program walks.
(define (tltest-reach-fixed
  [session : cis.InternStructuralSessionHandle]
  [decls : (& ast.AstDeclList)]
  [fuel : i64]
  [names : tltest_name_map.Map]) : tltest_name_map.Map
  (let
    [remaining : i64 fuel]
    [result : tltest_name_map.Map names]
    [done : bool false]
    (while (and (not done) (> remaining 0))
      (let
        [before : i64 (tltest_name_map.len (& result))]
        (set! result (tltest-reach-mark-decls-from session decls result))
        (if (= (tltest_name_map.len (& result)) before)
          (set! done true)
          (-= remaining 1))))
    result))

(define (tltest-reachable-names
  [session : cis.InternStructuralSessionHandle]
  [decls : (& ast.AstDeclList)]
  [tests : (& (__tl_dyn-array InlineTest))]) : tltest_name_map.Map
  (let
    [decl-count : i64 (ast.ast-decl-list-len decls)]
    (tltest-reach-fixed
      session
      decls
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
  [decl : (& ast.AstDecl)]
  [names : (& names tltest_name_map.Map)]) : bool
  (match decl
    [(or (Def _ name _ _) (Extern _ name _ _ _))
      (tltest-reachable-name-marked? session names name)]
    [(DefFn _ name _ _ _ metadata)
      (match (ast.ast-fn-metadata-export metadata)
        [(Export _) true]
        [(No) (tltest-reachable-name-marked? session names name)])]
    [(DefMacro _ _ _ _ _) true]
    [(Unsafe inner-box)
      (tltest-reachable-runtime-decl? session inner-box names)]
    [_ true]))

;; Keep every TLI-hydrated `Extern` across harness pruning: prebuilt `.tlci`
;; macros do not carry source AST bodies for reachability scanning, so their
;; expansions can reference any stdlib or prebuilt-package extern. Hydrated
;; externs carry no bodies, so keeping them adds no lowering or codegen work.
(define (tltest-tli-hydrated-extern-decl?
  [decl : (& ast.AstDecl)]
  [decl-path : (& decl-path str)]
  [decl-owner-id : i64]
  [decl-prov-id : i64]) : bool
  (match decl
    [(Extern _ _ _ meta-box _)
      (or
        (source_text.starts-with? decl-path "<tli-stdlib>:")
        (and
          (>= decl-prov-id 0)
          (source_text.starts-with?
            (& (ci.intern-str decl-prov-id))
            "<tli-stdlib>:"))
        (and
          (>= decl-owner-id 0)
          (compiler_load.compiler-load-tli-has-module?
            (& (ci.intern-str decl-owner-id))))
        (match meta-box
          [(Metadata abi _ _ _ _)
            (match abi
              [(TypeLisp) true]
              [_ false])]))]
    [(Unsafe inner-box)
      (tltest-tli-hydrated-extern-decl?
        inner-box
        decl-path
        decl-owner-id
        decl-prov-id)]
    [_ false]))

(define (tltest-prune-runtime-decls-in
  [session : cis.InternStructuralSessionHandle]
  [decls : ast.AstDeclList]
  [paths : ast.AstDeclPathList]
  [target-path : (& target-path str)]
  [keep-all-generated? : bool]
  [names : (& tltest_name_map.Map)]
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
                [decl-prov-id : i64
                  (ast.ast-decl-path-list-provenance-id
                    (& cur-paths)
                    0
                    decl-owner-id)]
                ;; Keep imported generated helpers: macro-expanded bodies can
                ;; reference them in ways the lightweight source reachability walk
                ;; cannot always see. Local generated helpers and ordinary imported
                ;; functions/values still go through reachability pruning so tiny
                ;; inline harnesses stay small. In combined mode any file in the
                ;; chunk may also be imported by another file in the chunk.
                (when
                  (or
                    (tltest-reachable-runtime-decl? session (& decl) names)
                    (tltest-tli-hydrated-extern-decl?
                      (& decl)
                      (& decl-path)
                      decl-owner-id
                      decl-prov-id)
                    (and
                      (or
                        keep-all-generated?
                        (not
                          (tltest-owned-test-path? target-path (& decl-path))))
                      (tltest-generated-comptime-decl? (& decl))))
                  (ast.ast-decl-list-push (&mut result-decls) decl)
                  (ast.ast-decl-path-list-push-with-owner-and-provenance-id
                    (&mut result-paths)
                    decl-path
                    decl-owner-id
                    decl-prov-id))
                (set! cur-decls rest)
                (set! cur-paths path-rest))])]))
    (Decls result-decls result-paths)))

(define (tltest-prune-runtime-decls
  [session : cis.InternStructuralSessionHandle]
  [source : (& source str)]
  [decls : ast.AstDeclList]
  [paths : ast.AstDeclPathList]
  [tests : (& (__tl_dyn-array InlineTest))]) : InlineRuntimeDecls
  (let
    [names : tltest_name_map.Map
      (tltest-reachable-names session (& decls) tests)]
    (tltest-prune-runtime-decls-in
      session
      decls
      paths
      (& (compiler_load.compiler-load-normalize-path source))
      false
      (& names)
      (ast.ast-decl-list-new)
      (ast.ast-decl-path-list-new))))

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
        (& tests))
        [(Decls pruned-decls pruned-paths)
          (let
            [count : i64 (array-length tests)]
            (Harness
              (ast.ast-program
                (compiler_load.compiler-load-decl-list-append
                  (& pruned-decls)
                  (&
                    (tltest-generated-test-decls
                      (owned_view.compiler-owned-shared-view tests)))))
              (compiler_load.compiler-load-decl-path-list-append
                (& pruned-paths)
                (& (tltest-generated-test-paths source tests)))
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
      (& decls)
      (& (tltest-generated-typecheck-decls tests)))))

(define (tltest-inline-typecheck-paths
  [paths : ast.AstDeclPathList]
  [tests : (__tl_dyn-array InlineTest)]) : ast.AstDeclPathList
  (compiler_load.compiler-load-decl-path-list-append
    (& paths)
    (& (tltest-generated-typecheck-paths tests))))

(defenum ResultTlTestInlineCheck
  (Ok)
  (Err String))

(define (tltest-inline-typecheck-loaded-result
  [source : String]
  [diagnostic-source : TlTestDiagnosticSource]
  [decls : ast.AstDeclList]
  [paths : ast.AstDeclPathList]
  [roots : cli_svec.Vec]
  [cfgs : sym_i64_env.SymI64Env]
  [cache-scope-prefix : String]) : ResultTlTestInlineCheck
  (match (tltest-collect source decls paths)
    [(Collect runtime-decls runtime-paths tests)
      (let
        [count : i64 (array-length tests)]
        (if (= count 0)
          (ResultTlTestInlineCheck.Ok)
          (match (tltest-prune-runtime-decls
            (tltest-active-structural-session)
            source
            runtime-decls
            runtime-paths
            (& tests))
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
                  [(ResultCompilerTypecheck.Ok _) (ResultTlTestInlineCheck.Ok)]
                  [(ResultCompilerTypecheck.Err diag)
                    (ResultTlTestInlineCheck.Err
                      (tltest-render-source-diagnostic
                        source
                        diagnostic-source
                        (cdiag.compiler-diagnostic-list-first (deref diag))))]))])))]))

(define (tltest-inline-typecheck-loaded
  [source : String]
  [diagnostic-source : TlTestDiagnosticSource]
  [decls : ast.AstDeclList]
  [paths : ast.AstDeclPathList]
  [roots : cli_svec.Vec]
  [cfgs : sym_i64_env.SymI64Env]
  [cache-scope-prefix : String]) : i64
  (match (tltest-inline-typecheck-loaded-result
    source
    diagnostic-source
    decls
    paths
    roots
    cfgs
    cache-scope-prefix)
    [(ResultTlTestInlineCheck.Ok) 0]
    [(ResultTlTestInlineCheck.Err message)
      (io.print-error message)
      1]))

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
          (& roots)))]
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

(define (tltest-inline-typecheck-file-with-cfg-result
  [source : String]
  [roots : cli_svec.Vec]
  [cfgs : sym_i64_env.SymI64Env]
  [cache-scope-prefix : String]) : ResultTlTestInlineCheck
  (if (or
    (tltest-inline-stdlib-source? source (cli_svec.clone-vec (& roots)))
    (not (io.file-exists? (owned_view.compiler-owned-shared-view source)))
    (not
      (tltest-source-has-inline-tests?
        (owned_view.compiler-owned-shared-view source))))
    (ResultTlTestInlineCheck.Ok)
    (let
      [test-cfgs : sym_i64_env.SymI64Env (tltest-inline-typecheck-cfgs cfgs)]
      [legacy-roots : cli_svec.Vec (cli_svec.clone-vec (& roots))]
      (tltest-inline-reset-load-state!)
      (match (driver.compiler-driver-load-file-with-runtime
        (owned_view.compiler-owned-shared-view source)
        legacy-roots
        test-cfgs)
        [(Ok decls paths _ _)
          (tltest-inline-typecheck-loaded-result
            (string.copy (& source))
            (tltest-diagnostic-source source (& decls) (& paths))
            decls
            paths
            roots
            test-cfgs
            cache-scope-prefix)]
        [(Err diag)
          (ResultTlTestInlineCheck.Err
            (driver.compiler-driver-render-source-diagnostic
              (tltest-diagnostic-with-source-fallback source (deref diag))))]))))

(define (tltest-inline-typecheck-file-with-cfg
  [source : String]
  [roots : cli_svec.Vec]
  [cfgs : sym_i64_env.SymI64Env]
  [cache-scope-prefix : String]) : i64
  (match (tltest-inline-typecheck-file-with-cfg-result
    source
    roots
    cfgs
    cache-scope-prefix)
    [(ResultTlTestInlineCheck.Ok) 0]
    [(ResultTlTestInlineCheck.Err message)
      (io.print-error message)
      1]))

;; `stdlib.tli` is built without `--cfg test`. Strip `test` only when opening
;; the stdlib catalog so non-stdlib tests hydrate prebuilt stdlib while keeping
;; `--cfg test` active for the test files themselves.
(define (tltest-stdlib-tli-cfgs [cfgs : sym_i64_env.SymI64Env]) : sym_i64_env.SymI64Env
  (cfg_core.compiler-cfg-remove-id cfgs (ci.intern "test")))

;; Auto-disable prebuilt stdlib when testing files inside `stdlib/` so stdlib
;; `(cfg test ...)` items and inline tests always compile from source.
(define (tltest-stdlib-source-path? [path : (& path str)]) : bool
  (let
    [norm : String (compiler_load.compiler-load-normalize-path path)]
    (or
      (compiler_load.compiler-load-stdlib-import? (& norm))
      (string.contains (& norm) "/stdlib/")
      (string.contains (& norm) "\\stdlib\\"))))

(define (tltest-any-stdlib-source-path? [paths : (& cli_svec.Vec)]) : bool
  (let
    [count : i64 (cli_svec.len paths)]
    [found : bool false]
    [i : i64 0]
    (while (and (not found) (< i count))
      (let
        [path : String (cli_svec.get paths i "")]
        (when (tltest-stdlib-source-path? (& path)) (set! found true)))
      (+= i 1))
    found))

(define (tltest-open-stdlib-tli-for-session!
  [entry-path : (& str)]
  [allow-prebuilt : bool]
  [target : target_cfg.CompilerTargetCfg]
  [stdlib-roots : (& cli_svec.Vec)]
  [cfgs : sym_i64_env.SymI64Env]
  [opt-level : i64]
  [require-archive : bool]) : tli_cli.ResultTliCatalogOpen
  (let
    [load-state : compiler_load.CompilerLoadSessionState
      (compiler_load.compiler-load-serial-test-session-state)]
    (if (and allow-prebuilt (not (tltest-stdlib-source-path? entry-path)))
      (driver.compiler-driver-open-tli-catalog-for-session!
        (& load-state)
        entry-path
        target
        stdlib-roots
        (tltest-stdlib-tli-cfgs cfgs)
        opt-level
        require-archive)
      (begin
        (driver.compiler-driver-clear-last-hydrated-archive-path!)
        (compiler_load.compiler-load-session-state-tli-release! (& load-state))
        tli_cli.ResultTliCatalogOpen.Ok))))

(define (tltest-hydrate-and-finish-tli-serial!
  [program : ir.CompilerIrProgram]
  [opt-level : i64]) : ir.CompilerIrProgram
  (let
    [load-state : compiler_load.CompilerLoadSessionState
      (compiler_load.compiler-load-serial-test-session-state)]
    [hydrated : ir.CompilerIrProgram
      (driver.compiler-driver-hydrate-tli-compact-ir!
        (& load-state)
        (ast.ast-node-pool-reader-context-current)
        program
        opt-level)]
    (driver.compiler-driver-finish-tli-hydrated-serial-session!)
    hydrated))

(define (tltest-package-open-tli-and-deps!
  [entry-path : (& str)]
  [target : target_cfg.CompilerTargetCfg]
  [stdlib-roots : (& cli_svec.Vec)]
  [manifest-dir : (& str)]
  [deps : (& compiler_load.CompilerPkgDeps)]
  [cfgs : sym_i64_env.SymI64Env]
  [opt-level : i64]
  [require-archive : bool]) : tli_cli.ResultTliCatalogOpen
  (let
    [load-state : compiler_load.CompilerLoadSessionState
      (compiler_load.compiler-load-serial-test-session-state)]
    (compiler_dependency_tlci.compiler-dependency-tlci-prepare-deps!
      (owned_view.compiler-owned-shared-view load-state)
      (string.copy manifest-dir)
      (compiler_load.clone-compiler-pkg-deps deps))
    (match (tltest-open-stdlib-tli-for-session!
      entry-path
      true
      target
      stdlib-roots
      cfgs
      opt-level
      require-archive)
      [(Err tli-msg) (Err tli-msg)]
      [(Ok)
        (if (compiler_dependency_tlci.compiler-dependency-tlci-force-source?)
          (tli_cli.ResultTliCatalogOpen.Ok)
          (tli_cli.tli-open-transitive-package-deps-for-session!
            (& load-state)
            manifest-dir
            deps
            target
            cfgs
            require-archive))])))

(define (tltest-package-release-tli-and-deps!) : unit
  (let
    [load-state : compiler_load.CompilerLoadSessionState
      (compiler_load.compiler-load-serial-test-session-state)]
    (compiler_load.compiler-load-tli-release!)
    (match (compiler_load.compiler-load-session-state-dependency-catalog-release!
      load-state)
      [(Ok) unit]
      [(Err _) unit])))

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
      [legacy-roots : cli_svec.Vec (cli_svec.clone-vec (& roots))]
      (match (tltest-package-open-tli-and-deps!
        (& source)
        (compiler_check_core.compiler-check-target-from-cfgs test-cfgs)
        (& legacy-roots)
        (& manifest-dir)
        (& deps)
        test-cfgs
        1
        false)
        [(Err tli-msg)
          (tltest-package-release-tli-and-deps!)
          (io.print-error tli-msg)
          1]
        [(Ok)
          (let
            [status : i64
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
                      (string.copy (& package-owner))
                      (& manifest-dir)
                      (& legacy-roots)
                      (string.copy (& source)))
                    (tltest-diagnostic-source source (& decls) (& paths))
                    decls
                    paths
                    roots
                    test-cfgs
                    cache-scope-prefix)]
                [(Err diag)
                  (io.print-error
                    (driver.compiler-driver-render-source-diagnostic
                      (tltest-diagnostic-with-source-fallback
                        source
                        (deref diag))))
                  1])]
            (tltest-package-release-tli-and-deps!)
            status)]))
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
      (unsafe
        ;; unsafe: installs the global load session; replaced before this arena ends
        (driver.compiler-driver-reset-file-state!))
      (unsafe
        ;; unsafe: resets the global persistent intern arena
        (ci.intern-persistent-arena-reset!))
      (unsafe
        ;; unsafe: releases the global token buffers; they keep no allocation of this arena
        (compiler_load.compiler-load-transfer-frontend-handoff!))
      (let
        [pools : ast.AstNodePoolContext
          (driver.compiler-driver-state-new-checked-lower-pools)]
        [_install : unit
          (unsafe
            ;; unsafe: installs global AST pool state; replaced before this arena ends
            (ast.ast-node-pool-context-install! pools))]
        [status : i64
          (unsafe
            ;; unsafe: interned names live in the persistent intern arena, not this one
            (tltest-inline-typecheck-package-source-with-cfg
              source
              roots
              manifest-dir
              package-owner
              deps
              (cfg_core.compiler-cfg-snapshot-to-env (& cfg-names))
              cache-scope-prefix))]
        [retired : ast.AstNodePoolContext
          (ast.ast-node-pool-context-capture-active)]
        ;; Retire all references before returning pool storage. Replacement
        ;; session/cache carriers must live outside the entry scratch arena.
        (in-arena
          home
          (tltest-inline-clear-load-only-caches!)
          (unsafe
            ;; unsafe: installs the global load session; replaced before this arena ends
            (driver.compiler-driver-reset-file-state!))
          (unsafe
            ;; unsafe: installs global AST pool state; replaced before this arena ends
            (driver.compiler-driver-state-destroy-uncommitted-pools! retired))
          (unsafe
            ;; unsafe: resets the global persistent intern arena
            (ci.intern-persistent-arena-reset!))
          (unsafe
            ;; unsafe: releases the global token buffers; they keep no allocation of this arena
            (compiler_load.compiler-load-transfer-frontend-handoff!)))
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
            (str_cat.str-cat
              "test: package inline preflight failed: "
              source
              "\n")))
        (+= cursor 1)))
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

(define (tltest-cfgs [backend-target : be_state.CompilerBackendTarget]) : sym_i64_env.SymI64Env
  (cfg_core.compiler-cfg-enable
    (driver.compiler-driver-target-cfgs
      backend-target
      (target_cfg.compiler-target-user-cfgs (& tltest-user-cfg-slots)))
    "test"))

(define (tltest-check-only
  [source : String]
  [diagnostic-source : TlTestDiagnosticSource]
  [program : ast.AstProgram]
  [paths : ast.AstDeclPathList]
  [count : i64]
  [target : be_state.CompilerBackendTarget]
  [roots : cli_svec.Vec]) : i64
  (let
    [legacy-roots : cli_svec.Vec (cli_svec.clone-vec (& roots))]
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
          (tltest-render-source-diagnostic
            source
            diagnostic-source
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

;; Package harnesses select declarations by display path. Snapshot the loaded
;; physical provenance before collection rebuilds the harness's path lanes.
(defstruct TlTestDiagnosticSource
  (physical-path String)
  (paths sym_i64_env.SymI64Env))

(define (tltest-diagnostic-source
  [source : String]
  [decls : (& decls ast.AstDeclList)]
  [paths : (& paths ast.AstDeclPathList)]) : TlTestDiagnosticSource
  (let
    [physical-paths : sym_i64_env.SymI64Env (sym_i64_env.sym-i64-empty)]
    (for [index (iterator.range 0 (ast.ast-decl-list-len decls))]
      (let
        [provenance : i64 (ast.ast-decl-path-list-provenance-id paths index -1)]
        (when
          (and
            (>= provenance 0)
            (match (ast.ast-decl-list-ref-borrowed decls index)
              [(Module _) false]
              [_ true]))
          (let
            [path : i64 (ci.intern (ast.ast-decl-path-list-get paths index ""))]
            [previous : i64
              (sym_i64_env.sym-i64-lookup-id-or (& physical-paths) path -1)]
            (when
              (and (not (= previous provenance)) (not (= previous -2)))
              (set!
                physical-paths
                (sym_i64_env.sym-i64-bind-id
                  physical-paths
                  path
                  (if (= previous -1)
                    provenance
                    -2))))))))
    (TlTestDiagnosticSource source physical-paths)))

(define (tltest-render-source-diagnostic
  [source : String]
  [diagnostic-source : TlTestDiagnosticSource]
  [diag : cdiag.CompilerDiagnostic]) : String
  (let
    [located : cdiag.CompilerDiagnostic
      (tltest-diagnostic-with-source-fallback (string.copy (& source)) diag)]
    [path : String (cdiag.compiler-diagnostic-path (& located))]
    [provenance : i64
      (sym_i64_env.sym-i64-lookup-id-or
        (& diagnostic-source.paths)
        (ci.intern (string.copy (& path)))
        -1)]
    [physical-path : String
      (cond
        [(string.eq path source) diagnostic-source.physical-path]
        [(>= provenance 0) (tc_core.tc-provenance-display-path provenance)]
        [else path])]
    [text : cdiag.CompilerDiagnosticSource
      (driver.compiler-driver-diagnostic-source-read
        (&
          (compiler_load.compiler-load-prelude-source-path
            (& physical-path)
            (cdiag.compiler-diagnostic-load-failure? (& located)))))]
    (cdiag.compiler-diagnostic-render-indexed-source (& located) (& text))))

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
  [target : be_state.CompilerBackendTarget]) : String
  (if (be_facts.compiler-backend-target-windows? target)
    "one;two;three"
    "one:two:three"))

(define (tltest-stdlib-env-fixture-env
  [target : be_state.CompilerBackendTarget]) : process.ProcessEnvList
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
  [target : be_state.CompilerBackendTarget]
  [backend-mode : be_state.CompilerBackendMode]) : lower.CompilerLowerMode
  (driver.compiler-driver-lower-mode-for-target target backend-mode))

(define (tltest-run-harness-in-temp-with-lower-state
  [lower-state : lower.CompilerLowerState]
  [source : String]
  [entry-path : String]
  [diagnostic-source : TlTestDiagnosticSource]
  [program : ast.AstProgram]
  [paths : ast.AstDeclPathList]
  [roots : cli_svec.Vec]
  [target : be_state.CompilerBackendTarget]
  [opt-level : i64]
  [backend-mode : be_state.CompilerBackendMode]
  [inline-harness : bool]
  [temp-dir : String]) : i64
  (let
    [files : build_run_core.SourceToolTempFiles
      (build_run_core.source-tool-temp-files temp-dir source target)]
    [legacy-roots : cli_svec.Vec (cli_svec.clone-vec (& roots))]
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
      (string.copy (& entry-path))
      program
      paths
      (tltest-harness-lower-mode target backend-mode)
      (owned_view.compiler-owned-shared-view legacy-roots)
      (tltest-cfgs target)
      (compiler_typecheck_api.compiler-typecheck-prefix-cache-scope
        "typecheck-prefix-test-cli"
        legacy-roots
        (tltest-cfgs target)))
      [(Ok ir spans lower-state)
        (let
          [hydrated-ir : ir.CompilerIrProgram
            (tltest-hydrate-and-finish-tli-serial! ir opt-level)]
          [link-inputs : build_run_core.SourceToolLinkInputs
            (build_run_core.source-tool-link-inputs-with-hydrated-archives
              (build_run_core.source-tool-link-inputs-empty))]
          (match (build_run_core.source-tool-link-and-run
            (build_run_core.SourceToolLinkRequest
              (owned_view.compiler-owned-shared-view source)
              (Lowered hydrated-ir spans lower-state)
              target
              opt-level
              backend-mode
              link-inputs
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
              failed]))]
      [(Err diag)
        (compiler_load.compiler-load-tli-release!)
        (io.print-error
          (tltest-render-source-diagnostic
            (if (string.eq entry-path "")
              (string.copy (& source))
              entry-path)
            diagnostic-source
            (deref diag)))
        (build_run_core.source-tool-clean-temp-files files true)
        failed])))

(define (tltest-run-harness-in-temp
  [source : String]
  [entry-path : String]
  [diagnostic-source : TlTestDiagnosticSource]
  [program : ast.AstProgram]
  [paths : ast.AstDeclPathList]
  [roots : cli_svec.Vec]
  [target : be_state.CompilerBackendTarget]
  [opt-level : i64]
  [backend-mode : be_state.CompilerBackendMode]
  [inline-harness : bool]
  [temp-dir : String]) : i64
  (let
    [lower-state : lower.CompilerLowerState (lower.compiler-lower-state-new)]
    [status : i64
      (tltest-run-harness-in-temp-with-lower-state
        lower-state
        source
        entry-path
        diagnostic-source
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
  [diagnostic-source : TlTestDiagnosticSource]
  [program : ast.AstProgram]
  [paths : ast.AstDeclPathList]
  [roots : cli_svec.Vec]
  [target : String]
  [opt-level : i64]
  [backend-mode : be_state.CompilerBackendMode]
  [inline-harness : bool]) : i64
  (match (build_run_core.source-tool-parse-target
    (owned_view.compiler-owned-shared-view target))
    [(Err message)
      (io.print-error message)
      1]
    [(Ok backend-target)
      (match (build_run_core.source-tool-create-temp-dir "typelisp-test")
        [(Ok temp-dir)
          (tltest-run-harness-in-temp
            source
            entry-path
            diagnostic-source
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
  [backend-mode : be_state.CompilerBackendMode]) : i64
  (tltest-run-direct-with-entry
    (owned_view.compiler-owned-shared-view source)
    (string.copy (& source))
    (TlTestDiagnosticSource source (sym_i64_env.sym-i64-empty))
    program
    paths
    roots
    target
    opt-level
    backend-mode
    true))

(define (tltest-no-tests-check
  [source : String]
  [decls : ast.AstDeclList]
  [paths : ast.AstDeclPathList]
  [roots : cli_svec.Vec]
  [target : be_state.CompilerBackendTarget]) : i64
  (let
    [legacy-roots : cli_svec.Vec (cli_svec.clone-vec (& roots))]
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
            (tltest-diagnostic-with-source-fallback
              source
              (cdiag.compiler-diagnostic-list-first (deref diag)))))
        1])))

(define (tltest-no-tests-run
  [source : String]
  [target : String]
  [program : ast.AstProgram]
  [paths : ast.AstDeclPathList]
  [roots : cli_svec.Vec]
  [opt-level : i64]
  [backend-mode : be_state.CompilerBackendMode]) : i64
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
            (+= i 1)
            (set! open true)]
          [(and open (tltest-source-prefix-space? c))
            (+= i 1)
            (set! open true)]
          [(and open (tltest-inline-marker-at? source i n)) (set! found true)]
          [(tltest-source-line-break? c)
            (+= i 1)
            (set! open true)]
          [else
            (+= i 1)
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
    [manifest-dir : String (str_cat.str-cat integration-prefix "manifest.d")]
    (match (fs.try-file-kind (& manifest-dir))
      [(OkFsFileKind kind) (fs.file-kind-directory? kind)]
      [(ErrFsFileKind _) false])))

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
      (if (tltest-main-decl? (& decl))
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
  [diagnostic-source : TlTestDiagnosticSource]
  [target : String]
  [roots : cli_svec.Vec]
  [opt-level : i64]
  [backend-mode : be_state.CompilerBackendMode]
  [test-mode : TestMode]
  [backend-target : be_state.CompilerBackendTarget]
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
                      source
                      diagnostic-source
                      program
                      harness-paths
                      count
                      backend-target
                      roots)]
                  [(Run)
                    (tltest-run-direct-with-entry
                      (string.copy (& source))
                      source
                      diagnostic-source
                      program
                      harness-paths
                      roots
                      target
                      opt-level
                      backend-mode
                      true)])]
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
    (for [index (iterator.range 0 (cli_svec.len (& sources)))]
      (let
        [source : String (cli_svec.get (& sources) index "")]
        (if (and
          (tltest-package-integration-source?
            (owned_view.compiler-owned-shared-view source)
            (owned_view.compiler-owned-shared-view tests-prefix))
          (tltest-package-integration-selected? source))
          (cli_svec.push-ref! (&mut selected) source)
          unit)))
    (tltest-shuffle-string-vec! (&mut selected))
    selected))

(define (tltest-package-integration-missing-main [source : String]) : String
  (str_cat.str-cat "test: integration test file has no main: " source "\n"))

(define (tltest-package-integration-check
  [source : String]
  [decls : ast.AstDeclList]
  [paths : ast.AstDeclPathList]
  [roots : cli_svec.Vec]
  [target : be_state.CompilerBackendTarget]) : ResultTestPackageTotals
  (io.print-format
    "{}"
    (tltest-package-integration-line
      (owned_view.compiler-owned-shared-view source)))
  (if (tltest-decls-have-main? (owned_view.compiler-owned-shared-view decls))
    (let
      [legacy-roots : cli_svec.Vec (cli_svec.clone-vec (& roots))]
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
              (tltest-diagnostic-with-source-fallback
                source
                (cdiag.compiler-diagnostic-list-first (deref diag)))))
          (Err 1)]))
    (begin
      (io.print-error (tltest-package-integration-missing-main source))
      (Err 1))))

(define (tltest-package-integration-run
  [source : String]
  [target : String]
  [roots : cli_svec.Vec]
  [opt-level : i64]
  [backend-mode : be_state.CompilerBackendMode]
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
          (string.copy (& source))
          ""
          (tltest-diagnostic-source source (& decls) (& paths))
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
  [backend-mode : be_state.CompilerBackendMode]
  [test-mode : TestMode]
  [backend-target : be_state.CompilerBackendTarget]
  [manifest-dir : String]
  [package-owner : String]
  [deps : compiler_load.CompilerPkgDeps]) : ResultTestPackageTotals
  (if (tltest-package-integration-selected? source)
    (if tltest-list-only
      (begin
        (io.print-format "{}" (str_cat.str-cat source "\n"))
        (Ok 1 1))
      (let
        [cfgs : sym_i64_env.SymI64Env (tltest-cfgs backend-target)]
        [target-cfg : target_cfg.CompilerTargetCfg
          (compiler_check_core.compiler-check-target-from-cfgs cfgs)]
        (match (tltest-package-open-tli-and-deps!
          (& source)
          target-cfg
          (& roots)
          (& manifest-dir)
          (& deps)
          cfgs
          opt-level
          (not (tltest-check-mode? test-mode)))
          [(Err tli-msg)
            (tltest-package-release-tli-and-deps!)
            (io.print-error tli-msg)
            (Err 1)]
          [(Ok)
            (let
              [result : ResultTestPackageTotals
                (match (driver.compiler-driver-load-package-file-with-runtime-owned-cfg
                  (owned_view.compiler-owned-shared-view source)
                  (owned_view.compiler-owned-shared-view roots)
                  manifest-dir
                  package-owner
                  deps
                  true
                  cfgs)
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
                      (str_cat.str-cat
                        "test: integration test source failed: "
                        source))
                    (io.print-error
                      (driver.compiler-driver-render-source-diagnostic
                        (deref diag)))
                    (Err 1)])]
              (tltest-package-release-tli-and-deps!)
              result)])))
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
      ;; `compiler-driver-reset-file-state!` recreates `tc-entry-hidden-arena`;
      ;; release it immediately so isolated batch entries retain no hidden arena.
      (tc_core.tc-entry-hidden-names-release!)
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
  (driver.compiler-driver-clear-last-hydrated-archive-path!)
  result)

(define (tltest-package-run-integration-source-isolated-count
  [source : String]
  [target : String]
  [roots : cli_svec.Vec]
  [opt-level : i64]
  [backend-mode : be_state.CompilerBackendMode]
  [test-mode : TestMode]
  [backend-target : be_state.CompilerBackendTarget]
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
  [backend-mode : be_state.CompilerBackendMode]
  [test-mode : TestMode]
  [backend-target : be_state.CompilerBackendTarget]
  [manifest-dir : String]
  [package-owner : String]
  [deps : compiler_load.CompilerPkgDeps]) : ResultTestPackageTotals
  (if (tltest-source-has-inline-tests?
    (owned_view.compiler-owned-shared-view source))
    (let
      [source-roots : cli_svec.Vec (tltest-source-roots (& source) roots)]
      [legacy-roots : cli_svec.Vec (cli_svec.clone-vec (& source-roots))]
      [cfgs : sym_i64_env.SymI64Env (tltest-cfgs backend-target)]
      [target-cfg : target_cfg.CompilerTargetCfg
        (compiler_check_core.compiler-check-target-from-cfgs cfgs)]
      (match (tltest-package-open-tli-and-deps!
        (& source)
        target-cfg
        (& legacy-roots)
        (& manifest-dir)
        (& deps)
        cfgs
        opt-level
        (not (tltest-check-mode? test-mode)))
        [(Err tli-msg)
          (tltest-package-release-tli-and-deps!)
          (io.print-error tli-msg)
          (Err 1)]
        [(Ok)
          (let
            [result : ResultTestPackageTotals
              (match (driver.compiler-driver-load-package-file-with-runtime-owned-cfg
                (owned_view.compiler-owned-shared-view source)
                (owned_view.compiler-owned-shared-view legacy-roots)
                (owned_view.compiler-owned-shared-view manifest-dir)
                (owned_view.compiler-owned-shared-view package-owner)
                deps
                true
                cfgs)
                [(Ok decls paths _ _)
                  (let
                    [owned-source : String
                      (compiler_load.compiler-load-package-owned-path
                        (string.copy (& package-owner))
                        (& manifest-dir)
                        (& legacy-roots)
                        (string.copy (& source)))]
                    (tltest-package-run-one
                      owned-source
                      (tltest-diagnostic-source source (& decls) (& paths))
                      target
                      source-roots
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
                    (driver.compiler-driver-render-source-diagnostic
                      (deref diag)))
                  (Err 1)])]
            (tltest-package-release-tli-and-deps!)
            result)]))
    (Ok 0 0)))

(define (tltest-package-run-source-isolated-count
  [source : String]
  [target : String]
  [roots : cli_svec.Vec]
  [opt-level : i64]
  [backend-mode : be_state.CompilerBackendMode]
  [test-mode : TestMode]
  [backend-target : be_state.CompilerBackendTarget]
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
  [tests-prefix : (& tests-prefix str)]
  [target : String]
  [roots : cli_svec.Vec]
  [opt-level : i64]
  [backend-mode : be_state.CompilerBackendMode]
  [test-mode : TestMode]
  [backend-target : be_state.CompilerBackendTarget]
  [manifest-dir : String]
  [package-owner : String]
  [deps : compiler_load.CompilerPkgDeps]
  [file-count : i64]
  [test-count : i64]
  [failed-file-count : i64]) : ResultTestPackageTotals
  (for [index (iterator.range 0 (cli_svec.len (& sources)))]
    (let
      [source : String (cli_svec.get (& sources) index "")]
      (if (tltest-package-test-source? source tests-prefix)
        unit
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
              (set! file-count (+ file-count 1))
              (set! test-count (+ test-count failed-tests))
              (set! failed-file-count (+ failed-file-count 1)))
            (if (< source-tests 0)
              (return (Err (- 0 source-tests)))
              (begin
                (set!
                  file-count
                  (if (= source-tests 0)
                    file-count
                    (+ file-count 1)))
                (set! test-count (+ test-count source-tests)))))))))
  (if (= failed-file-count 0)
    (Ok file-count test-count)
    (Failed file-count test-count failed-file-count)))

(define (tltest-package-run-sources
  [sources : cli_svec.Vec]
  [tests-prefix : (& tests-prefix str)]
  [target : String]
  [roots : cli_svec.Vec]
  [opt-level : i64]
  [backend-mode : be_state.CompilerBackendMode]
  [test-mode : TestMode]
  [backend-target : be_state.CompilerBackendTarget]
  [manifest-dir : String]
  [package-owner : String]
  [deps : compiler_load.CompilerPkgDeps]
  [file-count : i64]
  [test-count : i64]) : ResultTestPackageTotals
  (tltest-package-run-sources-from
    sources
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
  [tests-prefix : String]
  [target : String]
  [roots : cli_svec.Vec]
  [opt-level : i64]
  [backend-mode : be_state.CompilerBackendMode]
  [test-mode : TestMode]
  [backend-target : be_state.CompilerBackendTarget]
  [manifest-dir : String]
  [package-owner : String]
  [deps : compiler_load.CompilerPkgDeps]
  [file-count : i64]
  [test-count : i64]
  [failed-file-count : i64]) : ResultTestPackageTotals
  (for [index (iterator.range 0 (cli_svec.len (& sources)))]
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
              (set! file-count (+ file-count 1))
              (set! test-count (+ test-count failed-tests))
              (set! failed-file-count (+ failed-file-count 1)))
            (if (< source-tests 0)
              (return (Err (- 0 source-tests)))
              (begin
                (set!
                  file-count
                  (if (= source-tests 0)
                    file-count
                    (+ file-count 1)))
                (set! test-count (+ test-count source-tests))))))
        unit)))
  (if (= failed-file-count 0)
    (Ok file-count test-count)
    (Failed file-count test-count failed-file-count)))

(define (tltest-package-run-integration-sources
  [sources : cli_svec.Vec]
  [tests-prefix : String]
  [target : String]
  [roots : cli_svec.Vec]
  [opt-level : i64]
  [backend-mode : be_state.CompilerBackendMode]
  [test-mode : TestMode]
  [backend-target : be_state.CompilerBackendTarget]
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
  [backend-mode : be_state.CompilerBackendMode]
  [test-mode : TestMode]
  [backend-target : be_state.CompilerBackendTarget]
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

(define (tltest-package-check-entry
  [source-set : (& source-set package_source_core.PackageSourceSet)]
  [roots : (& roots cli_svec.Vec)]
  [backend-target : be_state.CompilerBackendTarget]) : i64
  (let
    [entry : TlTestEntry (tltest-entry-new)]
    [status : i64
      (in-arena
        entry.owner
        (driver.compiler-driver-reset-file-state!)
        (match (compiler_check_core.compiler-check-package-entry-file-with-roots-and-cfg
          (compiler_load.compiler-load-normalize-path
            (compiler_load.compiler-load-join-root-path
              (string.copy (& source-set.manifest-dir))
              (string.copy (& source-set.manifest.entry))))
          (cli_svec.clone-vec roots)
          (string.copy (& source-set.manifest-dir))
          (compiler_load.clone-compiler-pkg-deps (& source-set.manifest.deps))
          (match source-set.manifest.kind
            [(CompilerPkgKindBin) true]
            [(CompilerPkgKindLib) false])
          ;; Production checking uses the same target/user cfgs as `check`;
          ;; automatic `test` cfg belongs only to the following harnesses.
          (driver.compiler-driver-target-cfgs
            backend-target
            (target_cfg.compiler-target-user-cfgs (& tltest-user-cfg-slots)))
          (tc_core.tc-serial-job-state))
          [(Ok _ _ advisories)
            (driver.compiler-driver-print-advisories (& advisories))
            0]
          [(Err diagnostics advisories)
            (driver.compiler-driver-print-advisories (& advisories))
            (let
              [sources : driver.CompilerDriverDiagnosticSources
                (driver.compiler-driver-diagnostic-sources-new)]
              (for [index
                (iterator.range
                  0
                  (cdiag.compiler-diagnostic-list-count (deref diagnostics)))]
                (io.print-error
                  (driver.compiler-driver-render-source-diagnostic-from
                    (&mut sources)
                    (cdiag.compiler-diagnostic-list-get
                      (deref diagnostics)
                      index)))))
            1]))]
    (tltest-entry-finish entry status)))

(define (tltest-run-package
  [manifest-path : String]
  [has-manifest : bool]
  [target : String]
  [roots : cli_svec.Vec]
  [opt-level : i64]
  [backend-mode : be_state.CompilerBackendMode]
  [test-mode : TestMode]) : i64
  (match (build_run_core.source-tool-parse-target
    (owned_view.compiler-owned-shared-view target))
    [(Err message)
      (io.print-error message)
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
            (compiler_load.compiler-load-set-package-artifact-profile! "dev")
            (when
              (and
                (not tltest-list-only)
                (>
                  (compiler_load.compiler-pkg-dep-list-count
                    (&
                      (compiler_load.compiler-pkg-deps-list
                        (compiler_load.clone-compiler-pkg-deps
                          (& manifest.deps)))))
                  0)
                (not
                  (compiler_dependency_tlci.compiler-dependency-tlci-force-source?)))
              (match (build_run_core.source-tool-build-package-deps-only!
                (& source-set.manifest-path)
                backend-target
                (& roots)
                (& tltest-user-cfg-slots))
                [(Ok) unit]
                [(Err message)
                  (io.print-error message)
                  (return 1)]))
            (let
              [production-status : i64
                (if tltest-list-only
                  0
                  (tltest-package-check-entry
                    (& source-set)
                    (& roots)
                    backend-target))]
              (if (not (= production-status 0))
                production-status
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
                          0)])]))))])]))

(define (tltest-check-file-loaded
  [source : String]
  [decls : ast.AstDeclList]
  [paths : ast.AstDeclPathList]
  [backend-target : be_state.CompilerBackendTarget]
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
              (tltest-no-tests-check source decls paths roots backend-target)
              (tltest-check-only
                (string.copy (& source))
                (tltest-diagnostic-source source (& decls) (& paths))
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
  [backend-target : be_state.CompilerBackendTarget]) : ResultTestFileCheck
  (let
    [source-roots : cli_svec.Vec (tltest-source-roots (& source) roots)]
    [test-cfgs : sym_i64_env.SymI64Env (tltest-cfgs backend-target)]
    (match (tltest-open-stdlib-tli-for-session!
      (& source)
      true
      (driver.compiler-driver-target-cfg-from-backend backend-target)
      (& source-roots)
      test-cfgs
      1
      false)
      [(Err tli-msg)
        (compiler_load.compiler-load-tli-release!)
        (io.print-error tli-msg)
        (Err 1)]
      [(Ok)
        (let
          [result : ResultTestFileCheck
            (match (driver.compiler-driver-load-file-with-runtime
              (owned_view.compiler-owned-shared-view source)
              (owned_view.compiler-owned-shared-view source-roots)
              test-cfgs)
              [(Ok decls paths _ _)
                (tltest-check-file-loaded
                  source
                  decls
                  paths
                  backend-target
                  source-roots)]
              [(Err diag)
                (io.print-error
                  (driver.compiler-driver-render-source-diagnostic (deref diag)))
                (Err 1)])]
          (compiler_load.compiler-load-tli-release!)
          result)])))

(define (tltest-run-file-loaded
  [source : String]
  [target : String]
  [roots : cli_svec.Vec]
  [opt-level : i64]
  [backend-mode : be_state.CompilerBackendMode]
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
  [backend-mode : be_state.CompilerBackendMode]
  [backend-target : be_state.CompilerBackendTarget]) : ResultTestFileCheck
  (let
    [source-roots : cli_svec.Vec (tltest-source-roots (& source) roots)]
    [test-cfgs : sym_i64_env.SymI64Env (tltest-cfgs backend-target)]
    (match (tltest-open-stdlib-tli-for-session!
      (& source)
      true
      (driver.compiler-driver-target-cfg-from-backend backend-target)
      (& source-roots)
      test-cfgs
      opt-level
      true)
      [(Err tli-msg)
        (compiler_load.compiler-load-tli-release!)
        (io.print-error tli-msg)
        (Err 1)]
      [(Ok)
        (let
          [result : ResultTestFileCheck
            (match (driver.compiler-driver-load-file-with-runtime
              (owned_view.compiler-owned-shared-view source)
              (owned_view.compiler-owned-shared-view source-roots)
              test-cfgs)
              [(Ok decls paths _ _)
                (tltest-run-file-loaded
                  source
                  target
                  source-roots
                  opt-level
                  backend-mode
                  decls
                  paths)]
              [(Err diag)
                (io.print-error
                  (driver.compiler-driver-render-source-diagnostic (deref diag)))
                (Err 1)])]
          (compiler_load.compiler-load-tli-release!)
          result)])))

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
  [backend-target : be_state.CompilerBackendTarget]) : i64
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
  [backend-target : be_state.CompilerBackendTarget]
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
            (+= files 1)
            (+= tests entry-result)
            (+= cursor 1)))))
    (if (= status 0)
      (begin
        (io.print-format "{}" (tltest-batch-summary-line files tests))
        0)
      status)))

(define (tltest-run-batch-check-paths
  [paths : cli_svec.Vec]
  [roots : cli_svec.Vec]
  [backend-target : be_state.CompilerBackendTarget]
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
  (match (build_run_core.source-tool-parse-target
    (owned_view.compiler-owned-shared-view target))
    [(Err message)
      (io.print-error message)
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
  [backend-mode : be_state.CompilerBackendMode]
  [backend-target : be_state.CompilerBackendTarget]) : i64
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
  [backend-mode : be_state.CompilerBackendMode]
  [backend-target : be_state.CompilerBackendTarget]) : i64
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
            (+= files 1)
            (+= tests (- (- 0 entry-result) tltest-failed-count-offset))
            (+= failed-files 1)
            (+= cursor 1))
          (if (< entry-result 0)
            (begin
              (io.print-error
                (str_cat.str-cat "\ntest: batch source failed: " source))
              (io.print-error "\n")
              (set! fatal-status (- 0 entry-result)))
            (begin
              (+= files 1)
              (+= tests entry-result)
              (+= cursor 1))))))
    (if (= fatal-status 0)
      (begin
        (io.print-format
          "{}"
          (tltest-batch-run-summary-line files tests failed-files))
        (if (= failed-files 0)
          0
          1))
      fatal-status)))

(defenum InlineCombinedLoad
  (CombinedLoaded ast.AstDeclList ast.AstDeclPathList)
  (CombinedLoadErr String))

(defenum InlineCombinedCollect
  (CombinedCollect
    ast.AstDeclList
    ast.AstDeclPathList
    (__tl_dyn-array InlineTest)
    (__tl_dyn-array i64)))

(define (tltest-combined-path-absolute? [path : (& path str)]) : bool
  (let
    [n : i64 (string.string-length path)]
    (if (= n 0)
      false
      (let
        [c0 : char (string.string-ref path 0)]
        (or
          (= c0 '/')
          (= c0 '\\')
          (and (>= n 2) (= (string.string-ref path 1) ':')))))))

(define (tltest-combined-absolute-normalized
  [cwd : (& cwd str)]
  [path : (& path str)]) : String
  (let
    [norm : String (compiler_load.compiler-load-normalize-path path)]
    (if (or
      (tltest-combined-path-absolute? (& norm))
      (= (string.string-length cwd) 0))
      norm
      (compiler_load.compiler-load-normalize-path
        (& (compiler_load.compiler-load-join-root-path (string.copy cwd) norm))))))

(define (tltest-combined-path-basename-stem [norm : (& norm str)]) : String
  (let
    [n : i64 (string.string-length norm)]
    [slash : i64 -1]
    [i : i64 (- n 1)]
    (while (and (< slash 0) (>= i 0))
      (let
        [c : char (string.string-ref norm i)]
        (if (or (= c '/') (= c '\\'))
          (set! slash i)
          (-= i 1))))
    (let
      [start : i64 (+ slash 1)]
      [base : String (string.substring norm start (- n start))]
      (if (source_text.ends-with? (& base) ".tl")
        (string.substring (& base) 0 (- (string.string-length (& base)) 3))
        base))))

(define (tltest-combined-synthetic-module-name [index : i64]) : String
  (str_cat.str-cat "__tl_combined_file_mod_" (string.int->string index)))

(define (tltest-combined-canonical-module-name
  [path : (& path str)]
  [cwd : (& cwd str)]
  [roots : (& cli_svec.Vec)]
  [index : i64]
  [used-names : (&mut tltest_name_map.Map)]) : String
  (let
    [norm : String (compiler_load.compiler-load-normalize-path path)]
    [candidate : String
      (cond
        [(compiler_load.compiler-load-stdlib-import? (& norm))
          (compiler_load.compiler-load-canonical-module-id-from-path (& norm))]
        [(source_text.starts-with? (& norm) "src/tests/")
          (tltest-combined-path-basename-stem (& norm))]
        [(source_text.starts-with? (& norm) "src/")
          (let
            [suffix : String
              (string.substring
                (& norm)
                4
                (- (string.string-length (& norm)) 4))]
            (compiler_load.compiler-load-canonical-module-id-from-path
              (& suffix)))]
        [else
          (let
            [abs-norm : String
              (tltest-combined-absolute-normalized cwd (& norm))]
            [root-count : i64 (cli_svec.len roots)]
            [ridx : i64 0]
            [matched : String ""]
            (while (and
              (= (string.string-length (& matched)) 0)
              (< ridx root-count))
              (let
                [root : String (cli_svec.get roots ridx "")]
                [rnorm : String
                  (tltest-combined-absolute-normalized cwd (& root))]
                [prefix : String
                  (compiler_load.compiler-load-join-root-path
                    (string.copy (& rnorm))
                    "")]
                [plen : i64 (string.string-length (& prefix))]
                (when
                  (and
                    (> plen 0)
                    (source_text.starts-with? (& abs-norm) (& prefix)))
                  (let
                    [rel : String
                      (string.substring
                        (& abs-norm)
                        plen
                        (- (string.string-length (& abs-norm)) plen))]
                    (cond
                      [(or
                          (string.eq (& rnorm) "stdlib")
                          (source_text.ends-with? (& rnorm) "/stdlib"))
                        (set!
                          matched
                          (str_cat.str-cat
                            "stdlib."
                            (compiler_load.compiler-load-canonical-module-id-from-path
                              (& rel))))]
                      [(and
                          (or
                            (string.eq (& rnorm) "src")
                            (source_text.ends-with? (& rnorm) "/src"))
                          (source_text.starts-with? (& rel) "tests/"))
                        (set!
                          matched
                          (tltest-combined-path-basename-stem (& rel)))]
                      [else
                        (set!
                          matched
                          (compiler_load.compiler-load-canonical-module-id-from-path
                            (& rel)))]))))
              (+= ridx 1))
            matched)])]
    (if (= (string.string-length (& candidate)) 0)
      (tltest-combined-synthetic-module-name index)
      (let
        [key : i64
          (csym.compiler-symbol-name-id-key
            (ci.intern (string.copy (& candidate))))]
        (if (tltest_name_map.contains? used-names key)
          (tltest-combined-synthetic-module-name index)
          (begin
            (tltest_name_map.insert-if-absent-ref! used-names key 1)
            candidate))))))

(define (tltest-combined-effective-roots
  [paths : (& cli_svec.Vec)]
  [roots : (& cli_svec.Vec)]) : cli_svec.Vec
  (let
    [acc : cli_svec.Vec (cli_svec.clone-vec roots)]
    [count : i64 (cli_svec.len paths)]
    (for [i (iterator.range 0 count)]
      (let
        [source : String (cli_svec.get paths i "")]
        (set! acc (tltest-source-roots (& source) acc))))
    acc))

(define (tltest-combined-register-path-alias!
  [map : (&mut tltest_name_map.Map)]
  [alias : (& alias str)]
  [file-index : i64]) : unit
  (when
    (> (string.string-length alias) 0)
    (let
      [key : i64
        (csym.compiler-symbol-name-id-key (ci.intern (string.copy alias)))]
      [_inserted : bool
        (tltest_name_map.insert-if-absent-ref! map key file-index)]
      unit)))

(define (tltest-combined-target-map
  [paths : (& cli_svec.Vec)]
  [cwd : (& cwd str)]
  [roots : (& cli_svec.Vec)]) : tltest_name_map.Map
  (let
    [count : i64 (cli_svec.len paths)]
    [root-count : i64 (cli_svec.len roots)]
    [map : tltest_name_map.Map
      (tltest_name_map.with-capacity (+ (* count 4) 16))]
    (for [i (iterator.range 0 count)]
      (let
        [source : String (cli_svec.get paths i "")]
        [norm : String (compiler_load.compiler-load-normalize-path (& source))]
        [abs-norm : String (tltest-combined-absolute-normalized cwd (& norm))]
        (tltest-combined-register-path-alias! (&mut map) (& norm) i)
        (tltest-combined-register-path-alias! (&mut map) (& abs-norm) i)
        (when
          (compiler_load.compiler-load-stdlib-import? (& norm))
          (let
            [suffix : String
              (compiler_load.compiler-load-stdlib-suffix (& norm))]
            (match (compiler_load.compiler-load-resolve-stdlib-root
              (& suffix)
              roots)
              [(CompilerLoadSomePath resolved)
                (let
                  [res-norm : String
                    (compiler_load.compiler-load-normalize-path (& resolved))]
                  [res-abs : String
                    (tltest-combined-absolute-normalized cwd (& res-norm))]
                  (tltest-combined-register-path-alias!
                    (&mut map)
                    (& res-norm)
                    i)
                  (tltest-combined-register-path-alias!
                    (&mut map)
                    (& res-abs)
                    i))]
              [(CompilerLoadNoPath) unit])))
        (when
          (source_text.starts-with? (& norm) "src/")
          (let
            [suffix : String
              (string.substring
                (& norm)
                4
                (- (string.string-length (& norm)) 4))]
            (match (compiler_load.compiler-load-resolve-stdlib-root
              (& suffix)
              roots)
              [(CompilerLoadSomePath resolved)
                (let
                  [res-norm : String
                    (compiler_load.compiler-load-normalize-path (& resolved))]
                  [res-abs : String
                    (tltest-combined-absolute-normalized cwd (& res-norm))]
                  (tltest-combined-register-path-alias!
                    (&mut map)
                    (& res-norm)
                    i)
                  (tltest-combined-register-path-alias!
                    (&mut map)
                    (& res-abs)
                    i))]
              [(CompilerLoadNoPath) unit])))
        (for [ridx (iterator.range 0 root-count)]
          (let
            [root : String (cli_svec.get roots ridx "")]
            [root-norm : String
              (compiler_load.compiler-load-normalize-path (& root))]
            [rnorm : String
              (tltest-combined-absolute-normalized cwd (& root-norm))]
            [prefix : String
              (compiler_load.compiler-load-join-root-path
                (string.copy (& rnorm))
                "")]
            [plen : i64 (string.string-length (& prefix))]
            (when
              (and
                (> plen 0)
                (source_text.starts-with? (& abs-norm) (& prefix)))
              (let
                [rel : String
                  (string.substring
                    (& abs-norm)
                    plen
                    (- (string.string-length (& abs-norm)) plen))]
                [root-rel : String
                  (compiler_load.compiler-load-normalize-path
                    (&
                      (compiler_load.compiler-load-join-root-path
                        (string.copy (& root-norm))
                        (string.copy (& rel)))))]
                (tltest-combined-register-path-alias! (&mut map) (& root-rel) i)
                (cond
                  [(or
                      (string.eq (& rnorm) "stdlib")
                      (source_text.ends-with? (& rnorm) "/stdlib"))
                    (tltest-combined-register-path-alias!
                      (&mut map)
                      (& (str_cat.str-cat "stdlib/" (string.copy (& rel))))
                      i)]
                  [(or
                      (string.eq (& rnorm) "src")
                      (source_text.ends-with? (& rnorm) "/src"))
                    (tltest-combined-register-path-alias!
                      (&mut map)
                      (& (str_cat.str-cat "src/" (string.copy (& rel))))
                      i)]
                  [else unit])))))))
    map))

(define (tltest-combined-path-file-index
  [map : (& tltest_name_map.Map)]
  [cwd : (& cwd str)]
  [decl-path : (& decl-path str)]) : i64
  (let
    [norm : String (compiler_load.compiler-load-normalize-path decl-path)]
    [key : i64
      (csym.compiler-symbol-name-id-key (ci.intern (string.copy (& norm))))]
    [found : i64 (tltest_name_map.get-value-or map key -1)]
    (if (>= found 0)
      found
      (let
        [abs-norm : String (tltest-combined-absolute-normalized cwd (& norm))]
        [abs-key : i64 (csym.compiler-symbol-name-id-key (ci.intern abs-norm))]
        (tltest_name_map.get-value-or map abs-key -1)))))

(define (tltest-combined-has-duplicate-paths?
  [paths : (& cli_svec.Vec)]
  [cwd : (& cwd str)]) : bool
  (let
    [count : i64 (cli_svec.len paths)]
    [seen-paths : tltest_name_map.Map
      (tltest_name_map.with-capacity (+ count 8))]
    [dup : bool false]
    [i : i64 0]
    (while (and (not dup) (< i count))
      (let
        [source : String (cli_svec.get paths i "")]
        [abs-norm : String (tltest-combined-absolute-normalized cwd (& source))]
        [key : i64 (csym.compiler-symbol-name-id-key (ci.intern abs-norm))]
        (if (tltest_name_map.contains? (& seen-paths) key)
          (set! dup true)
          (begin
            (tltest_name_map.insert-if-absent-ref! (&mut seen-paths) key 1)
            (+= i 1)))))
    dup))

(define (tltest-combined-seen-held-by-other?
  [seen : (& sym_i64_env.SymI64Env)]
  [target-map : (& tltest_name_map.Map)]
  [cwd : (& cwd str)]
  [module-id : i64]
  [file-index : i64]) : bool
  (let
    [holder : i64 (sym_i64_env.sym-i64-lookup-id-or seen module-id -1)]
    (cond
      [(< holder 0) false]
      [(<= holder 1) true]
      [else
        (let
          [holder-path : String (ci.intern-str holder)]
          (not
            (=
              (tltest-combined-path-file-index target-map cwd (& holder-path))
              file-index)))])))

(define (tltest-combined-load-collided?
  [seen-before : (& sym_i64_env.SymI64Env)]
  [target-map : (& tltest_name_map.Map)]
  [cwd : (& cwd str)]
  [mod-id : i64]
  [file-decls : (& ast.AstDeclList)]
  [file-modules : (& ast.AstDeclModuleList)]
  [file-index : i64]) : bool
  (let
    [decl-len : i64 (ast.ast-decl-list-len file-decls)]
    (cond
      [(= decl-len 0)
        (tltest-combined-seen-held-by-other?
          seen-before
          target-map
          cwd
          mod-id
          file-index)]
      [(and (= decl-len 1) (= (ast.ast-decl-module-list-len file-modules) 1))
        (let
          [loaded-mod-id : i64
            (ast.ast-decl-module-list-get-id file-modules 0 -1)]
          (and
            (>= loaded-mod-id 0)
            (tltest-combined-seen-held-by-other?
              seen-before
              target-map
              cwd
              loaded-mod-id
              file-index)))]
      [else false])))

(define (tltest-combined-push-decls!
  [dst-decls : (&mut ast.AstDeclList)]
  [dst-paths : (&mut ast.AstDeclPathList)]
  [src-decls : ast.AstDeclList]
  [src-paths : ast.AstDeclPathList]) : unit
  (let
    [cur-decls : ast.AstDeclList src-decls]
    [cur-paths : ast.AstDeclPathList src-paths]
    [done : bool false]
    (while (not done)
      (match (ast.ast-decl-list-step cur-decls)
        [(Nil) (set! done true)]
        [(Cons decl rest-decls)
          (let
            [decl-owner-id : i64
              (ast.ast-decl-path-list-owner-id
                (& cur-paths)
                0
                cbi.compiler-builtin-id-fix-empty)]
            [decl-prov-id : i64
              (ast.ast-decl-path-list-provenance-id
                (& cur-paths)
                0
                decl-owner-id)]
            (match (ast.ast-decl-path-list-step cur-paths)
              [(Cons decl-path rest-paths)
                (ast.ast-decl-list-push dst-decls decl)
                (ast.ast-decl-path-list-push-with-owner-and-provenance-id
                  dst-paths
                  decl-path
                  decl-owner-id
                  decl-prov-id)
                (set! cur-paths rest-paths)]
              [(Nil)
                (ast.ast-decl-list-push dst-decls decl)
                (ast.ast-decl-path-list-push-with-owner-and-provenance-id
                  dst-paths
                  ""
                  decl-owner-id
                  decl-prov-id)
                (set! cur-paths (ast.ast-decl-path-list-new))]))
          (set! cur-decls rest-decls)]))))

(define (tltest-combined-load
  [paths : (& cli_svec.Vec)]
  [cwd : (& cwd str)]
  [effective-roots : (& cli_svec.Vec)]
  [target-map : (& tltest_name_map.Map)]
  [cfgs : sym_i64_env.SymI64Env]) : InlineCombinedLoad
  (if (tltest-combined-has-duplicate-paths? paths cwd)
    (CombinedLoadErr "duplicate batch path")
    (match (driver.compiler-driver-load-runtime-prelude-and-profile-state
      (cli_svec.clone-vec effective-roots)
      cfgs
      (profile_state.compiler-profile-state-new))
      [(Err _) (CombinedLoadErr "prelude load failed")]
      [(Ok prelude-decls prelude-paths _ prelude-seen)
        (let
          [acc-decls : ast.AstDeclList (ast.ast-decl-list-new)]
          [acc-paths : ast.AstDeclPathList (ast.ast-decl-path-list-new)]
          [seen : sym_i64_env.SymI64Env prelude-seen]
          [count : i64 (cli_svec.len paths)]
          [used-names : tltest_name_map.Map
            (tltest_name_map.with-capacity (+ count 16))]
          [err-msg : String ""]
          (tltest-combined-push-decls!
            (&mut acc-decls)
            (&mut acc-paths)
            prelude-decls
            prelude-paths)
          ;; Hold surface-summary load depth > 0 across all files in the combined
          ;; chunk so later files do not reset earlier modules' surface summaries
          ;; or miss cross-file import deduplication.
          ;;
          ;; Load paths[1..count-1] first in their canonical named modules, then
          ;; load paths[0] last. If paths[0] is not a stdlib module and was not
          ;; already imported by paths[1..count-1], load it in the root module
          ;; (matching single-file entry semantics, which preserves cross-module
          ;; macro type-name resolution for the chunk's primary test suite).
          (compiler_load.compiler-load-surface-summary-load-enter!)
          (let
            [cursor : i64 1]
            (while (and
              (= (string.string-length (& err-msg)) 0)
              (< cursor count))
              (let
                [source : String (cli_svec.get paths cursor "")]
                [mod-name : String
                  (tltest-combined-canonical-module-name
                    (& source)
                    cwd
                    effective-roots
                    cursor
                    (&mut used-names))]
                [mod-id : i64
                  (compiler_load.compiler-load-parse-context-name-id
                    (& mod-name))]
                (match (compiler_load.compiler-load-file-with-paths-and-roots-expect-cfg-fallback
                  (& source)
                  seen
                  effective-roots
                  (No)
                  cfgs
                  (string.copy (& mod-name))
                  (& mod-name))
                  [(Ok file-decls file-paths file-modules next-seen)
                    (if (tltest-combined-load-collided?
                      (& seen)
                      target-map
                      cwd
                      mod-id
                      (& file-decls)
                      (& file-modules)
                      cursor)
                      (set!
                        err-msg
                        (str_cat.str-cat "module collision for " source))
                      (begin
                        (tltest-combined-push-decls!
                          (&mut acc-decls)
                          (&mut acc-paths)
                          file-decls
                          file-paths)
                        (set! seen next-seen)
                        (+= cursor 1)))]
                  [(Err _)
                    (set! err-msg (str_cat.str-cat "load failed for " source))]))))
          (when
            (and (= (string.string-length (& err-msg)) 0) (> count 0))
            (let
              [source0 : String (cli_svec.get paths 0 "")]
              [norm0 : String
                (compiler_load.compiler-load-normalize-path (& source0))]
              [mod-name0 : String
                (tltest-combined-canonical-module-name
                  (& source0)
                  cwd
                  effective-roots
                  0
                  (&mut used-names))]
              [mod-id0 : i64
                (compiler_load.compiler-load-parse-context-name-id
                  (& mod-name0))]
              [already-seen? : bool
                (compiler_load.compiler-load-seen-module-contains?
                  seen
                  (& mod-name0)
                  mod-id0)]
              [use-root-module? : bool
                (and
                  (not already-seen?)
                  (not (compiler_load.compiler-load-stdlib-import? (& norm0))))]
              [source-mod-fallback0 : String
                (if use-root-module?
                  ""
                  (string.copy (& mod-name0)))]
              (when
                use-root-module?
                (ast.ast-decl-list-push
                  (&mut acc-decls)
                  (ast.ast-decl-module-id (tltest-empty-name-id)))
                (ast.ast-decl-path-list-push-with-owner-and-provenance-id
                  (&mut acc-paths)
                  (string.copy (& source0))
                  cbi.compiler-builtin-id-fix-empty
                  (compiler_load.compiler-load-source-path-id (& source0))))
              (match (compiler_load.compiler-load-file-with-paths-and-roots-expect-cfg-fallback
                (& source0)
                seen
                effective-roots
                (No)
                cfgs
                (string.copy (& mod-name0))
                (& source-mod-fallback0))
                [(Ok file-decls file-paths file-modules next-seen)
                  (if (tltest-combined-load-collided?
                    (& seen)
                    target-map
                    cwd
                    mod-id0
                    (& file-decls)
                    (& file-modules)
                    0)
                    (set!
                      err-msg
                      (str_cat.str-cat "module collision for " source0))
                    (begin
                      (tltest-combined-push-decls!
                        (&mut acc-decls)
                        (&mut acc-paths)
                        file-decls
                        file-paths)
                      (set! seen next-seen)))]
                [(Err _)
                  (set! err-msg (str_cat.str-cat "load failed for " source0))])))
          (compiler_load.compiler-load-surface-summary-load-exit!)
          (if (= (string.string-length (& err-msg)) 0)
            (CombinedLoaded acc-decls acc-paths)
            (CombinedLoadErr err-msg)))])))

(define (tltest-combined-decl-kind [decl : (& ast.AstDecl)]) : i64
  (match decl
    [(Test _ _ _ _) 0]
    [(Module _) 1]
    [(or (IncludeStr _ _) (IncludeStrComptime _ _) (IncludeStrLzss _ _)
         (IncludeBin _ _))
      2]
    [_
      (if (tltest-main-decl? decl)
        2
        3)]))

(define (tltest-combined-module-id-ref
  [decl : (& ast.AstDecl)]
  [fallback : i64]) : i64
  (match decl
    [(Module name) name]
    [_ fallback]))

(define (tltest-collect-combined
  [target-map : (& tltest_name_map.Map)]
  [cwd : (& cwd str)]
  [decls : ast.AstDeclList]
  [paths : ast.AstDeclPathList]) : InlineCombinedCollect
  (let
    [cur-decls : ast.AstDeclList decls]
    [cur-paths : ast.AstDeclPathList paths]
    [runtime-decls-out : ast.AstDeclList (ast.ast-decl-list-new)]
    [runtime-paths-out : ast.AstDeclPathList (ast.ast-decl-path-list-new)]
    [test-items : (__tl_dyn-array InlineTest) (__tl_make-array InlineTest 0)]
    [test-file-indices : (__tl_dyn-array i64) (__tl_make-array i64 0)]
    [current-module : i64 (tltest-empty-name-id)]
    [done : bool false]
    (while (not done)
      (match (ast.ast-decl-list-step cur-decls)
        [(Nil) (set! done true)]
        [(Cons decl rest-decls)
          (let
            [decl-owner-id : i64
              (ast.ast-decl-path-list-owner-id (& cur-paths) 0 current-module)]
            [decl-prov-id : i64
              (ast.ast-decl-path-list-provenance-id
                (& cur-paths)
                0
                decl-owner-id)]
            [decl-path : String ""]
            (match (ast.ast-decl-path-list-step cur-paths)
              [(Cons path path-rest)
                (set! decl-path path)
                (set! cur-paths path-rest)]
              [(Nil) (set! cur-paths (ast.ast-decl-path-list-new))])
            (let
              [kind : i64 (tltest-combined-decl-kind (& decl))]
              (cond
                [(= kind 0)
                  (match decl
                    [(Test name body-box metadata span)
                      (let
                        [file-idx : i64
                          (tltest-combined-path-file-index
                            target-map
                            cwd
                            (& decl-path))]
                        (when
                          (and
                            (>= file-idx 0)
                            (tltest-test-name-selected? (ci.intern-str name)))
                          (let
                            [test-count : i64 (array-length test-items)]
                            [private-name : String
                              (tltest-private-name test-count)]
                            [private-id : i64
                              (ci.intern-generated-name (& private-name))]
                            (__tl_array-push!
                              test-items
                              (Case
                                (ci.intern-str name)
                                decl-path
                                current-module
                                decl-prov-id
                                (tltest-source-line span)
                                body-box
                                private-name
                                private-id
                                (tltest-private-call-id
                                  current-module
                                  private-id)
                                (tltest-test-selection metadata)))
                            (__tl_array-push! test-file-indices file-idx))))]
                    [_ unit])]
                [(= kind 1)
                  (set!
                    current-module
                    (tltest-combined-module-id-ref (& decl) current-module))
                  (ast.ast-decl-list-push (&mut runtime-decls-out) decl)
                  (ast.ast-decl-path-list-push-with-owner-and-provenance-id
                    (&mut runtime-paths-out)
                    decl-path
                    decl-owner-id
                    decl-prov-id)]
                [(= kind 2) unit]
                [else
                  (ast.ast-decl-list-push (&mut runtime-decls-out) decl)
                  (ast.ast-decl-path-list-push-with-owner-and-provenance-id
                    (&mut runtime-paths-out)
                    decl-path
                    decl-owner-id
                    decl-prov-id)])))
          (set! cur-decls rest-decls)]))
    (CombinedCollect
      runtime-decls-out
      runtime-paths-out
      test-items
      test-file-indices)))

(define (tltest-combined-file-runner-id [file-index : i64]) : i64
  (ci.intern-generated-name
    (& (str_cat.str-cat "__tl_inline_file_" (string.int->string file-index)))))

(define (tltest-combined-parse-index-decl [parse-fn-id : i64]) : ast.AstDecl
  (let
    [p-id : i64 (ci.intern-generated-name "__tl_comb_p")]
    [idx-id : i64 (ci.intern-generated-name "__tl_comb_idx")]
    [acc-id : i64 (ci.intern-generated-name "__tl_comb_acc")]
    [done-id : i64 (ci.intern-generated-name "__tl_comb_done")]
    [bad-id : i64 (ci.intern-generated-name "__tl_comb_bad")]
    [b-id : i64 (ci.intern-generated-name "__tl_comb_b")]
    [u8-ptr-ty : ast.AstType
      (ast.AstType.Ptr (ast.ty-node-push (& (ast.AstType.U8))))]
    [read-argv1 : i64
      (ast.ast-node-push
        (Unsafe
          (ast.ast-expr-cons
            (ast.ast-expr-ptr-read
              (ast.ast-expr-ptr-offset
                (ast.ast-node-push (ProgramArgv))
                (ast.ast-node-push (Literal (ast.ast-lit-int 1)))))
            (& (ast.ast-expr-list-new)))))]
    [read-byte : i64
      (ast.ast-node-push
        (Unsafe
          (ast.ast-expr-cons
            (ast.ast-expr-ptr-read
              (ast.ast-expr-ptr-offset
                (ast.ast-node-push (Var p-id))
                (ast.ast-node-push (Var idx-id))))
            (& (ast.ast-expr-list-new)))))]
    [digit-cond : i64
      (ast.ast-expr-binary
        (And)
        (ast.ast-expr-binary
          (Ge)
          (ast.ast-expr-cast (ast.ast-node-push (Var b-id)) (& (I64)))
          (ast.ast-node-push (Literal (ast.ast-lit-int 48))))
        (ast.ast-expr-binary
          (Le)
          (ast.ast-expr-cast (ast.ast-node-push (Var b-id)) (& (I64)))
          (ast.ast-node-push (Literal (ast.ast-lit-int 57)))))]
    [digit-step : i64
      (ast.ast-node-push
        (Begin
          (ast.ast-expr-cons
            (ast.ast-expr-set-id
              acc-id
              (ast.ast-expr-binary
                (Add)
                (ast.ast-expr-binary
                  (Mul)
                  (ast.ast-node-push (Var acc-id))
                  (ast.ast-node-push (Literal (ast.ast-lit-int 10))))
                (ast.ast-expr-binary
                  (Sub)
                  (ast.ast-expr-cast (ast.ast-node-push (Var b-id)) (& (I64)))
                  (ast.ast-node-push (Literal (ast.ast-lit-int 48))))))
            (&
              (ast.ast-expr-cons
                (ast.ast-expr-set-id
                  idx-id
                  (ast.ast-expr-binary
                    (Add)
                    (ast.ast-node-push (Var idx-id))
                    (ast.ast-node-push (Literal (ast.ast-lit-int 1)))))
                (& (ast.ast-expr-list-new)))))))]
    [bad-step : i64
      (ast.ast-node-push
        (Begin
          (ast.ast-expr-cons
            (ast.ast-expr-set-id
              bad-id
              (ast.ast-node-push (Literal (Bool true))))
            (&
              (ast.ast-expr-cons
                (ast.ast-expr-set-id
                  done-id
                  (ast.ast-node-push (Literal (Bool true))))
                (& (ast.ast-expr-list-new)))))))]
    [loop-body : i64
      (ast.ast-expr-let
        (ast.ast-let-binding-cons
          (& (ast.ast-let-binding-id b-id (Some (U8)) read-byte))
          (& (ast.ast-let-binding-list-new)))
        (ast.ast-expr-if
          (ast.ast-expr-binary
            (Eq)
            (ast.ast-node-push (Var b-id))
            (ast.ast-expr-cast
              (ast.ast-node-push (Literal (ast.ast-lit-int 0)))
              (& (U8))))
          (ast.ast-expr-set-id
            done-id
            (ast.ast-node-push (Literal (Bool true))))
          (ast.ast-expr-if digit-cond digit-step bad-step)))]
    [loop-expr : i64
      (ast.ast-node-push
        (While
          (ast.ast-expr-binary
            (Eq)
            (ast.ast-node-push (Var done-id))
            (ast.ast-node-push (Literal (Bool false))))
          (ast.ast-expr-cons loop-body (& (ast.ast-expr-list-new)))))]
    [result-expr : i64
      (ast.ast-expr-if
        (ast.ast-expr-binary
          (Or)
          (ast.ast-node-push (Var bad-id))
          (ast.ast-expr-binary
            (Eq)
            (ast.ast-node-push (Var idx-id))
            (ast.ast-node-push (Literal (ast.ast-lit-int 0)))))
        (ast.ast-node-push (Literal (ast.ast-lit-int -1)))
        (ast.ast-node-push (Var acc-id)))]
    [parse-body : i64
      (ast.ast-expr-if
        (ast.ast-expr-binary
          (Lt)
          (ast.ast-node-push (ProgramArgc))
          (ast.ast-node-push (Literal (ast.ast-lit-int 2))))
        (ast.ast-node-push (Literal (ast.ast-lit-int -1)))
        (ast.ast-expr-let
          (ast.ast-let-binding-cons
            (& (ast.ast-let-binding-id p-id (Some u8-ptr-ty) read-argv1))
            (&
              (ast.ast-let-binding-cons
                (&
                  (ast.ast-let-binding-id
                    idx-id
                    (Some (I64))
                    (ast.ast-node-push (Literal (ast.ast-lit-int 0)))))
                (&
                  (ast.ast-let-binding-cons
                    (&
                      (ast.ast-let-binding-id
                        acc-id
                        (Some (I64))
                        (ast.ast-node-push (Literal (ast.ast-lit-int 0)))))
                    (&
                      (ast.ast-let-binding-cons
                        (&
                          (ast.ast-let-binding-id
                            done-id
                            (Some (Bool))
                            (ast.ast-node-push (Literal (Bool false)))))
                        (&
                          (ast.ast-let-binding-cons
                            (&
                              (ast.ast-let-binding-id
                                bad-id
                                (Some (Bool))
                                (ast.ast-node-push (Literal (Bool false)))))
                            (& (ast.ast-let-binding-list-new)))))))))))
          (ast.ast-node-push
            (Begin
              (ast.ast-expr-cons
                loop-expr
                (& (ast.ast-expr-cons result-expr (& (ast.ast-expr-list-new)))))))))]
    (ast.ast-decl-def-fn-id
      parse-fn-id
      (ast.ast-param-list-new)
      (I64)
      parse-body)))

(define (tltest-combined-dispatch-tree
  [sel-id : i64]
  [runner-ids : (& (__tl_dyn-array i64))]
  [lo : i64]
  [hi : i64]) : i64
  (if (>= lo hi)
    (ast.ast-node-push (Literal (ast.ast-lit-int 2)))
    (if (= (+ lo 1) hi)
      (ast.ast-expr-if
        (ast.ast-expr-binary
          (Eq)
          (ast.ast-node-push (Var sel-id))
          (ast.ast-node-push (Literal (ast.ast-lit-int lo))))
        (tltest-call-expr-id (array-ref runner-ids lo))
        (ast.ast-node-push (Literal (ast.ast-lit-int 2))))
      (let
        [mid : i64 (+ lo (/ (- hi lo) 2))]
        (ast.ast-expr-if
          (ast.ast-expr-binary
            (Lt)
            (ast.ast-node-push (Var sel-id))
            (ast.ast-node-push (Literal (ast.ast-lit-int mid))))
          (tltest-combined-dispatch-tree sel-id runner-ids lo mid)
          (tltest-combined-dispatch-tree sel-id runner-ids mid hi))))))

(define (tltest-combined-main-decl
  [parse-fn-id : i64]
  [runner-ids : (& (__tl_dyn-array i64))]
  [file-count : i64]) : ast.AstDecl
  (let
    [sel-id : i64 (ci.intern-generated-name "__tl_comb_sel")]
    (ast.ast-decl-def-fn-id
      (tltest-main-id)
      (ast.ast-param-list-new)
      (I64)
      (ast.ast-expr-let
        (ast.ast-let-binding-cons
          (&
            (ast.ast-let-binding-id
              sel-id
              (Some (I64))
              (tltest-call-expr-id parse-fn-id)))
          (& (ast.ast-let-binding-list-new)))
        (tltest-combined-dispatch-tree sel-id runner-ids 0 file-count)))))

(define (tltest-combined-compile-in-entry
  [paths : (& cli_svec.Vec)]
  [roots : (& cli_svec.Vec)]
  [files : (& build_run_core.SourceToolTempFiles)]
  [file-counts : (&mut (__tl_dyn-array i64))]
  [opt-level : i64]
  [backend-mode : be_state.CompilerBackendMode]
  [backend-target : be_state.CompilerBackendTarget]) : i64
  (let
    [file-count : i64 (cli_svec.len paths)]
    [cwd : String (fs.current-dir)]
    [effective-roots : cli_svec.Vec
      (tltest-combined-effective-roots paths roots)]
    [cfgs : sym_i64_env.SymI64Env (tltest-cfgs backend-target)]
    [first-source : String (cli_svec.get paths 0 "")]
    [allow-prebuilt : bool (not (tltest-any-stdlib-source-path? paths))]
    [target-map : tltest_name_map.Map
      (tltest-combined-target-map paths (& cwd) (& effective-roots))]
    (match (tltest-open-stdlib-tli-for-session!
      (& first-source)
      allow-prebuilt
      (driver.compiler-driver-target-cfg-from-backend backend-target)
      (& effective-roots)
      cfgs
      opt-level
      true)
      [(Err tli-msg)
        (compiler_load.compiler-load-tli-release!)
        (io.print-error tli-msg)
        4]
      [(Ok)
        (let
          [compile-status : i64
            (match (tltest-combined-load
              paths
              (& cwd)
              (& effective-roots)
              (& target-map)
              cfgs)
              [(CombinedLoadErr _) 1]
              [(CombinedLoaded loaded-decls loaded-paths)
                (match (tltest-collect-combined
                  (& target-map)
                  (& cwd)
                  loaded-decls
                  loaded-paths)
                  [(CombinedCollect
                      runtime-decls
                      runtime-paths
                      all-tests
                      test-file-indices)
                    (let
                      [total-tests : i64 (array-length all-tests)]
                      [dropped-tests? : bool
                        (let
                          [dropped : bool false]
                          [f : i64 0]
                          (for [j (iterator.range 0 file-count)]
                            (set! (array-ref file-counts j) 0))
                          (for [t (iterator.range 0 total-tests)]
                            (let
                              [idx : i64 (array-ref test-file-indices t)]
                              (when
                                (and (>= idx 0) (< idx file-count))
                                (set!
                                  (array-ref file-counts idx)
                                  (+ (array-ref file-counts idx) 1)))))
                          (unless
                            (tltest-selection-set?)
                            (while (and (not dropped) (< f file-count))
                              (when
                                (= (array-ref file-counts f) 0)
                                (let
                                  [file-source : String
                                    (cli_svec.get paths f "")]
                                  (when
                                    (and
                                      (io.file-exists?
                                        (string.copy (& file-source)))
                                      (tltest-source-has-inline-tests?
                                        file-source))
                                    (set! dropped true))))
                              (+= f 1)))
                          dropped)]
                      (if dropped-tests?
                        1
                        (let
                          [session : cis.InternStructuralSessionHandle
                            (tltest-active-structural-session)]
                          [reachable : tltest_name_map.Map
                            (tltest-reachable-names
                              session
                              (& runtime-decls)
                              (& all-tests))]
                          (match (tltest-prune-runtime-decls-in
                            session
                            runtime-decls
                            runtime-paths
                            ""
                            true
                            (& reachable)
                            (ast.ast-decl-list-new)
                            (ast.ast-decl-path-list-new))
                            [(Decls out-decls out-paths)
                              (let
                                [harness-decls : ast.AstDeclList out-decls]
                                [harness-paths : ast.AstDeclPathList out-paths]
                                [parse-fn-id : i64
                                  (ci.intern-generated-name
                                    "__tl_test_parse_index")]
                                [runner-ids : (__tl_dyn-array i64)
                                  (__tl_make-array i64 file-count)]
                                [harness-path : String
                                  "<combined test harness>"]
                                ;; Emit every collected inline test function in its owning module.
                                (for [t (iterator.range 0 total-tests)]
                                  (let
                                    [test : InlineTest
                                      (clone-inline-test
                                        (& (array-ref all-tests t)))]
                                    (match test
                                      [(Case
                                        _
                                        path
                                        module-id
                                        provenance-id
                                        _
                                        body
                                        _
                                        private-id
                                        _
                                        _)
                                        (ast.ast-decl-list-push
                                          (&mut harness-decls)
                                          (ast.ast-decl-module-id module-id))
                                        (ast.ast-decl-path-list-push-with-owner-and-provenance-id
                                          (&mut harness-paths)
                                          (string.copy (& path))
                                          module-id
                                          provenance-id)
                                        (ast.ast-decl-list-push
                                          (&mut harness-decls)
                                          (ast.ast-decl-def-fn-id
                                            private-id
                                            (ast.ast-param-list-new)
                                            (Unit)
                                            body))
                                        (ast.ast-decl-path-list-push-with-owner-and-provenance-id
                                          (&mut harness-paths)
                                          path
                                          module-id
                                          provenance-id)])))
                                ;; Switch to root module and import stdlib.runtime for suite helpers.
                                (ast.ast-decl-list-push
                                  (&mut harness-decls)
                                  (ast.ast-decl-module-id
                                    (tltest-empty-name-id)))
                                (ast.ast-decl-path-list-push-with-owner-and-provenance-id
                                  (&mut harness-paths)
                                  (string.copy (& harness-path))
                                  cbi.compiler-builtin-id-fix-empty
                                  (tltest-generated-harness-provenance-id))
                                (ast.ast-decl-list-push
                                  (&mut harness-decls)
                                  (Import
                                    (ast.ast-decl-meta-runtime-with-aggregate-markers
                                      0)
                                    (Spec
                                      (Module)
                                      "stdlib.runtime"
                                      (Some
                                        cbi.compiler-builtin-id-runtime-module)
                                      (Some (tltest-runtime-import-alias-id))
                                      (box (ast.ast-decl-span-fallback)))))
                                (ast.ast-decl-path-list-push-with-owner-and-provenance-id
                                  (&mut harness-paths)
                                  (string.copy (& harness-path))
                                  cbi.compiler-builtin-id-fix-empty
                                  (tltest-generated-harness-provenance-id))
                                ;; Emit one runner function per file in the batch.
                                (for [f (iterator.range 0 file-count)]
                                  (let
                                    [file-tests : (__tl_dyn-array InlineTest)
                                      (__tl_make-array InlineTest 0)]
                                    [file-source : String
                                      (cli_svec.get paths f "")]
                                    (for [t (iterator.range 0 total-tests)]
                                      (when
                                        (= (array-ref test-file-indices t) f)
                                        (__tl_array-push!
                                          file-tests
                                          (clone-inline-test
                                            (& (array-ref all-tests t))))))
                                    (tltest-shuffle-tests! (&mut file-tests))
                                    (set!
                                      (array-ref file-counts f)
                                      (array-length file-tests))
                                    (let
                                      [runner-id : i64
                                        (tltest-combined-file-runner-id f)]
                                      (set! (array-ref runner-ids f) runner-id)
                                      (ast.ast-decl-list-push
                                        (&mut harness-decls)
                                        (ast.ast-decl-def-fn-id
                                          runner-id
                                          (ast.ast-param-list-new)
                                          (I64)
                                          (ast.ast-node-push
                                            (Begin
                                              (tltest-main-exprs (& file-tests)))))))
                                    (ast.ast-decl-path-list-push-with-owner-and-provenance-id
                                      (&mut harness-paths)
                                      file-source
                                      cbi.compiler-builtin-id-fix-empty
                                      (tltest-generated-harness-provenance-id))))
                                ;; Emit argv index parser and dispatched main.
                                (ast.ast-decl-list-push
                                  (&mut harness-decls)
                                  (tltest-combined-parse-index-decl parse-fn-id))
                                (ast.ast-decl-path-list-push-with-owner-and-provenance-id
                                  (&mut harness-paths)
                                  (string.copy (& harness-path))
                                  cbi.compiler-builtin-id-fix-empty
                                  (tltest-generated-harness-provenance-id))
                                (ast.ast-decl-list-push
                                  (&mut harness-decls)
                                  (tltest-combined-main-decl
                                    parse-fn-id
                                    (& runner-ids)
                                    file-count))
                                (ast.ast-decl-path-list-push-with-owner-and-provenance-id
                                  (&mut harness-paths)
                                  (string.copy (& harness-path))
                                  cbi.compiler-builtin-id-fix-empty
                                  (tltest-generated-harness-provenance-id))
                                (let
                                  [full-program : ast.AstProgram
                                    (tltest-program-with-print-runtime
                                      (ast.ast-program harness-decls)
                                      backend-target)]
                                  [full-paths : ast.AstDeclPathList
                                    (tltest-paths-with-print-runtime
                                      backend-target
                                      harness-paths)]
                                  [lower-state : lower.CompilerLowerState
                                    (lower.compiler-lower-state-new)]
                                  [legacy-roots : cli_svec.Vec
                                    (cli_svec.clone-vec (& effective-roots))]
                                  [first-source : String
                                    (cli_svec.get paths 0 "")]
                                  [status : i64
                                    (match (lower.lower-compiler-program-with-decl-paths-mode-cache-and-state
                                      lower-state
                                      (string.copy (& first-source))
                                      full-program
                                      full-paths
                                      (tltest-harness-lower-mode
                                        backend-target
                                        backend-mode)
                                      (cli_svec.clone-vec (& legacy-roots))
                                      cfgs
                                      (compiler_typecheck_api.compiler-typecheck-prefix-cache-scope
                                        "typecheck-prefix-test-cli"
                                        legacy-roots
                                        cfgs))
                                      [(Err diag)
                                        (io.print-error
                                          (str_cat.str-cat
                                            "test: --combined diagnostic: "
                                            (driver.compiler-driver-render-source-diagnostic
                                              (deref diag))
                                            "\n"))
                                        2]
                                      [(Ok ir spans lowered-state)
                                        (let
                                          [hydrated-ir : ir.CompilerIrProgram
                                            (tltest-hydrate-and-finish-tli-serial!
                                              ir
                                              opt-level)]
                                          [link-inputs : build_run_core.SourceToolLinkInputs
                                            (build_run_core.source-tool-link-inputs-with-hydrated-archives
                                              (build_run_core.source-tool-link-inputs-empty))]
                                          (match (build_run_core.source-tool-link-program
                                            (build_run_core.SourceToolLinkRequest
                                              (string.copy (& first-source))
                                              (Lowered
                                                hydrated-ir
                                                spans
                                                lowered-state)
                                              backend-target
                                              opt-level
                                              backend-mode
                                              link-inputs
                                              (build_run_core.SourceToolTempFiles
                                                (string.copy (& files.dir))
                                                (string.copy (& files.asm))
                                                (string.copy (& files.obj))
                                                (string.copy (& files.bin)))
                                              "test: failed to write assembly artifact"))
                                            [(Ok) 0]
                                            [(Err msg)
                                              (io.print-error
                                                (str_cat.str-cat
                                                  "test: --combined link error: "
                                                  msg
                                                  "\n"))
                                              3]))])]
                                  (lower.compiler-lower-state-reset!
                                    lower-state)
                                  (lower.compiler-lower-arena-state-release!
                                    (lower.compiler-lower-state-arenas
                                      lower-state))
                                  status))]))))])])]
          (compiler_load.compiler-load-tli-release!)
          compile-status)])))

(define (tltest-combined-failure-label [code : i64]) : String
  (cond
    [(= code 1) "load failed"]
    [(= code 2) "typecheck/lower failed"]
    [(= code 3) "assemble/link failed"]
    [else "harness compile failed"]))

(define (tltest-run-batch-run-paths-combined
  [paths : cli_svec.Vec]
  [target : String]
  [roots : cli_svec.Vec]
  [opt-level : i64]
  [backend-mode : be_state.CompilerBackendMode]
  [backend-target : be_state.CompilerBackendTarget]) : i64
  (let
    [count : i64 (cli_svec.len (& paths))]
    (if (<= count 1)
      (tltest-run-batch-run-paths
        paths
        target
        roots
        opt-level
        backend-mode
        backend-target)
      (match (build_run_core.source-tool-create-temp-dir
        "typelisp-test-combined")
        [(Err message)
          (io.print-error
            (str_cat.str-cat "test: failed to create temp dir: " message "\n"))
          1]
        [(Ok temp-dir)
          (let
            [files : build_run_core.SourceToolTempFiles
              (build_run_core.source-tool-temp-files
                temp-dir
                "combined_harness.tl"
                backend-target)]
            [file-counts : (__tl_dyn-array i64) (__tl_make-array i64 count)]
            [entry : TlTestEntry (tltest-entry-new)]
            [entry-result : i64
              (in-arena
                entry.owner
                (tltest-combined-compile-in-entry
                  (& paths)
                  (& roots)
                  (& files)
                  (&mut file-counts)
                  opt-level
                  backend-mode
                  backend-target))]
            [compile-status : i64 (tltest-entry-finish entry entry-result)]
            (if (= compile-status 4)
              (begin
                (build_run_core.source-tool-clean-temp-files files true)
                (driver.compiler-driver-reset-file-state!)
                1)
              (if (not (= compile-status 0))
                (begin
                  (build_run_core.source-tool-clean-temp-files files true)
                  (driver.compiler-driver-reset-file-state!)
                  (io.print-error
                    (str_cat.str-cat
                      "test: --combined fallback to single-file mode ("
                      (tltest-combined-failure-label compile-status)
                      ")\n"))
                  (tltest-run-batch-run-paths
                    paths
                    target
                    roots
                    opt-level
                    backend-mode
                    backend-target))
                (let
                  [cursor : i64 0]
                  [ran-files : i64 0]
                  [ran-tests : i64 0]
                  [failed-files : i64 0]
                  [fatal-status : i64 0]
                  [preserve-artifacts : bool false]
                  (while (and (= fatal-status 0) (< cursor count))
                    (let
                      [source : String (cli_svec.get (& paths) cursor "")]
                      [file-test-count : i64 (array-ref file-counts cursor)]
                      (io.print-format
                        "{}"
                        (tltest-package-source-line
                          (string.copy (& source))
                          file-test-count))
                      (let
                        [command : process.ProcessCommand
                          (build_run_core.source-tool-command-for-target
                            backend-target
                            (process.command-with-env-list
                              (process.command
                                (string.copy (& files.bin))
                                (process.args-single
                                  (string.int->string cursor)))
                              (if (tltest-stdlib-env-fixture-source?
                                (string.copy (& source)))
                                (tltest-stdlib-env-fixture-env backend-target)
                                (process.env-empty))))]
                        (match (process.output command)
                          [(OkProcessOutput output)
                            (let
                              [status : i64 (process.output-status output)]
                              (build_run_core.source-tool-forward-output output)
                              (cond
                                [(= status 0)
                                  (+= ran-files 1)
                                  (+= ran-tests file-test-count)
                                  (+= cursor 1)]
                                [(and (> file-test-count 0) (= status 1))
                                  (+= ran-files 1)
                                  (+= ran-tests file-test-count)
                                  (+= failed-files 1)
                                  (+= cursor 1)]
                                [else
                                  (tltest-report-child-status output)
                                  (io.print-error
                                    (str_cat.str-cat
                                      "\ntest: batch source failed: "
                                      source
                                      "\n"))
                                  (set! fatal-status 2)]))]
                          [(ErrProcessOutput error)
                            (set! preserve-artifacts true)
                            (io.print-error
                              (tltest-run-executable-error-message
                                (string.copy (& files.bin))
                                (string.copy (& files.dir))
                                error))
                            (io.print-error
                              (str_cat.str-cat
                                "\ntest: batch source failed: "
                                source
                                "\n"))
                            (set! fatal-status 2)]))))
                  (unless
                    preserve-artifacts
                    (build_run_core.source-tool-clean-temp-files files true))
                  (if (= fatal-status 0)
                    (begin
                      (io.print-format
                        "{}"
                        (tltest-batch-run-summary-line
                          ran-files
                          ran-tests
                          failed-files))
                      (if (= failed-files 0)
                        0
                        1))
                    fatal-status)))))]))))

(define (tltest-run-batch-run
  [paths : cli_svec.Vec]
  [target : String]
  [roots : cli_svec.Vec]
  [opt-level : i64]
  [backend-mode : be_state.CompilerBackendMode]) : i64
  (compiler_load.compiler-load-session-cache-enable!)
  (compiler_load.compiler-load-session-program-cache-disable!)
  (driver.compiler-driver-reset-file-state!)
  (match (build_run_core.source-tool-parse-target
    (owned_view.compiler-owned-shared-view target))
    [(Err message)
      (io.print-error message)
      1]
    [(Ok backend-target)
      (if tltest-prefix-cache-stats
        (tc_core.tc-prefix-snapshot-cache-clear!)
        unit)
      (let
        [status : i64
          (if tltest-combined
            (tltest-run-batch-run-paths-combined
              paths
              target
              roots
              opt-level
              backend-mode
              backend-target)
            (tltest-run-batch-run-paths
              paths
              target
              roots
              opt-level
              backend-mode
              backend-target))]
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
      (match (build_run_core.source-tool-parse-target
        (owned_view.compiler-owned-shared-view target))
        [(Err message)
          (io.print-error message)
          1]
        [(Ok backend-target)
          (let
            [test-cfgs : sym_i64_env.SymI64Env (tltest-cfgs backend-target)]
            [require-archive : bool
              (and (not tltest-list-only) (not (tltest-check-mode? test-mode)))]
            (match (tltest-open-stdlib-tli-for-session!
              (& source)
              true
              (driver.compiler-driver-target-cfg-from-backend backend-target)
              (& roots)
              test-cfgs
              opt-level
              require-archive)
              [(Err tli-msg)
                (compiler_load.compiler-load-tli-release!)
                (io.print-error tli-msg)
                1]
              [(Ok)
                (let
                  [status : i64
                    (match (driver.compiler-driver-load-file-with-runtime
                      (owned_view.compiler-owned-shared-view source)
                      (owned_view.compiler-owned-shared-view roots)
                      test-cfgs)
                      [(Ok decls paths _ _)
                        (if tltest-list-only
                          (let
                            [count : i64
                              (tltest-list-loaded source decls paths)]
                            (io.print-format
                              "{}"
                              (tltest-list-summary-line count))
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
                                      source
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
                                      (string.copy (& source))
                                      (tltest-diagnostic-source
                                        source
                                        (& decls)
                                        (& paths))
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
                          (driver.compiler-driver-render-source-diagnostic
                            (deref diag)))
                        1])]
                  (compiler_load.compiler-load-tli-release!)
                  status)]))])]
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
  [backend-mode : be_state.CompilerBackendMode]
  [runs-avx2 : bool]
  [runs-avx512 : bool]) : TestMaybeString
  (match backend-mode
    [(Scalar) (No)]
    [(Sse2) (No)]
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
  [backend-mode : be_state.CompilerBackendMode]
  [test-mode : TestMode]
  [list-only : bool]) : bool
  (and
    (not (be_state.compiler-backend-mode-scalar? backend-mode))
    (not list-only)
    (not (tltest-check-mode? test-mode))))

;; A run is refused once per process, before any compilation, instead of
;; trapping on the first vector instruction of some harness.
(define (tltest-host-isa-permits?
  [backend-mode : be_state.CompilerBackendMode]
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
    [(or (File _ _ backend-mode _ _ test-mode)
         (Batch _ _ backend-mode _ _ test-mode)
         (Package _ _ _ backend-mode _ _ test-mode))
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