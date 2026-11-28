(import compiler_linux_asm_layout as layout)
(import compiler_linux_asm_symbols as sym)
(import compiler_x64_encode_bytes as enc)
(import stdlib.string)
(import stdlib.str_cat_runtime as str_cat)
(import stdlib.byte_buf_core as buf)
(import stdlib.byte_le)

;; ELF special sections are kept distinct from image-local section IDs.
(define undefined : i64
  -1)
(define absolute : i64
  -2)
(define common : i64
  -3)

(defstruct Value
  (section i64)
  (offset i64))

(defstruct Values
  (items (__tl_dyn-array Value))
  (state (__tl_dyn-array i64))
  (base (__tl_dyn-array i64)))

(defenum ResultValue
  (Ok Value)
  (Err String))

(defenum ResultValues
  (Ok Values)
  (Err String))

(define (at-position [image : (& layout.Image)] [p : (& sym.Position)]) : Value
  (if (< p.section 0)
    (Value undefined 0)
    (Value
      p.section
      (layout.label-address (& (array-ref image.items.slots p.section)) p))))

(define (term!
  [image : (& layout.Image)]
  [values : (&mut Values)]
  [id : i64]
  [dot : (& Value)]) : ResultValue
  (cond
    [(= id -1) (Ok (Value absolute 0))]
    [(= id -2) (Ok (Value dot.section dot.offset))]
    [else (resolve! image values id)]))

(define (evaluate!
  [image : (& layout.Image)]
  [values : (&mut Values)]
  [expr : (& sym.Expression)]
  [dot : (& Value)]) : ResultValue
  (let
    [a (try (term! image values expr.positive dot))]
    [b (try (term! image values expr.negative dot))]
    [n (+ (- a.offset b.offset) expr.constant)]
    (cond
      [(= b.section absolute) (Ok (Value a.section n))]
      [(and (>= a.section 0) (= a.section b.section)) (Ok (Value absolute n))]
      [else (Err "unresolvable symbol difference")])))

(define (resolve!
  [image : (& img layout.Image)]
  [values : (&mut Values)]
  [id : i64]) : ResultValue
  (let
    [state (array-ref values.state id)]
    (when
      (= state 2)
      (return
        (Ok
          (Value
            (array-ref values.items id).section
            (array-ref values.items id).offset))))
    (when (= state 1) (return (Err "cycle in .set definitions"))))
  (set! (array-ref values.state id) 1)
  (let
    [s : (& img sym.Symbol) (& (array-ref image.table.entries.slots id))]
    [at (at-position image (& s.position))]
    [value
      (cond
        [s.is-alias (try (evaluate! image values (& s.alias) (& at)))]
        [(> s.common-align 0) (Value common s.common-align)]
        [else at])]
    (when
      (and s.numeric-label (= value.section undefined))
      (return (Err "undefined numeric local label")))
    (set!
      (array-ref values.base id)
      (if (and s.is-alias (= value.section undefined) (>= s.alias.positive 0))
        (array-ref values.base s.alias.positive)
        id))
    (set! (array-ref values.items id) value)
    (set! (array-ref values.state id) 2)
    (Ok value)))

(define (resolve-all [image : (& layout.Image)]) : ResultValues
  (let
    [n image.table.entries.len]
    [i : i64 0]
    [values
      (Values
        (__tl_make-array Value n)
        (__tl_make-array i64 n)
        (__tl_make-array i64 n))]
    (while (< i n)
      (let
        [_resolved (try (resolve! image (&mut values) i))]
        (+= i 1)))
    (Ok values)))

(define (type-code
  [width : i64]
  [modifier : (& str)]
  [pc : bool]
  [branch : bool]
  [signed : bool]) : i64
  (cond
    [(string.eq modifier "")
      (cond
        [(and branch (= width 4)) 4]
        [pc
          (match width
            [1 15]
            [2 13]
            [4 2]
            [8 24]
            [_ -1])]
        [else
          (match width
            [1 14]
            [2 12]
            [4
              (if signed
                11
                10)]
            [8 1]
            [_ -1])])]
    [(and (= width 4) pc)
      (cond
        [(string.eq modifier "PLT") 4]
        [(string.eq modifier "GOTPCREL") 9]
        [(string.eq modifier "TLSGD") 19]
        [(string.eq modifier "TLSLD") 20]
        [(string.eq modifier "GOTTPOFF") 22]
        [else -1])]
    [(and (= width 4) (not pc))
      (cond
        [(string.eq modifier "TPOFF") 23]
        [(string.eq modifier "DTPOFF") 21]
        [(string.eq modifier "GOT") 3]
        [else -1])]
    [(and (= width 8) (not pc))
      (cond
        [(string.eq modifier "TPOFF") 18]
        [(string.eq modifier "DTPOFF") 17]
        [(string.eq modifier "GOTOFF") 25]
        [else -1])]
    [else -1]))

