;; Regression: Windows tail-call outgoing stack-argument frame reservation.
;;
;; `compiler-backend-instr-outgoing-stack-space` and
;; `compiler-backend-instr-needs-outgoing-space?` must account for
;; `IrInstrTailCall`, not just `IrInstrCall`/`IrInstrCallIndirect`.
;;
;; A tail-recursive function with more than four parameters passes its later
;; arguments (here the accumulator) on the stack under the Win64 ABI, and the
;; eighth outgoing argument's expression contains a nested call. Before the fix,
;; a tail call was not flagged as needing outgoing space, so the static Windows
;; outgoing-argument region was under-reserved; placing the outgoing stack
;; arguments then clobbered the accumulator's local slot, so the count came back
;; 0 instead of 2. The bug only manifests on the Windows target (System V
;; reserves outgoing argument space per-call) and at opt levels where the values
;; live in stack slots, so the byte-identical self-compile did not catch it.
(define (tcsa-spill? [int-idx : i64]) : bool
  (>= int-idx 6))

(define (tcsa-count
  [n : i64]
  [a : i64]
  [b : i64]
  [c : i64]
  [int-idx : i64]
  [d : i64]
  [e : i64]
  [stack-count : i64]) : i64
  (if (>= int-idx n)
    stack-count
    (tcsa-count
      n
      a
      b
      c
      (+ int-idx 1)
      d
      e
      (if (tcsa-spill? int-idx)
        (+ stack-count 1)
        stack-count))))

(define (main) : i64
  (if (= (tcsa-count 8 0 0 0 0 0 0 0) 2)
    42
    1))