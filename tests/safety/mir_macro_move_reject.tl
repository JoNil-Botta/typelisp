;; A move inside a macro expansion is checked on the expanded body; the
;; diagnostic carries the expansion frame.
(define (consume [_text : String]) : i64
  1)

(defmacro (twice-consume [value : Expr]) : Expr
  `(+ (consume ,value) (consume ,value)))

(define (twice [text : String]) : i64
  (twice-consume text))

(define (main) : i64
  0)