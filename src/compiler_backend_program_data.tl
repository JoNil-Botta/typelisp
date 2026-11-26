;; compiler_backend_program_data.tl - Program literals, globals and runtime function plans.
(import compiler_backend_operands as be_operand)
(import compiler_backend_program_facts as be_facts)
(import compiler_backend_state as be_state)
(import stdlib.iterator)
(import compiler_ir_types)
(import compiler_ast_types)
(import compiler_builtin_ids as cbi)
(import compiler_diagnostic)
(import compiler_regalloc)
(import compiler_backend_runtime_common as runtime_common)
(import compiler_backend_runtime_linux as runtime_linux)
(import compiler_backend_runtime_windows as runtime_windows)
(import compiler_backend_runtime_prune as runtime_prune)
(import compiler_x64_executable_template_catalog as x64_catalog)
(import stdlib.text_buf)
(import compiler_object as cobj)
(import compiler_object_asm as object_asm)
(import stdlib.sort)
(import stdlib.vector)
(import stdlib.hashmap)
(import (hashmap.hashmap String i64) as backend_string_i64_map)
(import (hashmap.hashmap i64 i64) as backend_i64_i64_map)
(import stdlib.string)
(import stdlib.byte_buf_core)
(import compiler_str_cat as str_cat)
(import compiler_owned_view as owned_view)

;; Sort keys borrow stable input slots through the compiler's scalar arena
;; handle ABI. They never escape the planner or outlive its input collection.
(defstruct CompilerBackendLiteralKey
  (slot-address u64)
  (owner i64)
  (offset i64))

;; The owner equality hook the full-mode vector shared with `stdlib.sort.vec`
;; requires.
(define (eq-compiler-backend-literal-key
  [left : (& left CompilerBackendLiteralKey)]
  [right : (& right CompilerBackendLiteralKey)]) : bool
  (and
    (= left.slot-address right.slot-address)
    (= left.owner right.owner)
    (= left.offset right.offset)))

(import (stdlib.vector.vector CompilerBackendLiteralKey) as literal_vec)
(import (stdlib.sort.vec CompilerBackendLiteralKey) as literal_sort)

(define (compiler-backend-string-set-list [set : be_state.BackendStringSet]) : be_state.BackendStringSeq
  set.items)

(define (compiler-backend-symbol-set-list [set : be_state.BackendSymbolSet]) : be_state.BackendSymbolSeq
  set.items)

(define (compiler-backend-float-set-list [set : be_state.BackendFloatSet]) : be_state.BackendFloatSeq
  set.items)

(define (compiler-backend-program-collections-functions
  [collections : be_state.CompilerBackendProgramCollections]) : be_state.BackendSymbolSeq
  (compiler-backend-symbol-set-list collections.functions))

(define (compiler-backend-program-collections-references
  [collections : be_state.CompilerBackendProgramCollections]) : be_state.BackendSymbolSeq
  (compiler-backend-symbol-set-list collections.references))

(define (compiler-backend-program-collections-strings
  [collections : be_state.CompilerBackendProgramCollections]) : be_state.BackendStringSeq
  (compiler-backend-string-set-list collections.strings))

(define (compiler-backend-program-collections-floats
  [collections : be_state.CompilerBackendProgramCollections]) : be_state.BackendFloatSeq
  (compiler-backend-float-set-list collections.floats))

(define (compiler-backend-program-collections-bytes
  [collections : be_state.CompilerBackendProgramCollections]) : be_state.BackendStringSeq
  (compiler-backend-string-set-list collections.bytes))

(define (compiler-backend-program-collections-uses-avx2-i64-lane-id?
  [collections : (& collections be_state.CompilerBackendProgramCollections)]) : bool
  collections.uses-avx2-i64-lane-id)

(define (compiler-backend-program-collections-uses-f64-neg?
  [collections : (& collections be_state.CompilerBackendProgramCollections)]) : bool
  collections.uses-f64-neg)

(define (compiler-backend-program-collections-uses-f32-neg?
  [collections : be_state.CompilerBackendProgramCollections]) : bool
  collections.uses-f32-neg)

(define (compiler-backend-collect-function-collections
  [collections : be_state.CompilerBackendProgramCollections]
  [functions : compiler_ir_types.CompilerIrFunctionSeq]) : be_state.CompilerBackendProgramCollections
  (match (be_facts.compiler-backend-collect-functions-shared
    (Collections (be_state.compiler-backend-global-shared-view collections))
    functions)
    [(Collections out) out]
    [_ collections]))

(define (compiler-backend-collect-global-collections-from
  [collections : be_state.CompilerBackendProgramCollections]
  [globals : compiler_ir_types.CompilerIrGlobalSeq]
  [index : i64]) : be_state.CompilerBackendProgramCollections
  (if (>= index globals.len)
    collections
    (match (compiler_ir_types.compiler-ir-global-seq-ref globals index)
      [(Global _ _ value _)
        (compiler-backend-collect-global-collections-from
          (be_facts.compiler-backend-collect-value-collections
            collections
            value)
          globals
          (+ index 1))])))

(define (compiler-backend-collect-global-collections
  [collections : be_state.CompilerBackendProgramCollections]
  [globals : compiler_ir_types.CompilerIrGlobalSeq]) : be_state.CompilerBackendProgramCollections
  (compiler-backend-collect-global-collections-from collections globals 0))

;; The one whole-program walk.
(define (compiler-backend-collect-program-collections
  [globals : compiler_ir_types.CompilerIrGlobalSeq]
  [functions : compiler_ir_types.CompilerIrFunctionSeq]) : be_state.CompilerBackendProgramCollections
  (compiler-backend-collect-function-collections
    (compiler-backend-collect-global-collections
      (be_state.compiler-backend-program-collections-new)
      globals)
    functions))

;; Reverse-byte descending order places every terminated suffix after an
;; owner. A suffix of any earlier value is also a suffix of the current owner:
;; reverse-lexicographic prefixes are contiguous, with longer values first.
(define (compiler-backend-literal-suffix-before?
  [left-key : CompilerBackendLiteralKey]
  [right-key : CompilerBackendLiteralKey]) : bool
  (let
    [left : String
      (unsafe
        (ptr-read (int->ptr left-key.slot-address : (Ptr String))))]
    [right : String
      (unsafe
        (ptr-read (int->ptr right-key.slot-address : (Ptr String))))]
    [i : i64 (string.string-length left)]
    [j : i64 (string.string-length right)]
    (while (and (> i 0) (> j 0))
      (-= i 1)
      (-= j 1)
      (let
        [a : char (string.string-ref left i)]
        [b : char (string.string-ref right j)]
        (unless (= a b) (return (> a b)))))
    (> i j)))

;; Every consumer of a literal byte label carries an explicit length: String
;; descriptors and located diagnostic paths. The C marshalling helpers copy
;; into their own terminated buffers, and raw binary data and runtime C
;; strings are emitted separately, so literal bytes carry no NUL. Put a real
;; label at each interior offset so text, ELF, and COFF all relocate to it
;; using their normal symbol-address records.
(define (compiler-backend-literal-text [address : u64]) : String
  (unsafe
    (ptr-read (int->ptr address : (Ptr String)))))

(define (compiler-backend-literal-position-before?
  [left : CompilerBackendLiteralKey]
  [right : CompilerBackendLiteralKey]) : bool
  (if (= left.owner right.owner)
    (< left.offset right.offset)
    (< left.owner right.owner)))

(define compiler-backend-literal-prefix-length : i64
  6)

;; The index key of `width` bytes at `offset`. A six-byte prefix packs into
;; the low 48 bits. A whole shorter literal is tagged with its width above
;; them, so keys of different widths never collide.
(define (compiler-backend-literal-key
  [text : (& text str)]
  [offset : i64]
  [width : i64]) : i64
  (let
    [key : i64 0]
    (for [i (iterator.range 0 width)]
      (set!
        key
        (bit-or (shl key 8) (cast (string.string-ref text (+ offset i)) : i64))))
    (if (< width compiler-backend-literal-prefix-length)
      (bit-or key (shl width 48))
      key)))

(define compiler-backend-literal-prefix-filter-size : i64
  65536)

(define (compiler-backend-literal-prefix-filter-index [key : i64]) : i64
  ;; Multiplicative hashing takes the high 16 bits of the wrapped product.
  (cast (shr (cast (* key -7046029254386353131) : u64) 48) : i64))

;; Moves each indexed owner with `key` whose bytes occur at `offset` of the
;; strictly longer owner `host` into that host. The caller has passed the
;; prefilter, so a filtered-out probe costs no call.
(define (compiler-backend-literal-place-at!
  [ordered : (&mut ordered literal_vec.Vec)]
  [links : (& links (__tl_dyn-array i64))]
  [keys : (& keys backend_i64_i64_map.Map)]
  [remaining : (&mut remaining (__tl_dyn-array i64))]
  [key : i64]
  [host : i64]
  [text : (& text str)]
  [offset : i64]) : unit
  (let
    [length : i64 (string.string-length text)]
    [link : i64 (backend_i64_i64_map.get-value-or keys key 0)]
    (while (> link 0)
      (let
        [index : i64 (- link 1)]
        [entry : CompilerBackendLiteralKey (array-ref ordered.slots index)]
        (when
          (= entry.owner index)
          (let
            [candidate : String
              (compiler-backend-literal-text entry.slot-address)]
            [need : i64 (string.string-length (& candidate))]
            (when
              (and
                (< need length)
                (<= need (- length offset))
                (string.is-string-prefix-at text (& candidate) offset))
              (set! (array-ref ordered.slots index).owner host)
              (set! (array-ref ordered.slots index).offset offset)
              (when
                (< need compiler-backend-literal-prefix-length)
                (-= (array-ref remaining need) 1)))))
        (set! link (array-ref links index))))))

;; Index every owner by its key: its six-byte prefix, or all of a shorter
;; literal. Each owner then probes every offset once per short width and once
;; for a prefix. A match must still prove equality across the full byte range.
;; Only a strictly longer owner can take over a payload, so the placement
;; graph is acyclic. The prefilter costs one byte lookup per probe and avoids
;; most hash-table probes; a short width with no owner left is not probed.
(define (compiler-backend-literal-place-interiors!
  [ordered : (&mut ordered literal_vec.Vec)]) : unit
  (with-arena
    scratch
    (let
      [links : (__tl_dyn-array i64) (__tl_make-array i64 ordered.len)]
      [filter : (__tl_dyn-array bool)
        (__tl_make-array bool compiler-backend-literal-prefix-filter-size)]
      [keys : backend_i64_i64_map.Map
        (backend_i64_i64_map.with-capacity ordered.len)]
      [remaining : (__tl_dyn-array i64)
        (__tl_make-array i64 compiler-backend-literal-prefix-length)]
      (for [i (iterator.range 0 ordered.len)]
        (let
          [entry : CompilerBackendLiteralKey (array-ref ordered.slots i)]
          [text : String (compiler-backend-literal-text entry.slot-address)]
          [length : i64 (string.string-length (& text))]
          (when
            (and (= entry.owner i) (> length 0))
            (let
              [key : i64
                (compiler-backend-literal-key
                  (& text)
                  0
                  (if (< length compiler-backend-literal-prefix-length)
                    length
                    compiler-backend-literal-prefix-length))]
              (set!
                (array-ref links i)
                (backend_i64_i64_map.get-value-or (& keys) key 0))
              (set!
                (array-ref
                  filter
                  (compiler-backend-literal-prefix-filter-index key))
                true)
              (when
                (< length compiler-backend-literal-prefix-length)
                (+= (array-ref remaining length) 1))
              (backend_i64_i64_map.insert-ref! (&mut keys) key (+ i 1))))))
      (for [i (iterator.range 0 ordered.len)]
        (let
          [host : CompilerBackendLiteralKey (array-ref ordered.slots i)]
          [text : String (compiler-backend-literal-text host.slot-address)]
          [length : i64 (string.string-length (& text))]
          (when
            (and (= host.owner i) (> length 1))
            (for [offset (iterator.range 0 length)]
              (let
                [rest : i64 (- length offset)]
                [widest : i64
                  (if (< rest compiler-backend-literal-prefix-length)
                    rest
                    (- compiler-backend-literal-prefix-length 1))]
                [bytes : i64 0]
                (for [width (iterator.range 1 (+ widest 1))]
                  (set!
                    bytes
                    (bit-or
                      (shl bytes 8)
                      (cast
                        (string.string-ref (& text) (+ offset (- width 1)))
                        : i64)))
                  (let
                    [key : i64 (bit-or bytes (shl width 48))]
                    (when
                      (and
                        (> (array-ref remaining width) 0)
                        (array-ref
                          filter
                          (compiler-backend-literal-prefix-filter-index key)))
                      (compiler-backend-literal-place-at!
                        ordered
                        (& links)
                        (& keys)
                        (&mut remaining)
                        key
                        i
                        (& text)
                        offset))))
                (when
                  (>= rest compiler-backend-literal-prefix-length)
                  (let
                    [key : i64
                      (bit-or
                        (shl bytes 8)
                        (cast
                          (string.string-ref (& text) (+ offset widest))
                          : i64))]
                    (when
                      (array-ref
                        filter
                        (compiler-backend-literal-prefix-filter-index key))
                      (compiler-backend-literal-place-at!
                        ordered
                        (& links)
                        (& keys)
                        (&mut remaining)
                        key
                        i
                        (& text)
                        offset)))))))))))
  (for [i (iterator.range 0 ordered.len)]
    (let
      [entry : CompilerBackendLiteralKey (array-ref ordered.slots i)]
      [owner : i64 entry.owner]
      [offset : i64 entry.offset]
      [parent : CompilerBackendLiteralKey (array-ref ordered.slots owner)]
      (while (!= owner parent.owner)
        (+= offset parent.offset)
        (set! owner parent.owner)
        (set! parent (array-ref ordered.slots owner)))
      (set!
        (array-ref ordered.slots i)
        (CompilerBackendLiteralKey entry.slot-address owner offset)))))

(define compiler-backend-literal-overlap-limit : i64
  64)

;; An odd hash base and its inverse modulo 2^64.
(define compiler-backend-literal-hash-base : i64
  1099511628211)
(define compiler-backend-literal-hash-base-inverse : i64
  -3560570117845248645)

;; True when the last `width` bytes of `left` are the first `width` of `right`.
(define (compiler-backend-literal-overlaps?
  [left : (& left str)]
  [right : (& right str)]
  [width : i64]) : bool
  (let
    [start : i64 (- (string.string-length left) width)]
    (for [i (iterator.range 0 width)]
      (unless
        (= (string.string-ref left (+ start i)) (string.string-ref right i))
        (return false)))
    true))

