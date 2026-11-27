;; compiler_object_layout.tl - Section layout and x64 encoding shared by the
;; ELF and COFF object writers: little-endian byte pushers, section sizes and
;; label offsets, text instruction encodings and their rel32 fixups, and the
;; relocation-list checks both formats apply.
(import stdlib.str_cat_runtime as str_cat)
(import stdlib.iterator)
(import stdlib.byte_buf_core)
(import stdlib.string)
(import compiler_object as cobj)
(import compiler_machine_x64 as mx)

(define compiler-object-max-file-size : i64
  1073741824)

(define (compiler-object-layout-string-length [text : (& text str)]) : i64
  (__tl_string_length text))

(define (compiler-object-layout-string-ref [text : (& text str)] [index : i64]) : char
  (__tl_string_ref text index))

(define (compiler-object-layout-push-u8!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [value : i64]) : unit
  (byte_buf_core.byte-buf-builder-push out (cast (bit-and value 0xff) : u8)))

(define (compiler-object-layout-push-u16!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [value : i64]) : unit
  (compiler-object-layout-push-u8! out value)
  (compiler-object-layout-push-u8! out (shr value 8)))

(define (compiler-object-layout-push-u32!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [value : i64]) : unit
  (compiler-object-layout-push-u8! out value)
  (compiler-object-layout-push-u8! out (shr value 8))
  (compiler-object-layout-push-u8! out (shr value 16))
  (compiler-object-layout-push-u8! out (shr value 24)))

(define (compiler-object-layout-push-u64!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [value : i64]) : unit
  (compiler-object-layout-push-u32! out value)
  (compiler-object-layout-push-u32! out (shr value 32)))

(define (compiler-object-layout-push-zeroes!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [count : i64]) : unit
  (for [i (iterator.range 0 count)]
    (compiler-object-layout-push-u8! out 0))
  unit)

(define (compiler-object-layout-push-string-bytes!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [text : (& text str)]) : unit
  (let
    [n : i64 (compiler-object-layout-string-length text)]
    (for [i (iterator.range 0 n)]
      (byte_buf_core.byte-buf-builder-push
        out
        (cast (compiler-object-layout-string-ref text i) : u8)))
    unit))

(define (compiler-object-layout-align-offset [offset : i64] [align : i64]) : i64
  (if (<= align 1)
    offset
    (let
      [rem : i64 (% offset align)]
      (if (= rem 0)
        offset
        (+ offset (- align rem))))))

(define (compiler-object-layout-render-padding-to!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [offset : i64]) : unit
  (compiler-object-layout-push-zeroes! out (- offset out.len)))

(define (compiler-object-layout-bytes-string
  [out : (& out byte_buf_core.ByteBufBuilder)]) : String
  (byte_buf_core.byte-buf-builder-finish-string out))

;; Both writers lay out and number their sections in this order.
(define (compiler-object-layout-section-at
  [image : (& cobj.CompilerObjectImage)]
  [index : i64]) : cobj.CompilerObjectSectionId
  (match (& (array-ref image.sections.slots index))
    [(Section spec _ _) spec.id]))

(define (compiler-object-layout-section-index
  [image : (& cobj.CompilerObjectImage)]
  [id : cobj.CompilerObjectSectionId]) : i64
  (for [i (iterator.range 0 image.sections.len)]
    (when
      (cobj.compiler-object-section-id-eq?
        (compiler-object-layout-section-at image i)
        id)
      (return i)))
  -1)

(define (compiler-object-layout-spec
  [image : (& r cobj.CompilerObjectImage)]
  [id : cobj.CompilerObjectSectionId]) : (& r cobj.CompilerObjectSectionSpec)
  (match (&
    (array-ref
      image.sections.slots
      (compiler-object-layout-section-index image id)))
    [(Section spec _ _) spec]))

(define (compiler-object-layout-data-records-size-from
  [records : (& cobj.CompilerObjectDataRecordList)]
  [offset : i64]) : i64
  (let
    [count : i64 (cobj.compiler-object-data-record-list-count records)]
    [cur-offset : i64 offset]
    (for [index (iterator.range 0 count)]
      (set!
        cur-offset
        (cobj.compiler-object-data-record-end-offset
          (& (cobj.compiler-object-data-record-list-ref records index))
          cur-offset)))
    cur-offset))

