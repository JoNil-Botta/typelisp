;; Legacy integer, control-flow, and string instructions in final x86-64 text.
(import compiler_x64_encode_operands as op)
(import compiler_x64_encode_bytes as enc)
(import stdlib.string)

(define (gp? [operand : (& op.Operand)] [width : i64]) : bool
  (and (op.reg? operand) (= operand.reg.width width)))

(define (rm? [operand : (& op.Operand)] [width : i64]) : bool
  (or (op.mem? operand) (gp? operand width)))

(define (size-suffix [c : char]) : i64
  (cond [(= c 'b') 1] [(= c 'w') 2] [(= c 'l') 4] [(= c 'q') 8] [else 0]))

(define (condition-code [name : (& str)]) : i64
  (cond
    [(string.eq name "o") 0]
    [(string.eq name "no") 1]
    [(or (string.eq name "b") (string.eq name "c") (string.eq name "nae")) 2]
    [(or (string.eq name "ae") (string.eq name "nb") (string.eq name "nc")) 3]
    [(or (string.eq name "e") (string.eq name "z")) 4]
    [(or (string.eq name "ne") (string.eq name "nz")) 5]
    [(or (string.eq name "be") (string.eq name "na")) 6]
    [(or (string.eq name "a") (string.eq name "nbe")) 7]
    [(string.eq name "s") 8]
    [(string.eq name "ns") 9]
    [(or (string.eq name "p") (string.eq name "pe")) 10]
    [(or (string.eq name "np") (string.eq name "po")) 11]
    [(or (string.eq name "l") (string.eq name "nge")) 12]
    [(or (string.eq name "ge") (string.eq name "nl")) 13]
    [(or (string.eq name "le") (string.eq name "ng")) 14]
    [(or (string.eq name "g") (string.eq name "nle")) 15]
    [else -1]))

(define (one-byte-opcode!
  [encoder : (&mut enc.Encoding)]
  [width : i64]
  [opcode : i64]
  [reg : op.RegisterInfo]) : unit
  (let
    [rex : i64
      (+
        (if (= width 8)
          8
          0)
        (enc.register-bit reg.number 3))]
    (when (= width 2) (enc.emit-byte! encoder 0x66))
    (when
      (or (> rex 0) (enc.needs-byte-rex? reg))
      (enc.emit-byte! encoder (+ 0x40 rex)))
    (enc.emit-byte! encoder (+ opcode (bit-and reg.number 7)))))

(define (arith-group [name : (& str)]) : i64
  (cond
    [(string.eq name "add") 0]
    [(string.eq name "or") 1]
    [(string.eq name "adc") 2]
    [(string.eq name "sbb") 3]
    [(string.eq name "and") 4]
    [(string.eq name "sub") 5]
    [(string.eq name "xor") 6]
    [(string.eq name "cmp") 7]
    [else -1]))

(define (immediate-width [width : i64]) : i64
  (if (< width 4)
    width
    4))

(define (short-immediate? [src : (& op.Operand)] [width : i64]) : bool
  (and
    (not (op.symbolic? src))
    (or
      (enc.signed-fit? src.number 1)
      (and
        (< width 8)
        (let
          [limit (shl (cast 1 : i64) (* width 8))]
          (and (>= src.number (- limit 128)) (< src.number limit)))))))

(define (emit-immediate!
  [encoder : (&mut enc.Encoding)]
  [src : (& op.Operand)]
  [width : i64]
  [short : bool]) : unit
  (if short
    (enc.emit-byte! encoder src.number)
    (enc.emit-field!
      encoder
      src
      (immediate-width width)
      (if (= width 8)
        (SignedAbsolute)
        (Absolute)))))

(define (alu!
  [encoder : (&mut enc.Encoding)]
  [width : i64]
  [group : i64]
  [src : (& op.Operand)]
  [dst : (& op.Operand)]) : bool
  (let
    [byte-lane : i64
      (if (= width 1)
        0
        1)]
    [opcode (+ (* group 8) byte-lane)]
    (cond
      [(and (op.imm? src) (rm? dst width))
        (let
          [short (and (> width 1) (short-immediate? src width))]
          (if (and (not short) (gp? dst width) (= dst.reg.number 0))
            (one-byte-opcode!
              encoder
              width
              (+ opcode 4)
              (op.operand-register dst))
            (enc.emit-scalar!
              encoder
              (cond [(= width 1) 0x80] [short 0x83] [else 0x81])
              0
              width
              (enc.group group)
              dst))
          (emit-immediate! encoder src width short)
          true)]
      [(and (gp? src width) (rm? dst width))
        (enc.emit-scalar! encoder opcode 0 width (op.operand-register src) dst)
        true]
      [(and (op.mem? src) (gp? dst width))
        (enc.emit-scalar!
          encoder
          (+ opcode 2)
          0
          width
          (op.operand-register dst)
          src)
        true]
      [else false])))