;; Greedy shortest-superstring merge of the owners left after placement,
;; longest overlap first. At each width, every owner whose tail is free takes
;; the first owner with a free head whose leading bytes are its trailing ones,
;; unless that owner heads its own chain. Each round shrinks both hashes by a
;; byte: a prefix hash drops its top term, and a suffix hash drops its first
;; byte and multiplies by the base inverse. A chain becomes one unit: its
;; owners and their payloads move to the chain head, at their offsets in the
;; merged bytes.
(define (compiler-backend-literal-chain-owners!
  [ordered : (&mut ordered literal_vec.Vec)]) : unit
  (with-arena
    scratch
    (let
      [count : i64 ordered.len]
      [limit : i64 compiler-backend-literal-overlap-limit]
      [lengths : (__tl_dyn-array i64) (__tl_make-array i64 count)]
      [prefixes : (__tl_dyn-array i64) (__tl_make-array i64 count)]
      [suffixes : (__tl_dyn-array i64) (__tl_make-array i64 count)]
      [next : (__tl_dyn-array i64) (__tl_make-array i64 count)]
      [joined : (__tl_dyn-array bool) (__tl_make-array bool count)]
      [ends : (__tl_dyn-array i64) (__tl_make-array i64 count)]
      [overlaps : (__tl_dyn-array i64) (__tl_make-array i64 count)]
      [links : (__tl_dyn-array i64) (__tl_make-array i64 count)]
      [powers : (__tl_dyn-array i64) (__tl_make-array i64 (+ limit 1))]
      [heads : backend_i64_i64_map.Map
        (backend_i64_i64_map.with-capacity count)]
      [alive : (__tl_dyn-array i64) (__tl_make-array i64 count)]
      [alive-count : i64 0]
      [width : i64 limit]
      (set! (array-ref powers 0) 1)
      (for [k (iterator.range 1 (+ limit 1))]
        (set!
          (array-ref powers k)
          (* (array-ref powers (- k 1)) compiler-backend-literal-hash-base)))
      (for [i (iterator.range 0 count)]
        (let
          [entry : CompilerBackendLiteralKey (array-ref ordered.slots i)]
          (set! (array-ref ends i) i)
          (when
            (= entry.owner i)
            (let
              [text : String (compiler-backend-literal-text entry.slot-address)]
              [length : i64 (string.string-length (& text))]
              [start : i64
                (if (< (- length 1) limit)
                  (- length 1)
                  limit)]
              [prefix : i64 0]
              [suffix : i64 0]
              (set! (array-ref lengths i) length)
              (when
                (> length 1)
                (set! (array-ref alive alive-count) i)
                (+= alive-count 1))
              (for [j (iterator.range 0 start)]
                (+=
                  prefix
                  (*
                    (cast (string.string-ref (& text) j) : i64)
                    (array-ref powers j)))
                (+=
                  suffix
                  (*
                    (cast
                      (string.string-ref (& text) (+ (- length start) j))
                      : i64)
                    (array-ref powers j))))
              (set! (array-ref prefixes i) prefix)
              (set! (array-ref suffixes i) suffix)))))
      ;; `alive` lists, in index order, the owners of two or more bytes whose
      ;; head or tail is still free. A walk unlinks each joined owner it meets
      ;; from its bucket, so no later walk visits it again.
      (while (> width 0)
        (backend_i64_i64_map.clear-ref! (&mut heads))
        (for [k (iterator.range 0 alive-count)]
          (let
            [i : i64 (array-ref alive k)]
            (when
              (and (> (array-ref lengths i) width) (not (array-ref joined i)))
              (set!
                (array-ref links i)
                (backend_i64_i64_map.get-value-or
                  (& heads)
                  (array-ref prefixes i)
                  0))
              (backend_i64_i64_map.insert-ref!
                (&mut heads)
                (array-ref prefixes i)
                (+ i 1)))))
        (for [k (iterator.range 0 alive-count)]
          (let
            [i : i64 (array-ref alive k)]
            (when
              (and (> (array-ref lengths i) width) (= (array-ref next i) 0))
              (let
                [left : String
                  (compiler-backend-literal-text
                    (array-ref ordered.slots i).slot-address)]
                [key : i64 (array-ref suffixes i)]
                [previous : i64 0]
                [link : i64 (backend_i64_i64_map.get-value-or (& heads) key 0)]
                (while (> link 0)
                  (let
                    [j : i64 (- link 1)]
                    [following : i64 (array-ref links j)]
                    (cond
                      [(array-ref joined j)
                        (if (= previous 0)
                          (backend_i64_i64_map.insert-ref!
                            (&mut heads)
                            key
                            following)
                          (set! (array-ref links (- previous 1)) following))
                        (set! link following)]
                      [(and
                          (!= j (array-ref ends i))
                          (let
                            [right : String
                              (compiler-backend-literal-text
                                (array-ref ordered.slots j).slot-address)]
                            (compiler-backend-literal-overlaps?
                              (& left)
                              (& right)
                              width)))
                        (let
                          [head : i64 (array-ref ends i)]
                          [tail : i64 (array-ref ends j)]
                          (set! (array-ref next i) link)
                          (set! (array-ref joined j) true)
                          (set! (array-ref overlaps j) width)
                          (set! (array-ref ends head) tail)
                          (set! (array-ref ends tail) head)
                          (set! link 0))]
                      [else
                        (set! previous link)
                        (set! link following)])))))))
        ;; Shrink only the hashes a later width still reads, and drop owners
        ;; whose head and tail are both taken.
        (let
          [kept : i64 0]
          (for [k (iterator.range 0 alive-count)]
            (let
              [i : i64 (array-ref alive k)]
              [length : i64 (array-ref lengths i)]
              [head-free : bool (not (array-ref joined i))]
              [tail-free : bool (= (array-ref next i) 0)]
              (when
                (> length width)
                (let
                  [text : String
                    (compiler-backend-literal-text
                      (array-ref ordered.slots i).slot-address)]
                  (when
                    head-free
                    (set!
                      (array-ref prefixes i)
                      (-
                        (array-ref prefixes i)
                        (*
                          (cast (string.string-ref (& text) (- width 1)) : i64)
                          (array-ref powers (- width 1))))))
                  (when
                    tail-free
                    (set!
                      (array-ref suffixes i)
                      (*
                        (-
                          (array-ref suffixes i)
                          (cast
                            (string.string-ref (& text) (- length width))
                            : i64))
                        compiler-backend-literal-hash-base-inverse)))))
              (when
                (or head-free tail-free)
                (set! (array-ref alive kept) i)
                (+= kept 1))))
          (set! alive-count kept))
        (-= width 1))
      (let
        [bases : (__tl_dyn-array i64) (__tl_make-array i64 count)]
        [roots : (__tl_dyn-array i64) (__tl_make-array i64 count)]
        (for [i (iterator.range 0 count)]
          (when
            (and
              (= (array-ref ordered.slots i).owner i)
              (not (array-ref joined i)))
            (let
              [member : i64 i]
              [base : i64 0]
              (set! (array-ref roots i) i)
              (while (> (array-ref next member) 0)
                (let
                  [following : i64 (- (array-ref next member) 1)]
                  (set!
                    base
                    (-
                      (+ base (array-ref lengths member))
                      (array-ref overlaps following)))
                  (set! (array-ref roots following) i)
                  (set! (array-ref bases following) base)
                  (set! member following))))))
        (for [i (iterator.range 0 count)]
          (let
            [owner : i64 (array-ref ordered.slots i).owner]
            (+= (array-ref ordered.slots i).offset (array-ref bases owner))
            (set! (array-ref ordered.slots i).owner (array-ref roots owner))))))))

;; Chaining glues unrelated literals into one unit, so a sectioned object,
;; whose linker collects each unit alone, keeps them apart.
(define (compiler-backend-literal-records
  [strings : be_state.BackendStringSeq]
  [start : i64]
  [chain : bool]) : cobj.CompilerObjectDataRecordList
  (let
    [ordered : literal_vec.Vec
      (literal_vec.with-capacity (- strings.len start))]
    (for [i (iterator.range start strings.len)]
      (literal_vec.push-ref!
        (&mut ordered)
        (CompilerBackendLiteralKey
          (unsafe
            (ptr->int (ptr-offset (__tl_array-data strings.slots) i)))
          0
          0)))
    (literal_sort.sort! (&mut ordered) compiler-backend-literal-suffix-before?)
    (let
      [owner : i64 0]
      [owner-address : u64 0]
      (for [i (iterator.range 0 ordered.len)]
        (let
          [entry : CompilerBackendLiteralKey (array-ref ordered.slots i)]
          [candidate : String
            (compiler-backend-literal-text entry.slot-address)]
          [text : String
            (if (> i 0)
              (compiler-backend-literal-text owner-address)
              "")]
          [offset : i64
            (- (string.string-length text) (string.string-length candidate))]
          (if (and
            (> i 0)
            (>= offset 0)
            (string.is-string-prefix-at text candidate offset))
            (set!
              (array-ref ordered.slots i)
              (CompilerBackendLiteralKey entry.slot-address owner offset))
            (begin
              (set! owner i)
              (set! owner-address entry.slot-address)
              (set!
                (array-ref ordered.slots i)
                (CompilerBackendLiteralKey entry.slot-address i 0)))))))
    (compiler-backend-literal-place-interiors! (&mut ordered))
    (when chain (compiler-backend-literal-chain-owners! (&mut ordered)))
    (literal_sort.sort!
      (&mut ordered)
      compiler-backend-literal-position-before?)
    (compiler-backend-literal-build-records (& ordered))))

;; `(Align 1)` opens each unit of shared bytes. A unit's bytes come from the
;; literal reaching furthest so far: in offset order, each literal starts
;; inside the bytes of an earlier one.
(define (compiler-backend-literal-build-records
  [ordered : (& ordered literal_vec.Vec)]) : cobj.CompilerObjectDataRecordList
  (let
    [records : cobj.CompilerObjectDataRecordBuilder
      (cobj.compiler-object-data-record-builder-with-capacity
        (+ 1 (* 7 ordered.len)))]
    [owner : i64 -1]
    [cursor : i64 0]
    [cover : String ""]
    [cover-offset : i64 0]
    [cover-end : i64 0]
    (for [i (iterator.range 0 (+ ordered.len 1))]
      (let
        [last : bool (= i ordered.len)]
        [entry : CompilerBackendLiteralKey
          (if last
            (CompilerBackendLiteralKey 0 -1 0)
            (array-ref ordered.slots i))]
        (when
          (and (!= owner entry.owner) (< cursor cover-end))
          (set!
            records
            (cobj.compiler-object-data-record-builder-push
              records
              (Bytes
                (string.substring
                  cover
                  (- cursor cover-offset)
                  (- cover-end cursor))))))
        (unless
          last
          (let
            [text : String (compiler-backend-literal-text entry.slot-address)]
            [end : i64 (+ entry.offset (string.string-length (& text)))]
            (when
              (!= owner entry.owner)
              (set!
                records
                (cobj.compiler-object-data-record-builder-push
                  records
                  (Align 1)))
              (set! owner entry.owner)
              (set! cursor 0)
              (set! cover-end 0))
            (when
              (> entry.offset cursor)
              (set!
                records
                (cobj.compiler-object-data-record-builder-push
                  records
                  (Bytes
                    (string.substring
                      cover
                      (- cursor cover-offset)
                      (- entry.offset cursor)))))
              (set! cursor entry.offset))
            (set!
              records
              (cobj.compiler-object-data-record-builder-push
                records
                (Label (be_facts.compiler-backend-string-data-label text))))
            (when
              (> end cover-end)
              (set! cover text)
              (set! cover-offset entry.offset)
              (set! cover-end end))))))
    (set!
      records
      (cobj.compiler-object-data-record-builder-push records (Align 8)))
    (for [i (iterator.range 0 ordered.len)]
      (let
        [text : String
          (compiler-backend-literal-text
            (array-ref ordered.slots i).slot-address)]
        (set!
          records
          (cobj.compiler-object-data-record-builder-push
            (cobj.compiler-object-data-record-builder-push
              (cobj.compiler-object-data-record-builder-push
                records
                (Label (be_operand.compiler-backend-string-fat-label text)))
              (SymbolAddress (be_facts.compiler-backend-string-data-label text)))
            (I64 (string.string-length text))))))
    (cobj.compiler-object-data-record-builder-finish records)))

(define (compiler-backend-emit-quoted-literal!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [head : String]
  [text : String]) : unit
  (byte_buf_core.byte-buf-builder-append-string out head)
  (byte_buf_core.byte-buf-builder-append-string
    out
    (be_facts.compiler-backend-escape-string text))
  (byte_buf_core.byte-buf-builder-append-string out "\"\n"))

;; Renders the unit of shared bytes whose records start at `start` and returns
;; the index of the record after it. Its bytes stay one `.ascii` record, so a
;; literal's text reads whole in the listing. A label at an interior offset is
;; set relative to the unit's first label.
(define (compiler-backend-emit-literal-unit!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [records : (& records cobj.CompilerObjectDataRecordList)]
  [start : i64]) : i64
  (let
    [first : String ""]
    [offset : i64 0]
    [bytes : text_buf.TextBuf (text_buf.empty)]
    [i : i64 start]
    [open : bool true]
    (while (and open (< i records.len))
      (match (cobj.compiler-object-data-record-list-ref records i)
        [(Label label)
          (if (= offset 0)
            (begin
              (byte_buf_core.byte-buf-builder-append-string
                out
                (str_cat.str-cat label ":\n"))
              (when (= i start) (set! first label)))
            (byte_buf_core.byte-buf-builder-append-string
              out
              (str_cat.str-cat
                "    .set "
                label
                ", "
                first
                " + "
                (string.int->string offset)
                "\n")))
          (+= i 1)]
        [(Bytes text)
          (+= offset (string.string-length (& text)))
          (set! bytes (text_buf.append bytes text))
          (+= i 1)]
        [_ (set! open false)]))
    (when
      (> offset 0)
      (compiler-backend-emit-quoted-literal!
        out
        "    .ascii \""
        (text_buf.render bytes)))
    i))

(define (compiler-backend-literal-section [label : (& label str)]) : String
  (be_operand.compiler-backend-elf-symbol-section
    ".rodata"
    label
    "\"a\",@progbits"))

;; A closed build drops each unit and header no live code names. A marker
;; closes each unit, whose labels share its bytes. The alignment between the
;; two bundles stays a root. A sectioned (ELF library) object gives each unit
;; and header its own section, so the linker collects it with the code that
;; names it.
(define (compiler-backend-emit-string-rodata-into
  [strings : be_state.BackendStringSeq]
  [sectioned : bool]
  [buf : text_buf.TextBuf]) : text_buf.TextBuf
  (if (= strings.len 0)
    buf
    (let
      [records : cobj.CompilerObjectDataRecordList
        (compiler-backend-literal-records strings 0 (not sectioned))]
      [out : byte_buf_core.ByteBufBuilder
        (byte_buf_core.byte-buf-builder-with-capacity 4096)]
      [i : i64 0]
      [unit-open : bool false]
      [headers : bool false]
      (byte_buf_core.byte-buf-builder-append-string
        (&mut out)
        "    .section .rodata\n")
      (byte_buf_core.byte-buf-builder-append-string
        (&mut out)
        (runtime_prune.literal-begin))
      (while (< i records.len)
        (match (cobj.compiler-object-data-record-list-ref (& records) i)
          [(Align alignment)
            (when
              unit-open
              (byte_buf_core.byte-buf-builder-append-string
                (&mut out)
                (runtime_prune.literal-unit-end))
              (set! unit-open false))
            (if (= alignment 1)
              (begin
                (when
                  sectioned
                  (match (cobj.compiler-object-data-record-list-ref
                    (& records)
                    (+ i 1))
                    [(Label label)
                      (byte_buf_core.byte-buf-builder-append-string
                        (&mut out)
                        (compiler-backend-literal-section (& label)))]
                    [_ unit]))
                (set! unit-open true)
                (set!
                  i
                  (-
                    (compiler-backend-emit-literal-unit!
                      (&mut out)
                      (& records)
                      (+ i 1))
                    1)))
              (begin
                (set! headers true)
                (byte_buf_core.byte-buf-builder-append-string
                  (&mut out)
                  (runtime_prune.literal-end))
                (unless
                  sectioned
                  (object_asm.compiler-object-asm-render-data-record!
                    (&mut out)
                    (Align alignment)))
                (byte_buf_core.byte-buf-builder-append-string
                  (&mut out)
                  (runtime_prune.literal-begin))))]
          [(Label label)
            (when
              (and headers sectioned)
              (byte_buf_core.byte-buf-builder-append-string
                (&mut out)
                (compiler-backend-literal-section (& label)))
              (byte_buf_core.byte-buf-builder-append-string
                (&mut out)
                "    .balign 8\n"))
            (object_asm.compiler-object-asm-render-data-record!
              (&mut out)
              (Label label))]
          [_
            (object_asm.compiler-object-asm-render-data-record!
              (&mut out)
              (be_state.compiler-backend-global-array-element-shared-view
                records.slots
                i))])
        (+= i 1))
      (byte_buf_core.byte-buf-builder-append-string
        (&mut out)
        (runtime_prune.literal-end))
      (when
        sectioned
        (byte_buf_core.byte-buf-builder-append-string
          (&mut out)
          "    .section .rodata\n"))
      (text_buf.append
        buf
        (byte_buf_core.byte-buf-builder-finish-string (& out))))))

