;; Authored loan/initialization graphs. The separate tools/ownership-model
;; oracle does not import these fixtures or the production decision rules.
(import compiler_ownership_core as own)
(import compiler_ownership_core_tests as fixture)
(import compiler_ownership_dump as dump)
(import stdlib.test)
(import stdlib.string)

(define (loan-test-id [index : i64]) : own.OwnershipLoanId
  (own.OwnershipLoanId (fixture.ownership-test-id) index))

(define (loan-test-loan [place : i64] [exclusive? : bool] [parent : i64]) : own.OwnershipLoan
  (own.OwnershipLoan
    (fixture.ownership-test-place-id place)
    (if exclusive?
      own.OwnershipLoanKind.Exclusive
      own.OwnershipLoanKind.Shared)
    (if (< parent 0)
      own.OwnershipLoanOrigin.Direct
      (own.OwnershipLoanOrigin.Parent (loan-test-id parent)))
    (fixture.ownership-test-source 5)))

(define (loan-test-op [kind : i64] [loan : i64] [place : i64]) : own.OwnershipInstruction
  (own.OwnershipInstruction
    (match kind
      [0 (own.OwnershipOperation.Borrow (loan-test-id loan))]
      [1 (own.OwnershipOperation.Reborrow (loan-test-id loan))]
      [2 (own.OwnershipOperation.UseLoan (loan-test-id loan))]
      [3 (own.OwnershipOperation.EndLoan (loan-test-id loan))]
      [4
        (own.OwnershipOperation.AccessThrough
          (loan-test-id loan)
          (fixture.ownership-test-place-id place)
          own.OwnershipAccess.Read)]
      [5
        (own.OwnershipOperation.AccessThrough
          (loan-test-id loan)
          (fixture.ownership-test-place-id place)
          own.OwnershipAccess.Write)]
      [6 (own.OwnershipOperation.Read (fixture.ownership-test-place-id place))]
      [7
        (own.OwnershipOperation.Assign (fixture.ownership-test-place-id place))]
      [8
        (own.OwnershipOperation.Consume (fixture.ownership-test-place-id place))]
      [_
        (own.OwnershipOperation.Invalidate
          (fixture.ownership-test-place-id place))])
    (fixture.ownership-test-source (+ 10 kind))))

(define (loan-test-body
  [loans : (__tl_dyn-array own.OwnershipLoan)]
  [instructions : (__tl_dyn-array own.OwnershipInstruction)]) : own.OwnershipBody
  (let
    [body : own.OwnershipBody
      (fixture.ownership-test-single
        instructions
        (fixture.ownership-test-return))]
    (set! body.loans loans)
    body))

(define (loan-test-result [body : own.OwnershipBody]) : i64
  (match (own.ownership-check (& body) (own.ownership-default-limits))
    [(own.OwnershipResult.Ok) 42]
    [(own.OwnershipResult.Err error)
      (match error.kind
        [(own.OwnershipFailureKind.Loan) 1]
        [(own.OwnershipFailureKind.Structural) 2]
        [(own.OwnershipFailureKind.Resource) 3]
        [(own.OwnershipFailureKind.Uninitialized) 4]
        [(own.OwnershipFailureKind.Cleanup) 6]
        [(own.OwnershipFailureKind.Unsupported) 5])]))

(define (loan-test-one [mode : i64]) : own.OwnershipBody
  (loan-test-body
    (__tl_make-array
      (loan-test-loan
        (if (= mode 8)
          5
          3)
        (!= mode 0)
        -1))
    (match mode
      [0
        (__tl_make-array
          (loan-test-op 0 0 0)
          (loan-test-op 6 0 3)
          (loan-test-op 4 0 3))]
      [1
        (__tl_make-array
          (loan-test-op 0 0 0)
          (loan-test-op 6 0 3)
          (loan-test-op 2 0 0))]
      [2
        (__tl_make-array
          (loan-test-op 0 0 0)
          (loan-test-op 7 0 4)
          (loan-test-op 5 0 3))]
      [3
        (__tl_make-array
          (loan-test-op 0 0 0)
          (loan-test-op 5 0 3)
          (loan-test-op 7 0 3))]
      [4
        (__tl_make-array
          (loan-test-op 0 0 0)
          (loan-test-op 3 0 0)
          (loan-test-op 7 0 3))]
      [5
        (__tl_make-array
          (loan-test-op 0 0 0)
          (loan-test-op 3 0 0)
          (loan-test-op 2 0 0))]
      [6 (__tl_make-array (loan-test-op 2 0 0) (loan-test-op 0 0 0))]
      [7 (__tl_make-array (loan-test-op 0 0 0) (loan-test-op 4 0 4))]
      [8 (__tl_make-array (loan-test-op 0 0 0) (loan-test-op 2 0 0))]
      [9
        (__tl_make-array
          (loan-test-op 0 0 0)
          (loan-test-op 8 0 3)
          (loan-test-op 2 0 0))]
      [_
        (__tl_make-array
          (loan-test-op 0 0 0)
          (loan-test-op 9 0 0)
          (loan-test-op 2 0 0))])))

