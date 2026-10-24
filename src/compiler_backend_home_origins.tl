;; Instruction-scoped logical identities before the frame-coloring renumber.
;; This table describes the actual remap; it must never change allocation.
(import compiler_ir_types as ir)
(import compiler_regalloc as regalloc)
(import compiler_liveness as live)
(import compiler_owned_view as owned_view)
(import stdlib.dense_list as dense_list)
(import stdlib.iterator)
(import stdlib.string)
(import stdlib.hashmap)
(import (hashmap.hashmap i64 i64) as block_index)

(defenum CompilerBackendHomePosition
  (Definition)
  (Parameter)
  ;; AddrOf's storage authority is distinct from a value read.
  (Address)
  ;; The canonical IR operand visitor's constructor order, including literals.
  (Use i64))

(defstruct CompilerBackendHomeBinding
  (emitted i64)
  (logical i64)
  (position CompilerBackendHomePosition))

(defstruct CompilerBackendHomeBindingList
  (slots (__tl_dyn-array CompilerBackendHomeBinding))
  (len i64))

(dense_list.compiler-dense-list-operations
  CompilerBackendHomeBinding
  CompilerBackendHomeBindingList
  compiler-backend-home-binding-list
  caller-provided-fallback
  zero-capacity
  compiler-dense-list-unused-shared-zero-storage
  append-from)

(defstruct CompilerBackendHomeBindingBuilder
  (bindings CompilerBackendHomeBindingList)
  (use-index i64)
  (error String))

(defenum CompilerBackendHomeBindingsResult
  (Ok CompilerBackendHomeBindingList)
  (Err String))

(defenum CompilerBackendHomeQuery
  (Definition)
  (Parameter)
  (Address)
  (AnyUse)
  (Use i64))

(defenum CompilerBackendLogicalHomeResult
  (Ok i64)
  (Err String))

(defstruct CompilerBackendHomeSite
  (block i64)
  (instruction i64)
  (bindings CompilerBackendHomeBindingList))

(defstruct CompilerBackendHomePlan
  (function i64)
  (entry-block i64)
  (parameters CompilerBackendHomeBindingList)
  (sites (__tl_dyn-array CompilerBackendHomeSite))
  (bytes (__tl_dyn-array i64)))

(defstruct CompilerBackendHomePlanInput
  (function i64)
  (logical-count i64)
  (emitted-count i64)
  (params ir.CompilerIrParamSeq)
  (original ir.CompilerIrBlockList)
  (placed ir.CompilerIrBlockList)
  (coloring regalloc.CompilerRegColoring)
  (groups live.CompilerLiveI64Set))

(defenum CompilerBackendHomePlanResult
  (Ok CompilerBackendHomePlan)
  (Err String))

(defstruct CompilerBackendLogicalHome
  (id i64)
  (bytes i64))

(defenum CompilerBackendPlannedHomeResult
  (Ok CompilerBackendLogicalHome)
  (Err String))

(define (compiler-backend-home-binding-add!
  [builder : (&mut builder CompilerBackendHomeBindingBuilder)]
  [coloring : (& regalloc.CompilerRegColoring)]
  [logical-count : i64]
  [logical : i64]
  [position : CompilerBackendHomePosition]) : unit
  (unless (string.eq (& builder.error) "") (return unit))
  (when
    (or (< logical 0) (>= logical logical-count))
    (set! builder.error "stack traffic: original home is outside its function")
    (return unit))
  (let
    [emitted : i64
      (match coloring
        [(None) logical]
        [(Remap remap _)
          (regalloc.compiler-reg-remap-id
            (owned_view.compiler-owned-reference-shared-view remap)
            logical)])]
    (when
      (< emitted 0)
      (set! builder.error "stack traffic: live home has no emitted color")
      (return unit))
    (compiler-backend-home-binding-list-push
      (&mut builder.bindings)
      (CompilerBackendHomeBinding emitted logical position))))

