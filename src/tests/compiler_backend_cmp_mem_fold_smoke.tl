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
(import stdlib.io)
(import stdlib.string)

(define cmp-mem-fold-smoke-n : i64
  257)

(define (cmp-mem-fold-smoke-fill
  [values : (&mut values (__tl_dyn-array i64))]
  [seed : i64]) : unit
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
  [flags : (& flags (__tl_dyn-array i64))]
  [marks : (& marks (__tl_dyn-array i64))]) : i64
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
  [flags : (& flags (__tl_dyn-array i64))]
  [marks : (& marks (__tl_dyn-array i64))]) : i64
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
  [uses : (& uses (__tl_dyn-array i64))]
  [live : (& live (__tl_dyn-array i64))]
  [defs : (& defs (__tl_dyn-array i64))]) : i64
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
  [uses : (& uses (__tl_dyn-array i64))]
  [live : (& live (__tl_dyn-array i64))]
  [defs : (& defs (__tl_dyn-array i64))]) : i64
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

;; GAP8-C: the accumulator shape, where the single-use element load sits on the
;; LHS and the OTHER operand is a loop-carried register value. This is the shape
;; whose two-address destination the allocator now ties to the accumulator
;; instead of to the load, so the commuted fold's staging `mov` self-elides and
;; the ALU line reads the element itself -- the loop body becomes one `andq
;; (base,index,8), %acc` per element instead of a `mov`/`and` pair that ping-pongs
;; the accumulator between two registers.
;;
;; Each op reads a DIFFERENT array so every load stays single use; four reads of
;; one element would be CSE'd into a multi-use load, which retires the fold.
(define (cmp-mem-fold-smoke-acc-folded
  [a : (& a (__tl_dyn-array i64))]
  [b : (& b (__tl_dyn-array i64))]
  [c : (& c (__tl_dyn-array i64))]
  [d : (& d (__tl_dyn-array i64))]
  [seed : i64]) : i64
  (let
    [i : i64 0]
    [acc : i64 seed]
    (begin
      (while (< i (array-length a))
        (begin
          (set! acc (bit-and (array-ref a i) acc))
          (set! acc (bit-or (array-ref b i) acc))
          (set! acc (bit-xor (array-ref c i) acc))
          (set! acc (+ (array-ref d i) acc))
          (set! i (+ i 1))))
      acc)))

(define (cmp-mem-fold-smoke-acc-unfolded
  [a : (& a (__tl_dyn-array i64))]
  [b : (& b (__tl_dyn-array i64))]
  [c : (& c (__tl_dyn-array i64))]
  [d : (& d (__tl_dyn-array i64))]
  [seed : i64]) : i64
  (let
    [i : i64 0]
    [acc : i64 seed]
    (begin
      (while (< i (array-length a))
        (let
          [av : i64 (array-ref a i)]
          [bv : i64 (array-ref b i)]
          [cv : i64 (array-ref c i)]
          [dv : i64 (array-ref d i)]
          (begin
            (set! acc (bit-and (bit-or av (- av av)) acc))
            (set! acc (bit-or (bit-or bv (- bv bv)) acc))
            (set! acc (bit-xor (bit-or cv (- cv cv)) acc))
            (set! acc (+ (bit-or dv (- dv dv)) acc))
            (set! i (+ i 1)))))
      acc)))

