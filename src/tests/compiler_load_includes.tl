(import compiler_load as load)
(import compiler_load_tests as load_tests)
(import compiler_ast_types as ast)
(import compiler_builtin_ids as cbi)
(import compiler_intern as ci)
(import compiler_ctfe as ctfe)
(import compiler_diagnostic as diag)
(import compiler_embedded_stdlib as embedded)
(import stdlib.io)
(import stdlib.fs)
(import stdlib.byte_buf)
(import stdlib.string)
(import stdlib.str_cat_runtime as cat)
(import stdlib.test)

(define (include-kinds) : (Array load.CompilerLoadIncludeKind 4)
  (array
    load.CompilerLoadIncludeKind.RuntimeString
    load.CompilerLoadIncludeKind.ComptimeString
    load.CompilerLoadIncludeKind.LzssString
    load.CompilerLoadIncludeKind.Binary))

(define (literal-matches?
  [pools : (& pools ast.AstNodePoolContext)]
  [id : i64]
  [contents : String]) : bool
  (match (ast.ast-node-pool-context-expr-get pools id)
    [(Literal (String value)) (string.eq (ci.intern-str value) contents)]
    [_ false]))

(define (include-matches?
  [kind : load.CompilerLoadIncludeKind]
  [pools : (& pools ast.AstNodePoolContext)]
  [result : load.ResultCompilerLoadInclude]
  [contents : String]) : bool
  (match result
    [(Ok decl)
      (match decl
        [(Def _ name ty body)
          (and
            (= name cbi.compiler-builtin-id-fix-x)
            (match kind
              [(RuntimeString)
                (and
                  (match ty
                    [(Some (String)) true]
                    [_ false])
                  (literal-matches? pools body contents))]
              [(ComptimeString) false]
              [_
                (and
                  (match ty
                    [(Some (DynArray element))
                      (match (ast.ast-node-pool-context-type-get pools element)
                        [(U8) true]
                        [_ false])]
                    [_ false])
                  (match (ast.ast-node-pool-context-expr-get pools body)
                    [(BinaryData bytes)
                      (string.eq
                        bytes
                        (match kind
                          [(LzssString)
                            (ctfe.ctfe-embedded-stdlib-binary-data-bytes
                              (& contents))]
                          [_ contents]))]
                    [_ false]))]))]
        [(DefMacro _ name params (String) body)
          (and
            (match kind
              [(ComptimeString) true]
              [_ false])
            (= name cbi.compiler-builtin-id-fix-x)
            (= params.len 0)
            (match (ast.ast-node-pool-context-expr-get pools body)
              [(Call callee args)
                (and
                  (= args.len 1)
                  (match (ast.ast-node-pool-context-expr-get pools callee)
                    [(Var name) (= name (cbi.compiler-builtin-ctfe-ref 29))]
                    [_ false])
                  (literal-matches?
                    pools
                    (ast.ast-expr-list-get (& args) 0 0)
                    contents))]
              [_ false]))]
        [_ false])]
    [_ false]))

(define (error-matches?
  [result : load.ResultCompilerLoadInclude]
  [message : String]) : bool
  (match result
    [(Err boxed)
      (let
        [diagnostic : diag.CompilerDiagnostic (deref boxed)]
        (and
          (string.eq
            (diag.compiler-diagnostic-path (& diagnostic))
            "tests/integration/include-entry.tl")
          (string.eq diagnostic.message message)))]
    [_ false]))

(define (malformed-text-matches?
  [result : load.ResultCompilerLoadInclude]
  [request : String]) : bool
  (match result
    [(Err boxed)
      (let
        [diagnostic : diag.CompilerDiagnostic (deref boxed)]
        (and
          (load_tests.compiler-load-error-code? (& diagnostic) "E0302")
          (string.eq
            (diag.compiler-diagnostic-path (& diagnostic))
            "tests/integration/include_bin_payload.bin")
          (= (diag.compiler-diagnostic-line (& diagnostic)) 1)
          (= (diag.compiler-diagnostic-col (& diagnostic)) 4)
          (string.eq
            diagnostic.message
            (cat.str-cat
              "compiler-load: invalid UTF-8 include-str "
              request
              " from tests/integration/include-entry.tl at byte 3 (UnexpectedContinuation)"))))]
    [_ false]))