(define (compiler-backend-home-binding-use!
  [builder : (&mut builder CompilerBackendHomeBindingBuilder)]
  [coloring : (& regalloc.CompilerRegColoring)]
  [logical-count : i64]
  [_role : ir.CompilerIrOperandRole]
  [value : ir.CompilerIrValue]) : unit
  (match value
    [(Var logical)
      (let
        [position : i64 builder.use-index]
        (compiler-backend-home-binding-add!
          builder
          coloring
          logical-count
          logical
          (Use position)))]
    [_ unit])
  (set! builder.use-index (+ builder.use-index 1)))

;; Called on the uncolored instruction with the exact coloring used by
;; compiler-reg-remap-instr. AddrOf's raw storage slot is not a value use and
;; does not authorize a memory read; its separate address authority is retained
;; by that instruction's emitter.
(define (compiler-backend-home-bindings
  [instr : (& ir.CompilerIrInstr)]
  [coloring : (& regalloc.CompilerRegColoring)]
  [logical-count : i64]) : CompilerBackendHomeBindingsResult
  (when
    (< logical-count 0)
    (return (Err "stack traffic: invalid original home extent")))
  (let
    [builder : CompilerBackendHomeBindingBuilder
      (CompilerBackendHomeBindingBuilder
        (compiler-backend-home-binding-list-new)
        0
        "")]
    [dst : i64 (ir.compiler-ir-instr-dst instr)]
    (when
      (>= dst 0)
      (compiler-backend-home-binding-add!
        (&mut builder)
        coloring
        logical-count
        dst
        (Definition)))
    (match instr
      [(AddrOf _ storage)
        (compiler-backend-home-binding-add!
          (&mut builder)
          coloring
          logical-count
          storage
          (Address))]
      [_ unit])
    (ir.compiler-ir-instr-visit-uses
      (owned_view.compiler-owned-reference-shared-view instr)
      compiler-backend-home-binding-use!
      (&mut builder)
      coloring
      logical-count)
    (if (string.eq (& builder.error) "")
      (Ok builder.bindings)
      (Err builder.error))))

;; A colored ID alone is insufficient when two original uses share a color.
;; The emitting parent must then supply its explicit canonical operand index.
(define (compiler-backend-home-resolve
  [bindings : (& bindings CompilerBackendHomeBindingList)]
  [emitted : i64]
  [query : CompilerBackendHomeQuery]) : CompilerBackendLogicalHomeResult
  (when
    (or
      (< emitted 0)
      (< bindings.len 0)
      (> bindings.len (array-length bindings.slots))
      (match query
        [(Use index) (< index 0)]
        [_ false]))
    (return (Err "stack traffic: invalid original-home lookup")))
  (let
    [logical : i64 -1]
    (for [index (iterator.range 0 bindings.len)]
      (let
        [binding : (& bindings CompilerBackendHomeBinding)
          (& (array-ref bindings.slots index))]
        [matches : bool
          (and
            (= binding.emitted emitted)
            (match query
              [(Definition)
                (match (& binding.position)
                  [(Definition) true]
                  [_ false])]
              [(Parameter)
                (match (& binding.position)
                  [(Parameter) true]
                  [_ false])]
              [(Address)
                (match (& binding.position)
                  [(Address) true]
                  [_ false])]
              [(AnyUse)
                (match (& binding.position)
                  [(Use _) true]
                  [_ false])]
              [(Use expected)
                (match (& binding.position)
                  [(Use actual) (= actual expected)]
                  [_ false])]))]
        (when
          (or
            (< binding.logical 0)
            (< binding.emitted 0)
            (match (& binding.position)
              [(Use index) (< index 0)]
              [_ false]))
          (return (Err "stack traffic: invalid original-home binding")))
        (when
          matches
          (when
            (and (>= logical 0) (!= logical binding.logical))
            (return
              (Err
                "stack traffic: colored operand needs an explicit source position")))
          (set! logical binding.logical))))
    (if (< logical 0)
      (Err "stack traffic: emitted operand has no original home at this site")
      (Ok logical))))

(define (compiler-backend-home-position-equal?
  [left : (& CompilerBackendHomePosition)]
  [right : (& CompilerBackendHomePosition)]) : bool
  (match left
    [(Parameter)
      (match right
        [(Parameter) true]
        [_ false])]
    [(Address)
      (match right
        [(Address) true]
        [_ false])]
    [(Definition)
      (match right
        [(Definition) true]
        [_ false])]
    [(Use a)
      (match right
        [(Use b) (= a b)]
        [_ false])]))

