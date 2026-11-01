;; Ownership graph regression tests. Source normalization is not exercised here.
(import compiler_ownership_core as own)
(import compiler_ownership_dump as dump)
(import stdlib.string)
(import stdlib.test)

(define (ownership-test-id) : own.OwnershipBodyId
  (own.OwnershipBodyId (cast 11 : u64) (cast 3 : u64) (cast 2 : u64)))

(define (ownership-test-type-id [index : i64]) : own.OwnershipTypeId
  (own.OwnershipTypeId (ownership-test-id) index))

(define (ownership-test-place-id [index : i64]) : own.OwnershipPlaceId
  (own.OwnershipPlaceId (ownership-test-id) index))

(define (ownership-test-block-id [index : i64]) : own.OwnershipBlockId
  (own.OwnershipBlockId (ownership-test-id) index))

(define (ownership-test-source [line : i64]) : own.OwnershipSource
  (own.OwnershipSource "ownership-fixture.tl" line 3 "fixture macro"))

;; Two operands parse as the type/length form when the first is nominal syntax.
(define (ownership-test-fields [first : i64] [second : i64]) : (__tl_dyn-array
    own.OwnershipTypeId)
  (let
    [out
      : (__tl_dyn-array own.OwnershipTypeId)
      ;; lint-allow: prefer-dynamic-array-literal
      (__tl_make-array own.OwnershipTypeId 2)]
    (set! (array-ref out 0) (ownership-test-type-id first))
    (set! (array-ref out 1) (ownership-test-type-id second))
    out))

(define (ownership-test-local [type-id : i64] [parameter? : bool]) : own.OwnershipLocal
  (own.OwnershipLocal
    (ownership-test-type-id type-id)
    parameter?
    (ownership-test-source 1)))

(define (ownership-test-place
  [local : i64]
  [type-id : i64]
  [parent : i64]
  [field : i64]) : own.OwnershipPlace
  (own.OwnershipPlace
    (own.OwnershipLocalId (ownership-test-id) local)
    (ownership-test-type-id type-id)
    (if (< parent 0)
      own.OwnershipProjection.Root
      (own.OwnershipProjection.Field (ownership-test-place-id parent) field))
    (ownership-test-source (+ field 2))))

;; Places: root=0, head=1, tail=2, tail.left=3, tail.right=4,
;; separate shadow binding=5, Boolean condition=6. No source name is an ID.
(define (ownership-test-body [blocks : (__tl_dyn-array own.OwnershipBlock)]) : own.OwnershipBody
  (let
    [types : (__tl_dyn-array own.OwnershipType)
      (__tl_make-array own.OwnershipType 4)]
    [locals : (__tl_dyn-array own.OwnershipLocal)
      (__tl_make-array own.OwnershipLocal 3)]
    [places : (__tl_dyn-array own.OwnershipPlace)
      (__tl_make-array own.OwnershipPlace 7)]
    (set!
      (array-ref types 0)
      (own.OwnershipType own.OwnershipTypeKind.Scalar false))
    (set!
      (array-ref types 1)
      (own.OwnershipType own.OwnershipTypeKind.Boolean true))
    (set!
      (array-ref types 2)
      (own.OwnershipType
        (own.OwnershipTypeKind.Product
          (own.OwnershipTypeIds (ownership-test-fields 0 0)))
        false))
    (set!
      (array-ref types 3)
      (own.OwnershipType
        (own.OwnershipTypeKind.Product
          (own.OwnershipTypeIds (ownership-test-fields 0 2)))
        false))
    (set! (array-ref locals 0) (ownership-test-local 3 true))
    (set! (array-ref locals 1) (ownership-test-local 0 false))
    (set! (array-ref locals 2) (ownership-test-local 1 true))
    (set! (array-ref places 0) (ownership-test-place 0 3 -1 0))
    (set! (array-ref places 1) (ownership-test-place 0 0 0 0))
    (set! (array-ref places 2) (ownership-test-place 0 2 0 1))
    (set! (array-ref places 3) (ownership-test-place 0 0 2 0))
    (set! (array-ref places 4) (ownership-test-place 0 0 2 1))
    (set! (array-ref places 5) (ownership-test-place 1 0 -1 0))
    (set! (array-ref places 6) (ownership-test-place 2 1 -1 0))
    (own.OwnershipBody
      (ownership-test-id)
      types
      locals
      places
      (__tl_make-array own.OwnershipLoan 0)
      (__tl_make-array own.OwnershipCleanup 0)
      (__tl_make-array own.OwnershipObligation 0)
      blocks
      (ownership-test-block-id 0))))

(define (ownership-test-op [kind : i64] [place : i64] [line : i64]) : own.OwnershipInstruction
  (own.OwnershipInstruction
    (match kind
      [0 (own.OwnershipOperation.Read (ownership-test-place-id place))]
      [1 (own.OwnershipOperation.Assign (ownership-test-place-id place))]
      [2 (own.OwnershipOperation.Consume (ownership-test-place-id place))]
      [3 (own.OwnershipOperation.Invalidate (ownership-test-place-id place))]
      [_ (own.OwnershipOperation.Unsupported "unclassified fixture operation")])
    (ownership-test-source line)))

(define (ownership-test-return) : own.OwnershipTerminator
  (own.OwnershipTerminator.Return
    (own.OwnershipPlaceIds (__tl_make-array own.OwnershipPlaceId 0))))

