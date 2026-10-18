(defstruct Cell
  (items (__tl_dyn-array i64)))

(defstruct Holder
  (cell Cell))

(defenum Choice
  (Empty)
  (Full Cell))

(define prefix-calls : i64
  0)
(define receiver-calls : i64
  0)

(define (observe [source : (& source Cell)]) : (& source Cell)
  (set! receiver-calls (+ receiver-calls 1))
  source)

(define (copy-direct [source : (& source Cell)]) : Cell
  (clone (deref (observe source))))

(define (copy-projected [source : (& source Holder)]) : Cell
  (clone (deref source).cell))

(define (copy-mutable [source : (&mut source Cell)]) : Cell
  (clone (deref source)))

(define (copy-choice [source : (& source Choice)]) : Choice
  (clone (deref source)))

(define (copy-fixed [source : (& source (Array Cell 2))]) : (Array Cell 2)
  (clone (deref source)))

(defmacro (read-cell [source : Expr]) : Expr
  `(deref ,source))

(define (copy-flow [source : (& source Cell)] [mode : i64]) : Cell
  (clone
    (match mode
      [0
        (set! prefix-calls (+ prefix-calls 1))
        (deref source)]
      [1
        (if true
          (deref source)
          (deref source))]
      [2
        (let
          [flag true]
          (if flag
            (deref source)
            (deref source)))]
      [3 (ann (deref source) : Cell)]
      [_ (read-cell source)])))

(define (first [cell : (& cell Cell)]) : i64
  (array-ref cell.items 0))

(define cleanup-value : i64
  0)

(define (cleanup-box [source : (Box Cell)]) : unit
  (set! cleanup-value (+ cleanup-value (first (& (deref source))))))

(define (box-cleanup-ok?) : bool
  (with
    ([source (box (Cell (__tl_make-array 90))) cleanup-box])
    (let
      [copy : Cell (clone (deref source))]
      (set! (array-ref copy.items 0) 92)
      (let
        [independent : bool (= (first (& (deref source))) 90)]
        (set! (deref source) (Cell (__tl_make-array 91)))
        (and
          independent
          (= cleanup-value 0)
          (= (first (& copy)) 92)
          (= (first (& (deref source))) 91))))))

(define (main) : i64
  (let
    [source : Cell (Cell (__tl_make-array 10 20))]
    [direct : Cell (copy-direct (& source))]
    [mutable : Cell (copy-mutable (&mut source))]
    [holder : Holder (Holder (Cell (__tl_make-array 25)))]
    [projected : Cell (copy-projected (& holder))]
    [sequence : Cell (copy-flow (& source) 0)]
    [conditional : Cell (copy-flow (& source) 1)]
    [bound : Cell (copy-flow (& source) 2)]
    [annotated : Cell (copy-flow (& source) 3)]
    [expanded : Cell (copy-flow (& source) 4)]
    [choice : Choice (Full (Cell (__tl_make-array 30 40)))]
    [choice-copy : Choice (copy-choice (& choice))]
    [fixed : (Array Cell 2)
      (array (Cell (__tl_make-array 50)) (Cell (__tl_make-array 60)))]
    [fixed-copy : (Array Cell 2) (copy-fixed (& fixed))]
    [boxed : (Box Cell) (box (Cell (__tl_make-array 70 80)))]
    [box-copy : Cell (clone (deref boxed))]
    [cleanup-ok : bool (box-cleanup-ok?)]
    [_mutate-copy : unit (set! (array-ref box-copy.items 0) 71)]
    [box-independent : bool (= (first (& (deref boxed))) 70)]
    (set! (array-ref source.items 0) 99)
    (set! (array-ref holder.cell.items 0) 26)
    (set! (deref boxed) (Cell (__tl_make-array 77)))
    (set! (array-ref (array-ref fixed 0).items 0) 55)
    (if (and
      cleanup-ok
      box-independent
      (= cleanup-value 91)
      (= receiver-calls 1)
      (= prefix-calls 1)
      (= (first (& source)) 99)
      (= (first (& direct)) 10)
      (= (first (& mutable)) 10)
      (= (first (& projected)) 25)
      (= (first (& holder.cell)) 26)
      (= (first (& sequence)) 10)
      (= (first (& conditional)) 10)
      (= (first (& bound)) 10)
      (= (first (& annotated)) 10)
      (= (first (& expanded)) 10)
      (match choice-copy
        [(Empty) false]
        [(Full cell) (= (first (& cell)) 30)])
      (match choice
        [(Empty) false]
        [(Full cell) (= (first (& cell)) 30)])
      (= (first (& (array-ref fixed-copy 0))) 50)
      (= (first (& (array-ref fixed-copy 1))) 60)
      (= (first (& (deref boxed))) 77)
      (= (first (& box-copy)) 71))
      42
      1)))