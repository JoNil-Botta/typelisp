;; compiler_abi.tl - Shared x86_64 ABI facts for backend and regalloc.
;;
;; This file is intentionally pass-dependency-free: regalloc and backend both
;; import it, so it must not depend on either pass. Helpers expose ABI facts by
;; index/count; pass-specific list types and allocation policy stay in callers.
(import stdlib.string)

(defenum CompilerRegTargetAbi
  (Linux)
  (Windows))

;; Canonical physical-register codes shared by regalloc and the backend.
;;
;; GP codes deliberately match the x86 low register encoding.  XMM and the
;; width-neutral allocator vector spelling occupy two compact arithmetic
;; ranges: they are distinct logical homes (so output keeps its class), while
;; `compiler-abi-register-ownership-id` folds both ranges onto the same XMM
;; family for physical interference.  Mask registers occupy a third range.
;;
;; Strings are accepted only by `compiler-abi-register-id-from-spelling`, the
;; cold legacy/test ingress boundary, and produced only by
;; `compiler-abi-register-spelling`, the emission/diagnostic boundary.
(define compiler-reg-id-invalid : i64
  -1)
(define compiler-reg-id-rax : i64
  0)
(define compiler-reg-id-rcx : i64
  1)
(define compiler-reg-id-rdx : i64
  2)
(define compiler-reg-id-rbx : i64
  3)
(define compiler-reg-id-rsp : i64
  4)
(define compiler-reg-id-rbp : i64
  5)
(define compiler-reg-id-rsi : i64
  6)
(define compiler-reg-id-rdi : i64
  7)
(define compiler-reg-id-r8 : i64
  8)
(define compiler-reg-id-r9 : i64
  9)
(define compiler-reg-id-r10 : i64
  10)
(define compiler-reg-id-r11 : i64
  11)
(define compiler-reg-id-r12 : i64
  12)
(define compiler-reg-id-r13 : i64
  13)
(define compiler-reg-id-r14 : i64
  14)
(define compiler-reg-id-r15 : i64
  15)
(define compiler-reg-id-xmm-base : i64
  32)
(define compiler-reg-id-vec-base : i64
  64)
(define compiler-reg-id-mask-base : i64
  96)
(define compiler-reg-id-family-count : i64
  32)
(define compiler-reg-id-mask-count : i64
  8)

(define (compiler-abi-xmm-register-id [index : i64]) : i64
  (if (and (>= index 0) (< index compiler-reg-id-family-count))
    (+ compiler-reg-id-xmm-base index)
    compiler-reg-id-invalid))

(define (compiler-abi-vector-register-id [index : i64]) : i64
  (if (and (>= index 0) (< index compiler-reg-id-family-count))
    (+ compiler-reg-id-vec-base index)
    compiler-reg-id-invalid))

(define (compiler-abi-mask-register-id [index : i64]) : i64
  (if (and (>= index 0) (< index compiler-reg-id-mask-count))
    (+ compiler-reg-id-mask-base index)
    compiler-reg-id-invalid))

(define (compiler-abi-gp-register-id? [reg-id : i64]) : bool
  (and (>= reg-id compiler-reg-id-rax) (<= reg-id compiler-reg-id-r15)))

(define (compiler-abi-xmm-register-id? [reg-id : i64]) : bool
  (and
    (>= reg-id compiler-reg-id-xmm-base)
    (< reg-id (+ compiler-reg-id-xmm-base compiler-reg-id-family-count))))

(define (compiler-abi-vector-register-id? [reg-id : i64]) : bool
  (and
    (>= reg-id compiler-reg-id-vec-base)
    (< reg-id (+ compiler-reg-id-vec-base compiler-reg-id-family-count))))

(define (compiler-abi-mask-register-id? [reg-id : i64]) : bool
  (and
    (>= reg-id compiler-reg-id-mask-base)
    (< reg-id (+ compiler-reg-id-mask-base compiler-reg-id-mask-count))))

