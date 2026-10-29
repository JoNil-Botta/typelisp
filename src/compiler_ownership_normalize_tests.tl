(import compiler_ownership_normalize as norm)
(import compiler_typed_occurrence as typed)
(import compiler_typed_occurrence_tests as fixture)
(import compiler_ownership_core as own)
(import compiler_ownership_dump as dump)
(import compiler_ast_types as ast)
(import compiler_intern as ci)
(import stdlib.test)
(import stdlib.io)
(import stdlib.str_cat_runtime as str_cat)
(import stdlib.string)

(define (normalize-test-node!
  [store : (&mut store typed.TypedStore)]
  [lease : (& lease (typed.TypedBodyLease intern))]
  [type : typed.TypedTypeId]
  [origin : typed.TypedOriginId]
  [operation : typed.TypedOperation]
  [children : (__tl_dyn-array typed.TypedOccurrenceId)]) : typed.TypedOccurrenceId
  (match (typed.typed-occurrence-add!
    store
    lease
    type
    typed.TypedSyntax.Generated
    origin
    operation
    (& children))
    [(typed.TypedOccurrenceResult.Ok id) id]
    [(typed.TypedOccurrenceResult.Err _) (io.panic "normalize fixture node")]))

(define (normalize-test-binder!
  [store : (&mut store typed.TypedStore)]
  [lease : (& lease (typed.TypedBodyLease intern))]
  [type : typed.TypedTypeId]
  [origin : typed.TypedOriginId]
  [parameter? : bool]) : typed.TypedBinderId
  (match (typed.typed-binder-add!
    store
    lease
    type
    (if parameter?
      typed.TypedBinderKind.Parameter
      typed.TypedBinderKind.Local)
    origin
    -1)
    [(typed.TypedBinderResult.Ok id) id]
    [(typed.TypedBinderResult.Err _) (io.panic "normalize fixture binder")]))

(define (normalize-test-empty) : (__tl_dyn-array typed.TypedOccurrenceId)
  (__tl_make-array typed.TypedOccurrenceId 0))

(define (normalize-test-one [node : typed.TypedOccurrenceId]) : (__tl_dyn-array
    typed.TypedOccurrenceId)
  (let
    [children : (__tl_dyn-array typed.TypedOccurrenceId) (normalize-test-empty)]
    (__tl_array-push! children node)
    children))

(define (normalize-test-primitive? [mode : i64]) : bool
  (let
    [intern-state : ci.InternCompatState
      (ci.intern-compat-state-capture-active)]
    [lease : (typed.TypedBodyLease intern-state)
      (fixture.typed-test-lease (& intern-state) (cast (+ 101 mode) : u64))]
    [store : typed.TypedStore (fixture.typed-test-store (& lease))]
    [origin : typed.TypedOriginId
      (fixture.typed-test-origin! (&mut store) (& lease))]
    [i64-type : typed.TypedTypeId
      (fixture.typed-test-type! (&mut store) (& lease) ast.AstType.I64)]
    [u64-type : typed.TypedTypeId
      (fixture.typed-test-type! (&mut store) (& lease) ast.AstType.U64)]
    [bool-type : typed.TypedTypeId
      (fixture.typed-test-type! (&mut store) (& lease) ast.AstType.Bool)]
    [left : typed.TypedOccurrenceId
      (fixture.typed-test-literal!
        (&mut store)
        (& lease)
        (if (= mode 5)
          bool-type
          i64-type)
        origin
        typed.TypedSyntax.Generated
        21)]
    [right : typed.TypedOccurrenceId
      (fixture.typed-test-literal!
        (&mut store)
        (& lease)
        (if (= mode 3)
          u64-type
          i64-type)
        origin
        typed.TypedSyntax.Generated
        21)]
    [root : typed.TypedOccurrenceId
      (normalize-test-node!
        (&mut store)
        (& lease)
        i64-type
        origin
        (typed.TypedOperation.Binary
          (if (= mode 1)
            ast.AstBinOp.Eq
            ast.AstBinOp.Add))
        (fixture.typed-test-children2
          left
          (if (= mode 2)
            left
            right)))]
    [limits : norm.OwnershipNormalizeLimits
      (norm.ownership-normalize-default-limits)]
    (cond
      [(= mode 6) (set! limits.depth 1)]
      [(= mode 7) (set! limits.records 32)]
      [(= mode 8) (set! limits.work 32)]
      [(= mode 9) (set! limits.source-bytes 1)]
      [(= mode 10) (typed.typed-store-retire! (&mut store))]
      [(= mode 11)
        (set! (array-ref store.occurrences root.handle.index).child-count 1)]
      [else unit])
    (match (norm.ownership-normalize!
      (&mut store)
      (& lease)
      root
      (if (= mode 4)
        bool-type
        i64-type)
      (__tl_make-array norm.OwnershipNormalizeTypeClass 0)
      limits)
      [(norm.OwnershipNormalizeResult.Ok output)
        (if (not (= mode 0))
          false
          (let
            [first : String
              (match (dump.ownership-dump
                (& output.body)
                (own.ownership-default-limits))
                [(dump.OwnershipDumpResult.Ok text) text]
                [_ (io.panic "normalize dump")])]
            ;; The normalized body owns its strings and no selected handle
            ;; is dereferenced after retirement, including diagnostic provenance.
            (set! (array-ref store.origins 0).source.path "retired-source.tl")
            (typed.typed-store-retire! (&mut store))
            (and
              ;; Primitive codes and the reserved Never slot; no value
              ;; class was needed.
              (=
                (array-length output.body.types)
                norm.normalize-first-value-type)
              (= (array-ref output.body.locals 0).type.index 5)
              (match (dump.ownership-dump
                (& output.body)
                (own.ownership-default-limits))
                [(dump.OwnershipDumpResult.Ok again) (string.eq first again)]
                [_ false]))))]
      [(norm.OwnershipNormalizeResult.Err failure)
        (match failure
          [(norm.OwnershipNormalizeFailure.Structural _)
            (or (and (>= mode 1) (<= mode 5)) (= mode 11))]
          [(norm.OwnershipNormalizeFailure.Resource)
            (and (>= mode 6) (<= mode 9))]
          [(norm.OwnershipNormalizeFailure.Typed error)
            (match error
              [(typed.TypedError.Lease) (= mode 10)]
              [_ false])]
          [_ false])])))

