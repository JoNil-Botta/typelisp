;; A hygienic local has a structural lifetime identity, not a string-pool index.
(defmacro (replace-from-hidden-local [target : Expr]) : Expr
  `(let
    [shadowed : i64 42]
    (set! ,target (& shadowed))))

(define (escape-hidden-local [incoming : (& keep i64)]) : i64
  (let
    [outer incoming]
    (replace-from-hidden-local outer)
    (deref outer)))

(define (main) : i64
  0)