(define (loan-test-reborrow [mode : i64]) : own.OwnershipBody
  (let
    [loans : (__tl_dyn-array own.OwnershipLoan)
      (__tl_make-array own.OwnershipLoan 2)]
    (set!
      (array-ref loans 0)
      (loan-test-loan 0 (not (or (= mode 5) (= mode 8))) -1))
    (set! (array-ref loans 1) (loan-test-loan 3 (or (= mode 4) (= mode 8)) 0))
    (loan-test-body
      loans
      (match mode
        [0
          (__tl_make-array
            (loan-test-op 0 0 0)
            (loan-test-op 1 1 0)
            (loan-test-op 4 0 3)
            (loan-test-op 4 1 3))]
        [1
          (__tl_make-array
            (loan-test-op 0 0 0)
            (loan-test-op 1 1 0)
            (loan-test-op 5 0 3)
            (loan-test-op 4 1 3))]
        [2
          (__tl_make-array
            (loan-test-op 0 0 0)
            (loan-test-op 1 1 0)
            (loan-test-op 5 0 4)
            (loan-test-op 4 1 3))]
        [3
          (__tl_make-array
            (loan-test-op 0 0 0)
            (loan-test-op 1 1 0)
            (loan-test-op 3 0 0)
            (loan-test-op 4 1 3))]
        [4
          (__tl_make-array
            (loan-test-op 0 0 0)
            (loan-test-op 1 1 0)
            (loan-test-op 4 0 3)
            (loan-test-op 4 1 3))]
        [5
          (__tl_make-array
            (loan-test-op 0 0 0)
            (loan-test-op 1 1 0)
            (loan-test-op 5 1 3))]
        [6
          (__tl_make-array
            (loan-test-op 0 0 0)
            (loan-test-op 1 1 0)
            (loan-test-op 3 1 0)
            (loan-test-op 3 0 0)
            (loan-test-op 7 0 0))]
        [8
          (__tl_make-array
            (loan-test-op 0 0 0)
            (loan-test-op 1 1 0)
            (loan-test-op 4 1 3))]
        [9
          (__tl_make-array
            (loan-test-op 0 0 0)
            (loan-test-op 1 1 0)
            (loan-test-op 3 1 0)
            (loan-test-op 4 1 3))]
        [_
          (__tl_make-array
            (loan-test-op 0 0 0)
            (loan-test-op 1 1 0)
            (loan-test-op 4 1 3)
            (loan-test-op 5 0 3))]))))

(define (compiler-ownership-loan-transfer-self-test) : i64
  (let
    [i : i64 0]
    (while (< i 11)
      (let
        [expected : i64
          (match i
            [0 42]
            [2 42]
            [3 42]
            [4 42]
            [7 2]
            [8 4]
            [_ 1])]
        (unless
          (= (loan-test-result (loan-test-one i)) expected)
          (return (+ 100 i)))
        (set! i (+ i 1))))
    (set! i 0)
    (while (< i 10)
      (let
        [expected : i64
          (match i
            [0 42]
            [2 42]
            [6 42]
            [7 42]
            [5 2]
            [8 2]
            [_ 1])]
        (unless
          (= (loan-test-result (loan-test-reborrow i)) expected)
          (return (+ 200 i)))
        (set! i (+ i 1))))
    42))

(define (loan-test-cfg [mode : i64]) : own.OwnershipBody
  (let
    [blocks : (__tl_dyn-array own.OwnershipBlock)
      (__tl_make-array own.OwnershipBlock 4)]
    [body : own.OwnershipBody (fixture.ownership-test-body blocks)]
    (set! body.loans (__tl_make-array (loan-test-loan 3 true -1)))
    (set!
      (array-ref body.blocks 0)
      (fixture.ownership-test-block
        (if (or (= mode 0) (= mode 1))
          (__tl_make-array own.OwnershipInstruction 0)
          (__tl_make-array (loan-test-op 0 0 0)))
        (own.OwnershipTerminator.Branch
          (fixture.ownership-test-place-id 6)
          (fixture.ownership-test-block-id 1)
          (fixture.ownership-test-block-id 2))))
    (set!
      (array-ref body.blocks 1)
      (fixture.ownership-test-block
        (cond
          [(= mode 0) (__tl_make-array (loan-test-op 0 0 0))]
          [(= mode 1)
            (__tl_make-array
              (loan-test-op 0 0 0)
              (loan-test-op 4 0 3)
              (loan-test-op 3 0 0))]
          [(= mode 4) (__tl_make-array (loan-test-op 3 0 0))]
          [else (__tl_make-array (loan-test-op 4 0 3))])
        (if (= mode 1)
          (own.OwnershipTerminator.Branch
            (fixture.ownership-test-place-id 6)
            (fixture.ownership-test-block-id 1)
            (fixture.ownership-test-block-id 3))
          (own.OwnershipTerminator.Goto (fixture.ownership-test-block-id 3)))))
    (set!
      (array-ref body.blocks 2)
      (fixture.ownership-test-block
        (if (= mode 2)
          (__tl_make-array (loan-test-op 7 0 3))
          (__tl_make-array own.OwnershipInstruction 0))
        (own.OwnershipTerminator.Goto (fixture.ownership-test-block-id 3))))
    (set!
      (array-ref body.blocks 3)
      (fixture.ownership-test-block
        (if (or (= mode 0) (= mode 4))
          (__tl_make-array (loan-test-op 2 0 0))
          (__tl_make-array (loan-test-op 7 0 3)))
        (fixture.ownership-test-return)))
    body))

(define (compiler-ownership-loan-cfg-self-test) : i64
  (let
    [i : i64 0]
    (while (< i 5)
      (unless
        (=
          (loan-test-result (loan-test-cfg i))
          (if (or (= i 0) (= i 4))
            1
            42))
        (return (+ 300 i)))
      (set! i (+ i 1)))
    42))