(define (coff-type [width : i64] [modifier : (& str)] [pc : bool]) : i64
  (cond
    [(and (not pc) (= width 4) (string.eq modifier "IMGREL")) 3]
    [(not (string.eq modifier "")) -1]
    [(and pc (= width 4)) 4]
    [pc -1]
    [(= width 4) 2]
    [(= width 8) 1]
    [else -1]))

(define (patch!
  [out : (&mut buf.ByteBufBuilder)]
  [at : i64]
  [width : i64]
  [value : i64]
  [pc : bool]) : layout.Status
  (unless
    (if pc
      (enc.signed-fit? value width)
      (enc.bit-pattern-fit? value width))
    (return (Err "assembly field overflow")))
  (let
    [i : i64 0]
    (while (< i width)
      (set! (array-ref out.slots (+ at i)) (byte_le.byte-le-byte value (* i 8)))
      (+= i 1)))
  (Ok unit))

(define (apply-fields!
  [image : (&mut img layout.Image)]
  [id : i64]
  [values : (&mut Values)]
  [out : (&mut buf.ByteBufBuilder)]) : layout.Status
  (let
    [i : i64 0]
    (while (< i (array-ref image.items.slots id).fixups.len)
      (let
        [f : (& img layout.Field)
          (& (array-ref (array-ref image.items.slots id).fixups.slots i))]
        [at
          (+
            (array-ref (array-ref image.items.slots id).runs.slots f.fragment).address
            f.delta)]
        [dot (Value id at)]
        [a (try (term! image values f.expression.positive (& dot)))]
        [b (try (term! image values f.expression.negative (& dot)))]
        [signed
          (match f.intent
            [(SignedAbsolute) true]
            [_ false])]
        [branch
          (match f.intent
            [(BranchRelative) true]
            [_ false])]
        [pc
          (match f.intent
            [(or (BranchRelative) (PcRelative)) true]
            [_ false])]
        [addend f.expression.constant]
        [target f.expression.positive]
        [modifier : (& img str) (& f.expression.modifier)]
        [local
          (or
            (< target 0)
            (and
              (>= a.section 0)
              (<= (array-ref image.table.entries.slots target).binding 0)))]
        (when pc (-= addend f.end-distance))
        (cond
          [(and
              (>= a.section 0)
              (= a.section b.section)
              (not pc)
              (string.eq modifier ""))
            (try (patch! out at f.width (+ (- a.offset b.offset) addend) false))]
          [(and
              pc
              (= a.section id)
              (or local image.coff)
              (string.eq modifier "")
              (= b.section absolute))
            (try
              (patch!
                out
                at
                f.width
                (+ (- a.offset at) (- addend b.offset))
                true))]
          [(and
              (= a.section absolute)
              (= b.section absolute)
              (not pc)
              (string.eq modifier ""))
            (try (patch! out at f.width (+ (- a.offset b.offset) addend) false))]
          [else
            (cond
              [(= b.section absolute) (-= addend b.offset)]
              [(and (= b.section id) (not pc))
                (set! pc true)
                (+= addend (- at b.offset))]
              [else
                (return (Err "ELF cannot represent this expression difference"))])
            (let
              [destination : layout.RelaTarget
                (cond
                  [(= target -2)
                    (+= addend at)
                    (SectionAddress id)]
                  [(= a.section absolute)
                    (+= addend a.offset)
                    (AbsoluteZero)]
                  [(= a.section undefined)
                    (+= addend a.offset)
                    (set! target (array-ref values.base target))
                    (Named target)]
                  [else (Named target)])]
              [ty
                (if image.coff
                  (coff-type f.width modifier pc)
                  (type-code
                    f.width
                    modifier
                    pc
                    (and branch (not local) (!= a.section absolute))
                    signed))]
              (when
                (< ty 0)
                (return
                  (Err
                    (str_cat.str-cat
                      "unsupported relocation modifier or width: "
                      (string.copy modifier)))))
              (when (and image.coff pc) (+= addend 4))
              (when (= ty 9) (set! ty f.got-type))
              (when
                (and (not image.coff) (>= target 0))
                (when
                  (and (>= ty 17) (<= ty 23))
                  (set! (array-ref image.table.entries.slots target).kind 6))
                (when
                  (or
                    (not (string.eq modifier ""))
                    (and
                      (>= a.section 0)
                      (!=
                        0
                        (bit-and
                          (array-ref image.items.slots a.section).flags
                          16))))
                  (set!
                    (array-ref image.table.entries.slots target).retain-name
                    true)))
              (layout.add-rela!
                (&mut (array-ref image.items.slots id))
                at
                destination
                ty
                addend))]))
      (+= i 1))
    (Ok unit)))