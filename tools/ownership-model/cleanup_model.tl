;; Independent concrete cleanup executions, derived from SPEC 4.7.1/4.7.2/5.19.
;; Two storage identities each contain two direct cleanup-required fields.
;; Tokens represent resources, not production place IDs or abstract bits.
;; Construction acquires resources before lexical binding activation. Actual
;; activation order determines the stack; the enum names do not imply nesting.
;; There is no compiler import, join, dataflow solver, or production transfer.
(defenum Owner
  (Outer)
  (Inner))

(defenum Field
  (Left)
  (Right))

(defenum Mode
  (Automatic)
  (Discharge))

(defenum Event
  ;; Atomic complete acquisition and lexical activation (BindFresh/BindMove).
  (Initialize Owner)
  (Move Owner Owner)
  ;; A pending construction is a frame, but not an automatic cleanup binding.
  (BeginConstruction Owner)
  (BindComplete Owner)
  (InitializeField Owner Field)
  ;; Reinitialization preserves the existing lexical frame position.
  (Reinitialize Owner)
  (Read Owner)
  (MoveField Owner Field Owner Field)
  (Cleanup Owner)
  (CleanupField Owner Field)
  (Leave Owner)
  (Return Owner)
  ;; All scope-leaving normal edges use this event, including recoverable try.
  (Exit)
  (Abort)
  ;; The right field's cleanup aborts after recording its observable action.
  (AbortCleanup Owner))

(defstruct CleanupAction
  (event i64)
  (owner Owner)
  (field Field)
  (token i64))

(defstruct Memory
  (slots (Array i64 4))
  (partial (Array bool 2))
  ;; 0 absent, 1 pending construction, 2 activated lexical binding.
  (phase (Array i64 2))
  (stack (Array Owner 2))
  (depth i64)
  (next i64)
  (log (__tl_dyn-array i64))
  (actions (__tl_dyn-array CleanupAction))
  (event i64)
  (count i64)
  (exported i64))

(defstruct Report
  (log (__tl_dyn-array i64))
  (actions (__tl_dyn-array CleanupAction))
  (count i64)
  (issued i64)
  (exported i64))

(defenum Outcome
  (Accepted Report)
  (Aborted Report)
  (Rejected i64)
  (InvalidInput))

(define (owner-index [owner : Owner]) : i64
  (match owner
    [(Owner.Outer) 0]
    [(Owner.Inner) 1]))

(define (field-index [field : Field]) : i64
  (match field
    [(Field.Left) 0]
    [(Field.Right) 1]))

(define (slot-index [owner : Owner] [field : Field]) : i64
  (+ (* 2 (owner-index owner)) (field-index field)))

(define (active? [memory : (& memory Memory)] [owner : Owner]) : bool
  (!= (array-ref memory.phase (owner-index owner)) 0))

(define (ready? [memory : (& memory Memory)] [owner : Owner]) : bool
  (let
    [start : i64 (* 2 (owner-index owner))]
    (and
      (> (array-ref memory.slots start) 0)
      (> (array-ref memory.slots (+ start 1)) 0))))

(define (empty? [memory : (& memory Memory)] [owner : Owner]) : bool
  (let
    [start : i64 (* 2 (owner-index owner))]
    (and
      (= (array-ref memory.slots start) 0)
      (= (array-ref memory.slots (+ start 1)) 0))))

(define (automatic? [mode : Mode]) : bool
  (match mode
    [(Mode.Automatic) true]
    [(Mode.Discharge) false]))

(define (top? [memory : (& memory Memory)] [owner : Owner]) : bool
  (and
    (> memory.depth 0)
    (=
      (owner-index (array-ref memory.stack (- memory.depth 1)))
      (owner-index owner))))

(define (push! [memory : (&mut memory Memory)] [owner : Owner] [phase : i64]) : bool
  (if (or
    (active? (& memory) owner)
    (not (empty? (& memory) owner))
    (>= memory.depth 2))
    false
    (begin
      (set! (array-ref memory.stack memory.depth) owner)
      (set! memory.depth (+ memory.depth 1))
      (set! (array-ref memory.phase (owner-index owner)) phase)
      (set! (array-ref memory.partial (owner-index owner)) false)
      true)))

(define (mint! [memory : (&mut memory Memory)] [slot : i64]) : bool
  (if (!= (array-ref memory.slots slot) 0)
    false
    (begin
      (set! (array-ref memory.slots slot) memory.next)
      (set! memory.next (+ memory.next 1))
      true)))

(define (fresh! [memory : (&mut memory Memory)] [owner : Owner]) : bool
  (if (not (empty? (& memory) owner))
    false
    (let
      [start : i64 (* 2 (owner-index owner))]
      (and
        (mint! memory start)
        (mint! memory (+ start 1))
        (begin
          (set! (array-ref memory.partial (owner-index owner)) false)
          true)))))

