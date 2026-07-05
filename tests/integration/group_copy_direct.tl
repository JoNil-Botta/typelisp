(import stdlib.io)

;; FORCING TEST for GAP2a: direct register-homed base/src in the fused
;; gep+CopyBytes (aggregate copy) path.
;;
;; `wrap` returns a 32-byte enum (8-byte tag + 24-byte Triple payload): the
;; construction writes the tag through the sret pointer and copies the payload
;; with the fused Gep+CopyBytes emitter (movups + movq chunk pair). Both the
;; sret base and the payload source pointer are REGISTER-HOMED (the never-taken
;; self-recursion blocks inlining and forces call-spanning CSR homes). Before
;; GAP2a the emitter staged BOTH through scavenged scratches every time:
;;     movq %rCSR, %r10
;;     addq $8, %r10
;;     movq %rCSR2, %r9
;;     movups (%r9), %xmm2
;;     movups %xmm2, (%r10)
;; After GAP2a the homes are the addressing bases directly and the constant
;; gep displacement folds into the chunk addresses:
;;     movups (%rCSR2), %xmm2
;;     movups %xmm2, 8(%rCSR)
;; The runtime loop checksums the copied payloads (a wrong base, displacement,
;; or clobbered home produces a wrong sum -> not 42); target/group-copy-gate.sh
;; additionally asserts the asm shape.
(defstruct Triple
  (a i64)
  (b i64)
  (c i64))

(defenum Wrap
  (WrapNone)
  (WrapSome Triple))

(define (wrap [t : Triple] [flag : i64]) : Wrap
  (if (> flag 1000000)
    (wrap t (- flag 1000000))
    (WrapSome t)))

(define (probe [n : i64]) : i64
  (let
    [i : i64 0]
    [acc : i64 0]
    (begin
      (while (< i n)
        (begin
          (match (wrap (Triple (+ i 1) (* i 2) 7) i)
            [(WrapSome t)
              (set!
                acc
                (+
                  acc
                  (+ (struct-get t a) (+ (struct-get t b) (struct-get t c)))))]
            [(WrapNone) (set! acc (- 0 1000000))])
          (set! i (+ i 1))))
      acc)))

(define (main) : i64
  (let
    [n : i64 (+ (io.arg-count) 5)]
    [r : i64 (probe n)]
    ;; n = 6 (no args): sum over i<6 of (i+1) + 2i + 7 = (1+..+6) + 2*15 + 42
    ;;                = 21 + 30 + 42 = 93.
    (if (= r 93)
      42
      1)))