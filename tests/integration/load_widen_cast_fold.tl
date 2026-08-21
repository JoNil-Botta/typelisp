(import stdlib.array)

;; FORCING TEST for M6-G: a narrow element load whose only reader is its
;; widening cast is emitted straight into the CAST's register, not into a
;; scratch that is then re-extended.
;;
;; `(cast (array-ref bytes i) : i64)` lowers to `Load : u8` then
;; `Cast u8 to i64`, and `movzbq` already performs that extension. When the
;; widened byte has ONE reader the M6-C compare fold consumes the whole pair
;; into a `cmpb`; `classify` below deliberately reads it EIGHT times, so M6-C
;; declines and the pair survives. Before M6-G it survived as two instructions:
;;     movzbq (%rBASE,%rIDX,1), %rSCRATCH
;;     movzbq %SCRATCHl, %rC
;; After M6-G the load lands in the cast's own register:
;;     movzbq (%rBASE,%rIDX,1), %rC
;;
;; `refused` is the nearest neighbour the fold must NOT take: the loaded byte is
;; kept at u8 width and stored back, so no widening cast follows the load and
;; there is nothing to fold. It also proves the fold is not simply deleting
;; loads: the two functions agree on every input.
;;
;; The never-taken self-recursion keeps both functions out of the opt2 inliner
;; so the shapes stay in their own frames. A fold that dropped or mis-extended
;; the byte yields a different classification -> not 42;
;; scripts/verify-asm-shape-gates.sh asserts the asm shape.
(define (classify
  [bytes : (& bytes (__tl_dyn-array u8))]
  [i : i64]
  [poke : i64]) : i64
  (if (< poke 0)
    (classify bytes i (+ poke 1))
    (let
      [c : i64 (cast (array-ref bytes i) : i64)]
      (cond
        [(= c 32) 1]
        [(= c 9) 2]
        [(= c 40) 3]
        [(= c 41) 4]
        [(and (>= c 48) (<= c 57)) 5]
        [(and (>= c 97) (<= c 122)) 6]
        [(= c 45) 7]
        [else 8]))))

;; Nearest refused neighbour: the element is read at its own width and written
;; back, so the load feeds a store rather than a widening cast.
(define (refused
  [bytes : (&mut bytes (__tl_dyn-array u8))]
  [i : i64]
  [poke : i64]) : i64
  (if (< poke 0)
    (refused bytes i (+ poke 1))
    (let
      [b : u8 (array-ref bytes i)]
      (begin
        (set! (array-ref bytes i) b)
        (let
          [c : i64 (cast b : i64)]
          (cond
            [(= c 32) 1]
            [(= c 9) 2]
            [(= c 40) 3]
            [(= c 41) 4]
            [(and (>= c 48) (<= c 57)) 5]
            [(and (>= c 97) (<= c 122)) 6]
            [(= c 45) 7]
            [else 8]))))))

(define (main) : i64
  (let
    [bytes : (__tl_dyn-array u8) (array.make-array u8 8)]
    [i : i64 0]
    [ok : i64 0]
    (begin
      (set! (array-ref bytes 0) (cast 32 : u8))
      (set! (array-ref bytes 1) (cast 9 : u8))
      (set! (array-ref bytes 2) (cast 40 : u8))
      (set! (array-ref bytes 3) (cast 41 : u8))
      (set! (array-ref bytes 4) (cast 55 : u8))
      (set! (array-ref bytes 5) (cast 120 : u8))
      (set! (array-ref bytes 6) (cast 45 : u8))
      (set! (array-ref bytes 7) (cast 200 : u8))
      (while (< i 8)
        (begin
          (if (= (classify (& bytes) i 0) (refused (&mut bytes) i 0))
            (set! ok (+ ok 1))
            unit)
          (set! i (+ i 1))))
      (if (= ok 8)
        42
        1))))