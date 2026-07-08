;; Regression guard for #4463: unsafe ptr-addr-of on register-resident
;; aggregate locals must expose the local's real storage, not a temporary copy.
;; Writes through field pointers must be visible to later ordinary struct-get
;; reads of the same local.
(defstruct Tiny
  (a i32)
  (b i32))

(defstruct Pair
  (x i64)
  (y i64))

(defstruct Wrap
  (tiny Tiny))

(define (one-word-field-write-score) : i64
  (let
    [item : Tiny (Tiny (cast 10 : i32) (cast 20 : i32))]
    [field : (MutPtr i32)
      (unsafe
        (ptr-addr-of (struct-get item b)))]
    (begin
      (unsafe
        (ptr-write! field (cast 33 : i32)))
      (+ (cast (struct-get item a) : i64) (cast (struct-get item b) : i64)))))

(define (two-word-field-write-score) : i64
  (let
    [item : Pair (Pair 40 50)]
    [field : (MutPtr i64)
      (unsafe
        (ptr-addr-of (struct-get item y)))]
    (begin
      (unsafe
        (ptr-write! field 77))
      (+ (struct-get item x) (struct-get item y)))))

(define (whole-local-address-score) : i64
  (let
    [item : Pair (Pair 3 4)]
    [addr : (MutPtr Pair)
      (unsafe
        (ptr-addr-of item))]
    [field : (MutPtr i64)
      (unsafe
        (ptr-addr-of (struct-get item x)))]
    (begin
      (unsafe
        (ptr-write! field 9))
      (if (=
        (unsafe
          (ptr->int addr))
        (unsafe
          (ptr->int (ptr-addr-of item))))
        (+ (struct-get item x) (struct-get item y))
        1000))))

(define (nested-field-write-score) : i64
  (let
    [wrap : Wrap (Wrap (Tiny (cast 11 : i32) (cast 12 : i32)))]
    [field : (MutPtr i32)
      (unsafe
        (ptr-addr-of (struct-get (struct-get wrap tiny) b)))]
    (begin
      (unsafe
        (ptr-write! field (cast 44 : i32)))
      (+
        (cast (struct-get (struct-get wrap tiny) a) : i64)
        (cast (struct-get (struct-get wrap tiny) b) : i64)))))

(define (main) : i64
  (let
    [one : i64 (one-word-field-write-score)]
    [two : i64 (two-word-field-write-score)]
    [whole : i64 (whole-local-address-score)]
    [nested : i64 (nested-field-write-score)]
    (cond
      [(not (= one 43)) 1]
      [(not (= two 117)) 2]
      [(not (= whole 13)) 3]
      [(not (= nested 55)) 4]
      [else 0])))