;; Append the decimal text of `value`, which is in 0..255.
(define (compiler-backend-push-byte-decimal!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [value : i64]) : unit
  (when
    (>= value 100)
    (byte_buf_core.byte-buf-builder-push out (cast (+ 48 (/ value 100)) : u8)))
  (when
    (>= value 10)
    (byte_buf_core.byte-buf-builder-push
      out
      (cast (+ 48 (% (/ value 10) 10)) : u8)))
  (byte_buf_core.byte-buf-builder-push out (cast (+ 48 (% value 10)) : u8)))

(define (compiler-backend-emit-byte-directives-into
  [bytes : String]
  [buf : text_buf.TextBuf]) : text_buf.TextBuf
  (let
    [n : i64 (string.string-length bytes)]
    (if (= n 0)
      (text_buf.append buf "    .byte 0\n")
      (let
        ;; At most three digits and one separator per byte, and one
        ;; ten-byte prefix per line of 16.
        [text : byte_buf_core.ByteBufBuilder
          (byte_buf_core.byte-buf-builder-with-capacity
            (+ (* n 4) (* (+ (/ n 16) 1) 10)))]
        [i : i64 0]
        [col : i64 0]
        (while (< i n)
          (if (= col 0)
            (byte_buf_core.byte-buf-builder-append-string
              (&mut text)
              "    .byte ")
            (byte_buf_core.byte-buf-builder-push (&mut text) (cast 44 : u8)))
          (compiler-backend-push-byte-decimal!
            (&mut text)
            (be_state.compiler-backend-char-code (string.string-ref bytes i)))
          (+= i 1)
          (+= col 1)
          (when
            (or (= col 16) (= i n))
            (byte_buf_core.byte-buf-builder-push (&mut text) (cast 10 : u8))
            (set! col 0)))
        (text_buf.append
          buf
          (byte_buf_core.byte-buf-builder-finish-string (& text)))))))

(define (compiler-backend-emit-bytes-entry-into
  [bytes : String]
  [buf : text_buf.TextBuf]) : text_buf.TextBuf
  (let
    [data-label : String (be_facts.compiler-backend-bytes-data-label bytes)]
    [fat-label : String (be_operand.compiler-backend-bytes-fat-label bytes)]
    [len-text : String (string.int->string (string.string-length bytes))]
    [data-buf : text_buf.TextBuf
      (compiler-backend-emit-byte-directives-into
        bytes
        (text_buf.append
          (text_buf.append buf "    .balign 8\n")
          (str_cat.str-cat data-label ":\n" "")))]
    (text_buf.append
      (text_buf.append
        (text_buf.append
          (text_buf.append
            (text_buf.append
              (text_buf.append data-buf "    .balign 8\n")
              fat-label)
            ":\n    .quad ")
          data-label)
        "\n    .quad ")
      (str_cat.str-cat len-text "\n"))))

(define (compiler-backend-emit-bytes-entries-into
  [items : be_state.BackendStringSeq]
  [index : i64]
  [buf : text_buf.TextBuf]) : text_buf.TextBuf
  (if (>= index items.len)
    buf
    (compiler-backend-emit-bytes-entries-into
      (be_state.compiler-backend-global-shared-view items)
      (+ index 1)
      (compiler-backend-emit-bytes-entry-into
        (be_state.compiler-backend-global-array-element-shared-view
          items.slots
          index)
        buf))))

(define (compiler-backend-emit-bytes-data-into
  [items : be_state.BackendStringSeq]
  [buf : text_buf.TextBuf]) : text_buf.TextBuf
  (if (= items.len 0)
    buf
    (text_buf.append
      (compiler-backend-emit-bytes-entries-into
        items
        0
        (text_buf.append buf "    .data\n"))
      "\n")))

(define (compiler-backend-float-bits-directive
  [ty : compiler_ast_types.AstType]
  [bits : u64]) : String
  (if (be_state.compiler-backend-f64-type? ty)
    (str_cat.str-cat "    .quad " (string.int->string (cast bits : i64)) "\n")
    (str_cat.str-cat
      "    .long "
      (string.int->string
        (cast (be_state.compiler-backend-float-payload-bits ty bits) : i64))
      "\n")))

(define (compiler-backend-float-object-data
  [ty : (& compiler_ast_types.AstType)]
  [bits : u64]) : cobj.CompilerObjectDataRecord
  (if (be_state.compiler-backend-f64-type? ty)
    (F64 bits)
    (F32 (be_state.compiler-backend-float-payload-bits ty bits))))

(define (compiler-backend-emit-float-entry
  [ty : compiler_ast_types.AstType]
  [bits : u64]) : String
  (str_cat.str-cat
    (if (be_state.compiler-backend-f64-type? ty)
      "    .balign 8\n"
      "    .balign 4\n")
    (be_operand.compiler-backend-float-label ty bits)
    ":\n"
    (compiler-backend-float-bits-directive ty bits)))

(define (compiler-backend-emit-float-entries-into
  [floats : be_state.BackendFloatSeq]
  [buf : text_buf.TextBuf]) : text_buf.TextBuf
  (let
    [slots : (__tl_dyn-array be_state.BackendFloatEntry) floats.slots]
    [count : i64 floats.len]
    [out : text_buf.TextBuf buf]
    (for [index (iterator.range 0 count)]
      (let
        [entry : be_state.BackendFloatEntry
          (be_state.compiler-backend-global-array-element-shared-view
            slots
            index)]
        (set!
          out
          (text_buf.append
            out
            (compiler-backend-emit-float-entry entry.ty entry.bits)))))
    out))

(define (compiler-backend-emit-float-rodata-into
  [floats : be_state.BackendFloatSeq]
  [buf : text_buf.TextBuf]) : text_buf.TextBuf
  (if (= floats.len 0)
    buf
    (compiler-backend-emit-float-entries-into
      floats
      (text_buf.append buf "    .section .rodata\n"))))

(define (compiler-backend-emit-float-sign-bit-rodata-into
  [enabled : bool]
  [buf : text_buf.TextBuf]
  [f64? : bool]) : text_buf.TextBuf
  (if enabled
    (text_buf.append
      (text_buf.append
        (text_buf.append buf "    .section .rodata\n    .balign 16\n")
        (if f64?
          (be_facts.compiler-backend-f64-sign-bit-label)
          (be_facts.compiler-backend-f32-sign-bit-label)))
      (if f64?
        ":\n    .quad 0x8000000000000000\n    .quad 0\n"
        ":\n    .quad 0x80000000\n    .quad 0\n"))
    buf))

;; Inline aggregate globals. The lowerer owns the decision: a memory-class
;; `RuntimeGlobal` has `Inline size align` IR storage, its cell IS the
;; aggregate, and its initializer writes it through the leading sret pointer.
;; The backend only publishes that storage, so every `Global g` read of such a
;; cell -- including a read of another object's TypeLisp data symbol through
;; an extern -- materialises the symbol's address.
(define (compiler-backend-inline-cell-bytes [size : i64]) : i64
  (if (<= size 8)
    8
    (bit-and (+ size 7) (bit-not 7))))

(define (compiler-backend-global-storage-align
  [storage : (& storage compiler_ir_types.CompilerIrGlobalStorage)]) : i64
  (match storage
    [(Inline _ align)
      (if (> align 8)
        align
        8)]
    [(Word) 8]))

(define (compiler-backend-publish-global-storage-entry!
  [table : (&mut table backend_i64_i64_map.Map)]
  [name : i64]
  [storage : (& storage compiler_ir_types.CompilerIrGlobalStorage)]) : unit
  (match storage
    [(Inline size _)
      (backend_i64_i64_map.insert-ref!
        table
        (compiler_ir_types.compiler-ir-symbol-id name)
        (compiler-backend-inline-cell-bytes size))]
    [(Word) unit]))

;; Replaces the previous program's table, so a batch entry never sees another
;; program's cells.
(define (compiler-backend-publish-global-storage!
  [backend-state : be_state.CompilerBackendState]
  [globals : (& globals compiler_ir_types.CompilerIrGlobalSeq)]
  [externs : (& externs compiler_ir_types.CompilerIrExternSeq)]) : unit
  (let
    [table : backend_i64_i64_map.Map
      (backend_i64_i64_map.with-capacity (+ globals.len externs.len 1))]
    (for [index (iterator.range 0 globals.len)]
      (match (compiler_ir_types.compiler-ir-global-seq-borrow globals index)
        [(Global name _ _ storage)
          (compiler-backend-publish-global-storage-entry!
            (&mut table)
            name
            (& storage))]))
    (for [index (iterator.range 0 externs.len)]
      (match (compiler_ir_types.compiler-ir-extern-seq-borrow externs index)
        [(Extern name _ _ _ _ _ _ _ _ _ storage)
          (compiler-backend-publish-global-storage-entry!
            (&mut table)
            name
            (& storage))]))
    (be_state.compiler-backend-state-set-inline-aggregate-globals!
      backend-state
      table)))

;; The reserved cell size of a runtime-initialised global: the aggregate itself
;; (whole words, at least one) for an inline cell, two words for a register
;; group, one word otherwise.
(define (compiler-backend-runtime-global-cell-size
  [type-segment-bases : i64]
  [program-index : be_state.CompilerBackendProgramIndex]
  [storage : (& storage compiler_ir_types.CompilerIrGlobalStorage)]
  [ty : (& compiler_ast_types.AstType)]) : i64
  (match storage
    [(Inline size _) (compiler-backend-inline-cell-bytes size)]
    [(Word)
      (if (be_facts.compiler-backend-group-type?
        type-segment-bases
        program-index
        ty)
        16
        8)]))

;; The base-2 logarithm of a power-of-two alignment, as COFF `.comm` takes it.
(define (compiler-backend-align-log2 [align : i64]) : i64
  (let
    [log : i64 0]
    (while (< (shl 1 log) align)
      (+= log 1))
    log))

