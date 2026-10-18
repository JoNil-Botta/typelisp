;: Matches checked by the ownership MIR: payload fields move out by value one
;: at a time, a borrowed match binds references, literal and catch-all arms,
;: and a scrutinee computed by a call.
(defenum Slot
  (Full (__tl_dyn-array i64) i64)
  (Pair i64 i64)
  (Empty))

(define (take [_items : (__tl_dyn-array i64)]) : i64
  1)

(define (count [s : Slot]) : i64
  (match s
    [(Slot.Full items n) (+ n (take items))]
    [(Slot.Pair a b) (+ a b)]
    [Slot.Empty 0]))

(define (peek [s : (& s Slot)]) : i64
  (match s
    [(Slot.Full _ _) 5]
    [(Slot.Pair a _) 6]
    [_ 0]))

(define (kind [n : i64]) : i64
  (match n
    [0 10]
    [1 11]
    [other other]))

(define (make [n : i64]) : Slot
  (Slot.Pair n 1))

(define (main) : i64
  (let
    [s : Slot (Slot.Pair 20 7)]
    (+ (peek (& s)) (kind 1) (count s) (count (make -3)))))