;; Authored cleanup authority/CFG obligations. The concrete oracle lives in
;; tools/ownership-model and does not import these production fixtures.
(import compiler_ownership_core as own)
(import compiler_ownership_dump as dump)
(import stdlib.test)
(import stdlib.string)

(define (cleanup-test-id) : own.OwnershipBodyId
  (own.OwnershipBodyId (cast 8449 : u64) (cast 9 : u64) (cast 1 : u64)))

(define (cleanup-test-type [index : i64]) : own.OwnershipTypeId
  (own.OwnershipTypeId (cleanup-test-id) index))

(define (cleanup-test-place [index : i64]) : own.OwnershipPlaceId
  (own.OwnershipPlaceId (cleanup-test-id) index))

(define (cleanup-test-owner [index : i64]) : own.OwnershipObligationId
  (own.OwnershipObligationId (cleanup-test-id) index))

(define (cleanup-test-contract [index : i64]) : own.OwnershipCleanupId
  (own.OwnershipCleanupId (cleanup-test-id) index))

(define (cleanup-test-loan) : own.OwnershipLoanId
  (own.OwnershipLoanId (cleanup-test-id) 0))

(define (cleanup-test-source [index : i64]) : own.OwnershipSource
  (own.OwnershipSource "cleanup-authored.tl" (+ index 1) 1 ""))

(define (cleanup-test-instr [operation : own.OwnershipOperation] [index : i64]) : own.OwnershipInstruction
  (own.OwnershipInstruction operation (cleanup-test-source index)))

(define (cleanup-test-bind [owner : i64] [index : i64]) : own.OwnershipInstruction
  (cleanup-test-instr
    (own.OwnershipOperation.BindFresh (cleanup-test-owner owner))
    index))

(define (cleanup-test-clean [owner : i64] [index : i64]) : own.OwnershipInstruction
  (cleanup-test-instr
    (own.OwnershipOperation.Cleanup
      (cleanup-test-owner owner)
      (cleanup-test-contract 0))
    index))

(define (cleanup-test-leave [owner : i64] [index : i64]) : own.OwnershipInstruction
  (cleanup-test-instr
    (own.OwnershipOperation.Leave (cleanup-test-owner owner))
    index))

(define (cleanup-test-retained [enabled? : bool]) : (__tl_dyn-array
    own.OwnershipCleanupUse)
  (if enabled?
    (__tl_make-array
      (own.OwnershipCleanupUse.Through
        (cleanup-test-loan)
        (cleanup-test-place 2)))
    (__tl_make-array own.OwnershipCleanupUse 0)))

(define (cleanup-test-binding [place : i64] [parent : i64] [retained? : bool]) : own.OwnershipObligation
  (own.OwnershipObligation
    (if (< parent 0)
      own.OwnershipObligationParent.Root
      (own.OwnershipObligationParent.Parent (cleanup-test-owner parent)))
    (cleanup-test-place place)
    own.OwnershipObligationMode.Discharge
    (cleanup-test-contract 0)
    (cleanup-test-retained retained?)
    (cleanup-test-source 0)))

