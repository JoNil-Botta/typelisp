(import stdlib.iterator)

;; Each fragment is a run of fixed bytes ending at a layout decision. Labels
;; and fixups within the run retain a fragment index and an intra-run offset.
(import compiler_linux_asm_symbols as sym)
(import compiler_x64_encode as x64)
(import compiler_x64_encode_bytes as enc)
(import stdlib.arena)
(import stdlib.byte_buf_core as buf)
(import stdlib.byte_le)
(import stdlib.string)
(import stdlib.str_cat_runtime as str_cat)
(import stdlib.vector)
(import stdlib.hashmap)
(import (hashmap.hashmap String i64) as section_map)
(import compiler_object_layout as object_layout)
(import compiler_object as obj)
(import compiler_object_linux_sections as linux)

(defenum Tail
  (Fixed)
  (Fill i64 i64)
  (Align i64 i64 i64)
  (Branch i64 i64 i64))

(defstruct Fragment
  (start i64)
  (count i64)
  (tail Tail)
  (address i64)
  (length i64))

(import (vector.vector Fragment core) as fragments)

(defstruct Field
  (fragment i64)
  (delta i64)
  (width i64)
  (end-distance i64)
  (got-type i64)
  (intent enc.X64RelocationIntent)
  (expression sym.Expression))

(import (vector.vector Field core) as fields)

(defenum RelaTarget
  (Named i64)
  (SectionAddress i64)
  (AbsoluteZero))

(defstruct Rela
  (offset i64)
  (target RelaTarget)
  (ty i64)
  (addend i64))

(import (vector.vector Rela core) as relas)

(defstruct Section
  (name String)
  (ty i64)
  (flags i64)
  (entry-size i64)
  (group i64)
  (link-name String)
  (alignment i64)
  (raw buf.ByteBufBuilder)
  (start i64)
  (runs fragments.Vec)
  (fixups fields.Vec)
  (relocations relas.Vec)
  (size i64))

(import (vector.vector Section core) as sections)

(define (new-section
  [name : String]
  [ty : i64]
  [flags : i64]
  [entry-size : i64]
  [group : i64]
  [link-name : String]) : Section
  (Section
    name
    ty
    flags
    entry-size
    group
    link-name
    1
    (buf.byte-buf-builder-new)
    0
    (fragments.new)
    (fields.new)
    (relas.new)
    0))

(define (position [section : (& Section)] [id : i64]) : sym.Position
  (sym.Position id section.runs.len (- section.raw.len section.start)))

(define (end-run! [s : (&mut run Section)] [tail : Tail] [length : i64]) : unit
  (fragments.push-ref!
    (&mut s.runs)
    (Fragment s.start (- s.raw.len s.start) tail 0 length))
  (set! s.start s.raw.len))

(defenum Status
  (Ok unit)
  (Err String))

(define (gotpcrel-type
  [out : (& buf.ByteBufBuilder)]
  [start : i64]
  [field : i64]) : i64
  ;; The linker may rewrite a RIP-relative MOV or indirect CALL/JMP only
  ;; when the relocation identifies a matching instruction encoding.
  (let
    [rex
      (and
        (>= (array-ref out.slots start) 0x40)
        (<= (array-ref out.slots start) 0x4f))]
    [op
      (+
        start
        (if rex
          1
          0))]
    (if (and
      (= field (+ op 2))
      (or
        (= (array-ref out.slots op) 0x8b)
        (and
          (= (array-ref out.slots op) 0xff)
          (or
            (= (array-ref out.slots (+ op 1)) 0x15)
            (= (array-ref out.slots (+ op 1)) 0x25)))))
      (if rex
        42
        41)
      9)))

