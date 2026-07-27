;; compiler_cfg_core.tl - Parser-independent cfg environment primitives.
(import stdlib.string)
(import compiler_intern as ci)
(import sym_i64_env)

(define (compiler-cfg-key-id [name-id : i64]) : i64
  (+ (ci.intern-capacity) name-id))

(define (compiler-cfg-name-id [key-id : i64]) : i64
  (- key-id (ci.intern-capacity)))

(define (compiler-cfg-key-name [key-id : i64]) : String
  (string.append "cfg:" (ci.intern-str (compiler-cfg-name-id key-id))))

(define (compiler-cfg-name [key-id : i64]) : String
  (ci.intern-str (compiler-cfg-name-id key-id)))

(define (compiler-cfg-empty) : sym_i64_env.SymI64Env
  (sym_i64_env.sym-i64-empty))

(define (compiler-cfg-enable-id [cfgs : sym_i64_env.SymI64Env] [name-id : i64]) : sym_i64_env.SymI64Env
  (compiler-cfg-bind-id cfgs name-id 1))

(define (compiler-cfg-bind-id
  [cfgs : sym_i64_env.SymI64Env]
  [name-id : i64]
  [value : i64]) : sym_i64_env.SymI64Env
  (sym_i64_env.sym-i64-bind-id cfgs (compiler-cfg-key-id name-id) value))

(define (compiler-cfg-enable [cfgs : sym_i64_env.SymI64Env] [name : String]) : sym_i64_env.SymI64Env
  (compiler-cfg-bind cfgs name 1))

(define (compiler-cfg-union-value) : i64
  2)

;; Static analyses can request both arms of a simple cfg expression. The
;; predicate remains enabled for declarations and one-armed expressions.
(define (compiler-cfg-union [cfgs : sym_i64_env.SymI64Env] [name : String]) : sym_i64_env.SymI64Env
  (compiler-cfg-bind cfgs name (compiler-cfg-union-value)))

(define (compiler-cfg-bind
  [cfgs : sym_i64_env.SymI64Env]
  [name : String]
  [value : i64]) : sym_i64_env.SymI64Env
  (compiler-cfg-bind-id
    cfgs
    (ci.intern-source-slice name 0 (ci.intern-private-string-length name))
    value))

(define (compiler-cfg-enable-with-intern-state
  [cfgs : sym_i64_env.SymI64Env]
  [name : String]
  [intern-state : ci.InternCompatState]) : sym_i64_env.SymI64Env
  (compiler-cfg-enable-id
    cfgs
    (ci.intern-compat-state-intern intern-state name)))

(define (compiler-cfg-merge
  [base : sym_i64_env.SymI64Env]
  [cfgs : sym_i64_env.SymI64Env]) : sym_i64_env.SymI64Env
  (match (sym_i64_env.sym-i64-view cfgs)
    [(sym_i64_env.SymI64ViewNil) base]
    [(sym_i64_env.SymI64ViewBind name-id value rest)
      (sym_i64_env.sym-i64-bind-id (compiler-cfg-merge base rest) name-id value)]))

(define (compiler-cfg-enabled?
  [dispatch : sym_i64_env.SymI64Env]
  [name-id : i64]) : bool
  (sym_i64_env.sym-i64-contains-id dispatch (compiler-cfg-key-id name-id)))

(define (compiler-cfg-union? [dispatch : sym_i64_env.SymI64Env] [name-id : i64]) : bool
  (=
    (sym_i64_env.sym-i64-lookup-id-or dispatch (compiler-cfg-key-id name-id) 0)
    (compiler-cfg-union-value)))