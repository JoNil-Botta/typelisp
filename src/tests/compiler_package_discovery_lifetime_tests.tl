;; Source-owned inline lifetime regressions, auto-discovered by
;; scripts/verify-inline-tests.sh on Linux and Windows.
(import stdlib.io)
(import stdlib.arena)
(import stdlib.string)
(import stdlib.str_cat_runtime as str_cat)
(import stdlib.text_buf)
(import stdlib.vector)
(import (vector.vector String) as roots_vec)
(import compiler_ast_types as ast)
(import compiler_backend as backend)
(import compiler_builtin_ids as cbi)
(import compiler_check_core as check)
(import compiler_cfg_core as cfg_core)
(import compiler_diagnostic as diag)
(import compiler_driver_core as driver)
(import compiler_intern as ci)
(import compiler_load as load)
(import compiler_load_tests as load_tests)
(import compiler_owned_view as owned_view)
(import doc_test)
(import doc_test_tests as doc_tests)
(import sym_i64_env)
(import tlci_core as tlci)
(import tlci_loader)
(import tlci_core_tests)
(import tlci_loader_tests)

(define (discovery-test-roots) : roots_vec.Vec
  (let
    [roots : roots_vec.Vec (roots_vec.new)]
    (roots_vec.push-ref! (&mut roots) "stdlib")
    (roots_vec.push-ref! (&mut roots) "src")
    roots))

(define (discovery-test-load
  [path : String]
  [target : backend.CompilerBackendTarget]) : driver.ResultCompilerDriverPackagePaths
  (driver.compiler-driver-load-package-paths-with-runtime
    path
    target
    (discovery-test-roots)
    "target/exp/package-discovery-lifetime"
    (load.compiler-pkg-deps-empty)
    true))

(define (discovery-test-paths-equal?
  [expected : ast.AstDeclPathList]
  [actual : (& actual ast.AstDeclPathList)]) : bool
  (let
    [count : i64 (ast.ast-decl-path-list-len (& expected))]
    [index : i64 0]
    [ok : bool (= count (ast.ast-decl-path-list-len actual))]
    (while (and ok (< index count))
      (set!
        ok
        (and
          (string.eq
            (ast.ast-decl-path-list-get (& expected) index "")
            (ast.ast-decl-path-list-get actual index ""))
          (= (ast.ast-decl-path-list-owner-id actual index 123) -1)
          (= (ast.ast-decl-path-list-provenance-id actual index 123) -1)))
      (set! index (+ index 1)))
    (and ok (> count 0))))

(define (discovery-test-reuse-storage!) : unit
  (with-scratch
    (let
      [slots : (__tl_dyn-array i64) (__tl_make-array i64 1048576)]
      [index : i64 0]
      (while (< index (array-length slots))
        (set! (array-ref slots index) 7666)
        (set! index (+ index 1))))))

(define (discovery-test-write-fixture!) : unit
  (load.compiler-load-test-mkdir "target/exp")
  (load.compiler-load-test-mkdir "target/exp/package-discovery-lifetime")
  (load.compiler-load-test-mkdir "target/exp/package-discovery-lifetime/src")
  (load_tests.compiler-load-write-file-text
    "target/exp/package-discovery-lifetime/src/helper.tl"
    "(module helper)\n(define value : i64 42)")
  (load_tests.compiler-load-write-file-text
    "target/exp/package-discovery-lifetime/src/main.tl"
    (str_cat.str-cat
      "(import helper as helper)\n"
      (doc_tests.doc-test-smoke-source)
      "\n(define (main) : i64 helper.value)"))
  (load_tests.compiler-load-write-file-text
    "target/exp/package-discovery-lifetime/src/bad.tl"
    "(define broken : i64"))