(define (test!
  [encoder : (&mut enc.Encoding)]
  [width : i64]
  [src : (& op.Operand)]
  [dst : (& op.Operand)]) : bool
  (let
    [byte-lane : i64
      (if (= width 1)
        0
        1)]
    (cond
      [(and (op.imm? src) (rm? dst width))
        (if (and (gp? dst width) (= dst.reg.number 0))
          (one-byte-opcode!
            encoder
            width
            (+ 0xa8 byte-lane)
            (op.operand-register dst))
          (enc.emit-scalar!
            encoder
            (+ 0xf6 byte-lane)
            0
            width
            (enc.group 0)
            dst))
        (enc.emit-field!
          encoder
          src
          (immediate-width width)
          (if (= width 8)
            (SignedAbsolute)
            (Absolute)))
        true]
      [(and (gp? src width) (rm? dst width))
        (enc.emit-scalar!
          encoder
          (+ 0x84 byte-lane)
          0
          width
          (op.operand-register src)
          dst)
        true]
      [(and (op.mem? src) (gp? dst width))
        (enc.emit-scalar!
          encoder
          (+ 0x84 byte-lane)
          0
          width
          (op.operand-register dst)
          src)
        true]
      [else false])))

(define (move!
  [encoder : (&mut enc.Encoding)]
  [width : i64]
  [absolute : bool]
  [src : (& op.Operand)]
  [dst : (& op.Operand)]) : bool
  (let
    [byte-lane : i64
      (if (= width 1)
        0
        1)]
    (cond
      [(and (op.imm? src) (rm? dst width))
        (let
          [long
            (or
              absolute
              (and
                (= width 8)
                (not (op.symbolic? src))
                (not (enc.signed-fit? src.number 4))))]
          (when (and long (not (gp? dst 8))) (return false))
          (if (and (gp? dst width) (or long (< width 8)))
            (begin
              (one-byte-opcode!
                encoder
                width
                (if (= width 1)
                  0xb0
                  0xb8)
                (op.operand-register dst))
              (enc.emit-field! encoder src width (Absolute)))
            (begin
              (enc.emit-scalar!
                encoder
                (+ 0xc6 byte-lane)
                0
                width
                (enc.group 0)
                dst)
              (enc.emit-field!
                encoder
                src
                (immediate-width width)
                (if (= width 8)
                  (SignedAbsolute)
                  (Absolute))))))
        true]
      [absolute false]
      [(and (gp? src width) (rm? dst width))
        (enc.emit-scalar!
          encoder
          (+ 0x88 byte-lane)
          0
          width
          (op.operand-register src)
          dst)
        true]
      [(and (op.mem? src) (gp? dst width))
        (enc.emit-scalar!
          encoder
          (+ 0x8a byte-lane)
          0
          width
          (op.operand-register dst)
          src)
        true]
      [else false])))

(define (extend-move!
  [encoder : (&mut enc.Encoding)]
  [name : (& name str)]
  [src : (& op.Operand)]
  [dst : (& op.Operand)]) : bool
  (unless
    (and
      (= (string.string-length name) 6)
      (string.is-string-prefix-at name "mov" 0))
    (return false))
  (let
    [sign (= (string.string-ref name 3) 's')]
    [from (size-suffix (string.string-ref name 4))]
    [to (size-suffix (string.string-ref name 5))]
    (unless
      (and
        (or sign (= (string.string-ref name 3) 'z'))
        (> from 0)
        (> to from)
        (rm? src from)
        (gp? dst to))
      (return false))
    (if (= from 4)
      (if sign
        (enc.emit-scalar! encoder 0x63 0 to (op.operand-register dst) src)
        (return false))
      (let
        [opcode : i64
          (+
            (if sign
              0xbe
              0xb6)
            (if (= from 2)
              1
              0))]
        (enc.emit-scalar! encoder opcode 1 to (op.operand-register dst) src)))
    true))

