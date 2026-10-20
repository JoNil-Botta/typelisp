;; One isolated canonical frontend job. Build with compiler-dependency-audit.
;; The parser/loader stream JSON facts; only successful frontend completion
;; writes the terminal event. No parsed summary is retained across cache reset.
(import compiler_load as load)
(import compiler_driver_core as driver)
(import compiler_typecheck_core as tc)
(import compiler_typecheck_api as typecheck)
(import compiler_ast_types as ast)
(import compiler_parse_core as parser)
(import compiler_diagnostic as diag)
(import compiler_dependency_trace as trace)
(import compiler_owned_view as owned)
(import sym_i64_env)
(import compiler_target_cfg_core as target_cfg)
(import stdlib.vector)
(import (vector.vector String) as strings)
(import stdlib.io)
(import stdlib.env)
(import stdlib.iterator)

(define (failure [boxed : (Box diag.CompilerDiagnostic)]) : i64
  (let
    [diagnostic : diag.CompilerDiagnostic (deref boxed)]
    (io.print-error (diag.compiler-diagnostic-render (& diagnostic))))
  2)

(define (check-failure [boxed : (Box diag.CompilerDiagnosticList)]) : i64
  (let
    [diagnostics : diag.CompilerDiagnosticList (deref boxed)]
    (for [index
      (iterator.range 0 (diag.compiler-diagnostic-list-count (& diagnostics)))]
      (io.print-error
        (diag.compiler-diagnostic-render
          (& (diag.compiler-diagnostic-list-get (& diagnostics) index)))))
    2))

(define (inspect [root : String] [cfgs : sym_i64_env.SymI64Env]) : i64
  ;; Architecture covers the complete import closure, including unused aliases.
  ;; The canonical eager-load mode keeps their transitive edges observable.
  (unless
    (env.set! "TYPELISP_LAZY_IMPORTS" "0")
    (io.print-error
      "dependency inspect: cannot enable complete import loading\n")
    (return 2))
  (let
    [roots : strings.Vec (strings.new)]
    (strings.push-ref! (&mut roots) "stdlib")
    (strings.push-ref! (&mut roots) "src")
    (match (driver.compiler-driver-load-file-with-runtime
      root
      (owned.compiler-owned-shared-view roots)
      (sym_i64_env.sym-i64-shared-view (& cfgs)))
      [(load.ResultCompilerLoadWithPaths.Err error) (failure error)]
      [(load.ResultCompilerLoadWithPaths.Ok decls paths modules _)
        (match (typecheck.typecheck-compiler-program-with-paths-cache
          (ast.ast-program decls)
          (ast.ast-decl-path-list-with-modules paths (& modules))
          roots
          cfgs
          "core-ir-dependency-boundary")
          [(tc.ResultCompilerTypecheck.Err errors) (check-failure errors)]
          [(tc.ResultCompilerTypecheck.Ok _)
            (trace.compiler-dependency-trace "done" "")
            0])])))

(define (inspect-main) : i64
  (if (< (io.arg-count) 3)
    (begin
      (io.print-error "dependency inspect: expected root, target and cfg names")
      2)
    (let
      [cfgs : sym_i64_env.SymI64Env (parser.compiler-cfg-empty)]
      [index : i64 3]
      (while (< index (io.arg-count))
        (set! cfgs (parser.compiler-cfg-enable cfgs (io.arg index)))
        (set! index (+ index 1)))
      (match (target_cfg.compiler-target-cfg-parse (io.arg 2))
        [(target_cfg.ResultCompilerTargetCfg.Ok target)
          (inspect (io.arg 1) (target_cfg.compiler-target-cfgs target cfgs))]
        [(target_cfg.ResultCompilerTargetCfg.Err message)
          (io.print-error message)
          2]))))

(define (main) : i64
  (cfg
    compiler-dependency-audit
    (inspect-main)
    (begin
      (io.print-error
        "dependency inspect: rebuild with --cfg compiler-dependency-audit\n")
      2)))