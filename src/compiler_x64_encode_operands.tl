;; Operand parsing for the compiler's final AT&T instruction text.
(import stdlib.string)
(import compiler_abi as abi)

(defenum OperandKind
  (Invalid)
  (Register)
  (Immediate)
  (Memory))

;; Register number is the hardware field number. Width is in bytes, with
;; width 0 for opmask registers. The high-byte aliases need special REX rules.
(defstruct RegisterInfo
  (number i64)
  (width i64)
  (high-byte bool))

(defstruct Operand
  (kind OperandKind)
  (reg RegisterInfo)
  (base i64)
  (index RegisterInfo)
  (scale i64)
  (rip bool)
  (address32 bool)
  (segment i64)
  (indirect bool)
  (number i64)
  (expression String)
  (mask i64)
  (zero bool))

(defenum IntegerLiteral
  (Integer i64)
  (Symbolic)
  (IntegerOverflow))

(define (digit [c : char]) : i64
  (cond
    [(and (>= c '0') (<= c '9')) (- (cast c : i64) 48)]
    [(and (>= c 'a') (<= c 'f')) (- (cast c : i64) 87)]
    [(and (>= c 'A') (<= c 'F')) (- (cast c : i64) 55)]
    [else -1]))

(define (integer-literal [text : (& text str)]) : IntegerLiteral
  (let
    [n (string.string-length text)]
    (when (= n 0) (return (Integer 0)))
    (let
      [first (string.string-ref text 0)]
      [negative (= first '-')]
      [i : i64
        (if (or negative (= first '+'))
          1
          0)]
      [radix : u64 10]
      [value : u64 0]
      [overflow false]
      (when
        (and (< (+ i 1) n) (= (string.string-ref text i) '0'))
        (let
          [c (string.string-ref text (+ i 1))]
          (when (or (= c 'x') (= c 'X')) (set! radix 16) (+= i 2))))
      (when (= i n) (return (Symbolic)))
      (while (< i n)
        (let
          [d (digit (string.string-ref text i))]
          (unless (and (>= d 0) (< (cast d : u64) radix)) (return (Symbolic)))
          (let
            [part (cast d : u64)]
            (if (> value (/ (- 0xffffffffffffffff part) radix))
              (set! overflow true)
              (set! value (+ (* value radix) part)))))
        (+= i 1))
      (cond
        [(or overflow (and negative (> value 0x8000000000000000)))
          (IntegerOverflow)]
        [negative (Integer (cast (- (cast 0 : u64) value) : i64))]
        [else (Integer (cast value : i64))]))))

(define (missing-register) : RegisterInfo
  (RegisterInfo -1 0 false))

(define (register [text : (& text str)]) : RegisterInfo
  (let
    [n (string.string-length text)]
    (when
      (or (< n 2) (not (= (string.string-ref text 0) '%')))
      (return (missing-register)))
    (let
      [gp (abi.compiler-abi-gp-register-id-from-spelling text)]
      (when (>= gp 0) (return (RegisterInfo gp 8 false))))
    (let
      [head (string.string-ref text 1)]
      (when
        (and (> n 4) (or (= head 'x') (= head 'y') (= head 'z')))
        (when
          (and
            (= (string.string-ref text 2) 'm')
            (= (string.string-ref text 3) 'm'))
          (match (integer-literal (& (string.substring text 4 (- n 4))))
            [(Integer idx)
              (when
                (and (>= idx 0) (< idx abi.compiler-reg-id-family-count))
                (return
                  (RegisterInfo
                    idx
                    (if (= head 'x')
                      16
                      (if (= head 'y')
                        32
                        64))
                    false)))]
            [_ (begin)])))
      (when
        (and (= head 'k') (= n 3))
        (let
          [idx (digit (string.string-ref text 2))]
          (when
            (and (>= idx 0) (< idx abi.compiler-reg-id-mask-count))
            (return (RegisterInfo idx 0 false)))))
      (let
        [last (string.string-ref text (- n 1))]
        (when
          (and (= head 'r') (or (= last 'b') (= last 'w') (= last 'd')))
          (let
            [gp
              (abi.compiler-abi-gp-register-id-from-spelling
                (& (string.substring text 0 (- n 1))))]
            (when
              (>= gp 8)
              (return
                (RegisterInfo
                  gp
                  (if (= last 'b')
                    1
                    (if (= last 'w')
                      2
                      4))
                  false)))))
        (when
          (and (= head 'e') (= n 4))
          (let
            [reg (legacy-register (& (string.substring text 2 2)))]
            (when
              (and (>= reg.number 0) (= reg.width 2))
              (return (RegisterInfo reg.number 4 false)))))
        (if (= n 3)
          (legacy-register (& (string.substring text 1 2)))
          (missing-register))))))

