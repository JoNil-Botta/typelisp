;; compiler_object_layout.tl - Section layout and x64 encoding shared by the
;; ELF and COFF object writers: little-endian byte pushers, section sizes and
;; label offsets, text instruction encodings and their rel32 fixups, and the
;; relocation-list checks both formats apply.
(import compiler_owned_view as owned_view)
(import stdlib.byte_buf_core)
(import stdlib.string)
(import compiler_object as cobj)

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
  (begin
    (compiler-object-layout-push-u8! out value)
    (compiler-object-layout-push-u8! out (shr value 8))))

(define (compiler-object-layout-push-u32!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [value : i64]) : unit
  (begin
    (compiler-object-layout-push-u8! out value)
    (compiler-object-layout-push-u8! out (shr value 8))
    (compiler-object-layout-push-u8! out (shr value 16))
    (compiler-object-layout-push-u8! out (shr value 24))))

(define (compiler-object-layout-push-u64!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [value : i64]) : unit
  (begin
    (compiler-object-layout-push-u32! out value)
    (compiler-object-layout-push-u32! out (shr value 32))))

(define (compiler-object-layout-push-zeroes!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [count : i64]) : unit
  (let
    [i : i64 0]
    (begin
      (while (< i count)
        (begin
          (compiler-object-layout-push-u8! out 0)
          (set! i (+ i 1))))
      unit)))

(define (compiler-object-layout-push-string-bytes!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [text : (& text str)]) : unit
  (let
    [i : i64 0]
    [n : i64 (compiler-object-layout-string-length text)]
    (begin
      (while (< i n)
        (begin
          (byte_buf_core.byte-buf-builder-push
            out
            (cast (compiler-object-layout-string-ref text i) : u8))
          (set! i (+ i 1))))
      unit)))

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
(define compiler-object-layout-section-count : i64
  7)

(define (compiler-object-layout-section-at [index : i64]) : cobj.CompilerObjectSectionKind
  (cond
    [(= index 0) (cobj.CompilerObjectSectionKind.Text)]
    [(= index 1) (cobj.CompilerObjectSectionKind.Data)]
    [(= index 2) (cobj.CompilerObjectSectionKind.Rodata)]
    [(= index 3) (cobj.CompilerObjectSectionKind.Bss)]
    [(= index 4) (cobj.CompilerObjectSectionKind.Pdata)]
    [(= index 5) (cobj.CompilerObjectSectionKind.Xdata)]
    [else (cobj.CompilerObjectSectionKind.Rsrc)]))

(define (compiler-object-layout-section-index
  [kind : cobj.CompilerObjectSectionKind]) : i64
  (match kind
    [(cobj.CompilerObjectSectionKind.Text) 0]
    [(cobj.CompilerObjectSectionKind.Data) 1]
    [(cobj.CompilerObjectSectionKind.Rodata) 2]
    [(cobj.CompilerObjectSectionKind.Bss) 3]
    [(cobj.CompilerObjectSectionKind.Pdata) 4]
    [(cobj.CompilerObjectSectionKind.Xdata) 5]
    [(cobj.CompilerObjectSectionKind.Rsrc) 6]))

(define (compiler-object-layout-data-records-size-from
  [records : cobj.CompilerObjectDataRecordList]
  [offset : i64]) : i64
  (let
    [count : i64 (cobj.compiler-object-data-record-list-count records)]
    [index : i64 0]
    [cur-offset : i64 offset]
    (begin
      (while (< index count)
        (begin
          (set!
            cur-offset
            (cobj.compiler-object-data-record-end-offset
              (cobj.compiler-object-data-record-list-ref records index)
              cur-offset))
          (set! index (+ index 1))))
      cur-offset)))

(define (compiler-object-layout-data-records-size
  [records : cobj.CompilerObjectDataRecordList]) : i64
  (compiler-object-layout-data-records-size-from records 0))

