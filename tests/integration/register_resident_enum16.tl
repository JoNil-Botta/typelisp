;; #2386: a 16-byte two-word register-group ENUM (tag in word0, a single
;; word-class payload in word1). Unlike register_pair_struct.tl, this exercises
;; the full register-group ENUM path END TO END across call boundaries:
;;   * construction (IrInstrPack: tag word0 + payload word1) and match/payload
;;     extraction (IrInstrWord),
;;   * pass-by-value into a call in a register pair and return-by-value in
;;     %rax:%rdx,
;;   * a register-group value carried through an `if` (a Phi of two group values),
;;   * a loop-carried register-group accumulator (`set!` across a `while`),
;;   * a register-group argument that lands in a STACK slot -- `mix8`'s 8th
;;     parameter sits past the six integer arg registers, so the whole group is
;;     passed on the stack (both eightbytes) rather than in registers.
;;
;; The whole-compiler proof is the bootstrap fixpoint: the self-hosted compiler's
;; own `CompilerIrValue` is exactly such a 16-byte register-group enum, so a
;; byte-identical stage2/stage3 already exercises this representation pervasively.
;; This case pins the behavior as a small, readable regression guard on both
;; targets: System V passes the two words in two integer arg registers (or two
;; stack words); Windows uses the same two-register/two-stack-word convention over
;; its rcx/rdx/r8/r9 arg sequence (these enum/struct groups are internal
;; compiler types that never cross an `(:abi c)` boundary, so a custom but
;; self-consistent convention is sound). `mix8`'s 8th argument forces a stacked
;; group on Windows, where only four integer arg registers are available.
(defenum Opt
  (None)
  (Some i64))

(defenum Res
  (Ok i64)
  (Err i64))

(define (unwrap [m : Opt]) : i64
  (match m
    [(None) 0]
    [(Some v) v]))

(define (handle [r : Res]) : i64
  (match r
    [(Ok v) v]
    [(Err e) (- 0 e)]))

;; `if` over two freshly-constructed group values -> a Phi merging register-group
;; vars, returned by value.
(define (mk [b : bool]) : Opt
  (if b
    (Some 5)
    (None)))

;; The 8th parameter `m` is a register-group enum. Seven integer params precede
;; it, exhausting the six integer arg registers, so `m` is passed entirely on the
;; stack (word0 then word1) and read back from the caller frame.
(define (mix8
  [a : i64]
  [b : i64]
  [c : i64]
  [d : i64]
  [e : i64]
  [f : i64]
  [g : i64]
  [m : Opt]) : i64
  (+ (+ (+ a b) (+ c d)) (+ (+ e f) (+ g (unwrap m)))))

;; Loop-carried register-group accumulator: `acc` is re-Packed each iteration and
;; the live value flows across the loop back-edge as a group.
(define (sumloop [n : i64]) : i64
  (let
    [acc : Opt (Some 0)]
    [i : i64 0]
    (begin
      (while (< i n)
        (begin
          (set! acc (Some (+ (unwrap acc) i)))
          (set! i (+ i 1))))
      (unwrap acc))))

(define (main) : i64
  (+
    (+ (mix8 4 4 4 4 4 4 4 (Some 2)) (+ (unwrap (mk true)) (unwrap (mk false))))
    (+ (sumloop 4) (handle (Ok 1)))))