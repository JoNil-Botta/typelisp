;; compiler_regalloc_interval_sort.tl - Declaration generation for regalloc's
;; allocation-free interval heapsorts.
;;
;; The generated declarations are concrete direct-call TypeLisp functions.
;; Ordering, copy, array-view, sift, and public sort names are explicit at each
;; use; `full-array` and `range` select source shapes at compile time, so the
;; hot full-array loops never carry or add a runtime base.
(import stdlib.comptime)

(defmacro (compiler-reg-interval-heapsort
  [T : type (:kind struct)]
  [before-name : Expr]
  [copy-name : Expr]
  [array-view-name : Expr]
  [sift-name : Expr]
  [sort-name : Expr]
  [shape : Expr]
  [ordering : Expr]) : Decls
  (let
    [before-expr : Expr
      (match before-name
        [(Expr.Var value) (comptime.expr-var value)]
        [_
          (comptime-error
            "compiler-reg-interval-heapsort: comparator must be a bare name")])]
    [copy-expr : Expr
      (match copy-name
        [(Expr.Var value) (comptime.expr-var value)]
        [_
          (comptime-error
            "compiler-reg-interval-heapsort: copy declaration must be a bare name")])]
    [array-view-expr : Expr
      (match array-view-name
        [(Expr.Var value) (comptime.expr-var value)]
        [_
          (comptime-error
            "compiler-reg-interval-heapsort: array-view helper must be a bare name")])]
    [sift-expr : Expr
      (match sift-name
        [(Expr.Var value) (comptime.expr-var value)]
        [_
          (comptime-error
            "compiler-reg-interval-heapsort: sift declaration must be a bare name")])]
    [sort-expr : Expr
      (match sort-name
        [(Expr.Var value) (comptime.expr-var value)]
        [_
          (comptime-error
            "compiler-reg-interval-heapsort: sort declaration must be a bare name")])]
    [range? : bool
      (match shape
        [(Expr.Var value)
          (match value
            ["full-array" false]
            ["range" true]
            [_
              (comptime-error
                "compiler-reg-interval-heapsort: shape must be `full-array` or `range`")])]
        [_
          (comptime-error
            "compiler-reg-interval-heapsort: shape must be a bare name")])]
    [candidate-order? : bool
      (match ordering
        [(Expr.Var value)
          (match value
            ["candidate-start-end-var" true]
            ["color-start-var" false]
            [_
              (comptime-error
                "compiler-reg-interval-heapsort: ordering must be `candidate-start-end-var` or `color-start-var`")])]
        [_
          (comptime-error
            "compiler-reg-interval-heapsort: ordering must be a bare name")])]
    [constructor : Expr (comptime.expr-var (type-nominal-name T))]
    [before-body : Expr
      (if candidate-order?
        `(let
          [left-start : i64 left.start]
          [right-start : i64 right.start]
          [left-end : i64 left.end]
          [right-end : i64 right.end]
          (cond
            [(< left-start right-start) true]
            [(> left-start right-start) false]
            [(< left-end right-end) true]
            [(> left-end right-end) false]
            [else (< left.var right.var)]))
        `(let
          [left-start : i64 left.start]
          [right-start : i64 right.start]
          (or
            (< left-start right-start)
            (and (= left-start right-start) (< left.var right.var)))))]
    [before-decl : Expr
      `(define (,before-expr [left : ,T] [right : ,T]) : bool
        ,before-body)]
    [copy-decl : Expr
      `(define (,copy-expr [item : ,T]) : ,T
        (,constructor item.var item.start item.end))]
    [pick-left : Expr
      (if range?
        `(array-ref items (+ base pick))
        `(array-ref items pick))]
    [left-item : Expr
      (if range?
        `(array-ref items (+ base left))
        `(array-ref items left))]
    [pick-right : Expr
      (if range?
        `(array-ref items (+ base pick))
        `(array-ref items pick))]
    [right-item : Expr
      (if range?
        `(array-ref items (+ base right))
        `(array-ref items right))]
    [node-item : Expr
      (if range?
        `(array-ref items (+ base node))
        `(array-ref items node))]
    [largest-item : Expr
      (if range?
        `(array-ref items (+ base largest))
        `(array-ref items largest))]
    [sift-swap : Expr
      (if range?
        `(begin
          (set! (array-ref items (+ base node)) largest-item)
          (set! (array-ref items (+ base largest)) node-item))
        `(begin
          (set! (array-ref items node) largest-item)
          (set! (array-ref items largest) node-item)))]
    [root-item : Expr
      (if range?
        `(array-ref items base)
        `(array-ref items 0))]
    [last-item : Expr
      (if range?
        `(array-ref items (+ base last))
        `(array-ref items last))]
    [extract-swap : Expr
      (if range?
        `(begin
          (set! (array-ref items base) last-item)
          (set! (array-ref items (+ base last)) root-item))
        `(begin
          (set! (array-ref items 0) last-item)
          (set! (array-ref items last) root-item)))]
    [sift-body : Expr
      `(let
        [node : i64 root]
        [done : bool false]
        (while (not done)
          (let
            [left : i64 (+ (* node 2) 1)]
            [right : i64 (+ (* node 2) 2)]
            [largest : i64
              (let
                [pick : i64 node]
                (begin
                  (if (and (< left count) (,before-expr ,pick-left ,left-item))
                    (set! pick left)
                    unit)
                  (if (and
                    (< right count)
                    (,before-expr ,pick-right ,right-item))
                    (set! pick right)
                    unit)
                  pick))]
            (if (= largest node)
              (set! done true)
              (let
                [node-item : ,T (,copy-expr ,node-item)]
                [largest-item : ,T (,copy-expr ,largest-item)]
                (begin
                  ,sift-swap
                  (set! node largest)))))))]
    [sift-decl : Expr
      (if range?
        `(define (,sift-expr
          [items : (__tl_dyn-array ,T)]
          [base : i64]
          [root : i64]
          [count : i64]) : unit
          ,sift-body)
        `(define (,sift-expr
          [items : (__tl_dyn-array ,T)]
          [root : i64]
          [count : i64]) : unit
          ,sift-body))]
    [heap-sift : Expr
      (if range?
        `(,sift-expr (,array-view-expr items) base index count)
        `(,sift-expr (,array-view-expr items) index count))]
    [extract-sift : Expr
      (if range?
        `(,sift-expr (,array-view-expr items) base 0 last)
        `(,sift-expr (,array-view-expr items) 0 last))]
    [sort-body : Expr
      `(begin
        (let
          [index : i64 (- (/ count 2) 1)]
          (while (>= index 0)
            (begin
              ,heap-sift
              (set! index (- index 1)))))
        (let
          [last : i64 (- count 1)]
          (while (> last 0)
            (let
              [root-item : ,T (,copy-expr ,root-item)]
              [last-item : ,T (,copy-expr ,last-item)]
              (begin
                ,extract-swap
                ,extract-sift
                (set! last (- last 1)))))))]
    [sort-decl : Expr
      (if range?
        `(define (,sort-expr
          [items : (__tl_dyn-array ,T)]
          [base : i64]
          [count : i64]) : unit
          ,sort-body)
        `(define (,sort-expr [items : (__tl_dyn-array ,T)] [count : i64]) : unit
          ,sort-body))]
    `(begin
      ,before-decl
      ,copy-decl
      ,sift-decl
      ,sort-decl)))