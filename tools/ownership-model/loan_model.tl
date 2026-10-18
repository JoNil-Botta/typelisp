;; Independent concrete loan semantics over two cells and three loan slots.
;; No production imports, CFG lattice, worklist or abstract transfer rules.
;; Each issued capability gets a fresh dynamic token. Finite traces represent
;; individual executions, including repeated visits to a static borrow site.
(import stdlib.iterator)

(defenum Cell
  (Whole)
  (Left)
  (Right))

(defstruct Loan
  (cell Cell)
  (exclusive bool)
  (parent i64))

(defenum Event
  (Read Cell)
  (Write Cell)
  (Consume Cell)
  (Invalidate Cell)
  (Borrow i64)
  (Reborrow i64)
  (Keep i64)
  ;; A use of a reference that may carry this loan: it keeps an issued token
  ;; alive but needs none, since this path may carry another loan.
  (MayKeep i64)
  (ReadThrough i64 Cell)
  (WriteThrough i64 Cell)
  (End i64))

(defstruct Memory
  (left bool)
  (right bool)
  (tokens (Array i64 3))
  (parents (Array i64 3))
  (next i64))

(defenum Outcome
  (Accepted bool bool)
  (Rejected i64)
  (InvalidInput))

;; Concrete execution observations, never abstract facts. Three entries per
;; event record the actual generation tokens before and after a successful
;; step. Before rows include last-use expiry from the preceding step; after
;; rows precede expiry. Only rows below completed are after-state witnesses.
(defstruct Observation
  (before (__tl_dyn-array i64))
  (after (__tl_dyn-array i64))
  (before-parents (__tl_dyn-array i64))
  (after-parents (__tl_dyn-array i64))
  (completed i64)
  ;; -1 means the whole trace executed; -2 is invalid input.
  (failure i64))

(define (contains? [outer : Cell] [inner : Cell]) : bool
  (match outer
    [(Cell.Whole) true]
    [(Cell.Left)
      (match inner
        [(Cell.Left) true]
        [_ false])]
    [(Cell.Right)
      (match inner
        [(Cell.Right) true]
        [_ false])]))

(define (overlap? [a : Cell] [b : Cell]) : bool
  (or (contains? a b) (contains? b a)))

(define (ready? [memory : (& memory Memory)] [cell : Cell]) : bool
  (match cell
    [(Cell.Whole) (and memory.left memory.right)]
    [(Cell.Left) memory.left]
    [(Cell.Right) memory.right]))

(define (write! [memory : (&mut memory Memory)] [cell : Cell] [value : bool]) : unit
  (match cell
    [(Cell.Whole)
      (begin
        (set! memory.left value)
        (set! memory.right value))]
    [(Cell.Left) (set! memory.left value)]
    [(Cell.Right) (set! memory.right value)]))

;; Follow actual generation links. Reissuing a parent cannot make an old child
;; valid again even when its static loan index has not changed.
(define (live?
  [loans : (& loans (Array Loan 3))]
  [memory : (& memory Memory)]
  [loan : i64]) : bool
  (let
    [current : i64 loan]
    (begin
      (while (>= current 0)
        (begin
          (unless (> (array-ref memory.tokens current) 0) (return false))
          (let
            [parent : i64 (array-ref loans current).parent]
            (begin
              (when
                (and
                  (>= parent 0)
                  (!=
                    (array-ref memory.parents current)
                    (array-ref memory.tokens parent)))
                (return false))
              (set! current parent)))))
      true)))

(define (depends-on?
  [loans : (& loans (Array Loan 3))]
  [memory : (& memory Memory)]
  [child : i64]
  [token : i64]) : bool
  (let
    [current : i64 child]
    (begin
      (while (>= current 0)
        (begin
          (when (= (array-ref memory.tokens current) token) (return true))
          (let
            [parent : i64 (array-ref loans current).parent]
            (if (and
              (>= parent 0)
              (=
                (array-ref memory.parents current)
                (array-ref memory.tokens parent)))
              (set! current parent)
              (set! current (- 0 1))))))
      false)))

