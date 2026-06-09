;; #2386 regression guard: borrowed match of a 16-byte register-resident enum.
;; The borrowed payload literal compare addressed the scrutinee as memory while
;; the place lowered to its packed register-group value, so the payload read
;; dereferenced the packed word and crashed. The scrutinee is now spilled to a
;; temp slot and the whole match runs on the slot address.
(defenum Maybe
  (None)
  (Some i64))

(define (score [m : Maybe]) : i64
  (match (& m)
    [(Some 9) 40]
    [(Some _) 1]
    [None 1]))

(define (main) : i64
  (let
    [a : Maybe (Some 9)]
    [b : Maybe (Some 7)]
    [c : Maybe None]
    (+ (score a) (+ (score b) (score c)))))