(define (compiler-object-layout-data-records-size
  [records : (& cobj.CompilerObjectDataRecordList)]) : i64
  (compiler-object-layout-data-records-size-from records 0))

(define (compiler-object-layout-data-records-max-align
  [records : (& cobj.CompilerObjectDataRecordList)]
  [min-align : i64]) : i64
  (let
    [count : i64 (cobj.compiler-object-data-record-list-count records)]
    [best : i64 min-align]
    (for [index (iterator.range 0 count)]
      (match (cobj.compiler-object-data-record-list-ref records index)
        [(Align align) (when (> align best) (set! best align))]
        [_ unit]))
    best))

(define (compiler-object-layout-base-section
  [role : cobj.CompilerObjectSectionKind]
  [name : String]
  [format : cobj.CompilerObjectSectionFormat]
  [data : cobj.CompilerObjectDataRecordList]
  [instrs : cobj.CompilerObjectX64InstrList]) : cobj.CompilerObjectSection
  (let
    [id (cobj.compiler-object-role-id role)]
    [align
      (compiler-object-layout-data-records-max-align
        (& data)
        (match role
          [(Text) 16]
          [_ 8]))]
    [storage : cobj.CompilerObjectSectionStorage
      (match role
        [(Bss) (ZeroFill (compiler-object-layout-data-records-size (& data)))]
        [_ (Initialized)])]
    (Section
      (cobj.CompilerObjectSectionSpec id id.value name align storage format)
      data
      instrs)))

(define (compiler-object-layout-section-align
  [image : (& cobj.CompilerObjectImage)]
  [id : cobj.CompilerObjectSectionId]) : i64
  (compiler-object-layout-spec image id).align)

(define (compiler-object-layout-instr-size
  [instr : (& cobj.CompilerObjectX64Instr)]) : i64
  (match instr
    [(Label _) 0]
    [(or (Call _) (TailCall _) (Jump _) (LoadAbsAddress _)) 5]
    [(or (Ja _) (Jcc _ _)) 6]
    [(Branch _ _) 14]
    [(SubRspImm8 _) 4]
    [(MovRcxRax) 3]
    [(XorpdRip _) 8]
    [(Machine instr) (mx.compiler-machine-x64-size instr)]
    [(Bytes bytes) (compiler-object-layout-string-length bytes)]
    [(Raw bytes) (compiler-object-layout-string-length bytes)]
    ;; The rest are REX + opcode + ModRM rip-relative forms with a rel32.
    [_ 7]))

;; Every instruction form encodes except a Jcc whose condition code is not
;; 0-15, and Raw bytes in a format that takes none (`raw` false).
(define (compiler-object-layout-instrs-encodable?
  [instrs : (& cobj.CompilerObjectX64InstrList)]
  [raw : bool]) : bool
  (let
    [count : i64 (cobj.compiler-object-instr-list-count instrs)]
    [index : i64 0]
    [ok : bool true]
    (while (and ok (< index count))
      (set!
        ok
        (match (cobj.compiler-object-instr-list-ref instrs index)
          [(Jcc cc _) (cobj.compiler-object-condition-code-valid? cc)]
          [(Raw _) raw]
          [_ true]))
      (+= index 1))
    ok))

;; The four-byte fixup fields of one text instruction and their symbols.
;; Each field is the instruction's last four bytes, except that Branch
;; (`test %rax; jnz true; jmp false`) has its jnz field at bytes 5..8.
;; The targets are borrowed from the instruction.
(defenum CompilerObjectLayoutFixup
  (:lifetimes a)
  (None)
  (One cobj.CompilerObjectRelocationKind (& a str))
  (Branch (& a str) (& a str)))

(define (compiler-object-layout-instr-fixup
  [instr : (& a cobj.CompilerObjectX64Instr)]) : (CompilerObjectLayoutFixup a)
  (match instr
    [(Call target) (One (Call) target)]
    [(TailCall target) (One (TailCall) target)]
    [(or (Jump target) (Ja target) (Jcc _ target)) (One (Branch) target)]
    [(Branch true-target false-target) (Branch true-target false-target)]
    [(LoadAbsAddress target) (One (Abs32) target)]
    [(or (LoadRip target) (MovRcxRip target) (MovRdxRip target)
         (XorpdRip target))
      (One (RipValue) target)]
    [(or (LoadRipAddress target) (LoadRipAddressR11 target) (StoreRip target)
         (LoadRipAddressRdx target) (StoreR14Rip target) (StoreR15Rip target)
         (AddRcxRip target))
      (One (RipAddress) target)]
    [_ (None)]))