(define (cleanup-test-body
  [instructions : (__tl_dyn-array own.OwnershipInstruction)]
  [retained-source? : bool]
  [retained-dest? : bool]) : own.OwnershipBody
  (let
    [types
      : (__tl_dyn-array own.OwnershipType)
      ;; lint-allow: prefer-dynamic-array-literal
      (__tl_make-array own.OwnershipType 2)]
    [locals : (__tl_dyn-array own.OwnershipLocal)
      (__tl_make-array own.OwnershipLocal 3)]
    [places : (__tl_dyn-array own.OwnershipPlace)
      (__tl_make-array own.OwnershipPlace 3)]
    [i : i64 0]
    (set!
      (array-ref types 0)
      (own.OwnershipType own.OwnershipTypeKind.Scalar false))
    (set!
      (array-ref types 1)
      (own.OwnershipType own.OwnershipTypeKind.Boolean true))
    (while (< i 3)
      (let
        [type : own.OwnershipTypeId
          (cleanup-test-type
            (if (= i 2)
              1
              0))]
        (set!
          (array-ref locals i)
          (own.OwnershipLocal type (= i 2) (cleanup-test-source 0)))
        (set!
          (array-ref places i)
          (own.OwnershipPlace
            (own.OwnershipLocalId (cleanup-test-id) i)
            type
            own.OwnershipProjection.Root
            (cleanup-test-source 0)))
        (set! i (+ i 1))))
    (own.OwnershipBody
      (cleanup-test-id)
      types
      locals
      places
      (if (or retained-source? retained-dest?)
        (__tl_make-array
          (own.OwnershipLoan
            (cleanup-test-place 2)
            own.OwnershipLoanKind.Shared
            own.OwnershipLoanOrigin.Direct
            (cleanup-test-source 0)))
        (__tl_make-array own.OwnershipLoan 0))
      (__tl_make-array
        (own.OwnershipCleanup
          (cleanup-test-type 0)
          true
          own.OwnershipCleanupKind.Intrinsic
          (cleanup-test-source 0)))
      (__tl_make-array
        (cleanup-test-binding 0 -1 retained-source?)
        (cleanup-test-binding 1 0 retained-dest?))
      (__tl_make-array
        (own.OwnershipBlock
          instructions
          (own.OwnershipTerminator.Return
            (own.OwnershipPlaceIds (__tl_make-array own.OwnershipPlaceId 0)))
          (cleanup-test-source 20)))
      (own.OwnershipBlockId (cleanup-test-id) 0))))

(define (cleanup-test-error?
  [result : own.OwnershipResult]
  [kind : i64]
  [instruction : i64]) : bool
  (match result
    [(own.OwnershipResult.Ok) false]
    [(own.OwnershipResult.Err error)
      (and
        (= error.instruction instruction)
        (match error.kind
          [(own.OwnershipFailureKind.Structural) (= kind 0)]
          [(own.OwnershipFailureKind.Cleanup) (= kind 1)]
          [(own.OwnershipFailureKind.Loan) (= kind 2)]
          [(own.OwnershipFailureKind.Resource) (= kind 3)]
          [(own.OwnershipFailureKind.Uninitialized) (= kind 4)]
          [(own.OwnershipFailureKind.Unsupported) (= kind 5)]))]))

(define (cleanup-test-ok? [body : (& body own.OwnershipBody)]) : bool
  (match (own.ownership-check body (own.ownership-default-limits))
    [(own.OwnershipResult.Ok) true]
    [_ false]))

(define (cleanup-test-retained-body [destination? : bool] [invalidate? : bool]) : own.OwnershipBody
  (let
    [instructions : (__tl_dyn-array own.OwnershipInstruction)
      (__tl_make-array
        own.OwnershipInstruction
        (if invalidate?
          5
          4))]
    (set!
      (array-ref instructions 0)
      (cleanup-test-instr (own.OwnershipOperation.Borrow (cleanup-test-loan)) 0))
    (set! (array-ref instructions 1) (cleanup-test-bind 0 1))
    (set!
      (array-ref instructions 2)
      (cleanup-test-instr
        (own.OwnershipOperation.BindMove
          (cleanup-test-place 0)
          (cleanup-test-owner 1))
        2))
    (when
      invalidate?
      (set!
        (array-ref instructions 3)
        (cleanup-test-instr
          (own.OwnershipOperation.Invalidate (cleanup-test-place 2))
          3)))
    (set!
      (array-ref
        instructions
        (if invalidate?
          4
          3))
      (cleanup-test-clean
        1
        (if invalidate?
          4
          3)))
    (cleanup-test-body instructions true destination?)))

(define (compiler-ownership-cleanup-retained-self-test) : i64
  (let
    [body : own.OwnershipBody (cleanup-test-retained-body false false)]
    (unless
      (cleanup-test-error?
        (own.ownership-check (& body) (own.ownership-default-limits))
        1
        2)
      (return 701)))
  (let
    [body : own.OwnershipBody (cleanup-test-retained-body true true)]
    (unless
      (cleanup-test-error?
        (own.ownership-check (& body) (own.ownership-default-limits))
        2
        3)
      (return 702)))
  (let
    [body : own.OwnershipBody (cleanup-test-retained-body true false)]
    (unless (cleanup-test-ok? (& body)) (return 703)))
  42)

