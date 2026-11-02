(unsafe
  (define (probe [input : (Ptr (Array i64 8192))] [index : i64])
    (:export-symbol "stack_foreign_probe") : i64
    (let
      [page : (Array i64 8192)
        (unsafe
          (ptr-read input))]
      [_stored : unit (set! (array-ref page index) 42)]
      (+ (array-ref page 0) (array-ref page 8191)))))

(define (main) : i64
  (let
    [input : i64
      (unsafe
        (syscall 9 0 65536 3 0x22 -1 0))]
    (if (< input 0)
      125
      (unsafe
        (probe (int->ptr (cast input : u64) : (Ptr (Array i64 8192))) 0)))))