(define (compiler-abi-register-vector-family-index [reg-id : i64]) : i64
  (if (compiler-abi-xmm-register-id? reg-id)
    (- reg-id compiler-reg-id-xmm-base)
    (if (compiler-abi-vector-register-id? reg-id)
      (- reg-id compiler-reg-id-vec-base)
      -1)))

(define (compiler-abi-register-ownership-id [reg-id : i64]) : i64
  (let
    [family : i64 (compiler-abi-register-vector-family-index reg-id)]
    (if (>= family 0)
      (+ compiler-reg-id-xmm-base family)
      reg-id)))

(define (compiler-abi-registers-overlap? [left : i64] [right : i64]) : bool
  (=
    (compiler-abi-register-ownership-id left)
    (compiler-abi-register-ownership-id right)))

(define (compiler-abi-register-with-vector-class [reg-id : i64] [vector : bool]) : i64
  (let
    [family : i64 (compiler-abi-register-vector-family-index reg-id)]
    (if (< family 0)
      compiler-reg-id-invalid
      (if vector
        (compiler-abi-vector-register-id family)
        (compiler-abi-xmm-register-id family)))))

(define (compiler-abi-register-decimal-suffix
  [text : String]
  [start : i64]
  [max : i64]) : i64
  (let
    [n : i64 (string.string-length text)]
    [i : i64 start]
    [value : i64 0]
    [valid : bool
      (and
        (< start n)
        (not (and (> n (+ start 1)) (= (string.string-ref text start) '0'))))]
    (begin
      (while (and valid (< i n))
        (let
          [digit : i64 (cast (string.string-ref text i) : i64)]
          (if (and (>= digit 48) (<= digit 57))
            (begin
              (set! value (+ (* value 10) (- digit 48)))
              (set! i (+ i 1)))
            (set! valid false))))
      (if (and valid (<= value max))
        value
        -1))))

(define (compiler-abi-register-id-from-spelling [spelling : String]) : i64
  (cond
    [(string.eq spelling "%rax") compiler-reg-id-rax]
    [(string.eq spelling "%rcx") compiler-reg-id-rcx]
    [(string.eq spelling "%rdx") compiler-reg-id-rdx]
    [(string.eq spelling "%rbx") compiler-reg-id-rbx]
    [(string.eq spelling "%rsp") compiler-reg-id-rsp]
    [(string.eq spelling "%rbp") compiler-reg-id-rbp]
    [(string.eq spelling "%rsi") compiler-reg-id-rsi]
    [(string.eq spelling "%rdi") compiler-reg-id-rdi]
    [(string.eq spelling "%r8") compiler-reg-id-r8]
    [(string.eq spelling "%r9") compiler-reg-id-r9]
    [(string.eq spelling "%r10") compiler-reg-id-r10]
    [(string.eq spelling "%r11") compiler-reg-id-r11]
    [(string.eq spelling "%r12") compiler-reg-id-r12]
    [(string.eq spelling "%r13") compiler-reg-id-r13]
    [(string.eq spelling "%r14") compiler-reg-id-r14]
    [(string.eq spelling "%r15") compiler-reg-id-r15]
    [else
      (let
        [n : i64 (string.string-length spelling)]
        [is-xmm : bool
          (and
            (> n 4)
            (= (string.string-ref spelling 0) '%')
            (= (string.string-ref spelling 1) 'x')
            (= (string.string-ref spelling 2) 'm')
            (= (string.string-ref spelling 3) 'm'))]
        [is-vec : bool
          (and
            (> n 4)
            (= (string.string-ref spelling 0) '%')
            (or
              (and
                (= (string.string-ref spelling 1) 'v')
                (= (string.string-ref spelling 2) 'e')
                (= (string.string-ref spelling 3) 'c'))
              (and
                (or
                  (= (string.string-ref spelling 1) 'y')
                  (= (string.string-ref spelling 1) 'z'))
                (= (string.string-ref spelling 2) 'm')
                (= (string.string-ref spelling 3) 'm'))))]
        [is-mask : bool
          (and
            (> n 2)
            (= (string.string-ref spelling 0) '%')
            (= (string.string-ref spelling 1) 'k'))]
        (if is-xmm
          (compiler-abi-xmm-register-id
            (compiler-abi-register-decimal-suffix spelling 4 31))
          (if is-vec
            (compiler-abi-vector-register-id
              (compiler-abi-register-decimal-suffix spelling 4 31))
            (if is-mask
              (compiler-abi-mask-register-id
                (compiler-abi-register-decimal-suffix spelling 2 7))
              compiler-reg-id-invalid))))]))

