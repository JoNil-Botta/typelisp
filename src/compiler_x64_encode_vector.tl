;; SSE, VEX and EVEX instructions share operand signatures and ModRM/SIB.
(import compiler_x64_encode_operands as op)
(import compiler_x64_encode_bytes as enc)
(import compiler_x64_encode_vector_forms as forms)
(import stdlib.sort)
(import stdlib.string)

(define (operand-class [operand : (& op.Operand)]) : char
  (cond
    [(op.imm? operand) 'i']
    [(op.mem? operand)
      (cond
        [(= operand.index.width 16) 's']
        [(= operand.index.width 32) 't']
        [(= operand.index.width 64) 'u']
        [else 'm'])]
    [(= operand.reg.width 0) 'k']
    [(= operand.reg.width 4) 'd']
    [(= operand.reg.width 8) 'q']
    [(= operand.reg.width 16) 'x']
    [(= operand.reg.width 32) 'y']
    [(= operand.reg.width 64) 'z']
    [else '?']))

(defstruct VectorOperands
  (signature i64)
  (count i64)
  (length i64)
  (needs-evex bool)
  (mask i64)
  (zero bool))

(define (classify [ops : (& ops (Array op.Operand 4))] [count : i64]) : VectorOperands
  (let
    [vector (VectorOperands 0 count 0 false 0 false)]
    [i : i64 0]
    (while (< i count)
      (let
        [operand : (& ops op.Operand) (& (array-ref ops i))]
        [class (operand-class operand)]
        (when
          (or
            operand.indirect
            (and (< i (- count 1)) (or operand.zero (> operand.mask 0))))
          (set! vector.count -1)
          (return vector))
        (set! vector.signature (+ (shl vector.signature 8) (cast class : i64)))
        (cond
          [(or (= class 'z') (= class 'u')) (set! vector.length 2)]
          [(and (= vector.length 0) (or (= class 'y') (= class 't')))
            (set! vector.length 1)]
          [else (begin)])
        (when
          (or
            (= vector.length 2)
            (>= operand.reg.number 16)
            (>= operand.index.number 16)
            (> operand.mask 0)
            operand.zero)
          (set! vector.needs-evex true))
        (when
          (= i (- count 1))
          (set! vector.mask operand.mask)
          (set! vector.zero operand.zero)))
      (+= i 1))
    vector))

(define (signature-matches? [signatures : (& str)] [vector : VectorOperands]) : bool
  (let
    [n (string.string-length signatures)]
    [i : i64 0]
    [length : i64 0]
    [signature : i64 0]
    (while (<= i n)
      (let
        [c : char
          (if (= i n)
            ' '
            (string.string-ref signatures i))]
        (if (= c ' ')
          (begin
            (when
              (and (= vector.count length) (= vector.signature signature))
              (return true))
            (set! length 0)
            (set! signature 0))
          (begin
            (+= length 1)
            (set! signature (+ (shl signature 8) (cast c : i64))))))
      (+= i 1))
    false))

(define (form-start [name : (& str)]) : i64
  (let
    [lo : i64 0]
    [hi (length forms.vector-forms)]
    (while (< lo hi)
      (let
        [mid (+ lo (/ (- hi lo) 2))]
        (if (sort.string-less-borrowed?
          (& (array-ref forms.vector-forms mid).name)
          name)
          (set! lo (+ mid 1))
          (set! hi mid))))
    lo))

(define (prefix-byte [pp : i64]) : i64
  (cond [(= pp 1) 0x66] [(= pp 2) 0xf3] [(= pp 3) 0xf2] [else 0]))

(define (emit-vector-prefix!
  [encoder : (&mut enc.Encoding)]
  [form : (& forms.VectorForm)]
  [mode : enc.ModRM]
  [reg : i64]
  [vvvv : i64]
  [length : i64]
  [mask : i64]
  [zero : bool]) : unit
  (let
    [r (- 1 (enc.register-bit reg 3))]
    [x (- 1 mode.x)]
    [b (- 1 mode.b)]
    [head (+ (* r 128) (+ (* x 64) (* b 32)))]
    [v (bit-and (bit-xor vvvv 15) 15)]
    (match form.kind
      [(Vex)
        (if (and (= form.map 1) (= form.w 0) (= mode.x 0) (= mode.b 0))
          (begin
            (enc.emit-byte! encoder 0xc5)
            (enc.emit-byte!
              encoder
              (+ (* r 128) (+ (* v 8) (+ (* length 4) form.pp)))))
          (begin
            (enc.emit-byte! encoder 0xc4)
            (enc.emit-byte! encoder (+ head form.map))
            (enc.emit-byte!
              encoder
              (+ (* form.w 128) (+ (* v 8) (+ (* length 4) form.pp))))))]
      [(Evex)
        (let
          [r-high (- 1 (enc.register-bit reg 4))]
          [v-high
            (-
              1
              (if (>= vvvv 16)
                1
                mode.vsib-high))]
          [z : i64
            (if zero
              128
              0)]
          (enc.emit-byte! encoder 0x62)
          (enc.emit-byte! encoder (+ head (+ (* r-high 16) form.map)))
          (enc.emit-byte! encoder (+ (* form.w 128) (+ (* v 8) (+ 4 form.pp))))
          (enc.emit-byte! encoder (+ z (+ (* length 32) (+ (* v-high 8) mask)))))]
      [_ (begin)])))