(define (instruction!
  [s : (&mut run Section)]
  [table : (&mut sym.Table)]
  [line : (& str)]
  [scratch : arena.Arena]) : Status
  (when (= s.ty 8) (return (Err "instruction in NOBITS section")))
  (let
    [start s.raw.len]
    [instruction : enc.X64EncodedInstruction
      (try (x64.x64-encode-instruction! (&mut s.raw) line (Near) scratch))]
    [i : i64 0]
    (while (< i instruction.fixup-count)
      (let
        [f (& (array-ref instruction.fixups i))]
        [expr (try (sym.parse-expression! table (& f.expression)))]
        [branch
          (match f.intent
            [(BranchRelative) true]
            [_ false])]
        [opcode (cast (array-ref s.raw.slots start) : i64)]
        (when
          (and
            branch
            (= f.width 4)
            (or (= opcode 0xe9) (= opcode 0x0f))
            (>= expr.positive 0)
            (= expr.negative -1)
            (string.eq (& expr.modifier) ""))
          (let
            [short-op
              (if (= opcode 0xe9)
                0xeb
                (- (cast (array-ref s.raw.slots (+ start 1)) : i64) 16))]
            (set! s.raw.len start)
            (end-run! s (Branch short-op expr.positive expr.constant) 2)
            (return (Ok unit))))
        (fields.push-ref!
          (&mut s.fixups)
          (Field
            s.runs.len
            (- f.field-offset s.start)
            f.width
            (- f.instruction-end f.field-offset)
            (if (string.eq (& expr.modifier) "GOTPCREL")
              (gotpcrel-type (& s.raw) start f.field-offset)
              9)
            (match f.intent
              [(Absolute) (Absolute)]
              [(SignedAbsolute) (SignedAbsolute)]
              [(PcRelative) (PcRelative)]
              [(BranchRelative) (BranchRelative)])
            expr)))
      (+= i 1))
    (Ok unit)))

(define (alignment!
  [s : (&mut run Section)]
  [alignment : i64]
  [fill : i64]
  [maximum : i64]) : Status
  (unless
    (and
      (object_layout.compiler-object-layout-valid-align? alignment)
      (<= alignment object_layout.compiler-object-max-file-size))
    (return (Err "alignment must be a power of two")))
  (when (> alignment s.alignment) (set! s.alignment alignment))
  (end-run! s (Align alignment fill maximum) 0)
  (Ok unit))

(define (assign-addresses! [s : (&mut run Section)] [align? : bool]) : Status
  (let
    [i : i64 0]
    [at : i64 0]
    (while (< i s.runs.len)
      (let
        [f : (&mut run Fragment) (&mut (array-ref s.runs.slots i))]
        (set! f.address at)
        (when
          (> f.count (- object_layout.compiler-object-max-file-size at))
          (return (Err "section exceeds size limit")))
        (+= at f.count)
        (match f.tail
          [(Align alignment _ maximum)
            (let
              [pad
                (if align?
                  (bit-and (- 0 at) (- alignment 1))
                  0)]
              (set!
                f.length
                (if (and (> maximum 0) (> pad maximum))
                  0
                  pad)))]
          [_ unit])
        (when
          (> f.length (- object_layout.compiler-object-max-file-size at))
          (return (Err "section exceeds size limit")))
        (+= at f.length))
      (+= i 1))
    (set! s.size at)
    (Ok unit)))

(define (label-address [s : (& Section)] [pos : (& sym.Position)]) : i64
  (+ (array-ref s.runs.slots pos.fragment).address pos.delta))

(define (promote-branches!
  [s : (&mut run Section)]
  [id : i64]
  [table : (& entry sym.Table)]) : bool
  (let
    [i : i64 0]
    [changed false]
    (while (< i s.runs.len)
      (let
        [f (array-ref s.runs.slots i)]
        (when
          (= f.length 2)
          (match f.tail
            [(Branch opcode target addend)
              (let
                [symbol : (& entry sym.Symbol)
                  (& (array-ref table.entries.slots target))]
                (when
                  (or
                    symbol.is-alias
                    (!= symbol.position.section id)
                    (= symbol.binding 2)
                    (not
                      (enc.signed-fit?
                        (-
                          (+ (label-address s (& symbol.position)) addend)
                          (+ f.address (+ f.count 2)))
                        1)))
                  (set!
                    (array-ref s.runs.slots i).length
                    (if (= opcode 0xeb)
                      5
                      6))
                  (set! changed true)))]
            [_ unit])))
      (+= i 1))
    changed))

(define (relax!
  [s : (&mut run Section)]
  [id : i64]
  [table : (& entry sym.Table)]) : Status
  (end-run! s (Fixed) 0)
  ;; First widen branches that fail even without padding. Intervening
  ;; alignments are unstable until those mandatory promotions have settled.
  (try (assign-addresses! s false))
  (while (promote-branches! s id table)
    (try (assign-addresses! s false)))
  (try (assign-addresses! s true))
  (while (promote-branches! s id table)
    (try (assign-addresses! s true)))
  (Ok unit))