(test
  package-discovery-copies-paths-and-restores-session
  (discovery-test-write-fixture!)
  (driver.compiler-driver-reset-file-state!)
  (match (driver.compiler-driver-load-package-file-with-runtime
    "target/exp/package-discovery-lifetime/src/main.tl"
    (Linux)
    (discovery-test-roots)
    "target/exp/package-discovery-lifetime"
    (load.compiler-pkg-deps-empty)
    true)
    [(Err _) (io.panic "discovery fixture must load before path retirement")]
    [(Ok _ paths _ _)
      (let
        [expected : ast.AstDeclPathList
          (driver.compiler-driver-copy-package-discovery-paths paths)]
        [intern-table : i64 (ci.intern-active-table-id)]
        [pool-owner : i64 (ast.ast-node-pool-owner-arena-handle)]
        [session : load.CompilerLoadSessionState
          (load.compiler-load-active-session-state-shared-view)]
        [_bind-owner : unit
          (load.compiler-load-session-state-use-with-intern-state!
            session
            (ci.intern-compat-state-capture-active))]
        (match (discovery-test-load
          "target/exp/package-discovery-lifetime/src/main.tl"
          (Linux))
          [(Err _)
            (io.panic "discovery must preserve successful import closure")]
          [(Ok copied)
            (unless
              (and
                (= intern-table (ci.intern-active-table-id))
                (= pool-owner (ast.ast-node-pool-owner-arena-handle))
                (cbi.compiler-builtin-table-current?)
                (array-ref session.intern-state-ready 0)
                (=
                  session.shared-address
                  (load.compiler-load-active-session-state-shared-view).shared-address))
              (io.panic "discovery did not restore enclosing owners"))
            (discovery-test-reuse-storage!)
            (unless
              (discovery-test-paths-equal? expected copied)
              (io.panic "retired discovery changed path order or retained ids"))
            (let
              [report : doc_test.DocTestRunReport
                (doc_test.doc-test-typecheck-package-paths-with-roots
                  copied
                  (discovery-test-roots)
                  "target/exp/package-discovery-lifetime"
                  (load.compiler-pkg-deps-empty))]
              (unless
                (and
                  (=
                    (doc_test.doc-test-run-report-count
                      (owned_view.compiler-owned-shared-view report))
                    2)
                  (doc_test.doc-test-run-report-ok? report))
                (io.panic "retired paths must still find both doctests")))]))])
  (match (check.compiler-check-file-with-roots
    "target/exp/package-discovery-lifetime/src/main.tl"
    (discovery-test-roots))
    [(Ok _ _) unit]
    [(Err _ _)
      (io.panic "typecheck after discovery must use live compiler state")]))

(test
  package-discovery-error-survives-next-target-load
  (discovery-test-write-fixture!)
  (driver.compiler-driver-reset-file-state!)
  (match (discovery-test-load
    "target/exp/package-discovery-lifetime/src/bad.tl"
    (Linux))
    [(Ok _) (io.panic "malformed discovery source must fail")]
    [(Err failure)
      (match (discovery-test-load
        "target/exp/package-discovery-lifetime/src/main.tl"
        (Windows))
        [(Ok _) unit]
        [(Err _) (io.panic "failed discovery must not poison next target load")])
      (discovery-test-reuse-storage!)
      (let
        [diagnostic : diag.CompilerDiagnostic
          (owned_view.compiler-owned-box-shared-view failure)]
        (unless
          (and
            (string.eq
              (diag.compiler-diagnostic-path diagnostic)
              "target/exp/package-discovery-lifetime/src/bad.tl")
            (>
              (string.string-length
                (diag.compiler-diagnostic-message diagnostic))
              0))
          (io.panic "discovery diagnostic must outlive retired storage")))]))