(define (compiler-object-layout-instr-size
  [instr : cobj.CompilerObjectX64Instr]) : i64
  (match instr
    [(cobj.CompilerObjectX64Instr.Label _) 0]
    [(cobj.CompilerObjectX64Instr.Call _) 5]
    [(cobj.CompilerObjectX64Instr.TailCall _) 5]
    [(cobj.CompilerObjectX64Instr.Jump _) 5]
    [(cobj.CompilerObjectX64Instr.Ja _) 6]
    [(cobj.CompilerObjectX64Instr.Branch _ _) 14]
    [(cobj.CompilerObjectX64Instr.SubRspImm8 _) 4]
    [(cobj.CompilerObjectX64Instr.MovRcxRax) 3]
    [(cobj.CompilerObjectX64Instr.XorpdRip _) 8]
    [(cobj.CompilerObjectX64Instr.Bytes bytes)
      (compiler-object-layout-string-length bytes)]
    [(cobj.CompilerObjectX64Instr.Raw bytes)
      (compiler-object-layout-string-length bytes)]
    ;; The rest are REX + opcode + ModRM rip-relative forms with a rel32.
    [_ 7]))

;; The rel32 fields of one text instruction and the symbols they target.
;; Each field is the instruction's last four bytes, except that Branch
;; (`test %rax; jnz true; jmp false`) has its jnz field at bytes 5..8.
(defenum CompilerObjectLayoutFixup
  (None)
  (One cobj.CompilerObjectRelocationKind String)
  (Branch String String))

(define (compiler-object-layout-instr-fixup
  [instr : cobj.CompilerObjectX64Instr]) : CompilerObjectLayoutFixup
  (match instr
    [(cobj.CompilerObjectX64Instr.Call target)
      (CompilerObjectLayoutFixup.One
        (cobj.CompilerObjectRelocationKind.Call)
        target)]
    [(cobj.CompilerObjectX64Instr.TailCall target)
      (CompilerObjectLayoutFixup.One
        (cobj.CompilerObjectRelocationKind.TailCall)
        target)]
    [(cobj.CompilerObjectX64Instr.Jump target)
      (CompilerObjectLayoutFixup.One
        (cobj.CompilerObjectRelocationKind.Branch)
        target)]
    [(cobj.CompilerObjectX64Instr.Ja target)
      (CompilerObjectLayoutFixup.One
        (cobj.CompilerObjectRelocationKind.Branch)
        target)]
    [(cobj.CompilerObjectX64Instr.Branch true-target false-target)
      (CompilerObjectLayoutFixup.Branch true-target false-target)]
    [(cobj.CompilerObjectX64Instr.LoadRip target)
      (CompilerObjectLayoutFixup.One
        (cobj.CompilerObjectRelocationKind.RipValue)
        target)]
    [(cobj.CompilerObjectX64Instr.MovRcxRip target)
      (CompilerObjectLayoutFixup.One
        (cobj.CompilerObjectRelocationKind.RipValue)
        target)]
    [(cobj.CompilerObjectX64Instr.MovRdxRip target)
      (CompilerObjectLayoutFixup.One
        (cobj.CompilerObjectRelocationKind.RipValue)
        target)]
    [(cobj.CompilerObjectX64Instr.XorpdRip target)
      (CompilerObjectLayoutFixup.One
        (cobj.CompilerObjectRelocationKind.RipValue)
        target)]
    [(cobj.CompilerObjectX64Instr.LoadRipAddress target)
      (CompilerObjectLayoutFixup.One
        (cobj.CompilerObjectRelocationKind.RipAddress)
        target)]
    [(cobj.CompilerObjectX64Instr.LoadRipAddressR11 target)
      (CompilerObjectLayoutFixup.One
        (cobj.CompilerObjectRelocationKind.RipAddress)
        target)]
    [(cobj.CompilerObjectX64Instr.StoreRip target)
      (CompilerObjectLayoutFixup.One
        (cobj.CompilerObjectRelocationKind.RipAddress)
        target)]
    [(cobj.CompilerObjectX64Instr.LoadRipAddressRdx target)
      (CompilerObjectLayoutFixup.One
        (cobj.CompilerObjectRelocationKind.RipAddress)
        target)]
    [(cobj.CompilerObjectX64Instr.StoreR14Rip target)
      (CompilerObjectLayoutFixup.One
        (cobj.CompilerObjectRelocationKind.RipAddress)
        target)]
    [(cobj.CompilerObjectX64Instr.StoreR15Rip target)
      (CompilerObjectLayoutFixup.One
        (cobj.CompilerObjectRelocationKind.RipAddress)
        target)]
    [(cobj.CompilerObjectX64Instr.AddRcxRip target)
      (CompilerObjectLayoutFixup.One
        (cobj.CompilerObjectRelocationKind.RipAddress)
        target)]
    [_ (CompilerObjectLayoutFixup.None)]))

