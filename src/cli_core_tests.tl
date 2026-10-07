;; cli_core_tests.tl - Inline tests for the inspect, explain, scaffold and repl
;; CLI cores.
(cfg test (import compiler_owned_view as owned_view))
(import stdlib.io)
(import stdlib.string)
(import stdlib.str_cat_runtime as str_cat)
(cfg embedded-stdlib-tlci (import compiler_embedded_stdlib_tlci))
(cfg test (import tlci_core))
(cfg test (import tlci_core_tests))
(cfg test (import inspect_cli_core as inspect))
(cfg test (import tlci_core_tests))
(cfg test (import compiler_diagnostic as cdiag))
(cfg test (import explain_cli_core as explain))
(import scaffold_cli_core as scaffold)
(import stdlib.vector)
(import (vector.vector String) as cli_svec)
(import compiler_ast_types as ast)
(import repl_cli_core as repl)

(cfg
  test
  (test
    tlci-inspect-error-includes-path
    (unless
      (string.eq
        (inspect.tlci-inspect-error
          "pkg/dep.tlci"
          "tlci: content hash mismatch")
        "inspect: pkg/dep.tlci: tlci: content hash mismatch\n")
      (io.panic "inspect error formatting failed"))))

(cfg
  test
  (test
    tlci-inspect-source-binding-shapes
    (let
      [sections : (__tl_dyn-array tlci_core.TlciAuxSection)
        (__tl_make-array tlci_core.TlciAuxSection 1)]
      [bound : String ""]
      [unsupported : String ""]
      [malformed : String ""]
      [bound-schema : String "source-set-binding-schema: 1\n"]
      [bound-digest : String "source-set-digest: 12345\n"]
      [missing-schema : String "source-set-binding-schema: missing-or-legacy\n"]
      [missing-digest : String "source-set-digest: unavailable\n"]
      [unsupported-schema : String
        "source-set-binding-schema: unsupported (2)\n"]
      [malformed-schema : String "source-set-binding-schema: malformed\n"]
      (set!
        (array-ref sections 0)
        (tlci_core.tlci-package-source-binding-section 12345))
      (match (tlci_core.tlci-aux-pack-rodata
        (tlci_core.tlci-empty-bytes)
        sections)
        [(Ok packed) (set! bound (inspect.tlci-inspect-source-binding packed))]
        [_ unit])
      (set!
        (array-ref sections 0)
        (tlci_core.TlciAuxSection
          tlci_core.tlci-aux-kind-package-source-binding
          2
          (tlci_core.tlci-string->bytes "future")))
      (match (tlci_core.tlci-aux-pack-rodata
        (tlci_core.tlci-empty-bytes)
        sections)
        [(Ok packed)
          (set! unsupported (inspect.tlci-inspect-source-binding packed))]
        [_ unit])
      (set!
        (array-ref sections 0)
        (tlci_core.TlciAuxSection
          tlci_core.tlci-aux-kind-package-source-binding
          tlci_core.tlci-package-source-binding-schema-version
          (__tl_make-array u8 7)))
      (match (tlci_core.tlci-aux-pack-rodata
        (tlci_core.tlci-empty-bytes)
        sections)
        [(Ok packed)
          (set! malformed (inspect.tlci-inspect-source-binding packed))]
        [_ unit])
      (let
        [missing : String
          (inspect.tlci-inspect-source-binding (tlci_core.tlci-empty-bytes))]
        (if (and
          (string.contains (& bound) (& bound-schema))
          (string.contains (& bound) (& bound-digest))
          (string.contains (& missing) (& missing-schema))
          (string.contains (& missing) (& missing-digest))
          (string.contains (& unsupported) (& unsupported-schema))
          (string.contains (& malformed) (& malformed-schema)))
          unit
          (io.panic "inspect source binding rendering failed"))))))

