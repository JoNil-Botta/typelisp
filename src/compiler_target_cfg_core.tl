;; compiler_target_cfg_core.tl - Shared target/user cfg construction.
;;
;; Keep target predicate aliases in one place so compiler emission and
;; non-emitting tooling parse exactly the same source configuration.
(import stdlib.vector)
(import (vector.vector String) as target_cfg_svec)
(import compiler_builtin_ids as cbi)
(import compiler_cfg_core as cfg_core)
(import compiler_intern as ci)
(import sym_i64_env)

(defenum CompilerTargetCfg
  (Linux)
  (Windows))

(defenum ResultCompilerTargetCfg
  (Ok CompilerTargetCfg)
  (Err String))

(define (compiler-target-cfg-default) : CompilerTargetCfg
  Linux)

(define (compiler-target-cfg-host) : CompilerTargetCfg
  (cfg windows Windows Linux))

(define (compiler-target-enable-linux-cfgs [cfgs : sym_i64_env.SymI64Env]) : sym_i64_env.SymI64Env
  (cfg_core.compiler-cfg-enable
    (cfg_core.compiler-cfg-enable
      (cfg_core.compiler-cfg-enable
        (cfg_core.compiler-cfg-enable cfgs "linux")
        "unix")
      "target-linux")
    "os-linux"))

(define (compiler-target-enable-windows-cfgs [cfgs : sym_i64_env.SymI64Env]) : sym_i64_env.SymI64Env
  (cfg_core.compiler-cfg-enable
    (cfg_core.compiler-cfg-enable
      (cfg_core.compiler-cfg-enable cfgs "windows")
      "target-windows")
    "os-windows"))

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

(define (compiler-target-enable-linux-cfgs-with-intern-state
  [cfgs : sym_i64_env.SymI64Env]
  [intern-state : (&mut intern-state ci.InternCompatState)]) : sym_i64_env.SymI64Env
  (cfg_core.compiler-cfg-enable-with-intern-state
    (cfg_core.compiler-cfg-enable-with-intern-state
      (cfg_core.compiler-cfg-enable-with-intern-state
        (cfg_core.compiler-cfg-enable-with-intern-state
          cfgs
          "linux"
          intern-state)
        "unix"
        intern-state)
      "target-linux"
      intern-state)
    "os-linux"
    intern-state))

(define (compiler-target-enable-windows-cfgs-with-intern-state
  [cfgs : sym_i64_env.SymI64Env]
  [intern-state : (&mut intern-state ci.InternCompatState)]) : sym_i64_env.SymI64Env
  (cfg_core.compiler-cfg-enable-with-intern-state
    (cfg_core.compiler-cfg-enable-with-intern-state
      (cfg_core.compiler-cfg-enable-with-intern-state
        cfgs
        "windows"
        intern-state)
      "target-windows"
      intern-state)
    "os-windows"
    intern-state))