(define (loan-test-malformed [mode : i64]) : own.OwnershipBody
  (let
    [body : own.OwnershipBody (loan-test-reborrow 0)]
    (cond
      [(= mode 0)
        (let
          [stale : own.OwnershipLoanId (loan-test-id 0)]
          (set! stale.body.generation (cast 99 : u64))
          (set!
            (array-ref (array-ref body.blocks 0).instructions 0).operation
            (own.OwnershipOperation.Borrow stale)))]
      [(= mode 1)
        (let
          [stale : own.OwnershipLoanId (loan-test-id 0)]
          (set! stale.body.owner (cast 99 : u64))
          (set!
            (array-ref body.loans 1).origin
            (own.OwnershipLoanOrigin.Parent stale)))]
      [(= mode 2)
        (set!
          (array-ref body.loans 1).origin
          (own.OwnershipLoanOrigin.Parent (loan-test-id 1)))]
      [(= mode 3)
        (set!
          (array-ref body.loans 1).place
          (fixture.ownership-test-place-id 5))]
      [(= mode 4)
        (set!
          (array-ref (array-ref body.blocks 0).instructions 2)
          (loan-test-op 0 0 0))]
      [(= mode 5)
        (set!
          (array-ref (array-ref body.blocks 0).instructions 0)
          (loan-test-op 2 0 0))]
      [else
        (set!
          (array-ref body.loans 1).place
          (fixture.ownership-test-place-id 99))])
    body))

(define (loan-test-resource?
  [body : own.OwnershipBody]
  [limits : own.OwnershipLimits]) : bool
  (match (own.ownership-check (& body) limits)
    [(own.OwnershipResult.Err failure)
      (match failure.kind
        [(own.OwnershipFailureKind.Resource) true]
        [_ false])]
    [(own.OwnershipResult.Ok) false]))

(define (compiler-ownership-loan-structure-self-test) : i64
  (let
    [i : i64 0]
    (while (< i 7)
      (unless
        (= (loan-test-result (loan-test-malformed i)) 2)
        (return (+ 400 i)))
      (set! i (+ i 1)))
    (let
      [mode : i64 0]
      (while (< mode 4)
        (let
          [body : own.OwnershipBody (loan-test-reborrow 0)]
          [bad : own.OwnershipLoanId
            (loan-test-id
              (if (= mode 0)
                0
                -1))]
          [at : i64
            (if (= mode 3)
              1
              0)]
          (when
            (or (= mode 0) (= mode 2))
            (set! bad.body.owner (cast 999 : u64)))
          (set!
            (array-ref (array-ref body.blocks 0).instructions at).operation
            (if (= mode 3)
              (own.OwnershipOperation.Reborrow bad)
              (own.OwnershipOperation.Borrow bad)))
          (match (own.ownership-check (& body) (own.ownership-default-limits))
            [(own.OwnershipResult.Ok) (return (+ 420 mode))]
            [(own.OwnershipResult.Err error)
              (unless
                (and
                  (match error.kind
                    [(own.OwnershipFailureKind.Structural) true]
                    [_ false])
                  (= error.block 0)
                  (= error.instruction at)
                  (string.eq error.message "invalid loan definition identity"))
                (return (+ 424 mode)))])
          (set! mode (+ mode 1)))))
    (unless
      (loan-test-resource?
        (loan-test-reborrow 0)
        (own.OwnershipLimits 65536 20 67108864))
      (return 410))
    (unless
      (loan-test-resource?
        (loan-test-reborrow 0)
        (own.OwnershipLimits 4 16777216 67108864))
      (return 411))
    (let
      [body : own.OwnershipBody (loan-test-reborrow 0)]
      (match (own.ownership-loan-liveness
        (& body)
        (own.OwnershipLimits 65536 16777216 1))
        [(own.OwnershipLoanLivenessResult.Ok _) (return 412)]
        [(own.OwnershipLoanLivenessResult.Err failure)
          (match failure.kind
            [(own.OwnershipFailureKind.Resource) unit]
            [_ (return 413)])]))
    (let
      [body : own.OwnershipBody (loan-test-reborrow 6)]
      (match (dump.ownership-dump (& body) (own.ownership-default-limits))
        [(dump.OwnershipDumpResult.Err _) (return 414)]
        [(dump.OwnershipDumpResult.Ok text)
          (unless
            (and
              (string.contains text "%loan0 = exclusive %p0 direct")
              (string.contains text "%loan1 = shared %p3 parent %loan0")
              (string.contains text "end %loan1"))
            (return 415))]))
    (let
      [body : own.OwnershipBody (loan-test-reborrow 1)]
      (match (own.ownership-check (& body) (own.ownership-default-limits))
        [(own.OwnershipResult.Ok) (return 416)]
        [(own.OwnershipResult.Err failure)
          (unless
            (and
              (= failure.loan 0)
              (= failure.conflicting-loan 1)
              (= failure.block 0)
              (= failure.instruction 2)
              (= failure.place 3)
              (= failure.source.line 15))
            (return 417))]))
    42))

(define (compiler-ownership-loan-self-test) : i64
  (let
    [result : i64 (compiler-ownership-loan-transfer-self-test)]
    (unless (= result 42) (return result)))
  (let
    [result : i64 (compiler-ownership-loan-cfg-self-test)]
    (unless (= result 42) (return result)))
  (let
    [result : i64 (compiler-ownership-loan-structure-self-test)]
    (unless (= result 42) (return result)))
  (let
    [result : i64 (compiler-ownership-loan-frontier-self-test)]
    (unless (= result 42) (return result)))
  (let
    [result : i64 (compiler-ownership-loan-mixed-self-test)]
    (unless (= result 42) (return result)))
  (let
    [result : i64 (compiler-ownership-loan-review-self-test)]
    (unless (= result 42) (return result)))
  (compiler-ownership-loan-observation-self-test))

