;; Semantic input for #7690, captured before raw-pointer machine normalization.
;; This module stores evidence; it does not admit any pointer return.
(import stdlib.arena)
(import stdlib.string)
(import stdlib.vector)
(import stdlib.hashmap)
(import (hashmap.hashmap i64 i64) as symbol_map)
(import compiler_ir_types as ir)
(import compiler_diagnostic as diagnostic)

(defenum PointerProofType
  (Missing)
  (Pointer)
  (MutablePointer)
  (Integer)
  (NonPointer))

(defenum PointerProofOperation
  (Parameter i64)
  (Binding)
  (Read i64)
  (Assignment i64)
  (DirectCall ir.CompilerIrSymbolId)
  (IndirectCall)
  (Return)
  (Join)
  (Sequence)
  (Loop)
  (Identity)
  (PointerCast)
  (PointerToInteger)
  (IntegerToPointer)
  (Null)
  (Offset)
  (IntegerCast)
  (AddressOf)
  (MemoryRead)
  (StringData)
  (ArrayData)
  (ProgramArgv)
  (ProgramEnvp)
  (TupleProjection i64)
  (StructProjection i64)
  (ArrayProjection)
  (BoxProjection)
  (Global ir.CompilerIrSymbolId)
  (StaticStorage)
  (Scalar)
  (Unsupported))

;; A reference identifies one semantic occurrence, never a machine variable.
;; Repeated reads of the same binding receive different indices.
(defstruct PointerProofRef
  (owner u64)
  (index i64)
  (abi-reserved i64))

(import (vector.vector PointerProofRef core) as ref_vec)

(defstruct PointerProofUse
  (function ir.CompilerIrSymbolId)
  (operation PointerProofOperation)
  (source-type PointerProofType)
  (operands ref_vec.Vec)
  (path String)
  (span ir.CompilerMaybeSourceSpan))

(import (vector.vector PointerProofUse core) as use_vec)

(defstruct PointerProofFunction
  (symbol ir.CompilerIrSymbolId)
  (parameters ref_vec.Vec)
  (result PointerProofRef)
  (result-type PointerProofType))

(import (vector.vector PointerProofFunction core) as function_vec)

;; The exact immutable sequence backings and their extents bind evidence to the
;; returned, unoptimized program. Analysis must precede any IR mutation.
(defstruct PointerProofProgramIdentity
  (globals u64)
  (global-count i64)
  (functions u64)
  (function-count i64)
  (externs u64)
  (extern-count i64)
  (source-spans u64)
  (source-span-count i64)
  (instruction-spans u64)
  (instruction-span-count i64))

(defenum PointerProofProgramBinding
  (Missing)
  (Bound PointerProofProgramIdentity))

(defstruct PointerProofStorage
  (arena i64)
  (uses use_vec.Vec)
  (functions function_vec.Vec)
  (function-indices symbol_map.Map)
  (binding PointerProofProgramBinding)
  (default-path String)
  (failure String)
  (failure-path String)
  (failure-span ir.CompilerMaybeSourceSpan))

;; The control cell belongs to the caller's handoff lifetime. Its data belongs
;; to a dedicated arena, never to source pools or the interner. Retiring data
;; tombstones the control cell before destroying that arena.
(defstruct PointerProofInput
  (control u64))

(defenum PointerProofRequest
  (Disabled)
  (Requested PointerProofInput))

(defenum ResultPointerProofUse
  (Ok PointerProofUse)
  (Err String))

(defenum ResultPointerProofFunction
  (Ok PointerProofFunction)
  (Err String))

(define (pointer-proof-operation-conversion?
  [operation : PointerProofOperation]) : bool
  (match operation
    [(PointerProofOperation.PointerCast) true]
    [(PointerProofOperation.PointerToInteger) true]
    [(PointerProofOperation.IntegerToPointer) true]
    [_ false]))

(define (pointer-proof-input-new) : PointerProofInput
  (let
    [control : (__tl_dyn-array u64) (__tl_make-array u64 1)]
    [owner : i64 (arena.tl_arena_make_small)]
    [address : u64
      (in-arena
        (arena.Arena owner)
        (let
          [storage : (__tl_dyn-array PointerProofStorage)
            (__tl_make-array PointerProofStorage 1)]
          (begin
            (set!
              (array-ref storage 0)
              (PointerProofStorage
                owner
                (use_vec.new)
                (function_vec.new)
                (symbol_map.with-capacity 8)
                PointerProofProgramBinding.Missing
                ""
                ""
                ""
                ir.CompilerMaybeSourceSpan.No))
            (unsafe
              (ptr->int (__tl_array-data storage))))))]
    (begin
      (set! (array-ref control 0) address)
      (PointerProofInput
        (unsafe
          (ptr->int (__tl_array-data control)))))))