(define (ownership-test-return-place [place : i64]) : own.OwnershipTerminator
  (let
    [uses : (__tl_dyn-array own.OwnershipPlaceId)
      (__tl_make-array own.OwnershipPlaceId 1)]
    (set! (array-ref uses 0) (ownership-test-place-id place))
    (own.OwnershipTerminator.Return (own.OwnershipPlaceIds uses))))

(define (ownership-test-block
  [instructions : (__tl_dyn-array own.OwnershipInstruction)]
  [terminator : own.OwnershipTerminator]) : own.OwnershipBlock
  (own.OwnershipBlock instructions terminator (ownership-test-source 40)))

(define (ownership-test-instructions1 [a : own.OwnershipInstruction]) : (__tl_dyn-array
    own.OwnershipInstruction)
  (__tl_make-array a))

(define (ownership-test-instructions2
  [a : own.OwnershipInstruction]
  [b : own.OwnershipInstruction]) : (__tl_dyn-array own.OwnershipInstruction)
  (let
    [out : (__tl_dyn-array own.OwnershipInstruction)
      (__tl_make-array own.OwnershipInstruction 2)]
    (set! (array-ref out 0) a)
    (set! (array-ref out 1) b)
    out))

(define (ownership-test-single
  [instructions : (__tl_dyn-array own.OwnershipInstruction)]
  [terminator : own.OwnershipTerminator]) : own.OwnershipBody
  (let
    [blocks : (__tl_dyn-array own.OwnershipBlock)
      (__tl_make-array own.OwnershipBlock 1)]
    (set! (array-ref blocks 0) (ownership-test-block instructions terminator))
    (ownership-test-body blocks)))

(define (ownership-test-ok? [body : own.OwnershipBody]) : bool
  (match (own.ownership-check (& body) (own.ownership-default-limits))
    [(own.OwnershipResult.Ok) true]
    [(own.OwnershipResult.Err _) false]))

(define (ownership-test-kind-code [kind : (& kind own.OwnershipFailureKind)]) : i64
  (match kind
    [(own.OwnershipFailureKind.Structural) 0]
    [(own.OwnershipFailureKind.Unsupported) 1]
    [(own.OwnershipFailureKind.Uninitialized) 2]
    [(own.OwnershipFailureKind.Loan) 4]
    [(own.OwnershipFailureKind.Cleanup) 5]
    [(own.OwnershipFailureKind.Resource) 3]))

(define (ownership-test-error?
  [body : own.OwnershipBody]
  [kind : i64]
  [block : i64]
  [instruction : i64]
  [place : i64]) : bool
  (match (own.ownership-check (& body) (own.ownership-default-limits))
    [(own.OwnershipResult.Ok) false]
    [(own.OwnershipResult.Err error)
      (and
        (= (ownership-test-kind-code (& error.kind)) kind)
        (= error.block block)
        (= error.instruction instruction)
        (= error.place place)
        (> error.source.line 0)
        (> (string.string-length (& error.message)) 0))]))

(define (ownership-test-place-transfers?) : bool
  (and
    ;; A moved nested child invalidates the parent but leaves its sibling live.
    (ownership-test-error?
      (ownership-test-single
        (ownership-test-instructions2
          (ownership-test-op 2 3 10)
          (ownership-test-op 0 0 11))
        (ownership-test-return))
      2
      0
      1
      0)
    (ownership-test-ok?
      (ownership-test-single
        (ownership-test-instructions2
          (ownership-test-op 2 3 10)
          (ownership-test-op 0 4 11))
        (ownership-test-return)))
    ;; Repair only the missing child; all aggregate ancestors become readable.
    (ownership-test-ok?
      (ownership-test-single
        (ownership-test-instructions2
          (ownership-test-op 2 3 10)
          (ownership-test-op 1 3 11))
        (ownership-test-return-place 0)))
    (ownership-test-ok?
      (ownership-test-single
        (ownership-test-instructions2
          (ownership-test-op 2 0 10)
          (ownership-test-op 1 0 11))
        (ownership-test-return-place 0)))
    ;; One child cannot repair its moved sibling or a moved whole parent.
    (ownership-test-error?
      (ownership-test-single
        (ownership-test-instructions2
          (ownership-test-op 2 0 10)
          (ownership-test-op 1 3 11))
        (ownership-test-return-place 0))
      2
      0
      2
      0)
    (ownership-test-error?
      (ownership-test-single
        (ownership-test-instructions2
          (ownership-test-op 2 3 10)
          (ownership-test-op 1 5 11))
        (ownership-test-return-place 3))
      2
      0
      2
      3)
    (ownership-test-error?
      (ownership-test-single
        (ownership-test-instructions1 (ownership-test-op 0 5 10))
        (ownership-test-return))
      2
      0
      0
      5)
    ;; Copy consumption preserves its source; raw invalidation does not.
    (ownership-test-ok?
      (ownership-test-single
        (ownership-test-instructions1 (ownership-test-op 2 6 10))
        (ownership-test-return-place 6)))
    (ownership-test-error?
      (ownership-test-single
        (ownership-test-instructions1 (ownership-test-op 3 6 10))
        (ownership-test-return-place 6))
      2
      0
      1
      6)))