(test
  ownership-loan-transfer
  (test.assert-i64-eq
    (compiler-ownership-loan-transfer-self-test)
    42
    "loan transfers"))

(test
  ownership-loan-cfg
  (test.assert-i64-eq (compiler-ownership-loan-cfg-self-test) 42 "loan CFG"))

(test
  ownership-loan-structure
  (test.assert-i64-eq
    (compiler-ownership-loan-structure-self-test)
    42
    "loan structure and limits"))

;; Direct/sibling conflicts and transitive grant chains are independent of the
;; original one-parent/one-child model fixtures.
(define (loan-test-frontier [mode : i64]) : own.OwnershipBody
  (cond
    [(or (= mode 0) (= mode 1))
      (loan-test-body
        (__tl_make-array
          (loan-test-loan 0 true -1)
          (loan-test-loan 3 true 0)
          (loan-test-loan 3 true 0))
        (if (= mode 0)
          (__tl_make-array
            (loan-test-op 0 0 0)
            (loan-test-op 1 1 0)
            (loan-test-op 1 2 0)
            (loan-test-op 2 1 0))
          (__tl_make-array
            (loan-test-op 0 0 0)
            (loan-test-op 1 1 0)
            (loan-test-op 1 2 0))))]
    [(or (= mode 2) (= mode 3))
      (loan-test-body
        (__tl_make-array
          (loan-test-loan 0 false -1)
          (loan-test-loan 3 (= mode 2) -1))
        (__tl_make-array
          (loan-test-op 0 0 0)
          (loan-test-op 0 1 0)
          (loan-test-op 2 0 0)))]
    [else
      (loan-test-body
        (__tl_make-array
          (loan-test-loan 0 true -1)
          (loan-test-loan 3 true 0)
          (loan-test-loan 3 (= mode 5) 1))
        (if (= mode 4)
          (__tl_make-array
            (loan-test-op 0 0 0)
            (loan-test-op 1 1 0)
            (loan-test-op 1 2 0)
            (loan-test-op 7 0 4)
            (loan-test-op 2 2 0))
          (__tl_make-array
            (loan-test-op 0 0 0)
            (loan-test-op 1 1 0)
            (loan-test-op 1 2 0)
            (loan-test-op 5 2 3)
            (loan-test-op 2 1 0))))]))

(define (loan-test-conflict?
  [body : own.OwnershipBody]
  [block : i64]
  [instruction : i64]
  [place : i64]
  [loan : i64]
  [conflicting : i64]) : bool
  (match (own.ownership-check (& body) (own.ownership-default-limits))
    [(own.OwnershipResult.Err failure)
      (and
        (match (& failure.kind)
          [(own.OwnershipFailureKind.Loan) true]
          [_ false])
        (= failure.block block)
        (= failure.instruction instruction)
        (= failure.place place)
        (= failure.loan loan)
        (= failure.conflicting-loan conflicting))]
    [_ false]))

(define (compiler-ownership-loan-frontier-self-test) : i64
  (cond
    [(not (loan-test-conflict? (loan-test-frontier 0) 0 2 3 2 1)) 500]
    [(!= (loan-test-result (loan-test-frontier 1)) 42) 501]
    [(not (loan-test-conflict? (loan-test-frontier 2) 0 1 3 1 0)) 502]
    [(!= (loan-test-result (loan-test-frontier 3)) 42) 503]
    [(not (loan-test-conflict? (loan-test-frontier 4) 0 3 4 -1 0)) 504]
    [(!= (loan-test-result (loan-test-frontier 5)) 42) 505]
    [else 42]))

(define (loan-test-copy-move [mode : i64]) : own.OwnershipBody
  (let
    [place : i64
      (if (= mode 4)
        6
        3)]
    [instruction : own.OwnershipInstruction
      (own.OwnershipInstruction
        (cond
          [(= mode 0)
            (own.OwnershipOperation.Move
              (fixture.ownership-test-place-id 3)
              (fixture.ownership-test-place-id 5))]
          [(= mode 1)
            (own.OwnershipOperation.Copy
              (fixture.ownership-test-place-id 4)
              (fixture.ownership-test-place-id 3))]
          [(= mode 2)
            (own.OwnershipOperation.Copy
              (fixture.ownership-test-place-id 3)
              (fixture.ownership-test-place-id 5))]
          [(= mode 3)
            (own.OwnershipOperation.Move
              (fixture.ownership-test-place-id 3)
              (fixture.ownership-test-place-id 5))]
          [else
            (own.OwnershipOperation.Consume (fixture.ownership-test-place-id 6))])
        (fixture.ownership-test-source 20))]
    [body : own.OwnershipBody
      (loan-test-body
        (__tl_make-array (loan-test-loan place false -1))
        (__tl_make-array (loan-test-op 0 0 0) instruction (loan-test-op 2 0 0)))]
    (when
      (and (> mode 0) (< mode 4))
      (set! (array-ref body.types 0).copy? true))
    body))

