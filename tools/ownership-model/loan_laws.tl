;; Finite production-lattice comparison, separate from the token trace oracle.
;; The concrete domain is an explicit set of Unissued/Active/Ended statuses.
;; No bitwise operation implements the expected union, ordering or successor.
;; Integer masks occur only at the representation adapter below.
;;
;; Scope: scalar powerset laws; componentwise joins/expiry for up to three
;; loans; direct Borrow/UseLoan/EndLoan on three disjoint shared referents.
;; Expiry receives an externally enumerated demand vector: this checks its
;; status transformation, not backward CFG liveness. Transfer failures remain
;; separate from syntactic successor effects. Parent generations, overlap,
;; permission checks and CFG traces belong to loan_model/loan_crosscheck.
;; Every loop has a fixed finite bound and every campaign pins its case count.
(import compiler_ownership_core as core)
(import stdlib.io)

(defenum LoanStatus
  (Unissued)
  (Active)
  (Ended))

(defstruct StatusSet
  (unissued bool)
  (active bool)
  (ended bool))

(define (status-set [index : i64]) : StatusSet
  (match index
    [0 (StatusSet false false false)]
    [1 (StatusSet true false false)]
    [2 (StatusSet false true false)]
    [3 (StatusSet true true false)]
    [4 (StatusSet false false true)]
    [5 (StatusSet true false true)]
    [6 (StatusSet false true true)]
    [7 (StatusSet true true true)]
    [_ (io.panic "loan laws: status set outside finite domain")]))

(define (status [index : i64]) : LoanStatus
  (match index
    [0 LoanStatus.Unissued]
    [1 LoanStatus.Active]
    [2 LoanStatus.Ended]
    [_ (io.panic "loan laws: concrete status outside finite domain")]))

(define (member? [set : StatusSet] [value : LoanStatus]) : bool
  (match value
    [(LoanStatus.Unissued) set.unissued]
    [(LoanStatus.Active) set.active]
    [(LoanStatus.Ended) set.ended]))

(define (include! [set : (&mut set StatusSet)] [value : LoanStatus]) : unit
  (match value
    [(LoanStatus.Unissued) (set! set.unissued true)]
    [(LoanStatus.Active) (set! set.active true)]
    [(LoanStatus.Ended) (set! set.ended true)]))

(define (subset? [left : StatusSet] [right : StatusSet]) : bool
  (and
    (or (not left.unissued) right.unissued)
    (or (not left.active) right.active)
    (or (not left.ended) right.ended)))

(define (union-set [left : StatusSet] [right : StatusSet]) : StatusSet
  (let
    [out : StatusSet (status-set 0)]
    [index : i64 0]
    (begin
      (while (< index 3)
        (let
          [value : LoanStatus (status index)]
          (begin
            (when
              (or (member? left value) (member? right value))
              (include! (&mut out) value))
            (set! index (+ index 1)))))
      out)))

;; Explicit membership-to-mask boundary, not the set-theoretic oracle.
(define (encode [set : StatusSet]) : i64
  (+
    (if set.unissued
      1
      0)
    (if set.active
      2
      0)
    (if set.ended
      4
      0)))

(define (mask? [value : i64]) : bool
  (and (>= value 0) (< value 8)))

(define (mask-subset? [left : i64] [right : i64]) : bool
  (and
    (mask? left)
    (mask? right)
    (subset? (status-set left) (status-set right))))

(define (mismatch [law : String] [first : i64] [second : i64] [third : i64]) : bool
  (begin
    (io.println
      "ownership-loan-laws mismatch: law={} first={} second={} third={}"
      law
      first
      second
      third)
    false))

