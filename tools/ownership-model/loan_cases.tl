;; Shared input construction only: no transfer, liveness or expected decisions.
;; 32 direct configurations, 20 sibling configurations, 8 three-deep chains.
;; Parent modes are structurally valid; invalid mode relationships have their
;; own malformed-input tests rather than being hidden in execution comparisons.
(import loan_model as model)
(import stdlib.iterator)

(define (side [right? : bool]) : model.Cell
  (if right?
    model.Cell.Right
    model.Cell.Left))

(define (configuration [code : i64]) : (Array model.Loan 3)
  (let
    [topology : i64
      (if (< code 32)
        0
        (if (< code 52)
          1
          2))]
    [within : i64
      (if (= topology 0)
        code
        (if (= topology 1)
          (- code 32)
          (- code 52)))]
    [permission : i64
      (if (= topology 2)
        (/ within 2)
        (/ within 4))]
    [exclusive : i64
      (cond
        [(= topology 0) permission]
        [(= topology 1)
          (if (= permission 0)
            0
            (- (* permission 2) 1))]
        [else (- (shl 1 permission) 1)])]
    [first : model.Cell (side (!= (bit-and within 1) 0))]
    [second : model.Cell
      (if (= topology 2)
        first
        (side (!= (bit-and within 2) 0)))]
    (array
      (model.Loan model.Cell.Whole (!= (bit-and exclusive 1) 0) -1)
      (model.Loan
        first
        (!= (bit-and exclusive 2) 0)
        (if (= topology 0)
          -1
          0))
      (model.Loan
        second
        (!= (bit-and exclusive 4) 0)
        (if (= topology 0)
          -1
          (if (= topology 1)
            0
            1))))))

(define (trace
  [loans : (& loans (Array model.Loan 3))]
  [retained : i64]
  [action : i64]) : (__tl_dyn-array model.Event)
  (let
    [keeps : i64
      (+
        (+
          (if (!= (bit-and retained 1) 0)
            1
            0)
          (if (!= (bit-and retained 2) 0)
            1
            0))
        (if (!= (bit-and retained 4) 0)
          1
          0))]
    [out : (__tl_dyn-array model.Event)
      (__tl_make-array
        model.Event
        (+
          (+ 3 keeps)
          (if (= action 0)
            0
            1)))]
    [index : i64 0]
    [position : i64 3]
    (begin
      (while (< index 3)
        (begin
          (set!
            (array-ref out index)
            (if (< (array-ref loans index).parent 0)
              (model.Event.Borrow index)
              (model.Event.Reborrow index)))
          (set! index (+ index 1))))
      (unless
        (= action 0)
        (begin
          (set!
            (array-ref out position)
            (match action
              [1 (model.Event.Read model.Cell.Whole)]
              [2 (model.Event.Read model.Cell.Left)]
              [3 (model.Event.Read model.Cell.Right)]
              [4 (model.Event.Write model.Cell.Whole)]
              [5 (model.Event.Write model.Cell.Left)]
              [6 (model.Event.Write model.Cell.Right)]
              [_ (model.Event.ReadThrough 2 (array-ref loans 2).cell)]))
          (set! position (+ position 1))))
      (set! index 0)
      (while (< index 3)
        (begin
          (unless
            (= (bit-and retained (shl 1 index)) 0)
            (begin
              (set! (array-ref out position) (model.Event.Keep index))
              (set! position (+ position 1))))
          (set! index (+ index 1))))
      out)))

(define (witness-loans [mode : i64]) : (Array model.Loan 3)
  (cond
    [(< mode 2) (configuration 48)]
    [(< mode 4)
      (array
        (model.Loan model.Cell.Whole false -1)
        (model.Loan model.Cell.Left (= mode 2) -1)
        (model.Loan model.Cell.Right false -1))]
    [(= mode 4) (configuration 56)]
    [(< mode 7) (configuration 58)]
    [else (configuration 26)]))

