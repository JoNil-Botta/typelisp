;; compiler_lower_smoke.tl - Runnable smoke for compiler_lower.tl.
(import stdlib.byte_buf)
(import stdlib.io)
(import stdlib.string)
(import stdlib.text_buf)
(import stdlib.vector)
(import (vector.vector String) as svec)
(import compiler_builtin_ids as cbi)
(import compiler_driver_core)
(import compiler_backend as backend)
(import compiler_lower_tests)
(import compiler_lower)
(import compiler_diagnostic as diagnostic)
(import compiler_parse_core as parser)
(import compiler_ast_types as ast)
(import compiler_ir_types as ir)
(import compiler_load as load)
(import sym_i64_env)

(define (compiler-lower-smoke-write-text [path : String] [contents : String]) : unit
  (io.write-file path (byte_buf.str-as-bytes (& contents))))

(define (compiler-lower-smoke-foreach-multi-output-source) : String
  "(define (fill [a : (Array i64)] [b : (Array i64)] [out-x : (Array i64)] [out-y : (Array i64)] [n : i64] [scale : i64] [offset : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (begin
      (array-set! out-x i (+ (* (array-ref a i) scale) (array-ref b i)))
      (array-set! out-y i (+ (* (array-ref a i) scale) offset)))))")

(define (compiler-lower-smoke-foreach-multi-output-same-destination-source) : String
  "(define (fill [a : (Array i64)] [out : (Array i64)] [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (begin
      (array-set! out i (+ (array-ref a i) 1))
      (array-set! out i (+ (array-ref a i) 2)))))")

(define (compiler-lower-smoke-foreach-multi-output-alias-source) : String
  "(define (fill [out-x : (Array i64)] [out-y : (Array i64)] [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (begin
      (array-set! out-x i (+ (array-ref out-x i) 1))
      (array-set! out-y i (+ (array-ref out-x i) 2)))))")

(define (compiler-lower-smoke-foreach-multi-output-mixed-source) : String
  "(define (fill [a : (Array i64)] [b : (Array i32)] [out-x : (Array i64)] [out-y : (Array i32)] [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (begin
      (array-set! out-x i (+ (array-ref a i) 1))
      (array-set! out-y i (+ (array-ref b i) 2)))))")

(define (compiler-lower-smoke-foreach-multi-output-mode-shape-ok?
  [mode : compiler_lower.CompilerLowerMode]
  [predicated? : bool]) : bool
  (match (compiler_lower.lower-compiler-source-with-mode
    (compiler-lower-smoke-foreach-multi-output-source)
    mode)
    [(compiler_lower.ResultCompilerLower.Ok program _)
      (match program
        [(ir.CompilerIrProgram.Program _ functions _)
          (and
            (=
              (compiler_lower_tests.lower-test-function-vector-load-count
                functions
                "fill")
              2)
            (=
              (compiler_lower_tests.lower-test-function-vector-binop-count
                functions
                "fill")
              (if predicated?
                6
                3))
            (=
              (compiler_lower_tests.lower-test-function-vector-store-count
                functions
                "fill")
              2)
            (=
              (compiler_lower_tests.lower-test-function-predicated-load-count
                functions
                "fill")
              (if predicated?
                2
                0))
            (=
              (compiler_lower_tests.lower-test-function-predicated-store-count
                functions
                "fill")
              (if predicated?
                2
                0))
            (=
              (compiler_lower_tests.lower-test-function-tail-mask-count
                functions
                "fill")
              (if predicated?
                1
                0))
            (>
              (compiler_lower_tests.lower-test-function-store-ptr-count
                functions
                "fill")
              0))])]
    [(compiler_lower.ResultCompilerLower.Err _) false]))

(define (compiler-lower-smoke-foreach-multi-output-shape-ok?) : bool
  (and
    (compiler-lower-smoke-foreach-multi-output-mode-shape-ok?
      (compiler_lower.CompilerLowerMode.Avx2)
      false)
    (compiler-lower-smoke-foreach-multi-output-mode-shape-ok?
      (compiler_lower.CompilerLowerMode.Avx512)
      true)
    (compiler_lower_tests.compiler-lower-mode-error-ok?
      (compiler-lower-smoke-foreach-multi-output-same-destination-source)
      (compiler_lower.CompilerLowerMode.Avx2)
      (compiler_lower.lower-simd-foreach-fallback-diagnostic))
    (compiler_lower_tests.compiler-lower-mode-error-ok?
      (compiler-lower-smoke-foreach-multi-output-alias-source)
      (compiler_lower.CompilerLowerMode.Avx2)
      (compiler_lower.lower-simd-foreach-fallback-diagnostic))
    (compiler_lower_tests.compiler-lower-mode-error-ok?
      (compiler-lower-smoke-foreach-multi-output-mixed-source)
      (compiler_lower.CompilerLowerMode.Avx2)
      (compiler_lower.lower-simd-foreach-fallback-diagnostic))))

;; Scalar `spmd-reduce` addend split: a `sum` over `(+ X U)` with
;; reduction-invariant `U` lowers to a loop that accumulates only `X` plus one
;; exit `(* trip-count U)` (visible as a single `Mul` in the lowered IR), while
;; the guarded-away shapes keep the per-iteration add (no `Mul`).
(define (compiler-lower-smoke-spmd-reduce-split-source) : String
  "(define (reduce_split_pos [a : (Array i64)] [n : i64] [r : i64]) : i64
  (spmd-reduce sum ([i : i64 0 n]) 0 (+ (array-ref a i) r)))
(define (reduce_split_pos_swapped [a : (Array i64)] [n : i64] [r : i64]) : i64
  (spmd-reduce sum ([i : i64 0 n]) 0 (+ r (array-ref a i))))