;; A conditional RHS is the only initializer of x. Reading x afterwards must
;; fail; eager normalization would incorrectly certify this body. Shadow's
;; independently initialized binder must not initialize x despite identical
;; primitive type and provenance.
(define (normalize-test-short? [and? : bool]) : bool
  (let
    [intern-state : ci.InternCompatState
      (ci.intern-compat-state-capture-active)]
    [lease : (typed.TypedBodyLease intern-state)
      (fixture.typed-test-lease (& intern-state) (cast 201 : u64))]
    [store : typed.TypedStore (fixture.typed-test-store (& lease))]
    [origin : typed.TypedOriginId
      (fixture.typed-test-origin! (&mut store) (& lease))]
    [int-type : typed.TypedTypeId
      (fixture.typed-test-type! (&mut store) (& lease) ast.AstType.I64)]
    [bool-type : typed.TypedTypeId
      (fixture.typed-test-type! (&mut store) (& lease) ast.AstType.Bool)]
    [unit-type : typed.TypedTypeId
      (fixture.typed-test-type! (&mut store) (& lease) ast.AstType.Unit)]
    [flag : typed.TypedBinderId
      (normalize-test-binder! (&mut store) (& lease) bool-type origin true)]
    [x : typed.TypedBinderId
      (normalize-test-binder! (&mut store) (& lease) int-type origin false)]
    [shadow : typed.TypedBinderId
      (normalize-test-binder! (&mut store) (& lease) int-type origin true)]
    [condition : typed.TypedOccurrenceId
      (normalize-test-node!
        (&mut store)
        (& lease)
        bool-type
        origin
        (typed.TypedOperation.Read flag)
        (normalize-test-empty))]
    [value : typed.TypedOccurrenceId
      (fixture.typed-test-literal!
        (&mut store)
        (& lease)
        int-type
        origin
        typed.TypedSyntax.Generated
        42)]
    [init : typed.TypedOccurrenceId
      (normalize-test-node!
        (&mut store)
        (& lease)
        unit-type
        origin
        (typed.TypedOperation.Initialize x)
        (normalize-test-one value))]
    [boolean : typed.TypedOccurrenceId
      (normalize-test-node!
        (&mut store)
        (& lease)
        bool-type
        origin
        (typed.TypedOperation.Literal (ast.AstLiteral.Bool true))
        (normalize-test-empty))]
    [right : typed.TypedOccurrenceId
      (normalize-test-node!
        (&mut store)
        (& lease)
        bool-type
        origin
        typed.TypedOperation.Sequence
        (fixture.typed-test-children2 init boolean))]
    [binary : typed.TypedOccurrenceId
      (normalize-test-node!
        (&mut store)
        (& lease)
        bool-type
        origin
        (typed.TypedOperation.Binary
          (if and?
            ast.AstBinOp.And
            ast.AstBinOp.Or))
        (fixture.typed-test-children2 condition right))]
    [read-shadow : typed.TypedOccurrenceId
      (normalize-test-node!
        (&mut store)
        (& lease)
        int-type
        origin
        (typed.TypedOperation.Read shadow)
        (normalize-test-empty))]
    [read : typed.TypedOccurrenceId
      (normalize-test-node!
        (&mut store)
        (& lease)
        int-type
        origin
        (typed.TypedOperation.Read x)
        (normalize-test-empty))]
    [children : (__tl_dyn-array typed.TypedOccurrenceId)
      (__tl_make-array binary read-shadow read)]
    [root : typed.TypedOccurrenceId
      (normalize-test-node!
        (&mut store)
        (& lease)
        int-type
        origin
        typed.TypedOperation.Sequence
        children)]
    (match (norm.ownership-normalize!
      (&mut store)
      (& lease)
      root
      int-type
      (__tl_make-array norm.OwnershipNormalizeTypeClass 0)
      (norm.ownership-normalize-default-limits))
      [(norm.OwnershipNormalizeResult.Err
          (norm.OwnershipNormalizeFailure.Core failure))
        (match (& failure.kind)
          [(own.OwnershipFailureKind.Uninitialized) true]
          [_ false])]
      [_ false])))

(define (normalize-test-return?) : bool
  (let
    [intern-state : ci.InternCompatState
      (ci.intern-compat-state-capture-active)]
    [lease : (typed.TypedBodyLease intern-state)
      (fixture.typed-test-lease (& intern-state) (cast 301 : u64))]
    [store : typed.TypedStore (fixture.typed-test-store (& lease))]
    [origin : typed.TypedOriginId
      (fixture.typed-test-origin! (&mut store) (& lease))]
    [int-type : typed.TypedTypeId
      (fixture.typed-test-type! (&mut store) (& lease) ast.AstType.I64)]
    [bool-type : typed.TypedTypeId
      (fixture.typed-test-type! (&mut store) (& lease) ast.AstType.Bool)]
    [never-type : typed.TypedTypeId
      (fixture.typed-test-type! (&mut store) (& lease) ast.AstType.Never)]
    [condition : typed.TypedOccurrenceId
      (normalize-test-node!
        (&mut store)
        (& lease)
        bool-type
        origin
        (typed.TypedOperation.Literal (ast.AstLiteral.Bool true))
        (normalize-test-empty))]
    [left : typed.TypedOccurrenceId
      (fixture.typed-test-literal!
        (&mut store)
        (& lease)
        int-type
        origin
        typed.TypedSyntax.Generated
        42)]
    [returned : typed.TypedOccurrenceId
      (normalize-test-node!
        (&mut store)
        (& lease)
        never-type
        origin
        typed.TypedOperation.Return
        (normalize-test-one left))]
    [right : typed.TypedOccurrenceId
      (fixture.typed-test-literal!
        (&mut store)
        (& lease)
        int-type
        origin
        typed.TypedSyntax.Generated
        17)]
    [root : typed.TypedOccurrenceId
      (normalize-test-node!
        (&mut store)
        (& lease)
        int-type
        origin
        typed.TypedOperation.If
        (__tl_make-array condition returned right))]
    (match (norm.ownership-normalize!
      (&mut store)
      (& lease)
      root
      int-type
      (__tl_make-array norm.OwnershipNormalizeTypeClass 0)
      (norm.ownership-normalize-default-limits))
      [(norm.OwnershipNormalizeResult.Ok output)
        (let
          [index : i64 0]
          [returns : i64 0]
          (while (< index (array-length output.body.blocks))
            (begin
              (match (& (array-ref output.body.blocks index).terminator)
                [(own.OwnershipTerminator.Return _)
                  (set! returns (+ returns 1))]
                [_ unit])
              (set! index (+ index 1))))
          (= returns 2))]
      [_ false])))