;; Scan an actual execution suffix for uses of THIS dynamic token. This is
;; deliberately not a backward CFG analysis. A later direct borrow overwrites
;; that slot's identity; a reborrow first uses its parent's current capability.
;; Keeping/ending a child also retains the exact parent generation it uses.
(define (needed-later?
  [loans : (& loans (Array Loan 3))]
  [count : i64]
  [memory : (& memory Memory)]
  [trace : (& trace (__tl_dyn-array Event))]
  [start : i64]
  [loan : i64]) : bool
  (let
    [token : i64 (array-ref memory.tokens loan)]
    [carries : (Array bool 3) (array false false false)]
    [index : i64 0]
    (begin
      (when (= token 0) (return false))
      (while (< index count)
        (begin
          (set!
            (array-ref carries index)
            (and
              (> (array-ref memory.tokens index) 0)
              (depends-on? loans memory index token)))
          (set! index (+ index 1))))
      (set! index start)
      (while (< index (array-length trace))
        (begin
          (match (array-ref trace index)
            [(Event.Borrow id) (set! (array-ref carries id) false)]
            [(Event.Reborrow id)
              (begin
                (when
                  (array-ref carries (array-ref loans id).parent)
                  (return true))
                (set! (array-ref carries id) false))]
            [(Event.Keep id) (when (array-ref carries id) (return true))]
            [(Event.MayKeep id) (when (array-ref carries id) (return true))]
            [(Event.ReadThrough id _)
              (when (array-ref carries id) (return true))]
            [(Event.WriteThrough id _)
              (when (array-ref carries id) (return true))]
            [(Event.End id)
              (begin
                (when (array-ref carries id) (return true))
                (set! (array-ref carries id) false))]
            [_ unit])
          (set! index (+ index 1))))
      false)))

(define (expire!
  [loans : (& loans (Array Loan 3))]
  [count : i64]
  [memory : (&mut memory Memory)]
  [trace : (& trace (__tl_dyn-array Event))]
  [start : i64]) : unit
  (let
    [needed : (Array bool 3) (array false false false)]
    [index : i64 0]
    (begin
      ;; Decide against one concrete state before retiring any parent token.
      (while (< index count)
        (begin
          (set!
            (array-ref needed index)
            (needed-later? loans count (& memory) trace start index))
          (set! index (+ index 1))))
      (set! index 0)
      (while (< index count)
        (begin
          (unless
            (array-ref needed index)
            (begin
              (set! (array-ref memory.tokens index) 0)
              (set! (array-ref memory.parents index) 0)))
          (set! index (+ index 1)))))))

(define (permitted?
  [loans : (& loans (Array Loan 3))]
  [count : i64]
  [memory : (& memory Memory)]
  [cell : Cell]
  [write : bool]
  [grant : i64]) : bool
  (let
    [index : i64 0]
    (begin
      (while (< index count)
        (begin
          (when
            (and
              (> (array-ref memory.tokens index) 0)
              (overlap? cell (array-ref loans index).cell)
              (or write (array-ref loans index).exclusive)
              (not
                (and
                  (>= grant 0)
                  (depends-on?
                    loans
                    memory
                    grant
                    (array-ref memory.tokens index)))))
            (return false))
          (set! index (+ index 1))))
      true)))

;; A static loan executed again while its earlier token is still needed (a
;; borrow site on a loop path, its old token retained by a child) issues a
;; second token. Two shared tokens of one loan cover the same cell with the
;; same authority and parent generation, so the slot keeps the held token for
;; both, and it lives while either is needed. Two exclusive tokens of one loan
;; would alias, so that issue fails, as does a shared one whose parent
;; generation has changed.
(define (issue!
  [loans : (& loans (Array Loan 3))]
  [count : i64]
  [memory : (&mut memory Memory)]
  [id : i64]) : bool
  (let
    [parent : i64 (array-ref loans id).parent]
    [cell : Cell (array-ref loans id).cell]
    [held : bool (> (array-ref memory.tokens id) 0)]
    (begin
      (unless
        (and
          (or
            (not held)
            (and
              (not (array-ref loans id).exclusive)
              (or
                (< parent 0)
                (=
                  (array-ref memory.parents id)
                  (array-ref memory.tokens parent)))))
          (ready? (& memory) cell)
          (or
            (< parent 0)
            (and
              (live? loans (& memory) parent)
              (or
                (not (array-ref loans id).exclusive)
                (array-ref loans parent).exclusive)))
          (permitted?
            loans
            count
            (& memory)
            cell
            (array-ref loans id).exclusive
            parent))
        (return false))
      (unless
        held
        (set! (array-ref memory.tokens id) memory.next)
        (set!
          (array-ref memory.parents id)
          (if (< parent 0)
            0
            (array-ref memory.tokens parent)))
        (set! memory.next (+ memory.next 1)))
      true)))

(define (event-id [event : Event]) : i64
  (match event
    [(Event.Borrow id) id]
    [(Event.Reborrow id) id]
    [(Event.Keep id) id]
    [(Event.MayKeep id) id]
    [(Event.ReadThrough id _) id]
    [(Event.WriteThrough id _) id]
    [(Event.End id) id]
    [_ (- 0 1)]))