(define (unary-group [name : (& str)]) : i64
  (cond
    [(string.eq name "not") 2]
    [(string.eq name "neg") 3]
    [(string.eq name "mul") 4]
    [(string.eq name "imul") 5]
    [(string.eq name "div") 6]
    [(string.eq name "idiv") 7]
    [else -1]))

(define (shift-group [name : (& str)]) : i64
  (cond
    [(string.eq name "rol") 0]
    [(string.eq name "ror") 1]
    [(string.eq name "rcl") 2]
    [(string.eq name "rcr") 3]
    [(or (string.eq name "shl") (string.eq name "sal")) 4]
    [(string.eq name "shr") 5]
    [(string.eq name "sar") 7]
    [else -1]))

(define (shift!
  [encoder : (&mut enc.Encoding)]
  [width : i64]
  [group : i64]
  [count : i64]
  [src : (& op.Operand)]
  [dst : (& op.Operand)]) : bool
  (let
    [byte-lane : i64
      (if (= width 1)
        0
        1)]
    (cond
      [(and (= count 1) (rm? src width))
        (enc.emit-scalar!
          encoder
          (+ 0xd0 byte-lane)
          0
          width
          (enc.group group)
          src)
        true]
      [(and (= count 2) (rm? dst width))
        (cond
          [(and (gp? src 1) (= src.reg.number 1))
            (enc.emit-scalar!
              encoder
              (+ 0xd2 byte-lane)
              0
              width
              (enc.group group)
              dst)]
          [(and (op.imm? src) (not (op.symbolic? src)) (= src.number 1))
            (enc.emit-scalar!
              encoder
              (+ 0xd0 byte-lane)
              0
              width
              (enc.group group)
              dst)]
          [(op.imm? src)
            (enc.emit-scalar!
              encoder
              (+ 0xc0 byte-lane)
              0
              width
              (enc.group group)
              dst)
            (enc.emit-field! encoder src 1 (Absolute))]
          [else (return false)])
        true]
      [else false])))

(define (stack!
  [encoder : (&mut enc.Encoding)]
  [push : bool]
  [width : i64]
  [src : (& op.Operand)]) : bool
  (unless (or (= width 2) (= width 8)) (return false))
  (cond
    [(gp? src width)
      (one-byte-opcode!
        encoder
        (if (= width 8)
          4
          2)
        (if push
          0x50
          0x58)
        (op.operand-register src))
      true]
    [(op.mem? src)
      (enc.emit-legacy!
        encoder
        (if push
          0xff
          0x8f)
        0
        (enc.prefix-for-width width)
        false
        (enc.group
          (if push
            6
            0))
        src)
      true]
    [(and push (op.imm? src))
      (let
        [short (short-immediate? src width)]
        (when (= width 2) (enc.emit-byte! encoder 0x66))
        (enc.emit-byte!
          encoder
          (if short
            0x6a
            0x68))
        (emit-immediate! encoder src width short))
      true]
    [else false]))

(define (branch!
  [encoder : (&mut enc.Encoding)]
  [name : (& name str)]
  [width : enc.X64BranchWidth]
  [target : (& op.Operand)]) : bool
  (let
    [call (or (string.eq name "call") (string.eq name "callq"))]
    [jump (or (string.eq name "jmp") (string.eq name "jmpq"))]
    [cc
      (if (and
        (> (string.string-length name) 1)
        (= (string.string-ref name 0) 'j'))
        (condition-code
          (& (string.substring name 1 (- (string.string-length name) 1))))
        -1)]
    (unless (or call jump (>= cc 0)) (return false))
    (if target.indirect
      (when
        (and (or call jump) (rm? target 8))
        (enc.emit-legacy!
          encoder
          0xff
          0
          0
          false
          (enc.group
            (if call
              2
              4))
          target)
        (return true))
      (when
        (and
          (op.mem? target)
          (not target.rip)
          (< target.base 0)
          (< target.index.number 0)
          (= target.segment 0))
        (let
          [short
            (and
              (not call)
              (match width
                [(Short) true]
                [_ false]))]
          (cond
            [call (enc.emit-byte! encoder 0xe8)]
            [jump
              (enc.emit-byte!
                encoder
                (if short
                  0xeb
                  0xe9))]
            [short (enc.emit-byte! encoder (+ 0x70 cc))]
            [else
              (enc.emit-byte! encoder 0x0f)
              (enc.emit-byte! encoder (+ 0x80 cc))])
          (let
            [field-width : i64
              (if short
                1
                4)]
            (if (op.symbolic? target)
              (enc.emit-fixup!
                encoder
                (& target.expression)
                field-width
                (BranchRelative))
              (let
                [target-text (string.int->string target.number)]
                (enc.emit-fixup!
                  encoder
                  (& target-text)
                  field-width
                  (BranchRelative)))))
          (return true))))
    false))

