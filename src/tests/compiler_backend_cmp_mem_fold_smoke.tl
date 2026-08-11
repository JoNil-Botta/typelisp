;; compiler_backend_cmp_mem_fold_smoke.tl - Runtime parity smoke for the M6
;; memory-operand compare folds and the GAP8 ALU memory-operand fold.
;;
;; Every shape below is computed TWICE: once in the form the backend folds (a
;; single-use element load feeding a compare or a commutative ALU op) and once
;; in a form the folds must refuse (the loaded value is bound and read twice, so
;; `compiler-backend-var-single-use?` fails). The two results must agree, which
;; is exactly the claim the folds make: dropping the load and reading the
;; element through the consuming instruction's memory operand is unobservable.
;;
;; Running the smoke at --opt-level 0 and 2 adds the second half of the check:
;; opt0 leaves the loads in place, opt2 folds them, and both must print the same
;; totals. The bounds checks in front of every `array-ref` are folded compares
;; too, so a fold that changed a check's sense would abort here instead of
;; returning.
(import stdlib.io as io)

(define cmp-mem-fold-smoke-n : i64
  257)

(define (cmp-mem-fold-smoke-fill [values : (Array i64)] [seed : i64]) : unit
  (let
    [i : i64 0]
    [state : i64 seed]
    (while (< i (array-length values))
      (begin
        (set! state (bit-and (+ (* state 1103515245) 12345) 2147483647))
        (set! (array-ref values i) (bit-and (shr state 7) 1023))
        (set! i (+ i 1))))))

;; The folded shape: `(= (array-ref flags i) 1)` and `(>= (array-ref marks i) 0)`
;; are single-use element loads feeding compares that feed branches, which is
;; the M6-B/M6-D shape (`cmpq $1, (base,index,8)`).
(define (cmp-mem-fold-smoke-folded
  [flags : (Array i64)]
  [marks : (Array i64)]) : i64
  (let
    [i : i64 0]
    [total : i64 0]
    (begin
      (while (< i (array-length flags))
        (begin
          (when
            (and (= (array-ref flags i) 1) (>= (array-ref marks i) 0))
            (set! total (+ total (array-ref marks i))))
          (set! i (+ i 1))))
      total)))

;; The refused shape: each element is bound to a local that is read twice, so
;; the single-use gate declines and the ordinary load-then-compare is emitted.
(define (cmp-mem-fold-smoke-unfolded
  [flags : (Array i64)]
  [marks : (Array i64)]) : i64
  (let
    [i : i64 0]
    [total : i64 0]
    (begin
      (while (< i (array-length flags))
        (let
          [flag : i64 (array-ref flags i)]
          [mark : i64 (array-ref marks i)]
          (begin
            (when
              (and (= flag 1) (>= mark 0))
              (set! total (+ total (+ mark (- flag flag)))))
            (set! i (+ i 1)))))
      total)))

;; The GAP8/GAP8-B shape: `uses | (live-out & ~defs)` over word arrays, with the
;; single-use element loads sitting on BOTH sides of the commutative ops.
(define (cmp-mem-fold-smoke-words-folded
  [uses : (Array i64)]
  [live : (Array i64)]
  [defs : (Array i64)]) : i64
  (let
    [i : i64 0]
    [acc : i64 0]
    (begin
      (while (< i (array-length uses))
        (begin
          (set!
            acc
            (bit-xor
              acc
              (bit-or
                (array-ref uses i)
                (bit-and (array-ref live i) (bit-xor (array-ref defs i) -1)))))
          (set! i (+ i 1))))
      acc)))

(define (cmp-mem-fold-smoke-words-unfolded
  [uses : (Array i64)]
  [live : (Array i64)]
  [defs : (Array i64)]) : i64
  (let
    [i : i64 0]
    [acc : i64 0]
    (begin
      (while (< i (array-length uses))
        (let
          [u : i64 (array-ref uses i)]
          [l : i64 (array-ref live i)]
          [d : i64 (array-ref defs i)]
          [notd : i64 (bit-xor d -1)]
          (begin
            (set!
              acc
              (bit-xor acc (bit-or u (bit-and l (bit-or notd (- d d))))))
            (set! i (+ i 1)))))
      acc)))

;; Indirect indexing: the loaded value becomes the NEXT access's index, so its
;; bounds check and the compare behind it must keep reading the same element.
(define (cmp-mem-fold-smoke-indirect
  [index : (Array i64)]
  [table : (Array i64)]) : i64
  (let
    [i : i64 0]
    [total : i64 0]
    (begin
      (while (< i (array-length index))
        (let
          [slot : i64 (bit-and (array-ref index i) 255)]
          (begin
            (when (= (array-ref table slot) 1) (set! total (+ total 1)))
            (when (>= (array-ref table slot) 512) (set! total (+ total 2)))
            (set! i (+ i 1)))))
      total)))

(define (main) : i64
  (let
    [flags : (Array i64) (make-array i64 cmp-mem-fold-smoke-n)]
    [marks : (Array i64) (make-array i64 cmp-mem-fold-smoke-n)]
    [uses : (Array i64) (make-array i64 cmp-mem-fold-smoke-n)]
    [live : (Array i64) (make-array i64 cmp-mem-fold-smoke-n)]
    [defs : (Array i64) (make-array i64 cmp-mem-fold-smoke-n)]
    [index : (Array i64) (make-array i64 cmp-mem-fold-smoke-n)]
    (begin
      (cmp-mem-fold-smoke-fill flags 1)
      (cmp-mem-fold-smoke-fill marks 2)
      (cmp-mem-fold-smoke-fill uses 3)
      (cmp-mem-fold-smoke-fill live 4)
      (cmp-mem-fold-smoke-fill defs 5)
      (cmp-mem-fold-smoke-fill index 6)
      ;; `flags` holds masked pseudorandom values; force a healthy population of
      ;; the literal the compare folds against.
      (let
        [i : i64 0]
        (while (< i cmp-mem-fold-smoke-n)
          (begin
            (when (= (bit-and i 3) 0) (set! (array-ref flags i) 1))
            (set! i (+ i 1)))))
      (if (not
        (=
          (cmp-mem-fold-smoke-folded flags marks)
          (cmp-mem-fold-smoke-unfolded flags marks)))
        (io.panic "cmp-mem fold: compare parity mismatch")
        unit)
      (if (not
        (=
          (cmp-mem-fold-smoke-words-folded uses live defs)
          (cmp-mem-fold-smoke-words-unfolded uses live defs)))
        (io.panic "cmp-mem fold: word ALU parity mismatch")
        unit)
      (io.println
        "cmp-mem fold smoke: compares={} words={} indirect={}"
        (cmp-mem-fold-smoke-folded flags marks)
        (cmp-mem-fold-smoke-words-folded uses live defs)
        (cmp-mem-fold-smoke-indirect index flags))
      0)))