(define (witness-trace [mode : i64]) : (__tl_dyn-array model.Event)
  (match mode
    [0
      (__tl_make-array
        (model.Event.Borrow 0)
        (model.Event.Reborrow 1)
        (model.Event.Reborrow 2)
        (model.Event.Keep 1))]
    [1
      (__tl_make-array
        (model.Event.Borrow 0)
        (model.Event.Reborrow 1)
        (model.Event.Reborrow 2))]
    [2
      (__tl_make-array
        (model.Event.Borrow 0)
        (model.Event.Borrow 1)
        (model.Event.Borrow 2)
        (model.Event.Keep 0))]
    [3
      (__tl_make-array
        (model.Event.Borrow 0)
        (model.Event.Borrow 1)
        (model.Event.Borrow 2)
        (model.Event.Keep 0))]
    [4
      (__tl_make-array
        (model.Event.Borrow 0)
        (model.Event.Reborrow 1)
        (model.Event.Reborrow 2)
        (model.Event.Write model.Cell.Right)
        (model.Event.Keep 2))]
    [5
      (__tl_make-array
        (model.Event.Borrow 0)
        (model.Event.Reborrow 1)
        (model.Event.Reborrow 2)
        (model.Event.WriteThrough 2 model.Cell.Left)
        (model.Event.Keep 1))]
    [6
      (__tl_make-array
        (model.Event.Borrow 0)
        (model.Event.Reborrow 1)
        (model.Event.Reborrow 2)
        (model.Event.Keep 2)
        (model.Event.Write model.Cell.Whole))]
    [_
      (__tl_make-array
        (model.Event.Borrow 0)
        (model.Event.Borrow 1)
        (model.Event.Borrow 2)
        (model.Event.Keep 1)
        (model.Event.Keep 2))]))

(define (reference-program [mode : i64]) : model.ReferenceProgram
  (let
    [copy? : bool
      (not
        (or (= mode 0) (= mode 1) (= mode 4) (= mode 7) (= mode 13) (= mode 14)))]
    [events : (__tl_dyn-array model.ReferenceEvent)
      (match mode
        [0
          (__tl_make-array
            (model.ReferenceEvent.Intrinsic (model.Event.Borrow 0))
            (model.ReferenceEvent.Bind 0 0)
            (model.ReferenceEvent.Intrinsic (model.Event.Borrow 0))
            (model.ReferenceEvent.Use 0))]
        [1
          (__tl_make-array
            (model.ReferenceEvent.Intrinsic (model.Event.Borrow 0))
            (model.ReferenceEvent.Bind 0 0)
            (model.ReferenceEvent.Clear 0)
            (model.ReferenceEvent.Intrinsic (model.Event.Borrow 0))
            (model.ReferenceEvent.Bind 0 0)
            (model.ReferenceEvent.Use 0))]
        [2
          (__tl_make-array
            (model.ReferenceEvent.Intrinsic (model.Event.Borrow 0))
            (model.ReferenceEvent.Bind 0 0)
            (model.ReferenceEvent.Intrinsic (model.Event.Borrow 0))
            (model.ReferenceEvent.Bind 1 0)
            (model.ReferenceEvent.Use 0)
            (model.ReferenceEvent.Use 1))]
        [3
          (__tl_make-array
            (model.ReferenceEvent.Intrinsic (model.Event.Borrow 0))
            (model.ReferenceEvent.Bind 0 0)
            (model.ReferenceEvent.Copy 0 1)
            (model.ReferenceEvent.Clear 0)
            (model.ReferenceEvent.Intrinsic (model.Event.Write model.Cell.Left))
            (model.ReferenceEvent.Use 1))]
        [4
          (__tl_make-array
            (model.ReferenceEvent.Intrinsic (model.Event.Borrow 0))
            (model.ReferenceEvent.Bind 0 0)
            (model.ReferenceEvent.Move 0 1)
            (model.ReferenceEvent.Intrinsic (model.Event.Write model.Cell.Left))
            (model.ReferenceEvent.Use 1))]
        [5
          (__tl_make-array
            (model.ReferenceEvent.Intrinsic (model.Event.Borrow 0))
            (model.ReferenceEvent.Bind 0 0)
            (model.ReferenceEvent.Intrinsic (model.Event.Borrow 1))
            (model.ReferenceEvent.Bind 1 1)
            (model.ReferenceEvent.Intrinsic (model.Event.Write model.Cell.Left))
            (model.ReferenceEvent.Move 1 0)
            (model.ReferenceEvent.Use 0))]
        [6
          (__tl_make-array
            (model.ReferenceEvent.Intrinsic (model.Event.Borrow 0))
            (model.ReferenceEvent.Bind 0 0)
            (model.ReferenceEvent.Copy 0 1)
            (model.ReferenceEvent.Intrinsic (model.Event.Borrow 1))
            (model.ReferenceEvent.Bind 2 1)
            (model.ReferenceEvent.Move 2 0)
            (model.ReferenceEvent.Intrinsic (model.Event.Write model.Cell.Left))
            (model.ReferenceEvent.Use 1))]
        [7
          (__tl_make-array
            (model.ReferenceEvent.Intrinsic (model.Event.Borrow 0))
            (model.ReferenceEvent.Bind 0 0)
            (model.ReferenceEvent.Move 0 1)
            (model.ReferenceEvent.Use 0))]
        [8
          (__tl_make-array
            (model.ReferenceEvent.Intrinsic (model.Event.Borrow 0))
            (model.ReferenceEvent.Bind 0 0)
            (model.ReferenceEvent.Move 0 1)
            (model.ReferenceEvent.Use 0)
            (model.ReferenceEvent.Use 1))]
        [9
          (__tl_make-array
            (model.ReferenceEvent.Intrinsic (model.Event.Borrow 0))
            (model.ReferenceEvent.Bind 0 0)
            (model.ReferenceEvent.Intrinsic (model.Event.End 0))
            (model.ReferenceEvent.Intrinsic (model.Event.Borrow 0))
            (model.ReferenceEvent.Bind 1 0)
            (model.ReferenceEvent.Use 0))]
        [10
          (__tl_make-array
            (model.ReferenceEvent.Intrinsic (model.Event.Borrow 0))
            (model.ReferenceEvent.Bind 0 0)
            (model.ReferenceEvent.Use 0)
            (model.ReferenceEvent.Intrinsic (model.Event.End 0)))]
        [11 (__tl_make-array (model.ReferenceEvent.Use 3))]
        [12 (__tl_make-array model.ReferenceEvent 0)]
        [13
          (__tl_make-array
            (model.ReferenceEvent.Intrinsic (model.Event.Borrow 0))
            (model.ReferenceEvent.Bind 0 0)
            (model.ReferenceEvent.Move 0 0)
            (model.ReferenceEvent.Use 0))]
        [14
          (__tl_make-array
            (model.ReferenceEvent.Intrinsic (model.Event.Borrow 0))
            (model.ReferenceEvent.Bind 0 0)
            (model.ReferenceEvent.Copy 0 1))]
        [_ (__tl_make-array (model.ReferenceEvent.Use 0))])]
    (model.ReferenceProgram copy? events)))

