;; #9061: an `if` against a plain expected type keeps its arms' arena region, so
;; a Copy struct read out of an arena Box cannot leave the arena through it.
(import stdlib.io)

(defstruct S3
  (x i64)
  (y i64)
  (z i64))

(define (keep [c : bool]) : S3
  (with-arena
    r
    (let
      [b : (Box S3) (box (S3 1 2 3))]
      (if c
        (deref b)
        (deref b)))))

(define (main) : i64
  (let
    [k (keep true)]
    (let
      [x : i64 k.x]
      [y : i64 k.y]
      [w : i64 k.z]
      (begin
        (io.println "D03 x={} y={} z={}" x y w)
        (if (and (= x 1) (= y 2) (= w 3))
          42
          (bit-and x 255))))))