(define (initialize! [memory : (&mut memory Memory)] [owner : Owner]) : bool
  (and (push! memory owner 2) (fresh! memory owner)))

(define (bind-complete! [memory : (&mut memory Memory)] [owner : Owner]) : bool
  (if (and
    (top? (& memory) owner)
    (= (array-ref memory.phase (owner-index owner)) 1)
    (ready? (& memory) owner))
    (begin
      (set! (array-ref memory.phase (owner-index owner)) 2)
      (set! (array-ref memory.partial (owner-index owner)) false)
      true)
    false))

(define (initialize-field!
  [memory : (&mut memory Memory)]
  [owner : Owner]
  [field : Field]) : bool
  (if (or
    (not (active? (& memory) owner))
    (not (mint! memory (slot-index owner field))))
    false
    (begin
      (set!
        (array-ref memory.partial (owner-index owner))
        (not (ready? (& memory) owner)))
      true)))

(define (move!
  [memory : (&mut memory Memory)]
  [source : Owner]
  [destination : Owner]) : bool
  (if (or
    (not (active? (& memory) source))
    (not (ready? (& memory) source))
    (not (push! memory destination 2)))
    false
    (let
      [from : i64 (* 2 (owner-index source))]
      [into : i64 (* 2 (owner-index destination))]
      (begin
        (set! (array-ref memory.slots into) (array-ref memory.slots from))
        (set!
          (array-ref memory.slots (+ into 1))
          (array-ref memory.slots (+ from 1)))
        (set! (array-ref memory.slots from) 0)
        (set! (array-ref memory.slots (+ from 1)) 0)
        (set! (array-ref memory.partial (owner-index source)) false)
        true))))

(define (move-field!
  [memory : (&mut memory Memory)]
  [source : Owner]
  [source-field : Field]
  [destination : Owner]
  [destination-field : Field]) : bool
  (let
    [from : i64 (slot-index source source-field)]
    [into : i64 (slot-index destination destination-field)]
    (if (or
      (not (active? (& memory) source))
      (not (active? (& memory) destination))
      (= from into)
      (= (array-ref memory.slots from) 0)
      (!= (array-ref memory.slots into) 0))
      false
      (begin
        (set! (array-ref memory.slots into) (array-ref memory.slots from))
        (set! (array-ref memory.slots from) 0)
        (set! (array-ref memory.partial (owner-index source)) true)
        (set!
          (array-ref memory.partial (owner-index destination))
          (not (ready? (& memory) destination)))
        true))))

;; The log is an independent exact-once witness: even an erroneously duplicated
;; token cannot be cleaned twice without a rejection. The parallel action log
;; records the actual event and leaf, so adapters need no second cleanup replay.
;; 128 events mint at most 256 tokens; both logs reserve that bound up front.
(define (clean-field!
  [memory : (&mut memory Memory)]
  [owner : Owner]
  [field : Field]) : bool
  (let
    [slot : i64 (slot-index owner field)]
    [token : i64 (array-ref memory.slots slot)]
    [index : i64 0]
    (begin
      (when
        (or (<= token 0) (>= memory.count (array-length memory.log)))
        (return false))
      (while (< index memory.count)
        (begin
          (when (= (array-ref memory.log index) token) (return false))
          (set! index (+ index 1))))
      (set! (array-ref memory.log memory.count) token)
      (set!
        (array-ref memory.actions memory.count)
        (CleanupAction memory.event owner field token))
      (set! memory.count (+ memory.count 1))
      (set! (array-ref memory.slots slot) 0)
      true)))

(define (cleanup! [memory : (&mut memory Memory)] [owner : Owner]) : bool
  (and
    (active? (& memory) owner)
    (ready? (& memory) owner)
    (clean-field! memory owner Field.Right)
    (clean-field! memory owner Field.Left)
    (begin
      (set! (array-ref memory.partial (owner-index owner)) false)
      true)))

(define (exit-owner!
  [modes : (& modes (Array Mode 2))]
  [memory : (&mut memory Memory)]
  [owner : Owner]) : bool
  (if (= (array-ref memory.phase (owner-index owner)) 1)
    ;; An incomplete initializer has no invented partial automatic destructor.
    ;; Every acquired field must already have been transferred or cleaned.
    (empty? (& memory) owner)
    (if (automatic? (array-ref modes (owner-index owner)))
      ;; With retains its cleanup operand even after a move or explicit cleanup.
      (cleanup! memory owner)
      (and
        (empty? (& memory) owner)
        (not (array-ref memory.partial (owner-index owner)))))))

(define (leave!
  [modes : (& modes (Array Mode 2))]
  [memory : (&mut memory Memory)]
  [owner : Owner]) : bool
  (and
    (top? (& memory) owner)
    (exit-owner! modes memory owner)
    (begin
      (set! memory.depth (- memory.depth 1))
      (set! (array-ref memory.phase (owner-index owner)) 0)
      true)))

