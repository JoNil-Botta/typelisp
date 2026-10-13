(defstruct Big
  (a i64)
  (b i64)
  (c i64)
  (d i64))

(define g : Big
  (Big 1 2 3 4))

(extern (foreign) : unit (:abi c))

(define (rebind!) : unit
  (set! g (Big 9 9 9 9)))

(define taken : (-> unit)
  rebind!)

(define (read-after [r : (& r Big)]) : i64
  (begin
    (unsafe
      (foreign))
    r.a))

(define (main) : i64
  (read-after (& g)))