;; Indirect indexing: the loaded value becomes the NEXT access's index, so its
;; bounds check and the compare behind it must keep reading the same element.
(define (cmp-mem-fold-smoke-indirect
  [index : (& index (__tl_dyn-array i64))]
  [table : (& table (__tl_dyn-array i64))]) : i64
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

;; M6-J: byte-width compares that read the element in place, with no widening
;; cast between the load and the compare -- an equality and an unsigned ordered
;; compare against literals, a register operand on the compare's left and on its
;; right, and a char scan against a char literal (the `string-ref` shape of a
;; path or token scanner). Each compare reads a DIFFERENT array so every load
;; stays single use; opt0 keeps the loads, so the printed total is the parity.
(define (cmp-mem-fold-smoke-bytes-fill
  [bytes : (&mut bytes (__tl_dyn-array u8))]
  [seed : i64]) : unit
  (let
    [i : i64 0]
    [state : i64 seed]
    (while (< i (array-length bytes))
      (begin
        (set! state (bit-and (+ (* state 1103515245) 12345) 2147483647))
        (set! (array-ref bytes i) (cast (bit-and (shr state 7) 127) : u8))
        (set! i (+ i 1))))))

(define (cmp-mem-fold-smoke-bytes
  [a : (& a (__tl_dyn-array u8))]
  [b : (& b (__tl_dyn-array u8))]
  [c : (& c (__tl_dyn-array u8))]
  [d : (& d (__tl_dyn-array u8))]
  [text : (& text str)]
  [key : u8]) : i64
  (let
    [i : i64 0]
    [total : i64 0]
    (begin
      (while (< i (array-length a))
        (begin
          (when (= (array-ref a i) (cast 47 : u8)) (set! total (+ total 1)))
          (when (< (array-ref b i) (cast 100 : u8)) (set! total (+ total 3)))
          (when (< key (array-ref c i)) (set! total (+ total 7)))
          (when (!= (array-ref d i) key) (set! total (+ total 11)))
          (set! i (+ i 1))))
      (set! i 0)
      (while (< i (string.string-length text))
        (begin
          (when (!= (string.string-ref text i) '/') (set! total (+ total 13)))
          (set! i (+ i 1))))
      total)))

(define (main) : i64
  (let
    [flags : (__tl_dyn-array i64) (__tl_make-array i64 cmp-mem-fold-smoke-n)]
    [marks : (__tl_dyn-array i64) (__tl_make-array i64 cmp-mem-fold-smoke-n)]
    [uses : (__tl_dyn-array i64) (__tl_make-array i64 cmp-mem-fold-smoke-n)]
    [live : (__tl_dyn-array i64) (__tl_make-array i64 cmp-mem-fold-smoke-n)]
    [defs : (__tl_dyn-array i64) (__tl_make-array i64 cmp-mem-fold-smoke-n)]
    [index : (__tl_dyn-array i64) (__tl_make-array i64 cmp-mem-fold-smoke-n)]
    (begin
      (cmp-mem-fold-smoke-fill (&mut flags) 1)
      (cmp-mem-fold-smoke-fill (&mut marks) 2)
      (cmp-mem-fold-smoke-fill (&mut uses) 3)
      (cmp-mem-fold-smoke-fill (&mut live) 4)
      (cmp-mem-fold-smoke-fill (&mut defs) 5)
      (cmp-mem-fold-smoke-fill (&mut index) 6)
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
          (cmp-mem-fold-smoke-folded (& flags) (& marks))
          (cmp-mem-fold-smoke-unfolded (& flags) (& marks))))
        (io.panic "cmp-mem fold: compare parity mismatch")
        unit)
      (if (not
        (=
          (cmp-mem-fold-smoke-words-folded (& uses) (& live) (& defs))
          (cmp-mem-fold-smoke-words-unfolded (& uses) (& live) (& defs))))
        (io.panic "cmp-mem fold: word ALU parity mismatch")
        unit)
      (if (not
        (=
          (cmp-mem-fold-smoke-acc-folded
            (& uses)
            (& live)
            (& defs)
            (& marks)
            12345)
          (cmp-mem-fold-smoke-acc-unfolded
            (& uses)
            (& live)
            (& defs)
            (& marks)
            12345)))
        (io.panic "cmp-mem fold: accumulator ALU parity mismatch")
        unit)
      (let
        [bytes-a : (__tl_dyn-array u8)
          (__tl_make-array u8 cmp-mem-fold-smoke-n)]
        [bytes-b : (__tl_dyn-array u8)
          (__tl_make-array u8 cmp-mem-fold-smoke-n)]
        [bytes-c : (__tl_dyn-array u8)
          (__tl_make-array u8 cmp-mem-fold-smoke-n)]
        [bytes-d : (__tl_dyn-array u8)
          (__tl_make-array u8 cmp-mem-fold-smoke-n)]
        (begin
          (cmp-mem-fold-smoke-bytes-fill (&mut bytes-a) 7)
          (cmp-mem-fold-smoke-bytes-fill (&mut bytes-b) 8)
          (cmp-mem-fold-smoke-bytes-fill (&mut bytes-c) 9)
          (cmp-mem-fold-smoke-bytes-fill (&mut bytes-d) 10)
          (io.println
            "cmp-mem fold smoke: bytes={}"
            (cmp-mem-fold-smoke-bytes
              (& bytes-a)
              (& bytes-b)
              (& bytes-c)
              (& bytes-d)
              "/usr/local//lib/typelisp/x/"
              (cast 64 : u8)))))
      (io.println
        "cmp-mem fold smoke: compares={} words={} indirect={} acc={}"
        (cmp-mem-fold-smoke-folded (& flags) (& marks))
        (cmp-mem-fold-smoke-words-folded (& uses) (& live) (& defs))
        (cmp-mem-fold-smoke-indirect (& index) (& flags))
        (cmp-mem-fold-smoke-acc-folded
          (& uses)
          (& live)
          (& defs)
          (& marks)
          12345))
      0)))