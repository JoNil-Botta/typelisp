;; #9612: a brand the call invalidates outlives no lifetime of the body other
;; than a nested lambda's own, and values typed with the brand itself stay
;; usable until it ends.
(import stdlib.arena)

(defstruct RefBox
  (:lifetimes m)
  (value (& m i64)))

(define (release [owner : (arena.Arena r) (:invalidate r)]) : unit
  (arena.destroy-safe! owner))

(define (read [a : (& q i64)]) : i64
  (deref a))

(define (pick [a : (& q i64)] [b : (& q i64)]) : (& q i64)
  a)

; Locals typed with the brand, inferred or annotated, and calls that keep it.
(define (keep-brand
  [ar : (arena.Arena r) (:invalidate r)]
  [v : (& r i64)]
  [u : (& r i64)]) : i64
  (let
    [w v]
    [bx : (RefBox r) (RefBox u)]
    [x : i64 (+ (read w) (deref (pick bx.value v)))]
    (begin
      (release ar)
      x)))

; Data of another caller lifetime may be held under a local's lifetime.
(define (other-into-local
  [ar : (arena.Arena r) (:invalidate r)]
  [k : (& p i64)]) : i64
  (let
    [y : i64 1]
    [w : (& y i64) k]
    (begin
      (release ar)
      (deref w))))

; A lambda's locals end before the lambda returns, and a lambda holding brand
; data ends with the brand.
(define (lambda-local [ar : (arena.Arena r) (:invalidate r)] [v : (& r i64)]) : i64
  (let
    [x : i64
      ((lambda () : i64
          (let
            [y : i64 1]
            [w : (& y i64) v]
            (deref w))))]
    (begin
      (release ar)
      x)))

; The same holds for the locals of a lambda nested in a lambda.
(define (nested-lambda-local
  [ar : (arena.Arena r) (:invalidate r)]
  [v : (& r i64)]) : i64
  (let
    [x : i64
      ((lambda () : i64
          ((lambda () : i64
              (let
                [z : i64 1]
                [w : (& z i64) v]
                (deref w))))))]
    (begin
      (release ar)
      x)))

; Arena data read before its brand ends.
(define (allocate-and-release [ar : (arena.Arena r) (:invalidate r)]) : i64
  (let
    [x : i64
      (in-arena
        ar
        (let
          [cell (box (ann 20 : i64))]
          [bx : (RefBox r) (RefBox (& (deref cell)))]
          (+ (read bx.value) (deref bx.value))))]
    (begin
      (release ar)
      x)))

(define (main) : i64
  (+ (allocate-and-release (arena.make)) 2))