(define (cleanup-test-alias-body [overlap? : bool]) : own.OwnershipBody
  (let
    [body : own.OwnershipBody
      (cleanup-test-body
        (if overlap?
          (__tl_make-array
            (cleanup-test-bind 0 0)
            (cleanup-test-clean 0 1)
            (cleanup-test-bind 1 2)
            (cleanup-test-clean 1 3))
          (__tl_make-array
            (cleanup-test-bind 0 0)
            (cleanup-test-clean 0 1)
            (cleanup-test-leave 0 2)
            (cleanup-test-bind 1 3)
            (cleanup-test-clean 1 4)))
        false
        false)]
    (set!
      body.obligations
      (__tl_make-array
        (cleanup-test-binding 0 -1 false)
        (cleanup-test-binding
          0
          (if overlap?
            0
            -1)
          false)
        (cleanup-test-binding 1 -1 false)))
    body))

(define (compiler-ownership-cleanup-authority-self-test) : i64
  (let
    [body : own.OwnershipBody (cleanup-test-alias-body true)]
    (unless
      (cleanup-test-error?
        (own.ownership-check (& body) (own.ownership-default-limits))
        1
        2)
      (return 711)))
  (let
    [body : own.OwnershipBody (cleanup-test-alias-body false)]
    (unless (cleanup-test-ok? (& body)) (return 712)))
  ;; An unregistered same-type root may not manufacture an ordinary-storage
  ;; route around a declared type-owned cleanup contract.
  (let
    [body : own.OwnershipBody
      (cleanup-test-body
        (__tl_make-array own.OwnershipInstruction 0)
        false
        false)]
    (set! body.obligations (__tl_make-array own.OwnershipObligation 0))
    (unless
      (cleanup-test-error?
        (own.ownership-check (& body) (own.ownership-default-limits))
        0
        -1)
      (return 713)))
  ;; Executable scope failures preserve first-error order with initialization.
  (let
    [body : own.OwnershipBody
      (cleanup-test-body
        (__tl_make-array
          (cleanup-test-instr
            (own.OwnershipOperation.Read (cleanup-test-place 0))
            0)
          (cleanup-test-leave 1 1))
        false
        false)]
    [out : own.OwnershipCleanupInspection
      (own.ownership-cleanup-inspect (& body) (own.ownership-default-limits))]
    (unless
      (and
        out.complete?
        (= (array-length out.failure-kinds) 3)
        (!= (bit-and (array-ref out.failure-kinds 0) 1) 0)
        (!= (bit-and (array-ref out.failure-kinds 1) 4) 0)
        (cleanup-test-error? out.result 4 0))
      (return 714)))
  42)

(define (compiler-ownership-cleanup-budget-self-test) : i64
  (let
    [body : own.OwnershipBody
      (cleanup-test-body
        (__tl_make-array (cleanup-test-bind 0 0) (cleanup-test-clean 0 1))
        false
        false)]
    [small : own.OwnershipLimits (own.OwnershipLimits 65536 64 67108864)]
    (match (own.ownership-validate (& body) small)
      [(own.OwnershipResult.Err _) (return 721)]
      [_ unit])
    (unless
      (cleanup-test-error? (own.ownership-check (& body) small) 3 -1)
      (return 722))
    (let
      [out : own.OwnershipCleanupInspection
        (own.ownership-cleanup-inspect (& body) small)]
      (when out.complete? (return 723)))
    (unless (cleanup-test-ok? (& body)) (return 724))
    42))

(test
  ownership-cleanup-retained
  (test.assert-i64-eq
    (compiler-ownership-cleanup-retained-self-test)
    42
    "cleanup dependencies survive whole transfer"))

(test
  ownership-cleanup-authority
  (test.assert-i64-eq
    (compiler-ownership-cleanup-authority-self-test)
    42
    "active cleanup identity and ordered failures"))