(define (compiler-object-layout-instr-relocation-count
  [instr : (& cobj.CompilerObjectX64Instr)]) : i64
  (match (compiler-object-layout-instr-fixup instr)
    [(None) 0]
    [(One _ _) 1]
    [(Branch _ _) 2]))

(define (compiler-object-layout-instrs-relocation-count
  [instrs : (& cobj.CompilerObjectX64InstrList)]) : i64
  (let
    [count : i64 (cobj.compiler-object-instr-list-count instrs)]
    [total : i64 0]
    (for [index (iterator.range 0 count)]
      (+=
        total
        (compiler-object-layout-instr-relocation-count
          (& (cobj.compiler-object-instr-list-ref instrs index)))))
    total))

(define (compiler-object-layout-instrs-size-from
  [instrs : (& cobj.CompilerObjectX64InstrList)]
  [offset : i64]) : i64
  (let
    [count : i64 (cobj.compiler-object-instr-list-count instrs)]
    [cur-offset : i64 offset]
    (for [index (iterator.range 0 count)]
      (+=
        cur-offset
        (compiler-object-layout-instr-size
          (& (cobj.compiler-object-instr-list-ref instrs index)))))
    cur-offset))

(define (compiler-object-layout-instrs-size
  [instrs : (& cobj.CompilerObjectX64InstrList)]) : i64
  (compiler-object-layout-instrs-size-from instrs 0))

(define (compiler-object-layout-section-size
  [section : (& cobj.CompilerObjectSection)]) : i64
  (match section
    [(Section spec data instrs)
      (match spec.storage
        [(ZeroFill extent) extent]
        [(Initialized)
          (+
            (compiler-object-layout-instrs-size instrs)
            (compiler-object-layout-data-records-size data))])]))

(define (compiler-object-layout-section-virtual-size
  [image : (& cobj.CompilerObjectImage)]
  [id : cobj.CompilerObjectSectionId]) : i64
  (compiler-object-layout-section-size
    (&
      (array-ref
        image.sections.slots
        (compiler-object-layout-section-index image id)))))

(define (compiler-object-layout-section-raw-size
  [image : (& cobj.CompilerObjectImage)]
  [id : cobj.CompilerObjectSectionId]) : i64
  (let
    [index : i64 (compiler-object-layout-section-index image id)]
    (if (< index 0)
      0
      (match (& (array-ref image.sections.slots index))
        [(Section spec _ _)
          (match spec.storage
            [(ZeroFill _) 0]
            [(Initialized)
              (compiler-object-layout-section-size
                (& (array-ref image.sections.slots index)))])]))))

