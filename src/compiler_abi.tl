;; compiler_abi.tl - Shared x86_64 ABI facts for backend and regalloc.
;;
;; This file is intentionally pass-dependency-free: regalloc and backend both
;; import it, so it must not depend on either pass. Helpers expose ABI facts by
;; index/count; pass-specific list types and allocation policy stay in callers.
(import stdlib.string)

(defenum CompilerRegTargetAbi
  (Linux)
  (Windows))

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

(define (compiler-abi-gp-arg-register [abi : CompilerRegTargetAbi] [idx : i64]) : String
  (match abi
    [(CompilerRegTargetAbi.Linux)
      (cond
        [(= idx 0) "%rdi"]
        [(= idx 1) "%rsi"]
        [(= idx 2) "%rdx"]
        [(= idx 3) "%rcx"]
        [(= idx 4) "%r8"]
        [(= idx 5) "%r9"]
        [else ""])]
    [(CompilerRegTargetAbi.Windows)
      (cond
        [(= idx 0) "%rcx"]
        [(= idx 1) "%rdx"]
        [(= idx 2) "%r8"]
        [(= idx 3) "%r9"]
        [else ""])]))

(define (compiler-abi-float-arg-register
  [abi : CompilerRegTargetAbi]
  [idx : i64]) : String
  (match abi
    [(CompilerRegTargetAbi.Linux)
      (cond
        [(= idx 0) "%xmm0"]
        [(= idx 1) "%xmm1"]
        [(= idx 2) "%xmm2"]
        [(= idx 3) "%xmm3"]
        [(= idx 4) "%xmm4"]
        [(= idx 5) "%xmm5"]
        [(= idx 6) "%xmm6"]
        [(= idx 7) "%xmm7"]
        [else ""])]
    [(CompilerRegTargetAbi.Windows)
      (cond
        [(= idx 0) "%xmm0"]
        [(= idx 1) "%xmm1"]
        [(= idx 2) "%xmm2"]
        [(= idx 3) "%xmm3"]
        [else ""])]))

(define (compiler-abi-integer-return-register [idx : i64]) : String
  (cond [(= idx 0) "%rax"] [(= idx 1) "%rdx"] [else ""]))

(define (compiler-abi-float-return-register [idx : i64]) : String
  (cond [(= idx 0) "%xmm0"] [(= idx 1) "%xmm1"] [else ""]))

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

(define (compiler-abi-caller-saved-gp-register
  [abi : CompilerRegTargetAbi]
  [idx : i64]) : String
  (match abi
    [(CompilerRegTargetAbi.Linux)
      (cond
        [(= idx 0) "%rax"]
        [(= idx 1) "%rcx"]
        [(= idx 2) "%rdx"]
        [(= idx 3) "%rsi"]
        [(= idx 4) "%rdi"]
        [(= idx 5) "%r8"]
        [(= idx 6) "%r9"]
        [(= idx 7) "%r10"]
        [(= idx 8) "%r11"]
        [else ""])]
    [(CompilerRegTargetAbi.Windows)
      (cond
        [(= idx 0) "%r9"]
        [(= idx 1) "%rcx"]
        [(= idx 2) "%rdx"]
        [(= idx 3) "%rax"]
        [(= idx 4) "%r8"]
        [(= idx 5) "%r10"]
        [(= idx 6) "%r11"]
        [else ""])]))

(define (compiler-abi-callee-saved-gp-register-count
  [abi : CompilerRegTargetAbi]) : i64
  (match abi
    [(CompilerRegTargetAbi.Linux) 5]
    [(CompilerRegTargetAbi.Windows) 7]))

(define (compiler-abi-callee-saved-gp-register
  [abi : CompilerRegTargetAbi]
  [idx : i64]) : String
  (match abi
    [(CompilerRegTargetAbi.Linux)
      (cond
        [(= idx 0) "%rbx"]
        [(= idx 1) "%r12"]
        [(= idx 2) "%r13"]
        [(= idx 3) "%r14"]
        [(= idx 4) "%r15"]
        [else ""])]
    [(CompilerRegTargetAbi.Windows)
      (cond
        [(= idx 0) "%rbx"]
        [(= idx 1) "%rsi"]
        [(= idx 2) "%rdi"]
        [(= idx 3) "%r12"]
        [(= idx 4) "%r13"]
        [(= idx 5) "%r14"]
        [(= idx 6) "%r15"]
        [else ""])]))

(define (compiler-abi-backend-callee-save-gp-register-count
  [abi : CompilerRegTargetAbi]) : i64
  (match abi
    [(CompilerRegTargetAbi.Linux) 5]
    [(CompilerRegTargetAbi.Windows) 7]))

(define (compiler-abi-backend-callee-save-gp-register
  [abi : CompilerRegTargetAbi]
  [idx : i64]) : String
  (match abi
    [(CompilerRegTargetAbi.Linux)
      (cond
        [(= idx 0) "%r12"]
        [(= idx 1) "%r13"]
        [(= idx 2) "%r14"]
        [(= idx 3) "%r15"]
        [(= idx 4) "%rbx"]
        [else ""])]
    [(CompilerRegTargetAbi.Windows)
      (cond
        [(= idx 0) "%r12"]
        [(= idx 1) "%r13"]
        [(= idx 2) "%r14"]
        [(= idx 3) "%r15"]
        [(= idx 4) "%rbx"]
        [(= idx 5) "%rsi"]
        [(= idx 6) "%rdi"]
        [else ""])]))

(define (compiler-abi-caller-saved-xmm-register-count
  [abi : CompilerRegTargetAbi]) : i64
  (match abi
    [(CompilerRegTargetAbi.Linux) 16]
    [(CompilerRegTargetAbi.Windows) 6]))

(define (compiler-abi-caller-saved-xmm-register
  [abi : CompilerRegTargetAbi]
  [idx : i64]) : String
  (if (< idx 0)
    ""
    (match abi
      [(CompilerRegTargetAbi.Linux)
        (if (< idx 16)
          (string.append "%xmm" (string.int->string idx))
          "")]
      [(CompilerRegTargetAbi.Windows)
        (if (< idx 6)
          (string.append "%xmm" (string.int->string idx))
          "")])))

(define (compiler-abi-callee-saved-xmm-register-count
  [abi : CompilerRegTargetAbi]) : i64
  (match abi
    [(CompilerRegTargetAbi.Linux) 0]
    [(CompilerRegTargetAbi.Windows) 10]))

(define (compiler-abi-callee-saved-xmm-register
  [abi : CompilerRegTargetAbi]
  [idx : i64]) : String
  (match abi
    [(CompilerRegTargetAbi.Linux) ""]
    [(CompilerRegTargetAbi.Windows)
      (if (and (>= idx 0) (< idx 10))
        (string.append "%xmm" (string.int->string (+ idx 6)))
        "")]))

(define (compiler-abi-sysv-varargs-vector-count-register) : String
  "%al")

(define (compiler-abi-win64-varargs-duplicates-float-to-gp?) : bool
  true)