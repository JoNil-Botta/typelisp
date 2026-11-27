;; Shared encoding machinery, independent of symbols and section layout.
(import compiler_x64_encode_operands as operand)
(import stdlib.byte_le)
(import stdlib.string)

(defenum X64BranchWidth
  (Near)
  (Short))

(defenum X64RelocationIntent
  (Absolute)
  (SignedAbsolute)
  (PcRelative)
  (BranchRelative))

(defstruct X64Fixup
  (field-offset i64)
  (width i64)
  (intent X64RelocationIntent)
  (expression String)
  (instruction-end i64))

(defstruct X64EncodedInstruction
  (fixup-count i64)
  (fixups (Array X64Fixup 2)))

(defenum X64EncodeResult
  (Ok X64EncodedInstruction)
  (Err String))

(defstruct Encoding
  (bytes (Array u8 15))
  (length i64)
  (fixup-count i64)
  (fixups (Array X64Fixup 2))
  (valid bool))

(define (new-encoding) : Encoding
  (Encoding
    (make-array u8 15)
    0
    0
    (array (X64Fixup 0 0 (Absolute) "" 0) (X64Fixup 0 0 (Absolute) "" 0))
    true))

(define (emit-byte! [enc : (&mut Encoding)] [byte : i64]) : unit
  (if (< enc.length 15)
    (begin
      (set! (array-ref enc.bytes enc.length) (cast byte : u8))
      (+= enc.length 1))
    (set! enc.valid false)))

(define (emit-le! [enc : (&mut Encoding)] [value : i64] [width : i64]) : unit
  (let
    [i : i64 0]
    (while (< i width)
      (emit-byte! enc (cast (byte_le.byte-le-byte value (* i 8)) : i64))
      (+= i 1))))

(define (signed-fit? [value : i64] [width : i64]) : bool
  (or
    (= width 8)
    (let
      [limit : i64 (shl 1 (- (* width 8) 1))]
      (and (>= value (- 0 limit)) (< value limit)))))

(define (bit-pattern-fit? [value : i64] [width : i64]) : bool
  (or
    (signed-fit? value width)
    (and (>= value 0) (< value (shl (cast 1 : i64) (* width 8))))))

(define (emit-fixup!
  [enc : (&mut Encoding)]
  [expression : (& str)]
  [width : i64]
  [intent : X64RelocationIntent]) : unit
  (if (< enc.fixup-count 2)
    (let
      [fixup (X64Fixup enc.length width intent (string.copy expression) 0)]
      (set! (array-ref enc.fixups enc.fixup-count) fixup)
      (+= enc.fixup-count 1)
      (emit-le! enc 0 width))
    (set! enc.valid false)))

(define (emit-field!
  [enc : (&mut Encoding)]
  [op : (& operand.Operand)]
  [width : i64]
  [intent : X64RelocationIntent]) : unit
  (if (operand.symbolic? op)
    (emit-fixup! enc (& op.expression) width intent)
    (let
      [fits
        (match intent
          [(Absolute) (bit-pattern-fit? op.number width)]
          [_ (signed-fit? op.number width)])]
      (if fits
        (emit-le! enc op.number width)
        (set! enc.valid false)))))

;; The same ModRM/SIB layout is used by legacy, VEX and EVEX instructions.
;; For register-direct EVEX, the r/m high extension occupies X rather than B.
(defstruct ModRM
  (mod i64)
  (rm i64)
  (sib i64)
  (disp-width i64)
  (disp-scale i64)
  (b i64)
  (x i64)
  (vsib-high i64))

(define (register-bit [reg : i64] [bit : i64]) : i64
  (bit-and (shr reg bit) 1))