(cfg
  test
  (test
    tlci-inspect-surface-shapes
    (let
      [sections : (__tl_dyn-array tlci_core.TlciAuxSection)
        (__tl_make-array tlci_core.TlciAuxSection 3)]
      (set!
        (array-ref sections 0)
        (tlci_core.TlciAuxSection
          tlci_core.tlci-aux-kind-package-identity
          1
          (tlci_core.tlci-string->bytes "identity")))
      (set!
        (array-ref sections 1)
        (tlci_core.TlciAuxSection
          tlci_core.tlci-aux-kind-frontend-ast
          5
          (tlci_core.tlci-empty-bytes)))
      (set!
        (array-ref sections 2)
        (tlci_core.TlciAuxSection
          tlci_core.tlci-aux-kind-frontend-facts
          1
          (tlci_core.tlci-string->bytes "facts")))
      (match (tlci_core.tlci-aux-pack-rodata
        (tlci_core.tlci-empty-bytes)
        sections)
        [(Err _) (io.panic "inspect surface fixture packing failed")]
        [(Ok rodata)
          (let
            [rendered : String
              (inspect.tlci-inspect-surface
                rodata
                "0123456789abcdef0123456789abcdef01234567")]
            [identity-line : String
              "surface-package-identity: present schema-version=1 bytes=8\n"]
            [ast-line : String
              "surface-frontend-ast: present schema-version=5 bytes=0\n"]
            [facts-line : String
              "surface-frontend-facts: present schema-version=1 bytes=5\n"]
            [trust-line : String
              "surface-trust-policy: exact-producer-and-source-binding-required\n"]
            (unless
              (and
                (string.contains (& rendered) (& identity-line))
                (string.contains (& rendered) (& ast-line))
                (string.contains (& rendered) (& facts-line))
                (string.contains (& rendered) (& trust-line)))
              (io.panic "inspect surface rendering failed")))]))))

(cfg
  test
  (test
    tlci-inspect-imports-and-file-size
    (let
      [ok : bool
        (match (tlci_core.tlci-emit-image
          (tlci_core_tests.tlci-test-imports-image))
          [(Err _) false]
          [(Ok bytes)
            (match (tlci_core.tlci-parse-image
              (owned_view.compiler-owned-shared-view bytes))
              [(Err _) false]
              [(Ok parsed)
                (let
                  [rendered : String (inspect.tlci-inspect-render bytes parsed)]
                  [expected-file-size : String "file-size: 314\n"]
                  [expected-imports : String
                    "  imports: offset=272 records=1 bytes=42\n"]
                  [expected-platform : String
                    (str_cat.str-cat
                      "host-platform: "
                      (tlci_core.tlci-host-platform-name
                        (tlci_core.tlci-build-host-platform))
                      " ("
                      (string.int->string (tlci_core.tlci-build-host-platform))
                      ")"
                      "\n")]
                  [expected-classification : String
                    "image-classification: metadata-only\n"]
                  (and
                    (string.contains (& rendered) (& expected-file-size))
                    (string.contains (& rendered) (& expected-imports))
                    (string.contains (& rendered) (& expected-platform))
                    (string.contains (& rendered) (& expected-classification))))])])]
      (unless ok (io.panic "inspect import section rendering failed")))))

(cfg
  test
  (test
    tlci-inspect-v2-spmd-callables
    (let
      [image : tlci_core.TlciImage
        (tlci_core.tlci-make-image
          (tlci_core.tlci-build-host-platform)
          tlci_core.tlci-callback-abi-version
          "inspect-v2-test"
          (tlci_core_tests.tlci-test-v2-metadata)
          (tlci_core.tlci-empty-bytes)
          (tlci_core.tlci-empty-bytes)
          (tlci_core.tlci-empty-bytes)
          (tlci_core.tlci-empty-bytes)
          (tlci_core.tlci-empty-bytes)
          (tlci_core.tlci-empty-bytes))]
      [ok : bool
        (match (tlci_core.tlci-emit-image image)
          [(Err _) false]
          [(Ok bytes)
            (match (tlci_core.tlci-parse-image
              (owned_view.compiler-owned-shared-view bytes))
              [(Err _) false]
              [(Ok parsed)
                (let
                  [rendered : String (inspect.tlci-inspect-render bytes parsed)]
                  [expected : String
                    (str_cat.str-cat
                      "spmd-callables:\n"
                      "  helper: name=demo.alpha signature=(-> i64 i64)\n"
                      "    specialization: abi=spmd-call-v1 backend=avx512 lanes=8 args=v result=v index-param=0 symbol=__tl_spmd_demo_alpha_v8\n"
                      "    specialization: abi=spmd-call-v1 backend=scalar lanes=1 args=v result=v index-param=0 symbol=__tl_spmd_demo_alpha_scalar\n"
                      "  helper: name=demo.beta signature=(-> i64 i64)\n"
                      "    specialization: abi=spmd-call-future backend=future lanes=4 args=u result=u index-param=-1 symbol=__tl_spmd_demo_beta_future\n")]
                  (string.contains (& rendered) (& expected)))])])]
      (unless ok (io.panic "inspect v2 SPMD callable rendering failed")))))