(define (emit-le! [out : (&mut buf.ByteBufBuilder)] [value : i64] [width : i64]) : unit
  (let
    [i : i64 0]
    (while (< i width)
      (buf.byte-buf-builder-push out (byte_le.byte-le-byte value (* i 8)))
      (+= i 1))))

(define (nops! [out : (&mut buf.ByteBufBuilder)] [length : i64]) : unit
  ;; Intel-recommended NOP encodings, with operand-size and segment
  ;; prefixes for the 9- through 11-byte forms used by GNU as.
  (let
    [n length]
    (while (> n 0)
      (let
        [width
          (if (> n 11)
            (+ 1 (% (- n 1) 11))
            n)]
        (cond
          [(= width 1) (emit-le! out 0x90 1)]
          [(= width 2) (emit-le! out 0x9066 2)]
          [(= width 3) (emit-le! out 0x001f0f 3)]
          [(= width 4) (emit-le! out 0x00401f0f 4)]
          [(= width 5) (emit-le! out 0x441f0f 5)]
          [(= width 6) (emit-le! out 0x441f0f66 6)]
          [(= width 7) (emit-le! out 0x801f0f 7)]
          [else
            (when (>= width 9) (emit-le! out 0x66 1))
            (when (= width 11) (emit-le! out 0x66 1))
            (when (>= width 10) (emit-le! out 0x2e 1))
            (emit-le! out 0x841f0f 8)])
        (-= n width)))))

(define (materialize!
  [s : (&mut run Section)]
  [id : i64]
  [table : (& entry sym.Table)]) : buf.ByteBufBuilder
  (when (= s.ty 8) (return (buf.byte-buf-builder-new)))
  (let
    [out (buf.byte-buf-builder-with-capacity s.size)]
    [i : i64 0]
    (while (< i s.runs.len)
      (let
        [f (array-ref s.runs.slots i)]
        (buf.byte-buf-builder-append-array-range
          (&mut out)
          (& s.raw.slots)
          f.start
          f.count)
        (match f.tail
          [(Fixed) unit]
          [(or (Align _ fill _) (Fill _ fill))
            (if (= fill -1)
              (nops! (&mut out) f.length)
              (let
                [j : i64 0]
                (while (< j f.length)
                  (buf.byte-buf-builder-push (&mut out) (cast fill : u8))
                  (+= j 1))))]
          [(Branch opcode target addend)
            (let
              [width : i64
                (if (= f.length 2)
                  1
                  4)]
              [symbol : (& entry sym.Symbol)
                (& (array-ref table.entries.slots target))]
              (cond
                [(= width 1) (emit-le! (&mut out) opcode 1)]
                [(= opcode 0xeb) (emit-le! (&mut out) 0xe9 1)]
                [else
                  (emit-le! (&mut out) 0x0f 1)
                  (emit-le! (&mut out) (+ opcode 16) 1)])
              (if (and
                (not symbol.is-alias)
                (= symbol.position.section id)
                (!= symbol.binding 2))
                (emit-le!
                  (&mut out)
                  (-
                    (+ (label-address s (& symbol.position)) addend)
                    (+ out.len width))
                  width)
                (begin
                  (fields.push-ref!
                    (&mut s.fixups)
                    (Field
                      i
                      (- out.len f.address)
                      width
                      width
                      9
                      (BranchRelative)
                      (sym.Expression target -1 addend "")))
                  (emit-le! (&mut out) 0 width))))]))
      (+= i 1))
    out))

(defstruct Image
  (table sym.Table)
  (items sections.Vec)
  (current i64)
  (index section_map.Map)
  (coff bool))

(define (new-image) : Image
  (let
    [items (sections.new)]
    [index (section_map.new)]
    [roles : (Array obj.CompilerObjectSectionKind 4)
      (array (Text) (Data) (Rodata) (Bss))]
    [i : i64 0]
    (while (< i 4)
      (let
        [role (array-ref roles i)]
        [name (linux.base-name role)]
        (section_map.insert-ref!
          (&mut index)
          (string.copy (& name))
          (obj.compiler-object-role-id role).value)
        (match (linux.base-format role)
          [(Elf ty flags)
            (sections.push-ref!
              (&mut items)
              (new-section name ty flags 0 -1 ""))]
          [_ unit]))
      (+= i 1))
    (Image (sym.new-table) items 0 index false)))