(define (compiler-abi-register-spelling [reg-id : i64]) : String
  (cond
    [(= reg-id compiler-reg-id-rax) "%rax"]
    [(= reg-id compiler-reg-id-rcx) "%rcx"]
    [(= reg-id compiler-reg-id-rdx) "%rdx"]
    [(= reg-id compiler-reg-id-rbx) "%rbx"]
    [(= reg-id compiler-reg-id-rsp) "%rsp"]
    [(= reg-id compiler-reg-id-rbp) "%rbp"]
    [(= reg-id compiler-reg-id-rsi) "%rsi"]
    [(= reg-id compiler-reg-id-rdi) "%rdi"]
    [(= reg-id compiler-reg-id-r8) "%r8"]
    [(= reg-id compiler-reg-id-r9) "%r9"]
    [(= reg-id compiler-reg-id-r10) "%r10"]
    [(= reg-id compiler-reg-id-r11) "%r11"]
    [(= reg-id compiler-reg-id-r12) "%r12"]
    [(= reg-id compiler-reg-id-r13) "%r13"]
    [(= reg-id compiler-reg-id-r14) "%r14"]
    [(= reg-id compiler-reg-id-r15) "%r15"]
    [(compiler-abi-xmm-register-id? reg-id)
      (string.append
        "%xmm"
        (string.int->string (- reg-id compiler-reg-id-xmm-base)))]
    [(compiler-abi-vector-register-id? reg-id)
      (string.append
        "%vec"
        (string.int->string (- reg-id compiler-reg-id-vec-base)))]
    [(compiler-abi-mask-register-id? reg-id)
      (string.append
        "%k"
        (string.int->string (- reg-id compiler-reg-id-mask-base)))]
    [else ""]))

(define (compiler-abi-linux? [abi : CompilerRegTargetAbi]) : bool
  (match abi
    [(CompilerRegTargetAbi.Linux) true]
    [(CompilerRegTargetAbi.Windows) false]))

(define (compiler-abi-windows? [abi : CompilerRegTargetAbi]) : bool
  (match abi
    [(CompilerRegTargetAbi.Linux) false]
    [(CompilerRegTargetAbi.Windows) true]))

(define (compiler-abi-gp-arg-register-count [abi : CompilerRegTargetAbi]) : i64
  (match abi
    [(CompilerRegTargetAbi.Linux) 6]
    [(CompilerRegTargetAbi.Windows) 4]))

(define (compiler-abi-float-arg-register-count [abi : CompilerRegTargetAbi]) : i64
  (match abi
    [(CompilerRegTargetAbi.Linux) 8]
    [(CompilerRegTargetAbi.Windows) 4]))

(define (compiler-abi-arg-banks-independent? [abi : CompilerRegTargetAbi]) : bool
  (match abi
    [(CompilerRegTargetAbi.Linux) true]
    [(CompilerRegTargetAbi.Windows) false]))

