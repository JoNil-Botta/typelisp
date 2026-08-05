;; #5960: contiguous simple-map tails use one predicated vector load/store.
;; For each possible partial AVX2 i64 gang (one, two, or three active lanes),
;; the backing data ends exactly at an unmapped page. A full-width access would
;; fault, so successful scalar/AVX2/AVX-512 parity proves inactive lanes remain
;; suppressed.
(cfg linux (extern (tl_alloc [bytes : u64]) : u64))

(cfg
  linux
  (define (write-i64! [addr : i64] [value : i64]) : unit
    (unsafe
      (ptr-write! (int->ptr (cast addr : u64) : (MutPtr i64)) value))))

(cfg
  linux
  (define (read-i64 [addr : i64]) : i64
    (unsafe
      (ptr-read (int->ptr (cast addr : u64) : (Ptr i64))))))

(cfg
  linux
  (define (array-i64-from-raw [data : i64] [len : i64]) : (Array i64)
    (let
      [descriptor : i64 (cast (tl_alloc (cast 16 : u64)) : i64)]
      [handle : i64 (cast (tl_alloc (cast 8 : u64)) : i64)]
      (begin
        (write-i64! descriptor data)
        (write-i64! (+ descriptor 8) len)
        (write-i64! handle descriptor)
        (unsafe
          (ptr-read (int->ptr (cast handle : u64) : (Ptr (Array i64)))))))))

(cfg
  linux
  (define (copy-tail
    [source : (Array i64)]
    [destination : (Array i64)]
    [n : i64]) : unit
    (foreach
      ([i : i64 0 n])
      (array-set! destination i (+ (array-ref source i) 1)))))

(cfg
  linux
  (define (run-tail [n : i64]) : bool
    (let
      [source-map : i64
        (unsafe
          (syscall 9 0 8192 3 34 -1 0))]
      [destination-map : i64
        (unsafe
          (syscall 9 0 8192 3 34 -1 0))]
      (if (or (< source-map 0) (< destination-map 0))
        false
        (let
          [source-data : i64 (+ source-map (- 4096 (* n 8)))]
          [destination-data : i64 (+ destination-map (- 4096 (* n 8)))]
          [source-guard-status : i64
            (unsafe
              (syscall 11 (+ source-map 4096) 4096))]
          [destination-guard-status : i64
            (unsafe
              (syscall 11 (+ destination-map 4096) 4096))]
          (if (or
            (not (= source-guard-status 0))
            (not (= destination-guard-status 0)))
            false
            (let
              [source : (Array i64) (array-i64-from-raw source-data n)]
              [destination : (Array i64)
                (array-i64-from-raw destination-data n)]
              [index : i64 0]
              [ok : bool true]
              (begin
                (while (< index n)
                  (begin
                    (write-i64! (+ source-data (* index 8)) (+ 40 index))
                    (write-i64! (+ destination-data (* index 8)) 0)
                    (set! index (+ index 1))))
                (copy-tail source destination n)
                (set! index 0)
                (while (< index n)
                  (begin
                    (if (not
                      (=
                        (read-i64 (+ destination-data (* index 8)))
                        (+ 41 index)))
                      (set! ok false)
                      unit)
                    (set! index (+ index 1))))
                (let
                  [source-free : i64
                    (unsafe
                      (syscall 11 source-map 4096))]
                  [destination-free : i64
                    (unsafe
                      (syscall 11 destination-map 4096))]
                  (and ok (= source-free 0) (= destination-free 0)))))))))))

(cfg
  linux
  (define (main) : i64
    (if (and (run-tail 1) (run-tail 2) (run-tail 3))
      42
      4)))

(cfg
  windows
  (define (main) : i64
    42))