(define (loan-test-branch-conflict) : own.OwnershipBody
  (let
    [blocks : (__tl_dyn-array own.OwnershipBlock)
      (__tl_make-array
        (fixture.ownership-test-block
          (__tl_make-array (loan-test-op 0 0 0))
          (own.OwnershipTerminator.Branch
            (fixture.ownership-test-place-id 6)
            (fixture.ownership-test-block-id 1)
            (fixture.ownership-test-block-id 2)))
        (fixture.ownership-test-block
          (__tl_make-array (loan-test-op 2 0 0))
          (fixture.ownership-test-return))
        (fixture.ownership-test-block
          (__tl_make-array own.OwnershipInstruction 0)
          (fixture.ownership-test-return)))]
    [body : own.OwnershipBody (fixture.ownership-test-body blocks)]
    (set! body.loans (__tl_make-array (loan-test-loan 6 true -1)))
    body))

(define (loan-test-end-backedge) : own.OwnershipBody
  (let
    [blocks : (__tl_dyn-array own.OwnershipBlock)
      (__tl_make-array
        (fixture.ownership-test-block
          (__tl_make-array (loan-test-op 0 0 0))
          (own.OwnershipTerminator.Goto (fixture.ownership-test-block-id 1)))
        (fixture.ownership-test-block
          (__tl_make-array own.OwnershipInstruction 0)
          (own.OwnershipTerminator.Branch
            (fixture.ownership-test-place-id 6)
            (fixture.ownership-test-block-id 2)
            (fixture.ownership-test-block-id 3)))
        (fixture.ownership-test-block
          (__tl_make-array (loan-test-op 2 0 0) (loan-test-op 3 0 0))
          (own.OwnershipTerminator.Goto (fixture.ownership-test-block-id 1)))
        (fixture.ownership-test-block
          (__tl_make-array own.OwnershipInstruction 0)
          (fixture.ownership-test-return)))]
    [body : own.OwnershipBody (fixture.ownership-test-body blocks)]
    (set! body.loans (__tl_make-array (loan-test-loan 3 false -1)))
    body))

(define (compiler-ownership-loan-mixed-self-test) : i64
  (cond
    [(not (loan-test-conflict? (loan-test-copy-move 0) 0 1 3 -1 0)) 520]
    [(not (loan-test-conflict? (loan-test-copy-move 1) 0 1 3 -1 0)) 521]
    [(!= (loan-test-result (loan-test-copy-move 2)) 42) 522]
    [(!= (loan-test-result (loan-test-copy-move 3)) 42) 523]
    [(!= (loan-test-result (loan-test-copy-move 4)) 42) 524]
    [(not (loan-test-conflict? (loan-test-branch-conflict) 0 1 6 -1 0)) 525]
    [(not (loan-test-conflict? (loan-test-end-backedge) 2 1 3 0 -1)) 526]
    [else 42]))

;; A zero-iteration path also rejects C's use, so checking only the overall
;; failure could mask loss of P's retained authority across its definition.
(define (loan-test-parent-reissue [end? : bool]) : own.OwnershipBody
  (let
    [blocks : (__tl_dyn-array own.OwnershipBlock)
      (__tl_make-array
        (fixture.ownership-test-block
          (__tl_make-array own.OwnershipInstruction 0)
          (own.OwnershipTerminator.Goto (fixture.ownership-test-block-id 1)))
        (fixture.ownership-test-block
          (__tl_make-array (loan-test-op 0 0 0))
          (own.OwnershipTerminator.Branch
            (fixture.ownership-test-place-id 6)
            (fixture.ownership-test-block-id 2)
            (fixture.ownership-test-block-id 3)))
        (fixture.ownership-test-block
          (if end?
            (__tl_make-array (loan-test-op 1 1 0) (loan-test-op 3 0 0))
            (__tl_make-array (loan-test-op 1 1 0)))
          (own.OwnershipTerminator.Goto (fixture.ownership-test-block-id 1)))
        (fixture.ownership-test-block
          (__tl_make-array (loan-test-op 2 1 0))
          (fixture.ownership-test-return)))]
    [body : own.OwnershipBody (fixture.ownership-test-body blocks)]
    (set!
      body.loans
      (__tl_make-array (loan-test-loan 0 false -1) (loan-test-loan 3 false 0)))
    body))

(define (loan-test-parent-live? [end? : bool]) : bool
  (let
    [body : own.OwnershipBody (loan-test-parent-reissue end?)]
    (match (own.ownership-validate (& body) (own.ownership-default-limits))
      [(own.OwnershipResult.Err _) false]
      [(own.OwnershipResult.Ok)
        (match (own.ownership-loan-liveness
          (& body)
          (own.ownership-default-limits))
          [(own.OwnershipLoanLivenessResult.Err _) false]
          [(own.OwnershipLoanLivenessResult.Ok live)
            (let
              [point : i64 (array-ref live.offsets 1)]
              (and
                (own.ownership-loan-live? (& live) point 0)
                (own.ownership-loan-live? (& live) point 1)))])])))

(define (loan-test-dead-malformed [exclusive-child? : bool]) : own.OwnershipBody
  (let
    [blocks : (__tl_dyn-array own.OwnershipBlock)
      (__tl_make-array
        (fixture.ownership-test-block
          (__tl_make-array own.OwnershipInstruction 0)
          (fixture.ownership-test-return))
        (fixture.ownership-test-block
          (if exclusive-child?
            (__tl_make-array (loan-test-op 0 0 0) (loan-test-op 1 1 0))
            (__tl_make-array (loan-test-op 0 0 0) (loan-test-op 5 0 3)))
          (fixture.ownership-test-return)))]
    [body : own.OwnershipBody (fixture.ownership-test-body blocks)]
    (set!
      body.loans
      (if exclusive-child?
        (__tl_make-array (loan-test-loan 0 false -1) (loan-test-loan 3 true 0))
        (__tl_make-array (loan-test-loan 3 false -1))))
    body))