(define (form-matches? [form : (& forms.VectorForm)] [vector : VectorOperands]) : bool
  (and
    (or
      (not vector.needs-evex)
      (match form.kind
        [(Evex) true]
        [_ false]))
    (or (= vector.mask 0) (> form.fields.mask 0))
    (or (not (= form.fields.mask 3)) (> vector.mask 0))
    (or (not vector.zero) (and (> vector.mask 0) (= form.fields.mask 2)))
    (signature-matches? (& form.signatures) vector)))

(define (emit-form!
  [encoder : (&mut enc.Encoding)]
  [form : (& forms.VectorForm)]
  [ops : (& ops (Array op.Operand 4))]
  [vector : VectorOperands]) : bool
  (let
    [rm : (& ops op.Operand) (& (array-ref ops form.fields.rm))]
    [reg
      (if (< form.fields.reg 0)
        (enc.group (- -1 form.fields.reg))
        (op.operand-register (& (array-ref ops form.fields.reg))))]
    [vvvv
      (if (< form.fields.vvvv 0)
        0
        (array-ref ops form.fields.vvvv).reg.number)]
    [length
      (if (< form.fields.length 0)
        vector.length
        form.fields.length)]
    [scale
      (if (< form.fields.disp-scale 0)
        (shl (cast 16 : i64) length)
        form.fields.disp-scale)]
    [mode (enc.modrm rm scale)]
    (when
      (and
        (>= rm.index.width 16)
        (or
          (= rm.index.number reg.number)
          (and
            (>= form.fields.vvvv 0)
            (or (= rm.index.number vvvv) (= reg.number vvvv)))))
      (return false))
    (match form.kind
      [(Legacy)
        (enc.emit-legacy!
          encoder
          form.opcode
          form.map
          (prefix-byte form.pp)
          (= form.w 1)
          reg
          rm)]
      [_
        (enc.emit-address-prefix! encoder rm)
        (emit-vector-prefix!
          encoder
          form
          mode
          reg.number
          vvvv
          length
          vector.mask
          vector.zero)
        (enc.emit-byte! encoder form.opcode)
        (enc.emit-modrm! encoder mode reg.number rm)])
    (cond
      [(= form.fields.immediate 0)
        (enc.emit-field! encoder (& (array-ref ops 0)) 1 (Absolute))]
      [(> form.fields.immediate 0)
        (enc.emit-byte!
          encoder
          (shl (array-ref ops (- form.fields.immediate 1)).reg.number 4))]
      [else (begin)])
    true))

(define (encode-vector!
  [encoder : (&mut enc.Encoding)]
  [name : (& str)]
  [ops : (& ops (Array op.Operand 4))]
  [count : i64]) : bool
  (when
    (and (= count 0) (string.eq name "vzeroupper"))
    (enc.emit-byte! encoder 0xc5)
    (enc.emit-byte! encoder 0xf8)
    (enc.emit-byte! encoder 0x77)
    (return true))
  (encode-vector-forms! encoder name ops count (& forms.vector-forms)))

(define (encode-vector-forms!
  [encoder : (&mut enc.Encoding)]
  [name : (& str)]
  [ops : (& ops (Array op.Operand 4))]
  [count : i64]
  [table : (& table (Slice forms.VectorForm))]) : bool
  (let
    [i (form-start name)]
    [n (length table)]
    [vector (classify ops count)]
    (when (< vector.count 0) (return false))
    (while (< i n)
      (let
        [form : (& table forms.VectorForm) (& (array-ref table i))]
        (unless (string.eq name (& form.name)) (return false))
        (when
          (form-matches? form vector)
          (return (emit-form! encoder form ops vector))))
      (+= i 1))
    false))