;; Opaque value classes through declared calls (#8449). Mode 0 moves a
;; move-only parameter into two calls: the second read is a named use of a moved
;; value whose move is the first call. Mode 1 classifies the same type as Copy
;; and certifies. Mode 2 leaves the type unclassified, which stays outside the
;; normalized subset. Mode 3 moves inside a loop body: the move reaches itself.
(define (normalize-test-call-moves? [mode : i64]) : bool
  (let
    [intern-state : ci.InternCompatState
      (ci.intern-compat-state-capture-active)]
    [lease : (typed.TypedBodyLease intern-state)
      (fixture.typed-test-lease (& intern-state) (cast (+ 701 mode) : u64))]
    [store : typed.TypedStore (fixture.typed-test-store (& lease))]
    [origin : typed.TypedOriginId
      (fixture.typed-test-origin! (&mut store) (& lease))]
    [int-type : typed.TypedTypeId
      (fixture.typed-test-type! (&mut store) (& lease) ast.AstType.I64)]
    [unit-type : typed.TypedTypeId
      (fixture.typed-test-type! (&mut store) (& lease) ast.AstType.Unit)]
    [bool-type : typed.TypedTypeId
      (fixture.typed-test-type! (&mut store) (& lease) ast.AstType.Bool)]
    [text-type : typed.TypedTypeId
      (fixture.typed-test-type! (&mut store) (& lease) ast.AstType.String)]
    [params : ast.AstTypeList (ast.ast-type-list-new)]
    [_param : unit
      (ast.ast-type-list-push
        (&mut params)
        (ast.ty-node-push (& (ast.AstType.String))))]
    [signature : typed.TypedTypeId
      (fixture.typed-test-type!
        (&mut store)
        (& lease)
        (ast.ast-ty-func
          params
          (& (ast.AstType.I64))
          (ast.AstCallableBinders.Resolved (ast.ast-lifetime-list-new))))]
    [text : typed.TypedBinderId
      (match (typed.typed-binder-add!
        (&mut store)
        (& lease)
        text-type
        typed.TypedBinderKind.Parameter
        origin
        77)
        [(typed.TypedBinderResult.Ok id) id]
        [(typed.TypedBinderResult.Err _)
          (io.panic "normalize fixture text binder")])]
    [first-call : typed.TypedCallId
      (match (typed.typed-call-add!
        (&mut store)
        (& lease)
        signature
        (typed.TypedCallKind.Declared 5)
        1)
        [(typed.TypedCallResult.Ok id) id]
        [_ (io.panic "normalize fixture call")])]
    [second-call : typed.TypedCallId
      (match (typed.typed-call-add!
        (&mut store)
        (& lease)
        signature
        (typed.TypedCallKind.Declared 5)
        1)
        [(typed.TypedCallResult.Ok id) id]
        [_ (io.panic "normalize fixture call")])]
    [first-read : typed.TypedOccurrenceId
      (normalize-test-node!
        (&mut store)
        (& lease)
        text-type
        origin
        (typed.TypedOperation.Read text)
        (normalize-test-empty))]
    [first : typed.TypedOccurrenceId
      (normalize-test-node!
        (&mut store)
        (& lease)
        int-type
        origin
        (typed.TypedOperation.Call first-call)
        (normalize-test-one first-read))]
    [root : typed.TypedOccurrenceId
      (if (= mode 3)
        (let
          [condition : typed.TypedOccurrenceId
            (normalize-test-node!
              (&mut store)
              (& lease)
              bool-type
              origin
              (typed.TypedOperation.Literal (ast.AstLiteral.Bool true))
              (normalize-test-empty))]
          [done : typed.TypedOccurrenceId
            (normalize-test-node!
              (&mut store)
              (& lease)
              unit-type
              origin
              (typed.TypedOperation.Literal ast.AstLiteral.Unit)
              (normalize-test-empty))]
          [body : typed.TypedOccurrenceId
            (normalize-test-node!
              (&mut store)
              (& lease)
              unit-type
              origin
              typed.TypedOperation.Sequence
              (fixture.typed-test-children2 first done))]
          (normalize-test-node!
            (&mut store)
            (& lease)
            unit-type
            origin
            typed.TypedOperation.While
            (fixture.typed-test-children2 condition body)))
        (let
          [second-read : typed.TypedOccurrenceId
            (normalize-test-node!
              (&mut store)
              (& lease)
              text-type
              origin
              (typed.TypedOperation.Read text)
              (normalize-test-empty))]
          [second : typed.TypedOccurrenceId
            (normalize-test-node!
              (&mut store)
              (& lease)
              int-type
              origin
              (typed.TypedOperation.Call second-call)
              (normalize-test-one second-read))]
          (normalize-test-node!
            (&mut store)
            (& lease)
            int-type
            origin
            (typed.TypedOperation.Binary ast.AstBinOp.Add)
            (fixture.typed-test-children2 first second))))]
    [classes : (__tl_dyn-array norm.OwnershipNormalizeTypeClass)
      (__tl_make-array norm.OwnershipNormalizeTypeClass 0)]
    [index : i64 0]
    (when
      (!= mode 2)
      (while (<= index text-type.handle.index)
        (begin
          (__tl_array-push!
            classes
            (if (= index text-type.handle.index)
              (norm.OwnershipNormalizeTypeClass 0 (= mode 1) 0 -1 false)
              (norm.OwnershipNormalizeTypeClass -1 true 0 -1 false)))
          (set! index (+ index 1)))))
    (match (norm.ownership-normalize!
      (&mut store)
      (& lease)
      root
      (if (= mode 3)
        unit-type
        int-type)
      classes
      (norm.ownership-normalize-default-limits))
      [(norm.OwnershipNormalizeResult.Ok _) (= mode 1)]
      [(norm.OwnershipNormalizeResult.Err failure)
        (match failure
          [(norm.OwnershipNormalizeFailure.Moved core diagnostic)
            (and
              (or (= mode 0) (= mode 3))
              (= diagnostic.name 77)
              (= diagnostic.loop-carried? (= mode 3))
              (match (& core.kind)
                [(own.OwnershipFailureKind.Uninitialized) true]
                [_ false]))]
          [(norm.OwnershipNormalizeFailure.Unsupported _) (= mode 2)]
          [_ false])])))

;; References: a parameter `text` (name 77) with shared and mutable borrows
;; passed to calls. Mode 0 moves `text` while an earlier argument's shared
;; loan waits for its call; 1 ends that loan at its call before the move; 2 is
;; a two-phase mutable argument followed by a shared borrow for a nested call;
;; 3 moves the reserved place; 4 passes two mutable borrows of it to one call.
(define (normalize-test-borrow!
  [store : (&mut store typed.TypedStore)]
  [lease : (& lease (typed.TypedBodyLease intern))]
  [origin : typed.TypedOriginId]
  [text-type : typed.TypedTypeId]
  [place : typed.TypedPlaceId]
  [reference-type : typed.TypedTypeId]
  [mutable? : bool]) : typed.TypedOccurrenceId
  (let
    [formation : typed.TypedOccurrenceId
      (normalize-test-node!
        store
        lease
        text-type
        (typed.TypedOriginId (typed.typed-handle-copy (& origin.handle)))
        (typed.TypedOperation.FormPlace place)
        (normalize-test-empty))]
    (normalize-test-node!
      store
      lease
      reference-type
      origin
      (typed.TypedOperation.Borrow mutable?)
      (normalize-test-one formation))))

(define (normalize-test-call!
  [store : (&mut store typed.TypedStore)]
  [lease : (& lease (typed.TypedBodyLease intern))]
  [origin : typed.TypedOriginId]
  [signature : typed.TypedTypeId]
  [int-type : typed.TypedTypeId]
  [key : i64]
  [arguments : (__tl_dyn-array typed.TypedOccurrenceId)]) : typed.TypedOccurrenceId
  (let
    [record : typed.TypedCallId
      (match (typed.typed-call-add!
        store
        lease
        signature
        (typed.TypedCallKind.Declared key)
        (array-length arguments))
        [(typed.TypedCallResult.Ok id) id]
        [_ (io.panic "normalize fixture call")])]
    (normalize-test-node!
      store
      lease
      int-type
      origin
      (typed.TypedOperation.Call record)
      arguments)))

(define (normalize-test-references? [mode : i64]) : bool
  (let
    [intern-state : ci.InternCompatState
      (ci.intern-compat-state-capture-active)]
    [lease : (typed.TypedBodyLease intern-state)
      (fixture.typed-test-lease (& intern-state) (cast (+ 801 mode) : u64))]
    [store : typed.TypedStore (fixture.typed-test-store (& lease))]
    [origin : typed.TypedOriginId
      (fixture.typed-test-origin! (&mut store) (& lease))]
    [int-type : typed.TypedTypeId
      (fixture.typed-test-type! (&mut store) (& lease) ast.AstType.I64)]
    [text-type : typed.TypedTypeId
      (fixture.typed-test-type! (&mut store) (& lease) ast.AstType.String)]
    [shared-type : typed.TypedTypeId
      (fixture.typed-test-type!
        (&mut store)
        (& lease)
        (ast.ast-ty-ref 1 (& (ast.AstType.String))))]
    [mutable-type : typed.TypedTypeId
      (fixture.typed-test-type!
        (&mut store)
        (& lease)
        (ast.AstType.MutRef
          1
          (ast.ast-node-pool-reader-type-push (& (ast.AstType.String)))))]
    ;; Call records only need arity; the normalizer types arguments itself.
    [one-params : ast.AstTypeList (ast.ast-type-list-new)]
    [two-params : ast.AstTypeList (ast.ast-type-list-new)]
    [_params : unit
      (begin
        (ast.ast-type-list-push
          (&mut one-params)
          (ast.ty-node-push (& (ast.AstType.I64))))
        (ast.ast-type-list-push
          (&mut two-params)
          (ast.ty-node-push (& (ast.AstType.I64))))
        (ast.ast-type-list-push
          (&mut two-params)
          (ast.ty-node-push (& (ast.AstType.I64)))))]
    [unary : typed.TypedTypeId
      (fixture.typed-test-type!
        (&mut store)
        (& lease)
        (ast.ast-ty-func
          one-params
          (& (ast.AstType.I64))
          (ast.AstCallableBinders.Resolved (ast.ast-lifetime-list-new))))]
    [signature : typed.TypedTypeId
      (fixture.typed-test-type!
        (&mut store)
        (& lease)
        (ast.ast-ty-func
          two-params
          (& (ast.AstType.I64))
          (ast.AstCallableBinders.Resolved (ast.ast-lifetime-list-new))))]
    [text : typed.TypedBinderId
      (match (typed.typed-binder-add!
        (&mut store)
        (& lease)
        (typed.TypedTypeId (typed.typed-handle-copy (& text-type.handle)))
        typed.TypedBinderKind.Parameter
        (typed.TypedOriginId (typed.typed-handle-copy (& origin.handle)))
        77)
        [(typed.TypedBinderResult.Ok id) id]
        [(typed.TypedBinderResult.Err _)
          (io.panic "normalize fixture text binder")])]
    [place : typed.TypedPlaceId
      (match (typed.typed-place-add!
        (&mut store)
        (& lease)
        (typed.TypedPlaceKind.Root text))
        [(typed.TypedPlaceResult.Ok id) id]
        [_ (io.panic "normalize fixture place")])]
    [first : typed.TypedOccurrenceId
      (normalize-test-borrow!
        (&mut store)
        (& lease)
        (typed.TypedOriginId (typed.typed-handle-copy (& origin.handle)))
        (typed.TypedTypeId (typed.typed-handle-copy (& text-type.handle)))
        (typed.TypedPlaceId (typed.typed-handle-copy (& place.handle)))
        (if (or (= mode 0) (= mode 1))
          (typed.TypedTypeId (typed.typed-handle-copy (& shared-type.handle)))
          (typed.TypedTypeId (typed.typed-handle-copy (& mutable-type.handle))))
        (>= mode 2))]
    ;; The second argument's own operand: a shared borrow (mode 2) or a read.
    [operand : typed.TypedOccurrenceId
      (if (= mode 2)
        (normalize-test-borrow!
          (&mut store)
          (& lease)
          (typed.TypedOriginId (typed.typed-handle-copy (& origin.handle)))
          (typed.TypedTypeId (typed.typed-handle-copy (& text-type.handle)))
          (typed.TypedPlaceId (typed.typed-handle-copy (& place.handle)))
          (typed.TypedTypeId (typed.typed-handle-copy (& shared-type.handle)))
          false)
        (normalize-test-node!
          (&mut store)
          (& lease)
          (typed.TypedTypeId (typed.typed-handle-copy (& text-type.handle)))
          (typed.TypedOriginId (typed.typed-handle-copy (& origin.handle)))
          (typed.TypedOperation.Read text)
          (normalize-test-empty)))]
    [second : typed.TypedOccurrenceId
      (if (= mode 4)
        (normalize-test-borrow!
          (&mut store)
          (& lease)
          (typed.TypedOriginId (typed.typed-handle-copy (& origin.handle)))
          (typed.TypedTypeId (typed.typed-handle-copy (& text-type.handle)))
          (typed.TypedPlaceId (typed.typed-handle-copy (& place.handle)))
          (typed.TypedTypeId (typed.typed-handle-copy (& mutable-type.handle)))
          true)
        (normalize-test-call!
          (&mut store)
          (& lease)
          (typed.TypedOriginId (typed.typed-handle-copy (& origin.handle)))
          (typed.TypedTypeId (typed.typed-handle-copy (& unary.handle)))
          (typed.TypedTypeId (typed.typed-handle-copy (& int-type.handle)))
          3
          (normalize-test-one operand)))]
    [root : typed.TypedOccurrenceId
      (if (= mode 1)
        (let
          [peek : typed.TypedOccurrenceId
            (normalize-test-call!
              (&mut store)
              (& lease)
              (typed.TypedOriginId (typed.typed-handle-copy (& origin.handle)))
              (typed.TypedTypeId (typed.typed-handle-copy (& unary.handle)))
              (typed.TypedTypeId (typed.typed-handle-copy (& int-type.handle)))
              4
              (normalize-test-one first))]
          (normalize-test-node!
            (&mut store)
            (& lease)
            (typed.TypedTypeId (typed.typed-handle-copy (& int-type.handle)))
            (typed.TypedOriginId (typed.typed-handle-copy (& origin.handle)))
            (typed.TypedOperation.Binary ast.AstBinOp.Add)
            (fixture.typed-test-children2 peek second)))
        (normalize-test-call!
          (&mut store)
          (& lease)
          (typed.TypedOriginId (typed.typed-handle-copy (& origin.handle)))
          (typed.TypedTypeId (typed.typed-handle-copy (& signature.handle)))
          (typed.TypedTypeId (typed.typed-handle-copy (& int-type.handle)))
          5
          (fixture.typed-test-children2 first second)))]
    [classes : (__tl_dyn-array norm.OwnershipNormalizeTypeClass)
      (__tl_make-array norm.OwnershipNormalizeTypeClass 0)]
    [index : i64 0]
    (while (<= index signature.handle.index)
      (let
        [class : norm.OwnershipNormalizeTypeClass
          (norm.OwnershipNormalizeTypeClass -1 true 0 -1 false)]
        (when
          (= index text-type.handle.index)
          (set! class (norm.OwnershipNormalizeTypeClass 0 false 0 -1 false)))
        (when
          (= index shared-type.handle.index)
          (set! class (norm.OwnershipNormalizeTypeClass 1 true 1 -1 false)))
        (when
          (= index mutable-type.handle.index)
          (set! class (norm.OwnershipNormalizeTypeClass 2 false 2 -1 false)))
        (__tl_array-push! classes class)
        (set! index (+ index 1))))
    (match (norm.ownership-normalize!
      (&mut store)
      (& lease)
      root
      int-type
      classes
      (norm.ownership-normalize-default-limits))
      [(norm.OwnershipNormalizeResult.Ok _) (or (= mode 1) (= mode 2))]
      [(norm.OwnershipNormalizeResult.Err failure)
        (match failure
          [(norm.OwnershipNormalizeFailure.Borrowed _ diagnostic)
            (and
              (= diagnostic.name 77)
              (or
                (and (or (= mode 0) (= mode 3)) (= diagnostic.access 1))
                (and (= mode 4) (= diagnostic.access 2))))]
          [_ false])])))

;; Places: a parameter `pair` (name 77) of a tuple (String i64) projected by
;; field. Mode 0 moves field 0 then reads the pair whole, which fails naming
;; `pair` with no field path; mode 1 moves field 0 then copies field 1, which
;; is a separate place; mode 2 moves field 0 twice, failing at field 0.
(define (normalize-test-field!
  [store : (&mut store typed.TypedStore)]
  [lease : (& lease (typed.TypedBodyLease intern))]
  [origin : typed.TypedOriginId]
  [root : typed.TypedPlaceId]
  [container : typed.TypedTypeId]
  [result : typed.TypedTypeId]
  [ordinal : i64]
  [move? : bool]) : typed.TypedOccurrenceId
  (let
    [projection : typed.TypedProjectionId
      (match (typed.typed-projection-add!
        store
        lease
        container
        (typed.TypedTypeId (typed.typed-handle-copy (& result.handle)))
        (typed.TypedProjectionKind.TupleElement ordinal)
        (typed.TypedOriginId (typed.typed-handle-copy (& origin.handle))))
        [(typed.TypedProjectionResult.Ok id) id]
        [_ (io.panic "normalize fixture projection")])]
    [place : typed.TypedPlaceId
      (match (typed.typed-place-add!
        store
        lease
        (typed.TypedPlaceKind.Projection root projection))
        [(typed.TypedPlaceResult.Ok id) id]
        [_ (io.panic "normalize fixture field place")])]
    [formation : typed.TypedOccurrenceId
      (normalize-test-node!
        store
        lease
        (typed.TypedTypeId (typed.typed-handle-copy (& result.handle)))
        (typed.TypedOriginId (typed.typed-handle-copy (& origin.handle)))
        (typed.TypedOperation.FormPlace
          (typed.TypedPlaceId (typed.typed-handle-copy (& place.handle))))
        (normalize-test-empty))]
    (normalize-test-node!
      store
      lease
      result
      origin
      (if move?
        (typed.TypedOperation.MovePlace place)
        (typed.TypedOperation.CopyPlace place))
      (normalize-test-one formation))))

(define (normalize-test-fields? [mode : i64]) : bool
  (let
    [intern-state : ci.InternCompatState
      (ci.intern-compat-state-capture-active)]
    [lease : (typed.TypedBodyLease intern-state)
      (fixture.typed-test-lease (& intern-state) (cast (+ 851 mode) : u64))]
    [store : typed.TypedStore (fixture.typed-test-store (& lease))]
    [origin : typed.TypedOriginId
      (fixture.typed-test-origin! (&mut store) (& lease))]
    [int-type : typed.TypedTypeId
      (fixture.typed-test-type! (&mut store) (& lease) ast.AstType.I64)]
    [text-type : typed.TypedTypeId
      (fixture.typed-test-type! (&mut store) (& lease) ast.AstType.String)]
    [elements : ast.AstTypeList (ast.ast-type-list-new)]
    [_elements : unit
      (begin
        (ast.ast-type-list-push
          (&mut elements)
          (ast.ty-node-push (& (ast.AstType.String))))
        (ast.ast-type-list-push
          (&mut elements)
          (ast.ty-node-push (& (ast.AstType.I64)))))]
    [pair-type : typed.TypedTypeId
      (fixture.typed-test-type!
        (&mut store)
        (& lease)
        (ast.ast-ty-tuple elements))]
    [pair : typed.TypedBinderId
      (match (typed.typed-binder-add!
        (&mut store)
        (& lease)
        (typed.TypedTypeId (typed.typed-handle-copy (& pair-type.handle)))
        typed.TypedBinderKind.Parameter
        (typed.TypedOriginId (typed.typed-handle-copy (& origin.handle)))
        77)
        [(typed.TypedBinderResult.Ok id) id]
        [(typed.TypedBinderResult.Err _)
          (io.panic "normalize fixture pair binder")])]
    [root : typed.TypedPlaceId
      (match (typed.typed-place-add!
        (&mut store)
        (& lease)
        (typed.TypedPlaceKind.Root
          (typed.TypedBinderId (typed.typed-handle-copy (& pair.handle)))))
        [(typed.TypedPlaceResult.Ok id) id]
        [_ (io.panic "normalize fixture root place")])]
    [first : typed.TypedOccurrenceId
      (normalize-test-field!
        (&mut store)
        (& lease)
        (typed.TypedOriginId (typed.typed-handle-copy (& origin.handle)))
        (typed.TypedPlaceId (typed.typed-handle-copy (& root.handle)))
        (typed.TypedTypeId (typed.typed-handle-copy (& pair-type.handle)))
        (typed.TypedTypeId (typed.typed-handle-copy (& text-type.handle)))
        0
        true)]
    [second : typed.TypedOccurrenceId
      (if (= mode 0)
        (normalize-test-node!
          (&mut store)
          (& lease)
          (typed.TypedTypeId (typed.typed-handle-copy (& pair-type.handle)))
          (typed.TypedOriginId (typed.typed-handle-copy (& origin.handle)))
          (typed.TypedOperation.Read pair)
          (normalize-test-empty))
        (normalize-test-field!
          (&mut store)
          (& lease)
          (typed.TypedOriginId (typed.typed-handle-copy (& origin.handle)))
          (typed.TypedPlaceId (typed.typed-handle-copy (& root.handle)))
          (typed.TypedTypeId (typed.typed-handle-copy (& pair-type.handle)))
          (if (= mode 1)
            (typed.TypedTypeId (typed.typed-handle-copy (& int-type.handle)))
            (typed.TypedTypeId (typed.typed-handle-copy (& text-type.handle))))
          (if (= mode 1)
            1
            0)
          (= mode 2)))]
    [result-type : typed.TypedTypeId
      (cond
        [(= mode 0)
          (typed.TypedTypeId (typed.typed-handle-copy (& pair-type.handle)))]
        [(= mode 1)
          (typed.TypedTypeId (typed.typed-handle-copy (& int-type.handle)))]
        [else
          (typed.TypedTypeId (typed.typed-handle-copy (& text-type.handle)))])]
    [sequence : typed.TypedOccurrenceId
      (normalize-test-node!
        (&mut store)
        (& lease)
        (typed.TypedTypeId (typed.typed-handle-copy (& result-type.handle)))
        origin
        typed.TypedOperation.Sequence
        (fixture.typed-test-children2 first second))]
    [classes : (__tl_dyn-array norm.OwnershipNormalizeTypeClass)
      (__tl_make-array norm.OwnershipNormalizeTypeClass 0)]
    [products : (__tl_dyn-array norm.OwnershipNormalizeProduct)
      (__tl_make-array norm.OwnershipNormalizeProduct 0)]
    [fields : (__tl_dyn-array i64) (__tl_make-array i64 0)]
    [names : (__tl_dyn-array i64) (__tl_make-array i64 0)]
    [index : i64 0]
    (__tl_array-push! fields text-type.handle.index)
    (__tl_array-push! fields int-type.handle.index)
    (__tl_array-push! names -1)
    (__tl_array-push! names -2)
    (__tl_array-push! products (norm.OwnershipNormalizeProduct fields names))
    (__tl_array-push!
      products
      (norm.OwnershipNormalizeProduct
        (__tl_make-array i64 0)
        (__tl_make-array i64 0)))
    (while (<= index pair-type.handle.index)
      (let
        [class : norm.OwnershipNormalizeTypeClass
          (norm.OwnershipNormalizeTypeClass -1 true 0 -1 false)]
        (when
          (= index pair-type.handle.index)
          (set! class (norm.OwnershipNormalizeTypeClass 0 false 0 -1 false)))
        (when
          (= index text-type.handle.index)
          (set! class (norm.OwnershipNormalizeTypeClass 1 false 0 -1 false)))
        (__tl_array-push! classes class)
        (set! index (+ index 1))))
    (match (norm.ownership-normalize-with-products!
      (&mut store)
      (& lease)
      sequence
      result-type
      classes
      products
      (norm.ownership-normalize-variances-empty)
      (norm.ownership-normalize-global-writes-empty)
      (norm.ownership-normalize-default-limits))
      [(norm.OwnershipNormalizeResult.Ok _) (= mode 1)]
      [(norm.OwnershipNormalizeResult.Err failure)
        (match failure
          [(norm.OwnershipNormalizeFailure.Moved _ diagnostic)
            (and
              (!= mode 1)
              (= diagnostic.name 77)
              (if (= mode 0)
                (= (array-length diagnostic.fields) 0)
                (and
                  (= (array-length diagnostic.fields) 1)
                  (= (array-ref diagnostic.fields 0) -1))))]
          [_ false])])))

(define (compiler-ownership-normalize-self-test) : i64
  (let
    [mode : i64 0]
    (while (< mode 12)
      (begin
        (test.assert-true
          (normalize-test-primitive? mode)
          (str_cat.str-cat
            "normalizer primitive/rejection mode "
            (string.int->string mode)))
        (set! mode (+ mode 1))))
    (test.assert-true
      (normalize-test-short? true)
      "normalizer And conditional initialization and shadow identity")
    (test.assert-true
      (normalize-test-short? false)
      "normalizer Or conditional initialization and shadow identity")
    (test.assert-true
      (normalize-test-return?)
      "normalizer return edge and Never branch join")
    (set! mode 0)
    (while (< mode 4)
      (begin
        (test.assert-true
          (normalize-test-call-moves? mode)
          (str_cat.str-cat
            "normalizer call moves mode "
            (string.int->string mode)))
        (set! mode (+ mode 1))))
    (set! mode 0)
    (while (< mode 3)
      (begin
        (test.assert-true
          (normalize-test-fields? mode)
          (str_cat.str-cat "normalizer fields mode " (string.int->string mode)))
        (set! mode (+ mode 1))))
    (set! mode 0)
    (while (< mode 5)
      (begin
        (test.assert-true
          (normalize-test-references? mode)
          (str_cat.str-cat
            "normalizer references mode "
            (string.int->string mode)))
        (set! mode (+ mode 1))))
    (set! mode 0)
    (while (< mode 7)
      (begin
        (test.assert-true
          (normalize-test-bindings? mode)
          (str_cat.str-cat
            "normalizer bindings mode "
            (string.int->string mode)))
        (set! mode (+ mode 1))))
    (test.assert-true
      (normalize-test-dead-unsupported?)
      "normalizer does not certify unsupported dead forms")
    (set! mode 0)
    (while (< mode 3)
      (begin
        (test.assert-true
          (normalize-test-diverging-operand? mode)
          (str_cat.str-cat
            "normalizer diverging operand mode "
            (string.int->string mode)))
        (set! mode (+ mode 1))))
    (set! mode 0)
    (while (< mode 15)
      (begin
        (test.assert-true
          (normalize-test-loop? mode)
          (str_cat.str-cat
            "normalizer scalar loop mode "
            (string.int->string mode)))
        (set! mode (+ mode 1))))
    (set! mode 0)
    (while (< mode 4)
      (begin
        (test.assert-true
          (normalize-test-snapshot? mode)
          (str_cat.str-cat
            "normalizer retained snapshot mode "
            (string.int->string mode)))
        (set! mode (+ mode 1))))
    42))

;; The body and values remain self-contained after store retirement. Parameter
;; enumeration must retain declaration order and reject an unused nonprimitive
;; signature instead of certifying just the observed expression tree.
(define (normalize-test-snapshot? [mode : i64]) : bool
  (let
    [intern-state : ci.InternCompatState
      (ci.intern-compat-state-capture-active)]
    [lease : (typed.TypedBodyLease intern-state)
      (fixture.typed-test-lease (& intern-state) (cast (+ 901 mode) : u64))]
    [store : typed.TypedStore (fixture.typed-test-store (& lease))]
    [origin : typed.TypedOriginId
      (fixture.typed-test-origin! (&mut store) (& lease))]
    [int-type : typed.TypedTypeId
      (fixture.typed-test-type! (&mut store) (& lease) ast.AstType.I64)]
    [other-type : typed.TypedTypeId
      (fixture.typed-test-type!
        (&mut store)
        (& lease)
        (if (= mode 1)
          ast.AstType.String
          ast.AstType.U64))]
    [first : typed.TypedBinderId
      (normalize-test-binder! (&mut store) (& lease) other-type origin true)]
    [second : typed.TypedBinderId
      (normalize-test-binder! (&mut store) (& lease) int-type origin true)]
    [root : typed.TypedOccurrenceId
      (normalize-test-node!
        (&mut store)
        (& lease)
        int-type
        origin
        (typed.TypedOperation.Literal (ast.AstLiteral.Int 42 "00042"))
        (normalize-test-empty))]
    [limits : norm.OwnershipNormalizeLimits
      (norm.ownership-normalize-default-limits)]
    (when (= mode 2) (typed.typed-store-retire! (&mut store)))
    (when (= mode 3) (set! limits.source-bytes 4))
    (match (norm.ownership-normalize!
      (&mut store)
      (& lease)
      root
      int-type
      (__tl_make-array norm.OwnershipNormalizeTypeClass 0)
      limits)
      [(norm.OwnershipNormalizeResult.Ok output)
        (set!
          (array-ref store.occurrences root.handle.index).operation
          (typed.TypedOperation.Literal (ast.AstLiteral.Int 99 "99")))
        (typed.typed-store-retire! (&mut store))
        (and
          (= mode 0)
          (= (array-length output.nodes) 1)
          (= (array-length output.binders) 2)
          (= (array-ref output.binders 0).type 9)
          (= (array-ref output.binders 1).type 5)
          (= (array-ref output.binders 0).handle.serial first.handle.serial)
          (= (array-ref output.binders 1).handle.serial second.handle.serial)
          (= output.return-type 5)
          (= output.root.handle.serial root.handle.serial)
          (match (& (array-ref output.nodes 0).operation)
            [(norm.NormalizeOperation.Literal (ast.AstLiteral.Int value text))
              (and (= value 42) (string.eq text "00042"))]
            [_ false])
          (match (typed.typed-binder-at! (&mut store) (& lease) 0)
            [(typed.TypedBinderResult.Err (typed.TypedError.Lease)) true]
            [_ false]))]
      [(norm.OwnershipNormalizeResult.Err
          (norm.OwnershipNormalizeFailure.Unsupported _))
        (= mode 1)]
      [(norm.OwnershipNormalizeResult.Err
          (norm.OwnershipNormalizeFailure.Typed (typed.TypedError.Lease)))
        (= mode 2)]
      [(norm.OwnershipNormalizeResult.Err
          (norm.OwnershipNormalizeFailure.Resource))
        (= mode 3)]
      [_ false])))

(define (normalize-test-bindings? [mode : i64]) : bool
  (let
    [intern-state : ci.InternCompatState
      (ci.intern-compat-state-capture-active)]
    [lease : (typed.TypedBodyLease intern-state)
      (fixture.typed-test-lease (& intern-state) (cast (+ 401 mode) : u64))]
    [store : typed.TypedStore (fixture.typed-test-store (& lease))]
    [origin : typed.TypedOriginId
      (fixture.typed-test-origin! (&mut store) (& lease))]
    [int-type : typed.TypedTypeId
      (fixture.typed-test-type! (&mut store) (& lease) ast.AstType.I64)]
    [unsigned-type : typed.TypedTypeId
      (fixture.typed-test-type! (&mut store) (& lease) ast.AstType.U64)]
    [bool-type : typed.TypedTypeId
      (fixture.typed-test-type! (&mut store) (& lease) ast.AstType.Bool)]
    [unit-type : typed.TypedTypeId
      (fixture.typed-test-type! (&mut store) (& lease) ast.AstType.Unit)]
    [never-type : typed.TypedTypeId
      (fixture.typed-test-type! (&mut store) (& lease) ast.AstType.Never)]
    [flag : typed.TypedBinderId
      (normalize-test-binder! (&mut store) (& lease) bool-type origin true)]
    [x : typed.TypedBinderId
      (normalize-test-binder! (&mut store) (& lease) int-type origin (= mode 6))]
    [value : typed.TypedOccurrenceId
      (fixture.typed-test-literal!
        (&mut store)
        (& lease)
        int-type
        origin
        typed.TypedSyntax.Generated
        3)]
    [before : typed.TypedOccurrenceId
      (if (or (= mode 0) (= mode 3) (= mode 4) (= mode 6))
        (normalize-test-node!
          (&mut store)
          (& lease)
          unit-type
          origin
          (typed.TypedOperation.Initialize x)
          (normalize-test-one value))
        (normalize-test-node!
          (&mut store)
          (& lease)
          unit-type
          origin
          (typed.TypedOperation.Literal ast.AstLiteral.Unit)
          (normalize-test-empty)))]
    [condition : typed.TypedOccurrenceId
      (normalize-test-node!
        (&mut store)
        (& lease)
        bool-type
        origin
        (typed.TypedOperation.Read flag)
        (normalize-test-empty))]
    [left-value : typed.TypedOccurrenceId
      (fixture.typed-test-literal!
        (&mut store)
        (& lease)
        (if (= mode 4)
          unsigned-type
          int-type)
        origin
        typed.TypedSyntax.Generated
        4)]
    [left : typed.TypedOccurrenceId
      (if (= mode 5)
        (normalize-test-node!
          (&mut store)
          (& lease)
          never-type
          origin
          typed.TypedOperation.Return
          (normalize-test-one left-value))
        (normalize-test-node!
          (&mut store)
          (& lease)
          unit-type
          origin
          (if (or (= mode 0) (= mode 3) (= mode 4) (= mode 6))
            (typed.TypedOperation.Assign x)
            (typed.TypedOperation.Initialize x))
          (normalize-test-one left-value)))]
    [right-value : typed.TypedOccurrenceId
      (fixture.typed-test-literal!
        (&mut store)
        (& lease)
        int-type
        origin
        typed.TypedSyntax.Generated
        5)]
    [right : typed.TypedOccurrenceId
      (if (= mode 1)
        (normalize-test-node!
          (&mut store)
          (& lease)
          unit-type
          origin
          (typed.TypedOperation.Literal ast.AstLiteral.Unit)
          (normalize-test-empty))
        (normalize-test-node!
          (&mut store)
          (& lease)
          unit-type
          origin
          (if (or (= mode 0) (= mode 3) (= mode 4) (= mode 6))
            (typed.TypedOperation.Assign x)
            (typed.TypedOperation.Initialize x))
          (normalize-test-one right-value)))]
    [branch : typed.TypedOccurrenceId
      (normalize-test-node!
        (&mut store)
        (& lease)
        unit-type
        origin
        typed.TypedOperation.If
        (__tl_make-array condition left right))]
    [read : typed.TypedOccurrenceId
      (normalize-test-node!
        (&mut store)
        (& lease)
        (if (= mode 3)
          bool-type
          int-type)
        origin
        (typed.TypedOperation.Read x)
        (normalize-test-empty))]
    [root : typed.TypedOccurrenceId
      (normalize-test-node!
        (&mut store)
        (& lease)
        int-type
        origin
        typed.TypedOperation.Sequence
        (__tl_make-array before branch read))]
    (match (norm.ownership-normalize!
      (&mut store)
      (& lease)
      root
      int-type
      (__tl_make-array norm.OwnershipNormalizeTypeClass 0)
      (norm.ownership-normalize-default-limits))
      [(norm.OwnershipNormalizeResult.Ok _) (or (= mode 0) (= mode 5))]
      [(norm.OwnershipNormalizeResult.Err
          (norm.OwnershipNormalizeFailure.Structural _))
        (or (= mode 2) (= mode 3) (= mode 4) (= mode 6))]
      [(norm.OwnershipNormalizeResult.Err
          (norm.OwnershipNormalizeFailure.Core failure))
        (and
          (= mode 1)
          (match (& failure.kind)
            [(own.OwnershipFailureKind.Uninitialized) true]
            [_ false]))]
      [_ false])))

(define (normalize-test-dead-unsupported?) : bool
  (let
    [intern-state : ci.InternCompatState
      (ci.intern-compat-state-capture-active)]
    [lease : (typed.TypedBodyLease intern-state)
      (fixture.typed-test-lease (& intern-state) (cast 501 : u64))]
    [store : typed.TypedStore (fixture.typed-test-store (& lease))]
    [origin : typed.TypedOriginId
      (fixture.typed-test-origin! (&mut store) (& lease))]
    [unit-type : typed.TypedTypeId
      (fixture.typed-test-type! (&mut store) (& lease) ast.AstType.Unit)]
    [never-type : typed.TypedTypeId
      (fixture.typed-test-type! (&mut store) (& lease) ast.AstType.Never)]
    [string-type : typed.TypedTypeId
      (fixture.typed-test-type! (&mut store) (& lease) ast.AstType.String)]
    [returned : typed.TypedOccurrenceId
      (normalize-test-node!
        (&mut store)
        (& lease)
        never-type
        origin
        typed.TypedOperation.Return
        (normalize-test-empty))]
    ;; A value of a type without an ownership class is outside the subset,
    ;; even dead.
    [read : typed.TypedOccurrenceId
      (normalize-test-node!
        (&mut store)
        (& lease)
        string-type
        origin
        (typed.TypedOperation.Primitive (typed.TypedPrimitive.Builtin 999 0))
        (normalize-test-empty))]
    [root : typed.TypedOccurrenceId
      (normalize-test-node!
        (&mut store)
        (& lease)
        never-type
        origin
        typed.TypedOperation.Sequence
        (fixture.typed-test-children2 returned read))]
    (match (norm.ownership-normalize!
      (&mut store)
      (& lease)
      root
      unit-type
      (__tl_make-array norm.OwnershipNormalizeTypeClass 0)
      (norm.ownership-normalize-default-limits))
      [(norm.OwnershipNormalizeResult.Err
          (norm.OwnershipNormalizeFailure.Unsupported _))
        true]
      [_ false])))

;; A diverging operand is an exit (#8449): the operation is never performed
;; and the operands after it are walked in blocks nothing reaches. Mode 0 is a
;; call's first argument (its second is dead), mode 1 a unary operand, mode 2
;; a loop condition (its body is dead). Each body returns once, through the
;; diverging operand.
(define (normalize-test-diverging-operand? [mode : i64]) : bool
  (let
    [intern-state : ci.InternCompatState
      (ci.intern-compat-state-capture-active)]
    [lease : (typed.TypedBodyLease intern-state)
      (fixture.typed-test-lease (& intern-state) (cast (+ 701 mode) : u64))]
    [store : typed.TypedStore (fixture.typed-test-store (& lease))]
    [origin : typed.TypedOriginId
      (fixture.typed-test-origin! (&mut store) (& lease))]
    [int-type : typed.TypedTypeId
      (fixture.typed-test-type! (&mut store) (& lease) ast.AstType.I64)]
    [unit-type : typed.TypedTypeId
      (fixture.typed-test-type! (&mut store) (& lease) ast.AstType.Unit)]
    [never-type : typed.TypedTypeId
      (fixture.typed-test-type! (&mut store) (& lease) ast.AstType.Never)]
    [value : typed.TypedOccurrenceId
      (fixture.typed-test-literal!
        (&mut store)
        (& lease)
        int-type
        origin
        typed.TypedSyntax.Generated
        42)]
    [returned : typed.TypedOccurrenceId
      (normalize-test-node!
        (&mut store)
        (& lease)
        never-type
        origin
        typed.TypedOperation.Return
        (normalize-test-one value))]
    [dead : typed.TypedOccurrenceId
      (if (= mode 2)
        (normalize-test-node!
          (&mut store)
          (& lease)
          unit-type
          origin
          (typed.TypedOperation.Literal ast.AstLiteral.Unit)
          (normalize-test-empty))
        (fixture.typed-test-literal!
          (&mut store)
          (& lease)
          int-type
          origin
          typed.TypedSyntax.Generated
          17))]
    [root : typed.TypedOccurrenceId
      (cond
        [(= mode 0)
          (normalize-test-node!
            (&mut store)
            (& lease)
            never-type
            origin
            (typed.TypedOperation.Primitive
              (typed.TypedPrimitive.Builtin 999 2))
            (fixture.typed-test-children2 returned dead))]
        [(= mode 1)
          (normalize-test-node!
            (&mut store)
            (& lease)
            never-type
            origin
            (typed.TypedOperation.Unary ast.AstUnOp.Neg)
            (normalize-test-one returned))]
        [else
          (normalize-test-node!
            (&mut store)
            (& lease)
            never-type
            origin
            typed.TypedOperation.While
            (fixture.typed-test-children2 returned dead))])]
    (match (norm.ownership-normalize!
      (&mut store)
      (& lease)
      root
      int-type
      (__tl_make-array norm.OwnershipNormalizeTypeClass 0)
      (norm.ownership-normalize-default-limits))
      [(norm.OwnershipNormalizeResult.Ok output)
        (let
          [index : i64 0]
          [returns : i64 0]
          (while (< index (array-length output.body.blocks))
            (begin
              (match (& (array-ref output.body.blocks index).terminator)
                [(own.OwnershipTerminator.Return _)
                  (set! returns (+ returns 1))]
                [_ unit])
              (set! index (+ index 1))))
          (= returns 1))]
      [_ false])))

(define (normalize-test-goto?
  [body : (& body own.OwnershipBody)]
  [block : i64]
  [target : i64]) : bool
  (and
    (< block (array-length body.blocks))
    (match (& (array-ref body.blocks block).terminator)
      [(own.OwnershipTerminator.Goto dest) (= dest.index target)]
      [_ false])))

;; The selected graph contains each executable child once. The resulting graph
;; checks both first-entry facts and all backedges rather than unrolling syntax.
(define (normalize-test-loop? [mode : i64]) : bool
  (let
    [intern-state : ci.InternCompatState
      (ci.intern-compat-state-capture-active)]
    [lease : (typed.TypedBodyLease intern-state)
      (fixture.typed-test-lease (& intern-state) (cast (+ 601 mode) : u64))]
    [store : typed.TypedStore (fixture.typed-test-store (& lease))]
    [origin : typed.TypedOriginId
      (fixture.typed-test-origin! (&mut store) (& lease))]
    [unit-type : typed.TypedTypeId
      (fixture.typed-test-type! (&mut store) (& lease) ast.AstType.Unit)]
    [bool-type : typed.TypedTypeId
      (fixture.typed-test-type! (&mut store) (& lease) ast.AstType.Bool)]
    [int-type : typed.TypedTypeId
      (fixture.typed-test-type! (&mut store) (& lease) ast.AstType.I64)]
    [never-type : typed.TypedTypeId
      (fixture.typed-test-type! (&mut store) (& lease) ast.AstType.Never)]
    [flag : typed.TypedBinderId
      (normalize-test-binder! (&mut store) (& lease) bool-type origin true)]
    [local : typed.TypedBinderId
      (normalize-test-binder! (&mut store) (& lease) int-type origin false)]
    [condition : typed.TypedOccurrenceId
      (cond
        [(= mode 9)
          (normalize-test-node!
            (&mut store)
            (& lease)
            never-type
            origin
            typed.TypedOperation.Break
            (normalize-test-empty))]
        [(= mode 10)
          (fixture.typed-test-literal!
            (&mut store)
            (& lease)
            int-type
            origin
            typed.TypedSyntax.Generated
            1)]
        [(= mode 14)
          (normalize-test-node!
            (&mut store)
            (& lease)
            never-type
            origin
            typed.TypedOperation.Return
            (normalize-test-empty))]
        [else
          (normalize-test-node!
            (&mut store)
            (& lease)
            bool-type
            origin
            (typed.TypedOperation.Read flag)
            (normalize-test-empty))])]
    [value : typed.TypedOccurrenceId
      (fixture.typed-test-literal!
        (&mut store)
        (& lease)
        int-type
        origin
        typed.TypedSyntax.Generated
        42)]
    [init : typed.TypedOccurrenceId
      (normalize-test-node!
        (&mut store)
        (& lease)
        unit-type
        origin
        (typed.TypedOperation.Initialize local)
        (normalize-test-one value))]
    [read : typed.TypedOccurrenceId
      (normalize-test-node!
        (&mut store)
        (& lease)
        int-type
        origin
        (typed.TypedOperation.Read local)
        (normalize-test-empty))]
    [unit-node : typed.TypedOccurrenceId
      (normalize-test-node!
        (&mut store)
        (& lease)
        unit-type
        origin
        (typed.TypedOperation.Literal ast.AstLiteral.Unit)
        (normalize-test-empty))]
    [body : typed.TypedOccurrenceId
      (cond
        [(or (= mode 1) (= mode 13))
          (normalize-test-node!
            (&mut store)
            (& lease)
            never-type
            origin
            typed.TypedOperation.Continue
            (normalize-test-empty))]
        [(= mode 2)
          (normalize-test-node!
            (&mut store)
            (& lease)
            never-type
            origin
            typed.TypedOperation.Break
            (normalize-test-empty))]
        [(= mode 3)
          (normalize-test-node!
            (&mut store)
            (& lease)
            unit-type
            origin
            typed.TypedOperation.Sequence
            (__tl_make-array read init unit-node))]
        [(= mode 4) init]
        [(= mode 5)
          (normalize-test-node!
            (&mut store)
            (& lease)
            unit-type
            origin
            typed.TypedOperation.Sequence
            (__tl_make-array init read unit-node))]
        [(= mode 6)
          (let
            [inner-condition : typed.TypedOccurrenceId
              (normalize-test-node!
                (&mut store)
                (& lease)
                bool-type
                origin
                (typed.TypedOperation.Read flag)
                (normalize-test-empty))]
            [inner-exit : typed.TypedOccurrenceId
              (normalize-test-node!
                (&mut store)
                (& lease)
                never-type
                origin
                typed.TypedOperation.Break
                (normalize-test-empty))]
            [inner : typed.TypedOccurrenceId
              (normalize-test-node!
                (&mut store)
                (& lease)
                unit-type
                origin
                typed.TypedOperation.While
                (fixture.typed-test-children2 inner-condition inner-exit))]
            [outer-continue : typed.TypedOccurrenceId
              (normalize-test-node!
                (&mut store)
                (& lease)
                never-type
                origin
                typed.TypedOperation.Continue
                (normalize-test-empty))]
            (normalize-test-node!
              (&mut store)
              (& lease)
              never-type
              origin
              typed.TypedOperation.Sequence
              (fixture.typed-test-children2 inner outer-continue)))]
        [(= mode 11) value]
        [else unit-node])]
    ;; A loop whose condition diverges (mode 14) never completes: its own
    ;; result is Never.
    [loop : typed.TypedOccurrenceId
      (normalize-test-node!
        (&mut store)
        (& lease)
        (if (= mode 14)
          never-type
          unit-type)
        origin
        typed.TypedOperation.While
        (fixture.typed-test-children2 condition body))]
    [root : typed.TypedOccurrenceId
      (cond
        [(or (= mode 7) (= mode 8))
          (normalize-test-node!
            (&mut store)
            (& lease)
            never-type
            origin
            (if (= mode 7)
              typed.TypedOperation.Break
              typed.TypedOperation.Continue)
            (normalize-test-empty))]
        [(= mode 4)
          (normalize-test-node!
            (&mut store)
            (& lease)
            int-type
            origin
            typed.TypedOperation.Sequence
            (fixture.typed-test-children2 loop read))]
        [(= mode 12)
          (let
            [exit : typed.TypedOccurrenceId
              (normalize-test-node!
                (&mut store)
                (& lease)
                never-type
                origin
                typed.TypedOperation.Return
                (normalize-test-empty))]
            [dead-break : typed.TypedOccurrenceId
              (normalize-test-node!
                (&mut store)
                (& lease)
                never-type
                origin
                typed.TypedOperation.Break
                (normalize-test-empty))]
            (normalize-test-node!
              (&mut store)
              (& lease)
              never-type
              origin
              typed.TypedOperation.Sequence
              (fixture.typed-test-children2 exit dead-break)))]
        [(= mode 13)
          ;; Continue must return to the condition and re-read the outer local.
          (let
            [outer-write-value : typed.TypedOccurrenceId
              (fixture.typed-test-literal!
                (&mut store)
                (& lease)
                int-type
                origin
                typed.TypedSyntax.Generated
                8)]
            [write : typed.TypedOccurrenceId
              (normalize-test-node!
                (&mut store)
                (& lease)
                unit-type
                origin
                (typed.TypedOperation.Assign local)
                (normalize-test-one outer-write-value))]
            [new-body : typed.TypedOccurrenceId
              (normalize-test-node!
                (&mut store)
                (& lease)
                never-type
                origin
                typed.TypedOperation.Sequence
                (fixture.typed-test-children2 write body))]
            [new-loop : typed.TypedOccurrenceId
              (normalize-test-node!
                (&mut store)
                (& lease)
                unit-type
                origin
                typed.TypedOperation.While
                (fixture.typed-test-children2 condition new-body))]
            (normalize-test-node!
              (&mut store)
              (& lease)
              unit-type
              origin
              typed.TypedOperation.Sequence
              (fixture.typed-test-children2 init new-loop)))]
        [else loop])]
    (match (norm.ownership-normalize!
      (&mut store)
      (& lease)
      root
      (if (= mode 4)
        int-type
        unit-type)
      (__tl_make-array norm.OwnershipNormalizeTypeClass 0)
      (norm.ownership-normalize-default-limits))
      [(norm.OwnershipNormalizeResult.Ok output)
        (cond
          [(or (= mode 0) (= mode 5))
            (and
              (= (array-length output.body.blocks) 4)
              (normalize-test-goto? (& output.body) 0 1)
              (normalize-test-goto? (& output.body) 2 1))]
          [(or (= mode 1) (= mode 13))
            (normalize-test-goto? (& output.body) 2 1)]
          [(= mode 2) (normalize-test-goto? (& output.body) 2 3)]
          [(= mode 6)
            (and
              (= (array-length output.body.blocks) 7)
              (normalize-test-goto? (& output.body) 2 4)
              (normalize-test-goto? (& output.body) 5 6)
              (normalize-test-goto? (& output.body) 6 1))]
          ;; A diverging condition is an exit: the condition block returns
          ;; and nothing reaches the body or the loop exit.
          [(= mode 14)
            (match (& (array-ref output.body.blocks 1).terminator)
              [(own.OwnershipTerminator.Return _) true]
              [_ false])]
          [else false])]
      [(norm.OwnershipNormalizeResult.Err
          (norm.OwnershipNormalizeFailure.Core failure))
        (and
          (or (= mode 3) (= mode 4))
          (match (& failure.kind)
            [(own.OwnershipFailureKind.Uninitialized) true]
            [_ false]))]
      [(norm.OwnershipNormalizeResult.Err
          (norm.OwnershipNormalizeFailure.Structural _))
        (or
          (= mode 7)
          (= mode 8)
          (= mode 9)
          (= mode 10)
          (= mode 11)
          (= mode 12))]
      [_ false])))