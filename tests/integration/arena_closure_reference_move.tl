;; #9770 control: a reference-capturing closure made in an arena and moved into
;; other locals before the call. Reading the closure local yields its
;; environment although the arena tags its function type (E0200 regression).
(define (main) : i64
  (let
    [n : i64 20]
    [r : (& n i64) (& n)]
    (with-arena
      scratch
      (let
        [f
          (lambda () : i64
            (deref r))]
        [g f]
        [h : (-> i64) g]
        [k
          (lambda () : i64
            (+ (deref r) 2))]
        [m : (-> i64) k]
        (+ (h) (m))))))