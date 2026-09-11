;; Check-only positive controls. Callers explicitly accept the documented raw
;; range, overflow, alignment, lifetime, overlap, and fresh-storage contracts.
(import stdlib.runtime)

(define (raw-write [fd : i64] [src : (Ptr u8)] [count : i64]) : i64
  (unsafe
    (runtime.os-write fd src count)))

(define (raw-substring [src : (Ptr u8)] [start : i64] [len : i64]) : String
  (unsafe
    (runtime.substring src start len)))

(define (raw-view [text : (& text str)] [start : i64] [len : i64]) : String
  (unsafe
    (runtime.str-view text start len)))

(define (raw-concat2 [a : (Ptr u8)] [a-len : i64] [b : (Ptr u8)] [b-len : i64]) : String
  (unsafe
    (runtime.string-concat a a-len b b-len)))

(define (raw-concat3
  [a : (Ptr u8)]
  [a-len : i64]
  [b : (Ptr u8)]
  [b-len : i64]
  [c : (Ptr u8)]
  [c-len : i64]) : String
  (unsafe
    (runtime.string-concat3 a a-len b b-len c c-len)))

(define (raw-concat4
  [a : (Ptr u8)]
  [a-len : i64]
  [b : (Ptr u8)]
  [b-len : i64]
  [c : (Ptr u8)]
  [c-len : i64]
  [d : (Ptr u8)]
  [d-len : i64]) : String
  (unsafe
    (runtime.string-concat4 a a-len b b-len c c-len d d-len)))

(define (raw-concat5
  [a : (Ptr u8)]
  [a-len : i64]
  [b : (Ptr u8)]
  [b-len : i64]
  [c : (Ptr u8)]
  [c-len : i64]
  [d : (Ptr u8)]
  [d-len : i64]
  [e : (Ptr u8)]
  [e-len : i64]) : String
  (unsafe
    (runtime.string-concat5 a a-len b b-len c c-len d d-len e e-len)))

(define (raw-fill-copy-zero
  [dst : (MutPtr u8)]
  [src : (Ptr u8)]
  [slots : i64]
  [bytes : i64]) : unit
  (unsafe
    (begin
      (runtime.array-fill8 dst slots (cast 0 : u64))
      (runtime.mem-fill8 dst slots (cast 0 : u64))
      (runtime.mem-copy-fwd dst src bytes)
      (runtime.array-zero dst bytes))))

(define (raw-site-word [site : (Ptr i64)] [offset : i64]) : i64
  (unsafe
    (runtime.abort-site-word site offset)))

(define (raw-write-site [site : (Ptr i64)]) : unit
  (unsafe
    (runtime.abort-write-site site)))

(define (raw-oob [site : (Ptr i64)] [index : i64] [length : i64]) : never
  (unsafe
    (runtime.oob-abort-at site index length)))

(define (raw-div [site : (Ptr i64)] [dividend : i64] [divisor : i64]) : never
  (unsafe
    (runtime.div-abort-at site dividend divisor)))

(define (raw-shift
  [site : (Ptr i64)]
  [count : i64]
  [width : i64]
  [unsigned-count? : bool]) : never
  (unsafe
    (runtime.shift-abort-at site count width unsigned-count?)))

(define (raw-panic [site : (Ptr i64)] [message : (& message str)]) : never
  (unsafe
    (runtime.panic-abort-at site message)))

(define (main) : i64
  0)