(test
  package-discovery-extraction-owns-code-output-and-errors
  (discovery-test-write-fixture!)
  (load_tests.compiler-load-write-file-text
    "target/exp/package-discovery-lifetime/src/extract.tl"
    (doc_tests.doc-test-runnable-source))
  (let
    [runnable : doc_test.DocTestExtraction
      (doc_test.doc-test-extract-package-file-text
        "target/exp/package-discovery-lifetime/src/extract.tl")]
    [_replace : unit
      (load_tests.compiler-load-write-file-text
        "target/exp/package-discovery-lifetime/src/extract.tl"
        (doc_tests.doc-test-malformed-source))]
    [malformed : doc_test.DocTestExtraction
      (doc_test.doc-test-extract-package-file-text
        "target/exp/package-discovery-lifetime/src/extract.tl")]
    (discovery-test-reuse-storage!)
    (match runnable
      [(Extraction examples errors)
        (unless
          (and
            (= (doc_test.doc-test-example-list-count examples) 2)
            (= (doc_test.doc-test-error-list-count errors) 0)
            (doc_tests.doc-test-runnable-example-ok?
              (doc_test.doc-test-example-list-ref examples 0)
              1
              2
              0
              "hello\n"
              "error\tline\r"
              "(define (main)")
            (doc_tests.doc-test-runnable-example-ok?
              (doc_test.doc-test-example-list-ref examples 1)
              2
              14
              42
              ""
              ""
              "42"))
          (io.panic "extracted code or runnable expectations escaped scratch"))])
    (match malformed
      [(Extraction examples errors)
        (unless
          (and
            (= (doc_test.doc-test-example-list-count examples) 0)
            (= (doc_test.doc-test-error-list-count errors) 3)
            (doc_tests.doc-test-malformed-errors-ok? errors))
          (io.panic "malformed fence ordering or messages escaped scratch"))])
    (match (doc_test.doc-test-extract-package-file-text
      "target/exp/package-discovery-lifetime/src/not-present.tl")
      [(Extraction examples errors)
        (unless
          (and
            (= (doc_test.doc-test-example-list-count examples) 0)
            (= (doc_test.doc-test-error-list-count errors) 0))
          (io.panic "missing package doctest path changed behavior"))])))

(test
  package-discovery-inline-cfg-snapshot-outlives-interns
  (driver.compiler-driver-reset-file-state!)
  (let
    [cfgs : sym_i64_env.SymI64Env
      (cfg_core.compiler-cfg-bind
        (cfg_core.compiler-cfg-bind
          (cfg_core.compiler-cfg-bind
            (cfg_core.compiler-cfg-empty)
            "discovery-retained-value"
            3)
          "discovery-retained-value"
          17)
        "discovery-retained-zero"
        0)]
    [snapshot : cfg_core.CompilerCfgSnapshot
      (cfg_core.compiler-cfg-snapshot-from-env cfgs)]
    (driver.compiler-driver-reset-file-state!)
    (ci.intern-persistent-arena-reset!)
    (discovery-test-reuse-storage!)
    (let
      [restored : sym_i64_env.SymI64Env
        (cfg_core.compiler-cfg-snapshot-to-env snapshot)]
      [value-key : i64
        (cfg_core.compiler-cfg-key-id
          (cfg_core.compiler-cfg-key-from-name-id
            (ci.intern "discovery-retained-value")))]
      [zero-key : i64
        (cfg_core.compiler-cfg-key-id
          (cfg_core.compiler-cfg-key-from-name-id
            (ci.intern "discovery-retained-zero")))]
      (unless
        (and
          (= (sym_i64_env.sym-i64-lookup-id-or restored value-key -1) 17)
          (= (sym_i64_env.sym-i64-lookup-id-or restored zero-key -1) 0))
        (io.panic "cfg names, binding order or values escaped intern storage")))))

(define (discovery-test-admit-native!
  [state : load.CompilerLoadSessionState]
  [owner : i64]) : bool
  (in-arena
    (arena.Arena owner)
    (match (tlci_loader_tests.tlci-loader-test-emit-with-real-fixup)
      [(Err _) false]
      [(Ok bytes)
        (match (tlci_loader.tlci-loader-load-from-bytes-with-host
          owner
          bytes
          (tlci_core_tests.tlci-test-host-callback-table))
          [(Err _) false]
          [(Ok loaded)
            (=
              (load.compiler-load-dependency-catalog-record-owned!
                state
                (load.CompilerLoadDependencyCatalogEntry
                  (load.CompilerLoadDependencyCatalogKey
                    "target/exp/package-discovery-lifetime/native"
                    "demo"
                    "0.1.0"
                    "target/exp/package-discovery-lifetime/native.tlci"
                    7666
                    1
                    (tlci.tlci-build-host-platform)
                    tlci.tlci-callback-abi-version
                    "abcdef0")
                  (Some (tlci_loader_tests.tlci-loader-test-image 0))
                  (tlci.tlci-spmd-callables-empty)
                  (TrustedCode loaded)))
              0)])])))

