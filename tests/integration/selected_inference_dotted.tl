;; Selected Query inference must preserve the canonical ID path for dotted
;; hygienic locals, including assignments and generated function bodies.
(import stdlib.comptime)

(defstruct SelectedPair
  (start i64)
  (value i64))

(defmacro (read-selected [source : comptime.Expr]) : comptime.Expr
  `(let
    [selected ,source]
    (+ selected.start 1)))

(defmacro (write-selected [source : comptime.Expr]) : comptime.Expr
  `(let
    [selected ,source]
    (begin
      (set! selected.start (+ selected.start 1))
      (+ selected.start selected.value))))

(defmacro (selected-reader) : comptime.Expr
  `(lambda ([selected : SelectedPair]) : i64
    (+ selected.start 1)))

(define (main) : i64
  (let
    [reader : (-> SelectedPair i64) (selected-reader)]
    (if (and
      (= (read-selected (SelectedPair 41 0)) 42)
      (= (write-selected (SelectedPair 40 1)) 42)
      (= (reader (SelectedPair 41 0)) 42))
      42
      1)))