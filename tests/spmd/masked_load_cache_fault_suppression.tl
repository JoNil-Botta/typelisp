;; #5961: a load cached under one child mask may feed its descendants, but not
;; a sibling or a descendant of that sibling. On Linux only the first two i64
;; source elements are mapped. The second source spelling is under an always-
;; empty mask, so a widened or unpredicated load reaches the guard page.
(cfg linux (extern (tl_alloc [bytes : u64]) : u64))

(cfg
  linux
  (define (write-i64! [addr : i64] [value : i64]) : unit
    (unsafe
      (ptr-write! (int->ptr (cast addr : u64) : (MutPtr i64)) value))))

(cfg
  linux
  (define (array-i64-from-raw [data : i64] [len : i64]) : (__tl_dyn-array i64)
    (let
      [descriptor : i64 (cast (tl_alloc (cast 16 : u64)) : i64)]
      [handle : i64 (cast (tl_alloc (cast 8 : u64)) : i64)]
      (begin
        (write-i64! descriptor data)
        (write-i64! (+ descriptor 8) len)
        (write-i64! handle descriptor)
        (unsafe
          (ptr-read (int->ptr (cast handle : u64) : (Ptr (__tl_dyn-array i64)))))))))

(define (masked-cache-copy
  [source : (& source (__tl_dyn-array i64))]
  [destination : (&mut destination (__tl_dyn-array i64))]) : unit
  (foreach
    ([i : i64 0 4])
    (set!
      (array-ref destination i)
      (if (< i 2)
        (if (> (array-ref source i) 0)
          (+ (array-ref source i) 1)
          (- (array-ref source i) 1))
        (if (< i 0)
          (array-ref source i)
          (cast 7 : i64))))))

(cfg
  linux
  (define (fault-suppression-case) : bool
    (let
      [source-map : i64
        (unsafe
          (syscall 9 0 8192 3 34 -1 0))]
      (if (< source-map 0)
        false
        (let
          [source-data : i64 (+ source-map 4080)]
          [guard-status : i64
            (unsafe
              (syscall 11 (+ source-map 4096) 4096))]
          (if (not (= guard-status 0))
            false
            (let
              [source : (__tl_dyn-array i64) (array-i64-from-raw source-data 4)]
              [destination : (__tl_dyn-array i64) (__tl_make-array i64 4)]
              (begin
                (write-i64! source-data 17)
                (write-i64! (+ source-data 8) 29)
                (masked-cache-copy (& source) (&mut destination))
                (let
                  [source-free : i64
                    (unsafe
                      (syscall 11 source-map 4096))]
                  (and
                    (= source-free 0)
                    (= (array-ref destination 0) 18)
                    (= (array-ref destination 1) 30)
                    (= (array-ref destination 2) 7)
                    (= (array-ref destination 3) 7)))))))))))

(cfg
  windows
  (define (fault-suppression-case) : bool
    true))

;; A masked store may alias an earlier load. The read after the store must not
;; reuse the pre-store value, and lowering the sibling arm must remain equally
;; conservative.
(define (mutation-case) : bool
  (let
    [n : i64 13]
    [xs : (__tl_dyn-array i64) (__tl_make-array i64 n)]
    [out : (__tl_dyn-array i64) (__tl_make-array i64 n)]
    [i : i64 0]
    [ok : bool true]
    (begin
      (while (< i n)
        (begin
          (set! (array-ref xs i) i)
          (set! i (+ i 1))))
      (foreach
        ([j : i64 0 n])
        (set!
          (array-ref out j)
          (if (= (bit-and (array-ref xs j) 1) 1)
            (begin
              (set! (array-ref xs j) (+ (array-ref xs j) 7))
              (array-ref xs j))
            (array-ref xs j))))
      (set! i 0)
      (while (< i n)
        (begin
          (let
            [expected : i64
              (if (= (bit-and i 1) 1)
                (+ i 7)
                i)]
            (if (or
              (!= (array-ref xs i) expected)
              (!= (array-ref out i) expected))
              (set! ok false)
              unit))
          (set! i (+ i 1))))
      ok)))

(define (main) : i64
  (if (and (fault-suppression-case) (mutation-case))
    42
    1))