(define (input-valid?
  [loans : (& loans (Array Loan 3))]
  [count : i64]
  [trace : (& trace (__tl_dyn-array Event))]) : bool
  (let
    [index : i64 0]
    (begin
      (unless
        (and (>= count 0) (<= count 3) (<= (array-length trace) 128))
        (return false))
      (while (< index count)
        (let
          [parent : i64 (array-ref loans index).parent]
          (begin
            (unless (and (>= parent (- 0 1)) (< parent index)) (return false))
            (when
              (and
                (>= parent 0)
                (not
                  (contains?
                    (array-ref loans parent).cell
                    (array-ref loans index).cell)))
              (return false))
            (set! index (+ index 1)))))
      (set! index 0)
      (while (< index (array-length trace))
        (let
          [event : Event (array-ref trace index)]
          [id : i64 (event-id event)]
          (begin
            (unless
              (match event
                [(Event.Read _) true]
                [(Event.Write _) true]
                [(Event.Consume _) true]
                [(Event.Invalidate _) true]
                [_ (and (>= id 0) (< id count))])
              (return false))
            (match event
              [(Event.Borrow loan)
                (unless (< (array-ref loans loan).parent 0) (return false))]
              [(Event.Reborrow loan)
                (unless (>= (array-ref loans loan).parent 0) (return false))]
              [_ unit])
            (set! index (+ index 1)))))
      true)))

(define (step!
  [loans : (& loans (Array Loan 3))]
  [count : i64]
  [memory : (&mut memory Memory)]
  [trace : (& trace (__tl_dyn-array Event))]
  [index : i64]) : bool
  (match (array-ref trace index)
    [(Event.Read cell)
      (and
        (ready? (& memory) cell)
        (permitted? loans count (& memory) cell false (- 0 1)))]
    [(Event.Write cell)
      (if (permitted? loans count (& memory) cell true (- 0 1))
        (begin
          (write! memory cell true)
          true)
        false)]
    [(Event.Consume cell)
      (if (and
        (ready? (& memory) cell)
        (permitted? loans count (& memory) cell true (- 0 1)))
        (begin
          (write! memory cell false)
          true)
        false)]
    [(Event.Invalidate cell)
      (if (permitted? loans count (& memory) cell true (- 0 1))
        (begin
          (write! memory cell false)
          true)
        false)]
    [(Event.Borrow id) (issue! loans count memory id)]
    [(Event.Reborrow id) (issue! loans count memory id)]
    [(Event.Keep id) (live? loans (& memory) id)]
    [(Event.MayKeep _) true]
    [(Event.ReadThrough id cell)
      (and
        (live? loans (& memory) id)
        (contains? (array-ref loans id).cell cell)
        (ready? (& memory) cell)
        (permitted? loans count (& memory) cell false id))]
    [(Event.WriteThrough id cell)
      (if (and
        (live? loans (& memory) id)
        (array-ref loans id).exclusive
        (contains? (array-ref loans id).cell cell)
        (permitted? loans count (& memory) cell true id))
        (begin
          (write! memory cell true)
          true)
        false)]
    [(Event.End id)
      (if (and
        (live? loans (& memory) id)
        (not (needed-later? loans count (& memory) trace (+ index 1) id)))
        (begin
          (set! (array-ref memory.tokens id) 0)
          (set! (array-ref memory.parents id) 0)
          true)
        false)]))

(define (execute
  [loans : (& loans (Array Loan 3))]
  [count : i64]
  [trace : (& trace (__tl_dyn-array Event))]
  [left : bool]
  [right : bool]) : Outcome
  (if (not (input-valid? loans count trace))
    Outcome.InvalidInput
    (let
      [memory : Memory (Memory left right (array 0 0 0) (array 0 0 0) 1)]
      [index : i64 0]
      (begin
        (while (< index (array-length trace))
          (begin
            (unless
              (step! loans count (&mut memory) trace index)
              (return (Outcome.Rejected index)))
            (expire! loans count (&mut memory) trace (+ index 1))
            (set! index (+ index 1))))
        (Outcome.Accepted memory.left memory.right)))))