(define (reduce_split_neg_i32 [g : (Array i32)] [n : i64] [r : i32]) : i32
  (spmd-reduce sum ([i : i64 0 n]) (cast 0 : i32) (+ (array-ref g i) r)))
(define (reduce_split_neg_index [a : (Array i64)] [n : i64]) : i64
  (spmd-reduce sum ([i : i64 0 n]) 0 (+ (array-ref a i) i)))
(define (reduce_split_neg_rebind [a : (Array i64)] [n : i64] [r : i64]) : i64
  (spmd-reduce sum ([i : i64 0 n]) 0 (+ (let [r : i64 9] (+ (array-ref a i) r)) r)))")

(define (compiler-lower-smoke-spmd-reduce-split-ok?) : bool
  (match (compiler_lower.lower-compiler-source-with-mode
    (compiler-lower-smoke-spmd-reduce-split-source)
    (compiler_lower.CompilerLowerMode.Scalar))
    [(compiler_lower.ResultCompilerLower.Ok program _)
      (match program
        [(ir.CompilerIrProgram.Program _ functions _)
          (and
            (=
              (compiler_lower_tests.lower-test-function-binop-op-count
                functions
                "reduce_split_pos"
                ir.CompilerIrBinOp.Mul)
              1)
            (=
              (compiler_lower_tests.lower-test-function-binop-op-count
                functions
                "reduce_split_pos_swapped"
                ir.CompilerIrBinOp.Mul)
              1)
            (=
              (compiler_lower_tests.lower-test-function-binop-op-count
                functions
                "reduce_split_neg_i32"
                ir.CompilerIrBinOp.Mul)
              0)
            (=
              (compiler_lower_tests.lower-test-function-binop-op-count
                functions
                "reduce_split_neg_index"
                ir.CompilerIrBinOp.Mul)
              0)
            (=
              (compiler_lower_tests.lower-test-function-binop-op-count
                functions
                "reduce_split_neg_rebind"
                ir.CompilerIrBinOp.Mul)
              0))])]
    [(compiler_lower.ResultCompilerLower.Err _) false]))

