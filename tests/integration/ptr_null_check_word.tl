;; Refs #9670: pointer null checks compare the whole pointer word at every opt
;; level. Words whose low 8 or 32 bits are all zero are still non-null, and the
;; same checks of a constant null take the null branch. A recursive writer keeps
;; the stored words behind a call, so the runtime compares are exercised too.
(define (write-word [slot : (MutPtr u64)] [bits : u64] [depth : i64]) : unit
  (if (> depth 0)
    (write-word slot bits (- depth 1))
    (unsafe
      (ptr-write! slot bits))))

(define (stored-c-fn [bits : u64]) : (CFunc nullable (-> i64 i64))
  (let
    [f : (CFunc nullable (-> i64 i64))
      (ptr-null : (CFunc nullable (-> i64 i64)))]
    (write-word
      (unsafe
        (ptr-cast (ptr-addr-of f) : (MutPtr u64)))
      bits
      3)
    f))

(define (stored-ptr [bits : u64]) : (Ptr u8)
  (let
    [p : (Ptr u8) (ptr-null : (Ptr u8))]
    (write-word
      (unsafe
        (ptr-cast (ptr-addr-of p) : (MutPtr u64)))
      bits
      3)
    p))

;; Each passing check adds its bit; a wrong null verdict leaves a bit clear.
(define (word-score [bits : u64] [bit : i64]) : i64
  (let
    [f : (CFunc nullable (-> i64 i64)) (stored-c-fn bits)]
    [_checked : (CFunc non-null (-> i64 i64)) (c-fn-check f)]
    (if (or (ptr-null? f) (ptr-null? (stored-ptr bits)))
      0
      bit)))

(define (main) : i64
  (if (and
    (ptr-null? (ptr-null : (Ptr u8)))
    (ptr-null? (ptr-null : (CFunc nullable (-> i64 i64))))
    (ptr-null? (stored-ptr 0))
    (ptr-null? (stored-c-fn 0)))
    (+
      (word-score 256 1)
      (+ (word-score 4294967296 2) (+ (word-score 9223372036854775808 4) 35)))
    1))