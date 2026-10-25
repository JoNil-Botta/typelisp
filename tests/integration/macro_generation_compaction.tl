;; Macro generations compact the expression rows their expansions discard
;; (#9224). The same generated imports expand again only after several firing
;; declarations, whose generations reclaimed rows and retired their arenas,
;; and must splice the memoized module; each firing declaration keeps its own
;; result.
(import stdlib.iterator)

(defmacro (emit-imports) : Decls
  `(begin
    (import decls_generated_import_dep as first)
    (import decls_generated_import_dep as second)))

(defmacro (twice [value : Expr]) : Expr
  `(+ ,value ,value))

(emit-imports)

(define (sum-above [limit : i64] [floor : i64]) : i64
  (let
    [total : i64 0]
    (for [index (iterator.range 0 limit)]
      (when (and (> index floor) (< index limit)) (+= total index)))
    total))

(define (count-odd [limit : i64]) : i64
  (let
    [count : i64 0]
    (for [index (iterator.range 0 limit)]
      (unless (= (% index 2) 0) (+= count 1)))
    count))

(define (doubled [value : i64]) : i64
  (twice (twice value)))

(define (chosen [flag : bool]) : i64
  (cond [(and flag (not (= (doubled 1) 0))) (twice 3)] [else (twice 4)]))

(emit-imports)

(define (main) : i64
  (if (and
    (= (sum-above 5 1) 9)
    (= (count-odd 7) 3)
    (= (doubled 2) 8)
    (= (chosen true) 6)
    (= first.answer 14)
    (= second.answer 14))
    42
    0))