(define (exit-all!
  [modes : (& modes (Array Mode 2))]
  [memory : (&mut memory Memory)]) : bool
  (begin
    (while (> memory.depth 0)
      (let
        [owner : Owner (array-ref memory.stack (- memory.depth 1))]
        (unless (leave! modes memory owner) (return false))))
    true))

(define (export!
  [modes : (& modes (Array Mode 2))]
  [memory : (&mut memory Memory)]
  [owner : Owner]) : bool
  (if (or
    (not (active? (& memory) owner))
    (and
      (= (array-ref memory.phase (owner-index owner)) 2)
      (automatic? (array-ref modes (owner-index owner))))
    (not (ready? (& memory) owner)))
    false
    (let
      [start : i64 (* 2 (owner-index owner))]
      (begin
        (set! (array-ref memory.slots start) 0)
        (set! (array-ref memory.slots (+ start 1)) 0)
        (set! (array-ref memory.partial (owner-index owner)) false)
        (set! memory.exported (+ memory.exported 2))
        true))))

(define (report [memory : (& memory Memory)]) : Report
  (let
    [log : (__tl_dyn-array i64) (__tl_make-array i64 memory.count)]
    [actions : (__tl_dyn-array CleanupAction)
      (__tl_make-array CleanupAction memory.count)]
    [index : i64 0]
    (begin
      (while (< index memory.count)
        (begin
          (set! (array-ref log index) (array-ref memory.log index))
          (let
            [action : CleanupAction (array-ref memory.actions index)]
            (set!
              (array-ref actions index)
              (CleanupAction
                action.event
                (match action.owner
                  [(Owner.Outer) Owner.Outer]
                  [(Owner.Inner) Owner.Inner])
                (match action.field
                  [(Field.Left) Field.Left]
                  [(Field.Right) Field.Right])
                action.token)))
          (set! index (+ index 1))))
      (Report log actions memory.count (- memory.next 1) memory.exported))))

(define (execute
  [modes : (& modes (Array Mode 2))]
  [trace : (& trace (__tl_dyn-array Event))]) : Outcome
  (if (or (= (array-length trace) 0) (> (array-length trace) 128))
    Outcome.InvalidInput
    (let
      [memory : Memory
        (Memory
          (array 0 0 0 0)
          (array false false)
          (array 0 0)
          (array Owner.Outer Owner.Outer)
          0
          1
          (__tl_make-array i64 256)
          (__tl_make-array CleanupAction 256)
          0
          0
          0)]
      [index : i64 0]
      (begin
        (while (< index (array-length trace))
          (begin
            (set! memory.event index)
            (let
              [valid : bool
                (match (array-ref trace index)
                  [(Event.Initialize owner) (initialize! (&mut memory) owner)]
                  [(Event.Move source destination)
                    (move! (&mut memory) source destination)]
                  [(Event.BeginConstruction owner)
                    (push! (&mut memory) owner 1)]
                  [(Event.BindComplete owner)
                    (bind-complete! (&mut memory) owner)]
                  [(Event.InitializeField owner field)
                    (initialize-field! (&mut memory) owner field)]
                  [(Event.Reinitialize owner)
                    (and
                      (= (array-ref memory.phase (owner-index owner)) 2)
                      (fresh! (&mut memory) owner))]
                  [(Event.Read owner)
                    (and (active? (& memory) owner) (ready? (& memory) owner))]
                  [(Event.MoveField source field destination into)
                    (move-field! (&mut memory) source field destination into)]
                  [(Event.Cleanup owner) (cleanup! (&mut memory) owner)]
                  [(Event.CleanupField owner field)
                    (and
                      (active? (& memory) owner)
                      (clean-field! (&mut memory) owner field)
                      (begin
                        (set!
                          (array-ref memory.partial (owner-index owner))
                          true)
                        true))]
                  [(Event.Leave owner) (leave! modes (&mut memory) owner)]
                  [(Event.Return owner)
                    (and
                      (export! modes (&mut memory) owner)
                      (exit-all! modes (&mut memory))
                      (return (Outcome.Accepted (report (& memory)))))]
                  [(Event.Exit)
                    (and
                      (exit-all! modes (&mut memory))
                      (return (Outcome.Accepted (report (& memory)))))]
                  [(Event.Abort) (return (Outcome.Aborted (report (& memory))))]
                  [(Event.AbortCleanup owner)
                    (and
                      (active? (& memory) owner)
                      (ready? (& memory) owner)
                      (clean-field! (&mut memory) owner Field.Right)
                      (return (Outcome.Aborted (report (& memory)))))])]
              (unless valid (return (Outcome.Rejected index))))
            (set! index (+ index 1))))
        Outcome.InvalidInput))))