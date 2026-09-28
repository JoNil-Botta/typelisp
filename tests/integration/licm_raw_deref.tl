;; #8085: a raw pointer, an integer address or pointer arithmetic is no evidence
;; of readable storage (SPEC section 7.3: validity is a use-site obligation), so
;; LICM may not move such a read out of a loop whose trips never perform it.
;; Every skipped read below takes its address from argv -- null, a nonzero
;; address in the unmapped first page, or a word 2^40 words past a live local --
;; so a hoisted copy faults where the source returns normally. The last two
;; calls do perform their reads, on a live buffer's first and last words, and
;; must see the same values at every opt level.
(import stdlib.io)
(import stdlib.string)

(define (raw-read-if [address : u64] [first : i64] [trips : i64]) : i64
  (let
    [i : i64 0]
    [sum : i64 0]
    (begin
      (while (< i trips)
        (begin
          (when
            (>= i first)
            (set!
              sum
              (+
                sum
                (unsafe
                  (ptr-read (int->ptr address : (Ptr i64)))))))
          (set! i (+ i 1))))
      sum)))

;; The same skipped read `words` past a live local, through `ptr-addr-of` and
;; `ptr-offset`.
(define (offset-read-if [words : i64] [first : i64]) : i64
  (let
    [cell : i64 7]
    [i : i64 0]
    [sum : i64 0]
    (begin
      (while (< i 10)
        (begin
          (when
            (>= i first)
            (set!
              sum
              (+
                sum
                (unsafe
                  (ptr-read
                    (ptr-offset (ptr-cast (ptr-addr-of cell) : (Ptr i64)) words))))))
          (set! i (+ i 1))))
      sum)))

(define (main) : i64
  (let
    [null : u64 (cast (string.>int (io.arg 1)) : u64)]
    [low : u64 (cast (string.>int (io.arg 2)) : u64)]
    [far : i64 (* (string.>int (io.arg 3)) 1099511627776)]
    [skip : i64 (string.>int (io.arg 4))]
    [items : (__tl_dyn-array i64) (__tl_make-array i64 4)]
    [data : u64
      (unsafe
        (ptr->int (ptr-cast (__tl_array-data items) : (Ptr i64))))]
    (begin
      (set! (array-ref items 0) 5)
      (set! (array-ref items 3) 8)
      (io.print-format "{}\n" (raw-read-if null skip 10))
      (io.print-format "{}\n" (raw-read-if low skip 10))
      (io.print-format "{}\n" (raw-read-if null 0 0))
      (io.print-format "{}\n" (offset-read-if far skip))
      (io.print-format "{}\n" (raw-read-if data 0 10))
      (io.print-format "{}\n" (raw-read-if (+ data 24) 8 10))
      42)))