;; Simple instructions whose operands are implicit in the emitted dialect.
(define (implicit-opcode [name : (& str)]) : i64
  (cond
    [(or (string.eq name "ret") (string.eq name "retq")) 0xc3]
    [(string.eq name "leave") 0xc9]
    [(string.eq name "nop") 0x90]
    [(string.eq name "int3") 0xcc]
    [(string.eq name "hlt") 0xf4]
    [(string.eq name "cld") 0xfc]
    [(string.eq name "std") 0xfd]
    [(string.eq name "syscall") 0x0f05]
    [(string.eq name "ud2") 0x0f0b]
    [(string.eq name "pause") 0xf390]
    [(or (string.eq name "cbw") (string.eq name "cbtw")) 0x6698]
    [(or (string.eq name "cwde") (string.eq name "cwtl")) 0x98]
    [(or (string.eq name "cltq") (string.eq name "cdqe")) 0x4898]
    [(or (string.eq name "cwd") (string.eq name "cwtd")) 0x6699]
    [(or (string.eq name "cdq") (string.eq name "cltd")) 0x99]
    [(or (string.eq name "cqto") (string.eq name "cqo")) 0x4899]
    [(string.eq name "cpuid") 0x0fa2]
    [(string.eq name "xgetbv") 0x0f01d0]
    [(string.eq name "rdtsc") 0x0f31]
    [(string.eq name "rdtscp") 0x0f01f9]
    [(string.eq name "lfence") 0x0faee8]
    [(string.eq name "mfence") 0x0faef0]
    [(string.eq name "sfence") 0x0faef8]
    [(string.eq name "endbr64") 0xf30f1efa]
    [else -1]))

(define (string-opcode [name : (& name str)]) : i64
  (let
    [n (string.string-length name)]
    (unless (= n 5) (return -1))
    (let
      [stem : String (string.substring name 0 4)]
      [width (size-suffix (string.string-ref name 4))]
      [opcode : i64
        (cond
          [(string.eq (& stem) "movs") 0xa4]
          [(string.eq (& stem) "stos") 0xaa]
          [(string.eq (& stem) "cmps") 0xa6]
          [(string.eq (& stem) "scas") 0xae]
          [(string.eq (& stem) "lods") 0xac]
          [else -1])]
      (if (or (< opcode 0) (= width 0))
        -1
        (cond
          [(= width 1) opcode]
          [(= width 2) (+ 0x6600 (+ opcode 1))]
          [(= width 8) (+ 0x4800 (+ opcode 1))]
          [else (+ opcode 1)])))))

(define (emit-packed-opcode! [encoder : (&mut enc.Encoding)] [opcode : i64]) : unit
  (let
    [shift : i64 24]
    (while (> shift 0)
      (when
        (> (shr opcode shift) 0)
        (enc.emit-byte! encoder (shr opcode shift)))
      (-= shift 8))
    (enc.emit-byte! encoder opcode)))

(define (lockable? [name : (& str)] [count : i64] [dst : (& op.Operand)]) : bool
  (and
    (op.mem? dst)
    (or
      (and
        (= count 1)
        (or
          (string.eq name "inc")
          (string.eq name "dec")
          (string.eq name "neg")
          (string.eq name "not")))
      (and
        (= count 2)
        (or
          (and (>= (arith-group name) 0) (< (arith-group name) 7))
          (string.eq name "cmpxchg")
          (string.eq name "xadd")
          (string.eq name "xchg")
          (string.eq name "bts")
          (string.eq name "btr")
          (string.eq name "btc"))))))

(define (bit-opcode [name : (& str)]) : i64
  (cond
    [(string.eq name "bt") 0xa3]
    [(string.eq name "bts") 0xab]
    [(string.eq name "btr") 0xb3]
    [(string.eq name "btc") 0xbb]
    [else -1]))

