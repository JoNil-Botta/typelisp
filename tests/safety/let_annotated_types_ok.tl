;; The move and borrow checks read an annotated let binding's type from body
;; typing; contextual literals, references and moves stay accepted.
(import stdlib.string)

(defstruct Pair
  (a i64)
  (b i64))

(define (main) : i64
  (let
    [small : u8 7]
    [x : Pair (Pair 1 2)]
    [r : (& x Pair) (& x)]
    [n : i64 r.a]
    [s : String (string.copy "ab")]
    [t : String s]
    (set! x.b 3)
    (+ n (+ (cast small : i64) (+ x.b (string.string-length (& t)))))))