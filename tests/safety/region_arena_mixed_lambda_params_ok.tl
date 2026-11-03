;; A lambda whose same-named parameters mix a non-carrier and a self-named
;; carrier, in either order: the non-carrier stops the body rename, and those
;; parameters then keep their types as written, so the signature and the body
;; agree on the caller lifetime (#9593, Sol's final review of 3bafc3d02).
(define (probe [p : (& r i64)]) : i64
  (with-arena
    r
    (let
      [f
        (lambda ([r : i64] [r : (& r i64)]) : i64
          (begin
            (& r r)
            20))]
      [g
        (lambda ([r : (& r i64)] [r : i64]) : i64
          (begin
            (& r r)
            22))]
      (+ (f 1 p) (g p 1)))))

(define (main) : i64
  (let
    [seed : i64 0]
    (probe (& seed))))