(import compiler_backend as backend)
(import compiler_lower as lower)
(import compiler_ast_types as ast)
(import compiler_diagnostic as diagnostic)
(import compiler_intern as intern)
(import compiler_builtin_ids as builtins)
(import compiler_load as load)
(import compiler_parse_core as parser)
(import compiler_typecheck_api as typecheck)
(import compiler_typecheck_core as tc)
(import compiler_profile_state as profile)
(import stdlib.iterator)
(import stdlib.string)
(import stdlib.test)
(import stdlib.vector)
(import (vector.vector String) as strings)

(include-str payload-source "../tests/integration/backend_source_import_payload.tl")
(include-str aliases-source "../tests/integration/backend_source_import_aliases.tl")
(include-str wildcard-source "../tests/integration/backend_source_import_wildcard.tl")
(include-str concat-source "../tests/integration/backend_source_import_str_cat.tl")

(define (release-result [result : lower.ResultCompilerLower]) : bool
  (match result
    [(Ok _ _ owner)
      (lower.compiler-lower-arena-state-release!
        (lower.compiler-lower-state-arenas owner))
      true]
    [(Err _) false]))

(define (error-at?
  [error : (& error diagnostic.CompilerDiagnostic)]
  [path : (& path str)]
  [needle : (& needle str)]
  [line : i64]
  [column : i64]) : bool
  (and
    (string.eq (diagnostic.compiler-diagnostic-path error) path)
    (= (diagnostic.compiler-diagnostic-line error) line)
    (= (diagnostic.compiler-diagnostic-col error) column)
    (backend.compiler-backend-string-contains?
      (diagnostic.compiler-diagnostic-message error)
      needle)))

;; Raw images are not admission decisions. The allocation control must retain
;; the existing semantic exclusion until runtime bodies are materialized.
(define (source-object-status
  [source : String]
  [target : backend.CompilerBackendTarget]) : String
  (match (backend.compiler-backend-lower-source-for-target source target)
    [(Err error)
      (diagnostic.compiler-diagnostic-render (& (__tl-box-place error)))]
    [(Ok program _ owner)
      (let
        [state : backend.CompilerBackendState
          (backend.compiler-backend-state-new
            (intern.intern-compat-state-capture-active))]
        [eligibility : backend.CompilerBackendObjectEligibility
          (backend.compiler-backend-object-program-eligibility-with-pools-and-profile-state
            state
            (ast.ast-node-pool-context-capture-active)
            program
            target
            (profile.compiler-profile-state-new))]
        [status : String
          (match eligibility
            [(Eligible) "eligible"]
            [(Unsupported reason)
              (backend.compiler-direct-object-fallback-category reason)])]
        (backend.compiler-backend-state-release-final-arenas! state)
        (lower.compiler-lower-arena-state-release!
          (lower.compiler-lower-state-arenas owner))
        status)]))

(define (import-matrix-ok?) : bool
  (let
    [sources : (__tl_dyn-array String)
      (__tl_make-array
        (string.copy (& payload-source))
        (string.copy (& aliases-source))
        (string.copy (& wildcard-source)))]
    [ok : bool true]
    (for [target-index (iterator.range 0 2)]
      (let
        [target : backend.CompilerBackendTarget
          (if (= target-index 0)
            (Linux)
            (Windows))]
        (for [index (iterator.range 0 (array-length sources))]
          (set!
            ok
            (and
              ok
              (match (backend.compiler-backend-emit-source-for-target
                (string.copy (& (array-ref sources index)))
                target)
                [(Ok text) (> (string.string-length text) 0)]
                [(Err _) false])))
          (set!
            ok
            (and
              ok
              (match (backend.compiler-backend-emit-source-object-image-for-target
                (string.copy (& (array-ref sources index)))
                target)
                [(Ok _) true]
                [(Err _) false]))))
        (set!
          ok
          (and
            ok
            (match (backend.compiler-backend-emit-source-for-target
              (string.copy (& concat-source))
              target)
              [(Ok _) true]
              [(Err _) false])))
        (set!
          ok
          (and
            ok
            (string.eq
              (source-object-status (string.copy (& concat-source)) target)
              "unsupported-object-semantics")))))
    ok))