(define (encode-integer!
  [encoder : (&mut enc.Encoding)]
  [stem : (& str)]
  [width : i64]
  [count : i64]
  [a : (& args op.Operand)]
  [b : (& args op.Operand)]
  [c : (& args op.Operand)]) : bool
  (let
    [byte-lane : i64
      (if (= width 1)
        0
        1)]
    [arith (arith-group stem)]
    [unary (unary-group stem)]
    [shift (shift-group stem)]
    [bit (bit-opcode stem)]
    (cond
      [(>= shift 0) (shift! encoder width shift count a b)]
      [(and (= count 1) (rm? a width))
        (cond
          [(or (string.eq stem "push") (string.eq stem "pop"))
            (stack! encoder (string.eq stem "push") width a)]
          [(>= unary 0)
            (enc.emit-scalar!
              encoder
              (+ 0xf6 byte-lane)
              0
              width
              (enc.group unary)
              a)
            true]
          [(or (string.eq stem "inc") (string.eq stem "dec"))
            (enc.emit-scalar!
              encoder
              (+ 0xfe byte-lane)
              0
              width
              (enc.group
                (if (string.eq stem "inc")
                  0
                  1))
              a)
            true]
          [(and (string.eq stem "bswap") (gp? a width) (>= width 4))
            (let
              [rex : i64
                (+
                  (if (= width 8)
                    8
                    0)
                  (enc.register-bit a.reg.number 3))]
              (when (> rex 0) (enc.emit-byte! encoder (+ 0x40 rex)))
              (enc.emit-byte! encoder 0x0f)
              (enc.emit-byte! encoder (+ 0xc8 (bit-and a.reg.number 7))))
            true]
          [else false])]
      [(and (= count 1) (string.eq stem "push")) (stack! encoder true width a)]
      [(and (= count 2) (>= arith 0)) (alu! encoder width arith a b)]
      [(and (= count 2) (string.eq stem "test")) (test! encoder width a b)]
      [(and (= count 2) (string.eq stem "mov")) (move! encoder width false a b)]
      [(and
        (= count 2)
        (string.eq stem "lea")
        (> width 1)
        (op.mem? a)
        (gp? b width))
        (enc.emit-scalar! encoder 0x8d 0 width (op.operand-register b) a)
        true]
      [(and
        (= count 2)
        (> width 1)
        (string.eq stem "imul")
        (rm? a width)
        (gp? b width))
        (enc.emit-scalar! encoder 0xaf 1 width (op.operand-register b) a)
        true]
      [(and
        (or (= count 2) (= count 3))
        (> width 1)
        (string.eq stem "imul")
        (op.imm? a)
        (rm? b width))
        (let
          [dst : (& args op.Operand)
            (if (= count 3)
              c
              b)]
          (unless (gp? dst width) (return false))
          (let
            [short (short-immediate? a width)]
            (enc.emit-scalar!
              encoder
              (if short
                0x6b
                0x69)
              0
              width
              (op.operand-register dst)
              b)
            (emit-immediate! encoder a width short)))
        true]
      [(and
        (= count 2)
        (gp? a width)
        (rm? b width)
        (or
          (string.eq stem "xchg")
          (string.eq stem "xadd")
          (string.eq stem "cmpxchg")))
        (cond
          [(string.eq stem "xchg")
            (if (and
              (> width 1)
              (gp? b width)
              (or (= a.reg.number 0) (= b.reg.number 0))
              (or (not (= width 4)) (not (= a.reg.number b.reg.number))))
              (one-byte-opcode!
                encoder
                width
                0x90
                (if (= a.reg.number 0)
                  (op.operand-register b)
                  (op.operand-register a)))
              (enc.emit-scalar!
                encoder
                (+ 0x86 byte-lane)
                0
                width
                (op.operand-register a)
                b))]
          [(string.eq stem "xadd")
            (enc.emit-scalar!
              encoder
              (+ 0xc0 byte-lane)
              1
              width
              (op.operand-register a)
              b)]
          [else
            (enc.emit-scalar!
              encoder
              (+ 0xb0 byte-lane)
              1
              width
              (op.operand-register a)
              b)])
        true]
      [(and (= count 2) (op.mem? a) (gp? b width) (string.eq stem "xchg"))
        (enc.emit-scalar!
          encoder
          (+ 0x86 byte-lane)
          0
          width
          (op.operand-register b)
          a)
        true]
      [(and
        (= count 2)
        (> width 1)
        (rm? a width)
        (gp? b width)
        (or (string.eq stem "bsf") (string.eq stem "bsr")))
        (enc.emit-scalar!
          encoder
          (if (string.eq stem "bsf")
            0xbc
            0xbd)
          1
          width
          (op.operand-register b)
          a)
        true]
      [(and (= count 2) (> width 1) (>= bit 0) (rm? b width))
        (cond
          [(gp? a width)
            (enc.emit-scalar! encoder bit 1 width (op.operand-register a) b)]
          [(op.imm? a)
            (enc.emit-scalar!
              encoder
              0xba
              1
              width
              (enc.group (+ 4 (/ (- bit 0xa3) 8)))
              b)
            (enc.emit-field! encoder a 1 (Absolute))]
          [else (return false)])
        true]
      [else false])))

