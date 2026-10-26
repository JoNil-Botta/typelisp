;: An extern's read of an owner conflicts with a live mutable borrow of it.
(extern (items-bits [items : (__tl_dyn-array i64)]) : u64 (:symbol "tl_float_to_bits"))

(define (grow [target : (&mut target (__tl_dyn-array i64))] [value : i64]) : unit
  (__tl_array-push! target value))

(define (run [items : (__tl_dyn-array i64)]) : u64
  (let
    [handle : (&mut items (__tl_dyn-array i64)) (&mut items)]
    [bits : u64 (items-bits items)]
    (begin
      (grow handle 1)
      bits)))

(define (main) : i64
  0)