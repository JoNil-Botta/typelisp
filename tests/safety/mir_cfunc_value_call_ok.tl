;; A call through a C function pointer value reads the pointer and copies its
;; C-ABI arguments: through an extern pointer global, a local copy of it, and
;; an unsafe pointer inside `unsafe`.
(defstruct Wide
  (:repr c)
  (a u64)
  (b u64)
  (c u64))

(extern wide-scorer (:symbol "tl_mir_wide_scorer") : (CFunc
  non-null
  (-> Wide u64 i64)))
(extern raw-scorer (:symbol "tl_mir_raw_scorer") : (CFunc
  unsafe-non-null
  (-> Wide i64)))

(define (main) : i64
  (let
    [arg : Wide (Wide (cast 1 : u64) (cast 2 : u64) (cast 3 : u64))]
    [copy : (CFunc non-null (-> Wide u64 i64)) wide-scorer]
    [direct : i64 (wide-scorer arg (cast 4 : u64))]
    [via-copy : i64 (copy arg (cast 5 : u64))]
    [raw : i64
      (unsafe
        (raw-scorer arg))]
    (+ direct (+ via-copy raw))))