(define (pointer-proof-input-address [input : PointerProofInput]) : u64
  (if (= input.control (cast 0 : u64))
    (cast 0 : u64)
    (unsafe
      (ptr-read (int->ptr input.control : (Ptr u64))))))

(define (pointer-proof-input-storage [input : PointerProofInput]) : PointerProofStorage
  (unsafe
    (ptr-read
      (int->ptr (pointer-proof-input-address input) : (Ptr PointerProofStorage)))))

(define (pointer-proof-input-store!
  [input : PointerProofInput]
  [storage : PointerProofStorage]) : unit
  (unsafe
    (ptr-write!
      (int->ptr
        (pointer-proof-input-address input)
        : (MutPtr PointerProofStorage))
      storage)))

(define (pointer-proof-input-use-default-path!
  [input : PointerProofInput]
  [path : String]) : unit
  (let
    [storage : PointerProofStorage (pointer-proof-input-storage input)]
    (when
      (= (string.string-length (& storage.default-path)) 0)
      (in-arena
        (arena.Arena storage.arena)
        (begin
          (set! storage.default-path (string.copy (& path)))
          (pointer-proof-input-store! input storage))))))

(define (pointer-proof-input-default-path [input : PointerProofInput]) : String
  (let
    [storage : PointerProofStorage (pointer-proof-input-storage input)]
    storage.default-path))

(define (pointer-proof-input-release! [input : PointerProofInput]) : unit
  (when
    (not (= (pointer-proof-input-address input) (cast 0 : u64)))
    (let
      [storage : PointerProofStorage (pointer-proof-input-storage input)]
      (unsafe
        (begin
          (ptr-write! (int->ptr input.control : (MutPtr u64)) (cast 0 : u64))
          ;; lint-allow: raw-arena-op -- tombstone precedes retirement of the input's dedicated arena.
          (arena.tl_arena_destroy storage.arena))))))

(define (pointer-proof-input-fail!
  [input : PointerProofInput]
  [message : String]) : unit
  (let
    [storage : PointerProofStorage (pointer-proof-input-storage input)]
    (when
      (= (string.string-length (& storage.failure)) 0)
      (in-arena
        (arena.Arena storage.arena)
        (begin
          (set! storage.failure (string.copy (& message)))
          (pointer-proof-input-store! input storage))))))

(define (pointer-proof-input-fail-at!
  [input : PointerProofInput]
  [message : String]
  [path : String]
  [span : ir.CompilerMaybeSourceSpan]) : unit
  (let
    [storage : PointerProofStorage (pointer-proof-input-storage input)]
    (when
      (= (string.string-length (& storage.failure)) 0)
      (in-arena
        (arena.Arena storage.arena)
        (begin
          (set! storage.failure (string.copy (& message)))
          (set! storage.failure-path (string.copy (& path)))
          (set! storage.failure-span span)
          (pointer-proof-input-store! input storage))))))

(define (pointer-proof-input-diagnostic
  [input : PointerProofInput]
  [message : String]) : diagnostic.CompilerDiagnostic
  (if (= (pointer-proof-input-address input) (cast 0 : u64))
    (diagnostic.compiler-diagnostic-at-start "" message)
    (let
      [storage : PointerProofStorage (pointer-proof-input-storage input)]
      [path : String
        (if (> (string.string-length (& storage.failure-path)) 0)
          (string.copy (& storage.failure-path))
          (string.copy (& storage.default-path)))]
      (match storage.failure-span
        [(ir.CompilerMaybeSourceSpan.Some span)
          (diagnostic.compiler-diagnostic-from-ast-span path span message)]
        [_ (diagnostic.compiler-diagnostic-at-start path message)]))))

