(module macro_struct_pattern)

(import macro_struct_pattern_defs as defs)
(import string)

(defstruct Pair
  (left i64)
  (right i64))

(defstruct Packet
  (pair Pair)
  (extra i64))

(defstruct Label
  (text String)
  (extra i64))

(defmacro (pair-sum [value : Expr]) : Expr
  `(match ,value
    [(Pair a b) (+ a b)]))

(defmacro (packet-sum [value : Expr]) : Expr
  `(match ,value
    [(Packet (Pair a b) extra) (+ a b extra)]))

(defmacro (packet-named-sum [value : Expr]) : Expr
  `(match ,value
    [(fields [extra extra] [(Pair a b) pair]) (+ a b extra)]))

(defmacro (label-score [value : Expr]) : Expr
  `(match ,value
    [(Label text extra) (+ (string.string-length text) extra)]))

(define (main) : i64
  (let
    [pair : Pair (Pair 20 22)]
    [packet : Packet (Packet (Pair 10 12) 20)]
    [label : Label (Label "abc" 39)]
    [foreign : defs.Pair (defs.Pair true 19 23)]
    ;; Nonmacro controls use exactly the constructor and named field forms.
    (unless
      (=
        (match pair
          [(Pair a b) (+ a b)])
        42)
      (return 1))
    (unless
      (=
        (match (& pair)
          [(Pair a b) (+ a b)])
        42)
      (return 2))
    (unless
      (=
        (match packet
          [(Packet (Pair a b) extra) (+ a b extra)])
        42)
      (return 3))
    (unless
      (=
        (match (& packet)
          [(fields [extra extra] [(Pair a b) pair]) (+ a b extra)])
        42)
      (return 4))
    (unless
      (=
        (match packet
          [(fields [extra extra] [(Pair a b) pair]) (+ a b extra)])
        42)
      (return 18))
    (unless
      (=
        (match (& packet)
          [(Packet (Pair a b) extra) (+ a b extra)])
        42)
      (return 19))
    (unless
      (=
        (match (& label)
          [(Label text extra) (+ (string.string-length text) extra)])
        42)
      (return 20))
    (unless
      (=
        (match (Label "abc" 39)
          [(Label text extra) (+ (string.string-length text) extra)])
        42)
      (return 21))
    (unless (= (pair-sum pair) 42) (return 5))
    (unless (= (pair-sum (& pair)) 42) (return 6))
    (unless (= (packet-sum packet) 42) (return 7))
    (unless (= (packet-sum (& packet)) 42) (return 8))
    (unless (= (packet-named-sum packet) 42) (return 9))
    (unless (= (packet-named-sum (& packet)) 42) (return 10))
    (unless (= (label-score (& label)) 42) (return 11))
    (unless (= (label-score label) 42) (return 12))
    (unless
      (=
        (match foreign
          [(defs.Pair _ a b) (+ a b)])
        42)
      (return 13))
    (unless (= (defs.pair-sum foreign) 42) (return 14))
    (unless (= (defs.pair-sum (& foreign)) 42) (return 15))
    (unless (= (defs.pair-named-sum foreign) 42) (return 16))
    (unless (= (defs.pair-named-sum (& foreign)) 42) (return 17))
    42))