(define (scalar-laws?) : bool
  (let
    [a : i64 0]
    [pairs : i64 0]
    [triples : i64 0]
    [ordered : i64 0]
    [monotone : i64 0]
    (begin
      (while (< a 8)
        (let
          [b : i64 0]
          (begin
            (unless
              (and
                (= (core.ownership-loan-state-join a 0) a)
                (= (core.ownership-loan-state-join a a) a))
              (return (mismatch "identity-idempotence" a 0 0)))
            (while (< b 8)
              (let
                [joined : i64 (core.ownership-loan-state-join a b)]
                [c : i64 0]
                [order? : bool (subset? (status-set a) (status-set b))]
                (begin
                  (unless
                    (and
                      (=
                        joined
                        (encode (union-set (status-set a) (status-set b))))
                      (= joined (core.ownership-loan-state-join b a))
                      (mask-subset? a joined)
                      (mask-subset? b joined))
                    (return (mismatch "scalar-union" a b joined)))
                  (set! pairs (+ pairs 1))
                  (when order? (set! ordered (+ ordered 1)))
                  (while (< c 8)
                    (begin
                      (unless
                        (=
                          (core.ownership-loan-state-join joined c)
                          (core.ownership-loan-state-join
                            a
                            (core.ownership-loan-state-join b c)))
                        (return (mismatch "associativity" a b c)))
                      (when
                        (and (mask-subset? a c) (mask-subset? b c))
                        (unless
                          (mask-subset? joined c)
                          (return (mismatch "least-upper-bound" a b c))))
                      (when
                        order?
                        (begin
                          (unless
                            (mask-subset?
                              (core.ownership-loan-state-join a c)
                              (core.ownership-loan-state-join b c))
                            (return (mismatch "join-monotonicity" a b c)))
                          (set! monotone (+ monotone 1))))
                      (set! triples (+ triples 1))
                      (set! c (+ c 1))))
                  (set! b (+ b 1)))))
            (set! a (+ a 1)))))
      (or
        (and (= pairs 64) (= triples 512) (= ordered 27) (= monotone 216))
        (mismatch "scalar-count" pairs triples monotone)))))

;; A base-eight tuple is a product of sets. Join is the least coordinatewise
;; upper bound; it conservatively contains the union of concrete triples but
;; does not retain their correlations. Empty components remain algebraic test
;; coordinates, not normalized representations of one global unreachable state.
(define (component [code : i64] [slot : i64] [base : i64]) : i64
  (match slot
    [0 (% code base)]
    [1 (% (/ code base) base)]
    [2 (% (/ code (* base base)) base)]
    [_ (io.panic "loan laws: component outside finite product")]))

(define (product-laws?) : bool
  (let
    [a : i64 0]
    [pairs : i64 0]
    (begin
      (while (< a 512)
        (let
          [b : i64 0]
          (begin
            (while (< b 512)
              (let
                [slot : i64 0]
                (begin
                  (while (< slot 3)
                    (let
                      [left : i64 (component a slot 8)]
                      [right : i64 (component b slot 8)]
                      (begin
                        (unless
                          (=
                            (core.ownership-loan-state-join left right)
                            (encode
                              (union-set (status-set left) (status-set right))))
                          (return (mismatch "product-union" a b slot)))
                        (set! slot (+ slot 1)))))
                  (set! pairs (+ pairs 1))
                  (set! b (+ b 1)))))
            (set! a (+ a 1)))))
      (or (= pairs 262144) (mismatch "product-count" pairs 0 0)))))

(define (expired [value : LoanStatus] [demanded? : bool]) : LoanStatus
  (match value
    [(LoanStatus.Active)
      (if demanded?
        LoanStatus.Active
        LoanStatus.Ended)]
    [(LoanStatus.Unissued) LoanStatus.Unissued]
    [(LoanStatus.Ended) LoanStatus.Ended]))

(define (expire-set [set : StatusSet] [demanded? : bool]) : StatusSet
  (let
    [out : StatusSet (status-set 0)]
    [index : i64 0]
    (begin
      (while (< index 3)
        (let
          [value : LoanStatus (status index)]
          (begin
            (when
              (member? set value)
              (include! (&mut out) (expired value demanded?)))
            (set! index (+ index 1)))))
      out)))