;; mode 0: normal moved arm; 1: returning moved arm; 2: aborting moved arm;
;; 3: move and reinitialize arm; 4: returning arm retains the moved owner.
(define (ownership-test-branch-body [mode : i64]) : own.OwnershipBody
  (let
    [blocks : (__tl_dyn-array own.OwnershipBlock)
      (__tl_make-array own.OwnershipBlock 4)]
    (set!
      (array-ref blocks 0)
      (ownership-test-block
        (__tl_make-array own.OwnershipInstruction 0)
        (own.OwnershipTerminator.Branch
          (ownership-test-place-id 6)
          (ownership-test-block-id 1)
          (ownership-test-block-id 2))))
    (set!
      (array-ref blocks 1)
      (ownership-test-block
        (if (= mode 3)
          (ownership-test-instructions2
            (ownership-test-op 2 3 10)
            (ownership-test-op 1 3 11))
          (ownership-test-instructions1 (ownership-test-op 2 3 10)))
        (match mode
          [1 (ownership-test-return)]
          [2 own.OwnershipTerminator.Abort]
          [4 (ownership-test-return-place 0)]
          [_ (own.OwnershipTerminator.Goto (ownership-test-block-id 3))])))
    (set!
      (array-ref blocks 2)
      (ownership-test-block
        (__tl_make-array own.OwnershipInstruction 0)
        (own.OwnershipTerminator.Goto (ownership-test-block-id 3))))
    (set!
      (array-ref blocks 3)
      (ownership-test-block
        (ownership-test-instructions1 (ownership-test-op 0 0 20))
        (ownership-test-return)))
    (ownership-test-body blocks)))

(define (ownership-test-branches?) : bool
  (and
    (ownership-test-error? (ownership-test-branch-body 0) 2 3 0 0)
    (ownership-test-ok? (ownership-test-branch-body 1))
    (ownership-test-ok? (ownership-test-branch-body 2))
    (ownership-test-ok? (ownership-test-branch-body 3))
    (ownership-test-error? (ownership-test-branch-body 4) 2 1 1 0)))

(define (ownership-test-loop-body [reinitialize? : bool] [read-after? : bool]) : own.OwnershipBody
  (let
    [blocks : (__tl_dyn-array own.OwnershipBlock)
      (__tl_make-array own.OwnershipBlock 3)]
    (set!
      (array-ref blocks 0)
      (ownership-test-block
        (__tl_make-array own.OwnershipInstruction 0)
        (own.OwnershipTerminator.Branch
          (ownership-test-place-id 6)
          (ownership-test-block-id 1)
          (ownership-test-block-id 2))))
    (set!
      (array-ref blocks 1)
      (ownership-test-block
        (if reinitialize?
          (ownership-test-instructions2
            (ownership-test-op 2 3 10)
            (ownership-test-op 1 3 11))
          (ownership-test-instructions1 (ownership-test-op 2 3 10)))
        (if read-after?
          (own.OwnershipTerminator.Goto (ownership-test-block-id 2))
          (own.OwnershipTerminator.Goto (ownership-test-block-id 0)))))
    (set!
      (array-ref blocks 2)
      (ownership-test-block
        (__tl_make-array own.OwnershipInstruction 0)
        (if read-after?
          (ownership-test-return-place 0)
          (ownership-test-return))))
    (ownership-test-body blocks)))

(define (ownership-test-loops?) : bool
  (and
    (ownership-test-error? (ownership-test-loop-body false false) 2 1 0 3)
    (ownership-test-ok? (ownership-test-loop-body true false))
    (ownership-test-error? (ownership-test-loop-body false true) 2 2 0 0)
    (ownership-test-ok? (ownership-test-loop-body true true))))

(define (ownership-test-transfer-body [copy? : bool] [read-source? : bool]) : own.OwnershipBody
  (ownership-test-single
    (ownership-test-instructions2
      (own.OwnershipInstruction
        (if copy?
          (own.OwnershipOperation.Copy
            (ownership-test-place-id 3)
            (ownership-test-place-id 5))
          (own.OwnershipOperation.Move
            (ownership-test-place-id 3)
            (ownership-test-place-id 5)))
        (ownership-test-source 10))
      (ownership-test-op
        0
        (if read-source?
          3
          5)
        11))
    (ownership-test-return)))

(define (ownership-test-explicit-transfers?) : bool
  (and
    (ownership-test-ok? (ownership-test-transfer-body false false))
    (ownership-test-error? (ownership-test-transfer-body false true) 2 0 1 3)
    (ownership-test-error? (ownership-test-transfer-body true false) 0 0 0 -1)
    (ownership-test-error?
      (ownership-test-single
        (ownership-test-instructions1
          (own.OwnershipInstruction
            (own.OwnershipOperation.Move
              (ownership-test-place-id 0)
              (ownership-test-place-id 0))
            (ownership-test-source 10)))
        (ownership-test-return))
      0
      0
      0
      -1)))

(define (ownership-test-copy-transfer? [move? : bool]) : bool
  (let
    [body : own.OwnershipBody
      (ownership-test-single
        (ownership-test-instructions2
          (own.OwnershipInstruction
            (if move?
              (own.OwnershipOperation.Move
                (ownership-test-place-id 6)
                (ownership-test-place-id 5))
              (own.OwnershipOperation.Copy
                (ownership-test-place-id 6)
                (ownership-test-place-id 5)))
            (ownership-test-source 10))
          (ownership-test-op 0 6 11))
        (ownership-test-return-place 5))]
    (set! (array-ref body.locals 1) (ownership-test-local 1 false))
    (set! (array-ref body.places 5) (ownership-test-place 1 1 -1 0))
    (ownership-test-ok? body)))

