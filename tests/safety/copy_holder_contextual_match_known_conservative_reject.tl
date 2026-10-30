;; Refs #9493. Known conservative rejection (Refs #9464 Refs #9256).
;; Holder q is Copy and its intrinsic reference lifetime q remains valid.
;; The contextual join also retains the incidental container-view lifetime o,
;; so this safe return is conservatively rejected with E0205.
(defstruct Holder
  (:lifetimes q)
  (r (& q i64))
  (a i64)
  (b i64))

(defstruct Out
  (:lifetimes q)
  (h (Holder q))
  (t i64))

(define (get [o : (& o (Out q))] [fallback : (Holder q)] [flag : bool]) : (Holder q)
  (match flag
    [true o.h]
    [false fallback]))

(define (main) : i64
  (let
    [n : i64 40]
    [o (Out (Holder (& n) 1 1) 0)]
    [r (get (& o) (Holder (& n) 1 1) true)]
    (+ (deref r.r) r.a r.b)))
