;; compiler_target_cfg_core.tl - Shared target/user cfg construction.
;;
;; Keep target predicate aliases in one place so compiler emission and
;; non-emitting tooling parse exactly the same source configuration.
(import stdlib.vector)
(import stdlib.iterator)
(import stdlib.string)
(import stdlib.clone as clone_gen)
(import (vector.vector String) as target_cfg_svec)
(import compiler_builtin_ids as cbi)
(import compiler_cfg_core as cfg_core)
(import compiler_intern as ci)
(import sym_i64_env)

(defenum CompilerTargetCfg
  (Linux)
  (Windows))

(clone_gen.gen-clone CompilerTargetCfg)

(defenum ResultCompilerTargetCfg
  (Ok CompilerTargetCfg)
  (Err String))

(define (compiler-target-cfg-host) : CompilerTargetCfg
  (cfg windows Windows Linux))

(define (compiler-target-linux-cfg-names) : (Array String 4)
  (array "linux" "unix" "target-linux" "os-linux"))

(define (compiler-target-enable-linux-cfgs [cfgs : sym_i64_env.SymI64Env]) : sym_i64_env.SymI64Env
  (let
    [names : (Array String 4) (compiler-target-linux-cfg-names)]
    [out : sym_i64_env.SymI64Env cfgs]
    (for [index (iterator.range 0 4)]
      (set! out (cfg_core.compiler-cfg-enable out (& (array-ref names index)))))
    out))

(define (compiler-target-enable-linux-cfgs-with-intern-state
  [cfgs : sym_i64_env.SymI64Env]
  [intern-state : (&mut intern-state ci.InternCompatState)]) : sym_i64_env.SymI64Env
  (let
    [names : (Array String 4) (compiler-target-linux-cfg-names)]
    [out : sym_i64_env.SymI64Env cfgs]
    (for [index (iterator.range 0 4)]
      (set!
        out
        (cfg_core.compiler-cfg-enable-with-intern-state
          out
          (& (array-ref names index))
          intern-state)))
    out))

(define (compiler-target-windows-cfg-names) : (Array String 3)
  (array "windows" "target-windows" "os-windows"))

(define (compiler-target-enable-windows-cfgs [cfgs : sym_i64_env.SymI64Env]) : sym_i64_env.SymI64Env
  (let
    [names : (Array String 3) (compiler-target-windows-cfg-names)]
    [out : sym_i64_env.SymI64Env cfgs]
    (for [index (iterator.range 0 3)]
      (set! out (cfg_core.compiler-cfg-enable out (& (array-ref names index)))))
    out))

(define (compiler-target-enable-windows-cfgs-with-intern-state
  [cfgs : sym_i64_env.SymI64Env]
  [intern-state : (&mut intern-state ci.InternCompatState)]) : sym_i64_env.SymI64Env
  (let
    [names : (Array String 3) (compiler-target-windows-cfg-names)]
    [out : sym_i64_env.SymI64Env cfgs]
    (for [index (iterator.range 0 3)]
      (set!
        out
        (cfg_core.compiler-cfg-enable-with-intern-state
          out
          (& (array-ref names index))
          intern-state)))
    out))

(define (compiler-target-derived-cfg? [name : (& str)]) : bool
  (let
    [linux : (Array String 4) (compiler-target-linux-cfg-names)]
    [windows : (Array String 3) (compiler-target-windows-cfg-names)]
    (for [index (iterator.range 0 (array-length linux))]
      (when (string.eq name (& (array-ref linux index))) (return true)))
    (for [index (iterator.range 0 (array-length windows))]
      (when (string.eq name (& (array-ref windows index))) (return true)))
    false))

(define (compiler-target-cfgs
  [target : CompilerTargetCfg]
  [cfgs : sym_i64_env.SymI64Env]) : sym_i64_env.SymI64Env
  (cbi.compiler-builtin-initialize-for-parse!)
  (match target
    [(Linux) (compiler-target-enable-linux-cfgs cfgs)]
    [(Windows) (compiler-target-enable-windows-cfgs cfgs)]))

(define (compiler-target-user-cfgs [names : (& names target_cfg_svec.Vec)]) : sym_i64_env.SymI64Env
  (let
    [env : sym_i64_env.SymI64Env (cfg_core.compiler-cfg-empty)]
    [index : i64 0]
    (while (< index (target_cfg_svec.len names))
      (set!
        env
        (cfg_core.compiler-cfg-enable
          env
          (& (target_cfg_svec.get names index ""))))
      (set! index (+ index 1)))
    env))

(define (compiler-target-user-cfgs-with-intern-state
  [names : (& names target_cfg_svec.Vec)]
  [intern-state : (&mut intern-state ci.InternCompatState)]) : sym_i64_env.SymI64Env
  (let
    [env : sym_i64_env.SymI64Env (cfg_core.compiler-cfg-empty)]
    [index : i64 0]
    (while (< index (target_cfg_svec.len names))
      (set!
        env
        (cfg_core.compiler-cfg-enable-with-intern-state
          env
          (& (target_cfg_svec.get names index ""))
          intern-state))
      (set! index (+ index 1)))
    env))

(define (compiler-target-cfgs-with-names
  [target : CompilerTargetCfg]
  [names : target_cfg_svec.Vec]) : sym_i64_env.SymI64Env
  (cbi.compiler-builtin-initialize-for-parse!)
  (compiler-target-cfgs target (compiler-target-user-cfgs (& names))))