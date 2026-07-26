;; #5674: inactive AVX2 masked-load and masked-store lanes may point into an
;; unmapped page. The active two i64 lanes end exactly at the preceding page
;; boundary, so a full-width memory access faults while vpmaskmovq must not.
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
  (define (masked-copy [source : (Array i64)] [destination : (Array i64)]) : unit
    (foreach
      ([i : i64 0 4])
      (if (< i 2)
        (array-set! destination i (array-ref source i))
        unit))))

(cfg
  linux
  (define (main) : i64
    (let
      [source-map : i64
        (unsafe
          (syscall 9 0 8192 3 34 -1 0))]
      [destination-map : i64
        (unsafe
          (syscall 9 0 8192 3 34 -1 0))]
      (if (or (< source-map 0) (< destination-map 0))
        2
        (let
          [source-data : i64 (+ source-map 4080)]
          [destination-data : i64 (+ destination-map 4080)]
          [source-guard-status : i64
            (unsafe
              (syscall 11 (+ source-map 4096) 4096))]
          [destination-guard-status : i64
            (unsafe
              (syscall 11 (+ destination-map 4096) 4096))]
          (if (or
            (not (= source-guard-status 0))
            (not (= destination-guard-status 0)))
            3
            (let
              [source : (Array i64) (array-i64-from-raw source-data 4)]
              [destination : (Array i64)
                (array-i64-from-raw destination-data 4)]
              (begin
                (write-i64! source-data 17)
                (write-i64! (+ source-data 8) 29)
                (write-i64! destination-data 0)
                (write-i64! (+ destination-data 8) 0)
                (masked-copy source destination)
                (let
                  [first : i64 (read-i64 destination-data)]
                  [second : i64 (read-i64 (+ destination-data 8))]
                  [_source-free : i64
                    (unsafe
                      (syscall 11 source-map 4096))]
                  [_destination-free : i64
                    (unsafe
                      (syscall 11 destination-map 4096))]
                  (if (and (= first 17) (= second 29))
                    42
                    4))))))))))

(cfg
  windows
  (define (main) : i64
    42))