(define (legacy-register [text : (& text str)]) : RegisterInfo
  (let
    [head (string.string-ref text 0)]
    [last (string.string-ref text 1)]
    [low : i64
      (cond
        [(= head 'a') 0]
        [(= head 'c') 1]
        [(= head 'd') 2]
        [(= head 'b') 3]
        [else -1])]
    (cond
      [(and (>= low 0) (= last 'x')) (RegisterInfo low 2 false)]
      [(and (>= low 0) (= last 'l')) (RegisterInfo low 1 false)]
      [(and (>= low 0) (= last 'h')) (RegisterInfo (+ low 4) 1 true)]
      [(string.eq text "sp") (RegisterInfo abi.compiler-reg-id-rsp 2 false)]
      [(string.eq text "bp") (RegisterInfo abi.compiler-reg-id-rbp 2 false)]
      [(string.eq text "si") (RegisterInfo abi.compiler-reg-id-rsi 2 false)]
      [(string.eq text "di") (RegisterInfo abi.compiler-reg-id-rdi 2 false)]
      [else (missing-register)])))

(define (empty-operand) : Operand
  (Operand
    (Invalid)
    (missing-register)
    -1
    (missing-register)
    0
    false
    false
    0
    false
    0
    ""
    0
    false))

(define (expression!
  ;; lint-allow: unused-variable -- This parameter is a caller-owned write destination.
  [operand : (&mut Operand)]
  [text : (& text str)]) : bool
  (match (integer-literal text)
    [(Integer n)
      (set! operand.number n)
      true]
    [(Symbolic)
      (set! operand.expression (string.copy text))
      true]
    [(IntegerOverflow) false]))

(define (skip-whitespace [text : (& str)] [start : i64] [end : i64]) : i64
  (let
    [at start]
    (while (and
      (< at end)
      (string.is-char-whitespace (string.string-ref text at)))
      (+= at 1))
    at))

;; Copy only this token or line into the active arena. Substring views use
;; process-lifetime descriptors, even when their source belongs to scratch.
(define (range [text : (& str)] [start : i64] [end : i64]) : String
  (let
    [first (skip-whitespace text start end)]
    [last end]
    (while (and
      (> last first)
      (string.is-char-whitespace (string.string-ref text (- last 1))))
      (-= last 1))
    (string.substring text first (- last first))))

(define (memory! [op : (&mut Operand)] [text : (& text str)]) : bool
  (let
    [n (string.string-length text)]
    [open (string.index-of-byte text 0 40)]
    (when (< open 0) (return (and (> n 0) (expression! op text))))
    (unless (= (string.string-ref text (- n 1)) ')') (return false))
    (unless (expression! op (& (range text 0 open))) (return false))
    (let
      [end (- n 1)]
      [start (+ open 1)]
      [comma (string.index-of-byte text start 44)]
      [base-text : String
        (range
          text
          start
          (if (< comma 0)
            end
            comma))]
      (unless
        (= (string.string-length (& base-text)) 0)
        (if (string.eq (& base-text) "%rip")
          (set! op.rip true)
          (let
            [base (register (& base-text))]
            (unless
              (and (>= base.number 0) (or (= base.width 4) (= base.width 8)))
              (return false))
            (set! op.base base.number)
            (set! op.address32 (= base.width 4)))))
      (when
        (>= comma 0)
        (when op.rip (return false))
        (let
          [index-start (+ comma 1)]
          [scale-comma (string.index-of-byte text index-start 44)]
          [index-text : String
            (range
              text
              index-start
              (if (< scale-comma 0)
                end
                scale-comma))]
          [idx (register (& index-text))]
          (unless
            (and
              (>= idx.number 0)
              (or
                (>= idx.width 16)
                (and
                  (not (= idx.number 4))
                  (or (= idx.width 4) (= idx.width 8)))))
            (return false))
          (when
            (and
              (>= op.base 0)
              (<= idx.width 8)
              (not (= op.address32 (= idx.width 4))))
            (return false))
          (when (= idx.width 4) (set! op.address32 true))
          (set! op.index idx)
          (when
            (>= scale-comma 0)
            (set!
              op.scale
              (match (integer-literal (& (range text (+ scale-comma 1) end)))
                [(Integer scale)
                  (cond
                    [(= scale 1) 0]
                    [(= scale 2) 1]
                    [(= scale 4) 2]
                    [(= scale 8) 3]
                    [else -1])]
                [_ -1]))
            (when (< op.scale 0) (return false)))))
      (or op.rip (>= op.base 0) (>= op.index.number 0)))))