(define (compiler-object-layout-instr-relocation-count
  [instr : cobj.CompilerObjectX64Instr]) : i64
  (match (compiler-object-layout-instr-fixup instr)
    [(CompilerObjectLayoutFixup.None) 0]
    [(CompilerObjectLayoutFixup.One _ _) 1]
    [(CompilerObjectLayoutFixup.Branch _ _) 2]))

(define (compiler-object-layout-instrs-relocation-count
  [instrs : cobj.CompilerObjectX64InstrList]) : i64
  (let
    [count : i64 (cobj.compiler-object-instr-list-count instrs)]
    [index : i64 0]
    [total : i64 0]
    (begin
      (while (< index count)
        (begin
          (set!
            total
            (+
              total
              (compiler-object-layout-instr-relocation-count
                (cobj.compiler-object-instr-list-ref instrs index))))
          (set! index (+ index 1))))
      total)))

(define (compiler-object-layout-instrs-size-from
  [instrs : cobj.CompilerObjectX64InstrList]
  [offset : i64]) : i64
  (let
    [count : i64 (cobj.compiler-object-instr-list-count instrs)]
    [index : i64 0]
    [cur-offset : i64 offset]
    (begin
      (while (< index count)
        (begin
          (set!
            cur-offset
            (+
              cur-offset
              (compiler-object-layout-instr-size
                (cobj.compiler-object-instr-list-ref instrs index))))
          (set! index (+ index 1))))
      cur-offset)))

(define (compiler-object-layout-instrs-size
  [instrs : cobj.CompilerObjectX64InstrList]) : i64
  (compiler-object-layout-instrs-size-from instrs 0))

(define (compiler-object-layout-section-virtual-size
  [image : (& image cobj.CompilerObjectImage)]
  [kind : cobj.CompilerObjectSectionKind]) : i64
  (match (cobj.compiler-object-section-list-find image.sections kind)
    [(cobj.CompilerObjectSection.Section _ data instrs)
      (match kind
        [(cobj.CompilerObjectSectionKind.Text)
          (compiler-object-layout-instrs-size instrs)]
        [_ (compiler-object-layout-data-records-size data)])]))

(define (compiler-object-layout-section-raw-size
  [image : (& image cobj.CompilerObjectImage)]
  [kind : cobj.CompilerObjectSectionKind]) : i64
  (match kind
    [(cobj.CompilerObjectSectionKind.Bss) 0]
    [_ (compiler-object-layout-section-virtual-size image kind)]))