(test
  ownership-cleanup-budget
  (test.assert-i64-eq
    (compiler-ownership-cleanup-budget-self-test)
    42
    "cleanup expansion reserves storage before solver admission"))

(define (cleanup-test-product-body [contract? : bool] [copy-hook? : bool]) : own.OwnershipBody
  (let
    [body : own.OwnershipBody
      (cleanup-test-body
        (__tl_make-array own.OwnershipInstruction 0)
        false
        false)]
    (set!
      body.types
      (__tl_make-array
        (own.OwnershipType own.OwnershipTypeKind.Scalar false)
        (own.OwnershipType own.OwnershipTypeKind.Boolean true)
        (own.OwnershipType
          (own.OwnershipTypeKind.Product
            (own.OwnershipTypeIds
              (__tl_make-array (cleanup-test-type 0) (cleanup-test-type 1))))
          false)))
    (set! (array-ref body.locals 0).type (cleanup-test-type 2))
    (set!
      body.places
      (__tl_make-array
        (own.OwnershipPlace
          (own.OwnershipLocalId (cleanup-test-id) 0)
          (cleanup-test-type 2)
          own.OwnershipProjection.Root
          (cleanup-test-source 0))
        (own.OwnershipPlace
          (own.OwnershipLocalId (cleanup-test-id) 1)
          (cleanup-test-type 0)
          own.OwnershipProjection.Root
          (cleanup-test-source 0))
        (own.OwnershipPlace
          (own.OwnershipLocalId (cleanup-test-id) 2)
          (cleanup-test-type 1)
          own.OwnershipProjection.Root
          (cleanup-test-source 0))
        (own.OwnershipPlace
          (own.OwnershipLocalId (cleanup-test-id) 0)
          (cleanup-test-type 0)
          (own.OwnershipProjection.Field (cleanup-test-place 0) 0)
          (cleanup-test-source 0))
        (own.OwnershipPlace
          (own.OwnershipLocalId (cleanup-test-id) 0)
          (cleanup-test-type 1)
          (own.OwnershipProjection.Field (cleanup-test-place 0) 1)
          (cleanup-test-source 0))))
    (when
      contract?
      (set!
        body.cleanups
        (__tl_make-array
          (own.OwnershipCleanup
            (cleanup-test-type 0)
            true
            own.OwnershipCleanupKind.Intrinsic
            (cleanup-test-source 0))
          (own.OwnershipCleanup
            (cleanup-test-type 2)
            true
            (own.OwnershipCleanupKind.Product
              (own.OwnershipCleanupFields
                (if copy-hook?
                  (__tl_make-array
                    (own.OwnershipCleanupField 0 (cleanup-test-contract 0))
                    (own.OwnershipCleanupField 1 (cleanup-test-contract 2)))
                  (__tl_make-array
                    (own.OwnershipCleanupField 0 (cleanup-test-contract 0))))))
            (cleanup-test-source 0))
          (own.OwnershipCleanup
            (cleanup-test-type 1)
            false
            own.OwnershipCleanupKind.Intrinsic
            (cleanup-test-source 0))))
      (set! (array-ref body.obligations 0).cleanup (cleanup-test-contract 1))
      (set!
        (array-ref body.blocks 0).instructions
        (__tl_make-array
          (cleanup-test-bind 0 0)
          (cleanup-test-instr
            (own.OwnershipOperation.Cleanup
              (cleanup-test-owner 0)
              (cleanup-test-contract 1))
            1))))
    body))

