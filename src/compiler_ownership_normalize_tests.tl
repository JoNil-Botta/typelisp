(import compiler_ownership_normalize as norm)
(import compiler_typed_occurrence as typed)
(import compiler_typed_occurrence_tests as fixture)
(import compiler_ownership_core as own)
(import compiler_ownership_core_tests as core_fixture)
(import compiler_ownership_dump as dump)
(import compiler_ast_types as ast)
(import compiler_intern as ci)
(import stdlib.test)
(import stdlib.io)
(import stdlib.str_cat_runtime as str_cat)
(import stdlib.string)
(import stdlib.hashmap)
(import (hashmap.hashmap i64 i64) as transfer_map)

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
        (ast.ast-ty-func params (& (ast.AstType.I64))))]
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
        (ast.ast-ty-func one-params (& (ast.AstType.I64))))]
    [signature : typed.TypedTypeId
      (fixture.typed-test-type!
        (&mut store)
        (& lease)
        (ast.ast-ty-func two-params (& (ast.AstType.I64))))]
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

;; Compare every key with the former block/instruction scan: repeated pairs,
;; interleaved Copy/Move/Read, projected roots, empty blocks and spare capacity.
(define (normalize-test-transfer-index?) : bool
  (let
    [blocks : (__tl_dyn-array own.OwnershipBlock)
      (__tl_make-array own.OwnershipBlock 3)]
    [counts : (__tl_dyn-array i64) (__tl_make-array 0 127 127)]
    [block : i64 0]
    (while (< block 3)
      (let
        [instructions : (__tl_dyn-array own.OwnershipInstruction)
          (__tl_make-array own.OwnershipInstruction 128)]
        [index : i64 0]
        (while (< index 128)
          (let
            [from : own.OwnershipPlaceId
              (core_fixture.ownership-test-place-id
                (if (= (% index 2) 0)
                  1
                  3))]
            [to : own.OwnershipPlaceId
              (core_fixture.ownership-test-place-id
                (if (= (% index 5) 0)
                  6
                  5))]
            (set!
              (array-ref instructions index)
              (own.OwnershipInstruction
                (match (% index 3)
                  [0 (own.OwnershipOperation.Copy from to)]
                  [1 (own.OwnershipOperation.Move from to)]
                  [_ (own.OwnershipOperation.Read from)])
                (core_fixture.ownership-test-source index))))
          (set! index (+ index 1)))
        (set!
          (array-ref blocks block)
          (core_fixture.ownership-test-block
            instructions
            (core_fixture.ownership-test-return))))
      (set! block (+ block 1)))
    (let
      [body : own.OwnershipBody (core_fixture.ownership-test-body blocks)]
      [transfers : norm.NormalizeTransfers
        (norm.normalize-transfer-index (& body) (& counts))]
      [source : i64 0]
      (while (< source 7)
        (let
          [target : i64 0]
          (while (< target 7)
            (let
              [read : i64
                (transfer_map.get-value-or
                  (& transfers.heads)
                  (norm.normalize-transfer-key source target 7)
                  0)]
              [block : i64 0]
              (while (< block 3)
                (let
                  [index : i64 0]
                  (while (< index (array-ref counts block))
                    (match (&
                      (array-ref
                        (array-ref body.blocks block).instructions
                        index).operation)
                      [(or (own.OwnershipOperation.Copy from to)
                           (own.OwnershipOperation.Move from to))
                        (when
                          (and
                            (=
                              source
                              (own.ownership-place-root (& body) from.index))
                            (=
                              target
                              (own.ownership-place-root (& body) to.index)))
                          (unless
                            (and
                              (> read 0)
                              (= (array-ref transfers.blocks (- read 1)) block)
                              (= (array-ref transfers.indices (- read 1)) index))
                            (return false))
                          (set! read (array-ref transfers.next (- read 1))))]
                      [_ unit])
                    (set! index (+ index 1))))
                (set! block (+ block 1)))
              (unless (= read 0) (return false)))
            (set! target (+ target 1))))
        (set! source (+ source 1)))
      true)))

;; Power-of-two place count and many sources into one target used to put all
;; unmixed pair keys into one bucket. Compare each list with a fresh scan.
(define (normalize-test-transfer-fan-in?) : bool
  (let
    [instructions : (__tl_dyn-array own.OwnershipInstruction)
      (__tl_make-array own.OwnershipInstruction 1024)]
    [blocks : (__tl_dyn-array own.OwnershipBlock)
      (__tl_make-array own.OwnershipBlock 1)]
    [counts : (__tl_dyn-array i64) (__tl_make-array i64 1)]
    [index : i64 0]
    (while (< index 1024)
      (set!
        (array-ref instructions index)
        (own.OwnershipInstruction
          (own.OwnershipOperation.Copy
            (core_fixture.ownership-test-place-id (+ index 1))
            (core_fixture.ownership-test-place-id 3))
          (core_fixture.ownership-test-source index)))
      (set! index (+ index 1)))
    (set! (array-ref counts 0) 1024)
    (set!
      (array-ref blocks 0)
      (core_fixture.ownership-test-block
        instructions
        (core_fixture.ownership-test-return)))
    (let
      [body : own.OwnershipBody (core_fixture.ownership-test-body blocks)]
      (set! body.places (__tl_make-array own.OwnershipPlace 4096))
      (set! body.locals (__tl_make-array own.OwnershipLocal 4096))
      (set! index 0)
      (while (< index 4096)
        (set!
          (array-ref body.places index)
          (core_fixture.ownership-test-place index 0 -1 0))
        (set!
          (array-ref body.locals index)
          (core_fixture.ownership-test-local 0 false))
        (set! index (+ index 1)))
      (let
        [transfers : norm.NormalizeTransfers
          (norm.normalize-transfer-index (& body) (& counts))]
        [source : i64 0]
        (while (< source 1026)
          (let
            [read : i64
              (transfer_map.get-value-or
                (& transfers.heads)
                (norm.normalize-transfer-key source 3 4096)
                0)]
            [index : i64 0]
            (while (< index 1024)
              (match (&
                (array-ref (array-ref body.blocks 0).instructions index).operation)
                [(own.OwnershipOperation.Copy from to)
                  (when
                    (and
                      (= source (own.ownership-place-root (& body) from.index))
                      (= 3 (own.ownership-place-root (& body) to.index)))
                    (unless
                      (and
                        (> read 0)
                        (= (array-ref transfers.blocks (- read 1)) 0)
                        (= (array-ref transfers.indices (- read 1)) index))
                      (return false))
                    (set! read (array-ref transfers.next (- read 1))))]
                [_ (return false)])
              (set! index (+ index 1)))
            (unless (= read 0) (return false)))
          (set! source (+ source 1)))
        true))))

