(import stdlib.io)

(defenum Cell
  (Empty)
  (Full (Box (Box i64)) i64))

(defmacro (peek-cell [c : Expr]) : Expr
  `(match ,c
    [(Cell.Empty) 0]
    [(Cell.Full b k)
      (let
        [r (& (box-get b))]
        (+ (deref r) k))]))

(define (via-ref [c : (& c Cell)]) : i64
  (peek-cell c))

(define (main) : i64
  (let
    [c : Cell (Cell.Full (box (box 40)) 2)]
    (begin
      (io.println "via-ref=[{}]" (via-ref (& c)))
      0)))