;; Check the remapper's actual definition/use shape, including operand order.
;; StoreOwned normalizes to StorePtr at this boundary with the same operands.
(define (compiler-backend-home-bindings-checked
  [original : (& ir.CompilerIrInstr)]
  [emitted : (& ir.CompilerIrInstr)]
  [coloring : (& regalloc.CompilerRegColoring)]
  [logical-count : i64]
  [emitted-count : i64]) : CompilerBackendHomeBindingsResult
  (let
    [expected : CompilerBackendHomeBindingList
      (try (compiler-backend-home-bindings original coloring logical-count))]
    [identity : regalloc.CompilerRegColoring (None)]
    [actual : CompilerBackendHomeBindingList
      (try (compiler-backend-home-bindings emitted (& identity) emitted-count))]
    (unless
      (= expected.len actual.len)
      (return (Err "stack traffic: remapped operand count differs")))
    (for [index (iterator.range 0 expected.len)]
      (let
        [before : (& expected CompilerBackendHomeBinding)
          (& (array-ref expected.slots index))]
        [after : (& actual CompilerBackendHomeBinding)
          (& (array-ref actual.slots index))]
        (unless
          (and
            (= before.emitted after.emitted)
            (compiler-backend-home-position-equal?
              (& before.position)
              (& after.position)))
          (return (Err "stack traffic: remapped operand identity differs")))))
    (Ok expected)))

;; Source blocks are matched by their typed label, then by instruction index.
;; Placement may reorder or retire whole blocks; it cannot silently add a clone
;; or edit an instruction's remapped operands. Sites follow ACTUAL placed order.
(define (compiler-backend-home-plan-build
  [input : (& input CompilerBackendHomePlanInput)]) : CompilerBackendHomePlanResult
  (when
    (or
      (< input.function 0)
      (< input.logical-count 0)
      (< input.emitted-count 0))
    (return (Err "stack traffic: invalid original-home plan identity")))
  (let
    [original : (& input (Slice ir.CompilerIrBlock))
      (ir.compiler-ir-block-list-view (& input.original))]
    [placed : (& input (Slice ir.CompilerIrBlock))
      (ir.compiler-ir-block-list-view (& input.placed))]
    [parameters : CompilerBackendHomeBindingBuilder
      (CompilerBackendHomeBindingBuilder
        (compiler-backend-home-binding-list-new)
        0
        "")]
    [parameter-seen : (__tl_dyn-array bool)
      (__tl_make-array bool input.logical-count)]
    [indices : block_index.Map
      (block_index.with-capacity (+ (* 2 (array-length original)) 1))]
    [seen : (__tl_dyn-array bool)
      (__tl_make-array bool (array-length original))]
    [sites : (__tl_dyn-array CompilerBackendHomeSite)
      (__tl_make-array
        CompilerBackendHomeSite
        (ir.compiler-ir-block-list-instruction-count (& input.placed)))]
    [cursor : i64 0]
    [words : (__tl_dyn-array i64) (__tl_make-array i64 input.logical-count)]
    [bytes : (__tl_dyn-array i64) (__tl_make-array i64 input.logical-count)]
    (unless
      (and
        (>= input.params.len 0)
        (<= input.params.len (array-length input.params.slots)))
      (return (Err "stack traffic: invalid original parameter extent")))
    (for [index (iterator.range 0 input.params.len)]
      (match (ir.compiler-ir-param-seq-ref input.params index)
        [(Param _ _ logical)
          (compiler-backend-home-binding-add!
            (&mut parameters)
            (& input.coloring)
            input.logical-count
            logical
            (Parameter))
          (unless
            (string.eq (& parameters.error) "")
            (return (Err parameters.error)))
          (when
            (or
              (array-ref parameter-seen logical)
              (>=
                (array-ref parameters.bindings.slots index).emitted
                input.emitted-count))
            (return
              (Err
                "stack traffic: original parameter has no unique emitted home")))
          (set! (array-ref parameter-seen logical) true)]))
    (when
      (and (> input.params.len 0) (= (array-length placed) 0))
      (return (Err "stack traffic: original parameters have no entry block")))
    (for [index (iterator.range 0 (array-length original))]
      (match (& (array-ref original index))
        [(Block label _)
          (when
            (or
              (< label 0)
              (not
                (block_index.insert-if-absent-ref! (&mut indices) label index)))
            (return (Err "stack traffic: duplicate or invalid original block")))]))
    (for [index (iterator.range 0 (array-length placed))]
      (match (& (array-ref placed index))
        [(Block label instructions)
          (let
            [before-index : i64
              (match (block_index.get-borrowed (& indices) label)
                [(LookupFound found) found]
                [(LookupMissing) -1])]
            (when
              (or (< before-index 0) (array-ref seen before-index))
              (return
                (Err "stack traffic: placed block has no unique original")))
            (set! (array-ref seen before-index) true)
            (match (& (array-ref original before-index))
              [(Block _ before)
                (unless
                  (= before.len instructions.len)
                  (return
                    (Err "stack traffic: placed instruction count differs")))
                (for [offset (iterator.range 0 instructions.len)]
                  (let
                    [bindings : CompilerBackendHomeBindingList
                      (match (compiler-backend-home-bindings-checked
                        (& (array-ref before.slots offset))
                        (& (array-ref instructions.slots offset))
                        (& input.coloring)
                        input.logical-count
                        input.emitted-count)
                        [(Ok result) result]
                        [(Err message) (return (Err message))])]
                    (set!
                      (array-ref sites cursor)
                      (CompilerBackendHomeSite label offset bindings))
                    (+= cursor 1)))]))]))
    ;; Reuse the exact allocator storage-shape census. In particular a mask's
    ;; reserved home may be wider than one emitted compact mask access.
    (regalloc.compiler-reg-vector-stack-words-params!
      (& input.params)
      (&mut words))
    (regalloc.compiler-reg-vector-stack-words-blocks!
      (& input.original)
      (&mut words))
    (regalloc.compiler-reg-vector-stack-words-fixpoint!
      (& input.original)
      (&mut words))
    (for [var (iterator.range 0 input.logical-count)]
      (let
        [size : i64
          (regalloc.compiler-reg-vector-stack-words-for-var (& words) var)]
        [capacity : i64
          (if (live.compiler-live-set-contains? (& input.groups) var)
            (if (< size 2)
              2
              size)
            size)]
        (when
          (> capacity 1152921504606846975)
          (return (Err "stack traffic: original home capacity overflows")))
        (set! (array-ref bytes var) (* 8 capacity))))
    (Ok
      (CompilerBackendHomePlan
        input.function
        (if (> (array-length placed) 0)
          (match (& (array-ref placed 0))
            [(Block label _) label])
          -1)
        parameters.bindings
        sites
        bytes))))

