;; compiler_backend_program_data.tl - Program literals, globals and runtime function plans.
(import compiler_backend_operands as be_operand)
(import compiler_backend_program_facts as be_facts)
(import compiler_backend_state as be_state)
(import stdlib.iterator)
(import stdlib.io)
(import stdlib.env)
(import compiler_ir_types)
(import compiler_ast_types)
(import compiler_builtin_ids as cbi)
(import compiler_diagnostic)
(import compiler_regalloc)
(import compiler_backend_runtime_common as runtime_common)
(import compiler_backend_runtime_linux as runtime_linux)
(import compiler_backend_runtime_windows as runtime_windows)
(import compiler_x64_executable_template_catalog as x64_catalog)
(import stdlib.text_buf)
(import compiler_object as cobj)
(import compiler_object_asm as object_asm)
(import stdlib.sort)
(import stdlib.vector)
(import compiler_intern as ci)
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
  (offset i64)
  (owner-address u64))

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
      [(Global _ _ value)
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

;; The one whole-program walk. `functions` must be the sequence the program
;; index was built from (the entry list), so a census row index is that
;; function's program-index slot; the global-initializer part runs with the
;; census "outside any function" so a constant that names a global cannot be
;; mistaken for a read by function 0.
(define (compiler-backend-collect-program-collections-with-iag
  [globals : compiler_ir_types.CompilerIrGlobalSeq]
  [functions : compiler_ir_types.CompilerIrFunctionSeq]
  [iag : be_state.CompilerBackendIagCensusCell]) : be_state.CompilerBackendProgramCollections
  (let
    [_outside : unit (be_facts.compiler-backend-iag-enter-function! iag -1)]
    [seeded : be_state.CompilerBackendProgramCollections
      (compiler-backend-collect-global-collections
        (be_state.compiler-backend-program-collections-new-with-iag iag)
        globals)]
    (compiler-backend-collect-function-collections seeded functions)))

(define (compiler-backend-collect-source-path-strings
  [backend-state : be_state.CompilerBackendState]
  [collections : be_state.CompilerBackendProgramCollections]
  [spans : compiler_ir_types.CompilerSourceSpans]) : be_state.CompilerBackendProgramCollections
  (match spans
    [(Spans _ instr-entries _ _)
      (let
        [slots : (__tl_dyn-array
          compiler_ir_types.CompilerSourceSpansInstrEntry)
          instr-entries.slots]
        [count : i64 instr-entries.len]
        [out : be_state.CompilerBackendProgramCollections collections]
        (for [index (iterator.range 0 count)]
          (let
            [span-entry : compiler_ir_types.CompilerSourceSpansInstrEntry
              (array-ref slots index)]
            [path-id : i64 span-entry.path-id]
            (when
              (> path-id 0)
              (set!
                out
                (be_state.compiler-backend-program-collections-add-string
                  out
                  (compiler_ir_types.compiler-debug-path-remap
                    (ci.intern-compat-state-str
                      (be_state.compiler-backend-state-intern backend-state)
                      path-id)))))))
        out)]))

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

;; Both consumers of literal byte labels carry explicit lengths: String
;; descriptors and located diagnostic paths. The C marshalling helpers create
;; their own terminated buffers. Raw binary data and runtime C strings are
;; emitted separately. Put a real label at each interior offset so text, ELF,
;; and COFF all relocate to it using their normal symbol-address records.
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

(define (compiler-backend-literal-prefix-key [text : (& text str)]) : i64
  (let
    [key : i64 0]
    (for [i (iterator.range 0 compiler-backend-literal-prefix-length)]
      (set! key (bit-or (shl key 8) (cast (string.string-ref text i) : i64))))
    key))

;; Index only prefixes that can remove an entire payload. A match must still
;; prove equality across the full byte range. Only a strictly longer owner
;; can take over a payload, so the placement graph is acyclic. Six bytes
;; separate common assembly and diagnostic prefixes. The prefilter costs
;; one byte lookup at each position and avoids most hash-table probes.
(define (compiler-backend-literal-place-interiors!
  [ordered : (&mut ordered literal_vec.Vec)]) : unit
  (let
    [links : (__tl_dyn-array i64) (__tl_make-array i64 ordered.len)]
    [filter : (__tl_dyn-array bool) (__tl_make-array bool 4096)]
    [prefixes : backend_i64_i64_map.Map
      (backend_i64_i64_map.with-capacity ordered.len)]
    (for [i (iterator.range 0 ordered.len)]
      (let
        [entry : CompilerBackendLiteralKey (array-ref ordered.slots i)]
        [text : String (compiler-backend-literal-text entry.slot-address)]
        (when
          (and
            (= entry.owner i)
            (>=
              (string.string-length text)
              compiler-backend-literal-prefix-length))
          (let
            [key : i64 (compiler-backend-literal-prefix-key (& text))]
            (set!
              (array-ref links i)
              (backend_i64_i64_map.get-value-or (& prefixes) key 0))
            (set! (array-ref filter (bit-and key 4095)) true)
            (backend_i64_i64_map.insert-ref! (&mut prefixes) key (+ i 1))))))
    (for [i (iterator.range 0 ordered.len)]
      (let
        [host : CompilerBackendLiteralKey (array-ref ordered.slots i)]
        [text : String (compiler-backend-literal-text host.slot-address)]
        [length : i64 (string.string-length text)]
        (when
          (and
            (= host.owner i)
            (> length compiler-backend-literal-prefix-length))
          (let
            [key : i64 (compiler-backend-literal-prefix-key (& text))]
            (for [offset
              (iterator.range
                0
                (+ 1 (- length compiler-backend-literal-prefix-length)))]
              (let
                [link : i64
                  (if (array-ref filter (bit-and key 4095))
                    (backend_i64_i64_map.get-value-or (& prefixes) key 0)
                    0)]
                (while (> link 0)
                  (let
                    [index : i64 (- link 1)]
                    [entry : CompilerBackendLiteralKey
                      (array-ref ordered.slots index)]
                    (when
                      (= entry.owner index)
                      (let
                        [candidate : String
                          (compiler-backend-literal-text entry.slot-address)]
                        [need : i64 (string.string-length candidate)]
                        (when
                          (and
                            (< need length)
                            (<= need (- length offset))
                            (string.is-string-prefix-at text candidate offset))
                          (set!
                            (array-ref ordered.slots index)
                            (CompilerBackendLiteralKey
                              entry.slot-address
                              i
                              offset
                              0)))))
                    (set! link (array-ref links index))))
                (when
                  (< (+ offset compiler-backend-literal-prefix-length) length)
                  (set!
                    key
                    (bit-or
                      (bit-and (shl key 8) 281474976710655)
                      (cast
                        (string.string-ref
                          text
                          (+ offset compiler-backend-literal-prefix-length))
                        : i64))))))))))
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
          (CompilerBackendLiteralKey
            entry.slot-address
            owner
            offset
            parent.slot-address))))))