(define (pointer-proof-input-push!
  [input : PointerProofInput]
  [function : ir.CompilerIrSymbolId]
  [operation : PointerProofOperation]
  [source-type : PointerProofType]
  [operands : ref_vec.Vec]
  [path : String]
  [span : ir.CompilerMaybeSourceSpan]) : PointerProofRef
  (let
    [storage : PointerProofStorage (pointer-proof-input-storage input)]
    [index : i64 (use_vec.len (& storage.uses))]
    (in-arena
      (arena.Arena storage.arena)
      (begin
        (match source-type
          [(PointerProofType.Missing)
            (pointer-proof-input-fail-at!
              input
              "pointer proof: missing source type"
              (string.copy (& path))
              span)]
          [_ unit])
        (match span
          [(ir.CompilerMaybeSourceSpan.No)
            (when
              (pointer-proof-operation-conversion? operation)
              (pointer-proof-input-fail-at!
                input
                "pointer proof: missing conversion source location"
                (string.copy (& path))
                span))]
          [_ unit])
        (set! storage (pointer-proof-input-storage input))
        (use_vec.push-ref!
          (&mut storage.uses)
          (PointerProofUse
            function
            operation
            source-type
            operands
            (string.copy (& path))
            span))
        (pointer-proof-input-store! input storage)
        (PointerProofRef input.control index 0)))))

(define (pointer-proof-input-add-function!
  [input : PointerProofInput]
  [function : PointerProofFunction]) : unit
  (let
    [storage : PointerProofStorage (pointer-proof-input-storage input)]
    (in-arena
      (arena.Arena storage.arena)
      (begin
        (symbol_map.insert-ref!
          (&mut storage.function-indices)
          (ir.compiler-ir-symbol-id-value function.symbol)
          (function_vec.len (& storage.functions)))
        (function_vec.push-ref! (&mut storage.functions) function)
        (pointer-proof-input-store! input storage)))))

(define (pointer-proof-input-operands [input : PointerProofInput]) : ref_vec.Vec
  (let
    [storage : PointerProofStorage (pointer-proof-input-storage input)]
    (in-arena (arena.Arena storage.arena) (ref_vec.new))))

(define (pointer-proof-input-push-operand!
  [input : PointerProofInput]
  [operands : (&mut operands ref_vec.Vec)]
  [reference : PointerProofRef]) : unit
  (let
    [storage : PointerProofStorage (pointer-proof-input-storage input)]
    (in-arena
      (arena.Arena storage.arena)
      (ref_vec.push-ref! operands reference))))

(define (pointer-proof-program-identity
  [program : ir.CompilerIrProgram]
  [spans : ir.CompilerSourceSpans]) : PointerProofProgramIdentity
  (match program
    [(ir.CompilerIrProgram.Program globals functions externs)
      (match spans
        [(ir.CompilerSourceSpans.Spans entries instructions _)
          (PointerProofProgramIdentity
            (unsafe
              (ptr->int (__tl_array-data globals.slots)))
            globals.len
            (unsafe
              (ptr->int (__tl_array-data functions.slots)))
            functions.len
            (unsafe
              (ptr->int (__tl_array-data externs.slots)))
            externs.len
            (unsafe
              (ptr->int (__tl_array-data entries.slots)))
            entries.len
            (unsafe
              (ptr->int (__tl_array-data instructions.slots)))
            instructions.len)])]))

(define (pointer-proof-input-bind!
  [input : PointerProofInput]
  [program : ir.CompilerIrProgram]
  [spans : ir.CompilerSourceSpans]) : unit
  (let
    [storage : PointerProofStorage (pointer-proof-input-storage input)]
    (begin
      (match (unsafe
        (ptr-read (ptr-addr-of program)))
        [(ir.CompilerIrProgram.Program _ functions _)
          (let
            [index : i64 0]
            (begin
              (unless
                (= functions.len (function_vec.len (& storage.functions)))
                (pointer-proof-input-fail!
                  input
                  "pointer proof: missing emitted-function metadata"))
              (while (< index functions.len)
                (match (unsafe
                  (ptr-read
                    (ptr-offset (__tl_array-data functions.slots) index)))
                  [(ir.CompilerIrFunction.Function symbol _ _ _ _ _)
                    (begin
                      (when
                        (<
                          (symbol_map.get-value-or
                            (& storage.function-indices)
                            symbol
                            -1)
                          0)
                        (pointer-proof-input-fail!
                          input
                          "pointer proof: mismatched emitted-function identity"))
                      (set! index (+ index 1)))]))))])
      (set! storage (pointer-proof-input-storage input))
      (set!
        storage.binding
        (PointerProofProgramBinding.Bound
          (pointer-proof-program-identity program spans)))
      (pointer-proof-input-store! input storage))))