(define (encode-scalar!
  [encoder : (&mut enc.Encoding)]
  [name : (& name str)]
  [prefix : i64]
  [branch-width : enc.X64BranchWidth]
  [count : i64]
  [ops : (& ops (Array op.Operand 4))]) : bool
  (let
    [a : (& ops op.Operand) (& (array-ref ops 0))]
    [b : (& ops op.Operand) (& (array-ref ops 1))]
    [c : (& ops op.Operand) (& (array-ref ops 2))]
    [n (string.string-length name)]
    (when
      (= count 0)
      (let
        [strings (string-opcode name)]
        [opcode
          (if (>= strings 0)
            strings
            (implicit-opcode name))]
        (unless
          (and
            (>= opcode 0)
            (or (= prefix 0) (and (>= strings 0) (not (= prefix 0xf0)))))
          (return false))
        (when (> prefix 0) (enc.emit-byte! encoder prefix))
        (emit-packed-opcode! encoder opcode)
        (return true)))
    (when (and (> prefix 0) (not (= prefix 0xf0))) (return false))
    (when (= n 0) (return false))
    (let
      [suffix : i64
        (if (or
          (string.eq name "sub")
          (string.eq name "sbb")
          (string.eq name "shl")
          (string.eq name "sal")
          (string.eq name "mul")
          (string.eq name "imul"))
          0
          (size-suffix (string.string-ref name (- n 1))))]
      [stem : String
        (string.substring
          name
          0
          (if (> suffix 0)
            (- n 1)
            n))]
      [width : i64
        (cond
          [(> suffix 0) suffix]
          [(op.reg? b) b.reg.width]
          [(op.reg? a) a.reg.width]
          [else 8])]
      (when
        (= prefix 0xf0)
        (unless
          (lockable?
            (& stem)
            count
            (if (= count 1)
              a
              b))
          (return false))
        (enc.emit-byte! encoder prefix))
      (cond
        [(and (= count 1) (= prefix 0) (branch! encoder name branch-width a))
          true]
        [(and
          (= count 1)
          (= prefix 0)
          (> n 3)
          (rm? a 1)
          (string.is-string-prefix-at name "set" 0))
          (let
            [cc (condition-code (& (string.substring name 3 (- n 3))))]
            (when (< cc 0) (return false))
            (enc.emit-scalar! encoder (+ 0x90 cc) 1 1 (enc.group 0) a))
          true]
        [(and
          (= count 2)
          (= prefix 0)
          (> n 4)
          (gp? b b.reg.width)
          (<= 2 b.reg.width)
          (<= b.reg.width 8)
          (rm? a b.reg.width)
          (string.is-string-prefix-at name "cmov" 0))
          (let
            [cc (condition-code (& (string.substring name 4 (- n 4))))]
            (when
              (and (< cc 0) (> n 5) (= suffix b.reg.width))
              (set! cc (condition-code (& (string.substring name 4 (- n 5))))))
            (when (< cc 0) (return false))
            (enc.emit-scalar!
              encoder
              (+ 0x40 cc)
              1
              b.reg.width
              (op.operand-register b)
              a))
          true]
        [(and (= count 2) (= prefix 0) (string.eq name "movabsq"))
          (move! encoder 8 true a b)]
        [(and (= count 2) (= prefix 0) (extend-move! encoder name a b)) true]
        [(and (> width 0) (<= width 8))
          (encode-integer! encoder (& stem) width count a b c)]
        [else false]))))