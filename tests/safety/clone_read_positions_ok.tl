;; Generated `clone-cell` takes a shared reference `(& Cell)` through every
;; result position: `if` branches, match arm bodies, a `let` body, the last
;; form of a `begin`, annotations and macro expansions, and projected places
;; (field, tuple, array, and `Box` `deref`). An owned place borrowed there
;; stays usable afterwards, a place borrowed through a reference is not moved
;; out of it, a temporary is cloned via `clone.deep`, and a diverging branch
;; reads nothing. Every copy is independent storage.
(import stdlib.clone)
(import stdlib.io)

(defstruct Cell
  (items (__tl_dyn-array i64)))

(clone.gen-clone Cell)

(defstruct Holder
  (cell Cell)
  (id i64))

(defmacro (pick [flag : Expr] [left : Expr] [right : Expr]) : Expr
  `(if ,flag
    ,left
    ,right))

(define (first [cell : (& cell Cell)]) : i64
  (array-ref cell.items 0))

(define (fresh [value : i64]) : Cell
  (Cell (__tl_make-array value)))

;; 1 + 2 + 1 + 1, then the originals: 10 (written after the copies) + 2.
(define (owned-places [flag : bool]) : i64
  (let
    [a : Cell (fresh 1)]
    [b : Cell (fresh 2)]
    [from-if : Cell
      (clone-cell
        (if flag
          (& a)
          (& b)))]
    [from-match : Cell
      (clone-cell
        (match flag
          [true
            (begin
              0
              (& b))]
          [false (& a)]))]
    [from-let : Cell
      (clone-cell
        (let
          [_unused 0]
          (& a)))]
    [from-macro : Cell (clone-cell (pick flag (ann (& a) : (& a Cell)) (& b)))]
    (set! (array-ref a.items 0) 10)
    (+
      (first (& from-if))
      (first (& from-match))
      (first (& from-let))
      (first (& from-macro))
      (first (& a))
      (first (& b)))))

;; 3 + 4 + 5.
(define (projections
  [flag : bool]
  [holder : (& holder Holder)]
  [pair : (& pair (Tuple Cell i64))]
  [cells : (& cells (Array Cell 2))]) : i64
  (let
    [h
      (if flag
        holder
        holder)]
    [field : Cell (clone-cell (& h.cell))]
    [p
      (match flag
        [true pair]
        [false pair])]
    [element : Cell (clone-cell (& (tuple-ref (deref p) 0)))]
    [c
      (if flag
        cells
        cells)]
    [item : Cell (clone-cell (& (array-ref (deref c) 1)))]
    (+ (first (& field)) (first (& element)) (first (& item)))))

;; 60 (the copy, written) + 6 + 7.
(define (boxes [flag : bool]) : i64
  (let
    [left : (Box Cell) (box (fresh 6))]
    [right : (Box Cell) (box (fresh 7))]
    [copy : Cell
      (clone-cell
        (if flag
          (& (deref left))
          (& (deref right))))]
    (set! (array-ref copy.items 0) 60)
    (+ (first (& copy)) (first (& (deref left))) (first (& (deref right))))))

;; 8 + 9.
(define (mixed [flag : bool] [source : (& source Cell)]) : i64
  (let
    [value : Cell
      (if flag
        (clone.deep (fresh 8))
        (clone-cell source))]
    [kept : Cell
      (clone-cell
        (if flag
          source
          (io.panic "unreachable")))]
    (+ (first (& value)) (first (& kept)))))

(define (main) : i64
  (let
    [holder : Holder (Holder (fresh 3) 0)]
    [pair : (Tuple Cell i64) (tuple (fresh 4) 0)]
    [cells : (Array Cell 2) (array (fresh 0) (fresh 5))]
    [source : Cell (fresh 9)]
    [total : i64
      (+
        (owned-places true)
        (projections true (& holder) (& pair) (& cells))
        (boxes true)
        (mixed true (& source)))]
    (if (and (= total 119) (= (first (& source)) 9))
      42
      1)))