(define (expiry-laws?) : bool
  (let
    [code : i64 0]
    [cases : i64 0]
    [ordered : i64 0]
    [outputs : (__tl_dyn-array i64) (__tl_make-array i64 16)]
    (begin
      (while (< code 8)
        (let
          [demand : i64 0]
          (begin
            (while (< demand 2)
              (let
                [state : (__tl_dyn-array i64) (__tl_make-array code)]
                [live : core.OwnershipLoanLiveness
                  (core.ownership-loan-liveness-row
                    (__tl_make-array (= demand 1)))]
                (begin
                  (core.ownership-loan-expire! (&mut state) (& live) 0)
                  (unless
                    (=
                      (array-ref state 0)
                      (encode (expire-set (status-set code) (= demand 1))))
                    (return
                      (mismatch "expiry-scalar" code demand (array-ref state 0))))
                  (set!
                    (array-ref outputs (+ (* code 2) demand))
                    (array-ref state 0))
                  (set! demand (+ demand 1)))))
            (set! code (+ code 1)))))
      (set! code 0)
      (while (< code 8)
        (let
          [other : i64 0]
          (begin
            (while (< other 8)
              (begin
                (when
                  (subset? (status-set code) (status-set other))
                  (let
                    [demand : i64 0]
                    (while (< demand 2)
                      (begin
                        (unless
                          (mask-subset?
                            (array-ref outputs (+ (* code 2) demand))
                            (array-ref outputs (+ (* other 2) demand)))
                          (return
                            (mismatch "expiry-monotonicity" code other demand)))
                        (set! ordered (+ ordered 1))
                        (set! demand (+ demand 1))))))
                (set! other (+ other 1))))
            (set! code (+ code 1)))))
      (set! code 0)
      (while (< code 512)
        (let
          [demand : i64 0]
          (begin
            (while (< demand 8)
              (let
                [state : (__tl_dyn-array i64)
                  (__tl_make-array
                    (component code 0 8)
                    (component code 1 8)
                    (component code 2 8))]
                [live : core.OwnershipLoanLiveness
                  (core.ownership-loan-liveness-row
                    (__tl_make-array
                      (= (component demand 0 2) 1)
                      (= (component demand 1 2) 1)
                      (= (component demand 2 2) 1)))]
                [slot : i64 0]
                (begin
                  (core.ownership-loan-expire! (&mut state) (& live) 0)
                  (while (< slot 3)
                    (begin
                      (unless
                        (=
                          (array-ref state slot)
                          (encode
                            (expire-set
                              (status-set (component code slot 8))
                              (= (component demand slot 2) 1))))
                        (return (mismatch "expiry-product" code demand slot)))
                      (set! slot (+ slot 1))))
                  (set! cases (+ cases 1))
                  (set! demand (+ demand 1)))))
            (set! code (+ code 1)))))
      (or
        (and (= cases 4096) (= ordered 54))
        (mismatch "expiry-count" cases ordered 0)))))

(define (law-body-id) : core.OwnershipBodyId
  (core.OwnershipBodyId (cast 8449 : u64) (cast 5 : u64) (cast 1 : u64)))

(define (law-type) : core.OwnershipTypeId
  (core.OwnershipTypeId (law-body-id) 0))

(define (law-place [slot : i64]) : core.OwnershipPlaceId
  (core.OwnershipPlaceId (law-body-id) slot))

(define (law-loan [slot : i64]) : core.OwnershipLoanId
  (core.OwnershipLoanId (law-body-id) slot))

(define (law-source) : core.OwnershipSource
  (core.OwnershipSource "loan-laws.tl" 1 1 "finite direct-status law"))

(define (law-instruction [operation : i64] [slot : i64]) : core.OwnershipInstruction
  (core.OwnershipInstruction
    (match operation
      [0 (core.OwnershipOperation.Borrow (law-loan slot))]
      [1 (core.OwnershipOperation.UseLoan (law-loan slot))]
      [2 (core.OwnershipOperation.EndLoan (law-loan slot))]
      [_ (io.panic "loan laws: operation outside declared scope")])
    (law-source)))