(define (observe
  [loans : (& loans (Array Loan 3))]
  [count : i64]
  [trace : (& trace (__tl_dyn-array Event))]
  [left : bool]
  [right : bool]) : Observation
  (if (not (input-valid? loans count trace))
    (Observation
      (__tl_make-array i64 0)
      (__tl_make-array i64 0)
      (__tl_make-array i64 0)
      (__tl_make-array i64 0)
      0
      -2)
    (let
      [cells : i64 (* 3 (array-length trace))]
      [before : (__tl_dyn-array i64) (__tl_make-array i64 cells)]
      [after : (__tl_dyn-array i64) (__tl_make-array i64 cells)]
      [before-parents : (__tl_dyn-array i64) (__tl_make-array i64 cells)]
      [after-parents : (__tl_dyn-array i64) (__tl_make-array i64 cells)]
      [memory : Memory (Memory left right (array 0 0 0) (array 0 0 0) 1)]
      [index : i64 0]
      (begin
        (while (< index (array-length trace))
          (let
            [loan : i64 0]
            (begin
              (while (< loan count)
                (begin
                  (set!
                    (array-ref before (+ (* 3 index) loan))
                    (array-ref memory.tokens loan))
                  (set!
                    (array-ref before-parents (+ (* 3 index) loan))
                    (array-ref memory.parents loan))
                  (set! loan (+ loan 1))))
              (unless
                (step! loans count (&mut memory) trace index)
                (return
                  (Observation
                    before
                    after
                    before-parents
                    after-parents
                    index
                    index)))
              (set! loan 0)
              (while (< loan count)
                (begin
                  (set!
                    (array-ref after (+ (* 3 index) loan))
                    (array-ref memory.tokens loan))
                  (set!
                    (array-ref after-parents (+ (* 3 index) loan))
                    (array-ref memory.parents loan))
                  (set! loan (+ loan 1))))
              (expire! loans count (&mut memory) trace (+ index 1))
              (set! index (+ index 1)))))
        (Observation before after before-parents after-parents index -1)))))

;; Reference values retain a concrete issuance, independently of the static
;; borrow slot. All three holders have the same Copy/MoveOnly reference type.
(defstruct ReferenceValue
  (loan i64)
  (token i64))

(defenum ReferenceEvent
  (Intrinsic Event)
  (Bind i64 i64)
  (Copy i64 i64)
  (Move i64 i64)
  (Clear i64)
  (Use i64))

(defstruct ReferenceProgram
  (copy? bool)
  (events (__tl_dyn-array ReferenceEvent)))

(define (reference-slot? [slot : i64]) : bool
  (and (>= slot 0) (< slot 3)))

(define (reference-program-valid?
  [loans : (& loans (Array Loan 3))]
  [count : i64]
  [program : (& program ReferenceProgram)]) : bool
  (let
    [intrinsics : (__tl_dyn-array Event) (__tl_make-array Event 0)]
    (unless
      (and (>= count 0) (<= count 3) (<= (array-length program.events) 128))
      (return false))
    (for [index (iterator.range 0 (array-length program.events))]
      (unless
        (match (array-ref program.events index)
          [(ReferenceEvent.Intrinsic event)
            (__tl_array-push! intrinsics event)
            true]
          [(ReferenceEvent.Bind holder loan)
            (and
              (reference-slot? holder)
              (>= loan 0)
              (< loan count)
              (= program.copy? (not (array-ref loans loan).exclusive)))]
          [(ReferenceEvent.Copy source destination)
            (and
              program.copy?
              (reference-slot? source)
              (reference-slot? destination))]
          [(ReferenceEvent.Move source destination)
            (and (reference-slot? source) (reference-slot? destination))]
          [(or (ReferenceEvent.Clear holder) (ReferenceEvent.Use holder))
            (reference-slot? holder)])
        (return false)))
    (input-valid? loans count (& intrinsics))))

(define (reference-live?
  [loans : (& loans (Array Loan 3))]
  [count : i64]
  [memory : (& memory Memory)]
  [value : ReferenceValue]) : bool
  (and
    (>= value.loan 0)
    (< value.loan count)
    (> value.token 0)
    (= value.token (array-ref memory.tokens value.loan))
    (live? loans memory value.loan)))