(define (compiler-abi-gp-arg-register-id
  [abi : CompilerRegTargetAbi]
  [idx : i64]) : i64
  (match abi
    [(CompilerRegTargetAbi.Linux)
      (cond
        [(= idx 0) compiler-reg-id-rdi]
        [(= idx 1) compiler-reg-id-rsi]
        [(= idx 2) compiler-reg-id-rdx]
        [(= idx 3) compiler-reg-id-rcx]
        [(= idx 4) compiler-reg-id-r8]
        [(= idx 5) compiler-reg-id-r9]
        [else compiler-reg-id-invalid])]
    [(CompilerRegTargetAbi.Windows)
      (cond
        [(= idx 0) compiler-reg-id-rcx]
        [(= idx 1) compiler-reg-id-rdx]
        [(= idx 2) compiler-reg-id-r8]
        [(= idx 3) compiler-reg-id-r9]
        [else compiler-reg-id-invalid])]))

(define (compiler-abi-gp-arg-register [abi : CompilerRegTargetAbi] [idx : i64]) : String
  (compiler-abi-register-spelling (compiler-abi-gp-arg-register-id abi idx)))

(define (compiler-abi-float-arg-register-id
  [abi : CompilerRegTargetAbi]
  [idx : i64]) : i64
  (match abi
    [(CompilerRegTargetAbi.Linux)
      (if (and (>= idx 0) (< idx 8))
        (compiler-abi-xmm-register-id idx)
        compiler-reg-id-invalid)]
    [(CompilerRegTargetAbi.Windows)
      (if (and (>= idx 0) (< idx 4))
        (compiler-abi-xmm-register-id idx)
        compiler-reg-id-invalid)]))

(define (compiler-abi-float-arg-register
  [abi : CompilerRegTargetAbi]
  [idx : i64]) : String
  (compiler-abi-register-spelling (compiler-abi-float-arg-register-id abi idx)))

(define (compiler-abi-outgoing-shadow-space [abi : CompilerRegTargetAbi]) : i64
  (match abi
    [(CompilerRegTargetAbi.Linux) 0]
    [(CompilerRegTargetAbi.Windows) 32]))

(define (compiler-abi-stack-call-arg-for-banks?
  [abi : CompilerRegTargetAbi]
  [is-float : bool]
  [int-idx : i64]
  [float-idx : i64]
  [position : i64]) : bool
  (if (compiler-abi-arg-banks-independent? abi)
    (if is-float
      (>= float-idx (compiler-abi-float-arg-register-count abi))
      (>= int-idx (compiler-abi-gp-arg-register-count abi)))
    (>= position (compiler-abi-gp-arg-register-count abi))))

(define (compiler-abi-caller-saved-gp-register-count
  [abi : CompilerRegTargetAbi]) : i64
  (match abi
    [(CompilerRegTargetAbi.Linux) 9]
    [(CompilerRegTargetAbi.Windows) 7]))

(define (compiler-abi-caller-saved-gp-register-id
  [abi : CompilerRegTargetAbi]
  [idx : i64]) : i64
  (match abi
    [(CompilerRegTargetAbi.Linux)
      (cond
        [(= idx 0) compiler-reg-id-rax]
        [(= idx 1) compiler-reg-id-rcx]
        [(= idx 2) compiler-reg-id-rdx]
        [(= idx 3) compiler-reg-id-rsi]
        [(= idx 4) compiler-reg-id-rdi]
        [(= idx 5) compiler-reg-id-r8]
        [(= idx 6) compiler-reg-id-r9]
        [(= idx 7) compiler-reg-id-r10]
        [(= idx 8) compiler-reg-id-r11]
        [else compiler-reg-id-invalid])]
    [(CompilerRegTargetAbi.Windows)
      (cond
        [(= idx 0) compiler-reg-id-r9]
        [(= idx 1) compiler-reg-id-rcx]
        [(= idx 2) compiler-reg-id-rdx]
        [(= idx 3) compiler-reg-id-rax]
        [(= idx 4) compiler-reg-id-r8]
        [(= idx 5) compiler-reg-id-r10]
        [(= idx 6) compiler-reg-id-r11]
        [else compiler-reg-id-invalid])]))