(define (law-body) : core.OwnershipBody
  (let
    [locals : (__tl_dyn-array core.OwnershipLocal)
      (__tl_make-array core.OwnershipLocal 3)]
    [places : (__tl_dyn-array core.OwnershipPlace)
      (__tl_make-array core.OwnershipPlace 3)]
    [loans : (__tl_dyn-array core.OwnershipLoan)
      (__tl_make-array core.OwnershipLoan 3)]
    [instructions : (__tl_dyn-array core.OwnershipInstruction)
      (__tl_make-array core.OwnershipInstruction 3)]
    [slot : i64 0]
    (begin
      (while (< slot 3)
        (begin
          (set!
            (array-ref locals slot)
            (core.OwnershipLocal (law-type) true (law-source)))
          (set!
            (array-ref places slot)
            (core.OwnershipPlace
              (core.OwnershipLocalId (law-body-id) slot)
              (law-type)
              core.OwnershipProjection.Root
              (law-source)))
          (set!
            (array-ref loans slot)
            (core.OwnershipLoan
              (law-place slot)
              core.OwnershipLoanKind.Shared
              core.OwnershipLoanOrigin.Direct
              (law-source)))
          (set! (array-ref instructions slot) (law-instruction 0 slot))
          (set! slot (+ slot 1))))
      (core.OwnershipBody
        (law-body-id)
        (__tl_make-array
          (core.OwnershipType core.OwnershipTypeKind.Scalar true))
        locals
        places
        loans
        (__tl_make-array core.OwnershipCleanup 0)
        (__tl_make-array core.OwnershipObligation 0)
        (__tl_make-array
          (core.OwnershipBlock
            instructions
            (core.OwnershipTerminator.Return
              (core.OwnershipPlaceIds (__tl_make-array core.OwnershipPlaceId 0)))
            (law-source)))
        (core.OwnershipBlockId (law-body-id) 0)))))

