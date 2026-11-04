;; Caller references stored through an elided-lifetime &mut remain valid
;; inside a distinct arena. Contextual lowering must keep check's verdict.
(defstruct RefBox
  (:lifetimes a)
  (value (& a i64)))

(define (sum [p : (& r i64)] [b : (&mut (RefBox r))]) : i64
  (with-arena
    q
    (let
      [x : (in q (Box i64)) (box 30)]
      [local : (RefBox q) (RefBox (& q (deref x)))]
      [read
        (lambda ([v : (& q i64)]) : i64
          (deref v))]
      (set! b.value p)
      (+ (read local.value) (deref b.value)))))

(define (main) : i64
  (let
    [seed : i64 12]
    [holder : (RefBox seed) (RefBox (& seed))]
    (sum (& seed) (&mut holder))))