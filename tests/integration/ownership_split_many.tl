;; Many independent reassigned references in one body exercise the transfer
;; index without committing thousands of repeated source lines.
(import stdlib.comptime)

(defstruct Pair
  (left i64)
  (right i64))

(defmacro (many-splits [count : comptime.Expr]) : Decls
  (let
    [forms : comptime.ExprList (comptime.expr-list-empty)]
    [index : i64
      (match count
        [(comptime.Expr.Int value) value]
        [_ 0])]
    (while (> index 0)
      (set! index (- index 1))
      (set!
        forms
        (comptime.expr-list-cons
          `(let
            [view : (& pair i64) (& pair.left)]
            (set! view (& pair.right))
            (set! total (+ total (deref view) (deref view))))
          forms)))
    `(define (split-many [value : i64]) : i64
      (let
        [pair : Pair (Pair 1 value)]
        [total : i64 0]
        ,@forms
        total))))

(many-splits 256)

;; Splitting `first` appends an edge rooted in the later branch-result place,
;; itself split between two definitions. Its unmatched edge must remain intact.
;; A second read of first exercises another outgoing edge of the same place.
(define (split-chain [choose : bool]) : i64
  (let
    [pair : Pair (Pair 3 39)]
    [first : (& pair i64) (& pair.left)]
    [before : i64 (read-reference first)]
    [second : (& pair i64) (& pair.right)]
    (set!
      first
      (if choose
        second
        (& pair.left)))
    (let
      [kept : (& pair i64) first]
      [also : (& pair i64) first]
      (set! second (& pair.left))
      (+
        before
        (read-reference kept)
        (read-reference also)
        (read-reference second)))))

(define (read-reference [view : (& value i64)]) : i64
  (deref view))

(define (main) : i64
  (if (and
    (= (split-many 21) 10752)
    (= (split-chain true) 84)
    (= (split-chain false) 12))
    42
    1))