(define (compiler-abi-caller-saved-gp-register
  [abi : CompilerRegTargetAbi]
  [idx : i64]) : String
  (compiler-abi-register-spelling
    (compiler-abi-caller-saved-gp-register-id abi idx)))

(define (compiler-abi-callee-saved-gp-register-count
  [abi : CompilerRegTargetAbi]) : i64
  (match abi
    [(CompilerRegTargetAbi.Linux) 5]
    [(CompilerRegTargetAbi.Windows) 7]))

(define (compiler-abi-callee-saved-gp-register-id
  [abi : CompilerRegTargetAbi]
  [idx : i64]) : i64
  (match abi
    [(CompilerRegTargetAbi.Linux)
      (cond
        [(= idx 0) compiler-reg-id-rbx]
        [(= idx 1) compiler-reg-id-r12]
        [(= idx 2) compiler-reg-id-r13]
        [(= idx 3) compiler-reg-id-r14]
        [(= idx 4) compiler-reg-id-r15]
        [else compiler-reg-id-invalid])]
    [(CompilerRegTargetAbi.Windows)
      (cond
        [(= idx 0) compiler-reg-id-rbx]
        [(= idx 1) compiler-reg-id-rsi]
        [(= idx 2) compiler-reg-id-rdi]
        [(= idx 3) compiler-reg-id-r12]
        [(= idx 4) compiler-reg-id-r13]
        [(= idx 5) compiler-reg-id-r14]
        [(= idx 6) compiler-reg-id-r15]
        [else compiler-reg-id-invalid])]))

(define (compiler-abi-callee-saved-gp-register
  [abi : CompilerRegTargetAbi]
  [idx : i64]) : String
  (compiler-abi-register-spelling
    (compiler-abi-callee-saved-gp-register-id abi idx)))

(define (compiler-abi-caller-saved-xmm-register-count
  [abi : CompilerRegTargetAbi]) : i64
  (match abi
    [(CompilerRegTargetAbi.Linux) 16]
    [(CompilerRegTargetAbi.Windows) 6]))

(define (compiler-abi-caller-saved-xmm-register-id
  [abi : CompilerRegTargetAbi]
  [idx : i64]) : i64
  (if (< idx 0)
    compiler-reg-id-invalid
    (match abi
      [(CompilerRegTargetAbi.Linux)
        (if (< idx 16)
          (compiler-abi-xmm-register-id idx)
          compiler-reg-id-invalid)]
      [(CompilerRegTargetAbi.Windows)
        (if (< idx 6)
          (compiler-abi-xmm-register-id idx)
          compiler-reg-id-invalid)])))

(define (compiler-abi-caller-saved-xmm-register
  [abi : CompilerRegTargetAbi]
  [idx : i64]) : String
  (compiler-abi-register-spelling
    (compiler-abi-caller-saved-xmm-register-id abi idx)))

(define (compiler-abi-callee-saved-xmm-register-count
  [abi : CompilerRegTargetAbi]) : i64
  (match abi
    [(CompilerRegTargetAbi.Linux) 0]
    [(CompilerRegTargetAbi.Windows) 10]))

(define (compiler-abi-callee-saved-xmm-register-id
  [abi : CompilerRegTargetAbi]
  [idx : i64]) : i64
  (match abi
    [(CompilerRegTargetAbi.Linux) compiler-reg-id-invalid]
    [(CompilerRegTargetAbi.Windows)
      (if (and (>= idx 0) (< idx 10))
        (compiler-abi-xmm-register-id (+ idx 6))
        compiler-reg-id-invalid)]))

(define (compiler-abi-callee-saved-xmm-register
  [abi : CompilerRegTargetAbi]
  [idx : i64]) : String
  (compiler-abi-register-spelling
    (compiler-abi-callee-saved-xmm-register-id abi idx)))