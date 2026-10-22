;; Introducing a same-named local does not change a captured incoming reference.
(defmacro (replace-from-incoming [target : Expr] [value : Expr]) : Expr
  `(let
    [shadowed : i64 42]
    (set! ,target ,value)))

(define (keep-reference [incoming : (& keep i64)]) : i64
  (let
    [outer incoming]
    (replace-from-incoming outer incoming)
    (deref outer)))

(define (main) : i64
  (let
    [shadowed : i64 42]
    (keep-reference (& shadowed))))