(define (compiler-backend-literal-records
  [strings : be_state.BackendStringSeq]
  [start : i64]) : cobj.CompilerObjectDataRecordList
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
              (CompilerBackendLiteralKey entry.slot-address owner offset 0))
            (begin
              (set! owner i)
              (set! owner-address entry.slot-address)
              (set!
                (array-ref ordered.slots i)
                (CompilerBackendLiteralKey entry.slot-address i 0 0)))))))
    (compiler-backend-literal-place-interiors! (&mut ordered))
    (literal_sort.sort!
      (&mut ordered)
      compiler-backend-literal-position-before?)
    (compiler-backend-literal-build-records (& ordered))))

(define (compiler-backend-literal-build-records
  [ordered : (& ordered literal_vec.Vec)]) : cobj.CompilerObjectDataRecordList
  (let
    [records : cobj.CompilerObjectDataRecordBuilder
      (cobj.compiler-object-data-record-builder-with-capacity
        (+ 1 (* 6 ordered.len)))]
    [owner : i64 -1]
    [cursor : i64 0]
    [text : String ""]
    (for [i (iterator.range 0 ordered.len)]
      (let
        [entry : CompilerBackendLiteralKey (array-ref ordered.slots i)]
        (when
          (!= owner entry.owner)
          (when
            (>= owner 0)
            (set!
              records
              (cobj.compiler-object-data-record-builder-push
                records
                (String
                  (string.substring
                    text
                    cursor
                    (- (string.string-length text) cursor))))))
          (set! owner entry.owner)
          (set! text (compiler-backend-literal-text entry.owner-address))
          (set! cursor 0))
        (when
          (> entry.offset cursor)
          (set!
            records
            (cobj.compiler-object-data-record-builder-push
              records
              (Bytes (string.substring text cursor (- entry.offset cursor)))))
          (set! cursor entry.offset))
        (set!
          records
          (cobj.compiler-object-data-record-builder-push
            records
            (Label
              (be_facts.compiler-backend-string-data-label
                (compiler-backend-literal-text entry.slot-address)))))))
    (when
      (>= owner 0)
      (set!
        records
        (cobj.compiler-object-data-record-builder-push
          records
          (String
            (string.substring
              text
              cursor
              (- (string.string-length text) cursor))))))
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

(define (compiler-backend-emit-string-rodata-into
  [strings : be_state.BackendStringSeq]
  [buf : text_buf.TextBuf]) : text_buf.TextBuf
  (if (= strings.len 0)
    buf
    (let
      [records : cobj.CompilerObjectDataRecordList
        (compiler-backend-literal-records strings 0)]
      [out : byte_buf_core.ByteBufBuilder
        (byte_buf_core.byte-buf-builder-with-capacity 4096)]
      [i : i64 0]
      (byte_buf_core.byte-buf-builder-append-string
        (&mut out)
        "    .section .rodata\n")
      (while (< i records.len)
        (match (cobj.compiler-object-data-record-list-ref (& records) i)
          [(String text)
            (compiler-backend-emit-quoted-literal!
              (&mut out)
              "    .string \""
              text)]
          [(Bytes text)
            (compiler-backend-emit-quoted-literal!
              (&mut out)
              "    .ascii \""
              text)]
          [_
            (object_asm.compiler-object-asm-render-data-record!
              (&mut out)
              (be_state.compiler-backend-global-array-element-shared-view
                records.slots
                i))])
        (+= i 1))
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

;; ============================================================================
;; IAG-1: inline storage for runtime-initialised aggregate globals.
;;
;; A module-level global whose type is a MEMORY aggregate is stored as an
;; 8-byte cell holding a POINTER to an arena box, so every field read pays two
;; dependent loads (`movq g(%rip), %r ; movq (%r), %x`). Where the
;; classification below proves no accepted program can observe the box
;; identity, the cell IS the aggregate: `.comm g, <size>, 8`,
;; `CompilerIrValue.Global g` materialises as `leaq g(%rip)` (a link-time
;; constant address) instead of a load, a constant-offset field read folds to
;; one `movq g+k(%rip), %r`, and the startup initializer plus every `(set! g v)`
;; rebind copy <size> bytes into the cell.
;;
;; SAFETY. The only way a program can observe box identity is a borrow of `g`
;; that stays live across a rebind of `g`. Let R(g) be the set of functions
;; containing `CompilerIrInstr.Store g _ _` -- the one direct cell writer (the
;; same instruction the W3(c) frozen-global scan keys on). If R(g) is empty
;; nothing can rebind and the inline form is unconditionally equivalent.
;; Otherwise EVERY function F that mentions `Global g` or `GlobalAddr g` must
;; satisfy all three of
;;
;;   * F does not itself write the cell -- once inlining folds a setter into a
;;     reader, a materialisation of `Global g` can straddle that write, and the
;;     box form would keep reading the OLD box where the inline form reads the
;;     new bytes;
;;   * F contains no indirect call, so its callee set is enumerable at all; and
;;   * no DIRECT callee of F transitively reaches a member of R(g).
;;
;; The third obligation is discharged by a bitset dataflow over the direct call
;; graph: reach[F] carries every candidate whose cell F -- or anything F can
;; call -- writes, and a function with an indirect call reads as "every
;; candidate that is rebound anywhere".
;; ============================================================================
;; Largest inline cell the startup/rebind copy will unroll, in bytes.
(define compiler-backend-iag-max-size : i64
  64)
(define compiler-backend-iag-reason-ok : i64
  0)
(define compiler-backend-iag-reason-no-size : i64
  1)
(define compiler-backend-iag-reason-too-large : i64
  2)
(define compiler-backend-iag-reason-self-rebind : i64
  3)
(define compiler-backend-iag-reason-indirect-call : i64
  4)
(define compiler-backend-iag-reason-callee-rebind : i64
  5)

(define (compiler-backend-iag-reason-text [reason : i64]) : String
  (cond
    [(= reason compiler-backend-iag-reason-no-size)
      "no static aggregate size in its initializer"]
    [(= reason compiler-backend-iag-reason-too-large)
      "aggregate larger than the inline cell cap"]
    [(= reason compiler-backend-iag-reason-self-rebind)
      "a function that reads it also rebinds it"]
    [(= reason compiler-backend-iag-reason-indirect-call)
      "a function that reads it makes an indirect call"]
    [(= reason compiler-backend-iag-reason-callee-rebind)
      "a callee of a function that reads it can rebind it"]
    [else "included"]))

(define (compiler-backend-iag-bit?
  [words : (& words (__tl_dyn-array i64))]
  [base : i64]
  [bit : i64]) : bool
  (not
    (=
      (bit-and
        (array-ref words (+ base (be_facts.compiler-backend-iag-bit-word bit)))
        (be_facts.compiler-backend-iag-bit-mask bit))
      0)))

;; `dst[dst-base .. ] |= src[src-base .. ]`; true when a bit was added.
(define (compiler-backend-iag-bits-merge!
  [dst : (__tl_dyn-array i64)]
  [dst-base : i64]
  [src : (__tl_dyn-array i64)]
  [src-base : i64]
  [words : i64]) : bool
  (let
    [changed : bool false]
    (for [index (iterator.range 0 words)]
      (let
        [old : i64 (array-ref dst (+ dst-base index))]
        [merged : i64 (bit-or old (array-ref src (+ src-base index)))]
        (when
          (not (= merged old))
          (set! (array-ref dst (+ dst-base index)) merged)
          (set! changed true))))
    changed))

(define (compiler-backend-iag-bits-empty?
  [words : (& words (__tl_dyn-array i64))]
  [base : i64]
  [count : i64]) : bool
  (let
    [empty : bool true]
    (for [index (iterator.range 0 count)]
      (when (not (= (array-ref words (+ base index)) 0)) (set! empty false)))
    empty))

;; ---------------------------------------------------------------------------
;; Candidate discovery.
;;
;; The escape copy lowering emits for a global initializer's memory-aggregate
;; result is `%r = call tl_alloc(N) ; copy_bytes %r, %src, N ; return %r`
;; (src/compiler_lower.tl `lower-return-abi-value` ->
;; `lower-copy-inline-aggregate-to-heap`). N is the only STATIC record of the
;; aggregate's byte size that reaches the backend at all --
;; `compiler-backend-type-size` answers 8 for every nominal struct handle,
;; because the handle is a pointer -- so the size is recovered from that copy.
;; A global whose initializer does not carry it is simply not a candidate.
;; ---------------------------------------------------------------------------
;; kind 0 -> the returned var id, or -1.
;; kind 1 -> the byte size of the `copy_bytes` writing var `arg`, or 0.
(define (compiler-backend-iag-scan-instrs
  [instrs : compiler_ir_types.CompilerIrInstrSeq]
  [kind : i64]
  [arg : i64]) : i64
  (for [index (iterator.range 0 instrs.len)]
    (let
      [instr (compiler_ir_types.compiler-ir-instr-seq-ref instrs index)]
      [found : i64
        (if (= kind 0)
          (match instr
            [(Return maybe)
              (match maybe
                [(Some value)
                  (match value
                    [(Var id) id]
                    [_ -1])]
                [(No) -1])]
            [_ -1])
          (match instr
            [(CopyBytes dst _ size)
              (if (be_operand.compiler-backend-branch-uses-var? dst arg)
                size
                0)]
            [_ 0]))]
      (when
        (if (= kind 0)
          (>= found 0)
          (> found 0))
        (return found))))
  (if (= kind 0)
    -1
    0))

(define (compiler-backend-iag-scan-block-seq
  [blocks : compiler_ir_types.CompilerIrBlockSeq]
  [kind : i64]
  [arg : i64]) : i64
  (for [index
    (iterator.range 0 (compiler_ir_types.compiler-ir-block-seq-count blocks))]
    (let
      [found : i64
        (match (compiler_ir_types.compiler-ir-block-seq-ref blocks index)
          [(Block _ instrs) (compiler-backend-iag-scan-instrs instrs kind arg)])]
      (when
        (if (= kind 0)
          (>= found 0)
          (> found 0))
        (return found))))
  (if (= kind 0)
    -1
    0))

(define (compiler-backend-iag-scan-blocks
  [blocks : compiler_ir_types.CompilerIrBlockList]
  [kind : i64]
  [arg : i64]) : i64
  (match blocks
    [(Array seq) (compiler-backend-iag-scan-block-seq seq kind arg)]))

;; The inline byte size the initializer named by `init` proves, or 0.
(define (compiler-backend-iag-initializer-size
  [functions : compiler_ir_types.CompilerIrFunctionSeq]
  [program-index : be_state.CompilerBackendProgramIndex]
  [init : i64]) : i64
  (match (be_operand.compiler-backend-index-function-slot program-index init)
    [(LookupMissing) 0]
    [(LookupFound slot)
      (match (owned_view.compiler-owned-element-view functions.slots slot)
        [(Function _ _ _ _ blocks _)
          (let
            [ret-var : i64
              (compiler-backend-iag-scan-blocks
                (be_state.compiler-backend-global-shared-view blocks)
                0
                0)]
            (if (< ret-var 0)
              0
              (compiler-backend-iag-scan-blocks blocks 1 ret-var)))])]))

;; True when the global's declared type is a nominal aggregate handle. Only
;; these are reported as EXCLUDED aggregates by the trace below; a dynamic
;; array or string handle is a one-word value, never a boxed aggregate.
(define (compiler-backend-iag-nominal-aggregate-type?
  [ty : compiler_ast_types.AstType]) : bool
  (match ty
    [(or (Struct _) (StructArgs _ _) (Enum _) (EnumArgs _ _) (Tuple _)) true]
    [_ false]))

;; A global takes the 8-byte boxed pointer cell today exactly when it is
;; runtime-initialised, is not a register group, and is not a float.
(define (compiler-backend-iag-boxed-cell?
  [type-segment-bases : i64]
  [program-index : be_state.CompilerBackendProgramIndex]
  [ty : compiler_ast_types.AstType]
  [value : (& value compiler_ir_types.CompilerIrValue)]) : bool
  (and
    (match value
      [(RuntimeGlobal _) true]
      [_ false])
    (not
      (be_facts.compiler-backend-group-type?
        type-segment-bases
        program-index
        ty))
    (not (be_operand.compiler-backend-float-type? ty))
    (= (be_operand.compiler-backend-type-size type-segment-bases ty) 8)))

(define (compiler-backend-iag-candidate-size
  [type-segment-bases : i64]
  [program-index : be_state.CompilerBackendProgramIndex]
  [functions : compiler_ir_types.CompilerIrFunctionSeq]
  [ty : compiler_ast_types.AstType]
  [value : compiler_ir_types.CompilerIrValue]) : i64
  (if (compiler-backend-iag-boxed-cell?
    type-segment-bases
    program-index
    ty
    value)
    (match value
      [(RuntimeGlobal init)
        (compiler-backend-iag-initializer-size functions program-index init)]
      [_ 0])
    0))

;; The disabled census: no candidate, so every hook below leaves immediately.
(define (compiler-backend-iag-census-disabled) : be_state.CompilerBackendIagCensusCell
  (compiler-backend-iag-census-cell
    (be_state.CompilerBackendIagCensus
      0
      1
      (__tl_make-array i64 1)
      (__tl_make-array i64 1)
      (__tl_make-array i64 1)
      (backend_i64_i64_map.with-capacity 1)
      0
      (__tl_make-array i64 1)
      (__tl_make-array i64 1)
      (__tl_make-array i64 1)
      (__tl_make-array i64 1)
      (__tl_make-array bool 1)
      (__tl_make-array i64 1)
      0
      (__tl_make-array i64 1)
      (__tl_make-array i64 1)
      (__tl_make-array i64 2)
      (backend_i64_i64_map.with-capacity 1))))

(define (compiler-backend-iag-census-cell
  [census : be_state.CompilerBackendIagCensus]) : be_state.CompilerBackendIagCensusCell
  (let
    [slots : (__tl_dyn-array be_state.CompilerBackendIagCensus)
      (__tl_make-array be_state.CompilerBackendIagCensus 1)]
    (set! (array-ref slots 0) census)
    (be_state.CompilerBackendIagCensusCell slots)))

;; ---------------------------------------------------------------------------
;; Dataflow, decision and publication.
;; ---------------------------------------------------------------------------
(define (compiler-backend-iag-seed-reach!
  [census : be_state.CompilerBackendIagCensus]) : unit
  (let
    [f : i64 0]
    (while (< f census.function-count)
      (let
        [base : i64 (* f census.words)]
        [w : i64 0]
        (while (< w census.words)
          (set!
            (array-ref census.reach (+ base w))
            (bit-or
              (array-ref census.writes (+ base w))
              (if (array-ref census.indirect f)
                (array-ref census.written w)
                0)))
          (+= w 1))
        (+= f 1)))))

;; Transitive closure over the direct call edges, as a reverse-CSR worklist
;; rather than repeated sweeps of the edge list. A sweep-to-fixpoint costs
;; rounds x edges; here a function is re-examined only when its own row GREW,
;; so the total work is bounded by the number of (function, candidate) bits
;; that ever turn on times that function's in-degree.
(define (compiler-backend-iag-fixpoint!
  [census : be_state.CompilerBackendIagCensus]
  [edge-count : i64]) : unit
  (let
    [functions : i64 census.function-count]
    ;; Reverse adjacency in CSR form: `starts[f] .. starts[f+1]` indexes the
    ;; CALLERS of `f` in `callers`.
    [starts : (__tl_dyn-array i64) (__tl_make-array i64 (+ functions 2))]
    [callers : (__tl_dyn-array i64) (__tl_make-array i64 (+ edge-count 1))]
    [cursor : (__tl_dyn-array i64) (__tl_make-array i64 (+ functions 2))]
    ;; Explicit stack plus a membership flag, so a function is queued once.
    [stack : (__tl_dyn-array i64) (__tl_make-array i64 (+ functions 1))]
    [queued : (__tl_dyn-array bool) (__tl_make-array bool (+ functions 1))]
    [top : i64 0]
    (for [e (iterator.range 0 edge-count)]
      (let
        [dst : i64 (array-ref census.edge-dst e)]
        (set! (array-ref starts (+ dst 1)) (+ (array-ref starts (+ dst 1)) 1))))
    (for [f (iterator.range 0 functions)]
      (set!
        (array-ref starts (+ f 1))
        (+ (array-ref starts (+ f 1)) (array-ref starts f))))
    (for [f (iterator.range 0 functions)]
      (set! (array-ref cursor f) (array-ref starts f)))
    (for [e (iterator.range 0 edge-count)]
      (let
        [dst : i64 (array-ref census.edge-dst e)]
        [at : i64 (array-ref cursor dst)]
        (set! (array-ref callers at) (array-ref census.edge-src e))
        (set! (array-ref cursor dst) (+ at 1))))
    ;; Seed: every function whose own row already carries a candidate.
    (for [f (iterator.range 0 functions)]
      (when
        (not
          (compiler-backend-iag-bits-empty?
            census.reach
            (* f census.words)
            census.words))
        (set! (array-ref stack top) f)
        (set! (array-ref queued f) true)
        (+= top 1)))
    (while (> top 0)
      (let
        [node : i64 (array-ref stack (- top 1))]
        [limit : i64 (array-ref starts (+ node 1))]
        (-= top 1)
        (set! (array-ref queued node) false)
        (for [index (iterator.range (array-ref starts node) limit)]
          (let
            [caller : i64 (array-ref callers index)]
            (when
              (compiler-backend-iag-bits-merge!
                (be_state.compiler-backend-global-shared-view census.reach)
                (* caller census.words)
                (be_state.compiler-backend-global-shared-view census.reach)
                (* node census.words)
                census.words)
              (when
                (not (array-ref queued caller))
                (set! (array-ref stack top) caller)
                (set! (array-ref queued caller) true)
                (+= top 1)))))))))

(define (compiler-backend-iag-callee-reach!
  [census : be_state.CompilerBackendIagCensus]
  [edge-count : i64]) : unit
  (for [e (iterator.range 0 edge-count)]
    (compiler-backend-iag-bits-merge!
      (be_state.compiler-backend-global-shared-view census.callee-reach)
      (* (array-ref census.edge-src e) census.words)
      (be_state.compiler-backend-global-shared-view census.reach)
      (* (array-ref census.edge-dst e) census.words)
      census.words)
    unit))

;; The safety rule, applied to the recorded rows: a candidate that some
;; function rebinds must not be MENTIONED by a function that rebinds it, that
;; makes an indirect call, or whose direct callees can reach a rebind.
(define (compiler-backend-iag-decide!
  [census : be_state.CompilerBackendIagCensus]) : unit
  (let
    [f : i64 0]
    (while (< f census.function-count)
      (let
        [base : i64 (* f census.words)]
        (when
          (not
            (compiler-backend-iag-bits-empty? census.mentions base census.words))
          (let
            [c : i64 0]
            (while (< c census.count)
              (when
                (and
                  (=
                    (array-ref census.reasons c)
                    compiler-backend-iag-reason-ok)
                  (compiler-backend-iag-bit? census.mentions base c)
                  (compiler-backend-iag-bit? census.written 0 c))
                (cond
                  [(array-ref census.indirect f)
                    (set!
                      (array-ref census.reasons c)
                      compiler-backend-iag-reason-indirect-call)]
                  [(compiler-backend-iag-bit? census.writes base c)
                    (set!
                      (array-ref census.reasons c)
                      compiler-backend-iag-reason-self-rebind)]
                  [(compiler-backend-iag-bit? census.callee-reach base c)
                    (set!
                      (array-ref census.reasons c)
                      compiler-backend-iag-reason-callee-rebind)]
                  [else unit]))
              (+= c 1))))
        (+= f 1)))))

(define (compiler-backend-iag-publish
  [census : (& census be_state.CompilerBackendIagCensus)]) : backend_i64_i64_map.Map
  (let
    [table : backend_i64_i64_map.Map
      (backend_i64_i64_map.with-capacity (+ (* census.count 2) 1))]
    (for [c (iterator.range 0 census.count)]
      (when
        (= (array-ref census.reasons c) compiler-backend-iag-reason-ok)
        (backend_i64_i64_map.insert-ref!
          (&mut table)
          (array-ref census.ids c)
          (array-ref census.sizes c))))
    table))

;; `TYPELISP_TRACE_INLINE_AGGREGATE_GLOBALS=1` reports the classification, so a
;; caller can see which aggregate globals the safety rule refused and why.
(define (compiler-backend-iag-trace?) : bool
  (string.eq (env.var-value "TYPELISP_TRACE_INLINE_AGGREGATE_GLOBALS") "1"))

(define (compiler-backend-iag-trace!
  [census : be_state.CompilerBackendIagCensus]
  [program-index : be_state.CompilerBackendProgramIndex]) : unit
  (for [c (iterator.range 0 census.count)]
    (io.print-error
      (str_cat.str-cat
        (if (= (array-ref census.reasons c) compiler-backend-iag-reason-ok)
          "inline-aggregate-global: "
          "inline-aggregate-global excluded: ")
        (be_state.compiler-backend-symbol-text-index
          program-index
          (array-ref census.ids c))
        " size="
        (string.int->string (array-ref census.sizes c))
        (str_cat.str-cat
          " reason="
          (compiler-backend-iag-reason-text (array-ref census.reasons c))
          "\n"
          "")))))

;; ---------------------------------------------------------------------------
;; Classification: prepare (before the shared walk) and finish (after it).
;;
;; `prepare` finds the candidates and allocates the census rows; the shared
;; whole-program collections walk then fills them as it goes; `finish!` runs
;; the small bitset dataflow over the collected rows and publishes the answer.
;; No IR traversal of IAG-1's own remains.
;; ---------------------------------------------------------------------------
(define (compiler-backend-iag-prepare
  [type-segment-bases : i64]
  [program-index : be_state.CompilerBackendProgramIndex]
  [globals : compiler_ir_types.CompilerIrGlobalSeq]
  [functions : compiler_ir_types.CompilerIrFunctionSeq]) : be_state.CompilerBackendIagCensusCell
  (let
    [global-count : i64 globals.len]
    [ids : (__tl_dyn-array i64) (__tl_make-array i64 (+ global-count 1))]
    [sizes : (__tl_dyn-array i64) (__tl_make-array i64 (+ global-count 1))]
    [reasons : (__tl_dyn-array i64) (__tl_make-array i64 (+ global-count 1))]
    [slots : backend_i64_i64_map.Map
      (backend_i64_i64_map.with-capacity (+ (* global-count 2) 1))]
    [count : i64 0]
    (for [gi (iterator.range 0 global-count)]
      (match (compiler_ir_types.compiler-ir-global-seq-ref globals gi)
        [(Global name ty value)
          (when
            (compiler-backend-iag-boxed-cell?
              type-segment-bases
              program-index
              (be_state.compiler-backend-global-shared-view ty)
              value)
            (let
              [size : i64
                (compiler-backend-iag-candidate-size
                  type-segment-bases
                  program-index
                  (be_state.compiler-backend-global-shared-view functions)
                  (be_state.compiler-backend-global-shared-view ty)
                  value)]
              [reason : i64
                (cond
                  [(or (< size 16) (not (= (bit-and size 7) 0)))
                    compiler-backend-iag-reason-no-size]
                  [(> size compiler-backend-iag-max-size)
                    compiler-backend-iag-reason-too-large]
                  [else compiler-backend-iag-reason-ok])]
              (when
                (or
                  (= reason compiler-backend-iag-reason-ok)
                  (compiler-backend-iag-nominal-aggregate-type? ty))
                (set!
                  (array-ref ids count)
                  (compiler_ir_types.compiler-ir-symbol-id name))
                (set! (array-ref sizes count) size)
                (set! (array-ref reasons count) reason)
                (backend_i64_i64_map.insert-ref!
                  (&mut slots)
                  (compiler_ir_types.compiler-ir-symbol-id name)
                  count)
                (+= count 1))))]))
    (if (= count 0)
      (compiler-backend-iag-census-disabled)
      (let
        [words : i64 (shr (+ count 63) 6)]
        [function-count : i64 functions.len]
        [row-cells : i64 (+ (* function-count words) 1)]
        ;; Seed the edge arrays at about one edge per function and let them
        ;; double from there.
        [edge-capacity : i64 (+ function-count 16)]
        [state : (__tl_dyn-array i64) (__tl_make-array i64 2)]
        [tables : (& program-index be_state.CompilerBackendProgramTables)
          (be_state.compiler-backend-program-tables program-index)]
        (set! (array-ref state be_facts.compiler-backend-iag-state-function) -1)
        (set! (array-ref state be_facts.compiler-backend-iag-state-cursor) 0)
        (compiler-backend-iag-census-cell
          (be_state.CompilerBackendIagCensus
            count
            words
            ids
            sizes
            reasons
            slots
            function-count
            (__tl_make-array i64 row-cells)
            (__tl_make-array i64 row-cells)
            (__tl_make-array i64 row-cells)
            (__tl_make-array i64 row-cells)
            (__tl_make-array bool (+ function-count 1))
            (__tl_make-array i64 words)
            edge-capacity
            (__tl_make-array i64 edge-capacity)
            (__tl_make-array i64 edge-capacity)
            state
            (owned_view.compiler-owned-reference-shared-view
              (& tables.functions))))))))

;; Runs on the rows the shared walk filled: seed, close over the call graph,
;; apply the safety rule and publish. Also the ONLY publisher, so a program
;; with no candidate still clears any answer a previous batch entry left.
(define (compiler-backend-iag-finish!
  [backend-state : be_state.CompilerBackendState]
  [cell : be_state.CompilerBackendIagCensusCell]
  [program-index : be_state.CompilerBackendProgramIndex]) : unit
  (if (not (be_facts.compiler-backend-iag-cell-active? cell))
    (be_state.compiler-backend-state-set-inline-aggregate-globals!
      backend-state
      (backend_i64_i64_map.with-capacity 1))
    (let
      [census : be_state.CompilerBackendIagCensus
        (be_facts.compiler-backend-iag-census-of cell)]
      [edge-count : i64
        (array-ref census.state be_facts.compiler-backend-iag-state-cursor)]
      [_seed : unit
        (compiler-backend-iag-seed-reach!
          (be_state.compiler-backend-global-shared-view census))]
      [_closure : unit
        (compiler-backend-iag-fixpoint!
          (be_state.compiler-backend-global-shared-view census)
          edge-count)]
      [_callee : unit
        (compiler-backend-iag-callee-reach!
          (be_state.compiler-backend-global-shared-view census)
          edge-count)]
      [_decide : unit
        (compiler-backend-iag-decide!
          (be_state.compiler-backend-global-shared-view census))]
      (be_state.compiler-backend-state-set-inline-aggregate-globals!
        backend-state
        (compiler-backend-iag-publish census))
      (when
        (compiler-backend-iag-trace?)
        (compiler-backend-iag-trace! census program-index)))))

;; ---------------------------------------------------------------------------
;; Inline aggregate cell emission (text backend).
;; ---------------------------------------------------------------------------
;; Copy `remaining` bytes from `offset(src-reg)` into the inline cell at
;; `symbol`. Sizes are small compile-time multiples of eight, so the run is
;; fully unrolled; `xmm` (when non-empty) takes 16 bytes at a time and `gp`
;; shuttles the rest one word at a time.
(define (compiler-backend-emit-inline-aggregate-copy-chunks
  [symbol : String]
  [src-reg : String]
  [gp : String]
  [xmm : String]
  [offset : i64]
  [remaining : i64]) : String
  (if (<= remaining 0)
    ""
    (if (and (>= remaining 16) (> (string.string-length xmm) 0))
      (str_cat.str-cat
        (str_cat.str-cat
          "    movups "
          (be_facts.compiler-backend-copy-address
            offset
            (be_state.compiler-backend-global-shared-view src-reg))
          ", "
          xmm
          "\n")
        (str_cat.str-cat
          "    movups "
          xmm
          ", "
          (be_state.compiler-backend-inline-aggregate-symbol-operand
            symbol
            offset)
          "\n")
        (compiler-backend-emit-inline-aggregate-copy-chunks
          symbol
          src-reg
          gp
          xmm
          (+ offset 16)
          (- remaining 16))
        "")
      (str_cat.str-cat
        (str_cat.str-cat
          "    movq "
          (be_facts.compiler-backend-copy-address
            offset
            (be_state.compiler-backend-global-shared-view src-reg))
          ", "
          gp
          "\n")
        (str_cat.str-cat
          "    movq "
          gp
          ", "
          (be_state.compiler-backend-inline-aggregate-symbol-operand
            symbol
            offset)
          "\n")
        (compiler-backend-emit-inline-aggregate-copy-chunks
          symbol
          src-reg
          gp
          xmm
          (+ offset 8)
          (- remaining 8))
        ""))))

;; The whole of a `(set! g v)` rebind for an inline aggregate global: `v` is a
;; pointer to the new aggregate, so the cell takes a byte copy rather than a
;; pointer store. The pointer is read from its register home when it has one,
;; else loaded into a scavenged register; the single extra shuttle register is
;; scavenged at this point, excluding it.
(define (compiler-backend-emit-inline-aggregate-store
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [symbol : String]
  [size : i64]
  [value : compiler_ir_types.CompilerIrValue]
  [backend-state : be_state.CompilerBackendState]) : be_state.ResultCompilerBackend
  (let
    [src-home : String
      (be_facts.compiler-backend-address-base-filter-direct
        (be_facts.compiler-backend-value-register-home
          backend-state
          assignments
          value))]
    [src-reg : String
      (if (string.eq src-home "")
        (be_operand.compiler-backend-scavenge-reg-here
          (be_facts.compiler-backend-addr-scavenge-exclude)
          0
          "%r10"
          backend-state)
        (owned_view.compiler-owned-shared-view src-home))]
    [shuttle : String
      (be_operand.compiler-backend-scavenge-reg-here
        (be_operand.compiler-backend-one-exclude
          (be_state.compiler-backend-global-shared-view src-reg))
        1
        "%r11"
        backend-state)]
    [src-asm
      (try
        (if (string.eq src-home "")
          (be_operand.compiler-backend-emit-load-value
            assignments
            value
            (be_state.compiler-backend-global-shared-view src-reg)
            backend-state)
          (be_state.ResultCompilerBackend.Ok "")))]
    (Ok
      (str_cat.str-cat
        src-asm
        (compiler-backend-emit-inline-aggregate-copy-chunks
          symbol
          src-reg
          shuttle
          ""
          0
          size)
        ""
        ""))))

;; The reserved cell size of a runtime-initialised global: the aggregate itself
;; for an inline aggregate, two words for a register group, one word otherwise.
(define (compiler-backend-runtime-global-cell-size
  [type-segment-bases : i64]
  [program-index : be_state.CompilerBackendProgramIndex]
  [name : i64]
  [ty : compiler_ast_types.AstType]) : i64
  (let
    [inline-size : i64
      (be_state.compiler-backend-inline-aggregate-global-size
        program-index.backend-state
        name)]
    (if (> inline-size 0)
      inline-size
      (if (be_facts.compiler-backend-group-type?
        type-segment-bases
        program-index
        ty)
        16
        8))))

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
  [size : i64]) : String
  ;; ELF `.comm` takes the alignment in bytes, COFF its base-2 logarithm.
  (str_cat.str-cat
    "    .comm "
    symbol
    ", "
    (string.int->string size)
    (if (be_state.compiler-backend-target-elf? target)
      ", 8\n"
      ", 3\n")))

(define (compiler-backend-emit-global
  [type-segment-bases : i64]
  [target : be_state.CompilerBackendTarget]
  [global : compiler_ir_types.CompilerIrGlobal]
  [program-index : be_state.CompilerBackendProgramIndex]) : be_state.ResultCompilerBackend
  (match global
    [(Global name ty value)
      (let
        [symbol : String
          (be_state.compiler-backend-state-user-symbol-id
            program-index.backend-state
            name)]
        (if (compiler-backend-runtime-global? ty value)
          (Ok
            (str_cat.str-cat
              ".globl "
              symbol
              "\n"
              (compiler-backend-emit-runtime-global
                target
                symbol
                (compiler-backend-runtime-global-cell-size
                  type-segment-bases
                  program-index
                  name
                  ty))
              ""))
          (let
            [value-asm
              (try
                (compiler-backend-global-value-asm
                  type-segment-bases
                  ty
                  value
                  program-index))]
            (Ok
              (str_cat.str-cat ".globl " symbol "\n" symbol ":\n" value-asm "")))))]))

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
  [name : i64]
  [init : i64]
  [ty : (& compiler_ast_types.AstType)]
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
    [inline-size : i64
      (be_state.compiler-backend-inline-aggregate-global-size
        program-index.backend-state
        name)]
    (str_cat.str-cat
      "    call "
      init-symbol
      "\n"
      (cond
        ;; IAG-1: the initializer still returns a pointer to an arena-resident
        ;; aggregate (src/compiler_lower.tl's global-init sret rule). The
        ;; startup sequence copies it into the inline cell. Nothing else is
        ;; live between the `__global_init_*` calls, so %r10/%xmm0 are free.
        [(> inline-size 0)
          (compiler-backend-emit-inline-aggregate-copy-chunks
            symbol
            "%rax"
            "%r10"
            "%xmm0"
            0
            inline-size)]
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
  [globals : (& compiler_ir_types.CompilerIrGlobalSeq)]
  [program-index : be_state.CompilerBackendProgramIndex]
  [index : i64]) : String
  (if (>= index globals.len)
    ""
    (match (compiler_ir_types.compiler-ir-global-seq-borrow globals index)
      [(Global name ty value)
        (str_cat.str-cat
          (match value
            [(RuntimeGlobal init)
              (compiler-backend-global-init-call
                type-segment-bases
                name
                init
                ty
                program-index)]
            [_ ""])
          (compiler-backend-global-initializers-from
            type-segment-bases
            globals
            program-index
            (+ index 1)))])))

(define (compiler-backend-global-initializers
  [type-segment-bases : i64]
  [globals : compiler_ir_types.CompilerIrGlobalSeq]
  [program-index : be_state.CompilerBackendProgramIndex]) : String
  (compiler-backend-global-initializers-from
    type-segment-bases
    globals
    program-index
    0))

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
      [(Extern name-id source-name-id _ _ _ link-symbol _ provided _)
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
      [(Extern name-id source-name-id _ _ _ link-symbol _ _ _)
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

(define (compiler-backend-extern-symbol-referenced?
  [runtime-index : (& runtime-index be_state.CompilerBackendRuntimeIndex)]
  [referenced-functions : (& referenced-functions be_state.BackendSymbolSeq)]
  [extern-name-id : i64]
  [source-name-id : i64]
  [link-symbol-id : i64]) : bool
  (or
    (be_state.backend-or4
      (compiler-backend-runtime-index-calls? runtime-index extern-name-id)
      (compiler-backend-runtime-index-calls? runtime-index source-name-id)
      (compiler-backend-runtime-index-calls? runtime-index link-symbol-id)
      (be_state.compiler-backend-symbol-list-contains-id?
        referenced-functions
        extern-name-id))
    (be_state.compiler-backend-symbol-list-contains-id?
      referenced-functions
      source-name-id)
    (be_state.compiler-backend-symbol-list-contains-id?
      referenced-functions
      link-symbol-id)))

(define (compiler-backend-emit-externs-into
  [backend-state : be_state.CompilerBackendState]
  [externs : compiler_ir_types.CompilerIrExternSeq]
  [plan : be_state.CompilerBackendRuntimePlan]
  [runtime-index : be_state.CompilerBackendRuntimeIndex]
  [referenced-functions : be_state.BackendSymbolSeq]
  [buf : text_buf.TextBuf]) : text_buf.TextBuf
  (compiler-backend-emit-extern-seq-into
    backend-state
    externs
    plan
    runtime-index
    referenced-functions
    buf
    0))

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
      [(Extern name-id source-name-id _ _ abi link-symbol-id _ provided _)
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
            (compiler-backend-extern-symbol-referenced?
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
        [(Extern name source _ _ _ link _ _ _)
          (let
            [bit : i64 (compiler-backend-runtime-leaf-bit backend-state link)]
            (when
              (and
                (!= bit 0)
                (= (bit-and mask bit) 0)
                (compiler-backend-extern-symbol-referenced?
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
        (set!
          features.leaf-mask
          (match target
            [(be_state.CompilerBackendTarget.Linux) used]
            [(be_state.CompilerBackendTarget.Windows)
              (bit-or features.leaf-mask (bit-and used 96))]))))
    features))

(define (compiler-backend-runtime-data-for-target
  [target : be_state.CompilerBackendTarget]
  [features : runtime_common.CompilerBackendRuntimeFeatures]) : String
  (match target
    [(be_state.CompilerBackendTarget.Linux)
      (runtime_linux.compiler-backend-runtime-data features)]
    [(be_state.CompilerBackendTarget.Windows)
      (runtime_windows.compiler-backend-runtime-data features)]))

(define (compiler-backend-runtime-functions-for-target
  [target : be_state.CompilerBackendTarget]
  [features : runtime_common.CompilerBackendRuntimeFeatures]) : String
  (match target
    [(be_state.CompilerBackendTarget.Linux)
      (runtime_linux.compiler-backend-runtime-functions features)]
    [(be_state.CompilerBackendTarget.Windows)
      (runtime_windows.compiler-backend-runtime-functions features)]))

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
;; the finished assembly (`compiler-backend-shared-object-assembly`) plus two
;; emission changes the pass cannot make: the program has no entry, only
;; `tl_shared_object_init`, and an abort-site descriptor is placed in
;; `.data.rel.ro` instead of inline in `.text`. The executable code model's
;; output is unchanged.
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
(define (compiler-backend-shared-object-section-kind
  [text : (& text str)]
  [start : i64]) : i64
  (let
    [push : bool (string.is-string-prefix-at text ".pushsection " start)]
    [name-start : i64
      (cond
        [push (+ start 13)]
        [(string.is-string-prefix-at text ".section " start) (+ start 9)]
        [else -1])]
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
      (if push
        (+ start 13)
        (+ start 9))]
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
    .ascii \"typelisp runtime: main-stack reservation failed\\n\"
    .text
.L_tl_main_stack_abort:
    movq $1, %rax
    movq $2, %rdi
    leaq .L_tl_main_stack_mmap_error(%rip), %rsi
    movq $48, %rdx
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
  [global-inits : String]) : String
  (let
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
            startup-profile-asm
            "    movq (%rsp), %rax\n"
            (if capture-argv
              "    movq %rax, .L_tl_argc(%rip)
    leaq 8(%rsp), %rax
    movq %rax, .L_tl_argv(%rip)
"
              "")
            (if capture-env
              (str_cat.str-cat
                (if capture-argv
                  "    movq (%rsp), %rax\n"
                  "")
                "    leaq 16(%rsp,%rax,8), %rax
    movq %rax, .L_tl_envp(%rip)
")
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
          (compiler-backend-global-initializers
            type-segment-bases
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
      (compiler-backend-emit-string-rodata-into strings globals-buf)]
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
                            runtime-features)
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

;; IAG-1 ordering. The `.comm` size, the `Global` materialisation form and
;; every fold read one already-published classification, so the whole-program
;; walk has to precede global emission. That walk is the one the backend
;; already made -- `compiler-backend-collect-program-collections` -- so it is
;; MOVED here rather than duplicated: prepare the census, run the single walk
;; (which fills the census rows as a side effect of visiting operands it was
;; visiting anyway), finish the classification, then spell the globals.
;;
;; The walk runs over the ENTRY function list, the sequence the program index
;; was built from, so a census row index is that function's program-index slot.
;; The only function that list can add is the synthesized implicit `main`
;; (`return 0`), which contributes nothing to any collection.
(define (compiler-backend-emit-globals-and-collections
  [type-segment-bases : i64]
  [target : be_state.CompilerBackendTarget]
  [globals : compiler_ir_types.CompilerIrGlobalSeq]
  [functions : compiler_ir_types.CompilerIrFunctionSeq]
  [spans : compiler_ir_types.CompilerSourceSpans]
  [program-index : be_state.CompilerBackendProgramIndex]) : ResultCompilerBackendGlobalsAndCollections
  (let
    [census : be_state.CompilerBackendIagCensusCell
      (compiler-backend-iag-prepare
        type-segment-bases
        program-index
        (be_state.compiler-backend-global-shared-view globals)
        (be_state.compiler-backend-global-shared-view functions))]
    [collections : be_state.CompilerBackendProgramCollections
      (compiler-backend-collect-source-path-strings
        program-index.backend-state
        (compiler-backend-collect-program-collections-with-iag
          (be_state.compiler-backend-global-shared-view globals)
          functions
          (be_state.compiler-backend-global-shared-view census))
        spans)]
    ;; W3(c): the walk above is the whole-program cell-writer scan. Publishing
    ;; here -- before any function is planned -- is what makes a frozen global's
    ;; read rematerialisable in the allocator.
    [_frozen-globals-known : unit
      (compiler_regalloc.compiler-reg-frozen-globals-finish!)]
    [_inline-aggregates : unit
      (compiler-backend-iag-finish!
        program-index.backend-state
        census
        program-index)]
    [globals-buf
      (try
        (compiler-backend-emit-globals-buffer-into
          type-segment-bases
          target
          globals
          (text_buf.append (text_buf.empty) ".data\n")
          program-index))]
    (Ok globals-buf collections)))