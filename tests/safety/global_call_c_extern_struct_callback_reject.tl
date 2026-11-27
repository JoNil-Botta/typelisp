;; A foreign C extern that receives a struct containing a C callback pointer
;; via `(Ptr Hooks)` may invoke TypeLisp code indirectly and mutate a borrowed
;; global.
(defstruct Big
  (a i64)
  (b i64)
  (c i64)
  (d i64))

(defstruct Hooks
  (:repr c)
  (on-step (CFunc non-null (-> i64 i64))))

(define g : Big
  (Big 1 2 3 4))

(extern (run-hooks [hooks : (Ptr Hooks)]) : i64 (:abi c))

(define (rebind!) : unit
  (set! g (Big 9 9 9 9)))

(define taken : (-> unit)
  rebind!)

(define (read-after [r : (& r Big)] [hooks : (Ptr Hooks)]) : i64
  (begin
    (unsafe
      (run-hooks hooks))
    r.a))

(define (main) : i64
  (let
    [hooks : (Ptr Hooks)
      (unsafe
        (int->ptr (cast 0 : u64) : (Ptr Hooks)))]
    (read-after (& g) hooks)))