(define (compiler-backend-home-plan-resolve
  [plan : (& plan CompilerBackendHomePlan)]
  [function : i64]
  [block : i64]
  [site : i64]
  [emitted : i64]
  [query : CompilerBackendHomeQuery]) : CompilerBackendPlannedHomeResult
  (unless
    (= function plan.function)
    (return (Err "stack traffic: original-home emission site is unbound")))
  (let
    [logical : i64
      (match (& query)
        [(Parameter)
          (unless
            (and (>= block 0) (= block plan.entry-block))
            (return
              (Err "stack traffic: original parameter entry block differs")))
          (match (compiler-backend-home-resolve
            (& plan.parameters)
            emitted
            query)
            [(Ok result) result]
            [(Err message) (return (Err message))])]
        [_
          (unless
            (and (>= site 0) (< site (array-length plan.sites)))
            (return
              (Err "stack traffic: original-home emission site is unbound")))
          (let
            [entry : (& plan CompilerBackendHomeSite)
              (& (array-ref plan.sites site))]
            (unless
              (= block entry.block)
              (return
                (Err "stack traffic: original-home emission block differs")))
            (match (compiler-backend-home-resolve
              (& entry.bindings)
              emitted
              query)
              [(Ok result) result]
              [(Err message) (return (Err message))]))])]
    (unless
      (and (>= logical 0) (< logical (array-length plan.bytes)))
      (return (Err "stack traffic: original home has no allocation capacity")))
    (Ok (CompilerBackendLogicalHome logical (array-ref plan.bytes logical)))))