;; Borrowing a shared referent is valid in every status: an issue while one
;; is active joins it (a loop's borrow site whose earlier issue is still held).
;; Using or ending needs an active issue.
(define (step-valid? [value : LoanStatus] [operation : i64]) : bool
  (match value
    [(LoanStatus.Active) true]
    [_ (= operation 0)]))

(define (step-status [value : LoanStatus] [operation : i64]) : LoanStatus
  (match operation
    [0 LoanStatus.Active]
    [1 value]
    [2 LoanStatus.Ended]
    [_ (io.panic "loan laws: successor operation outside declared scope")]))

(define (product-member? [code : i64] [concrete : i64]) : bool
  (and
    (member?
      (status-set (+ (component code 0 7) 1))
      (status (component concrete 0 3)))
    (member?
      (status-set (+ (component code 1 7) 1))
      (status (component concrete 1 3)))
    (member?
      (status-set (+ (component code 2 7) 1))
      (status (component concrete 2 3)))))

(define (product-subset? [left : i64] [right : i64]) : bool
  (and
    (mask-subset? (+ (component left 0 7) 1) (+ (component right 0 7) 1))
    (mask-subset? (+ (component left 1 7) 1) (+ (component right 1 7) 1))
    (mask-subset? (+ (component left 2 7) 1) (+ (component right 2 7) 1))))

(define (transfer-laws?) : bool
  (let
    [body : core.OwnershipBody (law-body)]
    [live : core.OwnershipLoanLiveness
      (core.ownership-loan-liveness-row (__tl_make-array false false false))]
    ;; 343 nonempty products * 3 operations * 3 target slots. The cache stores
    ;; actual canonical outputs once; subsequent ordered pairs inspect it.
    [outputs : (__tl_dyn-array i64) (__tl_make-array i64 9261)]
    [failures : (__tl_dyn-array bool) (__tl_make-array bool 3087)]
    [code : i64 0]
    [cases : i64 0]
    [members : i64 0]
    [ordered : i64 0]
    (begin
      (match (core.ownership-validate (& body) (core.ownership-default-limits))
        [(core.OwnershipResult.Err _)
          (return (mismatch "fixture-validation" 0 0 0))]
        [(core.OwnershipResult.Ok) unit])
      (while (< code 343)
        (let
          [choice : i64 0]
          (begin
            (while (< choice 9)
              (let
                [operation : i64 (/ choice 3)]
                [target : i64 (% choice 3)]
                [state : (__tl_dyn-array i64)
                  (__tl_make-array
                    (+ (component code 0 7) 1)
                    (+ (component code 1 7) 1)
                    (+ (component code 2 7) 1))]
                [instruction : core.OwnershipInstruction
                  (law-instruction operation target)]
                [work : i64 0]
                [failed? : bool false]
                [expected-failure? : bool false]
                [concrete : i64 0]
                [row : i64 (+ (* code 9) choice)]
                (begin
                  (match (core.ownership-loan-transfer!
                    (& body)
                    (&mut state)
                    (& live)
                    0
                    (& instruction)
                    0
                    target
                    (&mut work)
                    4096)
                    [(core.OwnershipResult.Ok) unit]
                    [(core.OwnershipResult.Err error)
                      (match error.kind
                        [(core.OwnershipFailureKind.Loan) (set! failed? true)]
                        [_
                          (return
                            (mismatch
                              "unexpected-transfer-failure"
                              code
                              choice
                              0))])])
                  (while (< concrete 27)
                    (begin
                      (when
                        (product-member? code concrete)
                        (let
                          [input : LoanStatus
                            (status (component concrete target 3))]
                          [valid? : bool (step-valid? input operation)]
                          [slot : i64 0]
                          (begin
                            (set! members (+ members 1))
                            (unless valid? (set! expected-failure? true))
                            ;; Only successful concrete successors are semantic
                            ;; outcomes. Rejected abstract prefixes still retain
                            ;; syntactic outputs, checked below by monotonicity.
                            (when
                              valid?
                              (while (< slot 3)
                                (let
                                  [output : LoanStatus
                                    (if (= slot target)
                                      (step-status input operation)
                                      (status (component concrete slot 3)))]
                                  (begin
                                    (unless
                                      (and
                                        (mask? (array-ref state slot))
                                        (member?
                                          (status-set (array-ref state slot))
                                          output))
                                      (return
                                        (mismatch
                                          "transfer-inclusion"
                                          code
                                          choice
                                          concrete)))
                                    (set! slot (+ slot 1)))))))))
                      (set! concrete (+ concrete 1))))
                  (unless
                    (= failed? expected-failure?)
                    (return (mismatch "transfer-rejection" code choice 0)))
                  (set! (array-ref failures row) failed?)
                  (let
                    [slot : i64 0]
                    (while (< slot 3)
                      (begin
                        (unless
                          (mask? (array-ref state slot))
                          (return (mismatch "transfer-mask" code choice slot)))
                        (set!
                          (array-ref outputs (+ (* row 3) slot))
                          (array-ref state slot))
                        (set! slot (+ slot 1)))))
                  (set! cases (+ cases 1))
                  (set! choice (+ choice 1)))))
            (set! code (+ code 1)))))
      (set! code 0)
      (while (< code 343)
        (let
          [other : i64 0]
          (begin
            (while (< other 343)
              (begin
                (when
                  (product-subset? code other)
                  (let
                    [choice : i64 0]
                    (while (< choice 9)
                      (let
                        [left : i64 (+ (* code 9) choice)]
                        [right : i64 (+ (* other 9) choice)]
                        [slot : i64 0]
                        (begin
                          (when
                            (and
                              (array-ref failures left)
                              (not (array-ref failures right)))
                            (return
                              (mismatch
                                "failure-monotonicity"
                                code
                                other
                                choice)))
                          (while (< slot 3)
                            (begin
                              (unless
                                (mask-subset?
                                  (array-ref outputs (+ (* left 3) slot))
                                  (array-ref outputs (+ (* right 3) slot)))
                                (return
                                  (mismatch
                                    "transfer-monotonicity"
                                    code
                                    other
                                    choice)))
                              (set! slot (+ slot 1))))
                          (set! ordered (+ ordered 1))
                          (set! choice (+ choice 1)))))))
                (set! other (+ other 1))))
            (set! code (+ code 1)))))
      ;; Each status occurs in four of the seven nonempty sets. Across three
      ;; coordinates: 12^3 memberships, each tested for nine operation/targets.
      (or
        (and (= cases 3087) (= members 15552) (= ordered 61731))
        (mismatch "transfer-count" cases members ordered)))))

(define (main) : i64
  (if (and (scalar-laws?) (product-laws?) (expiry-laws?) (transfer-laws?))
    (begin
      (io.println
        "ownership-loan-laws-v1: scalar=8 pairs=64 triples=512 product-pairs=262144 expiry=4096 transfers=3087 members=15552 monotone=61731 passed")
      0)
    1))