(define (pointer-proof-input-begin-error [input : PointerProofInput]) : String
  (if (= (pointer-proof-input-address input) (cast 0 : u64))
    "pointer proof: missing or retired requested owner"
    (let
      [storage : PointerProofStorage (pointer-proof-input-storage input)]
      (match storage.binding
        [(PointerProofProgramBinding.Bound _)
          "pointer proof: input already belongs to a lowering job"]
        [(PointerProofProgramBinding.Missing)
          (if (or
            (> (use_vec.len (& storage.uses)) 0)
            (> (string.string-length (& storage.failure)) 0))
            "pointer proof: incomplete input cannot be reused"
            "")]))))

(define (pointer-proof-input-error
  [input : PointerProofInput]
  [program : ir.CompilerIrProgram]
  [spans : ir.CompilerSourceSpans]) : String
  (if (= (pointer-proof-input-address input) (cast 0 : u64))
    "pointer proof: missing or retired input"
    (let
      [storage : PointerProofStorage (pointer-proof-input-storage input)]
      (if (> (string.string-length (& storage.failure)) 0)
        storage.failure
        (match storage.binding
          [(PointerProofProgramBinding.Missing)
            "pointer proof: incomplete lowering input"]
          [(PointerProofProgramBinding.Bound expected)
            (let
              [actual : PointerProofProgramIdentity
                (pointer-proof-program-identity program spans)]
              (if (and
                (= expected.globals actual.globals)
                (= expected.global-count actual.global-count)
                (= expected.functions actual.functions)
                (= expected.function-count actual.function-count)
                (= expected.externs actual.externs)
                (= expected.extern-count actual.extern-count)
                (= expected.source-spans actual.source-spans)
                (= expected.source-span-count actual.source-span-count)
                (= expected.instruction-spans actual.instruction-spans)
                (=
                  expected.instruction-span-count
                  actual.instruction-span-count))
                ""
                "pointer proof: input belongs to a different lowered program or source provenance"))])))))

(define (pointer-proof-input-use
  [input : PointerProofInput]
  [reference : PointerProofRef]) : ResultPointerProofUse
  (if (or
    (not (= input.control reference.owner))
    (= (pointer-proof-input-address input) (cast 0 : u64)))
    (ResultPointerProofUse.Err
      "pointer proof: foreign or retired semantic reference")
    (let
      [storage : PointerProofStorage (pointer-proof-input-storage input)]
      (if (or
        (> (string.string-length (& storage.failure)) 0)
        (< reference.index 0)
        (>= reference.index (use_vec.len (& storage.uses))))
        (ResultPointerProofUse.Err "pointer proof: missing semantic occurrence")
        (match storage.binding
          [(PointerProofProgramBinding.Missing)
            (ResultPointerProofUse.Err "pointer proof: incomplete input")]
          [_
            (ResultPointerProofUse.Ok
              (unsafe
                (ptr-read
                  (ptr-offset
                    (__tl_array-data storage.uses.slots)
                    reference.index))))])))))

(define (pointer-proof-input-use-count [input : PointerProofInput]) : i64
  (if (= (pointer-proof-input-address input) (cast 0 : u64))
    -1
    (let
      [storage : PointerProofStorage (pointer-proof-input-storage input)]
      (use_vec.len (& storage.uses)))))

(define (pointer-proof-input-function [input : PointerProofInput] [index : i64]) : ResultPointerProofFunction
  (if (= (pointer-proof-input-address input) (cast 0 : u64))
    (ResultPointerProofFunction.Err "pointer proof: missing or retired input")
    (let
      [storage : PointerProofStorage (pointer-proof-input-storage input)]
      (if (or
        (> (string.string-length (& storage.failure)) 0)
        (< index 0)
        (>= index (function_vec.len (& storage.functions))))
        (ResultPointerProofFunction.Err
          "pointer proof: missing function binding")
        (match storage.binding
          [(PointerProofProgramBinding.Missing)
            (ResultPointerProofFunction.Err "pointer proof: incomplete input")]
          [_
            (ResultPointerProofFunction.Ok
              (unsafe
                (ptr-read
                  (ptr-offset (__tl_array-data storage.functions.slots) index))))])))))