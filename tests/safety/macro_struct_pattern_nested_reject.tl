(defstruct Pair
  (left i64)
  (right i64))

(defstruct Packet
  (pair Pair))

(defmacro (bad-packet [value : Expr]) : Expr
  `(match ,value
    [(Packet (Pair a)) a]))

(define (main [packet : (& packet Packet)]) : i64
  (bad-packet packet))