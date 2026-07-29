;; compiler_target_cfg_core.tl - Shared target/user cfg construction.
;;
;; Keep target predicate aliases in one place so compiler emission and
;; non-emitting tooling parse exactly the same source configuration.
(import stdlib.string)
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
  CompilerTargetCfg.Linux)

(define (compiler-target-cfg-host) : CompilerTargetCfg
  (cfg windows CompilerTargetCfg.Windows CompilerTargetCfg.Linux))

(define (compiler-target-cfg-name [target : CompilerTargetCfg]) : String
  (match target
    [(CompilerTargetCfg.Linux) "linux-x86_64"]
    [(CompilerTargetCfg.Windows) "windows-x86_64"]))

(define (compiler-target-cfg-parse [value : String]) : ResultCompilerTargetCfg
  (cond
    [(or (string.eq value "linux-x86_64") (string.eq value "linux_x86_64"))
      (ResultCompilerTargetCfg.Ok CompilerTargetCfg.Linux)]
    [(or (string.eq value "windows-x86_64") (string.eq value "windows_x86_64"))
      (ResultCompilerTargetCfg.Ok CompilerTargetCfg.Windows)]
    [else
      (ResultCompilerTargetCfg.Err
        (string.append
          "unknown target "
          (string.append value "; expected linux-x86_64 or windows-x86_64")))]))

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
  (begin
    (cbi.compiler-builtin-initialize-for-parse!)
    (match target
      [(CompilerTargetCfg.Linux) (compiler-target-enable-linux-cfgs cfgs)]
      [(CompilerTargetCfg.Windows) (compiler-target-enable-windows-cfgs cfgs)])))

(define (compiler-target-cfgs-with-names-from
  [target : CompilerTargetCfg]
  [names : target_cfg_svec.Vec]
  [index : i64]
  [cfgs : sym_i64_env.SymI64Env]) : sym_i64_env.SymI64Env
  (if (>= index (target_cfg_svec.len (& names)))
    (compiler-target-cfgs target cfgs)
    (compiler-target-cfgs-with-names-from
      target
      names
      (+ index 1)
      (cfg_core.compiler-cfg-enable
        cfgs
        (target_cfg_svec.get (& names) index "")))))

(define (compiler-target-cfgs-with-names
  [target : CompilerTargetCfg]
  [names : target_cfg_svec.Vec]) : sym_i64_env.SymI64Env
  (begin
    (cbi.compiler-builtin-initialize-for-parse!)
    (compiler-target-cfgs-with-names-from
      target
      names
      0
      (cfg_core.compiler-cfg-empty))))

(define (compiler-target-enable-linux-cfgs-with-intern-state
  [cfgs : sym_i64_env.SymI64Env]
  [intern-state : ci.InternCompatState]) : sym_i64_env.SymI64Env
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
  [intern-state : ci.InternCompatState]) : sym_i64_env.SymI64Env
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

(define (compiler-target-cfgs-with-intern-state
  [target : CompilerTargetCfg]
  [cfgs : sym_i64_env.SymI64Env]
  [intern-state : ci.InternCompatState]) : sym_i64_env.SymI64Env
  (match target
    [(CompilerTargetCfg.Linux)
      (compiler-target-enable-linux-cfgs-with-intern-state cfgs intern-state)]
    [(CompilerTargetCfg.Windows)
      (compiler-target-enable-windows-cfgs-with-intern-state cfgs intern-state)]))