(define (decorations! [op : (&mut Operand)] [text : (& text str)] [start : i64]) : bool
  (let
    [at start]
    [n (string.string-length text)]
    (while (< at n)
      (unless (= (string.string-ref text at) '{') (return false))
      (let
        [end (string.index-of-byte text (+ at 1) 125)]
        (when (< end 0) (return false))
        (let
          [part : String (range text (+ at 1) end)]
          (cond
            [(string.eq (& part) "z")
              (when op.zero (return false))
              (set! op.zero true)]
            [else
              (let
                [reg (register (& part))]
                (unless
                  (and (= op.mask 0) (> reg.number 0) (= reg.width 0))
                  (return false))
                (set! op.mask reg.number))]))
        (set! at (+ end 1))))
    true))

;; Find a delimiter outside a quoted, backslash-escaped string.
(define (delimiter-before
  [text : (& str)]
  [start : i64]
  [n : i64]
  [want : char]) : i64
  (let
    [i start]
    [quoted false]
    (while (< i n)
      (let
        [c (string.string-ref text i)]
        (cond
          [(and quoted (= c '\\')) (+= i 1)]
          [(= c '"') (set! quoted (not quoted))]
          [(and (not quoted) (= c want)) (return i)]
          [else unit]))
      (+= i 1))
    n))

(define (delimiter [text : (& str)] [start : i64] [want : char]) : i64
  (delimiter-before text start (string.string-length text) want))

(define (parse-operand [text : (& text str)]) : Operand
  (let
    [op (empty-operand)]
    [n (string.string-length text)]
    [decoration (string.index-of-byte text 0 123)]
    [end
      (if (< decoration 0)
        n
        decoration)]
    [at : i64 0]
    (when
      (or
        (= end 0)
        (and (>= decoration 0) (not (decorations! (&mut op) text decoration))))
      (return (empty-operand)))
    (when (= (string.string-ref text at) '*') (set! op.indirect true) (+= at 1))
    (when (>= at end) (return (empty-operand)))
    (let
      [colon (delimiter text at ':')]
      (when
        (and (>= colon 0) (< colon end))
        (let
          [segment : String (range text at colon)]
          (set!
            op.segment
            (cond
              [(string.eq (& segment) "%fs") 0x64]
              [(string.eq (& segment) "%gs") 0x65]
              [else -1]))
          (when (< op.segment 0) (return (empty-operand)))
          (set! at (+ colon 1)))))
    (let
      [bare : String (range text at end)]
      (when (= (string.string-length (& bare)) 0) (return (empty-operand)))
      (cond
        [(= (string.string-ref (& bare) 0) '$')
          (when
            (and
              (> (string.string-length (& bare)) 1)
              (expression!
                (&mut op)
                (& (range (& bare) 1 (string.string-length (& bare))))))
            (set! op.kind (Immediate)))]
        [(and (= op.segment 0) (= (string.string-ref (& bare) 0) '%'))
          (set!
            op.reg
            (cond
              [(string.eq (& bare) "%spl")
                (RegisterInfo abi.compiler-reg-id-rsp 1 false)]
              [(string.eq (& bare) "%bpl")
                (RegisterInfo abi.compiler-reg-id-rbp 1 false)]
              [(string.eq (& bare) "%sil")
                (RegisterInfo abi.compiler-reg-id-rsi 1 false)]
              [(string.eq (& bare) "%dil")
                (RegisterInfo abi.compiler-reg-id-rdi 1 false)]
              [else (register (& bare))]))
          (when (>= op.reg.number 0) (set! op.kind (Register)))]
        [else (when (memory! (&mut op) (& bare)) (set! op.kind (Memory)))]))
    op))

(define (reg? [op : (& Operand)]) : bool
  (match op.kind
    [(Register) true]
    [_ false]))

(define (mem? [op : (& Operand)]) : bool
  (match op.kind
    [(Memory) true]
    [_ false]))

(define (imm? [op : (& Operand)]) : bool
  (match op.kind
    [(Immediate) true]
    [_ false]))

(define (valid? [op : (& Operand)]) : bool
  (match op.kind
    [(Invalid) false]
    [_ true]))

(define (symbolic? [op : (& Operand)]) : bool
  (> (string.string-length (& op.expression)) 0))

(define (operand-register [op : (& Operand)]) : RegisterInfo
  (RegisterInfo op.reg.number op.reg.width op.reg.high-byte))