(test
  package-discovery-preserves-admitted-native-mapping
  (discovery-test-write-fixture!)
  (driver.compiler-driver-reset-file-state!)
  (let
    [state : load.CompilerLoadSessionState
      (load.compiler-load-active-session-state-shared-view)]
    [owner : i64
      (load.compiler-load-dependency-catalog-owner-arena-ensure!
        (owned_view.compiler-owned-shared-view state))]
    (unless
      (discovery-test-admit-native!
        (owned_view.compiler-owned-shared-view state)
        owner)
      (io.panic "native discovery fixture must admit its host mapping"))
    (match (discovery-test-load
      "target/exp/package-discovery-lifetime/src/main.tl"
      (Linux))
      [(Ok _) unit]
      [(Err _) (io.panic "discovery with admitted native catalog must load")])
    (match (discovery-test-load
      "target/exp/package-discovery-lifetime/src/bad.tl"
      (Windows))
      [(Err _) unit]
      [(Ok _) (io.panic "native catalog must not hide malformed discovery")])
    (load.compiler-load-session-state-dependency-surfaces-release!
      (owned_view.compiler-owned-shared-view state))
    (discovery-test-reuse-storage!)
    (match (load.compiler-load-dependency-catalog-admitted-image state 0)
      [(TrustedCode _ loaded)
        (unless
          (and
            (=
              (tlci_loader.tlci-loader-read-mapped-i64 loaded.rodata-addr)
              loaded.image-region-addr)
            (=
              (tlci_loader.tlci-loader-read-mapped-i64 loaded.registration-addr)
              tlci.tlci-image-registration-magic))
          (io.panic "discovery retired the enclosing native mapping"))]
      [_ (io.panic "discovery changed admitted catalog status")])
    (match (load.compiler-load-session-state-dependency-catalog-release! state)
      [(Ok) unit]
      [(Err _) (io.panic "enclosing catalog must retain sole mapping release")])))

;; `(import wide.*)` notes two structural pairs per imported item, so each
;; discovery job grows its child interner across several generations.
(define (discovery-test-write-wide-fixture! [count : i64]) : unit
  (let
    [source : text_buf.TextBuf (text_buf.empty)]
    [index : i64 0]
    (text_buf.append! source "(module wide)")
    (while (< index count)
      (text_buf.append! source "\n(define wide_item_")
      (text_buf.append-int! source index)
      (text_buf.append! source " : i64 1)")
      (set! index (+ index 1)))
    (load.compiler-load-test-mkdir "target/exp")
    (load.compiler-load-test-mkdir "target/exp/package-discovery-lifetime")
    (load.compiler-load-test-mkdir "target/exp/package-discovery-lifetime/src")
    (load_tests.compiler-load-write-file-text
      "target/exp/package-discovery-lifetime/src/wide.tl"
      (text_buf.render source))
    (load_tests.compiler-load-write-file-text
      "target/exp/package-discovery-lifetime/src/wide_main.tl"
      "(import wide.*)\n(define (main) : i64 wide_item_0)")))

(define (discovery-test-wide-load-ok?) : bool
  (match (discovery-test-load
    "target/exp/package-discovery-lifetime/src/wide_main.tl"
    (Linux))
    [(Ok _) true]
    [(Err _) false]))

(test
  package-discovery-releases-structural-generations
  (discovery-test-write-wide-fixture! 4000)
  (driver.compiler-driver-reset-file-state!)
  (let
    [table-id : i64 (ci.intern-active-table-id)]
    [live : i64 (ci.intern-structural-generations-live)]
    [ok? : bool true]
    [index : i64 0]
    ;; Each job grows its child's records and map at least once, then
    ;; releases every generation before the parent is used again.
    (while (< index 3)
      (let
        [made : i64 (ci.intern-structural-generations-made-count)]
        (set!
          ok?
          (and
            ok?
            (discovery-test-wide-load-ok?)
            (>= (ci.intern-structural-generations-made-count) (+ made 2))
            (= (ci.intern-structural-generations-live) live)))
        (set! index (+ index 1))))
    (unless
      (and ok? (= table-id (ci.intern-active-table-id)))
      (io.panic "package discovery retained structural generations"))))