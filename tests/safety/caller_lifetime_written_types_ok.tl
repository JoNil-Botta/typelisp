;; Types written in `init`, `ptr-null`, `make-array`, `cast`, `ptr-cast` and
;; `int->ptr` forms name the
;; caller's lifetime like annotations do, and a top-level name spelled like it
;; does not shadow it, also in an SPMD helper call's arguments.
(defenum RefOpt
  (:lifetimes a)
  (None)
  (Some (& a i64)))

(define (first [p : (& a i64)]) : i64
  (let
    [o : (RefOpt a) (init : (RefOpt a))]
    [q : (Ptr (& a i64)) (ptr-null : (Ptr (& a i64)))]
    [arr : (Array (Ptr (& a i64)) 2) (make-array (Ptr (& a i64)) 2)]
    (let
      [a : i64 1]
      a)))

(define (raw [p : (& a i64)]) : i64
  (let
    [q : (Ptr (& a i64))
      (unsafe
        (ptr-cast (ptr-null : (Ptr i64)) : (Ptr (& a i64))))]
    [r : (Ptr (& a i64))
      (unsafe
        (int->ptr (cast 0 : u64) : (Ptr (& a i64))))]
    (let
      [a : i64 1]
      a)))

(define (t) : i64
  1)

(define (plus [p : (& t i64)] [x : i64]) : i64
  x)

(define (fill [p : (& t i64)] [out : (&mut out (__tl_dyn-array i64))] [n : i64]) : unit
  (let
    [k : i64 (t)]
    (foreach
      ([i : i64 0 n])
      (set! (array-ref out i) (plus (ann p : (& t i64)) (+ i k))))))

(define (main) : i64
  0)