(define (check-includes) : unit
  (let
    [_builtins : unit (cbi.compiler-builtin-initialize-for-parse!)]
    [kinds : (Array load.CompilerLoadIncludeKind 4) (include-kinds)]
    [contents : String
      (load.compiler-load-read-file-text
        "tests/integration/include_bin_payload.bin")]
    [pools : ast.AstNodePoolContext
      (ast.ast-node-pool-context-new-with-capacities 1 1)]
    [ambient-count : i64 (ast.ast-node-pool-len)]
    [index : i64 0]
    (while (< index 4)
      (let
        [kind : load.CompilerLoadIncludeKind (array-ref kinds index)]
        [result : load.ResultCompilerLoadInclude
          (load.compiler-load-expand-include-with-pools
            kind
            "tests/integration/include-entry.tl"
            "include_bin_payload.bin"
            cbi.compiler-builtin-id-fix-x
            (& (load_tests.compiler-load-string-vec-one "stdlib"))
            pools)]
        (test.assert-true
          (match kind
            [(RuntimeString)
              (malformed-text-matches? result "include_bin_payload.bin")]
            [_ (include-matches? kind (& pools) result (string.copy contents))])
          "runtime text rejects malformed UTF-8; binary forms retain exact payload")
        (test.assert-i64-eq
          (ast.ast-node-pool-len)
          ambient-count
          "explicit pools do not publish into ambient pool")
        (test.assert-true
          (error-matches?
            (load.compiler-load-expand-include-with-pools
              kind
              "tests/integration/include-entry.tl"
              "__missing_include__.bin"
              cbi.compiler-builtin-id-fix-x
              (& (load_tests.compiler-load-string-vec-one "stdlib"))
              pools)
            (cat.str-cat
              "compiler-load: cannot read "
              (match kind
                [(Binary) "include-bin"]
                [_ "include-str"])
              " __missing_include__.bin from tests/integration/include-entry.tl (resolved tests/integration/__missing_include__.bin)"))
          "missing-resource diagnostics retain importer, request and resolved path")
        (test.assert-true
          (error-matches?
            (load.compiler-load-expand-include-with-pools
              kind
              "tests/integration/include-entry.tl"
              "pkg:__missing_include__/payload.bin"
              cbi.compiler-builtin-id-fix-x
              (& (load_tests.compiler-load-string-vec-one "stdlib"))
              pools)
            "compiler-load: unknown package alias '__missing_include__': pkg:__missing_include__/payload.bin")
          "ordinary resolver errors survive include dispatch")
        (let
          [package-result : load.ResultCompilerLoadInclude
            (load.compiler-load-package-expand-include
              kind
              "tests/integration/include-entry.tl"
              "pkg:assets/include_bin_payload.bin"
              cbi.compiler-builtin-id-fix-x
              (& (load_tests.compiler-load-string-vec-one "stdlib"))
              "tests"
              (&
                (load.compiler-pkg-deps-cons
                  "assets"
                  "integration"
                  (& (load.compiler-pkg-deps-empty)))))]
          [active : ast.AstNodePoolContext
            (ast.ast-node-pool-context-capture-active)]
          (test.assert-true
            (match kind
              [(RuntimeString)
                (malformed-text-matches?
                  package-result
                  "pkg:assets/include_bin_payload.bin")]
              [_
                (include-matches?
                  kind
                  (& active)
                  package-result
                  (string.copy contents))])
            "package resolver preserves UTF-8 admission and every binary kind"))
        (set! ambient-count (ast.ast-node-pool-len))
        (set! index (+ index 1))))))

(test include-kind-matrix (check-includes))

(test
  include-utf8-text-exact-bytes
  (cbi.compiler-builtin-initialize-for-parse!)
  (let
    [contents : String
      (byte_buf.to-string
        (byte_buf.push (byte_buf.from-string "Aé€😀é\n") (cast 0 : u8)))]
    [directory : String
      (match (fs.try-create-temp-dir "typelisp-include-utf8")
        [(OkIoString path) path]
        [(ErrIoString error) (io.panic (io.error-message error))])]
    [path : String (fs.path-join (& directory) "payload.txt")]
    [entry : String (fs.path-join (& directory) "entry.tl")]
    [pools : ast.AstNodePoolContext
      (ast.ast-node-pool-context-new-with-capacities 1 1)]
    (load_tests.compiler-load-write-file-text
      (string.copy (& path))
      (string.copy (& contents)))
    (test.assert-true
      (include-matches?
        load.CompilerLoadIncludeKind.RuntimeString
        (& pools)
        (load.compiler-load-expand-include-with-pools
          load.CompilerLoadIncludeKind.RuntimeString
          (string.copy (& entry))
          "payload.txt"
          cbi.compiler-builtin-id-fix-x
          (& (load_tests.compiler-load-string-vec-one "stdlib"))
          pools)
        (string.copy (& contents)))
      "valid text include retains every UTF-8 byte")
    (test.assert-i64-eq
      (fs.remove-file-status (& path))
      0
      "remove own include payload")
    (test.assert-i64-eq
      (fs.remove-dir-status (& directory))
      0
      "remove own include directory")))

;; The ordinary inline harness deliberately uses an empty embedded payload.
;; Linux's alternate accepted separator forces fallback even inside the repo.
;; Running this native entry outside the repo exercises fallback on both OSes;
;; inside it, Windows resolves the real file instead. Each kind is checked
;; against the source the loader reads, which an `.tl` LZSS include embeds
;; with its inline tests blanked (#8713) and prose comments cut (#8659).
(cfg
  (not test)
  (define (main) : i64
    (let
      [_builtins : unit (cbi.compiler-builtin-initialize-for-parse!)]
      [kinds : (Array load.CompilerLoadIncludeKind 4) (include-kinds)]
      [pools : ast.AstNodePoolContext
        (ast.ast-node-pool-context-new-with-capacities 1 1)]
      [index : i64 0]
      [resolved : String (cfg linux "stdlib\\option.tl" "stdlib/option.tl")]
      (match (embedded.compiler-embedded-stdlib-lookup "option.tl")
        [(CompilerEmbeddedStdlibSomeSource contents)
          (let
            [source : String
              (if (io.file-exists? (string.copy resolved))
                (load.compiler-load-read-file-text (string.copy resolved))
                contents)]
            (while (< index 4)
              (let
                [kind : load.CompilerLoadIncludeKind (array-ref kinds index)]
                (test.assert-true
                  (include-matches?
                    kind
                    (& pools)
                    (load.compiler-load-include-from-resolved-with-pools
                      kind
                      "entry.tl"
                      "stdlib/option.tl"
                      (string.copy resolved)
                      cbi.compiler-builtin-id-fix-x
                      pools)
                    (match kind
                      [(LzssString)
                        (embedded.compiler-embedded-stdlib-payload-source
                          (string.copy source))]
                      [_ (string.copy source)]))
                  "embedded fallback retains every materialization kind")
                (set! index (+ index 1))))
            42)]
        [_ 0]))))