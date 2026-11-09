;; An older local owner of the name is protected by the existing store check
;; (#9609).
(defstruct RefBox
  (:lifetimes a)
  (value (& a i64)))

(define (leak [p : (& q i64)]) : i64
  (let
    [r : i64 1]
    [t : (RefBox r) (RefBox (& r))]
    (with-arena
      s
      (let
        [x : (Box i64) (box 5)]
        [local : (& s i64) (& s (deref x))]
        [r : i64 2]
        (set! t.value local)))
    (deref t.value)))

(define (main) : i64
  0)