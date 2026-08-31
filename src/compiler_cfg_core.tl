;; compiler_cfg_core.tl - Parser-independent cfg environment primitives.
(import stdlib.str_cat_runtime as str_cat)
(import compiler_intern as ci)
(import sym_i64_env)
(cfg test (import stdlib.test))

(defstruct CompilerCfgKey
  (value i64))

(cfg
  test
  (define (compiler-cfg-key-size) : i64
    (comptime (size-of (type CompilerCfgKey)))))

;; Cfg keys share raw i64 environments with compact source handles, IR-owned
;; symbols, session structural records, and negative sentinels. Encode a source
;; handle as the payload of the fixed [2^32, 2*2^32) cfg domain reserved in
;; compiler_intern. This remains collision-free when the source-name store grows
;; beyond today's fixed pool and keeps the raw environment boundary one word.
(define (compiler-cfg-key-domain-base) : i64
  (ci.intern-cfg-key-domain-base))

(define (compiler-cfg-key-domain-limit) : i64
  (+ (compiler-cfg-key-domain-base) (ci.intern-compiler-identity-domain-width)))

(define (compiler-cfg-key-domain? [key-id : i64]) : bool
  (and
    (>= key-id (compiler-cfg-key-domain-base))
    (< key-id (compiler-cfg-key-domain-limit))))

(define (compiler-cfg-key-from-name-id [name-id : i64]) : CompilerCfgKey
  (if (ci.intern-renderable-id? name-id)
    (CompilerCfgKey (+ (compiler-cfg-key-domain-base) name-id))
    (ci.intern-compiler-identity-domain-overflow-abort)))

;; The fixed pool cannot allocate future source handles around and beyond
;; 131,072 yet. Namespace tests use this narrow constructor to exercise the
;; complete u32 source-handle contract without claiming those handles are
;; renderable in the current table.
(cfg
  test
  (define (compiler-cfg-key-from-logical-source-handle [name-id : i64]) : CompilerCfgKey
    (if (or
      (< name-id 0)
      (>= name-id (ci.intern-compiler-identity-domain-width)))
      (ci.intern-compiler-identity-domain-overflow-abort)
      (CompilerCfgKey (+ (compiler-cfg-key-domain-base) name-id)))))

(define (compiler-cfg-key-id [key : CompilerCfgKey]) : i64
  key.value)

(define (compiler-cfg-name-id [key-id : i64]) : i64
  (if (compiler-cfg-key-domain? key-id)
    (- key-id (compiler-cfg-key-domain-base))
    -1))

(define (compiler-cfg-key-name [key-id : i64]) : String
  (let
    [name-id : i64 (compiler-cfg-name-id key-id)]
    (if (ci.intern-renderable-id? name-id)
      (str_cat.str-cat "cfg:" (ci.intern-str name-id))
      "")))

(define (compiler-cfg-name [key-id : i64]) : String
  (let
    [name-id : i64 (compiler-cfg-name-id key-id)]
    (if (ci.intern-renderable-id? name-id)
      (ci.intern-str name-id)
      "")))

(define (compiler-cfg-empty) : sym_i64_env.SymI64Env
  (sym_i64_env.sym-i64-empty))

(define (compiler-cfg-enable-id [cfgs : sym_i64_env.SymI64Env] [name-id : i64]) : sym_i64_env.SymI64Env
  (compiler-cfg-bind-id cfgs name-id 1))

(define (compiler-cfg-bind-id
  [cfgs : sym_i64_env.SymI64Env]
  [name-id : i64]
  [value : i64]) : sym_i64_env.SymI64Env
  (compiler-cfg-bind-key cfgs (compiler-cfg-key-from-name-id name-id) value))

(define (compiler-cfg-bind-key
  [cfgs : sym_i64_env.SymI64Env]
  [key : CompilerCfgKey]
  [value : i64]) : sym_i64_env.SymI64Env
  (sym_i64_env.sym-i64-bind-id cfgs (compiler-cfg-key-id key) value))

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
  [intern-state : (&mut intern-state ci.InternCompatState)]) : sym_i64_env.SymI64Env
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
  (if (ci.intern-renderable-id? name-id)
    (compiler-cfg-enabled-key? dispatch (compiler-cfg-key-from-name-id name-id))
    false))