;; Text relocations are the instruction fixup kinds. Data sections carry
;; absolute addresses, plus image-relative 32-bit ones where the format has
;; them (COFF's ADDR32NB, used by unwind and resource tables).
(define (compiler-object-layout-relocation-supported?
  [reloc : cobj.CompilerObjectRelocation]
  [addr32nb : bool]) : bool
  (match reloc
    [(cobj.CompilerObjectRelocation.Relocation section _ kind _)
      (match section
        [(cobj.CompilerObjectSectionKind.Text)
          (match kind
            [(cobj.CompilerObjectRelocationKind.Call) true]
            [(cobj.CompilerObjectRelocationKind.TailCall) true]
            [(cobj.CompilerObjectRelocationKind.RipValue) true]
            [(cobj.CompilerObjectRelocationKind.RipAddress) true]
            [(cobj.CompilerObjectRelocationKind.Branch) true]
            [_ false])]
        [_
          (match kind
            [(cobj.CompilerObjectRelocationKind.Abs64) true]
            [(cobj.CompilerObjectRelocationKind.Addr32Nb) addr32nb]
            [_ false])])]))

(define (compiler-object-layout-relocation-list-supported?
  [relocs : (& relocs cobj.CompilerObjectRelocationList)]
  [addr32nb : bool]) : bool
  (let
    [count : i64 (cobj.compiler-object-relocation-list-count relocs)]
    [index : i64 0]
    [ok : bool true]
    (begin
      (while (and ok (< index count))
        (if (compiler-object-layout-relocation-supported?
          (cobj.compiler-object-relocation-list-ref relocs index)
          addr32nb)
          (set! index (+ index 1))
          (set! ok false)))
      ok)))

(define (compiler-object-layout-data-label-offset-from
  [records : cobj.CompilerObjectDataRecordList]
  [label : String]
  [offset : i64]) : i64
  (let
    [count : i64 (cobj.compiler-object-data-record-list-count records)]
    [index : i64 0]
    [cur-offset : i64 offset]
    [result : i64 -1]
    [done : bool false]
    (begin
      (while (and (not done) (< index count))
        (let
          [record : cobj.CompilerObjectDataRecord
            (cobj.compiler-object-data-record-list-ref records index)]
          (match (owned_view.compiler-owned-shared-view record)
            [(cobj.CompilerObjectDataRecord.Label found)
              (if (string.eq found label)
                (begin
                  (set! result cur-offset)
                  (set! done true))
                (set! index (+ index 1)))]
            [_
              (begin
                (set!
                  cur-offset
                  (cobj.compiler-object-data-record-end-offset
                    record
                    cur-offset))
                (set! index (+ index 1)))])))
      result)))

(define (compiler-object-layout-instr-label-offset-from
  [instrs : cobj.CompilerObjectX64InstrList]
  [label : String]
  [offset : i64]) : i64
  (let
    [count : i64 (cobj.compiler-object-instr-list-count instrs)]
    [index : i64 0]
    [cur-offset : i64 offset]
    [result : i64 -1]
    [done : bool false]
    (begin
      (while (and (not done) (< index count))
        (let
          [instr : cobj.CompilerObjectX64Instr
            (cobj.compiler-object-instr-list-ref instrs index)]
          (match (owned_view.compiler-owned-shared-view instr)
            [(cobj.CompilerObjectX64Instr.Label found)
              (if (string.eq found label)
                (begin
                  (set! result cur-offset)
                  (set! done true))
                (set! index (+ index 1)))]
            [_
              (begin
                (set!
                  cur-offset
                  (+ cur-offset (compiler-object-layout-instr-size instr)))
                (set! index (+ index 1)))])))
      result)))

(define (compiler-object-layout-section-label-offset
  [image : (& image cobj.CompilerObjectImage)]
  [kind : cobj.CompilerObjectSectionKind]
  [label : String]) : i64
  (match (cobj.compiler-object-section-list-find image.sections kind)
    [(cobj.CompilerObjectSection.Section _ data instrs)
      (match kind
        [(cobj.CompilerObjectSectionKind.Text)
          (compiler-object-layout-instr-label-offset-from instrs label 0)]
        [_ (compiler-object-layout-data-label-offset-from data label 0)])]))

(define (compiler-object-layout-symbol-value
  [image : (& image cobj.CompilerObjectImage)]
  [name : String]
  [section : cobj.CompilerObjectMaybeSection]) : i64
  (match section
    [(cobj.CompilerObjectMaybeSection.No) 0]
    [(cobj.CompilerObjectMaybeSection.Some kind)
      (let
        [offset : i64
          (compiler-object-layout-section-label-offset image kind name)]
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
    (begin
      (while (and (not found) (< index count))
        (match (cobj.compiler-object-symbol-list-ref symbols index)
          [(cobj.CompilerObjectSymbol.Symbol symbol-name _ _ _)
            (if (string.eq symbol-name name)
              (set! found true)
              (set! index (+ index 1)))]))
      found)))

(define (compiler-object-layout-text-targets-known?
  [image : (& image cobj.CompilerObjectImage)]) : bool
  (match (cobj.compiler-object-section-list-find
    image.sections
    (cobj.CompilerObjectSectionKind.Text))
    [(cobj.CompilerObjectSection.Section _ _ instrs)
      (let
        [count : i64 (cobj.compiler-object-instr-list-count instrs)]
        [index : i64 0]
        [ok : bool true]
        (begin
          (while (and ok (< index count))
            (begin
              (set!
                ok
                (match (compiler-object-layout-instr-fixup
                  (cobj.compiler-object-instr-list-ref instrs index))
                  [(CompilerObjectLayoutFixup.None) true]
                  [(CompilerObjectLayoutFixup.One _ target)
                    (compiler-object-layout-symbol-known? image.symbols target)]
                  [(CompilerObjectLayoutFixup.Branch true-target false-target)
                    (and
                      (compiler-object-layout-symbol-known?
                        image.symbols
                        true-target)
                      (compiler-object-layout-symbol-known?
                        image.symbols
                        false-target))]))
              (set! index (+ index 1))))
          ok))]))

(define (compiler-object-layout-text-instr-relocation-count
  [image : (& image cobj.CompilerObjectImage)]) : i64
  (match (cobj.compiler-object-section-list-find
    image.sections
    (cobj.CompilerObjectSectionKind.Text))
    [(cobj.CompilerObjectSection.Section _ _ instrs)
      (compiler-object-layout-instrs-relocation-count instrs)]))

(define (compiler-object-layout-relocation-count
  [relocs : (& relocs cobj.CompilerObjectRelocationList)]
  [kind : cobj.CompilerObjectSectionKind]) : i64
  (let
    [count : i64 (cobj.compiler-object-relocation-list-count relocs)]
    [index : i64 0]
    [total : i64 0]
    (begin
      (while (< index count)
        (begin
          (match (cobj.compiler-object-relocation-list-ref relocs index)
            [(cobj.CompilerObjectRelocation.Relocation section _ _ _)
              (if (cobj.compiler-object-section-kind-eq? section kind)
                (set! total (+ total 1))
                unit)])
          (set! index (+ index 1))))
      total)))

(define (compiler-object-layout-section-relocation-count
  [image : (& image cobj.CompilerObjectImage)]
  [kind : cobj.CompilerObjectSectionKind]) : i64
  (match kind
    [(cobj.CompilerObjectSectionKind.Text)
      (compiler-object-layout-text-instr-relocation-count image)]
    [_ (compiler-object-layout-relocation-count image.relocations kind)]))

(define (compiler-object-layout-text-relocation-count-matches?
  [image : (& image cobj.CompilerObjectImage)]) : bool
  (=
    (compiler-object-layout-relocation-count
      image.relocations
      (cobj.CompilerObjectSectionKind.Text))
    (compiler-object-layout-text-instr-relocation-count image)))

(define (compiler-object-layout-render-data-record!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [record : cobj.CompilerObjectDataRecord]
  [offset : i64]) : i64
  (match record
    [(cobj.CompilerObjectDataRecord.Label _) offset]
    [(cobj.CompilerObjectDataRecord.Align align)
      (let
        [aligned : i64 (compiler-object-layout-align-offset offset align)]
        (begin
          (compiler-object-layout-push-zeroes! out (- aligned offset))
          aligned))]
    [(cobj.CompilerObjectDataRecord.Bytes bytes)
      (begin
        (compiler-object-layout-push-string-bytes! out bytes)
        (+ offset (compiler-object-layout-string-length bytes)))]
    [(cobj.CompilerObjectDataRecord.String text)
      (begin
        (compiler-object-layout-push-string-bytes! out text)
        (compiler-object-layout-push-u8! out 0)
        (cobj.compiler-object-data-record-end-offset
          (cobj.CompilerObjectDataRecord.String text)
          offset))]
    [(cobj.CompilerObjectDataRecord.F64 bits)
      (begin
        (compiler-object-layout-push-u64! out (cast bits : i64))
        (+ offset 8))]
    [(cobj.CompilerObjectDataRecord.F32 bits)
      (begin
        (compiler-object-layout-push-u32! out (cast bits : i64))
        (+ offset 4))]
    [(cobj.CompilerObjectDataRecord.I64 value)
      (begin
        (compiler-object-layout-push-u64! out value)
        (+ offset 8))]
    [(cobj.CompilerObjectDataRecord.Zero count)
      (begin
        (compiler-object-layout-push-zeroes! out count)
        (+ offset count))]
    [(cobj.CompilerObjectDataRecord.SymbolAddress _)
      (begin
        (compiler-object-layout-push-u64! out 0)
        (+ offset 8))]
    [(cobj.CompilerObjectDataRecord.SymbolRva32 _)
      (begin
        (compiler-object-layout-push-u32! out 0)
        (+ offset 4))]))

(define (compiler-object-layout-render-data-records!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [records : cobj.CompilerObjectDataRecordList]
  [offset : i64]) : i64
  (let
    [count : i64 (cobj.compiler-object-data-record-list-count records)]
    [index : i64 0]
    [cur-offset : i64 offset]
    (begin
      (while (< index count)
        (begin
          (set!
            cur-offset
            (compiler-object-layout-render-data-record!
              out
              (cobj.compiler-object-data-record-list-ref records index)
              cur-offset))
          (set! index (+ index 1))))
      cur-offset)))

;; Push the bytes HEX spells, two hex digits per byte.
(define (compiler-object-layout-push-hex!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [hex : (& hex str)]) : unit
  (let
    [i : i64 0]
    [n : i64 (compiler-object-layout-string-length hex)]
    (begin
      (while (< (+ i 1) n)
        (begin
          (compiler-object-layout-push-u8!
            out
            (+
              (* 16 (compiler-object-layout-hex-digit hex i))
              (compiler-object-layout-hex-digit hex (+ i 1))))
          (set! i (+ i 2))))
      unit)))

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
  (begin
    (compiler-object-layout-push-hex! out opcode)
    (compiler-object-layout-push-u32! out 0)))

(define (compiler-object-layout-render-instr!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [instr : cobj.CompilerObjectX64Instr]) : unit
  (match instr
    [(cobj.CompilerObjectX64Instr.Label _) unit]
    [(cobj.CompilerObjectX64Instr.Call _)
      (compiler-object-layout-push-rel32-instr! out "e8")]
    [(cobj.CompilerObjectX64Instr.TailCall _)
      (compiler-object-layout-push-rel32-instr! out "e9")]
    [(cobj.CompilerObjectX64Instr.Jump _)
      (compiler-object-layout-push-rel32-instr! out "e9")]
    [(cobj.CompilerObjectX64Instr.Ja _)
      (compiler-object-layout-push-rel32-instr! out "0f87")]
    [(cobj.CompilerObjectX64Instr.Branch _ _)
      (begin
        (compiler-object-layout-push-rel32-instr! out "4885c00f85")
        (compiler-object-layout-push-rel32-instr! out "e9"))]
    [(cobj.CompilerObjectX64Instr.LoadRip _)
      (compiler-object-layout-push-rel32-instr! out "488b05")]
    [(cobj.CompilerObjectX64Instr.LoadRipAddress _)
      (compiler-object-layout-push-rel32-instr! out "488d05")]
    [(cobj.CompilerObjectX64Instr.LoadRipAddressR11 _)
      (compiler-object-layout-push-rel32-instr! out "4c8d1d")]
    [(cobj.CompilerObjectX64Instr.StoreRip _)
      (compiler-object-layout-push-rel32-instr! out "488905")]
    [(cobj.CompilerObjectX64Instr.SubRspImm8 imm)
      (begin
        (compiler-object-layout-push-hex! out "4883ec")
        (compiler-object-layout-push-u8! out imm))]
    [(cobj.CompilerObjectX64Instr.MovRcxRip _)
      (compiler-object-layout-push-rel32-instr! out "488b0d")]
    [(cobj.CompilerObjectX64Instr.MovRdxRip _)
      (compiler-object-layout-push-rel32-instr! out "488b15")]
    [(cobj.CompilerObjectX64Instr.LoadRipAddressRdx _)
      (compiler-object-layout-push-rel32-instr! out "488d15")]
    [(cobj.CompilerObjectX64Instr.StoreR14Rip _)
      (compiler-object-layout-push-rel32-instr! out "4c8935")]
    [(cobj.CompilerObjectX64Instr.StoreR15Rip _)
      (compiler-object-layout-push-rel32-instr! out "4c893d")]
    [(cobj.CompilerObjectX64Instr.AddRcxRip _)
      (compiler-object-layout-push-rel32-instr! out "48010d")]
    [(cobj.CompilerObjectX64Instr.MovRcxRax)
      (compiler-object-layout-push-hex! out "4889c1")]
    [(cobj.CompilerObjectX64Instr.XorpdRip _)
      (compiler-object-layout-push-rel32-instr! out "660f5705")]
    [(cobj.CompilerObjectX64Instr.Bytes bytes)
      (compiler-object-layout-push-string-bytes! out bytes)]
    [(cobj.CompilerObjectX64Instr.Raw bytes)
      (compiler-object-layout-push-string-bytes! out bytes)]))

(define (compiler-object-layout-render-instrs!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [instrs : cobj.CompilerObjectX64InstrList]) : unit
  (let
    [count : i64 (cobj.compiler-object-instr-list-count instrs)]
    [index : i64 0]
    (begin
      (while (< index count)
        (begin
          (compiler-object-layout-render-instr!
            out
            (cobj.compiler-object-instr-list-ref instrs index))
          (set! index (+ index 1))))
      unit)))

(define (compiler-object-layout-render-section!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [image : (& image cobj.CompilerObjectImage)]
  [kind : cobj.CompilerObjectSectionKind]) : unit
  (match (cobj.compiler-object-section-list-find image.sections kind)
    [(cobj.CompilerObjectSection.Section _ data instrs)
      (match kind
        [(cobj.CompilerObjectSectionKind.Text)
          (compiler-object-layout-render-instrs! out instrs)]
        [_
          (begin
            (compiler-object-layout-render-data-records! out data 0)
            unit)])]))

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
        (begin
          (while ok
            (if (< i needle-len)
              (if (=
                (compiler-object-layout-string-ref text (+ start i))
                (compiler-object-layout-string-ref needle i))
                (set! i (+ i 1))
                (set! ok false))
              (set! ok false)))
          (= i needle-len))))))

(define (compiler-object-layout-contains?
  [text : (& text str)]
  [needle : String]) : bool
  (let
    [i : i64 0]
    [n : i64 (compiler-object-layout-string-length text)]
    [found : bool false]
    (begin
      (while (and (not found) (< i n))
        (begin
          (if (compiler-object-layout-prefix-at? text needle i)
            (set! found true)
            unit)
          (set! i (+ i 1))))
      found)))