(define (modrm [rm : (& operand.Operand)] [disp-scale : i64]) : ModRM
  (cond
    [(operand.reg? rm)
      (ModRM
        3
        (bit-and rm.reg.number 7)
        -1
        0
        1
        (register-bit rm.reg.number 3)
        (register-bit rm.reg.number 4)
        0)]
    [rm.rip (ModRM 0 5 -1 4 1 0 0 0)]
    [else
      (let
        [has-base (>= rm.base 0)]
        [has-index (>= rm.index.number 0)]
        [base
          (if has-base
            (bit-and rm.base 7)
            5)]
        [index
          (if has-index
            (bit-and rm.index.number 7)
            4)]
        [use-sib (or has-index (not has-base) (= base 4))]
        [width : i64
          (cond
            [(or (not has-base) (operand.symbolic? rm)) 4]
            [(and (= rm.number 0) (not (= base 5))) 0]
            [(and
                (= (% rm.number disp-scale) 0)
                (signed-fit? (/ rm.number disp-scale) 1))
              1]
            [else 4])]
        (ModRM
          (if has-base
            (if (= width 4)
              2
              width)
            0)
          (if use-sib
            4
            base)
          (if use-sib
            (+ (* rm.scale 64) (+ (* index 8) base))
            -1)
          width
          disp-scale
          (if has-base
            (register-bit rm.base 3)
            0)
          (if has-index
            (register-bit rm.index.number 3)
            0)
          (if has-index
            (register-bit rm.index.number 4)
            0)))]))

(define (emit-modrm!
  [enc : (&mut Encoding)]
  [modrm : ModRM]
  [reg : i64]
  [rm : (& operand.Operand)]) : unit
  (emit-byte! enc (+ (* modrm.mod 64) (+ (* (bit-and reg 7) 8) modrm.rm)))
  (when (>= modrm.sib 0) (emit-byte! enc modrm.sib))
  (cond
    [(= modrm.disp-width 1) (emit-byte! enc (/ rm.number modrm.disp-scale))]
    [(= modrm.disp-width 4)
      (emit-field!
        enc
        rm
        4
        (cond
          [rm.rip (PcRelative)]
          [rm.address32 (Absolute)]
          [else (SignedAbsolute)]))]
    [else (begin)]))

(define (emit-address-prefix!
  [enc : (&mut Encoding)]
  [rm : (& operand.Operand)]) : unit
  (when (> rm.segment 0) (emit-byte! enc rm.segment))
  (when rm.address32 (emit-byte! enc 0x67)))

(define (needs-byte-rex? [reg : operand.RegisterInfo]) : bool
  (and (= reg.width 1) (>= reg.number 4) (not reg.high-byte)))

(define (emit-legacy!
  [enc : (&mut Encoding)]
  [opcode : i64]
  [map : i64]
  [prefix : i64]
  [wide : bool]
  [reg : operand.RegisterInfo]
  [rm : (& operand.Operand)]) : unit
  (unless
    (and
      (or (operand.reg? rm) (operand.mem? rm))
      (< reg.number 16)
      (< rm.reg.number 16)
      (<= rm.index.width 8))
    (set! enc.valid false)
    (return unit))
  (let
    [mode (modrm rm 1)]
    [rex : i64
      (+
        (if wide
          8
          0)
        (+ (* 4 (register-bit reg.number 3)) (+ (* 2 mode.x) mode.b)))]
    (emit-address-prefix! enc rm)
    (when (> prefix 0) (emit-byte! enc prefix))
    (when
      (or
        (> rex 0)
        (needs-byte-rex? reg)
        (needs-byte-rex? (operand.operand-register rm)))
      (if (or reg.high-byte rm.reg.high-byte)
        (set! enc.valid false)
        (emit-byte! enc (+ 0x40 rex))))
    (when (> map 0) (emit-byte! enc 0x0f))
    (when
      (> map 1)
      (emit-byte!
        enc
        (if (= map 2)
          0x38
          0x3a)))
    (emit-byte! enc opcode)
    (emit-modrm! enc mode reg.number rm)))

(define (group [number : i64]) : operand.RegisterInfo
  (operand.RegisterInfo number 0 false))

(define (prefix-for-width [width : i64]) : i64
  (if (= width 2)
    0x66
    0))

(define (emit-scalar!
  [enc : (&mut Encoding)]
  [opcode : i64]
  [map : i64]
  [width : i64]
  [reg : operand.RegisterInfo]
  [rm : (& operand.Operand)]) : unit
  (emit-legacy! enc opcode map (prefix-for-width width) (= width 8) reg rm))