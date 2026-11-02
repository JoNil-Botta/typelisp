;; A `with-arena` region spelled like a caller lifetime shadows it inside the
;; body (#9593): annotations and borrow lifetimes spelled `r` name the arena,
;; so arena data typed with them stays usable inside it.
(defstruct RefBox
  (:lifetimes a)
  (value (& a i64)))

(define (sum [p : (& r i64)]) : i64
  (with-arena
    r
    (let
      [x : (in r (Box i64)) (box 30)]
      [local : (RefBox r) (RefBox (& r (deref x)))]
      [read
        (lambda ([v : (& r i64)]) : i64
          (deref v))]
      (+ (read local.value) (deref p)))))

(define (main) : i64
  (let
    [seed : i64 12]
    (sum (& seed))))