(define (loan-test-scale-body) : own.OwnershipBody
  (let
    [types : (__tl_dyn-array own.OwnershipType)
      (__tl_make-array (own.OwnershipType own.OwnershipTypeKind.Scalar false))]
    [locals : (__tl_dyn-array own.OwnershipLocal)
      (__tl_make-array own.OwnershipLocal 300)]
    [places : (__tl_dyn-array own.OwnershipPlace)
      (__tl_make-array own.OwnershipPlace 300)]
    [loans : (__tl_dyn-array own.OwnershipLoan)
      (__tl_make-array own.OwnershipLoan 50)]
    [instructions : (__tl_dyn-array own.OwnershipInstruction)
      (__tl_make-array own.OwnershipInstruction 1000)]
    [index : i64 0]
    (while (< index 300)
      (set!
        (array-ref locals index)
        (own.OwnershipLocal
          (fixture.ownership-test-type-id 0)
          true
          (fixture.ownership-test-source 2)))
      (set!
        (array-ref places index)
        (own.OwnershipPlace
          (own.OwnershipLocalId (fixture.ownership-test-id) index)
          (fixture.ownership-test-type-id 0)
          own.OwnershipProjection.Root
          (fixture.ownership-test-source 3)))
      (set! index (+ index 1)))
    (set! index 0)
    (while (< index 50)
      (set! (array-ref loans index) (loan-test-loan index false -1))
      (set! (array-ref instructions (* index 2)) (loan-test-op 0 index 0))
      (set! (array-ref instructions (+ (* index 2) 1)) (loan-test-op 2 index 0))
      (set! index (+ index 1)))
    (while (< (* index 2) 1000)
      (set! (array-ref instructions (* index 2)) (loan-test-op 6 0 0))
      (set! (array-ref instructions (+ (* index 2) 1)) (loan-test-op 6 0 0))
      (set! index (+ index 1)))
    (own.OwnershipBody
      (fixture.ownership-test-id)
      types
      locals
      places
      loans
      (__tl_make-array own.OwnershipCleanup 0)
      (__tl_make-array own.OwnershipObligation 0)
      (__tl_make-array
        (fixture.ownership-test-block
          instructions
          (fixture.ownership-test-return)))
      (fixture.ownership-test-block-id 0))))

(define (loan-test-resource-message?
  [body : own.OwnershipBody]
  [limits : own.OwnershipLimits]
  [message : String]) : bool
  (match (own.ownership-check (& body) limits)
    [(own.OwnershipResult.Err failure)
      (and
        (match (& failure.kind)
          [(own.OwnershipFailureKind.Resource) true]
          [_ false])
        (string.eq failure.message message))]
    [_ false]))

(define (compiler-ownership-loan-review-self-test) : i64
  (unless (loan-test-parent-live? false) (return 540))
  (unless (loan-test-parent-live? true) (return 541))
  (unless
    (= (loan-test-result (loan-test-dead-malformed false)) 2)
    (return 542))
  (unless (= (loan-test-result (loan-test-dead-malformed true)) 2) (return 543))
  (unless
    (loan-test-resource-message?
      (loan-test-reborrow 0)
      (own.OwnershipLimits 65536 40 67108864)
      "ownership loan state budget exhausted")
    (return 544))
  (let
    [body : own.OwnershipBody (loan-test-reborrow 0)]
    (match (own.ownership-check
      (& body)
      (own.OwnershipLimits 65536 48 67108864))
      [(own.OwnershipResult.Err _) (return 545)]
      [_ unit]))
  (let
    [body : own.OwnershipBody (loan-test-one 0)]
    (set!
      (array-ref body.blocks 0).instructions
      (__tl_make-array
        (loan-test-op 0 0 0)
        (loan-test-op 2 0 0)
        (loan-test-op 6 0 3)
        (loan-test-op 6 0 3)
        (loan-test-op 6 0 3)
        (loan-test-op 6 0 3)
        (loan-test-op 6 0 3)))
    (unless
      (loan-test-resource-message?
        body
        (own.OwnershipLimits 7 16777216 67108864)
        "ownership loan point budget exhausted")
      (return 546)))
  (unless (= (loan-test-result (loan-test-scale-body)) 42) (return 547))
  42)

(test
  ownership-loan-frontiers
  (test.assert-i64-eq
    (compiler-ownership-loan-frontier-self-test)
    42
    "loan direct/sibling/transitive frontiers"))

(test
  ownership-loan-mixed-operations
  (test.assert-i64-eq
    (compiler-ownership-loan-mixed-self-test)
    42
    "loan Copy/Move/Consume/Branch/backedge"))

(test
  ownership-loan-review-regressions
  (test.assert-i64-eq
    (compiler-ownership-loan-review-self-test)
    42
    "loan liveness/structural/budget/scaling"))