(define (ownership-test-malformed-body [mode : i64]) : own.OwnershipBody
  (let
    [body : own.OwnershipBody
      (ownership-test-single
        (__tl_make-array own.OwnershipInstruction 0)
        (ownership-test-return))]
    (match mode
      [0
        (set!
          body.entry
          (own.OwnershipBlockId
            (own.OwnershipBodyId (cast 12 : u64) (cast 3 : u64) (cast 2 : u64))
            0))]
      [1
        (set!
          body.entry
          (own.OwnershipBlockId
            (own.OwnershipBodyId (cast 11 : u64) (cast 4 : u64) (cast 2 : u64))
            0))]
      [2
        (set!
          body.entry
          (own.OwnershipBlockId
            (own.OwnershipBodyId (cast 11 : u64) (cast 3 : u64) (cast 3 : u64))
            0))]
      [3 (set! (array-ref body.places 3) (ownership-test-place 0 1 2 0))]
      [4 (set! (array-ref body.places 3) (ownership-test-place 0 0 2 1))]
      [5
        (set!
          (array-ref body.types 3)
          (own.OwnershipType
            (own.OwnershipTypeKind.Product
              (own.OwnershipTypeIds (ownership-test-fields 0 2)))
            true))]
      [6 (set! (array-ref body.locals 0) (ownership-test-local 99 true))]
      [_ (set! body.entry (ownership-test-block-id 99))])
    body))

(define (ownership-test-missing-field-body) : own.OwnershipBody
  (let
    [body : own.OwnershipBody
      (ownership-test-single
        (__tl_make-array own.OwnershipInstruction 0)
        (ownership-test-return))]
    [fields : (__tl_dyn-array own.OwnershipTypeId)
      (__tl_make-array own.OwnershipTypeId 3)]
    (set! (array-ref fields 0) (ownership-test-type-id 0))
    (set! (array-ref fields 1) (ownership-test-type-id 0))
    (set! (array-ref fields 2) (ownership-test-type-id 0))
    (set!
      (array-ref body.types 2)
      (own.OwnershipType
        (own.OwnershipTypeKind.Product (own.OwnershipTypeIds fields))
        false))
    body))

(define (ownership-test-unsupported-body [terminator? : bool]) : own.OwnershipBody
  (let
    [blocks : (__tl_dyn-array own.OwnershipBlock)
      (__tl_make-array own.OwnershipBlock 2)]
    (set!
      (array-ref blocks 0)
      (ownership-test-block
        (__tl_make-array own.OwnershipInstruction 0)
        (ownership-test-return)))
    ;; Dead blocks remain structurally validated; they cannot hide new core ops.
    (set!
      (array-ref blocks 1)
      (ownership-test-block
        (if terminator?
          (__tl_make-array own.OwnershipInstruction 0)
          (ownership-test-instructions1 (ownership-test-op 4 0 10)))
        (if terminator?
          (own.OwnershipTerminator.Unsupported "unclassified fixture exit")
          (ownership-test-return))))
    (ownership-test-body blocks)))

(define (ownership-test-malformed?) : bool
  (and
    (ownership-test-error? (ownership-test-malformed-body 0) 0 -1 -1 -1)
    (ownership-test-error? (ownership-test-malformed-body 1) 0 -1 -1 -1)
    (ownership-test-error? (ownership-test-malformed-body 2) 0 -1 -1 -1)
    (ownership-test-error? (ownership-test-malformed-body 3) 0 -1 -1 3)
    (ownership-test-error? (ownership-test-malformed-body 4) 0 -1 -1 4)
    (ownership-test-error? (ownership-test-malformed-body 5) 0 -1 -1 -1)
    (ownership-test-error? (ownership-test-malformed-body 6) 0 -1 -1 -1)
    (ownership-test-error? (ownership-test-malformed-body 7) 0 -1 -1 -1)
    (ownership-test-error? (ownership-test-missing-field-body) 0 -1 -1 2)
    (ownership-test-error? (ownership-test-unsupported-body false) 1 1 0 -1)
    (ownership-test-error? (ownership-test-unsupported-body true) 1 1 0 -1)))

(define (ownership-test-resource? [limits : own.OwnershipLimits]) : bool
  (let
    [body : own.OwnershipBody
      (ownership-test-single
        (ownership-test-instructions1 (ownership-test-op 0 0 10))
        (ownership-test-return))]
    (match (own.ownership-check (& body) limits)
      [(own.OwnershipResult.Err error)
        (= (ownership-test-kind-code (& error.kind)) 3)]
      [_ false])))

(define (ownership-test-limits?) : bool
  (and
    (ownership-test-resource? (own.OwnershipLimits 6 1000 1000))
    (ownership-test-resource? (own.OwnershipLimits 1000 6 1000))
    (ownership-test-resource? (own.OwnershipLimits 1000 1000 1))
    (ownership-test-resource? (own.OwnershipLimits 1000 1000 100))
    (ownership-test-resource? (own.OwnershipLimits 1000 1000 0))))

(define (ownership-test-instruction-limit?) : bool
  (let
    [instructions : (__tl_dyn-array own.OwnershipInstruction)
      (__tl_make-array own.OwnershipInstruction 8)]
    [i : i64 0]
    (while (< i 8)
      (set! (array-ref instructions i) (ownership-test-op 0 6 (+ i 10)))
      (set! i (+ i 1)))
    (let
      [body : own.OwnershipBody
        (ownership-test-single instructions (ownership-test-return))]
      (match (own.ownership-check (& body) (own.OwnershipLimits 7 1000 1000))
        [(own.OwnershipResult.Err error)
          (and
            (= (ownership-test-kind-code (& error.kind)) 3)
            (= error.block 0))]
        [_ false]))))