(define (private-context-retired? [source : String] [expected-ok : bool]) : bool
  (let
    [request : lower.CompilerLowerRequest
      (lower.compiler-lower-request (LinuxScalar))]
    [cfgs (lower.lower-source-request-cfgs (& request))]
    [program
      (match (parser.parse-ast-source-diagnostic-with-cfg
        "target/private-backend-source.tl"
        (& source)
        (clone cfgs))
        [(Ok program) program]
        [(Err _) (return false)])]
    [context : typecheck.TypecheckRequest
      (typecheck.TypecheckRequest
        (load.compiler-load-standalone-session-state-new)
        (tc.tc-prefix-snapshot-cache-state-new)
        (tc.tc-job-state-new)
        program
        (ast.ast-decl-path-list-new)
        (strings.new)
        cfgs
        "private-backend-source"
        (ast.ast-node-pool-context-capture-active)
        (intern.intern-compat-state-capture-active)
        (tc.TcSemanticObserver 0))]
    [surface-owner : i64
      (load.compiler-load-session-state-surface-summary-owner-arena-ensure!
        (& context.load-state))]
    [owner : lower.CompilerLowerState (lower.compiler-lower-state-new)]
    [_provenance : unit
      (load.compiler-load-session-state-note-embedded-module!
        (& context.load-state)
        "stdlib.backend_retirement_sentinel")]
    [provenance-owner : i64
      (array-ref context.load-state.embedded-provenance-owner-arena 0)]
    [result : lower.ResultCompilerLower
      (lower.lower-standalone-result
        owner
        (lower.lower-source-context
          owner
          "target/private-backend-source.tl"
          (& source)
          (& request)
          (& context)))]
    [ok : bool
      (match result
        [(Ok _ _ result-owner)
          (lower.compiler-lower-arena-state-release!
            (lower.compiler-lower-state-arenas result-owner))
          expected-ok]
        [(Err _) (not expected-ok)])]
    (and
      ok
      (> surface-owner 0)
      (> provenance-owner 0)
      (= (array-ref context.load-state.surface-summary-owner-arena 0) 0)
      (= (array-ref context.load-state.embedded-provenance-owner-arena 0) 0)
      (= (array-ref context.load-state.dotted-path-cache-owner-arena 0) 0)
      (= (array-ref context.prefix-cache.arena 0) 0))))