(define (loan-test-observation? [mode : i64] [error-at : i64]) : bool
  (let
    [body : own.OwnershipBody (loan-test-one mode)]
    [out : own.OwnershipInspection
      (own.ownership-inspect (& body) (own.ownership-default-limits))]
    (and
      out.observation.complete?
      (= (array-length out.observation.offsets) 2)
      (= (array-ref out.observation.offsets 0) 0)
      (= (array-ref out.observation.offsets 1) 4)
      (= (array-length out.observation.before-expiry) 4)
      (= (array-length out.observation.before) 4)
      (= (array-length out.observation.after) 4)
      (= (array-length out.observation.live) 4)
      (= (array-length out.observation.failure-kinds) 4)
      (= (array-ref out.observation.failure-kinds 0) 0)
      (=
        (array-ref out.observation.failure-kinds 1)
        (if (= mode 0)
          0
          2))
      (=
        (array-ref out.observation.failure-kinds 2)
        (if (= mode 5)
          2
          0))
      (= (array-ref out.observation.before 0) 1)
      (= (array-ref out.observation.after 0) 2)
      (match (& out.result)
        [(own.OwnershipResult.Ok) (= error-at -1)]
        [(own.OwnershipResult.Err error)
          (and
            (= error.block 0)
            (= error.instruction error-at)
            (match error.kind
              [(own.OwnershipFailureKind.Loan) true]
              [_ false]))]))))

(define (compiler-ownership-loan-observation-self-test) : i64
  (unless (loan-test-observation? 0 -1) (return 560))
  (unless (loan-test-observation? 1 1) (return 561))
  ;; A later UseLoan also fails after EndLoan. Inspection must retain the
  ;; first failure while recording the syntactic continuation, never admit it.
  (unless (loan-test-observation? 5 1) (return 562))
  (let
    [body : own.OwnershipBody (loan-test-one 0)]
    (match (own.ownership-check
      (& body)
      (own.OwnershipLimits 65536 38 67108864))
      [(own.OwnershipResult.Err _) (return 563)]
      [_ unit]))
  (let
    [body : own.OwnershipBody (loan-test-one 0)]
    [out : own.OwnershipInspection
      (own.ownership-inspect (& body) (own.OwnershipLimits 65536 59 67108864))]
    (when out.observation.complete? (return 564))
    (match (& out.result)
      [(own.OwnershipResult.Ok) (return 565)]
      [(own.OwnershipResult.Err error)
        (unless
          (and
            (match error.kind
              [(own.OwnershipFailureKind.Resource) true]
              [_ false])
            (string.eq error.message "ownership observation budget exhausted"))
          (return 566))]))
  (let
    [body : own.OwnershipBody (loan-test-one 0)]
    [out : own.OwnershipInspection
      (own.ownership-inspect (& body) (own.OwnershipLimits 65536 60 67108864))]
    (unless out.observation.complete? (return 567))
    (match (& out.result)
      [(own.OwnershipResult.Err _) (return 568)]
      [_ unit]))
  42)

(test
  ownership-loan-observation
  (test.assert-i64-eq
    (compiler-ownership-loan-observation-self-test)
    42
    "loan observation retains errors and reserves owned rows"))

;; A Copy or Move into a holder root ends the demands of reads through it
;; (`ownership-live-kill-holder!`). Root p7 is a second scalar local beside p5.
;; Mode 0: p7 is read (its MayUseLoan run names %loan0) and moved into p5,
;; p1 is written, then p5 is read: the loan crosses the move and the write
;; conflicts. (%loan1 is borrowed only so every loan has its definition.) Mode 1: p7 carries only %loan1; %loan0's referent is written
;; before p5 is overwritten, so %loan0 is dead there although p5's later read
;; may carry it. Mode 2 is mode 1 without p7's MayUseLoan run, as in a Move
;; synthesized by cleanup elaboration: the transfer's loans are unknown and
;; every demand continues.
(define (loan-test-may-use [loan : i64] [holder : i64]) : own.OwnershipInstruction
  (own.OwnershipInstruction
    (own.OwnershipOperation.MayUseLoan
      (loan-test-id loan)
      (fixture.ownership-test-place-id holder))
    (fixture.ownership-test-source 30)))

(define (loan-test-move [source : i64] [dest : i64]) : own.OwnershipInstruction
  (own.OwnershipInstruction
    (own.OwnershipOperation.Move
      (fixture.ownership-test-place-id source)
      (fixture.ownership-test-place-id dest))
    (fixture.ownership-test-source 31)))

(define (loan-test-holder-body [mode : i64]) : own.OwnershipBody
  (let
    [instructions : (__tl_dyn-array own.OwnershipInstruction)
      (if (= mode 0)
        (__tl_make-array
          (loan-test-op 7 0 7)
          (loan-test-op 0 0 0)
          (loan-test-op 0 1 0)
          (loan-test-may-use 0 7)
          (loan-test-move 7 5)
          (loan-test-op 7 0 1)
          (loan-test-may-use 0 5))
        (if (= mode 1)
          (__tl_make-array
            (loan-test-op 0 0 0)
            (loan-test-op 7 0 7)
            (loan-test-op 0 1 0)
            (loan-test-op 7 0 1)
            (loan-test-may-use 1 7)
            (loan-test-move 7 5)
            (loan-test-may-use 0 5)
            (loan-test-may-use 1 5))
          (__tl_make-array
            (loan-test-op 0 0 0)
            (loan-test-op 7 0 7)
            (loan-test-op 0 1 0)
            (loan-test-op 7 0 1)
            (loan-test-move 7 5)
            (loan-test-may-use 0 5)
            (loan-test-may-use 1 5))))]
    [body : own.OwnershipBody
      (loan-test-body
        (__tl_make-array
          (loan-test-loan 1 false -1)
          (loan-test-loan 3 false -1))
        instructions)]
    (set!
      body.locals
      (__tl_make-array
        (fixture.ownership-test-local 3 true)
        (fixture.ownership-test-local 0 false)
        (fixture.ownership-test-local 1 true)
        (fixture.ownership-test-local 0 false)))
    (set!
      body.places
      (__tl_make-array
        (fixture.ownership-test-place 0 3 -1 0)
        (fixture.ownership-test-place 0 0 0 0)
        (fixture.ownership-test-place 0 2 0 1)
        (fixture.ownership-test-place 0 0 2 0)
        (fixture.ownership-test-place 0 0 2 1)
        (fixture.ownership-test-place 1 0 -1 0)
        (fixture.ownership-test-place 2 1 -1 0)
        (fixture.ownership-test-place 3 0 -1 0)))
    body))