(define (compiler-cfg-enabled-key?
  [dispatch : sym_i64_env.SymI64Env]
  [key : CompilerCfgKey]) : bool
  (sym_i64_env.sym-i64-contains-id dispatch (compiler-cfg-key-id key)))

(define (compiler-cfg-union? [dispatch : sym_i64_env.SymI64Env] [name-id : i64]) : bool
  (if (ci.intern-renderable-id? name-id)
    (compiler-cfg-union-key? dispatch (compiler-cfg-key-from-name-id name-id))
    false))

(define (compiler-cfg-union-key?
  [dispatch : sym_i64_env.SymI64Env]
  [key : CompilerCfgKey]) : bool
  (=
    (sym_i64_env.sym-i64-lookup-id-or dispatch (compiler-cfg-key-id key) 0)
    (compiler-cfg-union-value)))

(cfg
  test
  (test
    compiler-cfg-capacity-independent-key-namespace
    (let
      [capacity : i64 (ci.intern-capacity)]
      [width : i64 (ci.intern-compiler-identity-domain-width)]
      [below : CompilerCfgKey
        (compiler-cfg-key-from-logical-source-handle (- capacity 1))]
      [at : CompilerCfgKey
        (compiler-cfg-key-from-logical-source-handle capacity)]
      [above : CompilerCfgKey
        (compiler-cfg-key-from-logical-source-handle (+ capacity 1))]
      [last : CompilerCfgKey
        (compiler-cfg-key-from-logical-source-handle (- width 1))]
      [cfgs-below : sym_i64_env.SymI64Env
        (compiler-cfg-bind-key (compiler-cfg-empty) below 11)]
      [cfgs-rest : sym_i64_env.SymI64Env
        (compiler-cfg-bind-key
          (compiler-cfg-bind-key (compiler-cfg-empty) at 22)
          above
          (compiler-cfg-union-value))]
      [cfgs : sym_i64_env.SymI64Env (compiler-cfg-merge cfgs-below cfgs-rest)]
      (begin
        (test.assert-i64-eq
          (compiler-cfg-key-size)
          8
          "cfg key remains one machine word")
        (test.assert-i64-eq
          (compiler-cfg-key-domain-base)
          width
          "cfg domain begins above every u32 source handle")
        (test.assert-i64-eq
          (compiler-cfg-key-domain-limit)
          (ci.intern-ir-symbol-domain-base)
          "cfg domain ends where the neighboring IR domain begins")
        (test.assert-i64-eq
          (compiler-cfg-name-id (compiler-cfg-key-id below))
          (- capacity 1)
          "source handle below old capacity round-trips")
        (test.assert-i64-eq
          (compiler-cfg-name-id (compiler-cfg-key-id at))
          capacity
          "source handle at old capacity round-trips")
        (test.assert-i64-eq
          (compiler-cfg-name-id (compiler-cfg-key-id above))
          (+ capacity 1)
          "source handle above old capacity round-trips")
        (test.assert-i64-eq
          (compiler-cfg-name-id (compiler-cfg-key-id last))
          (- width 1)
          "largest u32 source handle round-trips")
        (test.assert-true
          (compiler-cfg-enabled-key? cfgs below)
          "future-sized cfg environment finds lower handle")
        (test.assert-true
          (compiler-cfg-enabled-key? cfgs at)
          "future-sized cfg environment finds boundary handle")
        (test.assert-true
          (compiler-cfg-union-key? cfgs above)
          "future-sized cfg environment finds upper handle value")
        (test.assert-i64-eq
          (sym_i64_env.sym-i64-lookup-id-or cfgs (compiler-cfg-key-id below) -1)
          11
          "lower handle binding keeps its value")
        (test.assert-i64-eq
          (sym_i64_env.sym-i64-lookup-id-or cfgs (compiler-cfg-key-id at) -1)
          22
          "boundary handle binding cannot alias its neighbor")
        (test.assert-true
          (< (compiler-cfg-key-id last) (ci.intern-structural-key-base))
          "complete cfg domain stays below session structural records")))))