(define (new-coff-image) : Image
  (let
    [image (Image (sym.new-table) (sections.new) 0 (section_map.new) true)]
    (for [i (iterator.range 0 3)]
      (let
        [name : String
          (match i
            [0 ".text"]
            [1 ".data"]
            [_ ".bss"])]
        [section
          (new-section
            (string.copy (& name))
            (if (= i 2)
              8
              1)
            (if (= i 0)
              4
              1)
            0
            -1
            "")]
        (set! section.alignment 4)
        (section_map.insert-ref! (&mut image.index) name i)
        (sections.push-ref! (&mut image.items) section)))
    image))

(define (section-spec [s : (& Section)] [id : i64]) : obj.CompilerObjectSectionSpec
  (obj.CompilerObjectSectionSpec
    (obj.CompilerObjectSectionId id)
    id
    (string.copy (& s.name))
    s.alignment
    (if (= s.ty 8)
      (ZeroFill s.size)
      (Initialized))
    (Elf s.ty s.flags)))

(define (section-index [image : (& Image)] [key : (& str)]) : i64
  (section_map.lookup-value-or
    (section_map.get-borrowed (& image.index) key)
    -1))

(define (select-section!
  [image : (&mut img Image)]
  [name : (& str)]
  [ty : i64]
  [flags : i64]
  [entry-size : i64]
  [group : i64]
  [link-name : (& str)]) : Status
  (unless
    (object_layout.compiler-object-layout-name-valid? name)
    (return (Err "invalid ELF section name")))
  (let
    [key
      (if (and (< group 0) (string.eq link-name ""))
        (string.copy name)
        (str_cat.str-cat
          (string.copy name)
          "|"
          (string.int->string group)
          "|"
          (string.copy link-name)))]
    [i (section-index image (& key))]
    (when
      (>= i 0)
      (let
        [s : (& img Section) (& (array-ref image.items.slots i))]
        (when
          (and
            (> ty 0)
            (or (!= ty s.ty) (!= flags s.flags) (!= entry-size s.entry-size)))
          (return (Err "section redeclared with different attributes"))))
      (set! image.current i)
      (return (Ok unit)))
    (set! image.current image.items.len)
    (section_map.insert-ref! (&mut image.index) key image.current)
    (sections.push-ref!
      (&mut image.items)
      (new-section
        (string.copy name)
        (if (= ty 0)
          1
          ty)
        flags
        entry-size
        group
        (string.copy link-name)))
    (Ok unit)))

(define (data-field!
  [s : (&mut Section)]
  [table : (&mut sym.Table)]
  [text : (& str)]
  [start : i64]
  [end : i64]
  [width : i64]) : Status
  (let
    [expr (try (sym.parse-expression-range! table text start end))]
    (if (and (= expr.positive -1) (= expr.negative -1))
      (if (= s.ty 8)
        (if (= expr.constant 0)
          (end-run! s (Fill width 0) width)
          (return (Err "nonzero data in NOBITS section")))
        (emit-le! (&mut s.raw) expr.constant width))
      (begin
        (when (= s.ty 8) (return (Err "relocation in NOBITS section")))
        (fields.push-ref!
          (&mut s.fixups)
          (Field s.runs.len (- s.raw.len s.start) width 0 9 (Absolute) expr))
        (emit-le! (&mut s.raw) 0 width)))
    (Ok unit)))

(define (add-rela!
  [s : (&mut Section)]
  [offset : i64]
  [target : RelaTarget]
  [ty : i64]
  [addend : i64]) : unit
  (relas.push-ref! (&mut s.relocations) (Rela offset target ty addend)))

(define (append-generated! [image : (&mut Image)] [s : Section]) : Status
  (when
    (>= (section-index image (& s.name)) 0)
    (return
      (Err
        (str_cat.str-cat
          "generated section already defined: "
          (string.copy (& s.name))))))
  (section_map.insert-ref!
    (&mut image.index)
    (string.copy (& s.name))
    image.items.len)
  (end-run! (&mut s) (Fixed) 0)
  (try (assign-addresses! (&mut s) true))
  (sections.push-ref! (&mut image.items) s)
  (Ok unit))