;; Whether %loan0 is demanded before the write of p1 (instruction 3).
(define (loan-test-holder-live-at-write? [mode : i64]) : i64
  (let
    [body : own.OwnershipBody (loan-test-holder-body mode)]
    (match (own.ownership-loan-liveness (& body) (own.ownership-default-limits))
      [(own.OwnershipLoanLivenessResult.Err _) -1]
      [(own.OwnershipLoanLivenessResult.Ok liveness)
        (if (own.ownership-loan-live? (& liveness) 3 0)
          1
          0)])))

(define (compiler-ownership-loan-holder-self-test) : i64
  (cond
    [(!= (loan-test-result (loan-test-holder-body 0)) 1) 601]
    [(!= (loan-test-result (loan-test-holder-body 1)) 42) 602]
    [(!= (loan-test-result (loan-test-holder-body 2)) 1) 603]
    [(!= (loan-test-holder-live-at-write? 1) 0) 604]
    [(!= (loan-test-holder-live-at-write? 2) 1) 605]
    [else 42]))

(test
  ownership-loan-holder-overwrite
  (test.assert-i64-eq
    (compiler-ownership-loan-holder-self-test)
    42
    "a holder overwrite ends its read demands, bridging the loans its source carries"))

;; A loan borrowed in a loop is issued again on each trip while a reference
;; may still hold the previous trip's issue (`ownership-loan-liveness`). bb2
;; borrows p1 into the temporary p7, reads p5 (prev), then moves p7 into p5.
;; Mode 0 writes p1 at the top of bb2: from the second trip on, p5 still holds
;; the earlier issue and is read after the write, so the write conflicts. Mode
;; 1 writes p1 only after the loop, where p5 is no longer read: the shared
;; issue joins the held one. Mode 2 is mode 1 with an exclusive loan, which
;; would alias the held issue. Mode 3 is mode 0 without the read of p5: no
;; reference holds the earlier issue at the write.
(define (loan-test-reissue-body [mode : i64]) : own.OwnershipBody
  (let
    [body : own.OwnershipBody (loan-test-holder-body 1)]
    [blocks : (__tl_dyn-array own.OwnershipBlock)
      (__tl_make-array own.OwnershipBlock 4)]
    [trip : (__tl_dyn-array own.OwnershipInstruction)
      (cond
        [(= mode 0)
          (__tl_make-array
            (loan-test-op 7 0 1)
            (loan-test-op 0 0 0)
            (loan-test-op 7 0 7)
            (loan-test-may-use 0 5)
            (loan-test-op 8 0 5)
            (loan-test-may-use 0 7)
            (loan-test-move 7 5))]
        [(= mode 3)
          (__tl_make-array
            (loan-test-op 7 0 1)
            (loan-test-op 0 0 0)
            (loan-test-op 7 0 7)
            (loan-test-op 8 0 5)
            (loan-test-may-use 0 7)
            (loan-test-move 7 5))]
        [else
          (__tl_make-array
            (loan-test-op 0 0 0)
            (loan-test-op 7 0 7)
            (loan-test-may-use 0 5)
            (loan-test-op 8 0 5)
            (loan-test-may-use 0 7)
            (loan-test-move 7 5))])]
    (set!
      (array-ref blocks 0)
      (fixture.ownership-test-block
        (__tl_make-array (loan-test-op 7 0 5))
        (own.OwnershipTerminator.Goto (fixture.ownership-test-block-id 1))))
    (set!
      (array-ref blocks 1)
      (fixture.ownership-test-block
        (__tl_make-array own.OwnershipInstruction 0)
        (own.OwnershipTerminator.Branch
          (fixture.ownership-test-place-id 6)
          (fixture.ownership-test-block-id 2)
          (fixture.ownership-test-block-id 3))))
    (set!
      (array-ref blocks 2)
      (fixture.ownership-test-block
        trip
        (own.OwnershipTerminator.Goto (fixture.ownership-test-block-id 1))))
    (set!
      (array-ref blocks 3)
      (fixture.ownership-test-block
        (if (or (= mode 1) (= mode 2))
          (__tl_make-array (loan-test-op 7 0 1))
          (__tl_make-array own.OwnershipInstruction 0))
        (fixture.ownership-test-return)))
    (set! body.blocks blocks)
    (set! body.loans (__tl_make-array (loan-test-loan 1 (= mode 2) -1)))
    body))

(define (compiler-ownership-loan-reissue-self-test) : i64
  (cond
    [(!= (loan-test-result (loan-test-reissue-body 0)) 1) 611]
    [(!= (loan-test-result (loan-test-reissue-body 1)) 42) 612]
    [(!= (loan-test-result (loan-test-reissue-body 2)) 1) 613]
    [(!= (loan-test-result (loan-test-reissue-body 3)) 42) 614]
    [else 42]))

(test
  ownership-loan-reissue
  (test.assert-i64-eq
    (compiler-ownership-loan-reissue-self-test)
    42
    "a loan issued again in a loop stays live while a reference holds its earlier issue"))