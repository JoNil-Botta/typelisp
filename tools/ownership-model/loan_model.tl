;; Independent concrete loan semantics over two cells and three loan slots.
;; No production imports, CFG lattice, worklist or abstract transfer rules.
;; Each issued capability gets a fresh dynamic token. Finite traces represent
;; individual executions, including repeated visits to a static borrow site.
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