(define (compiler-backend-global-value-asm
  [type-segment-bases : i64]
  [ty : compiler_ast_types.AstType]
  [value : compiler_ir_types.CompilerIrValue]
  [program-index : be_state.CompilerBackendProgramIndex]) : be_state.ResultCompilerBackend
  (match value
    ;; A register-group global stores its value inline (16 bytes), so its
    ;; startup-initialized slot reserves two words rather than one.
    [(Unit)
      (if (be_facts.compiler-backend-group-type?
        type-segment-bases
        program-index
        ty)
        (Ok "    .quad 0\n    .quad 0\n")
        (Ok "    .quad 0\n"))]
    [(I64 n) (Ok (str_cat.str-cat "    .quad " (string.int->string n) "\n"))]
    [(Bool b)
      (if b
        (Ok "    .quad 1\n")
        (Ok "    .quad 0\n"))]
    [(Char c)
      (Ok
        (str_cat.str-cat
          "    .quad "
          (string.int->string (be_state.compiler-backend-char-code c))
          "\n"))]
    [(F64 bits) (Ok (compiler-backend-float-bits-directive ty bits))]
    ;; A static-array global (#8369) is a cell holding the address of the
    ;; element bytes that follow it: writable, one copy per global (never
    ;; deduplicated, so a store through one global's elements cannot show
    ;; through another's), and padded to 8 bytes so the next global stays
    ;; aligned. The cell keeps the pointer every `(Array T N)` value is.
    [(StaticArray bytes)
      (Ok
        (text_buf.render
          (text_buf.append
            (compiler-backend-emit-byte-directives-into
              bytes
              (text_buf.append (text_buf.empty) "    .quad .+8\n"))
            "    .balign 8\n")))]
    [(or (Global name) (GlobalAddr name))
      (Ok
        (str_cat.str-cat
          "    .quad "
          (be_facts.compiler-backend-function-or-global-addr-symbol
            program-index
            name)
          "\n"))]
    [(Function name)
      (Ok
        (str_cat.str-cat
          "    .quad "
          (be_operand.compiler-backend-closure-descriptor-label
            (be_state.compiler-backend-symbol-text-index program-index name))
          "\n"))]
    [(String text)
      (Ok
        (str_cat.str-cat
          "    .quad "
          (be_operand.compiler-backend-string-fat-label text)
          "\n"))]
    [(Bytes text)
      (Ok
        (str_cat.str-cat
          "    .quad "
          (be_operand.compiler-backend-bytes-fat-label text)
          "\n"))]
    [_
      (Err
        (box
          (compiler_diagnostic.compiler-diagnostic-at-start
            ""
            "backend: unsupported global initializer")))]))

(define (compiler-backend-runtime-global?
  [ty : (& ty compiler_ast_types.AstType)]
  [value : (& value compiler_ir_types.CompilerIrValue)]) : bool
  (match value
    [(RuntimeGlobal _) true]
    [(Unit)
      (match ty
        [(Unit) false]
        [_ true])]
    [_ false]))

(define (compiler-backend-emit-runtime-global
  [target : be_state.CompilerBackendTarget]
  [symbol : String]
  [size : i64]
  [align : i64]) : String
  ;; ELF `.comm` takes the alignment in bytes, COFF its base-2 logarithm.
  (str_cat.str-cat
    "    .comm "
    symbol
    ", "
    (string.int->string size)
    ", "
    (string.int->string
      (if (be_state.compiler-backend-target-elf? target)
        align
        (compiler-backend-align-log2 align)))
    "\n"))

(define (compiler-backend-emit-global
  [type-segment-bases : i64]
  [target : be_state.CompilerBackendTarget]
  [global : compiler_ir_types.CompilerIrGlobal]
  [program-index : be_state.CompilerBackendProgramIndex]) : be_state.ResultCompilerBackend
  (match global
    [(Global name ty value storage)
      (let
        [symbol : String
          (be_state.compiler-backend-state-user-symbol-id
            program-index.backend-state
            name)]
        [align : i64 (compiler-backend-global-storage-align (& storage))]
        [private? : bool
          (be_state.compiler-backend-state-private-global?
            program-index.backend-state
            name)]
        [library? : bool
          (be_state.compiler-backend-state-library-object?
            program-index.backend-state)]
        [zeroed? : bool (compiler-backend-runtime-global? ty value)]
        [visibility : String
          (if private?
            ""
            (str_cat.str-cat ".globl " symbol "\n"))]
        [size : i64
          (if zeroed?
            (compiler-backend-runtime-global-cell-size
              type-segment-bases
              program-index
              (& storage)
              (& ty))
            0)]
        (if (and zeroed? (not library?))
          (Ok
            (str_cat.str-cat
              visibility
              (compiler-backend-emit-runtime-global target symbol size align)))
          (let
            [section : String
              (if library?
                (match target
                  [(Linux)
                    (cond
                      [zeroed?
                        (be_operand.compiler-backend-elf-symbol-section
                          ".bss"
                          (& symbol)
                          "\"aw\",@nobits")]
                      [private?
                        (be_operand.compiler-backend-elf-symbol-section
                          ".rodata"
                          (& symbol)
                          "\"a\",@progbits")]
                      [else
                        (be_operand.compiler-backend-elf-symbol-section
                          ".data"
                          (& symbol)
                          "\"aw\",@progbits")])]
                  [(Windows)
                    (str_cat.str-cat
                      (cond
                        [zeroed? ".section .bss,\"bw\",one_only,"]
                        [private? ".section .rdata,\"dr\",one_only,"]
                        [else ".section .data,\"dw\",one_only,"])
                      symbol
                      "\n")])
                "")]
            [value-asm
              (try
                (if zeroed?
                  (be_state.ResultCompilerBackend.Ok
                    (str_cat.str-cat
                      "    .zero "
                      (string.int->string size)
                      "\n"))
                  (compiler-backend-global-value-asm
                    type-segment-bases
                    ty
                    value
                    program-index)))]
            (Ok
              (str_cat.str-cat
                section
                (if library?
                  (str_cat.str-cat
                    "    .balign "
                    (string.int->string align)
                    "\n")
                  "")
                visibility
                (if (and
                  private?
                  (be_state.compiler-backend-target-elf? target))
                  (str_cat.str-cat ".type " symbol ",@object\n")
                  "")
                symbol
                ":\n"
                value-asm)))))]))

(define (compiler-backend-emit-globals-buffer-from
  [type-segment-bases : i64]
  [target : be_state.CompilerBackendTarget]
  [globals : compiler_ir_types.CompilerIrGlobalSeq]
  [buf : text_buf.TextBuf]
  [program-index : be_state.CompilerBackendProgramIndex]
  [index : i64]) : be_state.ResultCompilerBackendBuffer
  (if (>= index globals.len)
    (Ok buf)
    (let
      [head
        (try
          (compiler-backend-emit-global
            type-segment-bases
            target
            (compiler_ir_types.compiler-ir-global-seq-ref globals index)
            program-index))]
      (compiler-backend-emit-globals-buffer-from
        type-segment-bases
        target
        globals
        (text_buf.append buf head)
        program-index
        (+ index 1)))))

(define (compiler-backend-emit-globals-buffer-into
  [type-segment-bases : i64]
  [target : be_state.CompilerBackendTarget]
  [globals : compiler_ir_types.CompilerIrGlobalSeq]
  [buf : text_buf.TextBuf]
  [program-index : be_state.CompilerBackendProgramIndex]) : be_state.ResultCompilerBackendBuffer
  (compiler-backend-emit-globals-buffer-from
    type-segment-bases
    target
    globals
    buf
    program-index
    0))

(define (compiler-backend-global-init-call
  [type-segment-bases : i64]
  [target : be_state.CompilerBackendTarget]
  [name : i64]
  [init : i64]
  [ty : (& compiler_ast_types.AstType)]
  [storage : (& storage compiler_ir_types.CompilerIrGlobalStorage)]
  [program-index : be_state.CompilerBackendProgramIndex]) : String
  (let
    [symbol : String
      (be_state.compiler-backend-state-user-symbol-id
        program-index.backend-state
        name)]
    [init-symbol : String
      (be_state.compiler-backend-state-user-symbol-id
        program-index.backend-state
        init)]
    [inline? : bool
      (match storage
        [(Inline _ _) true]
        [(Word) false])]
    (str_cat.str-cat
      ;; An inline cell is the initializer's leading sret argument: it writes
      ;; the aggregate in place, and its returned pointer needs no copy.
      (if inline?
        (str_cat.str-cat
          "    leaq "
          symbol
          "(%rip), "
          (if (be_state.compiler-backend-target-elf? target)
            "%rdi"
            "%rcx")
          "\n")
        "")
      "    call "
      init-symbol
      "\n"
      (cond
        [inline? ""]
        ;; A register-group init returns word0:word1 in %rax:%rdx; store
        ;; both into the inline 16-byte global slot.
        [(be_facts.compiler-backend-group-type?
            type-segment-bases
            program-index
            ty)
          (str_cat.str-cat
            "    movq %rax, "
            symbol
            "(%rip)\n    movq %rdx, "
            symbol
            "+8(%rip)\n"
            "")]
        [(be_operand.compiler-backend-float-type? ty)
          (str_cat.str-cat
            "    "
            (be_operand.compiler-backend-float-move ty)
            " %xmm0, "
            symbol
            "(%rip)\n")]
        [else (str_cat.str-cat "    movq %rax, " symbol "(%rip)\n")])
      "")))

(define (compiler-backend-global-initializers-from
  [type-segment-bases : i64]
  [target : be_state.CompilerBackendTarget]
  [globals : (& compiler_ir_types.CompilerIrGlobalSeq)]
  [program-index : be_state.CompilerBackendProgramIndex]
  [index : i64]
  [selection : i64]) : String
  (if (>= index globals.len)
    ""
    (match (compiler_ir_types.compiler-ir-global-seq-borrow globals index)
      [(Global name ty value storage)
        (str_cat.str-cat
          (match value
            [(RuntimeGlobal init)
              (if (compiler-backend-global-init-selected?
                program-index.backend-state
                name
                selection)
                (compiler-backend-global-init-call
                  type-segment-bases
                  target
                  name
                  init
                  ty
                  (& storage)
                  program-index)
                "")]
            [_ ""])
          (compiler-backend-global-initializers-from
            type-segment-bases
            target
            globals
            program-index
            (+ index 1)
            selection))])))

;; Initializer selection: 0 every global, 1 source-loaded stdlib globals, 2
;; every other global.
(define (compiler-backend-global-init-selected?
  [backend-state : be_state.CompilerBackendState]
  [name : i64]
  [selection : i64]) : bool
  (if (= selection 0)
    true
    (let
      [text : String
        (be_state.compiler-backend-symbol-text-state backend-state name)]
      [stdlib? : bool
        (or
          (be_operand.compiler-backend-string-prefix-at? text "stdlib." 0)
          (be_operand.compiler-backend-string-prefix-at? text "stdlib/" 0)
          (be_operand.compiler-backend-string-prefix-at? text "stdlib\\" 0))]
      (if (= selection 1)
        stdlib?
        (not stdlib?)))))

(define (compiler-backend-startup-init-calls
  [backend-state : be_state.CompilerBackendState]) : String
  (let
    [symbols : (__tl_dyn-array String)
      (be_state.compiler-backend-state-startup-init-symbols backend-state)]
    [count : i64 (array-length symbols)]
    (if (= count 0)
      ""
      (let
        [buf : text_buf.TextBuf (text_buf.empty)]
        (for [i (iterator.range 0 count)]
          (let
            [sym : String (string.copy (& (array-ref symbols i)))]
            (set!
              buf
              (text_buf.append buf (str_cat.str-cat "    call " sym "\n")))))
        (text_buf.render buf)))))

(define (compiler-backend-global-initializers
  [type-segment-bases : i64]
  [target : be_state.CompilerBackendTarget]
  [globals : compiler_ir_types.CompilerIrGlobalSeq]
  [program-index : be_state.CompilerBackendProgramIndex]) : String
  (let
    [startup : String
      (compiler-backend-startup-init-calls program-index.backend-state)]
    (if (= (string.string-length (& startup)) 0)
      (compiler-backend-global-initializers-from
        type-segment-bases
        target
        globals
        program-index
        0
        0)
      ;; Hydrated module initializers may read stdlib globals: a stdlib loaded
      ;; from source (no prebuilt stdlib) initializes before them, and the
      ;; program's own globals after them.
      (str_cat.str-cat
        (compiler-backend-global-initializers-from
          type-segment-bases
          target
          globals
          program-index
          0
          1)
        startup
        (compiler-backend-global-initializers-from
          type-segment-bases
          target
          globals
          program-index
          0
          2)))))

(define (compiler-backend-runtime-prelude-helper-function?
  [name : String]
  [helper : (& helper str)]) : bool
  (and
    (string.eq (be_operand.compiler-backend-symbol-leaf name) helper)
    (be_operand.compiler-backend-stdlib-runtime-function-name? name)))

(define (compiler-backend-function-seq-defines-runtime-prelude-helper?
  [backend-state : be_state.CompilerBackendState]
  [functions : compiler_ir_types.CompilerIrFunctionSeq]
  [helper : String]) : bool
  (compiler-backend-function-seq-defines-runtime-prelude-helper-from?
    backend-state
    functions
    helper))

(define (compiler-backend-function-seq-defines-runtime-prelude-helper-from?
  [backend-state : be_state.CompilerBackendState]
  [functions : compiler_ir_types.CompilerIrFunctionSeq]
  [helper : String]) : bool
  (for [index
    (iterator.range
      0
      (compiler_ir_types.compiler-ir-function-seq-count functions))]
    (match (owned_view.compiler-owned-element-view functions.slots index)
      [(Function name _ _ _ _ _)
        (when
          (compiler-backend-runtime-prelude-helper-function?
            (be_state.compiler-backend-symbol-text-state backend-state name)
            helper)
          (return true))]))
  false)

(define (compiler-backend-runtime-index-empty) : be_state.CompilerBackendRuntimeIndex
  (be_state.CompilerBackendRuntimeIndex
    (backend_i64_i64_map.with-capacity 256)
    (backend_i64_i64_map.with-capacity 256)
    (backend_i64_i64_map.with-capacity 256)
    -1
    false))

(define (compiler-backend-runtime-index-defines?
  [index : (& index be_state.CompilerBackendRuntimeIndex)]
  [name-id : i64]) : bool
  (backend_i64_i64_map.contains? (& index.defines) name-id))

(define (compiler-backend-runtime-index-extern?
  [index : (& index be_state.CompilerBackendRuntimeIndex)]
  [name-id : i64]) : bool
  (backend_i64_i64_map.contains? (& index.externs) name-id))

(define (compiler-backend-runtime-index-calls?
  [index : (& index be_state.CompilerBackendRuntimeIndex)]
  [name-id : i64]) : bool
  (backend_i64_i64_map.contains? (& index.calls) name-id))

(define (compiler-backend-runtime-index-add-define
  [index : be_state.CompilerBackendRuntimeIndex]
  [name-id : i64]) : be_state.CompilerBackendRuntimeIndex
  (let
    [defines : backend_i64_i64_map.Map index.defines]
    (backend_i64_i64_map.insert-ref! (&mut defines) name-id 1)
    (be_state.CompilerBackendRuntimeIndex
      defines
      index.externs
      index.calls
      index.tlci-macro-entry-call-id
      index.startup-profile)))

(define (compiler-backend-runtime-index-add-extern-name
  [index : be_state.CompilerBackendRuntimeIndex]
  [name-id : i64]) : be_state.CompilerBackendRuntimeIndex
  (let
    [externs : backend_i64_i64_map.Map index.externs]
    (backend_i64_i64_map.insert-ref! (&mut externs) name-id 1)
    (be_state.CompilerBackendRuntimeIndex
      index.defines
      externs
      index.calls
      index.tlci-macro-entry-call-id
      index.startup-profile)))

(define (compiler-backend-runtime-index-add-call
  [index : be_state.CompilerBackendRuntimeIndex]
  [name-id : i64]) : be_state.CompilerBackendRuntimeIndex
  (let
    [calls : backend_i64_i64_map.Map index.calls]
    (backend_i64_i64_map.insert-ref! (&mut calls) name-id 1)
    (be_state.CompilerBackendRuntimeIndex
      index.defines
      index.externs
      calls
      index.tlci-macro-entry-call-id
      index.startup-profile)))

(define (compiler-backend-runtime-index-with-extern-role
  [index : be_state.CompilerBackendRuntimeIndex]
  [call-id : i64]
  [link-id : i64]) : be_state.CompilerBackendRuntimeIndex
  (set!
    index.tlci-macro-entry-call-id
    (if (cbi.compiler-builtin-backend-tlci-call-macro-entry-id? link-id)
      call-id
      index.tlci-macro-entry-call-id))
  index)

(define (compiler-backend-runtime-index-with-startup-profile-role
  [index : be_state.CompilerBackendRuntimeIndex]
  [link-id : i64]
  [backend-state : be_state.CompilerBackendState]) : be_state.CompilerBackendRuntimeIndex
  (if (string.eq
    (be_state.compiler-backend-symbol-text-state backend-state link-id)
    "tl_startup_profile_process_entry_tick")
    (begin
      (set! index.startup-profile true)
      index)
    index))

(define (compiler-backend-runtime-index-instr
  [index : be_state.CompilerBackendRuntimeIndex]
  [instr : compiler_ir_types.CompilerIrInstr]) : be_state.CompilerBackendRuntimeIndex
  (match instr
    [(or (Call _ call-name _ _) (TailCall call-name _ _))
      (compiler-backend-runtime-index-add-call index call-name)]
    [(CallCAbiStoreResult payload-box)
      (let
        [call-name (deref payload-box).name]
        (compiler-backend-runtime-index-add-call index call-name))]
    [_ index]))

(define (compiler-backend-runtime-index-instr-seq
  [index : be_state.CompilerBackendRuntimeIndex]
  [instrs : compiler_ir_types.CompilerIrInstrSeq]) : be_state.CompilerBackendRuntimeIndex
  (let
    [slots : (__tl_dyn-array compiler_ir_types.CompilerIrInstr) instrs.slots]
    [count : i64 instrs.len]
    [out : be_state.CompilerBackendRuntimeIndex index]
    (for [i (iterator.range 0 count)]
      (set!
        out
        (compiler-backend-runtime-index-instr
          out
          (be_state.compiler-backend-global-array-element-shared-view slots i))))
    out))

(define (compiler-backend-runtime-index-blocks
  [index : be_state.CompilerBackendRuntimeIndex]
  [blocks : compiler_ir_types.CompilerIrBlockList]) : be_state.CompilerBackendRuntimeIndex
  (match blocks
    [(Array seq) (compiler-backend-runtime-index-block-seq index seq 0)]))

(define (compiler-backend-runtime-index-block-seq
  [index : be_state.CompilerBackendRuntimeIndex]
  [blocks : compiler_ir_types.CompilerIrBlockSeq]
  [seq-index : i64]) : be_state.CompilerBackendRuntimeIndex
  (if (>= seq-index (compiler_ir_types.compiler-ir-block-seq-count blocks))
    index
    (match (compiler_ir_types.compiler-ir-block-seq-ref blocks seq-index)
      [(Block _ instrs)
        (compiler-backend-runtime-index-block-seq
          (compiler-backend-runtime-index-instr-seq index instrs)
          blocks
          (+ seq-index 1))])))

(define (compiler-backend-runtime-index-functions
  [index : be_state.CompilerBackendRuntimeIndex]
  [functions : compiler_ir_types.CompilerIrFunctionSeq]) : be_state.CompilerBackendRuntimeIndex
  (compiler-backend-runtime-index-function-seq index functions 0))

(define (compiler-backend-runtime-index-function-seq
  [index : be_state.CompilerBackendRuntimeIndex]
  [functions : compiler_ir_types.CompilerIrFunctionSeq]
  [seq-index : i64]) : be_state.CompilerBackendRuntimeIndex
  (if (>=
    seq-index
    (compiler_ir_types.compiler-ir-function-seq-count functions))
    index
    (match (owned_view.compiler-owned-element-view functions.slots seq-index)
      [(Function name _ _ _ blocks _)
        (compiler-backend-runtime-index-function-seq
          (compiler-backend-runtime-index-blocks
            (compiler-backend-runtime-index-add-define index name)
            blocks)
          functions
          (+ seq-index 1))])))

(define (compiler-backend-runtime-index-externs
  [backend-state : be_state.CompilerBackendState]
  [index : be_state.CompilerBackendRuntimeIndex]
  [externs : compiler_ir_types.CompilerIrExternSeq]) : be_state.CompilerBackendRuntimeIndex
  (compiler-backend-runtime-index-extern-seq backend-state index externs 0))

(define (compiler-backend-runtime-index-extern-seq
  [backend-state : be_state.CompilerBackendState]
  [index : be_state.CompilerBackendRuntimeIndex]
  [externs : compiler_ir_types.CompilerIrExternSeq]
  [seq-index : i64]) : be_state.CompilerBackendRuntimeIndex
  (if (>= seq-index (compiler_ir_types.compiler-ir-extern-seq-count externs))
    index
    (match (compiler_ir_types.compiler-ir-extern-seq-borrow externs seq-index)
      [(Extern name-id source-name-id _ _ _ link-symbol _ provided _ _ _)
        (let
          [with-startup-role : be_state.CompilerBackendRuntimeIndex
            (compiler-backend-runtime-index-with-startup-profile-role
              index
              link-symbol
              backend-state)]
          (compiler-backend-runtime-index-extern-seq
            backend-state
            (if provided
              with-startup-role
              (compiler-backend-runtime-index-with-extern-role
                (compiler-backend-runtime-index-add-extern-name
                  (compiler-backend-runtime-index-add-extern-name
                    (compiler-backend-runtime-index-add-extern-name
                      with-startup-role
                      name-id)
                    source-name-id)
                  link-symbol)
                name-id
                link-symbol))
            externs
            (+ seq-index 1)))])))

(define (compiler-backend-runtime-index-arena-debug-call-links
  [index : be_state.CompilerBackendRuntimeIndex]
  [externs : compiler_ir_types.CompilerIrExternSeq]) : be_state.CompilerBackendRuntimeIndex
  (compiler-backend-runtime-index-arena-debug-call-link-seq index externs 0))

(define (compiler-backend-runtime-index-arena-debug-call-link-seq
  [index : be_state.CompilerBackendRuntimeIndex]
  [externs : compiler_ir_types.CompilerIrExternSeq]
  [seq-index : i64]) : be_state.CompilerBackendRuntimeIndex
  (if (>= seq-index (compiler_ir_types.compiler-ir-extern-seq-count externs))
    index
    (match (compiler_ir_types.compiler-ir-extern-seq-borrow externs seq-index)
      [(Extern name-id source-name-id _ _ _ link-symbol _ _ _ _ _)
        (compiler-backend-runtime-index-arena-debug-call-link-seq
          (if (and
            (cbi.compiler-builtin-backend-runtime-arena-debug-id? link-symbol)
            (or
              (compiler-backend-runtime-index-calls? index name-id)
              (compiler-backend-runtime-index-calls? index source-name-id)))
            (compiler-backend-runtime-index-add-call index link-symbol)
            index)
          externs
          (+ seq-index 1))])))

(define (compiler-backend-runtime-index
  [backend-state : be_state.CompilerBackendState]
  [functions : compiler_ir_types.CompilerIrFunctionSeq]
  [externs : compiler_ir_types.CompilerIrExternSeq]) : be_state.CompilerBackendRuntimeIndex
  (compiler-backend-runtime-index-arena-debug-call-links
    (compiler-backend-runtime-index-functions
      (compiler-backend-runtime-index-externs
        backend-state
        (compiler-backend-runtime-index-empty)
        (be_state.compiler-backend-global-shared-view externs))
      functions)
    externs))

(define (compiler-backend-runtime-plan-with-index-for-with-backend-state
  [backend-state : be_state.CompilerBackendState]
  [functions : compiler_ir_types.CompilerIrFunctionSeq]
  [externs : compiler_ir_types.CompilerIrExternSeq]) : be_state.ResultBackendRuntimePlanWithIndex
  (let
    [index : be_state.CompilerBackendRuntimeIndex
      (compiler-backend-runtime-index
        backend-state
        (be_state.compiler-backend-global-shared-view functions)
        externs)]
    [defines-alloc : bool
      (or
        (compiler-backend-runtime-index-defines?
          index
          cbi.compiler-builtin-id-tl-alloc)
        (compiler-backend-runtime-index-defines?
          index
          cbi.compiler-builtin-id-tl-alloc-aligned)
        (compiler-backend-runtime-index-defines?
          index
          cbi.compiler-builtin-id-tl-alloc-global))]
    [defines-substring : bool
      (compiler-backend-runtime-index-defines?
        index
        cbi.compiler-builtin-id-tl-substring)]
    [defines-str-view : bool
      (compiler-backend-runtime-index-defines?
        index
        cbi.compiler-builtin-id-tl-str-view)]
    [defines-concat : bool
      (be_state.backend-or4
        (compiler-backend-runtime-index-defines?
          index
          cbi.compiler-builtin-id-tl-string-concat)
        (compiler-backend-runtime-index-defines?
          index
          cbi.compiler-builtin-id-tl-string-concat3)
        (compiler-backend-runtime-index-defines?
          index
          cbi.compiler-builtin-id-tl-string-concat4)
        (compiler-backend-runtime-index-defines?
          index
          cbi.compiler-builtin-id-tl-string-concat5))]
    [defines-int-to-string : bool
      (compiler-backend-runtime-index-defines?
        index
        cbi.compiler-builtin-id-tl-int-to-string)]
    [provides-substring : bool
      (compiler-backend-function-seq-defines-runtime-prelude-helper?
        backend-state
        (be_state.compiler-backend-global-shared-view functions)
        "substring")]
    [provides-str-view : bool
      (compiler-backend-function-seq-defines-runtime-prelude-helper?
        backend-state
        (be_state.compiler-backend-global-shared-view functions)
        "str-view")]
    [provides-concat : bool
      (be_state.backend-or4
        (compiler-backend-function-seq-defines-runtime-prelude-helper?
          backend-state
          (be_state.compiler-backend-global-shared-view functions)
          "string-concat")
        (compiler-backend-function-seq-defines-runtime-prelude-helper?
          backend-state
          (be_state.compiler-backend-global-shared-view functions)
          "string-concat3")
        (compiler-backend-function-seq-defines-runtime-prelude-helper?
          backend-state
          (be_state.compiler-backend-global-shared-view functions)
          "string-concat4")
        (compiler-backend-function-seq-defines-runtime-prelude-helper?
          backend-state
          (be_state.compiler-backend-global-shared-view functions)
          "string-concat5"))]
    [provides-int-to-string : bool
      (compiler-backend-function-seq-defines-runtime-prelude-helper?
        backend-state
        functions
        "int-to-string")]
    [defines-region-mark : bool
      (compiler-backend-runtime-index-defines?
        index
        cbi.compiler-builtin-id-tl-region-mark)]
    [defines-region-reset : bool
      (compiler-backend-runtime-index-defines?
        index
        cbi.compiler-builtin-id-tl-region-reset)]
    [defines-profile-alloc-total : bool
      (compiler-backend-runtime-index-defines?
        index
        cbi.compiler-builtin-id-tl-profile-alloc-total)]
    [defines-profile-alloc-live : bool
      (compiler-backend-runtime-index-defines?
        index
        cbi.compiler-builtin-id-tl-profile-alloc-live)]
    [defines-profile-alloc-peak : bool
      (compiler-backend-runtime-index-defines?
        index
        cbi.compiler-builtin-id-tl-profile-alloc-peak)]
    [defines-profile-alloc-reset-peak : bool
      (compiler-backend-runtime-index-defines?
        index
        cbi.compiler-builtin-id-tl-profile-alloc-reset-peak)]
    [extern-region-mark : bool
      (compiler-backend-runtime-index-extern?
        index
        cbi.compiler-builtin-id-tl-region-mark)]
    [extern-region-reset : bool
      (compiler-backend-runtime-index-extern?
        index
        cbi.compiler-builtin-id-tl-region-reset)]
    [extern-profile-alloc-total : bool
      (compiler-backend-runtime-index-extern?
        index
        cbi.compiler-builtin-id-tl-profile-alloc-total)]
    [extern-profile-alloc-live : bool
      (compiler-backend-runtime-index-extern?
        index
        cbi.compiler-builtin-id-tl-profile-alloc-live)]
    [extern-profile-alloc-peak : bool
      (compiler-backend-runtime-index-extern?
        index
        cbi.compiler-builtin-id-tl-profile-alloc-peak)]
    [extern-profile-alloc-reset-peak : bool
      (compiler-backend-runtime-index-extern?
        index
        cbi.compiler-builtin-id-tl-profile-alloc-reset-peak)]
    [calls-alloc : bool
      (or
        (compiler-backend-runtime-index-calls?
          index
          cbi.compiler-builtin-id-tl-alloc)
        (compiler-backend-runtime-index-calls?
          index
          cbi.compiler-builtin-id-tl-alloc-aligned)
        (compiler-backend-runtime-index-calls?
          index
          cbi.compiler-builtin-id-tl-alloc-global))]
    [calls-substring : bool
      (compiler-backend-runtime-index-calls?
        index
        cbi.compiler-builtin-id-tl-substring)]
    [calls-str-view : bool
      (compiler-backend-runtime-index-calls?
        index
        cbi.compiler-builtin-id-tl-str-view)]
    [calls-concat : bool
      (be_state.backend-or4
        (compiler-backend-runtime-index-calls?
          index
          cbi.compiler-builtin-id-tl-string-concat)
        (compiler-backend-runtime-index-calls?
          index
          cbi.compiler-builtin-id-tl-string-concat3)
        (compiler-backend-runtime-index-calls?
          index
          cbi.compiler-builtin-id-tl-string-concat4)
        (compiler-backend-runtime-index-calls?
          index
          cbi.compiler-builtin-id-tl-string-concat5))]
    [calls-int-to-string : bool
      (compiler-backend-runtime-index-calls?
        index
        cbi.compiler-builtin-id-tl-int-to-string)]
    [calls-region-mark : bool
      (compiler-backend-runtime-index-calls?
        index
        cbi.compiler-builtin-id-tl-region-mark)]
    [calls-region-reset : bool
      (compiler-backend-runtime-index-calls?
        index
        cbi.compiler-builtin-id-tl-region-reset)]
    [calls-profile-alloc-total : bool
      (compiler-backend-runtime-index-calls?
        index
        cbi.compiler-builtin-id-tl-profile-alloc-total)]
    [calls-profile-alloc-live : bool
      (compiler-backend-runtime-index-calls?
        index
        cbi.compiler-builtin-id-tl-profile-alloc-live)]
    [calls-profile-alloc-peak : bool
      (compiler-backend-runtime-index-calls?
        index
        cbi.compiler-builtin-id-tl-profile-alloc-peak)]
    [calls-profile-alloc-reset-peak : bool
      (compiler-backend-runtime-index-calls?
        index
        cbi.compiler-builtin-id-tl-profile-alloc-reset-peak)]
    [calls-arena-debug-protect : bool
      (compiler-backend-runtime-index-calls?
        index
        cbi.compiler-builtin-id-tl-arena-debug-protect-never-reset)]
    [calls-arena-debug-retire : bool
      (compiler-backend-runtime-index-calls?
        index
        cbi.compiler-builtin-id-tl-arena-debug-retire-protected)]
    [calls-arena-debug-pool-install : bool
      (compiler-backend-runtime-index-calls?
        index
        cbi.compiler-builtin-id-tl-arena-debug-assert-pool-install)]
    ;; Prelude string helpers keep fixed export symbols for validation and call
    ;; spelling, but their TypeLisp bodies expose allocator calls directly in
    ;; the runtime index. The plan therefore retains only these symbol facts;
    ;; only a real `tl_alloc` call enables allocator asm.
    [needs-substring : bool
      (or provides-substring (and (not defines-substring) calls-substring))]
    [needs-str-view : bool
      (or provides-str-view (and (not defines-str-view) calls-str-view))]
    [needs-concat : bool
      (or provides-concat (and (not defines-concat) calls-concat))]
    [needs-int-to-string : bool
      (or
        provides-int-to-string
        (and (not defines-int-to-string) calls-int-to-string))]
    [needs-alloc : bool (and (not defines-alloc) calls-alloc)]
    [needs-region-mark : bool
      (and (not defines-region-mark) (or extern-region-mark calls-region-mark))]
    [needs-region-reset : bool
      (and
        (not defines-region-reset)
        (or extern-region-reset calls-region-reset))]
    [needs-profile : bool
      (be_state.backend-or4
        (and
          (not defines-profile-alloc-total)
          (or extern-profile-alloc-total calls-profile-alloc-total))
        (and
          (not defines-profile-alloc-live)
          (or extern-profile-alloc-live calls-profile-alloc-live))
        (and
          (not defines-profile-alloc-peak)
          (or extern-profile-alloc-peak calls-profile-alloc-peak))
        (and
          (not defines-profile-alloc-reset-peak)
          (or extern-profile-alloc-reset-peak calls-profile-alloc-reset-peak)))]
    [needs-arena-debug : bool
      (or
        calls-arena-debug-protect
        calls-arena-debug-pool-install
        calls-arena-debug-retire)]
    [needs-tlci-macro-entry : bool
      (let
        [call-id : i64 index.tlci-macro-entry-call-id]
        (and
          (>= call-id 0)
          (compiler-backend-runtime-index-calls? index call-id)))]
    [needs-startup-profile : bool index.startup-profile]
    (Ok
      (be_state.CompilerBackendRuntimePlanWithIndex
        (Plan
          needs-alloc
          needs-substring
          needs-str-view
          needs-concat
          needs-int-to-string
          needs-region-mark
          needs-region-reset
          (be_state.CompilerBackendRuntimeTailPlan
            needs-profile
            needs-tlci-macro-entry
            needs-arena-debug
            needs-startup-profile))
        index))))

(define (compiler-backend-runtime-plan-for-with-backend-state
  [backend-state : be_state.CompilerBackendState]
  [functions : compiler_ir_types.CompilerIrFunctionSeq]
  [externs : compiler_ir_types.CompilerIrExternSeq]) : be_state.ResultBackendRuntimePlan
  (let
    [planned
      (try
        (compiler-backend-runtime-plan-with-index-for-with-backend-state
          backend-state
          functions
          externs))]
    (Ok planned.plan)))

(define (compiler-backend-runtime-plan-with-backend-state
  [backend-state : be_state.CompilerBackendState]
  [program : compiler_ir_types.CompilerIrProgram]) : be_state.ResultBackendRuntimePlan
  ;; Seed builtin/runtime ids before scratch-backed per-function emission. The
  ;; runtime-plan id predicates are then lookup-only in scratch arenas.
  (cbi.compiler-builtin-refresh!)
  (match program
    [(Program _ functions externs _authority)
      (compiler-backend-runtime-plan-for-with-backend-state
        backend-state
        functions
        externs)]))

(define (compiler-backend-runtime-plan-with-index-with-backend-state
  [backend-state : be_state.CompilerBackendState]
  [program : compiler_ir_types.CompilerIrProgram]) : be_state.ResultBackendRuntimePlanWithIndex
  ;; Seed builtin/runtime ids before scratch-backed per-function emission. The
  ;; runtime-plan id predicates are then lookup-only in scratch arenas.
  (cbi.compiler-builtin-refresh!)
  (match program
    [(Program _ functions externs _authority)
      (compiler-backend-runtime-plan-with-index-for-with-backend-state
        backend-state
        functions
        externs)]))

(define (compiler-backend-emit-startup-init-externs-into
  [backend-state : be_state.CompilerBackendState]
  [buf : text_buf.TextBuf]) : text_buf.TextBuf
  (let
    [symbols : (__tl_dyn-array String)
      (be_state.compiler-backend-state-startup-init-symbols backend-state)]
    [count : i64 (array-length symbols)]
    [out : text_buf.TextBuf buf]
    (for [i (iterator.range 0 count)]
      (set!
        out
        (text_buf.append
          (text_buf.append out ".extern ")
          (str_cat.str-cat (string.copy (& (array-ref symbols i))) "\n" ""))))
    out))

(define (compiler-backend-emit-externs-into
  [backend-state : be_state.CompilerBackendState]
  [externs : compiler_ir_types.CompilerIrExternSeq]
  [plan : be_state.CompilerBackendRuntimePlan]
  [runtime-index : be_state.CompilerBackendRuntimeIndex]
  [referenced-functions : be_state.BackendSymbolSeq]
  [buf : text_buf.TextBuf]) : text_buf.TextBuf
  (compiler-backend-emit-startup-init-externs-into
    backend-state
    (compiler-backend-emit-extern-seq-into
      backend-state
      externs
      plan
      runtime-index
      referenced-functions
      buf
      0)))

(define (compiler-backend-emit-extern-seq-into
  [backend-state : be_state.CompilerBackendState]
  [externs : (& externs compiler_ir_types.CompilerIrExternSeq)]
  [plan : be_state.CompilerBackendRuntimePlan]
  [runtime-index : (& runtime-index be_state.CompilerBackendRuntimeIndex)]
  [referenced-functions : (& referenced-functions be_state.BackendSymbolSeq)]
  [buf : text_buf.TextBuf]
  [seq-index : i64]) : text_buf.TextBuf
  (if (>= seq-index (compiler_ir_types.compiler-ir-extern-seq-count externs))
    buf
    (match (compiler_ir_types.compiler-ir-extern-seq-borrow externs seq-index)
      [(Extern name-id source-name-id _ _ abi link-symbol-id _ provided _ _ _)
        (compiler-backend-emit-extern-seq-into
          backend-state
          externs
          plan
          runtime-index
          referenced-functions
          (if (and
            (be_facts.compiler-backend-emits-extern-symbol?
              backend-state
              name-id
              link-symbol-id
              provided
              plan)
            (be_facts.compiler-backend-extern-symbol-referenced?
              runtime-index
              referenced-functions
              name-id
              source-name-id
              link-symbol-id))
            (text_buf.append
              (text_buf.append buf ".extern ")
              (str_cat.str-cat
                (be_operand.compiler-backend-link-symbol-id
                  link-symbol-id
                  plan
                  backend-state
                  (compiler_ast_types.ast-extern-abi-c? abi))
                "\n"
                ""))
            buf)
          (+ seq-index 1))])))

;; `tl_current_arena` is the stable first-segment root handle shared by tl_alloc,
;; the region runtime, and the first-class arena builtins. Physical growth heads
;; are reached through root+56 and never replace this public identity. It is a
;; per-thread active-arena slot: Linux uses local-exec ELF TLS; Windows stores
;; the root in the TEB arbitrary-user slot (GS:0x28). Like the arena
;; primitives, the runtime lives in exactly ONE object per executable (the entry
;; object, `emit-entry=true`); library/dependency objects (`emit-entry=false`)
;; emit none of the runtime and reference the Linux TLS slot as an extern.
;; Runtime planning and indexing stay in this module. Emission consumes one
;; narrow immutable recipe and selects a platform leaf once for each composed
;; data, function, and extern fragment.
(define (compiler-backend-runtime-features
  [plan : be_state.CompilerBackendRuntimePlan]) : runtime_common.CompilerBackendRuntimeFeatures
  (cbi.compiler-builtin-refresh!)
  (match plan
    [(Plan alloc _ _ _ _ region-mark region-reset tail-plan)
      (runtime_common.CompilerBackendRuntimeFeatures
        alloc
        region-mark
        region-reset
        (be_state.compiler-backend-runtime-tail-arena-debug? tail-plan)
        (be_state.compiler-backend-runtime-tail-profile? tail-plan)
        (be_state.compiler-backend-runtime-tail-tlci-macro-entry? tail-plan)
        (be_state.compiler-backend-runtime-tail-startup-profile? tail-plan)
        (compiler_ir_types.compiler-debug-info-enabled?)
        31)]))

;; These leaves have no incoming edges from the always-emitted runtime. Keep
;; them for direct calls, address-taken symbols, and any referenced extern alias.
;; Reuse the call and reference inventories already built for symbol emission.
;; Every direct-callee IR form capable of targeting these leaves must be indexed.
;; No pass after runtime indexing may introduce a new runtime-leaf call.
(define (compiler-backend-runtime-leaf-bit
  [backend-state : be_state.CompilerBackendState]
  [name : i64]) : i64
  (let
    [text : String
      (be_state.compiler-backend-symbol-text-state backend-state name)]
    (cond
      [(string.eq text "tl_memchr") 1]
      [(string.eq text "tl_tlci_call_image_entry") 2]
      [(string.eq text "tl_mem_copy_fwd") 4]
      [(string.eq text "tl_mem_copy8_fwd") 8]
      [(string.eq text "tl_mem_fill8") 16]
      [(string.eq text "tl_alloc_global") 32]
      [(string.eq text "tl_arena_sanitize_enable") 64]
      [else 0])))

(define (compiler-backend-runtime-used-leaf-mask
  [backend-state : be_state.CompilerBackendState]
  [runtime-index : (& runtime-index be_state.CompilerBackendRuntimeIndex)]
  [referenced : (& referenced be_state.BackendSymbolSeq)]
  [externs : compiler_ir_types.CompilerIrExternSeq]) : i64
  (let
    [mask : i64 0]
    [capacity : i64 (backend_i64_i64_map.capacity (& runtime-index.calls))]
    (for [i (iterator.range 0 capacity)]
      (match (backend_i64_i64_map.entry-at (& runtime-index.calls) i)
        [(EntrySome name _)
          (set!
            mask
            (bit-or mask (compiler-backend-runtime-leaf-bit backend-state name)))]
        [_ unit]))
    (for [i (iterator.range 0 referenced.len)]
      (set!
        mask
        (bit-or
          mask
          (compiler-backend-runtime-leaf-bit
            backend-state
            (array-ref referenced.slots i)))))
    (for [i
      (iterator.range
        0
        (compiler_ir_types.compiler-ir-extern-seq-count externs))]
      (match (compiler_ir_types.compiler-ir-extern-seq-borrow externs i)
        [(Extern name source _ _ _ link _ _ _ _ _)
          (let
            [bit : i64 (compiler-backend-runtime-leaf-bit backend-state link)]
            (when
              (and
                (!= bit 0)
                (= (bit-and mask bit) 0)
                (be_facts.compiler-backend-extern-symbol-referenced?
                  runtime-index
                  referenced
                  name
                  source
                  link))
              (set! mask (bit-or mask bit))))]))
    mask))

(define (compiler-backend-runtime-features-for-emission
  [target : be_state.CompilerBackendTarget]
  [plan : be_state.CompilerBackendRuntimePlan]
  [backend-state : be_state.CompilerBackendState]
  [runtime-index : (& runtime-index be_state.CompilerBackendRuntimeIndex)]
  [referenced : (& referenced be_state.BackendSymbolSeq)]
  [externs : compiler_ir_types.CompilerIrExternSeq]
  [emit-entry : bool]) : runtime_common.CompilerBackendRuntimeFeatures
  (let
    [features : runtime_common.CompilerBackendRuntimeFeatures
      (compiler-backend-runtime-features plan)]
    (when
      emit-entry
      (let
        [used : i64
          (compiler-backend-runtime-used-leaf-mask
            backend-state
            runtime-index
            referenced
            externs)]
        (if (be_state.compiler-backend-state-archive-runtime? backend-state)
          (begin
            (set! features.alloc true)
            (set! features.region-mark true)
            (set! features.region-reset true)
            ;; Only an explicit reference enables the test-only quarantine.
            (set! features.leaf-mask (bit-or 63 (bit-and used 64))))
          (set!
            features.leaf-mask
            (match target
              [(be_state.CompilerBackendTarget.Linux) used]
              [(be_state.CompilerBackendTarget.Windows)
                (bit-or features.leaf-mask (bit-and used 96))])))))
    features))

(define (compiler-backend-runtime-data-for-target
  [target : be_state.CompilerBackendTarget]
  [features : runtime_common.CompilerBackendRuntimeFeatures]
  [freestanding : bool]) : String
  (match target
    [(be_state.CompilerBackendTarget.Linux)
      (runtime_linux.compiler-backend-runtime-data features freestanding)]
    [(be_state.CompilerBackendTarget.Windows)
      (runtime_windows.compiler-backend-runtime-data features freestanding)]))

(define (compiler-backend-runtime-fast-alloc-entry? [line : (& str)]) : bool
  (let
    [length : i64 (string.string-length line)]
    (and
      (or (= length 14) (= length 15))
      (string.is-string-prefix-at line ".L_tl_alloc" 0)
      (>= (string.string-ref line (- length 3)) '0')
      (<= (string.string-ref line (- length 3)) '9')
      (= (string.string-ref line (- length 2)) ':'))))

(define (compiler-backend-runtime-sectioned-functions
  [target : be_state.CompilerBackendTarget]
  [body : (& str)]) : String
  (let
    [buf : text_buf.TextBuf (text_buf.empty)]
    [limit : i64 (string.string-length body)]
    [start : i64 0]
    [in-text? : bool true]
    (while (< start limit)
      (let
        [end : i64 (string.index-of-byte body start 10)]
        [next : i64
          (if (< end 0)
            limit
            (+ end 1))]
        [line : String (string.substring body start (- next start))]
        (cond
          [(compiler-backend-runtime-fast-alloc-entry? (& line))
            ;; The archive can reference this size class. Keep the local
            ;; label for calls from within the executable.
            (let
              [symbol : String
                (string.substring (& line) 3 (- (- next start) 5))]
              (set!
                buf
                (text_buf.append
                  buf
                  (str_cat.str-cat
                    (be_operand.compiler-backend-function-section
                      target
                      (& symbol))
                    ".globl "
                    symbol
                    "\n"
                    symbol
                    ":\n"))))]
          [(string.is-string-prefix-at (& line) ".L_tl_alloc_win_commit_to:" 0)
            ;; The commit helper has callers outside the last size class.
            (text_buf.append!
              buf
              (be_operand.compiler-backend-function-section
                target
                ".L_tl_alloc_win_commit_to"))]
          [(string.is-string-prefix-at (& line) "    .text" 0)
            (set! in-text? true)]
          [(or
              (string.is-string-prefix-at (& line) "    .data" 0)
              (string.is-string-prefix-at (& line) "    .bss" 0)
              (string.is-string-prefix-at (& line) "    .section ." 0))
            (set! in-text? false)]
          [(and
              in-text?
              (>= end 0)
              (string.is-string-prefix-at (& line) "    .globl " 0))
            (set!
              buf
              (text_buf.append
                buf
                (be_operand.compiler-backend-function-section
                  target
                  (& (string.substring (& line) 11 (- end (+ start 11)))))))]
          [else unit])
        (set! buf (text_buf.append buf line))
        (set! start next)))
    (text_buf.render (text_buf.append buf ".text\n"))))

(define (compiler-backend-runtime-functions-for-target
  [target : be_state.CompilerBackendTarget]
  [features : runtime_common.CompilerBackendRuntimeFeatures]
  [closed : bool]
  [archives : bool]
  [freestanding : bool]) : String
  (let
    [body : String
      (match target
        [(be_state.CompilerBackendTarget.Linux)
          (runtime_linux.compiler-backend-runtime-functions-for-executable
            features
            closed)]
        [(be_state.CompilerBackendTarget.Windows)
          (runtime_windows.compiler-backend-runtime-functions-for-executable
            features
            closed
            freestanding)])]
    (if archives
      (compiler-backend-runtime-sectioned-functions target (& body))
      body)))

(define (compiler-backend-runtime-externs-for-target
  [target : be_state.CompilerBackendTarget]
  [features : runtime_common.CompilerBackendRuntimeFeatures]) : String
  (match target
    [(be_state.CompilerBackendTarget.Linux)
      (runtime_linux.compiler-backend-runtime-externs features)]
    [(be_state.CompilerBackendTarget.Windows)
      (runtime_windows.compiler-backend-runtime-externs features)]))

;; Linux inline entry text selects backend `_tl_start` or CRT `main`.
;; Windows declares user `main` here; its selected runtime bundle supplies
;; the freestanding `_tl_start` image entry.
(define (compiler-backend-target-entry-text-with-crt
  [target : be_state.CompilerBackendTarget]
  [emit-entry : bool]
  [crt-entry : bool]) : String
  (if emit-entry
    (match target
      [(be_state.CompilerBackendTarget.Linux)
        (if crt-entry
          ".text\n.globl main\n"
          ".text\n.globl _tl_start\n")]
      [(be_state.CompilerBackendTarget.Windows) ".text\n.globl main\n"])
    ".text\n"))

;; `_tl_start` is the freestanding Linux entry and the only function this
;; module emits outside compiler-backend-emit-function, so it carries the same
;; ELF symbol typing (see compiler-backend-emit-function-type-directive). This
;; text is emitted only from the Linux arm of
;; compiler-backend-entry-for-target-with-crt, so neither needs a target test.
;; The label line itself is untouched: scripts detect the freestanding entry by
;; grepping for `^_tl_start:$`.
;;
;; The size closes the entry at the exit syscall rather than after the
;; mmap-failure stub, because that stub re-enters `.text` by name. In a debug
;; build the entry itself sits in `.text.typelisp_runtime` (the debug trailer
;; parks the runtime there), and `. - _tl_start` spanning two sections is not
;; an assemble-time constant.
(define compiler-backend-entry-type-directive : String
  "    .type _tl_start,@function\n")
(define compiler-backend-entry-size-directive : String
  "    .size _tl_start, . - _tl_start\n")

;; Run main on a fresh 1 GiB mmap'd stack, then exit(main()). The compiler
;; recurses far deeper than the default 8 MiB stack rlimit allows -- type-directed
;; `clone` of large IR values during arena escapes is the worst case -- so
;; a self-hosted compiler segfaults compiling a large program on the default
;; stack. argc/argv/envp are already captured into globals before this runs, so
;; switching %rsp is safe (main reads them from globals, not the stack). Do not
;; silently continue on the original small stack when mmap fails: report the
;; failed reservation and exit 134 so a runner constraint cannot masquerade as
;; an unrelated compiler SIGSEGV.
;; --- Shared-object code model (#8257) ---------------------------------------
;; A Linux shared object needs object code with no text relocation, no
;; local-exec TLS and no exported internal symbol. The emission keeps the
;; executable code everywhere else, so the model is applied by one pass over
;; the finished assembly (`compiler-backend-shared-object-assembly`) plus
;; one emission change the pass cannot make: `tl_shared_object_init` takes
;; the place of the executable entry point.
;; The register a TLS store borrows under the shared-object code model, by
;; enclosing function, or "" for none. An initial-exec store reaches the
;; variable through its GOT offset, which must be loaded into a register first.
;; Each runtime helper that stores TLS names a register dead at its stores.
;; Generated code stores TLS only through the current-arena store builtin,
;; which is lowered at a call site, where %rax is call-clobbered.
(define (compiler-backend-shared-object-tls-scratch
  [function : (& function str)]) : String
  (cond
    [(or
        (string.eq function "tl_alloc")
        (string.eq function "tl_alloc_aligned")
        (string.eq function "tl_arena_set")
        (string.eq function "tl_backtrace_stack_set"))
      "%rax"]
    [(string.eq function "tl_alloc_global") "%r11"]
    [(string.eq function "tl_region_reset") "%rbx"]
    [(string.eq function "tl_thread_init") "%rdi"]
    [(string.is-string-prefix-at function "tl_" 0) ""]
    [else "%rax"]))

(defenum CompilerBackendSharedObjectLine
  (Ok String)
  (Err String))

;; The symbol between PREFIX and `@tpoff` in OPERAND, or "".
(define (compiler-backend-shared-object-tls-symbol
  [operand : (& operand str)]
  [prefix : (& prefix str)]) : String
  (let
    [length : i64 (string.string-length operand)]
    [prefix-length : i64 (string.string-length prefix)]
    (if (and
      (string.is-string-prefix-at operand prefix 0)
      (> length (+ prefix-length 6))
      (string.is-string-prefix-at operand "@tpoff" (- length 6)))
      (string.substring operand prefix-length (- length (+ prefix-length 6)))
      "")))

;; One instruction line holding `@tpoff`, rewritten from local-exec to
;; initial-exec: a load reads the GOT offset into its own destination, an
;; offset immediate becomes the GOT word, and a store borrows SCRATCH.
(define (compiler-backend-shared-object-tls-line
  [line : (& line str)]
  [function : (& function str)]) : CompilerBackendSharedObjectLine
  (let
    [text : String (string.trim line)]
    [space : i64 (string.index-of-byte (& text) 0 (cast 32 : u8))]
    [comma : i64 (string.index-of-byte (& text) 0 (cast 44 : u8))]
    [unsupported : String
      (str_cat.str-cat
        "backend: no shared-object form for TLS access `"
        text
        "` in "
        function)]
    (if (or (< space 0) (< comma space))
      (Err unsupported)
      (let
        [mnemonic : String (string.substring (& text) 0 space)]
        [source : String
          (string.trim
            (& (string.substring (& text) (+ space 1) (- comma (+ space 1)))))]
        [dest : String
          (string.trim
            (&
              (string.substring
                (& text)
                (+ comma 1)
                (- (string.string-length (& text)) (+ comma 1)))))]
        [load-symbol : String
          (compiler-backend-shared-object-tls-symbol (& source) "%fs:")]
        [store-symbol : String
          (compiler-backend-shared-object-tls-symbol (& dest) "%fs:")]
        [offset-symbol : String
          (compiler-backend-shared-object-tls-symbol (& source) "$")]
        (cond
          [(and
              (string.eq mnemonic "movq")
              (> (string.string-length (& load-symbol)) 0)
              (string.is-string-prefix-at dest "%" 0))
            (Ok
              (str_cat.str-cat
                "    movq "
                load-symbol
                "@gottpoff(%rip), "
                dest
                "\n    movq %fs:("
                dest
                "), "
                dest))]
          [(and
              (string.eq mnemonic "movq")
              (> (string.string-length (& store-symbol)) 0))
            (let
              [scratch : String
                (compiler-backend-shared-object-tls-scratch function)]
              (if (or
                (= (string.string-length (& scratch)) 0)
                (string.eq scratch source))
                (Err
                  (str_cat.str-cat
                    "backend: no shared-object scratch register for TLS store `"
                    text
                    "` in "
                    function))
                (Ok
                  (str_cat.str-cat
                    "    movq "
                    store-symbol
                    "@gottpoff(%rip), "
                    scratch
                    "\n    movq "
                    source
                    ", %fs:("
                    scratch
                    ")"))))]
          [(and
              (or (string.eq mnemonic "movq") (string.eq mnemonic "addq"))
              (> (string.string-length (& offset-symbol)) 0)
              (string.is-string-prefix-at dest "%" 0))
            (Ok
              (str_cat.str-cat
                "    "
                mnemonic
                " "
                offset-symbol
                "@gottpoff(%rip), "
                dest))]
          ;; `@gottpoff` takes only mov and add, so a subtracted offset is added
          ;; to the negated register. The value matches; the flags do not, and
          ;; the one such site, in tl_thread_init, never reads them.
          [(and
              (string.eq mnemonic "subq")
              (> (string.string-length (& offset-symbol)) 0)
              (string.is-string-prefix-at dest "%" 0))
            (Ok
              (str_cat.str-cat
                "    negq "
                dest
                "\n    addq "
                offset-symbol
                "@gottpoff(%rip), "
                dest
                "\n    negq "
                dest))]
          [else (Err unsupported)])))))

;; The first offset in [START, END) of TEXT that is not a space or tab.
(define (compiler-backend-shared-object-skip-blank
  [text : (& text str)]
  [start : i64]
  [end : i64]) : i64
  (let
    [index : i64 start]
    (while (and
      (< index end)
      (or
        (= (string.char-at text index) ' ')
        (= (string.char-at text index) '\t')))
      (+= index 1))
    index))

;; Whether the line [START, END) of TEXT, from its first non-blank byte, is a
;; `.quad` whose operand is not an integer: an address the loader relocates.
(define (compiler-backend-shared-object-relocated-word?
  [text : (& text str)]
  [start : i64]
  [end : i64]) : bool
  (if (string.is-string-prefix-at text ".quad " start)
    (let
      [index : i64
        (compiler-backend-shared-object-skip-blank text (+ start 6) end)]
      [numeric : bool (< index end)]
      (when
        (and (< index end) (= (string.char-at text index) '-'))
        (+= index 1))
      (when (string.is-string-prefix-at text "0x" index) (+= index 2))
      (set! numeric (< index end))
      (while (and numeric (< index end))
        (let
          [c : char (string.char-at text index)]
          (unless
            (or
              (and (>= c '0') (<= c '9'))
              (and (>= c 'a') (<= c 'f'))
              (and (>= c 'A') (<= c 'F'))
              (= c ' ')
              (= c '\t'))
            (set! numeric false)))
        (+= index 1))
      (not numeric))
    false))

;; What the line of TEXT whose first non-blank byte is at START does to the
;; current section: 0 nothing, 1 select a writable or code section, 2 select a
;; read-only data section, 3 push a section, 4 pop one. A push of a read-only
;; section is 5. Every prefix tested holds no newline, so no match crosses the
;; line's end.
;; Where the section name of the `.section`/`.pushsection` directive whose
;; first byte is at START of TEXT begins, past an opening quote (a sectioned
;; object quotes each `.rodata.<label>`), or -1 for any other line.
(define (compiler-backend-shared-object-section-name-start
  [text : (& text str)]
  [start : i64]) : i64
  (let
    [name-start : i64
      (cond
        [(string.is-string-prefix-at text ".pushsection " start) (+ start 13)]
        [(string.is-string-prefix-at text ".section " start) (+ start 9)]
        [else -1])]
    (if (and
      (>= name-start 0)
      (string.is-string-prefix-at text "\"" name-start))
      (+ name-start 1)
      name-start)))

(define (compiler-backend-shared-object-section-kind
  [text : (& text str)]
  [start : i64]) : i64
  (let
    [push : bool (string.is-string-prefix-at text ".pushsection " start)]
    [name-start : i64
      (compiler-backend-shared-object-section-name-start text start)]
    (cond
      [(>= name-start 0)
        (let
          [read-only : bool
            (or
              (string.is-string-prefix-at text ".rodata" name-start)
              (string.is-string-prefix-at
                text
                ".typelisp_backtrace,"
                name-start))]
          (cond [(and push read-only) 5] [push 3] [read-only 2] [else 1]))]
      [(string.is-string-prefix-at text ".popsection" start) 4]
      [(or
          (string.is-string-prefix-at text ".text" start)
          (string.is-string-prefix-at text ".data" start)
          (string.is-string-prefix-at text ".bss" start))
        1]
      [else 0])))

;; Whether the section directive whose first byte is at START of TEXT selects
;; code: a `.text` directive, or a `.section`/`.pushsection` of a `.text*`
;; section such as the runtime's `.text.typelisp_runtime`.
(define (compiler-backend-shared-object-text-section?
  [text : (& text str)]
  [start : i64]) : bool
  (or
    (string.is-string-prefix-at text ".text" start)
    (string.is-string-prefix-at text ".section .text" start)
    (string.is-string-prefix-at text ".pushsection .text" start)))

;; The directive that replaces a moved read-only section directive whose first
;; byte is at START of TEXT: the same kind (a push stays a push, so its
;; `.popsection` still matches), now writable for the loader's relocations.
(define (compiler-backend-shared-object-moved-section
  [text : (& text str)]
  [start : i64]) : String
  (let
    [push : bool (string.is-string-prefix-at text ".pushsection " start)]
    [name-start : i64
      (compiler-backend-shared-object-section-name-start text start)]
    (str_cat.str-cat
      (if push
        "    .pushsection "
        "    .section ")
      (if (string.is-string-prefix-at text ".typelisp_backtrace" name-start)
        ".typelisp_backtrace"
        ".data.rel.ro")
      ",\"aw\",@progbits")))

;; Whether the line [START, END) of TEXT mentions a local-exec TLS offset.
(define (compiler-backend-shared-object-tls-line?
  [text : (& text str)]
  [start : i64]
  [end : i64]) : bool
  (let
    [at : i64 (string.index-of-byte text start (cast 64 : u8))]
    [found : bool false]
    (while (and (not found) (>= at 0) (< at end))
      (if (string.is-string-prefix-at text "@tpoff" at)
        (set! found true)
        (set! at (string.index-of-byte text (+ at 1) (cast 64 : u8)))))
    found))

;; The extern symbol TEXT reads rip-relatively on the line [START, END) when
;; it names one in EXTERNS, else "".
(define (compiler-backend-shared-object-extern-reference
  [text : (& text str)]
  [start : i64]
  [end : i64]
  [externs : (& externs backend_string_i64_map.Map)]) : String
  (let
    [open : i64 (string.index-of-byte text start (cast 40 : u8))]
    [found : String ""]
    (while (and (>= open 0) (< open end) (= (string.string-length (& found)) 0))
      (when
        (string.is-string-prefix-at text "(%rip)" open)
        (let
          [first : i64 open]
          [scanning : bool true]
          (while (and scanning (> first start))
            (let
              [c : char (string.char-at text (- first 1))]
              (if (or
                (and (>= c 'a') (<= c 'z'))
                (and (>= c 'A') (<= c 'Z'))
                (and (>= c '0') (<= c '9'))
                (= c '_')
                (= c '.'))
                (-= first 1)
                (set! scanning false))))
          (when
            (< first open)
            (let
              [symbol : String (string.substring text first (- open first))]
              (when
                (backend_string_i64_map.contains?
                  externs
                  (string.copy (& symbol)))
                (set! found symbol))))))
      (set! open (string.index-of-byte text (+ open 1) (cast 40 : u8))))
    found))

;; One instruction line reading extern SYMBOL rip-relatively, rewritten to
;; reach it through the GOT: the symbol may be defined in another object of
;; the process, so its address is the GOT word, not a link-time constant.
(define (compiler-backend-shared-object-extern-line
  [line : (& line str)]
  [symbol : (& symbol str)]
  [function : (& function str)]) : CompilerBackendSharedObjectLine
  (let
    [text : String (string.trim line)]
    [space : i64 (string.index-of-byte (& text) 0 (cast 32 : u8))]
    [comma : i64 (string.index-of-byte (& text) 0 (cast 44 : u8))]
    [unsupported : String
      (str_cat.str-cat
        "backend: no shared-object form for extern access `"
        text
        "` in "
        function)]
    (if (or (< space 0) (< comma space))
      (Err unsupported)
      (let
        [mnemonic : String (string.substring (& text) 0 space)]
        [source : String
          (string.trim
            (& (string.substring (& text) (+ space 1) (- comma (+ space 1)))))]
        [dest : String
          (string.trim
            (&
              (string.substring
                (& text)
                (+ comma 1)
                (- (string.string-length (& text)) (+ comma 1)))))]
        [rip-symbol : String (str_cat.str-cat symbol "(%rip)")]
        (cond
          [(not
              (and
                (string.eq source rip-symbol)
                (string.is-string-prefix-at dest "%" 0)))
            (Err unsupported)]
          [(string.eq mnemonic "leaq")
            (Ok (str_cat.str-cat "    movq " symbol "@GOTPCREL(%rip), " dest))]
          [(string.eq mnemonic "movq")
            (Ok
              (str_cat.str-cat
                "    movq "
                symbol
                "@GOTPCREL(%rip), "
                dest
                "\n    movq ("
                dest
                "), "
                dest))]
          [else (Err unsupported)])))))

;; TEXT, a whole executable-model assembly, under the shared-object code
;; model:
;; - every `.globl` symbol is also `.hidden`, so the object exports nothing
;;   until #8194's export policy names a symbol;
;; - every local-exec TLS access becomes initial-exec
;;   (`compiler-backend-shared-object-tls-line`), so the object links into a
;;   DSO marked static-TLS;
;; - a rip-relative read of an `.extern` symbol goes through the GOT, since
;;   the symbol may live in another object of the process;
;; - a read-only data run holding a relocated word moves to `.data.rel.ro`, which
;;   the loader writes once before RELRO seals it.
;; A relocated word left in `.text` would be a text relocation; that is an
;; error here rather than a link failure later. Lines are scanned in place and
;; unchanged runs are copied whole, so the pass allocates per edit, not per
;; line.
(define (compiler-backend-shared-object-assembly [text : String]) : be_state.ResultCompilerBackendBuffer
  (let
    [length : i64 (string.string-length (& text))]
    [moved : (__tl_dyn-array i64) (__tl_make-array i64 0)]
    [moved-count : i64 0]
    [chunk-start : i64 -1]
    [chunk-relocated : bool false]
    [pushed-text : (__tl_dyn-array bool) (__tl_make-array bool 0)]
    [depth : i64 0]
    [in-text : bool true]
    [externs : backend_string_i64_map.Map
      (backend_string_i64_map.with-capacity 16)]
    [error : String ""]
    [start : i64 0]
    ;; Pass 1: record the directive of each read-only run that holds a
    ;; relocated word, and refuse a relocated word in `.text`.
    (while (and (< start length) (= (string.string-length (& error)) 0))
      (let
        [newline : i64 (string.index-of-byte (& text) start (cast 10 : u8))]
        [end : i64
          (if (< newline 0)
            length
            newline)]
        [first : i64
          (compiler-backend-shared-object-skip-blank (& text) start end)]
        [kind : i64
          (compiler-backend-shared-object-section-kind (& text) first)]
        (when
          (string.is-string-prefix-at (& text) ".extern " first)
          (backend_string_i64_map.insert-ref!
            (&mut externs)
            (string.trim
              (& (string.substring (& text) (+ first 8) (- end (+ first 8)))))
            1))
        (cond
          [(> kind 0)
            (when
              (and (>= chunk-start 0) chunk-relocated)
              (__tl_array-push! moved chunk-start)
              (+= moved-count 1))
            (set! chunk-start -1)
            (set! chunk-relocated false)
            (cond
              [(= kind 4)
                (if (> depth 0)
                  (begin
                    (-= depth 1)
                    (set! in-text (array-ref pushed-text depth)))
                  (set! in-text true))]
              [else
                (when
                  (or (= kind 3) (= kind 5))
                  (if (< depth (array-length pushed-text))
                    (set! (array-ref pushed-text depth) in-text)
                    (__tl_array-push! pushed-text in-text))
                  (+= depth 1))
                (set!
                  in-text
                  (compiler-backend-shared-object-text-section? (& text) first))
                (when (or (= kind 2) (= kind 5)) (set! chunk-start start))])]
          [(compiler-backend-shared-object-relocated-word? (& text) first end)
            (cond
              [(>= chunk-start 0) (set! chunk-relocated true)]
              [in-text
                (set!
                  error
                  (str_cat.str-cat
                    "backend: shared-object code model leaves a relocated word in .text: "
                    (string.substring (& text) first (- end first))))]
              [else unit])]
          [else unit])
        (set! start (+ end 1))))
    (when
      (and (>= chunk-start 0) chunk-relocated)
      (__tl_array-push! moved chunk-start)
      (+= moved-count 1))
    (if (> (string.string-length (& error)) 0)
      (Err (box (compiler_diagnostic.compiler-diagnostic-at-start "" error)))
      ;; Pass 2: copy unchanged runs and rewrite the marked lines.
      (let
        [out : text_buf.TextBuf (text_buf.empty)]
        [copied : i64 0]
        [next-moved : i64 0]
        [function : String ""]
        (set! start 0)
        (while (and (< start length) (= (string.string-length (& error)) 0))
          (let
            [newline : i64 (string.index-of-byte (& text) start (cast 10 : u8))]
            [end : i64
              (if (< newline 0)
                length
                newline)]
            [first : i64
              (compiler-backend-shared-object-skip-blank (& text) start end)]
            ;; The extern an instruction reads rip-relatively, or "".
            [extern-symbol : String
              (if (and
                (< first end)
                (not (= (string.char-at (& text) first) '.')))
                (compiler-backend-shared-object-extern-reference
                  (& text)
                  first
                  end
                  (& externs))
                "")]
            (cond
              [(and
                (< next-moved moved-count)
                (= (array-ref moved next-moved) start))
                (+= next-moved 1)
                (set!
                  out
                  (text_buf.append
                    (text_buf.append
                      out
                      (string.substring (& text) copied (- start copied)))
                    (compiler-backend-shared-object-moved-section
                      (& text)
                      first)))
                (set! copied end)]
              [(string.is-string-prefix-at (& text) ".globl " first)
                (set!
                  out
                  (text_buf.append
                    (text_buf.append
                      (text_buf.append
                        out
                        (string.substring (& text) copied (- end copied)))
                      "\n    .hidden ")
                    (string.substring
                      (& text)
                      (compiler-backend-shared-object-skip-blank
                        (& text)
                        (+ first 7)
                        end)
                      (-
                        end
                        (compiler-backend-shared-object-skip-blank
                          (& text)
                          (+ first 7)
                          end)))))
                (set! copied end)]
              [(and
                  (= first start)
                  (> end (+ start 1))
                  (not (= (string.char-at (& text) start) '.'))
                  (= (string.char-at (& text) (- end 1)) ':'))
                (set!
                  function
                  (string.substring (& text) start (- (- end start) 1)))]
              ;; Only an instruction is rewritten; a `.string` or `.ascii`
              ;; directive may spell `@tpoff` as data.
              [(and
                  (< first end)
                  (not (= (string.char-at (& text) first) '.'))
                  (compiler-backend-shared-object-tls-line? (& text) first end))
                (match (compiler-backend-shared-object-tls-line
                  (& (string.substring (& text) start (- end start)))
                  (& function))
                  [(Ok rewritten)
                    (set!
                      out
                      (text_buf.append
                        (text_buf.append
                          out
                          (string.substring (& text) copied (- start copied)))
                        rewritten))
                    (set! copied end)]
                  [(Err message) (set! error message)])]
              [(> (string.string-length (& extern-symbol)) 0)
                (match (compiler-backend-shared-object-extern-line
                  (& (string.substring (& text) start (- end start)))
                  (& extern-symbol)
                  (& function))
                  [(Ok rewritten)
                    (set!
                      out
                      (text_buf.append
                        (text_buf.append
                          out
                          (string.substring (& text) copied (- start copied)))
                        rewritten))
                    (set! copied end)]
                  [(Err message) (set! error message)])]
              [else unit])
            (set! start (+ end 1))))
        (if (> (string.string-length (& error)) 0)
          (Err
            (box (compiler_diagnostic.compiler-diagnostic-at-start "" error)))
          (Ok
            (text_buf.append
              out
              (string.substring (& text) copied (- length copied)))))))))

;; RESULT, an unstreamed emission, under the shared-object code model when the
;; emission policy asks for it. A streamed emission is rewritten once its
;; stream finishes, in the final-buffer entry instead.
(define (compiler-backend-shared-object-unstreamed
  [backend-state : be_state.CompilerBackendState]
  [result : be_state.ResultCompilerBackendBuffer]) : be_state.ResultCompilerBackendBuffer
  (match result
    [(Ok buf)
      (if (and
        (be_state.compiler-backend-state-emission-target-policy backend-state).shared-object
        (not
          (be_facts.compiler-backend-assembly-stream-active?
            (be_state.compiler-backend-state-stream-state backend-state))))
        (compiler-backend-shared-object-assembly (text_buf.render buf))
        (Ok buf))]
    [(Err message) (Err message)]))

(define (compiler-backend-entry-call-main [global-inits : String]) : String
  (x64_catalog.compiler-x64-template-render-assembly
    (if (compiler_ir_types.compiler-debug-info-enabled?)
      (LinuxStartupTailBacktrace)
      (LinuxStartupTail))
    (LinuxX64)
    (str_cat.str-cat
      "    movq $0x40010000, %rsi
    xorq %rdi, %rdi
    xorq %rdx, %rdx
    movq $0x22, %r10
    movq $-1, %r8
    xorq %r9, %r9
    movq $9, %rax
    syscall
    testq %rax, %rax
    js .L_tl_main_stack_abort
    leaq 65536(%rax), %r8
    movq %r8, %rdi
    movq $0x40000000, %rsi
    movq $3, %rdx
    movq $10, %rax
    syscall
    testq %rax, %rax
    js .L_tl_main_stack_protect_abort
"
      (if (compiler_ir_types.compiler-debug-info-enabled?)
        "    movq %r8, %fs:tl_backtrace_stack_low@tpoff
"
        "")
      "    leaq 0x40000000(%r8), %rax
    andq $-16, %rax
"
      (if (compiler_ir_types.compiler-debug-info-enabled?)
        "    movq %rax, %fs:tl_backtrace_stack_high@tpoff
"
        "")
      "    movq %rax, %rsp
"
      (if (compiler_ir_types.compiler-debug-info-enabled?)
        "    xorl %ebp, %ebp
"
        "")
      global-inits
      "    call main
    movq %rax, %rdi
    movq $60, %rax
    syscall
"
      (be_state.compiler-backend-string-shared-view
        (& compiler-backend-entry-size-directive))
      "    .section .rodata
.L_tl_main_stack_mmap_error:
    .ascii \"tl: main-stack reservation failed\\n\"
    .text
.L_tl_main_stack_abort:
    movq $1, %rax
    movq $2, %rdi
    leaq .L_tl_main_stack_mmap_error(%rip), %rsi
    movq $34, %rdx
    syscall
    movq $231, %rax
    movq $134, %rdi
    syscall
.L_tl_main_stack_protect_abort:
    leaq -65536(%r8), %rdi
    movq $0x40010000, %rsi
    movq $11, %rax
    syscall
    jmp .L_tl_main_stack_abort
")))

(define (compiler-backend-entry
  [capture-argv : bool]
  [capture-env : bool]
  [startup-profile : bool]
  [init-null-arena : bool]
  [global-inits : String]) : String
  (let
    [null-arena-init-asm : String
      (if init-null-arena
        "    movb $17, .L_tl_null_arena+48(%rip)\n"
        "")]
    [startup-profile-asm : String
      (if startup-profile
        "    movq $228, %rax
    movq $1, %rdi
    leaq .L_tl_startup_profile_timespec(%rip), %rsi
    syscall
    testq %rax, %rax
    js .L_tl_startup_profile_process_entry_done
    movq .L_tl_startup_profile_timespec(%rip), %rax
    imulq $1000000000, %rax
    addq .L_tl_startup_profile_timespec+8(%rip), %rax
    movq %rax, .L_tl_startup_profile_process_entry_tick(%rip)
.L_tl_startup_profile_process_entry_done:
"
        "")]
    (if (or capture-argv capture-env)
      (str_cat.str-cat
        (x64_catalog.compiler-x64-template-render-assembly
          (if startup-profile
            (LinuxStartupPrefixStartupProfile)
            (LinuxStartupPrefix))
          (LinuxX64)
          (str_cat.str-cat
            (be_state.compiler-backend-string-shared-view
              (& compiler-backend-entry-type-directive))
            "_tl_start:\n"
            null-arena-init-asm
            startup-profile-asm
            "    movq (%rsp), %rax\n"
            (if capture-argv
              "    movq %rax, .L_tl_argc(%rip)\n"
              "")
            (if capture-env
              "    leaq 16(%rsp,%rax,8), %rax
    movq %rax, .L_tl_envp(%rip)
"
              "")
            (if capture-argv
              "    leaq 8(%rsp), %rax
    movq %rax, .L_tl_argv(%rip)
"
              "")
            "    call tl_thread_init\n"))
        (compiler-backend-entry-call-main global-inits))
      (str_cat.str-cat
        (x64_catalog.compiler-x64-template-render-assembly
          (if startup-profile
            (LinuxStartupPrefixStartupProfile)
            (LinuxStartupPrefix))
          (LinuxX64)
          (str_cat.str-cat
            (be_state.compiler-backend-string-shared-view
              (& compiler-backend-entry-type-directive))
            "_tl_start:\n"
            null-arena-init-asm
            startup-profile-asm
            "    call tl_thread_init\n"))
        (compiler-backend-entry-call-main global-inits)))))

(define (compiler-backend-entry-for-target-with-crt
  [type-segment-bases : i64]
  [target : be_state.CompilerBackendTarget]
  [plan : be_state.CompilerBackendRuntimePlan]
  [globals : compiler_ir_types.CompilerIrGlobalSeq]
  [crt-entry : bool]
  [program-index : be_state.CompilerBackendProgramIndex]) : String
  (match target
    [(be_state.CompilerBackendTarget.Linux)
      (if crt-entry
        ""
        (compiler-backend-entry
          true
          true
          (be_state.compiler-backend-runtime-tail-startup-profile?
            (be_state.compiler-backend-runtime-plan-tail plan))
          (not
            (be_state.compiler-backend-runtime-tail-arena-debug?
              (be_state.compiler-backend-runtime-plan-tail plan)))
          (compiler-backend-global-initializers
            type-segment-bases
            target
            globals
            program-index)))]
    [(be_state.CompilerBackendTarget.Windows) ""]))

(define (compiler-backend-emit-program-prefix-buffer
  [target : be_state.CompilerBackendTarget]
  [functions : compiler_ir_types.CompilerIrFunctionSeq]
  [externs : compiler_ir_types.CompilerIrExternSeq]
  [plan : be_state.CompilerBackendRuntimePlan]
  [runtime-features : runtime_common.CompilerBackendRuntimeFeatures]
  [program-index : be_state.CompilerBackendProgramIndex]
  [runtime-index : be_state.CompilerBackendRuntimeIndex]
  [closure-names : be_state.BackendSymbolSeq]
  [referenced-symbols : be_state.BackendSymbolSeq]
  [strings : be_state.BackendStringSeq]
  [bytes : be_state.BackendStringSeq]
  [floats : be_state.BackendFloatSeq]
  [uses-avx2-i64-lane-id : bool]
  [uses-avx512-i64-lane-id : bool]
  [uses-f64-neg : bool]
  [uses-f32-neg : bool]
  [globals-buf : text_buf.TextBuf]
  [emit-entry : bool]
  [crt-entry : bool]) : text_buf.TextBuf
  (let
    [string-buf : text_buf.TextBuf
      (compiler-backend-emit-string-rodata-into
        strings
        (and
          (be_state.compiler-backend-state-library-object?
            program-index.backend-state)
          (be_state.compiler-backend-target-elf? target))
        globals-buf)]
    (begin
      (cfg
        compile-profile
        (be_state.compiler-backend-profile-finish
          program-index.profile-state
          "compose.string_rodata"))
      (cfg
        compile-profile
        (be_state.compiler-backend-profile-start program-index.profile-state))
      (let
        [bytes-buf : text_buf.TextBuf
          (compiler-backend-emit-bytes-data-into bytes string-buf)]
        (begin
          (cfg
            compile-profile
            (be_state.compiler-backend-profile-finish
              program-index.profile-state
              "compose.bytes_data"))
          (cfg
            compile-profile
            (be_state.compiler-backend-profile-start
              program-index.profile-state))
          (let
            [float-literals-buf : text_buf.TextBuf
              (compiler-backend-emit-float-rodata-into floats bytes-buf)]
            [f64-buf : text_buf.TextBuf
              (compiler-backend-emit-float-sign-bit-rodata-into
                uses-f64-neg
                float-literals-buf
                true)]
            [f32-buf : text_buf.TextBuf
              (compiler-backend-emit-float-sign-bit-rodata-into
                uses-f32-neg
                f64-buf
                false)]
            [lane-id-buf : text_buf.TextBuf
              (be_facts.compiler-backend-emit-lane-id-rodata-into
                uses-avx2-i64-lane-id
                uses-avx512-i64-lane-id
                f32-buf)]
            (begin
              (cfg
                compile-profile
                (be_state.compiler-backend-profile-finish
                  program-index.profile-state
                  "compose.float_rodata"))
              (cfg
                compile-profile
                (be_state.compiler-backend-profile-start
                  program-index.profile-state))
              (let
                [descriptor-buf : text_buf.TextBuf
                  (be_facts.compiler-backend-emit-closure-descriptors-into
                    closure-names
                    (be_state.compiler-backend-global-shared-view functions)
                    (be_state.compiler-backend-global-shared-view externs)
                    program-index
                    lane-id-buf)]
                (begin
                  (cfg
                    compile-profile
                    (be_state.compiler-backend-profile-finish
                      program-index.profile-state
                      "compose.closure_descriptors"))
                  (cfg
                    compile-profile
                    (be_state.compiler-backend-profile-start
                      program-index.profile-state))
                  (let
                    [switch-buf : text_buf.TextBuf
                      (be_facts.compiler-backend-emit-switch-tables-functions-into
                        target
                        functions
                        program-index
                        (be_state.compiler-backend-state-absolute-switch-ok?
                          program-index.backend-state)
                        descriptor-buf)]
                    [runtime-data-buf : text_buf.TextBuf
                      (text_buf.append
                        switch-buf
                        (if emit-entry
                          (compiler-backend-runtime-data-for-target
                            target
                            runtime-features
                            (not
                              (or
                                crt-entry
                                (be_state.compiler-backend-state-emission-target-policy
                                  program-index.backend-state).shared-object)))
                          ""))]
                    (begin
                      (cfg
                        compile-profile
                        (be_state.compiler-backend-profile-finish
                          program-index.profile-state
                          "compose.runtime_data"))
                      (cfg
                        compile-profile
                        (be_state.compiler-backend-profile-start
                          program-index.profile-state))
                      (let
                        [externs-buf : text_buf.TextBuf
                          (compiler-backend-emit-externs-into
                            program-index.backend-state
                            externs
                            plan
                            runtime-index
                            referenced-symbols
                            runtime-data-buf)]
                        (begin
                          (cfg
                            compile-profile
                            (be_state.compiler-backend-profile-finish
                              program-index.profile-state
                              "compose.externs"))
                          (cfg
                            compile-profile
                            (be_state.compiler-backend-profile-start
                              program-index.profile-state))
                          (let
                            [runtime-externs-buf : text_buf.TextBuf
                              (text_buf.append
                                externs-buf
                                (if emit-entry
                                  (compiler-backend-runtime-externs-for-target
                                    target
                                    runtime-features)
                                  ""))]
                            (begin
                              (cfg
                                compile-profile
                                (be_state.compiler-backend-profile-finish
                                  program-index.profile-state
                                  "compose.runtime_externs"))
                              (cfg
                                compile-profile
                                (be_state.compiler-backend-profile-start
                                  program-index.profile-state))
                              (let
                                [prefix-buf : text_buf.TextBuf
                                  (text_buf.append
                                    runtime-externs-buf
                                    (if (be_state.compiler-backend-state-emission-target-policy
                                      program-index.backend-state).shared-object
                                      ".text\n"
                                      (compiler-backend-target-entry-text-with-crt
                                        target
                                        emit-entry
                                        crt-entry)))]
                                (begin
                                  (cfg
                                    compile-profile
                                    (be_state.compiler-backend-profile-finish
                                      program-index.profile-state
                                      "compose.entry_text"))
                                  prefix-buf)))))))))))))))))

(defenum ResultCompilerBackendGlobalsAndCollections
  (Ok text_buf.TextBuf be_state.CompilerBackendProgramCollections)
  (Err (Box compiler_diagnostic.CompilerDiagnostic)))

;; The `.comm` size, the `Global` materialisation form and every fold read the
;; published IR storage, so it is published before globals are spelled.
(define (compiler-backend-emit-globals-and-collections
  [type-segment-bases : i64]
  [target : be_state.CompilerBackendTarget]
  [globals : compiler_ir_types.CompilerIrGlobalSeq]
  [functions : compiler_ir_types.CompilerIrFunctionSeq]
  [externs : (& externs compiler_ir_types.CompilerIrExternSeq)]
  [program-index : be_state.CompilerBackendProgramIndex]) : ResultCompilerBackendGlobalsAndCollections
  (let
    [_inline-aggregates : unit
      (compiler-backend-publish-global-storage!
        program-index.backend-state
        (& globals)
        externs)]
    [collections : be_state.CompilerBackendProgramCollections
      (compiler-backend-collect-program-collections
        (be_state.compiler-backend-global-shared-view globals)
        functions)]
    ;; W3(c): the walk above is the whole-program cell-writer scan. Publishing
    ;; here -- before any function is planned -- is what makes a frozen global's
    ;; read rematerialisable in the allocator.
    [_frozen-globals-known : unit
      (compiler_regalloc.compiler-reg-frozen-globals-finish!)]
    [globals-buf
      (try
        (compiler-backend-emit-globals-buffer-into
          type-segment-bases
          target
          globals
          (text_buf.append (text_buf.empty) ".data\n")
          program-index))]
    (Ok globals-buf collections)))