(cfg
  test
  (define (diagnostic-explain-detailed-entry-ok? [code : String]) : bool
    (match (explain.diagnostic-explain-lookup code)
      [(DiagnosticExplainDetailed text)
        (and
          (string.contains (& text) "Description:")
          (string.contains (& text) "Minimal failing example:")
          (string.contains (& text) "Fix:")
          (string.contains (& text) "See also:"))]
      [DiagnosticExplainUnknown false])))

(cfg
  test
  (define (diagnostic-explain-registry-entry-ok? [index : i64]) : bool
    (let
      [code : String (cdiag.compiler-diagnostic-code-registry-code index)]
      [title : String (cdiag.compiler-diagnostic-code-registry-title index)]
      (match (explain.diagnostic-explain-lookup (string.copy (& code)))
        [(DiagnosticExplainDetailed text)
          (and
            (string.contains (& text) (& code))
            (string.contains (& text) (& title))
            (diagnostic-explain-detailed-entry-ok? code))]
        [DiagnosticExplainUnknown false]))))

(cfg
  test
  (define (diagnostic-explain-registry-complete?) : bool
    (let
      [index : i64 0]
      [count : i64 (cdiag.compiler-diagnostic-code-registry-count)]
      [ok : bool true]
      (while (and ok (< index count))
        (if (diagnostic-explain-registry-entry-ok? index)
          unit
          (set! ok false))
        (set! index (+ index 1)))
      ok)))

(cfg
  test
  (test
    diagnostic-explain-registry
    (unless
      (and
        (diagnostic-explain-registry-complete?)
        (diagnostic-explain-detailed-entry-ok? "e0207")
        (explain.diagnostic-explain-ascii-case-contains
          (explain.diagnostic-explain-e0208)
          "MOVE VIOLATION")
        (match (explain.diagnostic-explain-lookup "E9999")
          [DiagnosticExplainUnknown true]
          [_ false]))
      (io.panic "explain: diagnostic registry test failed"))))

(test
  scaffold-first-run-source-smoke
  (let
    [bin-source : String (scaffold.scaffold-bin-source)]
    [lib-source : String (scaffold.scaffold-lib-source)]
    [greeting : String "(io.print-format \"{}\" \"Hello, TypeLisp!\\n\")"]
    [test-import : String "(cfg test (import stdlib.test))"]
    [test-item : String "(test answer-is-42 "]
    (unless
      (and
        (string.contains (& bin-source) (& greeting))
        (string.contains (& bin-source) (& test-import))
        (string.contains (& bin-source) (& test-item))
        (string.contains (& lib-source) (& test-import))
        (string.contains (& lib-source) (& test-item)))
      (io.panic "scaffold: first-run source smoke mismatch"))))

(define (repl-scratch-source-canonical-output-ok?
  [expr-source : String]
  [ty : ast.AstType]) : bool
  (let
    [canonical-newline-call : String "(io.println"]
    (match (repl.repl-scratch-source "" expr-source ty)
      [(Ok source) (string.contains (& source) (& canonical-newline-call))]
      [(Err _) false])))