(define (request-context-ok?) : bool
  (let
    [request : lower.CompilerLowerRequest
      (lower.compiler-lower-request (LinuxScalar))]
    [path : String "target/backend-source-request.tl"]
    [source : String
      "(import stdlib.string as item)
(cfg backend-source-feature (define chosen : i64 39))
(define (main) : i64 (+ chosen (item.string-length \"abc\")))"]
    [bad : (__tl_dyn-array String)
      (__tl_make-array
        "(define harmless : i64 1)
(import stdlib.backend_missing_for_test)"
        "(import stdlib.arena as item)
(define (main) : i64 (item.string-length \"abc\"))"
        "(import stdlib.string as")]
    [ok : bool true]
    (strings.push-ref! (&mut request.stdlib-roots) "stdlib")
    (strings.push-ref! (&mut request.cfg-names) "backend-source-feature")
    (set!
      ok
      (release-result
        (lower.lower-compiler-source-with-request
          (string.copy (& path))
          (string.copy (& source))
          (& request))))
    (for [index (iterator.range 0 (array-length bad))]
      (let
        [result : lower.ResultCompilerLower
          (lower.lower-compiler-source-with-request
            (string.copy (& path))
            (string.copy (& (array-ref bad index)))
            (& request))]
        (set!
          ok
          (and
            ok
            (match result
              [(Err error)
                (and
                  (if (= index 0)
                    (let
                      [labels : diagnostic.CompilerDiagnosticLabelList
                        (diagnostic.compiler-diagnostic-secondary-spans
                          (__tl-box-place error))]
                      (and
                        (string.eq
                          (diagnostic.compiler-diagnostic-path
                            (__tl-box-place error))
                          "stdlib/backend_missing_for_test.tl")
                        (> labels.len 0)
                        (string.eq
                          (diagnostic.compiler-diagnostic-label-list-get
                            labels
                            0).span.path
                          path)
                        (=
                          (diagnostic.compiler-diagnostic-label-list-get
                            labels
                            0).span.start-line
                          2)
                        (=
                          (diagnostic.compiler-diagnostic-label-list-get
                            labels
                            0).span.start-col
                          1)))
                    (if (= index 1)
                      (error-at?
                        (__tl-box-place error)
                        path
                        "item.string-length"
                        2
                        23)
                      (error-at?
                        (__tl-box-place error)
                        path
                        "unterminated list"
                        1
                        1))))]
              [(Ok _ _ owner)
                (lower.compiler-lower-arena-state-release!
                  (lower.compiler-lower-state-arenas owner))
                false]))))
      (set!
        ok
        (and
          ok
          (release-result
            (lower.lower-compiler-source-with-request
              (string.copy (& path))
              (string.copy (& source))
              (& request))))))
    (and
      ok
      (private-context-retired? (string.copy (& payload-source)) true)
      (private-context-retired?
        "(import stdlib.backend_missing_for_test)"
        false))))

(define (in-session-library-entry-ok? [target : backend.CompilerBackendTarget]) : bool
  (match (backend.compiler-backend-lower-source-for-target-in-session
    "(module library-entries)
(define (entry [value : i64]) : i64 value)"
    target)
    [(Err _) false]
    [(Ok program spans owner)
      (let
        [ok : bool
          (match (backend.compiler-backend-emit-program-target-with-mode
            program
            target
            (Scalar)
            spans
            false)
            [(Ok text)
              (backend.compiler-backend-string-contains? text "_tl_f0:\n")]
            [(Err _) false])]
        (lower.compiler-lower-arena-state-release!
          (lower.compiler-lower-state-arenas owner))
        ok)]))

(define (in-session-context-ok?) : bool
  (builtins.compiler-builtin-initialize-for-parse!)
  (let
    [previous : load.CompilerLoadSessionState
      (load.compiler-load-active-session-state-shared-view)]
    [enclosing : load.CompilerLoadSessionState
      (load.compiler-load-session-state-new)]
    [pools : ast.AstNodePoolContext (ast.ast-node-pool-context-capture-active)]
    [sentinel : i64
      (ast.ast-node-pool-context-expr-push
        pools
        (ast.AstExpr.Literal (ast.ast-lit-int 37)))]
    [name : String "enclosing-import-sentinel"]
    [name-id : i64
      (intern.intern-source-slice (& name) 0 (string.string-length name))]
    [generation : i64 (intern.intern-generation)]
    [import-id : i64 builtins.compiler-builtin-id-fix-import]
    [ok : bool true]
    (ast.ast-node-pool-context-install! pools)
    (load.compiler-load-session-state-use! enclosing)
    (for [index (iterator.range 0 3)]
      (set!
        ok
        (and
          ok
          (in-session-library-entry-ok?
            (if (= index 1)
              (Windows)
              (Linux)))))
      (set!
        ok
        (and
          ok
          (release-result
            (backend.compiler-backend-lower-source-for-target-in-session
              (string.copy (& payload-source))
              (Linux)))))
      (set!
        ok
        (and
          ok
          (match (backend.compiler-backend-lower-source-for-target-in-session
            "(import stdlib.string as item)
(define (main) : i64 (item.absent))"
            (Windows))
            [(Err error)
              (error-at? (__tl-box-place error) "<source>" "item.absent" 2 23)]
            [(Ok _ _ owner)
              (lower.compiler-lower-arena-state-release!
                (lower.compiler-lower-state-arenas owner))
              false]))))
    (set!
      ok
      (and
        ok
        (= generation (intern.intern-generation))
        (= import-id builtins.compiler-builtin-id-fix-import)
        (=
          enclosing.shared-address
          (load.compiler-load-active-session-state-shared-view).shared-address)
        (string.eq
          (intern.intern-id-str (intern.intern-id-from-renderable name-id))
          name)
        (match (ast.ast-node-pool-context-expr-get pools sentinel)
          [(Literal (Int 37 _)) true]
          [_ false])))
    (load.compiler-load-session-state-use! previous)
    ok))

(define (self-test) : bool
  (and (import-matrix-ok?) (request-context-ok?) (in-session-context-ok?)))

(test
  backend-source-import-matrix
  (test.assert-true
    (import-matrix-ok?)
    "target source helpers preserve imported context"))

(test
  backend-source-import-request-context
  (test.assert-true
    (request-context-ok?)
    "request roots/cfgs and diagnostics remain isolated"))

(test
  backend-source-import-enclosing-session
  (test.assert-true
    (in-session-context-ok?)
    "nested jobs preserve enclosing owners"))