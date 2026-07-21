;; compiler_prelude_surface_producer.tl - build the stdlib prelude deployment
;; of the generic package frontend-surface schemas.
(import "compiler_load.tl")
(import "compiler_surface_ast.tl")
(import compiler_builtin_ids as cbi)
(import compiler_intern as ci)
(import compiler_surface_identity as surface_identity)
(import stdlib.arena)
(import stdlib.string)
(import stdlib.vector)
(import (vector.vector String) as surface_svec)

(defenum ResultPreludeSurface
  (Ok (Array u8))
  (Err String))

(define (prelude-surface-path-present?
  [items : (& items surface_svec.Vec)]
  [path : String]) : bool
  (let
    [index : i64 0]
    [present : bool false]
    (begin
      (while (and (not present) (< index (surface_svec.len items)))
        (if (string.eq (surface_svec.get items index "") path)
          (set! present true)
          (set! index (+ index 1))))
      present)))

(define (prelude-surface-module-set [paths : AstDeclPathList]) : (Array String)
  (let
    [items : surface_svec.Vec (surface_svec.new)]
    [index : i64 0]
    [count : i64 (ast-decl-path-list-len (& paths))]
    (begin
      (while (< index count)
        (let
          [path : String
            (array-ref
              (struct-get paths slots)
              (+ (struct-get paths offset) index))]
          (begin
            (if (prelude-surface-path-present? (& items) path)
              unit
              (surface_svec.push (&mut items) path))
            (set! index (+ index 1)))))
      (let
        [out : (Array String) (surface_svec.to-array (& items))]
        [sort-index : i64 1]
        (begin
          (while (< sort-index (array-length out))
            (let
              [value : String (array-ref out sort-index)]
              [scan : i64 sort-index]
              (begin
                (while (and
                  (> scan 0)
                  (surface_identity.surface-identity-string-less?
                    value
                    (array-ref out (- scan 1))))
                  (begin
                    (array-set! out scan (array-ref out (- scan 1)))
                    (set! scan (- scan 1))))
                (array-set! out scan value)
                (set! sort-index (+ sort-index 1)))))
          out)))))

(define (prelude-surface-target-cfgs [windows-target : bool]) : sym_i64_env.SymI64Env
  (let
    [cfgs : sym_i64_env.SymI64Env (compiler-cfg-empty)]
    (compiler-cfg-enable-compiler-language-features
      (if windows-target
        (compiler-cfg-enable
          (compiler-cfg-enable
            (compiler-cfg-enable cfgs "windows")
            "target-windows")
          "os-windows")
        (compiler-cfg-enable
          (compiler-cfg-enable
            (compiler-cfg-enable (compiler-cfg-enable cfgs "linux") "unix")
            "target-linux")
          "os-linux")))))

(define (prelude-surface-load-cold
  [load-state : CompilerLoadSessionState]
  [roots : surface_svec.Vec]
  [cfgs : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]) : ResultCompilerLoadWithPaths
  (match (compiler-load-file-with-paths-and-roots-cfg-with-pools
    load-state
    "stdlib/runtime.tl"
    (sym_i64_env.sym-i64-empty)
    roots
    cfgs
    pools)
    [(ResultCompilerLoadWithPaths.Ok
        runtime-decls
        runtime-paths
        runtime-modules
        runtime-seen)
      (match (compiler-load-core-macro-prelude-with-roots-cfg-with-pools
        load-state
        runtime-seen
        roots
        cfgs
        pools)
        [(ResultCompilerLoadWithPaths.Ok
            macro-decls
            macro-paths
            macro-modules
            macro-seen)
          (ResultCompilerLoadWithPaths.Ok
            (compiler-load-decl-list-append runtime-decls macro-decls)
            (compiler-load-decl-path-list-append runtime-paths macro-paths)
            (compiler-load-decl-module-list-append
              runtime-modules
              macro-modules)
            macro-seen)]
        [(ResultCompilerLoadWithPaths.Err diag)
          (ResultCompilerLoadWithPaths.Err diag)])]
    [(ResultCompilerLoadWithPaths.Err diag)
      (ResultCompilerLoadWithPaths.Err diag)]))

(define (prelude-surface-pack
  [identity-bytes : (Array u8)]
  [ast-bytes : (Array u8)]) : ResultPreludeSurface
  (let
    [sections : (Array TlciAuxSection) (make-array TlciAuxSection 2)]
    (begin
      (array-set!
        sections
        0
        (TlciAuxSection tlci-aux-kind-package-identity 1 identity-bytes))
      (array-set!
        sections
        1
        (TlciAuxSection tlci-aux-kind-frontend-ast 1 ast-bytes))
      (match (tlci-aux-pack-rodata (tlci-empty-bytes) sections)
        [(ResultTlciAuxBytes.Err message) (ResultPreludeSurface.Err message)]
        [(ResultTlciAuxBytes.Ok rodata) (ResultPreludeSurface.Ok rodata)]))))

(define (prelude-surface-build
  [root : String]
  [source-hash : String]
  [build-hash : String]
  [windows-target : bool]) : ResultPreludeSurface
  (let
    [previous-arena : i64 (arena.tl_arena_current)]
    [surface-arena : i64 (arena.tl_arena_make)]
    [_set-surface-arena : unit
      (unsafe
        (arena.tl_arena_set surface-arena))]
    [_reset-interns : unit (ci.intern-reset!)]
    [_reset-builtins : unit (cbi.compiler-builtin-reset!)]
    [roots : surface_svec.Vec (surface_svec.new)]
    [pools : AstNodePoolContext
      (ast-node-pool-context-new-with-capacities-in-arena
        131072
        8192
        surface-arena)]
    [load-state : CompilerLoadSessionState (compiler-load-session-state-new)]
    (begin
      (surface_svec.push (&mut roots) root)
      (match (prelude-surface-load-cold
        load-state
        roots
        (prelude-surface-target-cfgs windows-target)
        pools)
        [(ResultCompilerLoadWithPaths.Err diag)
          (begin
            (unsafe
              (arena.tl_arena_set previous-arena))
            (ResultPreludeSurface.Err
              (str-cat
                "prelude surface load failed: "
                (compiler-diagnostic-render (box-get diag)))))]
        [(ResultCompilerLoadWithPaths.Ok decls paths modules seen)
          (let
            [module-set : (Array String) (prelude-surface-module-set paths)]
            [key : surface_identity.SurfaceIdentityKey
              (surface_identity.SurfaceIdentityKey
                "stdlib.prelude"
                module-set
                source-hash
                build-hash
                (if windows-target
                  "windows-default"
                  "linux-default"))]
            [identity-payload : surface_identity.SurfaceIdentityPayload
              (surface_identity.surface-identity-capture key)]
            [source-count : i64
              (array-length (struct-get identity-payload source-names))]
            [identity-count : i64
              (+
                source-count
                (array-length (struct-get identity-payload generated)))]
            (begin
              (unsafe
                (arena.tl_arena_set previous-arena))
              (match (surface_identity.surface-identity-encode identity-payload)
                [(surface_identity.ResultSurfaceIdentityBytes.Err message)
                  (ResultPreludeSurface.Err message)]
                [(surface_identity.ResultSurfaceIdentityBytes.Ok identity-bytes)
                  (match (surface-ast-encode
                    decls
                    paths
                    modules
                    seen
                    pools
                    source-count
                    identity-count)
                    [(ResultSurfaceAstBytes.Err message)
                      (ResultPreludeSurface.Err message)]
                    [(ResultSurfaceAstBytes.Ok ast-bytes)
                      (prelude-surface-pack identity-bytes ast-bytes)])])))]))))