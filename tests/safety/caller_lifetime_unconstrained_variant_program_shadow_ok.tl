;; #8998: an unconstrained variant lifetime does not depend on the reserved
;; `program` being unshadowed: a parameter or local named `program` leaves the
;; unpinned variant repair in place.
(defenum Text
  (:lifetimes cwd)
  (Missing)
  (Present (& cwd str)))

(defstruct Command
  (:lifetimes cwd)
  (id i64)
  (cwd (Text cwd)))

(defenum Maybe
  (:lifetimes x)
  (None)
  (Some (& x i64)))

(defstruct Pair
  (:lifetimes x)
  (left (Maybe x))
  (right (Maybe x)))

(define (none-param [cwd : (& next str)] [program : i64]) : (Text next)
  (Text.Missing))

(define (none-local [cwd : (& next str)]) : (Text next)
  (let
    [program : i64 0]
    (Text.Missing)))

(define (first [x : i64] [program : i64] [value : (Maybe a)]) : (Pair a)
  (Pair (Maybe.None) value))

(define (last [x : i64] [program : i64] [value : (Maybe a)]) : (Pair a)
  (Pair value (Maybe.None)))

(define (command [cwd : (& next str)]) : (Command next)
  (let
    [program : i64 0]
    (Command 1 (Text.Missing))))

(define (main) : i64
  0)