;; Follow values along one concrete suffix, not production holder demands.
;; A new issuance replaces its slot but never a saved reference value. Copy
;; and move read their source before overwriting their destination.
(define (reference-needed-later?
  [loans : (& loans (Array Loan 3))]
  [count : i64]
  [memory : (& memory Memory)]
  [values : (& values (Array ReferenceValue 3))]
  [program : (& program ReferenceProgram)]
  [start : i64]
  [loan : i64]) : bool
  (let
    [token : i64 (array-ref memory.tokens loan)]
    [carriers : (Array bool 3) (array false false false)]
    [holders : (Array bool 3) (array false false false)]
    (when (= token 0) (return false))
    (for [site (iterator.range 0 count)]
      (set!
        (array-ref carriers site)
        (and
          (> (array-ref memory.tokens site) 0)
          (depends-on? loans memory site token))))
    (for [holder (iterator.range 0 3)]
      (let
        [value : ReferenceValue (array-ref values holder)]
        (set!
          (array-ref holders holder)
          (and
            (reference-live? loans count memory value)
            (array-ref carriers value.loan)))))
    (for [index (iterator.range start (array-length program.events))]
      (match (array-ref program.events index)
        [(ReferenceEvent.Intrinsic event)
          (match event
            [(Event.Borrow site) (set! (array-ref carriers site) false)]
            [(Event.Reborrow site)
              (when
                (array-ref carriers (array-ref loans site).parent)
                (return true))
              (set! (array-ref carriers site) false)]
            [(or (Event.Keep site) (Event.MayKeep site)
                 (Event.ReadThrough site _) (Event.WriteThrough site _))
              (when (array-ref carriers site) (return true))]
            [(Event.End site)
              (when (array-ref carriers site) (return true))
              (set! (array-ref carriers site) false)]
            [_ unit])]
        [(ReferenceEvent.Bind holder site)
          (when (array-ref carriers site) (return true))
          (set! (array-ref holders holder) false)]
        [(or (ReferenceEvent.Copy source destination)
             (ReferenceEvent.Move source destination))
          (when (array-ref holders source) (return true))
          (set! (array-ref holders destination) false)]
        [(ReferenceEvent.Clear holder) (set! (array-ref holders holder) false)]
        [(ReferenceEvent.Use holder)
          (when (array-ref holders holder) (return true))]))
    false))

(define (execute-references
  [loans : (& loans (Array Loan 3))]
  [count : i64]
  [program : (& program ReferenceProgram)]
  [left : bool]
  [right : bool]) : Outcome
  (unless
    (reference-program-valid? loans count program)
    (return Outcome.InvalidInput))
  (let
    [memory : Memory (Memory left right (array 0 0 0) (array 0 0 0) 1)]
    [values : (Array ReferenceValue 3)
      (array (ReferenceValue -1 0) (ReferenceValue -1 0) (ReferenceValue -1 0))]
    (for [index (iterator.range 0 (array-length program.events))]
      (let
        [ok? : bool
          (match (array-ref program.events index)
            [(ReferenceEvent.Intrinsic event)
              ;; Reuse the existing concrete primitive transfer. The End
              ;; operation's suffix includes a retained use exactly when a
              ;; future reference value still needs that actual generation.
              (let
                [ending-site : i64
                  (match event
                    [(Event.End site) site]
                    [_ -1])]
                [retained? : bool
                  (and
                    (>= ending-site 0)
                    (reference-needed-later?
                      loans
                      count
                      (& memory)
                      (& values)
                      program
                      (+ index 1)
                      ending-site))]
                [primitive : (__tl_dyn-array Event)
                  (__tl_make-array
                    Event
                    (if retained?
                      2
                      1))]
                (set! (array-ref primitive 0) (clone event))
                (when
                  retained?
                  (set! (array-ref primitive 1) (Event.Keep ending-site)))
                (step! loans count (&mut memory) (& primitive) 0))]
            [(ReferenceEvent.Bind holder site)
              (if (live? loans (& memory) site)
                (begin
                  (set!
                    (array-ref values holder)
                    (ReferenceValue site (array-ref memory.tokens site)))
                  true)
                false)]
            [(or (ReferenceEvent.Copy source destination)
                 (ReferenceEvent.Move source destination))
              (let
                [value : ReferenceValue (array-ref values source)]
                (if (reference-live? loans count (& memory) value)
                  (begin
                    (when
                      (and
                        (not program.copy?)
                        (match (array-ref program.events index)
                          [(ReferenceEvent.Move _ _) true]
                          [_ false]))
                      (set! (array-ref values source) (ReferenceValue -1 0)))
                    (set! (array-ref values destination) value)
                    true)
                  false))]
            [(ReferenceEvent.Clear holder)
              (set! (array-ref values holder) (ReferenceValue -1 0))
              true]
            [(ReferenceEvent.Use holder)
              (reference-live? loans count (& memory) (array-ref values holder))])]
        (unless ok? (return (Outcome.Rejected index))))
      (let
        [needed : (Array bool 3) (array false false false)]
        (for [site (iterator.range 0 count)]
          (set!
            (array-ref needed site)
            (reference-needed-later?
              loans
              count
              (& memory)
              (& values)
              program
              (+ index 1)
              site)))
        (for [site (iterator.range 0 count)]
          (unless
            (array-ref needed site)
            (set! (array-ref memory.tokens site) 0)
            (set! (array-ref memory.parents site) 0)))))
    (Outcome.Accepted memory.left memory.right)))