;# benchmarks/radix_sort/bench.tl - 8-bit LSD radix sort over (u64, i64) pairs.
;#
;# Equivalent to benchmarks/radix_sort/baseline.c. Each round fills a buffer of
;# `count` `(u64 key, i64 val)` records from a deterministic SplitMix64 stream,
;# sorts them by `key` using 8-pass 8-bit LSD radix sort (256-bucket histogram,
;# exclusive prefix sum, and double-buffered ping-pong scatter), asserts
;# non-decreasing key order, and folds all sorted `(key, val)` pairs into a
;# wrapping 64-bit FNV-1a checksum. Record count and round count are runtime
;# CLI arguments.
(import stdlib.io)
(import stdlib.string)
(import stdlib.vector)

(defstruct Record
  (key u64)
  (val i64))

(import (vector.vector Record core) as recvec)

(define rs-hash-basis : u64
  0xcbf29ce484222325)
(define rs-hash-prime : u64
  1099511628211)

(define (rs-mix [h : u64] [v : u64]) : u64
  (* (bit-xor h v) rs-hash-prime))

(define (rs-splitmix [x : u64]) : u64
  (let
    [z : u64 (+ x 0x9e3779b97f4a7c15)]
    (set! z (* (bit-xor z (shr z 30)) 0xbf58476d1ce4e5b9))
    (set! z (* (bit-xor z (shr z 27)) 0x94d049bb133111eb))
    (bit-xor z (shr z 31))))

(define (rs-zero-vec [n : i64]) : recvec.Vec
  (let
    [v : recvec.Vec (recvec.with-capacity n)]
    [i : i64 0]
    (while (< i n)
      (recvec.push! v (Record 0 0))
      (set! i (+ i 1)))
    v))

(define (rs-fill
  [dst : (&mut dst (Slice Record))]
  [n : i64]
  [seed : u64]
  [round : i64]) : u64
  (let
    [state : u64 seed]
    [i : i64 0]
    [r-tag : i64 (* round 1315423911)]
    (while (< i n)
      (set! state (+ state 0x9e3779b97f4a7c15))
      (let
        [k : u64 (rs-splitmix state)]
        [v : i64 (bit-xor i r-tag)]
        (set! (array-ref dst i) (Record k v)))
      (set! i (+ i 1)))
    state))

(define (rs-pass
  [src : (& src (Slice Record))]
  [dst : (&mut dst (Slice Record))]
  [counts : (&mut counts (Array i64 256))]
  [n : i64]
  [shift : u64]) : unit
  (let
    [b : i64 0]
    [i : i64 0]
    [sum : i64 0]
    (while (< b 256)
      (set! (array-ref counts b) 0)
      (set! b (+ b 1)))
    (while (< i n)
      (let
        [rec : Record (array-ref src i)]
        [bucket : i64 (cast (bit-and (shr rec.key shift) 255) : i64)]
        (set! (array-ref counts bucket) (+ (array-ref counts bucket) 1)))
      (set! i (+ i 1)))
    (set! b 0)
    (while (< b 256)
      (let
        [c : i64 (array-ref counts b)]
        (set! (array-ref counts b) sum)
        (set! sum (+ sum c)))
      (set! b (+ b 1)))
    (set! i 0)
    (while (< i n)
      (let
        [rec : Record (array-ref src i)]
        [bucket : i64 (cast (bit-and (shr rec.key shift) 255) : i64)]
        [pos : i64 (array-ref counts bucket)]
        (set! (array-ref counts bucket) (+ pos 1))
        (set! (array-ref dst pos) rec))
      (set! i (+ i 1)))))

(define (rs-verify-and-hash
  [src : (& src (Slice Record))]
  [n : i64]
  [acc : u64]) : u64
  (let
    [h : u64 acc]
    [i : i64 0]
    [prev : u64 0]
    (while (< i n)
      (let
        [rec : Record (array-ref src i)]
        (when
          (and (> i 0) (< rec.key prev))
          (io.panic "radix sort order violation"))
        (set! prev rec.key)
        (set! h (rs-mix h rec.key))
        (set! h (rs-mix h (cast rec.val : u64))))
      (set! i (+ i 1)))
    h))

(define (rs-bench [n : i64] [rounds : i64]) : u64
  (let
    [buf-a : recvec.Vec (rs-zero-vec n)]
    [buf-b : recvec.Vec (rs-zero-vec n)]
    [counts : (Array i64 256) (make-array i64 256)]
    [state : u64 0x123456789abcdef0]
    [acc : u64 rs-hash-basis]
    [round : i64 0]
    (while (< round rounds)
      (set! state (rs-fill (recvec.view-mut (&mut buf-a)) n state round))
      (let
        [shift : u64 0]
        (while (< shift 64)
          (rs-pass
            (recvec.view (& buf-a))
            (recvec.view-mut (&mut buf-b))
            (&mut counts)
            n
            shift)
          (rs-pass
            (recvec.view (& buf-b))
            (recvec.view-mut (&mut buf-a))
            (&mut counts)
            n
            (+ shift 8))
          (set! shift (+ shift 16))))
      (set! acc (rs-verify-and-hash (recvec.view (& buf-a)) n acc))
      (set! round (+ round 1)))
    acc))

(define (main) : i64
  (let
    [n : i64 (string.>int (io.arg 1))]
    [rounds : i64 (string.>int (io.arg 2))]
    (io.println "{}" (rs-bench n rounds))
    0))