(define (ownership-test-dump?) : bool
  (let
    [first : own.OwnershipBody (ownership-test-branch-body 3)]
    [second : own.OwnershipBody (ownership-test-branch-body 3)]
    (match (dump.ownership-dump (& first) (own.ownership-default-limits))
      [(dump.OwnershipDumpResult.Ok first-text)
        (match (dump.ownership-dump (& second) (own.ownership-default-limits))
          [(dump.OwnershipDumpResult.Ok second-text)
            (and
              (string.eq (& first-text) (& second-text))
              (string.contains (& first-text) "scope 0.11:0.3:0.2 entry=bb0")
              (string.contains (& first-text) "%p3 : %t0 = %l0 field %p2 0")
              (string.contains (& first-text) "branch %p6 bb1 bb2")
              (string.contains (& first-text) "consume %p3")
              (string.contains (& first-text) "expansion=13:fixture macro"))]
          [_ false])]
      [_ false])))

(define (ownership-test-shared-provenance-source) : own.OwnershipSource
  (own.OwnershipSource
    "shared-provenance/shared-provenance/shared-provenance/shared-provenance/shared-provenance/shared-provenance/shared-provenance/shared-provenance/shared-provenance/shared-provenance/shared-provenance/shared-provenance/shared-provenance/shared-provenance/shared-provenance/shared-provenance/shared-provenance/shared-provenance/shared-provenance/shared-provenance/shared-provenance/shared-provenance/shared-provenance/shared-provenance/shared-provenance/shared-provenance/shared-provenance/shared-provenance/shared-provenance/shared-provenance/"
    2
    3
    "shared expansion"))

(define (ownership-test-provenance-limit?) : bool
  (let
    [baseline : own.OwnershipBody
      (ownership-test-single
        (__tl_make-array own.OwnershipInstruction 0)
        (ownership-test-return))]
    [body : own.OwnershipBody
      (ownership-test-single
        (__tl_make-array own.OwnershipInstruction 0)
        (ownership-test-return))]
    [limits : own.OwnershipLimits (own.OwnershipLimits 1000 1000 1000)]
    ;; Repeated occurrences share the helper's static String storage. Each
    ;; occurrence expands independently in a dump and must consume budget.
    (set!
      (array-ref body.locals 0)
      (own.OwnershipLocal
        (ownership-test-type-id 3)
        true
        (ownership-test-shared-provenance-source)))
    (set!
      (array-ref body.locals 1)
      (own.OwnershipLocal
        (ownership-test-type-id 0)
        false
        (ownership-test-shared-provenance-source)))
    (and
      (match (own.ownership-check (& baseline) limits)
        [(own.OwnershipResult.Ok) true]
        [_ false])
      (match (own.ownership-check (& body) limits)
        [(own.OwnershipResult.Err error)
          (= (ownership-test-kind-code (& error.kind)) 3)]
        [_ false])
      (match (dump.ownership-dump (& body) limits)
        [(dump.OwnershipDumpResult.Err error)
          (= (ownership-test-kind-code (& error.kind)) 3)]
        [_ false]))))

(define (ownership-test-return-budget-body
  [operands : i64]
  [instructions : i64]) : own.OwnershipBody
  (let
    [uses : (__tl_dyn-array own.OwnershipPlaceId)
      (__tl_make-array own.OwnershipPlaceId operands)]
    [ops : (__tl_dyn-array own.OwnershipInstruction)
      (__tl_make-array own.OwnershipInstruction instructions)]
    [i : i64 0]
    (while (< i operands)
      (set! (array-ref uses i) (ownership-test-place-id 0))
      (set! i (+ i 1)))
    (set! i 0)
    (while (< i instructions)
      (set! (array-ref ops i) (ownership-test-op 0 0 10))
      (set! i (+ i 1)))
    (ownership-test-single
      ops
      (own.OwnershipTerminator.Return (own.OwnershipPlaceIds uses)))))

(define (ownership-test-result-resource? [result : own.OwnershipResult]) : bool
  (match result
    [(own.OwnershipResult.Err error)
      (= (ownership-test-kind-code (& error.kind)) 3)]
    [_ false]))

(define (ownership-test-return-budgets?) : bool
  (let
    [large : own.OwnershipBody (ownership-test-return-budget-body 1000 0)]
    [solver : own.OwnershipBody (ownership-test-return-cycle-body 700)]
    [validation-limit : own.OwnershipLimits
      (own.OwnershipLimits 2000 1000 1000)]
    [solver-work : i64 (ownership-test-validation-work (& solver) 2000)]
    (and
      (ownership-test-result-resource?
        (own.ownership-validate (& large) validation-limit))
      ;; The first return is visited before the backedge initializes shadow.
      ;; Its input then grows and the same retained operands must be checked
      ;; again. This measures actual revisits, not pessimistic subtree cost:
      ;; the budget that validates the body cannot also solve it.
      (> solver-work 0)
      (ownership-test-result-resource?
        (own.ownership-check
          (& solver)
          (own.OwnershipLimits 2000 1000 solver-work))))))