(define (reference-loans [copy? : bool]) : (Array model.Loan 3)
  (array
    (model.Loan model.Cell.Left (not copy?) -1)
    (model.Loan model.Cell.Right (not copy?) -1)
    (model.Loan model.Cell.Whole false -1)))

;; Concrete paths through a loop with one static borrow site. Prev initially
;; names the disjoint right cell, so even the first trip reads a real reference.
(define (reference-cfg-program [kind : i64] [trips : i64]) : model.ReferenceProgram
  (let
    [copy? : bool (or (= kind 1) (= kind 3))]
    [events : (__tl_dyn-array model.ReferenceEvent)
      (__tl_make-array
        (model.ReferenceEvent.Intrinsic (model.Event.Borrow 1))
        (model.ReferenceEvent.Bind 0 1))]
    (for [_trip (iterator.range 0 trips)]
      (when (= kind 2) (__tl_array-push! events (model.ReferenceEvent.Clear 0)))
      (__tl_array-push!
        events
        (model.ReferenceEvent.Intrinsic (model.Event.Borrow 0)))
      (__tl_array-push! events (model.ReferenceEvent.Bind 1 0))
      (unless (= kind 2) (__tl_array-push! events (model.ReferenceEvent.Use 0)))
      (__tl_array-push! events (model.ReferenceEvent.Move 1 0))
      (when
        (= kind 3)
        (__tl_array-push!
          events
          (model.ReferenceEvent.Intrinsic (model.Event.End 0)))))
    (__tl_array-push!
      events
      (model.ReferenceEvent.Intrinsic (model.Event.Consume model.Cell.Left)))
    (model.ReferenceProgram copy? events)))