;; Independent predecessor-union fixpoint, including disconnected generators.
;; Compare every entry bit and bound the production traversal's actual work.
(define (normalize-test-reaching-case?
  [blocks : (__tl_dyn-array own.OwnershipBlock)]
  [last : (__tl_dyn-array i64)]
  [large? : bool]) : bool
  (let
    [body : own.OwnershipBody (core_fixture.ownership-test-body blocks)]
    [size : i64 (array-length body.blocks)]
    [count : i64 4]
    [expected : (__tl_dyn-array bool) (__tl_make-array bool (* size count))]
    [exit : (__tl_dyn-array bool) (__tl_make-array bool (* size count))]
    [actual : (__tl_dyn-array bool) (__tl_make-array bool (* size count))]
    [work : i64 0]
    [old-work : i64 0]
    [changed : bool true]
    (while changed
      (set! changed false)
      (let
        [block : i64 0]
        (while (< block size)
          (set! old-work (+ old-work count))
          (let
            [pred : i64 0]
            (while (< pred size)
              (let
                [term : (& body own.OwnershipTerminator)
                  (& (array-ref body.blocks pred).terminator)]
                (when
                  (or
                    (= (own.ownership-successor term 0) block)
                    (= (own.ownership-successor term 1) block))
                  (let
                    [d : i64 0]
                    (while (< d count)
                      (when
                        (and
                          (array-ref exit (+ (* pred count) d))
                          (not (array-ref expected (+ (* block count) d))))
                        (set! (array-ref expected (+ (* block count) d)) true)
                        (set! changed true))
                      (set! d (+ d 1))))))
              (set! pred (+ pred 1))))
          (let
            [d : i64 0]
            (while (< d count)
              (let
                [out : bool
                  (if (>= (array-ref last block) 0)
                    (= d (array-ref last block))
                    (array-ref expected (+ (* block count) d)))]
                (when
                  (and out (not (array-ref exit (+ (* block count) d))))
                  (set! (array-ref exit (+ (* block count) d)) true)
                  (set! changed true)))
              (set! d (+ d 1))))
          (set! block (+ block 1)))))
    (match (norm.normalize-reaching-entries!
      (& body)
      (& last)
      count
      (&mut actual)
      (&mut work)
      (* size count))
      [(norm.NormalizeUnit.Err _) (return false)]
      [_ unit])
    (let
      [cell : i64 0]
      (while (< cell (* size count))
        (unless
          (= (array-ref actual cell) (array-ref expected cell))
          (return false))
        (set! cell (+ cell 1))))
    (when
      large?
      (let
        [limited : (__tl_dyn-array bool) (__tl_make-array bool (* size count))]
        [charged : i64 0]
        (match (norm.normalize-reaching-entries!
          (& body)
          (& last)
          count
          (&mut limited)
          (&mut charged)
          1)
          [(norm.NormalizeUnit.Err norm.OwnershipNormalizeFailure.Resource)
            (unless (= charged 1) (return false))]
          [_ (return false)])))
    (and (<= work (* size count)) (or (not large?) (>= old-work (* size size))))))

(define (normalize-test-reaching?) : bool
  (let
    [graph : i64 0]
    ;; All three-node single-successor graphs, including absent and self
    ;; edges; then all six-edge graphs without self edges, with branches.
    (while (< graph 128)
      (let
        [generators : i64 0]
        (while (< generators 8)
          (let
            [blocks : (__tl_dyn-array own.OwnershipBlock)
              (__tl_make-array own.OwnershipBlock 3)]
            [last : (__tl_dyn-array i64) (__tl_make-array i64 3)]
            [bits : i64 (% graph 64)]
            [mask : i64 generators]
            [block : i64 0]
            (while (< block 3)
              (set!
                (array-ref last block)
                (if (= (% mask 2) 0)
                  -1
                  block))
              (set! mask (/ mask 2))
              (let
                [yes : i64
                  (if (< graph 64)
                    (- (% bits 4) 1)
                    (if (= (% bits 2) 0)
                      -1
                      (% (+ block 1) 3)))]
                [no : i64
                  (if (< graph 64)
                    yes
                    (if (= (% (/ bits 2) 2) 0)
                      -1
                      (% (+ block 2) 3)))]
                (set!
                  (array-ref blocks block)
                  (core_fixture.ownership-test-block
                    (__tl_make-array own.OwnershipInstruction 0)
                    (own.OwnershipTerminator.Branch
                      (core_fixture.ownership-test-place-id 0)
                      (core_fixture.ownership-test-block-id yes)
                      (core_fixture.ownership-test-block-id no)))))
              (set! bits (/ bits 4))
              (set! block (+ block 1)))
            (unless
              (normalize-test-reaching-case? blocks last false)
              (return false)))
          (set! generators (+ generators 1))))
      (set! graph (+ graph 1)))
    (let
      [size : i64 256]
      [blocks : (__tl_dyn-array own.OwnershipBlock)
        (__tl_make-array own.OwnershipBlock size)]
      [last : (__tl_dyn-array i64) (__tl_make-array i64 size)]
      [block : i64 0]
      (while (< block size)
        (set! (array-ref last block) -1)
        (set!
          (array-ref blocks block)
          (core_fixture.ownership-test-block
            (__tl_make-array own.OwnershipInstruction 0)
            (own.OwnershipTerminator.Goto
              (core_fixture.ownership-test-block-id
                (% (+ block (- size 1)) size)))))
        (set! block (+ block 1)))
      ;; Definition 0 is overwritten in its block; 3 has no generator.
      (set! (array-ref last (- size 1)) 1)
      (set! (array-ref last (/ size 2)) 2)
      (normalize-test-reaching-case? blocks last true))))

