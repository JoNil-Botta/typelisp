;; Non-tail recursion keeps a real 64 KiB by-value local live across its call.
;; The input is a separate small mmap, so no expanded array initializer is
;; needed merely to construct this overflow witness.
(unsafe
  (define (dive [input : (Ptr (Array i64 8192))] [n : i64])
    (:export-symbol "stack_dive") : i64
    (let
      [page : (Array i64 8192)
        (unsafe
          (ptr-read input))]
      [_stored : unit (set! (array-ref page 0) n)]
      [child : i64
        (unsafe
          (dive input (+ n 1)))]
      (+ child (array-ref page 0)))))

(define (main) : i64
  (let
    [input : i64
      (unsafe
        (syscall 9 0 65536 3 0x22 -1 0))]
    (if (< input 0)
      125
      (unsafe
        (dive (int->ptr (cast input : u64) : (Ptr (Array i64 8192))) 1)))))