(define (compiler-ownership-cleanup-metadata-self-test) : i64
  (let
    [body : own.OwnershipBody (cleanup-test-product-body false false)]
    (match (own.ownership-check (& body) (own.ownership-default-limits))
      [(own.OwnershipResult.Err error)
        (unless
          (and
            (match error.kind
              [(own.OwnershipFailureKind.Structural) true]
              [_ false])
            (string.eq
              error.message
              "ordinary aggregate cannot contain a type-owned field"))
          (return 731))]
      [_ (return 732)]))
  (let
    [body : own.OwnershipBody (cleanup-test-product-body true false)]
    [out : own.OwnershipCleanupInspection
      (own.ownership-cleanup-inspect (& body) (own.ownership-default-limits))]
    (unless
      (and
        out.complete?
        (= (array-length out.actions) 1)
        (= (array-ref out.actions 0).place.index 3)
        (= (array-ref out.actions 0).cleanup.index 0)
        (match out.result
          [(own.OwnershipResult.Ok) true]
          [_ false]))
      (return 733)))
  ;; A Copy field can have its own explicit intrinsic hook without making
  ;; every Boolean value (including the ordinary parameter) a cleanup owner.
  (let
    [body : own.OwnershipBody (cleanup-test-product-body true true)]
    [out : own.OwnershipCleanupInspection
      (own.ownership-cleanup-inspect (& body) (own.ownership-default-limits))]
    (unless
      (and
        out.complete?
        (= (array-length out.actions) 2)
        (= (array-ref out.actions 0).place.index 4)
        (= (array-ref out.actions 0).cleanup.index 2)
        (= (array-ref out.actions 1).place.index 3)
        (= (array-ref out.actions 1).cleanup.index 0)
        (match out.result
          [(own.OwnershipResult.Ok) true]
          [_ false]))
      (return 734)))
  (let
    [body : own.OwnershipBody (cleanup-test-product-body true false)]
    (set!
      (array-ref body.cleanups 1).kind
      (own.OwnershipCleanupKind.Product
        (own.OwnershipCleanupFields
          (__tl_make-array own.OwnershipCleanupField 0))))
    (match (own.ownership-check (& body) (own.ownership-default-limits))
      [(own.OwnershipResult.Err error)
        (unless
          (string.eq
            error.message
            "product omits or substitutes an owned field cleanup")
          (return 735))]
      [_ (return 736)]))
  42)

(test
  ownership-cleanup-metadata
  (test.assert-i64-eq
    (compiler-ownership-cleanup-metadata-self-test)
    42
    "type ownership and explicit Copy hooks have distinct contracts"))

(define (compiler-ownership-cleanup-dump-self-test) : i64
  (let
    [body : own.OwnershipBody (cleanup-test-retained-body true false)]
    (match (dump.ownership-dump (& body) (own.ownership-default-limits))
      [(dump.OwnershipDumpResult.Err _) (return 741)]
      [(dump.OwnershipDumpResult.Ok text)
        (unless
          (and
            (string.contains text "typelisp-ownership v3")
            (string.contains text "%cleanup0 = %t0 type-owned intrinsic")
            (string.contains
              text
              "%owner0 = %p0 %cleanup0 discharge root retain-through %loan0 %p2")
            (string.contains
              text
              "%owner1 = %p1 %cleanup0 discharge parent %owner0 retain-through %loan0 %p2"))
          (return 742))]))
  (let
    [body : own.OwnershipBody (cleanup-test-product-body true true)]
    (match (dump.ownership-dump (& body) (own.ownership-default-limits))
      [(dump.OwnershipDumpResult.Err _) (return 743)]
      [(dump.OwnershipDumpResult.Ok text)
        (unless
          (and
            (string.contains text "%cleanup2 = %t1 context-only intrinsic")
            (string.contains
              text
              "%cleanup1 = %t2 type-owned product field0:%cleanup0 field1:%cleanup2"))
          (return 744))]))
  42)

(define (compiler-ownership-cleanup-self-test) : i64
  (let
    [result : i64 (compiler-ownership-cleanup-retained-self-test)]
    (unless (= result 42) (return result)))
  (let
    [result : i64 (compiler-ownership-cleanup-authority-self-test)]
    (unless (= result 42) (return result)))
  (let
    [result : i64 (compiler-ownership-cleanup-budget-self-test)]
    (unless (= result 42) (return result)))
  (let
    [result : i64 (compiler-ownership-cleanup-metadata-self-test)]
    (unless (= result 42) (return result)))
  (compiler-ownership-cleanup-dump-self-test))

(test
  ownership-cleanup-dump
  (test.assert-i64-eq
    (compiler-ownership-cleanup-dump-self-test)
    42
    "cleanup dumps retain type contracts, identities and dependencies"))