(define (ownership-test-return-cycle-body [operands : i64]) : own.OwnershipBody
  (let
    [uses : (__tl_dyn-array own.OwnershipPlaceId)
      (__tl_make-array own.OwnershipPlaceId operands)]
    [blocks : (__tl_dyn-array own.OwnershipBlock)
      (__tl_make-array own.OwnershipBlock 3)]
    [i : i64 0]
    (while (< i operands)
      (set! (array-ref uses i) (ownership-test-place-id 0))
      (set! i (+ i 1)))
    (set!
      (array-ref blocks 0)
      (ownership-test-block
        (__tl_make-array own.OwnershipInstruction 0)
        (own.OwnershipTerminator.Branch
          (ownership-test-place-id 6)
          (ownership-test-block-id 1)
          (ownership-test-block-id 2))))
    (set!
      (array-ref blocks 1)
      (ownership-test-block
        (__tl_make-array own.OwnershipInstruction 0)
        (own.OwnershipTerminator.Return (own.OwnershipPlaceIds uses))))
    (set!
      (array-ref blocks 2)
      (ownership-test-block
        (ownership-test-instructions1 (ownership-test-op 1 5 10))
        (own.OwnershipTerminator.Goto (ownership-test-block-id 0))))
    (ownership-test-body blocks)))

(define (ownership-test-unsupported-budget? [terminator? : bool]) : bool
  (let
    [reason : own.OwnershipSource (ownership-test-shared-provenance-source)]
    [body : own.OwnershipBody
      (ownership-test-single
        (if terminator?
          (__tl_make-array own.OwnershipInstruction 0)
          (ownership-test-instructions1
            (own.OwnershipInstruction
              (own.OwnershipOperation.Unsupported (string.copy (& reason.path)))
              (ownership-test-source 10))))
        (if terminator?
          (own.OwnershipTerminator.Unsupported (string.copy (& reason.path)))
          (ownership-test-return)))]
    [limits : own.OwnershipLimits (own.OwnershipLimits 1000 1000 700)]
    (and
      (ownership-test-result-resource? (own.ownership-validate (& body) limits))
      (match (dump.ownership-dump (& body) limits)
        [(dump.OwnershipDumpResult.Err error)
          (= (ownership-test-kind-code (& error.kind)) 3)]
        [_ false]))))

(define (ownership-test-move-validation-budget?) : bool
  (let
    [baseline : own.OwnershipBody
      (ownership-test-single
        (ownership-test-instructions1 (ownership-test-op 0 1 10))
        (ownership-test-return))]
    [body : own.OwnershipBody
      (ownership-test-single
        (ownership-test-instructions1
          (own.OwnershipInstruction
            (own.OwnershipOperation.Move
              (ownership-test-place-id 1)
              (ownership-test-place-id 5))
            (ownership-test-source 10)))
        (ownership-test-return))]
    [need : i64 (ownership-test-validation-work (& baseline) 1000)]
    ;; The move's operand chains (`ownership-overlap?`) cost validation work
    ;; beyond a plain operation's: the baseline's budget is not enough.
    (and
      (> need 0)
      (ownership-test-result-resource?
        (own.ownership-validate (& body) (own.OwnershipLimits 1000 1000 need)))
      (match (own.ownership-validate
        (& body)
        (own.OwnershipLimits 1000 1000 (+ need 1000)))
        [(own.OwnershipResult.Ok) true]
        [_ false]))))

;; The least work budget that validates `body`, or -1.
(define (ownership-test-validation-work
  [body : (& body own.OwnershipBody)]
  [nodes : i64]) : i64
  (let
    [limit : i64 1]
    [found : i64 -1]
    (while (and (< found 0) (< limit 100000))
      (begin
        (match (own.ownership-validate
          body
          (own.OwnershipLimits nodes 1000 limit))
          [(own.OwnershipResult.Ok) (set! found limit)]
          [_ unit])
        (set! limit (+ limit 1))))
    found))

(define (ownership-test-work-overflow?) : bool
  (let
    [work : i64 9223372036854775806]
    (and
      (own.ownership-charge! (&mut work) 9223372036854775807 1)
      (= work 9223372036854775807)
      (not (own.ownership-charge! (&mut work) 9223372036854775807 1))
      (= work 9223372036854775807))))

(define (ownership-test-variable-work?) : bool
  (and
    (ownership-test-return-budgets?)
    (ownership-test-unsupported-budget? false)
    (ownership-test-unsupported-budget? true)
    (ownership-test-move-validation-budget?)
    (ownership-test-work-overflow?)))

(define (ownership-test-dump-rejects?) : bool
  (let
    [body : own.OwnershipBody (ownership-test-malformed-body 1)]
    (match (dump.ownership-dump (& body) (own.ownership-default-limits))
      [(dump.OwnershipDumpResult.Err error)
        (= (ownership-test-kind-code (& error.kind)) 0)]
      [_ false])))

(define (ownership-test-dump-identities?) : bool
  (and
    (string.eq
      (dump.ownership-dump-identity-component (cast 4294967296 : u64))
      "1.0")
    (string.eq
      (dump.ownership-dump-identity-component (cast 18446744073709551615 : u64))
      "4294967295.4294967295")
    (let
      [source : own.OwnershipSource (own.OwnershipSource "a:\nb" 2 7 "x:y\nz")]
      (string.eq
        (dump.ownership-dump-source (& source))
        " @4:a:\nb:2:7 expansion=5:x:y\nz"))))