(cfg
  test
  (test
    compiler-cfg-key-render-and-foreign-domains-fail-closed
    (let
      [name-id : i64 (ci.intern "cfg-key-render")]
      [key : CompilerCfgKey (compiler-cfg-key-from-name-id name-id)]
      [raw : i64 (compiler-cfg-key-id key)]
      [cfgs : sym_i64_env.SymI64Env
        (compiler-cfg-bind-key (compiler-cfg-empty) key 7)]
      [name : String (compiler-cfg-name raw)]
      [key-name : String (compiler-cfg-key-name raw)]
      [expected-name : String "cfg-key-render"]
      [expected-key-name : String "cfg:cfg-key-render"]
      [empty : String ""]
      [compact-last : i64 (- (ci.intern-compact-id-domain-limit) 1)]
      [ir-base : i64 (ci.intern-ir-symbol-domain-base)]
      [structural-base : i64 (ci.intern-structural-key-base)]
      [future : CompilerCfgKey
        (compiler-cfg-key-from-logical-source-handle (+ (ci.intern-capacity) 1))]
      [future-name : String (compiler-cfg-name (compiler-cfg-key-id future))]
      [future-key-name : String
        (compiler-cfg-key-name (compiler-cfg-key-id future))]
      [missing-name : String (compiler-cfg-name -1)]
      [missing-key-name : String (compiler-cfg-key-name -1)]
      [compact-name : String (compiler-cfg-name compact-last)]
      [ir-name : String (compiler-cfg-name ir-base)]
      [ir-key-name : String (compiler-cfg-key-name ir-base)]
      [structural-name : String (compiler-cfg-name structural-base)]
      (begin
        (test.assert-true
          (compiler-cfg-enabled? cfgs name-id)
          "renderable source name queries through typed cfg key")
        (test.assert-string-eq
          (& name)
          (& expected-name)
          "cfg key renders its source spelling")
        (test.assert-string-eq
          (& key-name)
          (& expected-key-name)
          "cfg cache key retains stable prefix rendering")
        (test.assert-false
          (compiler-cfg-key-domain? -1)
          "negative missing sentinel is not a cfg key")
        (test.assert-false
          (compiler-cfg-key-domain? compact-last)
          "source handle domain is not a cfg key")
        (test.assert-false
          (compiler-cfg-key-domain? ir-base)
          "IR symbol domain is not a cfg key")
        (test.assert-false
          (compiler-cfg-key-domain? structural-base)
          "session structural domain is not a cfg key")
        (test.assert-false
          (compiler-cfg-enabled? cfgs -1)
          "missing query fails closed")
        (test.assert-false
          (compiler-cfg-enabled? cfgs compact-last)
          "source handle outside the live pool fails closed")
        (test.assert-false
          (compiler-cfg-union? cfgs ir-base)
          "IR-domain query fails closed")
        (test.assert-false
          (compiler-cfg-union? cfgs structural-base)
          "structural-domain query fails closed")
        (test.assert-i64-eq
          (compiler-cfg-name-id -1)
          -1
          "missing sentinel decode fails closed")
        (test.assert-i64-eq
          (compiler-cfg-name-id compact-last)
          -1
          "source-domain decode fails closed")
        (test.assert-i64-eq
          (compiler-cfg-name-id ir-base)
          -1
          "IR-domain decode fails closed")
        (test.assert-i64-eq
          (compiler-cfg-name-id structural-base)
          -1
          "structural-domain decode fails closed")
        (test.assert-string-eq
          (& future-name)
          (& empty)
          "currently unallocated future handle does not reach intern-str")
        (test.assert-string-eq
          (& future-key-name)
          (& empty)
          "future handle cache rendering does not reach intern-str")
        (test.assert-string-eq
          (& missing-name)
          (& empty)
          "missing sentinel renders empty")
        (test.assert-string-eq
          (& missing-key-name)
          (& empty)
          "missing cache key renders empty")
        (test.assert-string-eq
          (& compact-name)
          (& empty)
          "wrong compact domain renders empty")
        (test.assert-string-eq
          (& ir-name)
          (& empty)
          "wrong IR domain renders empty")
        (test.assert-string-eq
          (& ir-key-name)
          (& empty)
          "wrong IR cache key renders empty")
        (test.assert-string-eq
          (& structural-name)
          (& empty)
          "wrong structural domain renders empty")))))