;; Compact lifetime occurrence shapes (#9584). The oracle is the walk the
;; shapes replaced: every position laid out with its name, invariance and the
;; position of the reference it lies under. Region edges built from it,
;; position by position, are compared with the edges built from the DAG.
(defstruct NormalizeTestFlat
  (names (__tl_dyn-array i64))
  (vars (__tl_dyn-array bool))
  (outers (__tl_dyn-array i64)))

(define (normalize-test-flat-new) : NormalizeTestFlat
  (NormalizeTestFlat
    (__tl_make-array i64 0)
    (__tl_make-array bool 0)
    (__tl_make-array i64 0)))

(define (normalize-test-flat-push!
  [out : (&mut out NormalizeTestFlat)]
  [name : i64]
  [inv? : bool]
  [outer : i64]) : unit
  (norm.normalize-push-i64! (&mut out.names) name)
  (norm.normalize-push-bool! (&mut out.vars) inv?)
  (norm.normalize-push-i64! (&mut out.outers) outer))

(define (normalize-test-flat-lifetimes
  [variances : (& variances norm.OwnershipNormalizeVariances)]
  [lender? : bool]
  [name : i64]
  [lifetimes : (& lifetimes ast.AstLifetimeList)]
  [inv? : bool]
  [out : (&mut out NormalizeTestFlat)]
  [outer : i64]) : unit
  (let
    [index : i64 0]
    (while (< index (ast.ast-lifetime-list-len lifetimes))
      (if lender?
        (let
          [variance : i64 (norm.normalize-lender-variance variances name index)]
          (when
            (< variance 2)
            (normalize-test-flat-push!
              out
              (ast.ast-lifetime-list-get lifetimes index -1)
              (or inv? (= variance 0))
              outer)))
        (normalize-test-flat-push!
          out
          (ast.ast-lifetime-list-get lifetimes index -1)
          (or
            inv?
            (not (norm.normalize-nominal-covariant? variances name index)))
          outer))
      (set! index (+ index 1)))))

(define (normalize-test-flat-walk
  [variances : (& variances norm.OwnershipNormalizeVariances)]
  [lender? : bool]
  [ty : ast.AstType]
  [inv? : bool]
  [out : (&mut out NormalizeTestFlat)]
  [outer : i64]) : unit
  (let
    [here : i64 (array-length out.names)]
    (match ty
      [(ast.AstType.Ref lifetime inner)
        (normalize-test-flat-push! out lifetime inv? outer)
        (normalize-test-flat-walk
          variances
          lender?
          (ast.ty-node-get inner)
          inv?
          out
          here)]
      [(ast.AstType.MutRef lifetime inner)
        (normalize-test-flat-push! out lifetime inv? outer)
        (normalize-test-flat-walk
          variances
          lender?
          (ast.ty-node-get inner)
          true
          out
          here)]
      [(ast.AstType.Region lifetime inner)
        (normalize-test-flat-push! out lifetime inv? outer)
        (normalize-test-flat-walk
          variances
          lender?
          (ast.ty-node-get inner)
          inv?
          out
          here)]
      [(ast.AstType.Invalidate lifetime inner)
        (normalize-test-flat-push! out lifetime true outer)
        (normalize-test-flat-walk
          variances
          lender?
          (ast.ty-node-get inner)
          true
          out
          here)]
      [(or (ast.AstType.EnumArgs name lifetimes)
           (ast.AstType.StructArgs name lifetimes))
        (normalize-test-flat-lifetimes
          variances
          lender?
          name
          (& (deref lifetimes))
          inv?
          out
          outer)]
      [(ast.AstType.VarArgs _ lifetimes)
        (normalize-test-flat-lifetimes
          variances
          lender?
          -1
          (& (deref lifetimes))
          true
          out
          outer)]
      [(ast.AstType.Tuple elems)
        (normalize-test-flat-list
          variances
          lender?
          (& (deref elems))
          inv?
          out
          outer)]
      [(ast.AstType.Func args ret)
        (normalize-test-flat-list
          variances
          lender?
          (& (deref args))
          true
          out
          -1)
        (normalize-test-flat-walk
          variances
          lender?
          (ast.ty-node-get ret)
          true
          out
          -1)]
      [(or (ast.AstType.Array elem _) (ast.AstType.DynArray elem)
           (ast.AstType.Box elem) (ast.AstType.Slice elem))
        (normalize-test-flat-walk
          variances
          lender?
          (ast.ty-node-get elem)
          inv?
          out
          outer)]
      [_ unit])))

(define (normalize-test-flat-list
  [variances : (& variances norm.OwnershipNormalizeVariances)]
  [lender? : bool]
  [types : (& types ast.AstTypeList)]
  [inv? : bool]
  [out : (&mut out NormalizeTestFlat)]
  [outer : i64]) : unit
  (let
    [index : i64 0]
    (while (< index (ast.ast-type-list-len types))
      (normalize-test-flat-walk
        variances
        lender?
        (ast.ty-node-get
          (ast.ast-type-list-get types index (ast.ast-type-id-fallback)))
        inv?
        out
        outer)
      (set! index (+ index 1)))))

(define (normalize-test-flat
  [variances : (& variances norm.OwnershipNormalizeVariances)]
  [lender? : bool]
  [id : i64]) : NormalizeTestFlat
  (let
    [out : NormalizeTestFlat (normalize-test-flat-new)]
    (normalize-test-flat-walk
      variances
      lender?
      (ast.ty-node-get id)
      false
      (&mut out)
      -1)
    out))

;; The old position-by-position relation (`normalize-relate!` before #9584).
(define (normalize-test-flat-relate!
  [edges : (&mut edges norm.NormalizeRegionEdges)]
  [nodes : (& nodes norm.NormalizeNodes)]
  [shapes : (& shapes norm.NormalizeShapes)]
  [from-key : i64]
  [from : (& from NormalizeTestFlat)]
  [from-shape : i64]
  [from-skip : i64]
  [to-key : i64]
  [to : (& to NormalizeTestFlat)]
  [to-shape : i64]
  [to-skip : i64]
  [both? : bool]) : unit
  (if (!=
    (- (array-length from.names) from-skip)
    (- (array-length to.names) to-skip))
    (norm.normalize-relate-all!
      edges
      nodes
      shapes
      from-key
      from-shape
      to-key
      to-shape)
    (let
      [count : i64 (- (array-length from.names) from-skip)]
      [index : i64 0]
      [mismatch : bool false]
      (while (and (not both?) (< index count))
        (when
          (!=
            (array-ref from.vars (+ from-skip index))
            (array-ref to.vars (+ to-skip index)))
          (set! mismatch true))
        (set! index (+ index 1)))
      (if mismatch
        (norm.normalize-relate-all!
          edges
          nodes
          shapes
          from-key
          from-shape
          to-key
          to-shape)
        (begin
          (set! index 0)
          (while (< index count)
            (let
              [a : i64
                (norm.normalize-node-of
                  nodes
                  shapes
                  from-key
                  (array-ref from.names (+ from-skip index)))]
              [b : i64
                (norm.normalize-node-of
                  nodes
                  shapes
                  to-key
                  (array-ref to.names (+ to-skip index)))]
              (if (or (< a 0) (< b 0))
                (norm.normalize-relate-all!
                  edges
                  nodes
                  shapes
                  from-key
                  from-shape
                  to-key
                  to-shape)
                (begin
                  (norm.normalize-region-edge! edges a b)
                  (when
                    (or both? (array-ref from.vars (+ from-skip index)))
                    (norm.normalize-region-edge! edges b a)))))
            (set! index (+ index 1))))))))

;; The old reborrow relation (`normalize-relate-reborrow!` before #9584).
(define (normalize-test-flat-reborrow!
  [edges : (&mut edges norm.NormalizeRegionEdges)]
  [nodes : (& nodes norm.NormalizeNodes)]
  [shapes : (& shapes norm.NormalizeShapes)]
  [from-key : i64]
  [from-shape : i64]
  [to-key : i64]
  [to : (& to NormalizeTestFlat)]
  [to-shape : i64]) : unit
  (let
    [index : i64 0]
    [others : (__tl_dyn-array i64) (__tl_make-array i64 0)]
    (norm.normalize-key-nodes-into!
      nodes
      shapes
      from-key
      from-shape
      (&mut others))
    (while (< index (array-length to.names))
      (let
        [name : i64 (array-ref to.names index)]
        [b : i64 (norm.normalize-node-of nodes shapes to-key name)]
        [a : i64 (norm.normalize-node-of nodes shapes from-key name)]
        (cond
          [(< b 0)
            (norm.normalize-relate-all!
              edges
              nodes
              shapes
              from-key
              from-shape
              to-key
              to-shape)]
          [(and (>= a 0) (= index 0))
            (norm.normalize-region-edge-kind! edges a b true)]
          [(>= a 0)
            (norm.normalize-region-edge! edges a b)
            (norm.normalize-region-edge! edges b a)]
          [else
            (let
              [at : i64 0]
              (while (< at (array-length others))
                (norm.normalize-region-edge-kind!
                  edges
                  (array-ref others at)
                  b
                  (= index 0))
                (unless
                  (= index 0)
                  (norm.normalize-region-edge! edges b (array-ref others at)))
                (set! at (+ at 1))))]))
      (set! index (+ index 1)))))

;; The old well-formedness edges (`normalize-shape-outlives!` before #9584).
(define (normalize-test-flat-outlives!
  [edges : (&mut edges norm.NormalizeRegionEdges)]
  [nodes : (& nodes norm.NormalizeNodes)]
  [shapes : (& shapes norm.NormalizeShapes)]
  [key : i64]
  [flat : (& flat NormalizeTestFlat)]) : unit
  (let
    [index : i64 0]
    (while (< index (array-length flat.names))
      (let
        [outer : i64 (array-ref flat.outers index)]
        (when
          (>= outer 0)
          (norm.normalize-region-edge-kind!
            edges
            (norm.normalize-node-of
              nodes
              shapes
              key
              (array-ref flat.names index))
            (norm.normalize-node-of
              nodes
              shapes
              key
              (array-ref flat.names outer))
            true)))
      (set! index (+ index 1)))))

;; Whether edge `index` of `edges` already occurs before it.
(define (normalize-test-edge-repeat?
  [edges : (& edges norm.NormalizeRegionEdges)]
  [index : i64]) : bool
  (let
    [at : i64 0]
    (while (< at index)
      (when
        (and
          (= (array-ref edges.from.items at) (array-ref edges.from.items index))
          (= (array-ref edges.to.items at) (array-ref edges.to.items index))
          (=
            (array-ref edges.outlives.items at)
            (array-ref edges.outlives.items index)))
        (return true))
      (set! at (+ at 1)))
    false))

;; Two edge lists add the same distinct edges in the same first-occurrence
;; order (the loan closure reads only the set; repeats add nothing).
(define (normalize-test-edges-same?
  [a : (& a norm.NormalizeRegionEdges)]
  [b : (& b norm.NormalizeRegionEdges)]) : bool
  (let
    [i : i64 0]
    [j : i64 0]
    (unless (= a.exhausted b.exhausted) (return false))
    (while true
      (while (and (< i a.from.len) (normalize-test-edge-repeat? a i))
        (set! i (+ i 1)))
      (while (and (< j b.from.len) (normalize-test-edge-repeat? b j))
        (set! j (+ j 1)))
      (when
        (or (>= i a.from.len) (>= j b.from.len))
        (return (and (>= i a.from.len) (>= j b.from.len))))
      (unless
        (and
          (= (array-ref a.from.items i) (array-ref b.from.items j))
          (= (array-ref a.to.items i) (array-ref b.to.items j))
          (= (array-ref a.outlives.items i) (array-ref b.outlives.items j)))
        (return false))
      (set! i (+ i 1))
      (set! j (+ j 1)))
    true))

;; The first-occurrence distinct items of `items` from `from`.
(define (normalize-test-distinct
  [items : (& items (__tl_dyn-array i64))]
  [from : i64]) : (__tl_dyn-array i64)
  (let
    [out : (__tl_dyn-array i64) (__tl_make-array i64 0)]
    [index : i64 from]
    (while (< index (array-length items))
      (unless
        (norm.normalize-i64-member? (& out) (array-ref items index))
        (norm.normalize-push-i64! (&mut out) (array-ref items index)))
      (set! index (+ index 1)))
    out))

;; Shape `shape`'s summaries agree with its laid-out positions `flat`.
(define (normalize-test-summaries-agree?
  [shapes : (& shapes norm.NormalizeShapes)]
  [shape : i64]
  [flat : (& flat NormalizeTestFlat)]) : bool
  (let
    [len : i64 (array-length flat.names)]
    [names : (__tl_dyn-array i64) (normalize-test-distinct (& flat.names) 0)]
    [tail : (__tl_dyn-array i64) (normalize-test-distinct (& flat.names) 1)]
    ;; Distinct (name, invariance) rows in first-occurrence order.
    [row-names : (__tl_dyn-array i64) (__tl_make-array i64 0)]
    [row-invs : (__tl_dyn-array bool) (__tl_make-array bool 0)]
    [index : i64 0]
    (while (< index len)
      (let
        [at : i64 0]
        [seen : bool false]
        (while (< at (array-length row-names))
          (when
            (and
              (= (array-ref row-names at) (array-ref flat.names index))
              (= (array-ref row-invs at) (array-ref flat.vars index)))
            (set! seen true))
          (set! at (+ at 1)))
        (unless
          seen
          (norm.normalize-push-i64!
            (&mut row-names)
            (array-ref flat.names index))
          (norm.normalize-push-bool!
            (&mut row-invs)
            (array-ref flat.vars index))))
      (set! index (+ index 1)))
    (unless
      (and
        (= (array-ref shapes.lens.items shape) len)
        (or
          (= len 0)
          (= (norm.normalize-shape-first shapes shape) (array-ref flat.names 0)))
        (=
          (norm.normalize-shape-name-count shapes shape false)
          (array-length names))
        (=
          (norm.normalize-shape-name-count shapes shape true)
          (array-length tail)))
      (return false))
    (set! index 0)
    (while (< index (array-length names))
      (unless
        (=
          (norm.normalize-shape-name-at shapes shape false index)
          (array-ref names index))
        (return false))
      (set! index (+ index 1)))
    (set! index 0)
    (while (< index (array-length tail))
      (unless
        (=
          (norm.normalize-shape-name-at shapes shape true index)
          (array-ref tail index))
        (return false))
      (set! index (+ index 1)))
    ;; A flat shape holds the laid-out positions themselves.
    (when
      (norm.normalize-shape-flat? shapes shape)
      (let
        [first : i64 (array-ref shapes.flat-first.items shape)]
        [at : i64 0]
        (while (< at len)
          (unless
            (and
              (=
                (array-ref shapes.flat-names.items (+ first at))
                (array-ref flat.names at))
              (=
                (array-ref shapes.flat-invs.items (+ first at))
                (array-ref flat.vars at))
              (=
                (array-ref shapes.flat-outers.items (+ first at))
                (array-ref flat.outers at)))
            (return false))
          (set! at (+ at 1)))
        (return (<= len norm.normalize-flat-limit))))
    (let
      [root : i64 (norm.normalize-shape-root shapes shape)]
      (if (< root 0)
        (= (array-length row-names) 0)
        (and
          (=
            (array-ref shapes.node-rows-count.items root)
            (array-length row-names))
          (let
            [first : i64 (array-ref shapes.node-rows-first.items root)]
            [at : i64 0]
            [same : bool true]
            (while (< at (array-length row-names))
              (unless
                (and
                  (=
                    (array-ref shapes.row-pool.items (+ first at))
                    (array-ref row-names at))
                  (=
                    (array-ref shapes.row-invs.items (+ first at))
                    (array-ref row-invs at)))
                (set! same false))
              (set! at (+ at 1)))
            same))))))

;; Region nodes for the comparisons: keys 0 and 1 are places, key 0 with one
;; node per name 1..5 and per huge name 2^62 + 1..5, key 1 without name 5 and
;; its huge twin (unknown nodes).
(define (normalize-test-shape-nodes) : norm.NormalizeNodes
  (let
    [nodes : norm.NormalizeNodes
      (norm.NormalizeNodes
        (norm.normalize-i64s)
        (norm.normalize-i64s)
        (__tl_make-array i64 2)
        (__tl_make-array i64 2)
        (__tl_make-array i64 0)
        (__tl_make-array i64 0)
        0
        0
        -1
        (__tl_make-array bool 2))]
    [name : i64 1]
    (while (<= name 5)
      (norm.normalize-node-add! (&mut nodes) 0 name)
      (norm.normalize-node-add! (&mut nodes) 0 (+ 4611686018427387904 name))
      (set! name (+ name 1)))
    (set! (array-ref nodes.place-first 0) 0)
    (set! (array-ref nodes.place-count 0) 10)
    (set! (array-ref nodes.place-first 1) nodes.keys.len)
    (set! name 4)
    (while (>= name 1)
      (norm.normalize-node-add! (&mut nodes) 1 name)
      (norm.normalize-node-add! (&mut nodes) 1 (+ 4611686018427387904 name))
      (set! name (- name 1)))
    (set! (array-ref nodes.place-count 1) 8)
    nodes))

;; Nominals for the generated types: 501 has a covariant and an invariant
;; lifetime, 502 one bivariant (in the lender lane) covariant one.
(define (normalize-test-shape-variances [lender? : bool]) : norm.OwnershipNormalizeVariances
  (let
    [variances : norm.OwnershipNormalizeVariances
      (norm.ownership-normalize-variances-empty)]
    [names : (__tl_dyn-array i64) (__tl_make-array i64 2)]
    [starts : (__tl_dyn-array i64) (__tl_make-array i64 2)]
    [counts : (__tl_dyn-array i64) (__tl_make-array i64 2)]
    [covariant : (__tl_dyn-array bool) (__tl_make-array bool 3)]
    [bivariant : (__tl_dyn-array bool) (__tl_make-array bool 3)]
    (set! (array-ref names 0) 501)
    (set! (array-ref names 1) 502)
    (set! (array-ref starts 0) 0)
    (set! (array-ref starts 1) 2)
    (set! (array-ref counts 0) 2)
    (set! (array-ref counts 1) 1)
    (set! (array-ref covariant 0) true)
    (set! (array-ref covariant 2) true)
    (set! (array-ref bivariant 2) true)
    (set! variances.names names)
    (set! variances.starts starts)
    (set! variances.counts counts)
    (set! variances.covariant covariant)
    (when
      lender?
      (let
        [arenas : (__tl_dyn-array norm.OwnershipNormalizeArena)
          (__tl_make-array norm.OwnershipNormalizeArena 1)]
        (set!
          (array-ref arenas 0)
          (norm.OwnershipNormalizeArena
            (__tl_make-array i64 0)
            (__tl_make-array i64 0)
            bivariant))
        (set!
          variances.lenders
          (norm.OwnershipNormalizeLenderInput.Gated arenas))))
    variances))

(define normalize-test-shape-seed : i64
  12345)

(define (normalize-test-shape-rand [bound : i64]) : i64
  (set!
    normalize-test-shape-seed
    (% (+ (* normalize-test-shape-seed 1103515245) 12345) 2147483648))
  (% (shr normalize-test-shape-seed 8) bound))

(define (normalize-test-shape-type [ty : ast.AstType]) : i64
  (ast.ty-node-push (& ty)))

;; A lifetime name: mostly 1..5, sometimes one past 2^62, as generated arena
;; brands are (names span the whole i64 range).
(define (normalize-test-shape-name) : i64
  (let
    [name : i64 (+ 1 (normalize-test-shape-rand 5))]
    (if (= (normalize-test-shape-rand 8) 0)
      (+ 4611686018427387904 name)
      name)))

(define (normalize-test-shape-pair [a : i64] [b : i64]) : i64
  (let
    [list : ast.AstTypeList (ast.ast-type-list-new)]
    (ast.ast-type-list-push (&mut list) a)
    (ast.ast-type-list-push (&mut list) b)
    (normalize-test-shape-type (ast.AstType.Tuple (box list)))))

(define (normalize-test-shape-lifetimes [count : i64]) : (Box
    ast.AstLifetimeList)
  (let
    [list : ast.AstLifetimeList (ast.ast-lifetime-list-new)]
    [index : i64 0]
    (while (< index count)
      (ast.ast-lifetime-list-push (&mut list) (normalize-test-shape-name))
      (set! index (+ index 1)))
    (box list)))

;; A random type of at most `depth` type edges over lifetimes 1..5; `flip?`
;; swaps `&` and `&mut` (the same shape with other variances). `pool` holds
;; earlier types, reused to make shared DAGs.
(define (normalize-test-shape-random
  [depth : i64]
  [flip? : bool]
  [pool : (&mut pool (__tl_dyn-array i64))]) : i64
  (let
    [pick : i64 (normalize-test-shape-rand 12)]
    [name : i64 (normalize-test-shape-name)]
    [id : i64
      (cond
        [(and (> (array-length pool) 0) (= pick 0))
          (array-ref pool (normalize-test-shape-rand (array-length pool)))]
        [(or (<= depth 0) (= pick 1))
          (if (= (normalize-test-shape-rand 2) 0)
            (normalize-test-shape-type ast.AstType.I64)
            (normalize-test-shape-type
              (ast.AstType.StructArgs
                (+ 501 (normalize-test-shape-rand 2))
                (normalize-test-shape-lifetimes
                  (+ 1 (normalize-test-shape-rand 2))))))]
        [(= pick 2)
          (let
            [inner : i64 (normalize-test-shape-random (- depth 1) flip? pool)]
            (normalize-test-shape-type
              (if flip?
                (ast.AstType.MutRef name inner)
                (ast.AstType.Ref name inner))))]
        [(= pick 3)
          (let
            [inner : i64 (normalize-test-shape-random (- depth 1) flip? pool)]
            (normalize-test-shape-type
              (if flip?
                (ast.AstType.Ref name inner)
                (ast.AstType.MutRef name inner))))]
        [(= pick 4)
          (normalize-test-shape-type
            (ast.AstType.Region
              name
              (normalize-test-shape-random (- depth 1) flip? pool)))]
        [(= pick 5)
          (normalize-test-shape-type
            (ast.AstType.Invalidate
              name
              (normalize-test-shape-random (- depth 1) flip? pool)))]
        [(= pick 6)
          (normalize-test-shape-type
            (ast.AstType.VarArgs 0 (normalize-test-shape-lifetimes 2)))]
        [(= pick 7)
          (let
            [args : ast.AstTypeList (ast.ast-type-list-new)]
            (ast.ast-type-list-push
              (&mut args)
              (normalize-test-shape-random (- depth 1) flip? pool))
            (normalize-test-shape-type
              (ast.AstType.Func
                (box args)
                (normalize-test-shape-random (- depth 1) flip? pool))))]
        [(= pick 8)
          (normalize-test-shape-type
            (ast.AstType.DynArray
              (normalize-test-shape-random (- depth 1) flip? pool)))]
        [else
          (let
            [a : i64 (normalize-test-shape-random (- depth 1) flip? pool)]
            (normalize-test-shape-pair a a))])]
    (norm.normalize-push-i64! pool id)
    id))

;; One comparison of the DAG relations of `from` and `to` (shapes `fs`, `ts`)
;; with the old position-by-position ones.
(define (normalize-test-shape-relations-agree?
  [shapes : (& shapes norm.NormalizeShapes)]
  [nodes : (& nodes norm.NormalizeNodes)]
  [fs : i64]
  [from : (& from NormalizeTestFlat)]
  [ts : i64]
  [to : (& to NormalizeTestFlat)]) : bool
  (let
    [ok : bool true]
    [mode : i64 0]
    (while (< mode 4)
      (let
        [both? : bool (>= mode 2)]
        [to-skip : i64 (% mode 2)]
        [old : norm.NormalizeRegionEdges
          (norm.normalize-region-edges-empty 1000000 1000000)]
        [new : norm.NormalizeRegionEdges
          (norm.normalize-region-edges-empty 1000000 1000000)]
        (when
          (or (= to-skip 0) (> (array-length to.names) 0))
          (normalize-test-flat-relate!
            (&mut old)
            nodes
            shapes
            0
            from
            fs
            0
            1
            to
            ts
            to-skip
            both?)
          (norm.normalize-relate!
            (&mut new)
            nodes
            shapes
            0
            fs
            0
            1
            ts
            to-skip
            both?)
          (unless (normalize-test-edges-same? (& old) (& new)) (set! ok false))))
      (set! mode (+ mode 1)))
    (let
      [old : norm.NormalizeRegionEdges
        (norm.normalize-region-edges-empty 1000000 1000000)]
      [new : norm.NormalizeRegionEdges
        (norm.normalize-region-edges-empty 1000000 1000000)]
      (normalize-test-flat-reborrow! (&mut old) nodes shapes 0 fs 1 to ts)
      (norm.normalize-relate-reborrow! (&mut new) nodes shapes 0 fs 1 ts)
      (unless (normalize-test-edges-same? (& old) (& new)) (set! ok false)))
    (let
      [old : norm.NormalizeRegionEdges
        (norm.normalize-region-edges-empty 1000000 1000000)]
      [new : norm.NormalizeRegionEdges
        (norm.normalize-region-edges-empty 1000000 1000000)]
      (normalize-test-flat-outlives! (&mut old) nodes shapes 0 from)
      (norm.normalize-shape-outlives! (&mut new) nodes shapes 0 fs)
      (unless (normalize-test-edges-same? (& old) (& new)) (set! ok false)))
    ok))

;; Random types in both lanes: summaries, zips (aligned, renamed, regrouped,
;; variance-flipped and unaligned), reborrows and outlives edges all match
;; the laid-out walk.
(define (normalize-test-shape-differential?) : bool
  (let
    [ok : bool true]
    [trial : i64 0]
    (set! normalize-test-shape-seed 12345)
    (while (and ok (< trial 800))
      (let
        [lender? : bool (= (% trial 2) 1)]
        [variances : norm.OwnershipNormalizeVariances
          (normalize-test-shape-variances lender?)]
        [shapes : norm.NormalizeShapes
          (norm.normalize-shapes-new 2 0 lender? 1000000 33554432)]
        [nodes : norm.NormalizeNodes (normalize-test-shape-nodes)]
        [pool : (__tl_dyn-array i64) (__tl_make-array i64 0)]
        [seed : i64 normalize-test-shape-seed]
        ;; The last 200 trials draw deeper types: longer shapes, kept as DAGs.
        [depth : i64
          (if (< trial 600)
            5
            8)]
        [a : i64 (normalize-test-shape-random depth false (&mut pool))]
        [after : i64 normalize-test-shape-seed]
        ;; The same draws flipped: equal length, other variances.
        [_flip : unit (set! normalize-test-shape-seed seed)]
        [scratch : (__tl_dyn-array i64) (__tl_make-array i64 0)]
        [flipped : i64 (normalize-test-shape-random depth true (&mut scratch))]
        [_resume : unit (set! normalize-test-shape-seed after)]
        [b : i64 (normalize-test-shape-random depth false (&mut pool))]
        [c : i64 (normalize-test-shape-random 3 false (&mut pool))]
        ;; Regrouped: ((a b) c) against (a (b c)).
        [left : i64
          (normalize-test-shape-pair (normalize-test-shape-pair a b) c)]
        [right : i64
          (normalize-test-shape-pair a (normalize-test-shape-pair b c))]
        [ids : (__tl_dyn-array i64) (__tl_make-array i64 6)]
        [shape-ids : (__tl_dyn-array i64) (__tl_make-array i64 6)]
        [flats : (__tl_dyn-array NormalizeTestFlat)
          (__tl_make-array NormalizeTestFlat 6)]
        [index : i64 0]
        (set! (array-ref ids 0) a)
        (set! (array-ref ids 1) flipped)
        (set! (array-ref ids 2) b)
        (set! (array-ref ids 3) left)
        (set! (array-ref ids 4) right)
        (set! (array-ref ids 5) c)
        (while (< index 6)
          (match (norm.normalize-shape-add!
            (&mut shapes)
            (& variances)
            (ast.ty-node-get (array-ref ids index)))
            [(norm.NormalizeInt.Ok id) (set! (array-ref shape-ids index) id)]
            [(norm.NormalizeInt.Err _) (set! ok false)])
          (set!
            (array-ref flats index)
            (normalize-test-flat (& variances) lender? (array-ref ids index)))
          (when
            ok
            (unless
              (normalize-test-summaries-agree?
                (& shapes)
                (array-ref shape-ids index)
                (& (array-ref flats index)))
              (set! ok false)))
          (set! index (+ index 1)))
        (set! index 0)
        (while (and ok (< index 36))
          (let
            [i : i64 (/ index 6)]
            [j : i64 (% index 6)]
            (unless
              (normalize-test-shape-relations-agree?
                (& shapes)
                (& nodes)
                (array-ref shape-ids i)
                (& (array-ref flats i))
                (array-ref shape-ids j)
                (& (array-ref flats j)))
              (set! ok false)))
          (set! index (+ index 1))))
      (set! trial (+ trial 1)))
    ok))

;; A balanced tuple tree of 2^`depth` copies of `leaf`.
(define (normalize-test-shape-balanced [leaf : i64] [depth : i64]) : i64
  (if (= depth 0)
    leaf
    (let
      [half : i64 (normalize-test-shape-balanced leaf (- depth 1))]
      (normalize-test-shape-pair half half))))

;; `count` copies of `leaf` as balanced blocks, largest first (or last).
(define (normalize-test-shape-blocks
  [leaf : i64]
  [count : i64]
  [largest-first? : bool]) : i64
  (let
    [result : i64 -1]
    [bit : i64 0]
    (while (< bit 20)
      (let
        [at : i64
          (if largest-first?
            bit
            (- 19 bit))]
        (when
          (> (bit-and count (shl 1 at)) 0)
          (let
            [block : i64 (normalize-test-shape-balanced leaf at)]
            (set!
              result
              (cond
                [(< result 0) block]
                [largest-first? (normalize-test-shape-pair block result)]
                [else (normalize-test-shape-pair result block)])))))
      (set! bit (+ bit 1)))
    result))

;; Unaligned equal-length DAGs of 4095, 4096 and 4097 positions relate as the
;; laid-out walk does, within budget: balanced blocks against the same count
;; behind one leading leaf, so no aligned node pair meets until the leaves,
;; and the zip descends (charged, not cut off) rather than taking the
;; same-node shortcut.
(define (normalize-test-shape-unaligned?) : bool
  (let
    [ok : bool true]
    [variances : norm.OwnershipNormalizeVariances
      (normalize-test-shape-variances false)]
    [nodes : norm.NormalizeNodes (normalize-test-shape-nodes)]
    [leaf-a : i64
      (normalize-test-shape-type
        (ast.AstType.Ref 1 (normalize-test-shape-type ast.AstType.I64)))]
    [leaf-b : i64
      (normalize-test-shape-type
        (ast.AstType.MutRef 2 (normalize-test-shape-type ast.AstType.I64)))]
    [count : i64 4095]
    (while (<= count 4097)
      (let
        [shapes : norm.NormalizeShapes
          (norm.normalize-shapes-new 2 0 false 1048576 33554432)]
        [from : i64 (normalize-test-shape-blocks leaf-a count true)]
        [to : i64
          (normalize-test-shape-pair
            leaf-b
            (normalize-test-shape-blocks leaf-a (- count 1) true))]
        [fs : i64
          (match (norm.normalize-shape-add!
            (&mut shapes)
            (& variances)
            (ast.ty-node-get from))
            [(norm.NormalizeInt.Ok id) id]
            [(norm.NormalizeInt.Err _) -1])]
        [ts : i64
          (match (norm.normalize-shape-add!
            (&mut shapes)
            (& variances)
            (ast.ty-node-get to))
            [(norm.NormalizeInt.Ok id) id]
            [(norm.NormalizeInt.Err _) -1])]
        (if (or (< fs 0) (< ts 0))
          (set! ok false)
          (let
            [from-flat : NormalizeTestFlat
              (normalize-test-flat (& variances) false from)]
            [to-flat : NormalizeTestFlat
              (normalize-test-flat (& variances) false to)]
            [probe : norm.NormalizeRegionEdges
              (norm.normalize-region-edges-empty 33554432 1048576)]
            (norm.normalize-relate!
              (&mut probe)
              (& nodes)
              (& shapes)
              0
              fs
              0
              1
              ts
              0
              true)
            (unless
              (and
                (= (array-ref shapes.lens.items fs) count)
                (= (array-ref shapes.lens.items ts) count)
                (!=
                  (norm.normalize-shape-root (& shapes) fs)
                  (norm.normalize-shape-root (& shapes) ts))
                (not probe.exhausted)
                ;; The descent visited the positions, not one shortcut.
                (> probe.work count)
                (normalize-test-shape-relations-agree?
                  (& shapes)
                  (& nodes)
                  fs
                  (& from-flat)
                  ts
                  (& to-flat)))
              (set! ok false)))))
      (set! count (+ count 1)))
    ;; A flat 16-position shape and a reference to it (17 positions, a DAG):
    ;; the borrow relation skips the reference's own position and relates a
    ;; flat shape with a DAG one.
    (let
      [shapes : norm.NormalizeShapes
        (norm.normalize-shapes-new 2 0 false 1048576 33554432)]
      [mixed : i64 (normalize-test-shape-pair leaf-a leaf-b)]
      [inner : i64 (normalize-test-shape-blocks mixed 8 true)]
      [outer : i64 (normalize-test-shape-type (ast.AstType.Ref 3 inner))]
      [fs : i64
        (match (norm.normalize-shape-add!
          (&mut shapes)
          (& variances)
          (ast.ty-node-get inner))
          [(norm.NormalizeInt.Ok id) id]
          [(norm.NormalizeInt.Err _) -1])]
      [ts : i64
        (match (norm.normalize-shape-add!
          (&mut shapes)
          (& variances)
          (ast.ty-node-get outer))
          [(norm.NormalizeInt.Ok id) id]
          [(norm.NormalizeInt.Err _) -1])]
      (if (or (< fs 0) (< ts 0))
        (set! ok false)
        (let
          [from-flat : NormalizeTestFlat
            (normalize-test-flat (& variances) false inner)]
          [to-flat : NormalizeTestFlat
            (normalize-test-flat (& variances) false outer)]
          (unless
            (and
              (norm.normalize-shape-flat? (& shapes) fs)
              (not (norm.normalize-shape-flat? (& shapes) ts))
              (= (array-ref shapes.lens.items ts) 17)
              (normalize-test-shape-relations-agree?
                (& shapes)
                (& nodes)
                fs
                (& from-flat)
                ts
                (& to-flat)))
            (set! ok false)))))
    ok))

;; Records and work used adding `id` to fresh shapes with ample budget.
(define (normalize-test-shape-cost [lender? : bool] [id : i64]) : (Tuple
    i64
    i64)
  (let
    [variances : norm.OwnershipNormalizeVariances
      (normalize-test-shape-variances lender?)]
    [shapes : norm.NormalizeShapes
      (norm.normalize-shapes-new 0 0 lender? 1048576 33554432)]
    (norm.normalize-shape-add! (&mut shapes) (& variances) (ast.ty-node-get id))
    (tuple shapes.records-used shapes.work-used)))

;; Whether adding `id` with exactly `records` and `work` succeeds (1); a
;; failure must be a Resource that records no shape and spends no more than
;; the budget (0), anything else is -1.
(define (normalize-test-shape-fits?
  [lender? : bool]
  [id : i64]
  [records : i64]
  [work : i64]) : i64
  (let
    [variances : norm.OwnershipNormalizeVariances
      (normalize-test-shape-variances lender?)]
    [shapes : norm.NormalizeShapes
      (norm.normalize-shapes-new 0 0 lender? records work)]
    (match (norm.normalize-shape-add!
      (&mut shapes)
      (& variances)
      (ast.ty-node-get id))
      [(norm.NormalizeInt.Ok _) 1]
      [(norm.NormalizeInt.Err (norm.OwnershipNormalizeFailure.Resource))
        (if (and
          (= shapes.roots.len 0)
          (<= shapes.records-used records)
          (<= shapes.work-used work))
          0
          -1)]
      [(norm.NormalizeInt.Err _) -1])))

;; The budget: the exact records and work a shape needs succeed and one less
;; of either fails closed, in both lanes; sharing is charged once; positions
;; past 2^63 overflow closed; the depth bound counts reused nodes as a fresh
;; walk would.
(define (normalize-test-shape-budget-code) : i64
  (let
    [code : i64 0]
    [leaf : i64
      (normalize-test-shape-type
        (ast.AstType.StructArgs 501 (normalize-test-shape-lifetimes 2)))]
    [deep : i64 (normalize-test-shape-balanced leaf 40)]
    [lane : i64 0]
    (while (< lane 2)
      (let
        [lender? : bool (= lane 1)]
        [cost : (Tuple i64 i64) (normalize-test-shape-cost lender? deep)]
        [records : i64 (tuple-ref cost 0)]
        [work : i64 (tuple-ref cost 1)]
        (unless
          (and
            (> records 0)
            (< records 50000)
            (< work 50000)
            (= (normalize-test-shape-fits? lender? deep records work) 1)
            (= (normalize-test-shape-fits? lender? deep (- records 1) work) 0)
            (= (normalize-test-shape-fits? lender? deep records (- work 1)) 0))
          (when (= code 0) (set! code 1))))
      (set! lane (+ lane 1)))
    ;; 2^62 positions fit; 2^63 overflow.
    (let
      [variances : norm.OwnershipNormalizeVariances
        (normalize-test-shape-variances false)]
      [shapes : norm.NormalizeShapes
        (norm.normalize-shapes-new 0 0 false 1048576 33554432)]
      [one : i64
        (normalize-test-shape-type
          (ast.AstType.Ref 1 (normalize-test-shape-type ast.AstType.I64)))]
      ;; A reference has 1 position: 2^62 references, then 2^63.
      (match (norm.normalize-shape-add!
        (&mut shapes)
        (& variances)
        (ast.ty-node-get (normalize-test-shape-balanced one 62)))
        [(norm.NormalizeInt.Ok id)
          (unless
            (= (array-ref shapes.lens.items id) 4611686018427387904)
            (when (= code 0) (set! code 2)))]
        [_ (when (= code 0) (set! code 3))])
      (match (norm.normalize-shape-add!
        (&mut shapes)
        (& variances)
        (ast.ty-node-get (normalize-test-shape-balanced one 63)))
        [(norm.NormalizeInt.Err (norm.OwnershipNormalizeFailure.Resource)) unit]
        [_ (when (= code 0) (set! code 4))]))
    ;; A chain of 200 type edges, reused 56 and 57 edges deeper: the walk
    ;; would reach 256 and 257.
    (let
      [variances : norm.OwnershipNormalizeVariances
        (normalize-test-shape-variances false)]
      [shapes : norm.NormalizeShapes
        (norm.normalize-shapes-new 0 0 false 1048576 33554432)]
      [unit-type : i64 (normalize-test-shape-type ast.AstType.I64)]
      [chain : i64 leaf]
      [index : i64 0]
      (while (< index 200)
        (set! chain (normalize-test-shape-pair chain unit-type))
        (set! index (+ index 1)))
      (match (norm.normalize-shape-add!
        (&mut shapes)
        (& variances)
        (ast.ty-node-get chain))
        [(norm.NormalizeInt.Ok _) unit]
        [_ (when (= code 0) (set! code 5))])
      (let
        [outer : i64 chain]
        [depth : i64 0]
        (while (< depth 57)
          (set! outer (normalize-test-shape-pair outer unit-type))
          (set! depth (+ depth 1))
          (let
            [added : norm.NormalizeInt
              (norm.normalize-shape-add!
                (&mut shapes)
                (& variances)
                (ast.ty-node-get outer))]
            (match added
              [(norm.NormalizeInt.Ok _)
                (when (= depth 57) (when (= code 0) (set! code 6)))]
              [(norm.NormalizeInt.Err (norm.OwnershipNormalizeFailure.Resource))
                (when (< depth 57) (when (= code 0) (set! code 7)))]
              [_ (when (= code 0) (set! code 8))])))))
    code))

;; Region edges are pushed as the positional relation pushed them (duplicates
;; included); their columns' growth is charged first, so a limit too small
;; for a first edge's backing exhausts the graph.
(define (normalize-test-shape-edges?) : bool
  (let
    [edges : norm.NormalizeRegionEdges
      (norm.normalize-region-edges-empty 1000 1000)]
    [tight : norm.NormalizeRegionEdges
      (norm.normalize-region-edges-empty 3 1000)]
    (norm.normalize-region-edge! (&mut edges) 1 2)
    (norm.normalize-region-edge! (&mut edges) 1 2)
    (norm.normalize-region-edge-kind! (&mut edges) 1 2 true)
    (norm.normalize-region-edge! (&mut edges) 2 1)
    (norm.normalize-region-edge! (&mut tight) 1 2)
    (and
      (= edges.from.len 4)
      (not edges.exhausted)
      (>= edges.records 24)
      (= tight.from.len 0)
      tight.exhausted)))

;; Charging reproducers: empty shapes for 1,000 places and 1,000 cached types
;; hold 3,000 cells, so a 44-record budget fails closed before recording a
;; shape; relating under no work allowance allocates and charges nothing; the
;; probe table spreads the packed edge keys (k -> 0) of 512 edges, counts
;; every probe, and stops at its allowance.
(define (normalize-test-shape-charging?) : bool
  (let
    [variances : norm.OwnershipNormalizeVariances
      (normalize-test-shape-variances false)]
    [small : norm.NormalizeShapes
      (norm.normalize-shapes-new 1000 1000 false 44 33554432)]
    [nodes : norm.NormalizeNodes (normalize-test-shape-nodes)]
    [shapes : norm.NormalizeShapes
      (norm.normalize-shapes-new 2 0 false 1048576 33554432)]
    [leaf : i64
      (normalize-test-shape-type
        (ast.AstType.Ref 1 (normalize-test-shape-type ast.AstType.I64)))]
    [left : i64
      (normalize-test-shape-pair leaf (normalize-test-shape-pair leaf leaf))]
    [right : i64
      (normalize-test-shape-pair (normalize-test-shape-pair leaf leaf) leaf)]
    [fs : i64
      (match (norm.normalize-shape-add!
        (&mut shapes)
        (& variances)
        (ast.ty-node-get left))
        [(norm.NormalizeInt.Ok id) id]
        [(norm.NormalizeInt.Err _) -1])]
    [ts : i64
      (match (norm.normalize-shape-add!
        (&mut shapes)
        (& variances)
        (ast.ty-node-get right))
        [(norm.NormalizeInt.Ok id) id]
        [(norm.NormalizeInt.Err _) -1])]
    [none : norm.NormalizeRegionEdges
      (norm.normalize-region-edges-empty 0 1048576)]
    [table : norm.NormalizeProbeTable (norm.normalize-probe-table-new)]
    [ok : bool true]
    [probes : i64 0]
    [k : i64 1]
    (match (norm.normalize-shape-add!
      (&mut small)
      (& variances)
      ast.AstType.I64)
      [(norm.NormalizeInt.Err (norm.OwnershipNormalizeFailure.Resource))
        (unless (= small.roots.len 0) (set! ok false))]
      [_ (set! ok false)])
    (norm.normalize-relate!
      (&mut none)
      (& nodes)
      (& shapes)
      0
      fs
      0
      1
      ts
      0
      false)
    (norm.normalize-relate!
      (&mut none)
      (& nodes)
      (& shapes)
      0
      fs
      0
      1
      ts
      0
      false)
    (unless
      (and
        (>= fs 0)
        (>= ts 0)
        none.exhausted
        (= none.records 0)
        (= none.from.len 0))
      (set! ok false))
    (while (<= k 512)
      (let
        [key : i64 (* (* k 1073741824) 2)]
        (when
          (> (norm.normalize-probe-table-growth (& table)) 0)
          (norm.normalize-probe-table-grow!
            (&mut table)
            (norm.normalize-probe-table-growth (& table))
            1000000)
          (set! probes (+ probes table.probes)))
        (norm.normalize-probe-table-put! (&mut table) key k 1000000)
        (set! probes (+ probes table.probes)))
      (set! k (+ k 1)))
    (set! k 1)
    (while (<= k 512)
      (unless
        (=
          (norm.normalize-probe-table-get!
            (&mut table)
            (* (* k 1073741824) 2)
            0
            1000000)
          k)
        (set! ok false))
      (set! probes (+ probes table.probes))
      (set! k (+ k 1)))
    ;; Spread: far below the 131,328 probes of one shared bucket.
    (unless (and (> probes 0) (< probes 8192)) (set! ok false))
    ;; A lookup with no allowance left stops before probing.
    (norm.normalize-probe-table-get! (&mut table) 7 0 0)
    (unless (and table.stopped (= table.probes 0)) (set! ok false))
    ;; A lookup that runs past its allowance through a crowded run stops with
    ;; the probes it took (charged by its user), not a sentinel.
    (let
      [crowded : norm.NormalizeProbeTable (norm.normalize-probe-table-new)]
      [found : i64 0]
      [key : i64 1]
      (norm.normalize-probe-table-grow! (&mut crowded) 8 100)
      (while (< found 3)
        (when
          (= (norm.normalize-probe-table-start key 3) 0)
          (norm.normalize-probe-table-put! (&mut crowded) key key 100)
          (set! found (+ found 1)))
        (set! key (+ key 1)))
      (while (!= (norm.normalize-probe-table-start key 3) 0)
        (set! key (+ key 1)))
      (norm.normalize-probe-table-get! (&mut crowded) key 0 2)
      (unless (and crowded.stopped (= crowded.probes 2)) (set! ok false)))
    ;; Universal names grow only for names they lack: one shape of 64 names
    ;; added 200 times costs its scratch copies, not 200 universal copies.
    (let
      [many : norm.NormalizeShapes
        (norm.normalize-shapes-new 0 0 false 1048576 33554432)]
      [lifetimes : ast.AstLifetimeList (ast.ast-lifetime-list-new)]
      [name : i64 1]
      [pass : i64 0]
      (while (<= name 64)
        (ast.ast-lifetime-list-push (&mut lifetimes) (+ 1000 name))
        (set! name (+ name 1)))
      (match (norm.normalize-shape-add!
        (&mut many)
        (& variances)
        (ast.AstType.VarArgs 0 (box lifetimes)))
        [(norm.NormalizeInt.Ok id)
          (while (and ok (< pass 200))
            (match (norm.normalize-shape-universal-add! (&mut many) id)
              [(norm.NormalizeUnit.Ok _) unit]
              [_ (set! ok false)])
            (set! pass (+ pass 1)))
          (unless
            (and
              (= (array-length many.universal) 64)
              (< many.records-used 500000))
            (set! ok false))]
        [_ (set! ok false)]))
    ;; Each membership scan is charged: a one-name shape naming the last of
    ;; 1,000 universal names costs at least its 1,000 comparisons.
    (let
      [wide : norm.NormalizeShapes
        (norm.normalize-shapes-new 0 0 false 1048576 33554432)]
      [last : ast.AstLifetimeList (ast.ast-lifetime-list-new)]
      [name : i64 1]
      [before : i64 0]
      (while (<= name 1000)
        (norm.normalize-push-i64! (&mut wide.universal) (+ 5000 name))
        (set! name (+ name 1)))
      (ast.ast-lifetime-list-push (&mut last) 6000)
      (match (norm.normalize-shape-add!
        (&mut wide)
        (& variances)
        (ast.AstType.VarArgs 0 (box last)))
        [(norm.NormalizeInt.Ok id)
          (set! before wide.work-used)
          (match (norm.normalize-shape-universal-add! (&mut wide) id)
            [(norm.NormalizeUnit.Ok _)
              (unless
                (and
                  (>= (- wide.work-used before) 1000)
                  (= (array-length wide.universal) 1000))
                (set! ok false))]
            [_ (set! ok false)])]
        [_ (set! ok false)]))
    ok))

(define (compiler-ownership-normalize-self-test) : i64
  (test.assert-true
    (normalize-test-shape-differential?)
    "compact shapes: summaries, zips, reborrows and outlives edges match the laid-out walk in both lanes")
  (test.assert-true
    (normalize-test-shape-unaligned?)
    "compact shapes: unaligned equal-length DAGs of 4095/4096/4097 relate as the laid-out walk within budget")
  (test.assert-true
    (= (normalize-test-shape-budget-code) 0)
    "compact shapes: exact budget fits, one less fails closed, overflow and the reused-node depth bound fail closed")
  (test.assert-true
    (normalize-test-shape-charging?)
    "compact shapes: constructor cells, unpaid zips and hash probes are charged before they happen")
  (test.assert-true
    (normalize-test-shape-edges?)
    "region edges keep the positional relation's pushes and exhaust at the limit")
  (test.assert-true
    (normalize-test-reaching?)
    "normalizer sparse reaching definitions match the fixpoint with linear visits")
  (test.assert-true
    (normalize-test-transfer-index?)
    "normalizer transfer index preserves every ordered scan match")
  (test.assert-true
    (normalize-test-transfer-fan-in?)
    "normalizer transfer index preserves 1024 fan-in pairs across 4096 places")
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