(import "stdlib/core_macros.tl" module stdlib.core-macros as core)

(defstruct WideArg
  (:repr c)
  (a u64)
  (b f64))

(extern (wide-arg-score [arg : WideArg] [tag : u64]) : i64 (:symbol "tl_cabi_wide_arg_score"))

(extern wide-arg-scorer (:symbol "tl_cabi_wide_arg_score_ptr") : (->
  WideArg
  u64
  i64))

(define (main) : i64
  (let
    [direct-arg : WideArg (WideArg (cast 10 : u64) 1.5)]
    [ptr-arg : WideArg (WideArg (cast 20 : u64) 2.5)]
    [direct : i64 (wide-arg-score direct-arg (cast 7 : u64))]
    [via-ptr : i64 (wide-arg-scorer ptr-arg (cast 5 : u64))]
    (core/cond (not (= direct 32)) 1 (not (= via-ptr 75)) 2 42)))