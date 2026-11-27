;; Encode one complete compiler-emitted Linux x86-64 instruction.
(import compiler_machine_x64 as machine)
(import compiler_x64_encode_bytes as enc)
(import compiler_x64_encode_operands as op)
(import compiler_x64_encode_scalar as scalar)
(import compiler_x64_encode_vector as vector)
(import stdlib.byte_buf_core)
(import stdlib.str_cat_runtime as str_cat)
(import stdlib.string)

(define (word-end-at [text : (& str)] [start : i64]) : i64
  (let
    [n (string.string-length text)]
    [i : i64 start]
    (while (and
      (< i n)
      (not (string.is-char-whitespace (string.string-ref text i))))
      (+= i 1))
    i))

(define (word-end [text : (& str)]) : i64
  (word-end-at text 0))

(define (parse-operands!
  [ops : (&mut (Array op.Operand 4))]
  [text : (& text str)]) : i64
  (let
    [end (string.string-length text)]
    [start : i64 0]
    [i : i64 0]
    [count : i64 0]
    [inside-address false]
    (when (= end 0) (return 0))
    (while (<= i end)
      (let
        [c : char
          (if (= i end)
            ','
            (string.string-ref text i))]
        (cond
          [(= c '(')
            (when inside-address (return -1))
            (set! inside-address true)]
          [(= c ')')
            (unless inside-address (return -1))
            (set! inside-address false)]
          [(and (= c ',') (not inside-address))
            (when (>= count 4) (return -1))
            (let
              [operand (op.parse-operand (& (op.range text start i)))]
              (unless (op.valid? (& operand)) (return -1))
              (set! (array-ref ops count) operand))
            (+= count 1)
            (set! start (+ i 1))]
          [else (begin)]))
      (+= i 1))
    (if inside-address
      -1
      count)))

(define (prefix-byte [word : (& str)]) : i64
  (cond
    [(string.eq word "lock") 0xf0]
    [(or (string.eq word "rep") (string.eq word "repe") (string.eq word "repz"))
      0xf3]
    [(or (string.eq word "repne") (string.eq word "repnz")) 0xf2]
    [else 0]))

(define (scalar-operands?
  [name : (& name str)]
  [ops : (& ops (Array op.Operand 4))]
  [count : i64]) : bool
  (let
    [i : i64 0]
    (while (< i count)
      (let
        [operand : (& ops op.Operand) (& (array-ref ops i))]
        (when
          (or
            (> operand.mask 0)
            operand.zero
            (and
              operand.indirect
              (not
                (or
                  (string.eq name "call")
                  (string.eq name "callq")
                  (string.eq name "jmp")
                  (string.eq name "jmpq")))))
          (return false)))
      (+= i 1))
    true))

(define (encode-text!
  [encoder : (&mut enc.Encoding)]
  [line : (& line str)]
  [branch-width : enc.X64BranchWidth]) : bool
  (let
    [comment (string.index-of-byte line 0 35)]
    [text : String
      (op.range
        line
        0
        (if (< comment 0)
          (string.string-length line)
          comment))]
    [head-end (word-end (& text))]
    [head : String (op.range (& text) 0 head-end)]
    [prefix (prefix-byte (& head))]
    [body : String
      (if (= prefix 0)
        text
        (op.range (& text) head-end (string.string-length (& text))))]
    [name-end (word-end (& body))]
    [name : String (op.range (& body) 0 name-end)]
    [ops
      (array
        (op.empty-operand)
        (op.empty-operand)
        (op.empty-operand)
        (op.empty-operand))]
    [count
      (parse-operands!
        (&mut ops)
        (& (op.range (& body) name-end (string.string-length (& body)))))]
    (and
      (>= count 0)
      (or
        (and
          (scalar-operands? (& name) (& ops) count)
          (scalar.encode-scalar!
            encoder
            (& name)
            prefix
            branch-width
            count
            (& ops)))
        (and
          (= prefix 0)
          (= encoder.length 0)
          (vector.encode-vector! encoder (& name) (& ops) count))))))

;: Append the instruction bytes to a caller-owned sink. Fixup offsets are
;: relative to the start of that sink, and the width is in bytes. A diagnostic
;: leaves the sink untouched. Direct branches use the selected width, with
;: calls always using a 32-bit displacement.
(define (x64-encode-instruction!
  [out : (&mut byte_buf_core.ByteBufBuilder)]
  [line : (& line str)]
  [branch-width : enc.X64BranchWidth]) : enc.X64EncodeResult
  (let
    [encoder (enc.new-encoding)]
    (unless
      (and (encode-text! (&mut encoder) line branch-width) encoder.valid)
      (return
        (Err
          (str_cat.str-cat
            "x86-64: unsupported instruction or operands: "
            (string.copy line)))))
    (let
      [start (byte_buf_core.byte-buf-builder-len out)]
      [end (+ start encoder.length)]
      [i : i64 0]
      (while (< i encoder.length)
        (machine.compiler-machine-x64-push!
          out
          (cast (array-ref encoder.bytes i) : i64))
        (+= i 1))
      (set! i 0)
      (while (< i encoder.fixup-count)
        (+= (array-ref encoder.fixups i).field-offset start)
        (set! (array-ref encoder.fixups i).instruction-end end)
        (+= i 1))
      (Ok (enc.X64EncodedInstruction encoder.fixup-count encoder.fixups)))))