;; Interleaved siblings ensure the index follows projection identity rather
;; than assuming that the descendants of a place form a contiguous interval.
(define (ownership-test-wide-body [width : i64] [rounds : i64]) : own.OwnershipBody
  (let
    [types : (__tl_dyn-array own.OwnershipType)
      (__tl_make-array own.OwnershipType 2)]
    [fields : (__tl_dyn-array own.OwnershipTypeId)
      (__tl_make-array own.OwnershipTypeId width)]
    [locals : (__tl_dyn-array own.OwnershipLocal)
      (__tl_make-array own.OwnershipLocal 2)]
    [places : (__tl_dyn-array own.OwnershipPlace)
      (__tl_make-array own.OwnershipPlace (+ 2 (* 2 width)))]
    [instructions : (__tl_dyn-array own.OwnershipInstruction)
      (__tl_make-array own.OwnershipInstruction (* 4 rounds))]
    [i : i64 0]
    (while (< i width)
      (set! (array-ref fields i) (ownership-test-type-id 0))
      (set! (array-ref places (+ 2 (* 2 i))) (ownership-test-place 0 0 0 i))
      (set! (array-ref places (+ 3 (* 2 i))) (ownership-test-place 1 0 1 i))
      (set! i (+ i 1)))
    (set!
      (array-ref types 0)
      (own.OwnershipType own.OwnershipTypeKind.Scalar false))
    (set!
      (array-ref types 1)
      (own.OwnershipType
        (own.OwnershipTypeKind.Product (own.OwnershipTypeIds fields))
        false))
    (set! (array-ref locals 0) (ownership-test-local 1 true))
    (set! (array-ref locals 1) (ownership-test-local 1 true))
    (set! (array-ref places 0) (ownership-test-place 0 1 -1 0))
    (set! (array-ref places 1) (ownership-test-place 1 1 -1 0))
    (set! i 0)
    (while (< i rounds)
      (let
        [leaf : i64 (+ 2 (* 2 (% i width)))]
        [at : i64 (* 4 i)]
        (set! (array-ref instructions at) (ownership-test-op 3 leaf 10))
        (set! (array-ref instructions (+ at 1)) (ownership-test-op 0 1 11))
        (set! (array-ref instructions (+ at 2)) (ownership-test-op 1 leaf 12))
        (set! (array-ref instructions (+ at 3)) (ownership-test-op 0 0 13))
        (set! i (+ i 1))))
    (own.OwnershipBody
      (ownership-test-id)
      types
      locals
      places
      (__tl_make-array own.OwnershipLoan 0)
      (__tl_make-array own.OwnershipCleanup 0)
      (__tl_make-array own.OwnershipObligation 0)
      (__tl_make-array
        (ownership-test-block instructions (ownership-test-return)))
      (ownership-test-block-id 0))))

;; A thousand-level type/place chain exercises iterative ascent and descent.
(define (ownership-test-deep-body [depth : i64] [rounds : i64]) : own.OwnershipBody
  (let
    [types : (__tl_dyn-array own.OwnershipType)
      (__tl_make-array own.OwnershipType (+ depth 1))]
    [places : (__tl_dyn-array own.OwnershipPlace)
      (__tl_make-array own.OwnershipPlace (+ depth 1))]
    [instructions : (__tl_dyn-array own.OwnershipInstruction)
      (__tl_make-array own.OwnershipInstruction (* 3 rounds))]
    [i : i64 1]
    (set!
      (array-ref types 0)
      (own.OwnershipType own.OwnershipTypeKind.Scalar false))
    (while (<= i depth)
      (set!
        (array-ref types i)
        (own.OwnershipType
          (own.OwnershipTypeKind.Product
            (own.OwnershipTypeIds
              (__tl_make-array (ownership-test-type-id (- i 1)))))
          false))
      (set! i (+ i 1)))
    (set! i 0)
    (while (<= i depth)
      (set! (array-ref places i) (ownership-test-place 0 (- depth i) (- i 1) 0))
      (set! i (+ i 1)))
    (set! i 0)
    (while (< i rounds)
      (let
        [at : i64 (* 3 i)]
        (set! (array-ref instructions at) (ownership-test-op 3 depth 10))
        (set! (array-ref instructions (+ at 1)) (ownership-test-op 1 depth 11))
        (set! (array-ref instructions (+ at 2)) (ownership-test-op 0 0 12))
        (set! i (+ i 1))))
    (own.OwnershipBody
      (ownership-test-id)
      types
      (__tl_make-array (ownership-test-local depth true))
      places
      (__tl_make-array own.OwnershipLoan 0)
      (__tl_make-array own.OwnershipCleanup 0)
      (__tl_make-array own.OwnershipObligation 0)
      (__tl_make-array
        (ownership-test-block instructions (ownership-test-return)))
      (ownership-test-block-id 0))))

(define (ownership-test-index-visits?
  [body : (& body own.OwnershipBody)]
  [place : i64]
  [visits : i64]
  [root-state : i64]) : bool
  (let
    [index : own.OwnershipPlaceIndex (own.ownership-place-index body)]
    [state : (__tl_dyn-array i64)
      (own.ownership-state-row (array-length body.places) 2)]
    [work : i64 0]
    (unless
      (own.ownership-state-set!
        (& index)
        (&mut state)
        place
        1
        (&mut work)
        visits)
      (return false))
    (unless
      (and
        (= work visits)
        (= (own.ownership-state-get (& state) 0 0) root-state))
      (return false))
    (set! work 0)
    (and
      (not
        (own.ownership-state-set!
          (& index)
          (&mut state)
          place
          2
          (&mut work)
          (- visits 1)))
      (= work (- visits 1)))))