(test
  repl-scratch-source-stdlib-imports
  (if (let
    [io-import : String "(import stdlib.io)\n"]
    [string-import : String "(import stdlib.string)\n"]
    [legacy-tl-import : String "stdlib/tl"]
    [legacy-io-import : String "stdlib/io.tl"]
    (match (repl.repl-scratch-source "" "1" (I64))
      [(Ok source)
        (and
          (string.contains (& source) (& io-import))
          (string.contains (& source) (& string-import))
          (not (string.contains (& source) (& legacy-tl-import)))
          (not (string.contains (& source) (& legacy-io-import)))
          (repl-scratch-source-canonical-output-ok? "3.5" (F64))
          (repl-scratch-source-canonical-output-ok? "'Z'" (Char))
          (repl-scratch-source-canonical-output-ok? "\"hi\"" (String)))]
      [(Err _) false]))
    unit
    (io.panic "repl: scratch source stdlib imports mismatch")))

(define (repl-scratch-cleanup-report-test-ok?) : bool
  (let
    [both : String
      (repl.repl-scratch-cleanup-report-text
        (ErrIoUnit (IoSystemCode 123 "/secret/repl_expr.tl"))
        (ErrIoUnit (IoPermissionDenied "/secret/repl-dir")))]
    [secret : String "/secret"]
    [code : String "123"]
    (and
      (string.eq
        (repl.repl-scratch-cleanup-report-text (OkIoUnit) (OkIoUnit))
        "")
      (string.eq
        (repl.repl-scratch-cleanup-report-text
          (ErrIoUnit (IoSystemCode 123 "/secret/repl_expr.tl"))
          (OkIoUnit))
        "repl: scratch file cleanup failed (system-error)\n")
      (string.eq
        (repl.repl-scratch-cleanup-report-text
          (OkIoUnit)
          (ErrIoUnit (IoPermissionDenied "/secret/repl-dir")))
        "repl: scratch directory cleanup failed (permission-denied)\n")
      (string.eq
        both
        (str_cat.str-cat
          "repl: scratch file cleanup failed (system-error)\n"
          "repl: scratch directory cleanup failed (permission-denied)\n"))
      (string.eq
        (repl.repl-run-and-scratch-cleanup-report-text
          0
          (OkIoUnit)
          (ErrIoUnit (IoPermissionDenied "/secret/repl-dir")))
        "repl: scratch directory cleanup failed (permission-denied)\n")
      (string.eq
        (repl.repl-run-and-scratch-cleanup-report-text
          135
          (ErrIoUnit (IoSystemCode 123 "/secret/repl_expr.tl"))
          (ErrIoUnit (IoPermissionDenied "/secret/repl-dir")))
        (str_cat.str-cat
          "\nREPL evaluation exited with status 135\n"
          "repl: scratch file cleanup failed (system-error)\n"
          "repl: scratch directory cleanup failed (permission-denied)\n"))
      (not (string.contains (& both) (& secret)))
      (not (string.contains (& both) (& code)))
      (string.eq
        (repl.repl-scratch-cleanup-message
          "file"
          (ErrIoUnit (IoNotFound "hidden")))
        "repl: scratch file cleanup failed (not-found)")
      (string.eq
        (repl.repl-scratch-cleanup-message
          "file"
          (ErrIoUnit (IoInvalidPath "hidden")))
        "repl: scratch file cleanup failed (invalid-path)")
      (string.eq
        (repl.repl-scratch-cleanup-message
          "file"
          (ErrIoUnit (IoUnsupported "hidden")))
        "repl: scratch file cleanup failed (unsupported)")
      (string.eq
        (repl.repl-scratch-cleanup-message
          "file"
          (ErrIoUnit (IoInterrupted "hidden")))
        "repl: scratch file cleanup failed (interrupted)")
      (string.eq
        (repl.repl-scratch-cleanup-message
          "file"
          (ErrIoUnit (IoUnknown "hidden")))
        "repl: scratch file cleanup failed (unknown)"))))

(test
  repl-scratch-cleanup-reports
  (if (and
    (repl-scratch-cleanup-report-test-ok?)
    (repl-scratch-cleanup-report-test-ok?))
    unit
    (io.panic "repl: scratch cleanup report mismatch")))