(define (compiler-lower-smoke-imported-local-vector-source) : String
  "(module stdlib.vector)
(define (local-vector-string) : String \"a\")
(module main)
(import stdlib.vector)
(define (main) : i64
  (__tl_string_length (vector.local-vector-string)))")

(define (compiler-lower-smoke-imported-local-vector-ok?) : bool
  (match (compiler_lower.lower-compiler-source
    (compiler-lower-smoke-imported-local-vector-source))
    [(compiler_lower.ResultCompilerLower.Ok _ _) true]
    [(compiler_lower.ResultCompilerLower.Err _) false]))

(define (compiler-lower-smoke-imported-nullary-file-ok?) : bool
  (let
    [root : String "target/lower_nullary_stdlib"]
    [dep : String "target/lower_nullary_stdlib/maybe_string.tl"]
    [entry : String "target/lower_nullary_entry.tl"]
    [roots : svec.Vec
      (let
        [items : svec.Vec (svec.new)]
        (begin
          (svec.push (&mut items) root)
          items))]
    (begin
      (load.compiler-load-test-mkdir root)
      (compiler-lower-smoke-write-text
        dep
        "(module stdlib.maybe_string)
(defenum MaybeString (No) (Some String))
(define (maybe-string-single [value : String]) : MaybeString
  (MaybeString.Some value))")
      (compiler-lower-smoke-write-text
        entry
        "(import stdlib.maybe_string)
(define (main) : i64
  (__tl_string_length
    (match (maybe_string.maybe-string-single \"a\")
      [(maybe_string.MaybeString.No) \"\"]
      [(maybe_string.MaybeString.Some head) head])))")
      (match (load.compiler-load-file-with-paths-and-roots
        entry
        (sym_i64_env.sym-i64-empty)
        roots)
        [(load.ResultCompilerLoadWithPaths.Ok decls paths _ _)
          (match (compiler_lower.lower-compiler-program-with-decl-paths
            entry
            (ast.ast-program decls)
            paths)
            [(compiler_lower.ResultCompilerLower.Ok _ _) true]
            [(compiler_lower.ResultCompilerLower.Err diag)
              (io.panic (diagnostic.compiler-diagnostic-message (box-get diag)))])]
        [(load.ResultCompilerLoadWithPaths.Err diag)
          (io.panic (diagnostic.compiler-diagnostic-message (box-get diag)))]))))

(define (compiler-lower-smoke-stdlib-args-ok?) : bool
  (let
    [roots : svec.Vec
      (let
        [items : svec.Vec (svec.new)]
        (begin
          (svec.push (&mut items) "stdlib")
          items))]
    (begin
      (compiler_driver_core.compiler-driver-reset-file-state!)
      (match (compiler_driver_core.compiler-driver-load-and-lower-escaping
        "stdlib/args.tl"
        (backend.CompilerBackendTarget.Linux)
        roots
        (backend.CompilerBackendMode.Scalar)
        (compiler_driver_core.compiler-driver-target-cfgs
          (backend.CompilerBackendTarget.Linux)
          (parser.compiler-cfg-empty)))
        [(compiler_driver_core.ResultCompilerDriverLowered.Ok _ _ _ _) true]
        [(compiler_driver_core.ResultCompilerDriverLowered.Err _) false]))))

(define (compiler-lower-smoke-module-macro-stdlib-vector-import-no-main-source) : String
  "(defmacro (vector-user) : Module
  `(begin
    (module generated.lower_vector_user_no_main)
    (import stdlib.vector)
(import (vector.vector String) as svec)
    (defstruct T
      (value i64))
    (import (vector.vector T) as vec)
    (define (make [value : i64]) : T
      (T value))
    (define (score [first : T] [fallback : T]) : i64
      (let
        [items : vec.Vec (vec.new)]
        (begin
          (vec.push (&mut items) first)
          (if (= (vec.len (& items)) 1)
            (begin
              (vec.get (& items) 0 fallback)
              42)
            0))))))
(import (vector-user) as user)")

(define (compiler-lower-smoke-module-macro-stdlib-vector-import-no-main-ok?) : bool
  (match (compiler_lower.lower-compiler-source
    (compiler-lower-smoke-module-macro-stdlib-vector-import-no-main-source))
    [(compiler_lower.ResultCompilerLower.Ok _ _) true]
    [(compiler_lower.ResultCompilerLower.Err _) false]))

(define (compiler-lower-smoke-module-macro-vector-no-main-ir-ok?) : bool
  (let
    [path : String "target/lower_module_macro_vector_no_main.tl"]
    [roots : svec.Vec
      (let
        [items : svec.Vec (svec.new)]
        (begin
          (svec.push (&mut items) "stdlib")
          items))]
    (begin
      (compiler-lower-smoke-write-text
        path
        (compiler-lower-smoke-module-macro-stdlib-vector-import-no-main-source))
      (match (compiler_driver_core.compiler-driver-emit-ir-summary-file-with-target-roots-level-mode-and-cfg
        path
        (backend.CompilerBackendTarget.Linux)
        roots
        0
        (backend.CompilerBackendMode.Scalar)
        (parser.compiler-cfg-empty))
        [(compiler_driver_core.ResultCompilerDriver.Ok _) true]
        [(compiler_driver_core.ResultCompilerDriver.Err diag)
          (io.panic (diagnostic.compiler-diagnostic-message (box-get diag)))]))))

(define (compiler-lower-smoke-direct-no-main-keeps-source-symbols?) : bool
  (let
    [path : String "target/lower_direct_no_main_symbols.tl"]
    [roots : svec.Vec
      (let
        [items : svec.Vec (svec.new)]
        (begin
          (svec.push (&mut items) "stdlib")
          items))]
    (begin
      (compiler-lower-smoke-write-text
        path
        "(define (no-main-direct-helper) : i64 7)")
      (compiler_lower.lower-no-main-entry-prune-set! true)
      (compiler_driver_core.compiler-driver-reset-file-state!)
      (match (compiler_driver_core.compiler-driver-emit-file-buffer-with-target-roots-level-mode-and-cfg
        path
        (backend.CompilerBackendTarget.Linux)
        true
        roots
        0
        (backend.CompilerBackendMode.Scalar)
        (parser.compiler-cfg-empty))
        [(compiler_driver_core.ResultCompilerDriverBuffer.Ok buf)
          (let
            [asm : String (text_buf.render buf)]
            [needle : String
              "_tl_lower_direct_no_main_symbols_no_main_direct_helper:"]
            (string.contains (& asm) (& needle)))]
        [(compiler_driver_core.ResultCompilerDriverBuffer.Err diag)
          (io.panic (diagnostic.compiler-diagnostic-message (box-get diag)))]))))

;; P4/C4.3 per-instantiation typecheck-completeness regression.
;;
;; A generated module is materialized in FULL and typechecked in full,
;; independent of which of its methods a consumer references, because the
;; reachability gate now runs AFTER typecheck (see
;; lower-compiler-expanded-program-with-decl-paths-mode-cache-active-and-pools).
;; Referencing `push` only vs. `push` + `map` therefore adds zero new typecheck
;; work on the (vector C43Point) module and cannot surface a new type error from
;; its body. Both variants must lower cleanly.
(define (compiler-lower-smoke-c43-vector-push-only-source) : String
  "(import stdlib.vector)
(defstruct C43Point (x i64) (y i64))
(import (vector.vector C43Point) as pvec)
(define (main) : i64
  (let
    [v : pvec.Vec (pvec.new)]
    (begin
      (pvec.push (&mut v) (C43Point 1 2))
      (pvec.len (& v)))))")

(define (compiler-lower-smoke-c43-vector-push-map-source) : String
  "(import stdlib.vector)
(defstruct C43Point (x i64) (y i64))
(import (vector.vector C43Point) as pvec)
(define (c43-bump [p : C43Point]) : C43Point
  (C43Point (+ (struct-get p x) 1) (struct-get p y)))
(define (main) : i64
  (let
    [v : pvec.Vec (pvec.new)]
    (begin
      (pvec.push (&mut v) (C43Point 1 2))
      (let
        [w : pvec.Vec (pvec.map (& v) c43-bump)]
        (pvec.len (& w))))))")

;; A hand-written function that is UNREACHABLE from main but has a type error in
;; its body. With the reachability gate positioned before typecheck (pre-P4) it
;; was pruned and the error was silently missed at `compile`; P4 typechecks the
;; whole program, so this MUST be rejected. Guards against re-gating typecheck.
(define (compiler-lower-smoke-c43-unreachable-error-source) : String
  "(import stdlib.vector)
(defstruct C43Point (x i64) (y i64))
(import (vector.vector C43Point) as pvec)
(define (main) : i64
  (let
    [v : pvec.Vec (pvec.new)]
    (begin
      (pvec.push (&mut v) (C43Point 1 2))
      (pvec.len (& v)))))
(define (c43-dead [s : String]) : i64 (+ s 1))")

(define (compiler-lower-smoke-c43-vector-push-only-ok?) : bool
  (match (compiler_lower.lower-compiler-source
    (compiler-lower-smoke-c43-vector-push-only-source))
    [(compiler_lower.ResultCompilerLower.Ok _ _) true]
    [(compiler_lower.ResultCompilerLower.Err _) false]))

(define (compiler-lower-smoke-c43-vector-push-map-ok?) : bool
  (match (compiler_lower.lower-compiler-source
    (compiler-lower-smoke-c43-vector-push-map-source))
    [(compiler_lower.ResultCompilerLower.Ok _ _) true]
    [(compiler_lower.ResultCompilerLower.Err _) false]))

(define (compiler-lower-smoke-c43-unreachable-error-rejected?) : bool
  (match (compiler_lower.lower-compiler-source
    (compiler-lower-smoke-c43-unreachable-error-source))
    [(compiler_lower.ResultCompilerLower.Ok _ _) false]
    [(compiler_lower.ResultCompilerLower.Err _) true]))

(define (compiler-lower-smoke-c43-typecheck-completeness-ok?) : bool
  (begin
    (unless
      (compiler-lower-smoke-c43-vector-push-only-ok?)
      (io.panic
        "lower/C4.3: (vector C43Point) referencing only push must fully typecheck"))
    (unless
      (compiler-lower-smoke-c43-vector-push-map-ok?)
      (io.panic
        "lower/C4.3: adding a map call must not surface a new type error"))
    (unless
      (compiler-lower-smoke-c43-unreachable-error-rejected?)
      (io.panic
        "lower/C4.3: an unreachable type error must be caught (typecheck is not reachability-gated)"))
    true))

(define (compiler-lower-smoke-issue3494-ok?) : bool
  (begin
    (unless
      (compiler-lower-smoke-imported-local-vector-ok?)
      (io.panic "lower: issue3494 imported local vector failed"))
    (unless
      (compiler-lower-smoke-imported-nullary-file-ok?)
      (io.panic "lower: issue3494 imported nullary file failed"))
    (unless
      (compiler-lower-smoke-stdlib-args-ok?)
      (io.panic "lower: issue3494 stdlib args failed"))
    (unless
      (compiler-lower-smoke-module-macro-vector-no-main-ir-ok?)
      (io.panic "lower: no-main module macro vector IR failed"))
    (unless
      (compiler-lower-smoke-direct-no-main-keeps-source-symbols?)
      (io.panic "lower: direct no-main compile pruned source symbol"))
    (unless
      (compiler-lower-smoke-module-macro-stdlib-vector-import-no-main-ok?)
      (io.panic "lower: no-main module macro vector import failed"))
    true))

(define (compiler-lower-smoke-module-entry-main-check) : unit
  (match (parser.parse-ast-source
    (compiler_lower_tests.compiler-lower-module-entry-main-source))
    [(parser.ResultAstProgram.Ok program)
      (match (compiler_lower.lower-compiler-program-with-decl-paths
        "stdlib/arena.tl"
        program
        (ast.ast-decl-path-list-new))
        [(compiler_lower.ResultCompilerLower.Ok lowered _)
          (match lowered
            [(ir.CompilerIrProgram.Program _ functions _)
              (begin
                (unless
                  (compiler_lower_tests.lower-test-function-defined?
                    functions
                    "main")
                  (io.panic "lower: module entry main function missing"))
                (unless
                  (compiler_lower_tests.lower-test-function-defined?
                    functions
                    "arena.tl::stdlib.arena/helper")
                  (io.panic "lower: module entry helper function missing"))
                (let
                  [path-count : i64
                    (compiler_lower_tests.lower-test-function-direct-call-count
                      functions
                      "main"
                      "arena.tl::stdlib.arena/helper")]
                  [module-count : i64
                    (compiler_lower_tests.lower-test-function-direct-call-count
                      functions
                      "main"
                      "stdlib.arena/helper")]
                  [bare-count : i64
                    (compiler_lower_tests.lower-test-function-direct-call-count
                      functions
                      "main"
                      "helper")]
                  (unless
                    (= path-count 1)
                    (if (= module-count 1)
                      (io.panic "lower: module entry main uses module helper")
                      (if (= bare-count 1)
                        (io.panic "lower: module entry main uses bare helper")
                        (io.panic
                          "lower: module entry main helper call missing"))))))])]
        [(compiler_lower.ResultCompilerLower.Err diag)
          (io.panic (diagnostic.compiler-diagnostic-message (box-get diag)))])]
    [(parser.ResultAstProgram.Err _)
      (io.panic "lower: module entry main parse failed")]))

(define (compiler-lower-smoke-stdlib-string-public-substring-source) : String
  "(module stdlib.runtime)
(define (substring [src : (Ptr u8)] [start : i64] [len : i64]) : String
  (unsafe (string-from-bytes (ptr-offset src start) len)))
(module stdlib.string)
(define (substring [text : String] [start : i64] [len : i64]) : String
  text)
(define (main) : String
  (substring \"abc\" 0 1))")

(define (compiler-lower-smoke-stdlib-string-public-substring-paths) : ast.AstDeclPathList
  (ast.ast-decl-root-path-cons
    "stdlib/runtime.tl"
    (ast.ast-decl-root-path-cons
      "stdlib/runtime.tl"
      (ast.ast-decl-root-path-cons
        "stdlib/string.tl"
        (ast.ast-decl-root-path-cons
          "stdlib/string.tl"
          (ast.ast-decl-root-path-cons
            "stdlib/string.tl"
            (ast.ast-decl-path-list-new)))))))

(define (compiler-lower-smoke-stdlib-runtime-substring-defined?
  [functions : ir.CompilerIrFunctionList]) : bool
  (or
    (compiler_lower_tests.lower-test-function-defined?
      functions
      "stdlib/runtime.tl::substring")
    (compiler_lower_tests.lower-test-function-defined?
      functions
      "runtime.tl::substring")
    (compiler_lower_tests.lower-test-function-defined?
      functions
      "stdlib/runtime.tl::stdlib.runtime/substring")
    (compiler_lower_tests.lower-test-function-defined?
      functions
      "runtime.tl::stdlib.runtime/substring")
    (compiler_lower_tests.lower-test-function-defined?
      functions
      "stdlib.runtime/substring")))

(define (compiler-lower-smoke-stdlib-string-public-substring-defined?
  [functions : ir.CompilerIrFunctionList]) : bool
  (or
    (compiler_lower_tests.lower-test-function-defined?
      functions
      "stdlib/string.tl::stdlib.string/substring")
    (compiler_lower_tests.lower-test-function-defined?
      functions
      "string.tl::stdlib.string/substring")))

(define (compiler-lower-smoke-stdlib-string-public-substring-reachable-ok?) : bool
  (match (parser.parse-ast-source
    (compiler-lower-smoke-stdlib-string-public-substring-source))
    [(parser.ResultAstProgram.Ok program)
      (match (compiler_lower.lower-compiler-program-with-decl-paths
        "stdlib/string.tl"
        program
        (compiler-lower-smoke-stdlib-string-public-substring-paths))
        [(compiler_lower.ResultCompilerLower.Ok lowered _)
          (match lowered
            [(ir.CompilerIrProgram.Program _ functions _)
              (and
                (not
                  (compiler-lower-smoke-stdlib-runtime-substring-defined?
                    functions))
                (compiler-lower-smoke-stdlib-string-public-substring-defined?
                  functions))])]
        [(compiler_lower.ResultCompilerLower.Err _) false])]
    [(parser.ResultAstProgram.Err _) false]))

(define (compiler-lower-smoke-self-test) : unit
  (begin
    (unless
      (compiler_lower_tests.compiler-lower-and-or-short-circuit-shape-ok?)
      (io.panic "lower: and/or short-circuit smoke mismatch"))
    (unless
      (compiler_lower_tests.compiler-lower-entry-moduled-main-ok?)
      (io.panic "lower: entry moduled main smoke mismatch"))
    (unless
      (compiler_lower_tests.compiler-lower-ok-summary?
        (compiler_lower_tests.compiler-lower-smoke-source))
      (io.panic "lower: basic summary smoke mismatch"))
    (unless
      (compiler_lower_tests.compiler-lower-ok?
        (compiler_lower_tests.compiler-lower-macro-expand-source))
      (io.panic "lower: macro expand smoke mismatch"))
    (unless
      (compiler_lower_tests.compiler-lower-ok?
        (compiler_lower_tests.compiler-lower-macro-expr-clause-source))
      (io.panic "lower: macro expr clause smoke mismatch"))
    (unless
      (compiler_lower_tests.compiler-lower-ok?
        (compiler_lower_tests.compiler-lower-macro-expr-clause-variadic-source))
      (io.panic "lower: macro variadic clause smoke mismatch"))
    (unless
      (compiler_lower_tests.compiler-lower-ok?
        (compiler_lower_tests.compiler-lower-macro-hygiene-definition-source))
      (io.panic "lower: macro hygiene definition smoke mismatch"))
    (unless
      (compiler_lower_tests.compiler-lower-error-ok?
        (compiler_lower_tests.compiler-lower-macro-arity-source)
        "macro call has too few arguments")
      (io.panic "lower: macro arity diagnostic smoke mismatch"))
    (unless
      (compiler_lower_tests.compiler-lower-error-ok?
        "(import stdlib.comptime)
(define (main) : i64
  (comptime.error \"runtime forbidden\"))"
        "lower: comptime-error is compile-time only")
      (io.panic "lower: comptime-error runtime diagnostic smoke mismatch"))
    (unless
      (compiler_lower_tests.compiler-lower-error-ok?
        (compiler_lower_tests.compiler-lower-macro-expr-clause-to-expr-error-source)
        "typecheck: macro operand type mismatch: expected Expr, got bracket clause")
      (io.panic "lower: macro clause-to-expr diagnostic smoke mismatch"))
    (unless
      (compiler_lower_tests.compiler-lower-error-ok?
        (compiler_lower_tests.compiler-lower-macro-expr-to-clause-error-source)
        "typecheck: ExprClause macro operand expects bracket syntax")
      (io.panic "lower: macro expr-to-clause diagnostic smoke mismatch"))
    (unless
      (compiler_lower_tests.compiler-lower-error-ok?
        (compiler_lower_tests.compiler-lower-macro-expr-clause-shape-error-source)
        "typecheck: ExprClause macro operand expects bracket clause [expr expr]")
      (io.panic "lower: macro clause shape diagnostic smoke mismatch"))
    (unless
      (compiler_lower_tests.compiler-lower-error-ok?
        (compiler_lower_tests.compiler-lower-bracket-ordinary-call-error-source)
        "typecheck: bracket clause is only valid as an ExprClause or ExprBindingClause macro operand")
      (io.panic "lower: bracket ordinary-call diagnostic smoke mismatch"))
    (unless
      (compiler_lower_tests.compiler-lower-spans-ok?
        (compiler_lower_tests.compiler-lower-smoke-source))
      (io.panic "lower: source span smoke mismatch"))
    (unless
      (compiler_lower_tests.compiler-lower-nested-expression-diagnostic-span-ok?)
      (io.panic "lower: nested diagnostic span smoke mismatch"))
    (unless
      (compiler_lower_tests.compiler-lower-compound-expression-diagnostic-span-ok?)
      (io.panic "lower: compound diagnostic span smoke mismatch"))
    (unless
      (compiler_lower_tests.compiler-lower-ok?
        (compiler_lower_tests.compiler-lower-match-source))
      (io.panic "lower: match smoke mismatch"))
    (unless
      (compiler_lower_tests.compiler-lower-match-tail-shape-ok?
        (compiler_lower_tests.compiler-lower-match-source))
      (io.panic "lower: match tail smoke mismatch"))
    (unless
      (compiler_lower_tests.compiler-lower-ok?
        (compiler_lower_tests.compiler-lower-enum-match-source))
      (io.panic "lower: enum match smoke mismatch"))
    (unless
      (compiler_lower_tests.compiler-lower-ok?
        (compiler_lower_tests.compiler-lower-enum-literal-payload-source))
      (io.panic "lower: enum literal payload smoke mismatch"))
    (unless
      (compiler_lower_tests.compiler-lower-ok?
        (compiler_lower_tests.compiler-lower-enum-nested-payload-source))
      (io.panic "lower: enum nested payload smoke mismatch"))
    (unless
      (compiler_lower_tests.compiler-lower-ok?
        (compiler_lower_tests.compiler-lower-enum-string-literal-payload-source))
      (io.panic "lower: enum string payload smoke mismatch"))
    (unless
      (compiler_lower_tests.compiler-lower-enum-string-literal-payload-shape-ok?)
      (io.panic "lower: enum string payload shape smoke mismatch"))
    (unless
      (compiler_lower_tests.compiler-lower-ok?
        (compiler_lower_tests.compiler-lower-borrowed-enum-match-source))
      (io.panic "lower: borrowed enum match smoke mismatch"))
    (unless
      (compiler_lower_tests.compiler-lower-ok?
        (compiler_lower_tests.compiler-lower-borrowed-enum-match-ref-struct-array-source))
      (io.panic "lower: borrowed enum ref struct array smoke mismatch"))
    (unless
      (compiler_lower_tests.compiler-lower-ok?
        (compiler_lower_tests.compiler-lower-borrowed-enum-match-str-source))
      (io.panic "lower: borrowed enum str smoke mismatch"))
    (unless
      (compiler_lower_tests.compiler-lower-ok?
        (compiler_lower_tests.compiler-lower-borrowed-enum-match-nested-source))
      (io.panic "lower: borrowed enum nested smoke mismatch"))
    (unless
      (compiler_lower_tests.compiler-lower-ok?
        (compiler_lower_tests.compiler-lower-export-source))
      (io.panic "lower: export smoke mismatch"))
    (unless
      (compiler_lower_tests.compiler-lower-defdispatch-thunk-shape-ok?)
      (io.panic "lower: defdispatch thunk smoke mismatch"))
    (unless
      (compiler_lower_tests.compiler-lower-defdispatch-shared-helper-ok?)
      (io.panic "lower: defdispatch shared helper smoke mismatch"))
    (unless
      (compiler_lower_tests.compiler-lower-ok?
        (compiler_lower_tests.compiler-lower-result-try-source))
      (io.panic "lower: result try smoke mismatch"))
    (unless
      (compiler_lower_tests.compiler-lower-ok?
        (compiler_lower_tests.compiler-lower-option-try-source))
      (io.panic "lower: option try smoke mismatch"))
    (unless
      (compiler_lower_tests.compiler-lower-enum-match-shape-ok?
        (compiler_lower_tests.compiler-lower-enum-match-source))
      (io.panic "lower: enum match shape smoke mismatch"))
    (unless
      (compiler_lower_tests.compiler-lower-two-variant-fallthrough-shape-ok?)
      (io.panic "lower: two-variant final fallthrough smoke mismatch"))
    (unless
      (compiler_lower_tests.compiler-lower-total-enum-provenance-shape-ok?)
      (io.panic "lower: total-enum provenance smoke mismatch"))
    (unless
      (compiler_lower_tests.compiler-lower-borrowed-enum-match-shape-ok?)
      (io.panic "lower: borrowed enum match shape smoke mismatch"))
    (unless
      (compiler_lower_tests.compiler-lower-result-try-shape-ok?
        (compiler_lower_tests.compiler-lower-result-try-source))
      (io.panic "lower: result try shape smoke mismatch"))
    (unless
      (compiler_lower_tests.compiler-lower-option-try-shape-ok?)
      (io.panic "lower: option try shape smoke mismatch"))
    (unless
      (compiler_lower_tests.compiler-lower-return-shape-ok?)
      (io.panic "lower: return smoke mismatch"))
    (unless
      (compiler_lower_tests.compiler-lower-return-with-arena-shape-ok?)
      (io.panic "lower: return with arena smoke mismatch"))
    (unless
      (compiler_lower_tests.compiler-lower-resource-with-shape-ok?)
      (io.panic "lower: resource-with smoke mismatch"))
    (unless
      (compiler_lower_tests.compiler-lower-resource-with-nested-shape-ok?)
      (io.panic "lower: nested resource-with smoke mismatch"))
    (unless
      (compiler_lower_tests.compiler-lower-cleanup-struct-shape-ok?)
      (io.panic "lower: cleanup struct smoke mismatch"))
    (unless
      (compiler_lower_tests.compiler-lower-cleanup-struct-nested-shape-ok?)
      (io.panic "lower: nested cleanup struct smoke mismatch"))
    (unless
      (compiler_lower_tests.compiler-lower-ok?
        (compiler_lower_tests.compiler-lower-array-length-source))
      (io.panic "lower: array length smoke mismatch"))
    (unless
      (compiler_lower_tests.compiler-lower-array-access-shape-ok?
        (compiler_lower_tests.compiler-lower-array-access-source))
      (io.panic "lower: array access smoke mismatch"))
    (unless
      (compiler_lower_tests.compiler-lower-array-take-shape-ok?)
      (io.panic "lower: array take smoke mismatch"))
    (unless
      (compiler_lower_tests.compiler-lower-fixed-array-access-shape-ok?
        (compiler_lower_tests.compiler-lower-fixed-array-access-source))
      (io.panic "lower: fixed array access smoke mismatch"))
    (unless
      (compiler_lower_tests.compiler-lower-fixed-array-literal-stack-shape-ok?)
      (io.panic "lower: fixed array stack literal smoke mismatch"))
    (unless
      (compiler_lower_tests.compiler-lower-fixed-array-aggregate-layout-shape-ok?)
      (io.panic "lower: fixed array aggregate layout smoke mismatch"))
    (unless
      (compiler_lower_tests.compiler-lower-array-access-shape-ok?
        (compiler_lower_tests.compiler-lower-mut-ref-array-access-source))
      (io.panic "lower: mutable ref array access smoke mismatch"))
    (unless
      (compiler_lower_tests.compiler-lower-mut-ref-by-value-writeback-shape-ok?)
      (io.panic "lower: mutable ref writeback smoke mismatch"))
    (unless
      (compiler_lower_tests.compiler-lower-mut-ref-array-field-access-shape-ok?)
      (io.panic "lower: mutable ref array field smoke mismatch"))
    (unless
      (compiler_lower_tests.compiler-lower-array-push-shape-ok?
        (compiler_lower_tests.compiler-lower-array-push-source))
      (io.panic "lower: array push smoke mismatch"))
    (unless
      (compiler_lower_tests.compiler-lower-array-push-shape-ok?
        (compiler_lower_tests.compiler-lower-mut-ref-array-access-source))
      (io.panic "lower: mutable ref array push smoke mismatch"))
    (unless
      (compiler_lower_tests.compiler-lower-error-ok?
        (compiler_lower_tests.compiler-lower-fixed-array-push-source)
        "typecheck: array-push! requires dynamic array type")
      (io.panic "lower: fixed array push diagnostic smoke mismatch"))
    (unless
      (compiler_lower_tests.compiler-lower-make-array-shape-ok?
        (compiler_lower_tests.compiler-lower-make-array-source))
      (io.panic "lower: make-array smoke mismatch"))
    (unless
      (compiler_lower_tests.compiler-lower-make-array-init-shape-ok?
        (compiler_lower_tests.compiler-lower-make-array-init-source))
      (io.panic "lower: make-array init smoke mismatch"))
    (unless
      (compiler_lower_tests.compiler-lower-dyn-array-literal-shape-ok?)
      (io.panic "lower: dynamic array literal smoke mismatch"))
    (unless
      (compiler_lower_tests.compiler-lower-make-array-register-resident-zero-fill-shape-ok?)
      (io.panic "lower: make-array fill8 smoke mismatch"))
    (unless
      (compiler_lower_tests.compiler-lower-runtime-helper-tests-ok?)
      (io.panic "lower: runtime helper smoke mismatch"))
    (unless
      (compiler_lower_tests.compiler-lower-function-value-shape-ok?)
      (io.panic "lower: function value smoke mismatch"))
    (unless
      (compiler_lower_tests.compiler-lower-function-value-contextual-init-ok?)
      (io.panic "lower: contextual function value smoke mismatch"))
    (unless
      (compiler_lower_tests.compiler-lower-noncapturing-lambda-tests-ok?)
      (io.panic "lower: noncapturing lambda smoke mismatch"))
    (unless
      (compiler_lower_tests.compiler-lower-capturing-lambda-tests-ok?)
      (io.panic "lower: capturing lambda smoke mismatch"))
    (unless
      (compiler_lower_tests.compiler-lower-ok?
        (compiler_lower_tests.compiler-lower-aggregate-source))
      (io.panic "lower: aggregate smoke mismatch"))
    (unless
      (compiler_lower_tests.compiler-lower-ok?
        (compiler_lower_tests.compiler-lower-init-source))
      (io.panic "lower: init smoke mismatch"))
    (unless
      (compiler_lower_tests.compiler-lower-tuple-shape-ok?)
      (io.panic "lower: tuple smoke mismatch"))
    (unless
      (compiler_lower_tests.compiler-lower-ok?
        (compiler_lower_tests.compiler-lower-tuple-return-source))
      (io.panic "lower: tuple return smoke mismatch"))
    (unless
      (compiler_lower_tests.compiler-lower-clone-shape-ok?)
      (io.panic "lower: clone smoke mismatch"))
    (unless
      (compiler_lower_tests.compiler-lower-clone-dynarray-bulk-copy-ok?)
      (io.panic "lower: clone dynarray bulk smoke mismatch"))
    (unless
      (compiler_lower_tests.compiler-lower-clone-reachable-helpers-ok?)
      (io.panic "lower: clone reachable helpers smoke mismatch"))
    (unless
      (compiler_lower_tests.compiler-lower-error-ok?
        (compiler_lower_tests.compiler-lower-clone-unsupported-source)
        "typecheck: clone unsupported type (-> i64 i64)")
      (io.panic "lower: clone unsupported diagnostic smoke mismatch"))
    (unless
      (compiler_lower_tests.compiler-lower-inline-aggregate-tests-ok?)
      (io.panic "lower: inline aggregate smoke mismatch"))
    (unless
      (compiler_lower_tests.compiler-lower-ok?
        (compiler_lower_tests.compiler-lower-generated-decl-source))
      (io.panic "lower: comptime decl smoke mismatch"))
    (unless
      (compiler_lower_tests.compiler-lower-generated-paths-preserved-ok?)
      (io.panic "lower: generated paths smoke mismatch"))
    (unless
      (compiler_lower_tests.compiler-lower-module-symbols-ok?)
      (io.panic "lower: module symbols smoke mismatch"))
    (unless
      (compiler_lower_tests.compiler-lower-package-owned-symbols-ok?)
      (io.panic "lower: package-owned symbols smoke mismatch"))
    (compiler-lower-smoke-module-entry-main-check)
    (unless
      (compiler_lower_tests.compiler-lower-module-qualified-ok?)
      (io.panic "lower: module qualified smoke mismatch"))
    (unless
      (compiler_lower_tests.compiler-lower-import-alias-ok?)
      (io.panic "lower: import alias smoke mismatch"))
    (unless
      (compiler_lower_tests.compiler-lower-dotted-import-default-alias-ok?)
      (io.panic "lower: dotted import default alias smoke mismatch"))
    (unless
      (compiler_lower_tests.compiler-lower-dotted-import-string-call-ok?)
      (io.panic "lower: dotted import string call smoke mismatch"))
    (unless
      (compiler_lower_tests.compiler-lower-module-function-returning-struct-ok?)
      (io.panic "lower: module struct return smoke mismatch"))
    (unless
      (compiler_lower_tests.compiler-lower-module-function-returning-enum-ok?)
      (io.panic "lower: module enum return smoke mismatch"))
    (unless
      (compiler_lower_tests.compiler-lower-imported-enum-aggregate-payload-ok?)
      (io.panic "lower: imported enum aggregate payload smoke mismatch"))
    (unless
      (compiler_lower_tests.compiler-lower-module-macro-codegen-ok?)
      (io.panic "lower: module macro codegen smoke mismatch"))
    (unless
      (compiler_lower_tests.compiler-lower-module-macro-global-init-ok?)
      (io.panic "lower: module macro global init smoke mismatch"))
    (unless
      (compiler_lower_tests.compiler-lower-module-macro-stdlib-vector-import-ok?)
      (io.panic "lower: module macro stdlib vector import smoke mismatch"))
    (unless
      (compiler-lower-smoke-module-macro-stdlib-vector-import-no-main-ok?)
      (io.panic
        "lower: no-main module macro stdlib vector import smoke mismatch"))
    (unless
      (compiler_lower_tests.compiler-lower-function-decl-count-wrapped-ok?)
      (io.panic "lower: function decl count smoke mismatch"))
    (unless
      (compiler_lower_tests.compiler-lower-extern-link-metadata-ok?)
      (io.panic "lower: extern link metadata smoke mismatch"))
    (unless
      (compiler_lower_tests.compiler-lower-extern-value-fnptr-shape-ok?)
      (io.panic "lower: extern fnptr value smoke mismatch"))
    (unless
      (compiler_lower_tests.compiler-lower-c-abi-linux-tag-only-enum-shape-ok?)
      (io.panic "lower: linux tag-only enum C ABI smoke mismatch"))
    (unless
      (compiler_lower_tests.compiler-lower-c-abi-windows-enum-aggregate-shape-ok?)
      (io.panic "lower: windows enum aggregate C ABI smoke mismatch"))
    (unless
      (compiler_lower_tests.compiler-lower-c-abi-linux-payload-enum-shape-ok?)
      (io.panic "lower: linux payload enum C ABI smoke mismatch"))
    (unless
      (compiler_lower_tests.compiler-lower-c-abi-windows-byref-aggregate-shape-ok?)
      (io.panic "lower: windows byref aggregate C ABI smoke mismatch"))
    (unless
      (compiler_lower_tests.compiler-lower-c-abi-windows-small-float-aggregate-shape-ok?)
      (io.panic "lower: windows small float aggregate C ABI smoke mismatch"))
    (unless
      (compiler_lower_tests.compiler-lower-c-abi-windows-nested-small-aggregate-shape-ok?)
      (io.panic "lower: windows nested small aggregate C ABI smoke mismatch"))
    (unless
      (compiler_lower_tests.compiler-lower-windows-error-ok?
        (compiler_lower_tests.compiler-lower-c-abi-windows-unsupported-aggregate-source)
        "lower: unsupported windows-x86_64 C aggregate ABI for OuterText; this slice supports scalar structs of size 1, 2, 4, or 8 bytes, including nested scalar struct fields")
      (io.panic "lower: windows unsupported C ABI diagnostic smoke mismatch"))
    (unless
      (compiler_lower_tests.compiler-lower-global-shape-ok?)
      (io.panic "lower: global shape smoke mismatch"))
    (unless
      (compiler_lower_tests.compiler-lower-raw-pointer-ops-ok?)
      (io.panic "lower: raw pointer ops smoke mismatch"))
    (unless
      (compiler_lower_tests.compiler-lower-raw-pointer-call-value-shape-ok?)
      (io.panic "lower: raw pointer call value smoke mismatch"))
    (unless
      (compiler-lower-smoke-foreach-multi-output-shape-ok?)
      (io.panic "lower: multi-output foreach smoke mismatch"))
    (unless
      (compiler-lower-smoke-spmd-reduce-split-ok?)
      (io.panic "lower: spmd reduce addend split smoke mismatch"))
    (unless
      (compiler_lower_tests.compiler-lower-back-half-tests-ok?)
      (io.panic "lower: back-half smoke mismatch"))
    (unless
      (compiler-lower-smoke-stdlib-string-public-substring-reachable-ok?)
      (io.panic "lower: stdlib string public substring reachability mismatch"))))

(define (main) : i64
  (begin
    (cbi.compiler-builtin-initialize-for-parse!)
    (compiler-lower-smoke-self-test)
    (unless
      (compiler-lower-smoke-issue3494-ok?)
      (io.panic "lower: issue3494 smoke failed"))
    (unless
      (compiler-lower-smoke-c43-typecheck-completeness-ok?)
      (io.panic "lower: C4.3 typecheck-completeness smoke failed"))
    42))