(define (ownership-test-place-scaling?) : bool
  (let
    [wide : own.OwnershipBody (ownership-test-wide-body 512 64)]
    [deep : own.OwnershipBody (ownership-test-deep-body 1024 32)]
    [limits : own.OwnershipLimits (own.OwnershipLimits 65536 16777216 1000000)]
    (and
      (match (own.ownership-check (& wide) limits)
        [(own.OwnershipResult.Ok) true]
        [_ false])
      (match (own.ownership-check (& deep) limits)
        [(own.OwnershipResult.Ok) true]
        [_ false])
      (ownership-test-index-visits? (& wide) 2 514 3)
      (ownership-test-index-visits? (& deep) 1024 2049 1)
      (ownership-test-index-visits? (& deep) 0 2049 1)
      (ownership-test-result-resource?
        (own.ownership-check
          (& wide)
          (own.OwnershipLimits 1025 16777216 1000000)))
      ;; The packed state rows are bounded exactly: one cell below the deep
      ;; body's need is a resource failure.
      (let
        [need : i64 (ownership-test-state-cell-need (& deep))]
        (and
          (> need 1)
          (ownership-test-result-resource?
            (own.ownership-check
              (& deep)
              (own.OwnershipLimits 65536 (- need 1) 1000000))))))))

;; The least state-cell budget that checks `body` (binary search; failure is
;; monotone in the budget), or -1.
(define (ownership-test-state-cell-need [body : (& body own.OwnershipBody)]) : i64
  (let
    [low : i64 1]
    [high : i64 16777216]
    (match (own.ownership-check body (own.OwnershipLimits 65536 high 1000000))
      [(own.OwnershipResult.Ok) unit]
      [_ (return -1)])
    (while (< low high)
      (let
        [middle : i64 (/ (+ low high) 2)]
        (match (own.ownership-check
          body
          (own.OwnershipLimits 65536 middle 1000000))
          [(own.OwnershipResult.Ok) (set! high middle)]
          [_ (set! low (+ middle 1))])))
    low))

(define (ownership-test-fresh-initialization?) : bool
  (let
    [joined : own.OwnershipBody (ownership-test-branch-body 0)]
    (set!
      (array-ref (array-ref joined.blocks 3).instructions 0)
      (own.OwnershipInstruction
        (own.OwnershipOperation.Initialize (ownership-test-place-id 3))
        (ownership-test-source 20)))
    (and
      (ownership-test-ok?
        (ownership-test-single
          (__tl_make-array
            (own.OwnershipInstruction
              (own.OwnershipOperation.Initialize (ownership-test-place-id 5))
              (ownership-test-source 10)))
          (ownership-test-return-place 5)))
      (ownership-test-error?
        (ownership-test-single
          (__tl_make-array
            (own.OwnershipInstruction
              (own.OwnershipOperation.Initialize (ownership-test-place-id 3))
              (ownership-test-source 10)))
          (ownership-test-return))
        5
        0
        0
        3)
      (ownership-test-ok?
        (ownership-test-single
          (__tl_make-array
            (ownership-test-op 2 3 10)
            (own.OwnershipInstruction
              (own.OwnershipOperation.Initialize (ownership-test-place-id 3))
              (ownership-test-source 11)))
          (ownership-test-return-place 0)))
      (ownership-test-error? joined 5 3 0 3))))

(define (compiler-ownership-core-self-test) : i64
  (unless (ownership-test-place-transfers?) (return 1))
  (unless (ownership-test-branches?) (return 2))
  (unless (ownership-test-loops?) (return 3))
  (unless (ownership-test-explicit-transfers?) (return 4))
  (unless (ownership-test-malformed?) (return 5))
  (unless (ownership-test-limits?) (return 6))
  (unless (ownership-test-dump?) (return 7))
  (unless (ownership-test-dump-rejects?) (return 8))
  (unless (ownership-test-dump-identities?) (return 9))
  (unless (ownership-test-copy-transfer? false) (return 10))
  (unless (ownership-test-copy-transfer? true) (return 11))
  (unless (ownership-test-instruction-limit?) (return 12))
  (unless (ownership-test-provenance-limit?) (return 13))
  (unless (ownership-test-variable-work?) (return 14))
  (unless (ownership-test-place-scaling?) (return 15))
  (unless (ownership-test-fresh-initialization?) (return 16))
  42)

(test
  ownership-core-nested-places
  (test.assert-true
    (and
      (ownership-test-place-transfers?)
      (ownership-test-fresh-initialization?)
      (ownership-test-explicit-transfers?)
      (ownership-test-copy-transfer? false)
      (ownership-test-copy-transfer? true))
    "partial moves, disjoint storage, exact repair and Copy transfers"))

(test
  ownership-core-control-flow
  (test.assert-true
    (and (ownership-test-branches?) (ownership-test-loops?))
    "all reachable predecessors, backedges and distinct exit obligations"))

(test
  ownership-core-malformed
  (test.assert-true
    (ownership-test-malformed?)
    "typed identities and complete place forests reject malformed graphs"))

(test
  ownership-core-resource-limits
  (test.assert-true
    (and
      (ownership-test-limits?)
      (ownership-test-instruction-limit?)
      (ownership-test-provenance-limit?)
      (ownership-test-variable-work?))
    "analysis limits report resource failure"))

(test
  ownership-core-place-scaling
  (test.assert-true
    (ownership-test-place-scaling?)
    "wide interleaved and deep forests charge visited nodes and retain hard limits"))

(test
  ownership-core-dumps
  (test.assert-true
    (and
      (ownership-test-dump?)
      (ownership-test-dump-rejects?)
      (ownership-test-dump-identities?))
    "dumps validate graphs and retain deterministic identities and origins"))