;; Text relocations are the instruction fixup kinds. Data sections carry
;; absolute addresses, plus image-relative 32-bit ones where the format has
;; them (COFF's ADDR32NB, used by unwind and resource tables).
(define (compiler-object-layout-relocation-supported?
  [reloc : (& cobj.CompilerObjectRelocation)]
  [coff? : bool]) : bool
  (match reloc
    [(Relocation section _ kind _)
      (cond
        [(cobj.compiler-object-section-id-eq? section cobj.text-id)
          (match kind
            [(or (Call) (TailCall) (RipValue) (RipAddress) (Branch)) true]
            [(Abs32) (not coff?)]
            [_ false])]
        [else
          (match kind
            [(Abs64) true]
            [(Addr32Nb) coff?]
            [_ false])])]))

(define (compiler-object-layout-relocation-list-supported?
  [relocs : (& relocs cobj.CompilerObjectRelocationList)]
  [coff? : bool]) : bool
  (let
    [count : i64 (cobj.compiler-object-relocation-list-count relocs)]
    [index : i64 0]
    [ok : bool true]
    (while (and ok (< index count))
      (if (compiler-object-layout-relocation-supported?
        (& (cobj.compiler-object-relocation-list-ref relocs index))
        coff?)
        (+= index 1)
        (set! ok false)))
    ok))

(define (compiler-object-layout-data-label-offset-from
  [records : (& records cobj.CompilerObjectDataRecordList)]
  [label : (& str)]
  [offset : i64]) : i64
  (let
    [count : i64 (cobj.compiler-object-data-record-list-count records)]
    [index : i64 0]
    [cur-offset : i64 offset]
    [result : i64 -1]
    [done : bool false]
    (while (and (not done) (< index count))
      (let
        [record : cobj.CompilerObjectDataRecord
          (cobj.compiler-object-data-record-list-ref records index)]
        (match (& record)
          [(Label found)
            (if (string.eq found label)
              (begin
                (set! result cur-offset)
                (set! done true))
              (+= index 1))]
          [_
            (set!
              cur-offset
              (cobj.compiler-object-data-record-end-offset
                (& record)
                cur-offset))
            (+= index 1)])))
    result))

(define (compiler-object-layout-instr-label-offset-from
  [instrs : (& cobj.CompilerObjectX64InstrList)]
  [label : (& str)]
  [offset : i64]) : i64
  (let
    [count : i64 (cobj.compiler-object-instr-list-count instrs)]
    [index : i64 0]
    [cur-offset : i64 offset]
    [result : i64 -1]
    [done : bool false]
    (while (and (not done) (< index count))
      (let
        [instr : cobj.CompilerObjectX64Instr
          (cobj.compiler-object-instr-list-ref instrs index)]
        (match (& instr)
          [(Label found)
            (if (string.eq found label)
              (begin
                (set! result cur-offset)
                (set! done true))
              (+= index 1))]
          [_
            (+= cur-offset (compiler-object-layout-instr-size (& instr)))
            (+= index 1)])))
    result))

(define (compiler-object-layout-section-label-offset
  [image : (& image cobj.CompilerObjectImage)]
  [kind : cobj.CompilerObjectSectionId]
  [label : (& str)]) : i64
  (match (cobj.compiler-object-section-list-find image.sections kind)
    [(Section _ data instrs)
      (cond
        [(cobj.compiler-object-section-id-eq? kind cobj.text-id)
          (compiler-object-layout-instr-label-offset-from
            (& instrs)
            (& label)
            0)]
        [else (compiler-object-layout-data-label-offset-from data (& label) 0)])]))

(define (compiler-object-layout-symbol-value
  [image : (& image cobj.CompilerObjectImage)]
  [name : (& str)]
  [section : cobj.CompilerObjectMaybeSection]) : i64
  (match section
    [(No) 0]
    [(Some kind)
      (let
        [offset : i64
          (compiler-object-layout-section-label-offset image kind (& name))]
        (if (< offset 0)
          0
          offset))]))

(define (compiler-object-layout-symbol-known?
  [symbols : (& symbols cobj.CompilerObjectSymbolList)]
  [name : (& name str)]) : bool
  (let
    [count : i64 (cobj.compiler-object-symbol-list-count symbols)]
    [index : i64 0]
    [found : bool false]
    (while (and (not found) (< index count))
      (match (cobj.compiler-object-symbol-list-ref symbols index)
        [(Symbol symbol-name _ _ _)
          (if (string.eq symbol-name name)
            (set! found true)
            (+= index 1))]))
    found))

(define (compiler-object-layout-text-targets-known?
  [image : (& image cobj.CompilerObjectImage)]) : bool
  (match (cobj.compiler-object-section-list-find image.sections cobj.text-id)
    [(Section _ _ instrs)
      (let
        [count : i64 (cobj.compiler-object-instr-list-count instrs)]
        [index : i64 0]
        [ok : bool true]
        (while (and ok (< index count))
          (let
            [instr : cobj.CompilerObjectX64Instr
              (cobj.compiler-object-instr-list-ref instrs index)]
            (set!
              ok
              (match (compiler-object-layout-instr-fixup (& instr))
                [(None) true]
                [(One _ target)
                  (compiler-object-layout-symbol-known? image.symbols target)]
                [(Branch true-target false-target)
                  (and
                    (compiler-object-layout-symbol-known?
                      image.symbols
                      true-target)
                    (compiler-object-layout-symbol-known?
                      image.symbols
                      false-target))])))
          (+= index 1))
        ok)]))

(define (compiler-object-layout-text-instr-relocation-count
  [image : (& image cobj.CompilerObjectImage)]) : i64
  (match (cobj.compiler-object-section-list-find image.sections cobj.text-id)
    [(Section _ _ instrs)
      (compiler-object-layout-instrs-relocation-count (& instrs))]))

(define (compiler-object-layout-relocation-count
  [relocs : (& relocs cobj.CompilerObjectRelocationList)]
  [kind : cobj.CompilerObjectSectionId]) : i64
  (let
    [count : i64 (cobj.compiler-object-relocation-list-count relocs)]
    [total : i64 0]
    (for [index (iterator.range 0 count)]
      (match (cobj.compiler-object-relocation-list-ref relocs index)
        [(Relocation section _ _ _)
          (if (cobj.compiler-object-section-id-eq? section kind)
            (+= total 1)
            unit)]))
    total))

(define (compiler-object-layout-section-relocation-count
  [image : (& image cobj.CompilerObjectImage)]
  [kind : cobj.CompilerObjectSectionId]) : i64
  (cond
    [(cobj.compiler-object-section-id-eq? kind cobj.text-id)
      (compiler-object-layout-text-instr-relocation-count image)]
    [else (compiler-object-layout-relocation-count image.relocations kind)]))

(define (compiler-object-layout-text-relocation-count-matches?
  [image : (& image cobj.CompilerObjectImage)]) : bool
  (=
    (compiler-object-layout-relocation-count image.relocations cobj.text-id)
    (compiler-object-layout-text-instr-relocation-count image)))

(define (compiler-object-layout-render-data-record!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [record : cobj.CompilerObjectDataRecord]
  [offset : i64]) : i64
  (match record
    [(Label _) offset]
    [(Align align)
      (let
        [aligned : i64 (compiler-object-layout-align-offset offset align)]
        (compiler-object-layout-push-zeroes! out (- aligned offset))
        aligned)]
    [(Bytes bytes)
      (compiler-object-layout-push-string-bytes! out bytes)
      (+ offset (compiler-object-layout-string-length bytes))]
    [(String text)
      (compiler-object-layout-push-string-bytes! out text)
      (compiler-object-layout-push-u8! out 0)
      (cobj.compiler-object-data-record-end-offset (& (String text)) offset)]
    [(F64 bits)
      (compiler-object-layout-push-u64! out (cast bits : i64))
      (+ offset 8)]
    [(F32 bits)
      (compiler-object-layout-push-u32! out (cast bits : i64))
      (+ offset 4)]
    [(I64 value)
      (compiler-object-layout-push-u64! out value)
      (+ offset 8)]
    [(Zero count)
      (compiler-object-layout-push-zeroes! out count)
      (+ offset count)]
    [(SymbolAddress _)
      (compiler-object-layout-push-u64! out 0)
      (+ offset 8)]
    [(SymbolRva32 _)
      (compiler-object-layout-push-u32! out 0)
      (+ offset 4)]))

(define (compiler-object-layout-render-data-records!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [records : (& cobj.CompilerObjectDataRecordList)]
  [offset : i64]) : i64
  (let
    [count : i64 (cobj.compiler-object-data-record-list-count records)]
    [cur-offset : i64 offset]
    (for [index (iterator.range 0 count)]
      (set!
        cur-offset
        (compiler-object-layout-render-data-record!
          out
          (cobj.compiler-object-data-record-list-ref records index)
          cur-offset)))
    cur-offset))

;; Push the bytes HEX spells, two hex digits per byte.
(define (compiler-object-layout-push-hex!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [hex : (& hex str)]) : unit
  (let
    [i : i64 0]
    [n : i64 (compiler-object-layout-string-length hex)]
    (while (< (+ i 1) n)
      (compiler-object-layout-push-u8!
        out
        (+
          (* 16 (compiler-object-layout-hex-digit hex i))
          (compiler-object-layout-hex-digit hex (+ i 1))))
      (+= i 2))
    unit))

(define (compiler-object-layout-hex-digit [hex : (& hex str)] [index : i64]) : i64
  (let
    [c : char (compiler-object-layout-string-ref hex index)]
    (cond
      [(and (>= c '0') (<= c '9')) (- (cast c : i64) (cast '0' : i64))]
      [(and (>= c 'a') (<= c 'f')) (+ 10 (- (cast c : i64) (cast 'a' : i64)))]
      [(and (>= c 'A') (<= c 'F')) (+ 10 (- (cast c : i64) (cast 'A' : i64)))]
      [else 0])))

;; An instruction whose last four bytes are a rel32 field: OPCODE's bytes, then
;; zeroes for the relocation to fill.
(define (compiler-object-layout-push-rel32-instr!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [opcode : (& opcode str)]) : unit
  (compiler-object-layout-push-hex! out opcode)
  (compiler-object-layout-push-u32! out 0))

(define (compiler-object-layout-render-instr!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [instr : (& cobj.CompilerObjectX64Instr)]) : unit
  (match instr
    [(Label _) unit]
    [(Call _) (compiler-object-layout-push-rel32-instr! out "e8")]
    [(or (TailCall _) (Jump _))
      (compiler-object-layout-push-rel32-instr! out "e9")]
    [(Ja _) (compiler-object-layout-push-rel32-instr! out "0f87")]
    [(Jcc cc _)
      (compiler-object-layout-push-u8! out 0x0f)
      (compiler-object-layout-push-u8! out (+ 0x80 cc))
      (compiler-object-layout-push-u32! out 0)]
    [(Branch _ _)
      (compiler-object-layout-push-rel32-instr! out "4885c00f85")
      (compiler-object-layout-push-rel32-instr! out "e9")]
    [(LoadRip _) (compiler-object-layout-push-rel32-instr! out "488b05")]
    [(LoadRipAddress _) (compiler-object-layout-push-rel32-instr! out "488d05")]
    [(LoadAbsAddress _) (compiler-object-layout-push-rel32-instr! out "b8")]
    [(LoadRipAddressR11 _)
      (compiler-object-layout-push-rel32-instr! out "4c8d1d")]
    [(StoreRip _) (compiler-object-layout-push-rel32-instr! out "488905")]
    [(SubRspImm8 imm)
      (compiler-object-layout-push-hex! out "4883ec")
      (compiler-object-layout-push-u8! out imm)]
    [(MovRcxRip _) (compiler-object-layout-push-rel32-instr! out "488b0d")]
    [(MovRdxRip _) (compiler-object-layout-push-rel32-instr! out "488b15")]
    [(LoadRipAddressRdx _)
      (compiler-object-layout-push-rel32-instr! out "488d15")]
    [(StoreR14Rip _) (compiler-object-layout-push-rel32-instr! out "4c8935")]
    [(StoreR15Rip _) (compiler-object-layout-push-rel32-instr! out "4c893d")]
    [(AddRcxRip _) (compiler-object-layout-push-rel32-instr! out "48010d")]
    [(MovRcxRax) (compiler-object-layout-push-hex! out "4889c1")]
    [(XorpdRip _) (compiler-object-layout-push-rel32-instr! out "660f5705")]
    [(Machine instr) (mx.compiler-machine-x64-encode! out instr)]
    [(Bytes bytes) (compiler-object-layout-push-string-bytes! out bytes)]
    [(Raw bytes) (compiler-object-layout-push-string-bytes! out bytes)]))

(define (compiler-object-layout-render-instrs!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [instrs : (& cobj.CompilerObjectX64InstrList)]) : unit
  (let
    [count : i64 (cobj.compiler-object-instr-list-count instrs)]
    (for [index (iterator.range 0 count)]
      (compiler-object-layout-render-instr!
        out
        (& (cobj.compiler-object-instr-list-ref instrs index))))
    unit))

(define (compiler-object-layout-render-section!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [image : (& image cobj.CompilerObjectImage)]
  [kind : cobj.CompilerObjectSectionId]) : unit
  (match (cobj.compiler-object-section-list-find image.sections kind)
    [(Section _ data instrs)
      (cond
        [(cobj.compiler-object-section-id-eq? kind cobj.text-id)
          (compiler-object-layout-render-instrs! out (& instrs))]
        [else
          (compiler-object-layout-render-data-records! out (& data) 0)
          unit])]))

(define (compiler-object-layout-u8-at [text : (& text str)] [offset : i64]) : i64
  (cast (compiler-object-layout-string-ref text offset) : i64))

(define (compiler-object-layout-u16-at [text : (& text str)] [offset : i64]) : i64
  (+
    (compiler-object-layout-u8-at text offset)
    (shl (compiler-object-layout-u8-at text (+ offset 1)) 8)))

(define (compiler-object-layout-u32-at [text : (& text str)] [offset : i64]) : i64
  (+
    (compiler-object-layout-u16-at text offset)
    (shl (compiler-object-layout-u16-at text (+ offset 2)) 16)))

(define (compiler-object-layout-prefix-at?
  [text : (& text str)]
  [needle : (& needle str)]
  [start : i64]) : bool
  (let
    [text-len : i64 (compiler-object-layout-string-length text)]
    [needle-len : i64 (compiler-object-layout-string-length needle)]
    (if (> (+ start needle-len) text-len)
      false
      (let
        [i : i64 0]
        [ok : bool true]
        (while ok
          (if (< i needle-len)
            (if (=
              (compiler-object-layout-string-ref text (+ start i))
              (compiler-object-layout-string-ref needle i))
              (+= i 1)
              (set! ok false))
            (set! ok false)))
        (= i needle-len)))))

(define (compiler-object-layout-contains?
  [text : (& text str)]
  [needle : (& str)]) : bool
  (let
    [i : i64 0]
    [n : i64 (compiler-object-layout-string-length text)]
    [found : bool false]
    (while (and (not found) (< i n))
      (if (compiler-object-layout-prefix-at? text needle i)
        (set! found true)
        unit)
      (+= i 1))
    found))

;; The binary and assembly projections accept the same names. This subset of
;; assembler identifiers also excludes NUL, quotes and directive separators.
(define (compiler-object-layout-name-valid? [name : (& str)]) : bool
  (when (= (string.string-length name) 0) (return false))
  (for [i (iterator.range 0 (string.string-length name))]
    (let
      [c : char (string.string-ref name i)]
      (unless
        (or
          (and (>= c 'a') (<= c 'z'))
          (and (>= c 'A') (<= c 'Z'))
          (and (>= c '0') (<= c '9'))
          (= c '.')
          (= c '_')
          (= c '$')
          (= c '-'))
        (return false))))
  true)

(define (compiler-object-layout-valid-align? [align : i64]) : bool
  (and (> align 0) (= (bit-and align (- align 1)) 0)))

(define (compiler-object-layout-section-error
  [section : (& cobj.CompilerObjectSection)]
  [coff? : bool]) : String
  (match section
    [(Section spec data instrs)
      (let
        [nobits : bool
          (match spec.storage
            [(ZeroFill _) true]
            [_ false])]
        [text? : bool
          (cobj.compiler-object-section-id-eq?
            (cobj.CompilerObjectSectionId spec.id.value)
            cobj.text-id)]
        [offset : i64 0]
        (when (< spec.id.value 0) (return "negative section identity"))
        (unless
          (compiler-object-layout-name-valid? spec.name)
          (return "invalid section name"))
        (unless
          (and
            (compiler-object-layout-valid-align? spec.align)
            (<=
              spec.align
              (if coff?
                8192
                compiler-object-max-file-size)))
          (return "invalid section alignment"))
        (match spec.format
          [(Elf ty flags)
            (when coff? (return "ELF descriptor in COFF image"))
            (when
              (or
                (!=
                  ty
                  (if nobits
                    8
                    1))
                (!= (bit-and flags 7) flags)
                (and text? (= (bit-and flags 4) 0))
                (and nobits (!= (bit-and flags 4) 0)))
              (return "invalid ELF type or flags"))
            (when
              (or
                (string.eq spec.name ".symtab")
                (string.eq spec.name ".strtab")
                (string.eq spec.name ".shstrtab")
                (string.eq spec.name ".note.GNU-stack"))
              (return "reserved ELF section name"))]
          [(Coff flags)
            (unless coff? (return "COFF descriptor in ELF image"))
            (let
              [content : i64 (bit-and flags 0xe0)]
              (when
                (or
                  (!= (bit-and flags 0xe20000e0) flags)
                  (= (bit-and flags 0x40000000) 0)
                  (not (or (= content 32) (= content 64) (= content 128)))
                  (!= (= content 128) nobits)
                  (!= (= content 32) (!= (bit-and flags 0x20000000) 0))
                  (and text? (!= content 32)))
                (return "invalid COFF characteristics")))])
        (when
          (or (and text? (> data.len 0)) (and (not text?) (> instrs.len 0)))
          (return "illegal instruction or data payload"))
        (unless
          (compiler-object-layout-instrs-encodable? instrs (not coff?))
          (return "unsupported text instruction"))
        (for [i (iterator.range 0 data.len)]
          (let
            [record : cobj.CompilerObjectDataRecord
              (cobj.compiler-object-data-record-list-ref data i)]
            (match (& record)
              [(Zero count) (when (< count 0) (return "negative zero extent"))]
              [(Align align)
                (unless
                  (and
                    (compiler-object-layout-valid-align? align)
                    (<= align spec.align))
                  (return "invalid record alignment"))]
              [(Label _) unit]
              [(SymbolRva32 _)
                (when
                  (or nobits (not coff?))
                  (return "incompatible SymbolRva32 data record"))]
              [_
                (when nobits (return "initialized record in zero-fill section"))])
            (let
              [end : i64
                (cobj.compiler-object-data-record-end-offset (& record) offset)]
              (when (< end offset) (return "data extent overflow"))
              (set! offset end))))
        (match spec.storage
          [(ZeroFill size)
            (when
              (or (< size offset) (and coff? (> size 0xffffffff)))
              (return "invalid zero-fill extent"))]
          [(Initialized)
            (when
              (> offset compiler-object-max-file-size)
              (return "file payload exceeds size limit"))])
        "")]))

(defenum ResultCompilerObjectSection
  (Ok cobj.CompilerObjectSection)
  (Err String))

;; Extensible producer boundary. Serializers also validate the complete image
;; because names, identity uniqueness and symbol references are image-wide.
(define (compiler-object-checked-section
  [section : cobj.CompilerObjectSection]
  [coff? : bool]) : ResultCompilerObjectSection
  (let
    [error (compiler-object-layout-section-error (& section) coff?)]
    (if (string.eq (& error) "")
      (Ok section)
      (match (& section)
        [(Section spec _ _)
          (Err
            (str_cat.str-cat
              (if coff?
                "coff"
                "elf")
              ": section "
              (string.copy spec.name)
              ": "
              error))]))))

(define (compiler-object-layout-image-error
  [image : (& cobj.CompilerObjectImage)]
  [coff? : bool]) : String
  (let
    [target : String
      (if coff?
        "coff"
        "elf")]
    (when
      (>
        image.sections.len
        (if coff?
          32767
          32637))
      (return (str_cat.str-cat target ": section count exceeds format limit")))
    (for [i (iterator.range 0 image.sections.len)]
      (match (& (array-ref image.sections.slots i))
        [(Section spec _ _)
          (let
            [error : String
              (compiler-object-layout-section-error
                (& (array-ref image.sections.slots i))
                coff?)]
            (for [j (iterator.range 0 i)]
              (match (& (array-ref image.sections.slots j))
                [(Section prev _ _)
                  (when
                    (= prev.id.value spec.id.value)
                    (set! error "duplicate identity"))
                  (when
                    (string.eq prev.name spec.name)
                    (set! error "duplicate name"))]))
            (when
              (and
                (> i 0)
                (cobj.compiler-object-section-less?
                  (& (array-ref image.sections.slots i))
                  (& (array-ref image.sections.slots (- i 1)))))
              (set! error "sections out of order"))
            (unless
              (string.eq (& error) "")
              (return
                (str_cat.str-cat
                  target
                  ": section "
                  (string.copy spec.name)
                  ": "
                  error))))]))
    (unless
      coff?
      (for [i (iterator.range 0 image.sections.len)]
        (match (& (array-ref image.sections.slots i))
          [(Section spec _ _)
            (when
              (compiler-object-layout-prefix-at? spec.name ".rela" 0)
              (for [j (iterator.range 0 image.sections.len)]
                (match (& (array-ref image.sections.slots j))
                  [(Section other _ _)
                    (when
                      (and
                        (=
                          (string.string-length spec.name)
                          (+ 5 (string.string-length other.name)))
                        (compiler-object-layout-prefix-at?
                          spec.name
                          other.name
                          5))
                      (return
                        (str_cat.str-cat
                          "elf: section collides with relocation table: "
                          (string.copy spec.name))))])))])))
    (for [i (iterator.range 0 image.symbols.len)]
      (match (& (array-ref image.symbols.slots i))
        [(Symbol name _ _ section)
          (match section
            [(Some id)
              (when
                (< (compiler-object-layout-section-index image id) 0)
                (return
                  (str_cat.str-cat
                    target
                    ": undeclared section for symbol "
                    (string.copy name))))]
            [_ unit])]))
    (for [i (iterator.range 0 image.relocations.len)]
      (match (& (array-ref image.relocations.slots i))
        [(Relocation id site _ _)
          (when
            (< (compiler-object-layout-section-index image id) 0)
            (return
              (str_cat.str-cat
                target
                ": undeclared section for relocation "
                (string.copy site))))
          (match (compiler-object-layout-spec image id).storage
            [(ZeroFill _)
              (return
                (str_cat.str-cat
                  target
                  ": relocation in zero-fill section "
                  (string.copy (compiler-object-layout-spec image id).name)))]
            [_ unit])]))
    ""))