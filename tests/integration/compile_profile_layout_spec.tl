;; compile_profile_layout_spec.tl - Fixture for layout/spec compile-profile rows.
(import "stdlib/comptime.tl")

(defstruct ProfileInner
  (a i32)
  (b i64)
  (c bool)
  (d u16))

(defstruct ProfileWide
  (tag u8)
  (inner ProfileInner)
  (left i64)
  (right i64)
  (flag bool)
  (tail u32))

(defenum ProfileChoice
  (ProfileNone)
  (ProfilePair i64 i64)
  (ProfileWidePayload ProfileWide i32 bool))

(defstruct ProfileCInner
  (:repr c)
  (x i32)
  (y i64))

(defstruct ProfileCOuter
  (:repr c)
  (head u8)
  (inner ProfileCInner)
  (tail i64))

(extern (profile-c-roundtrip [value : ProfileCOuter]) : ProfileCOuter (:symbol "tl_profile_c_roundtrip"))

(define profile-struct-layout-score : i64
  (comptime
    (+
      (size-of (type ProfileWide))
      (+
        (align-of (type ProfileWide))
        (+
          (offset-of (type ProfileWide) inner)
          (+ (offset-of (type ProfileWide) tail) (size-of (type ProfileInner))))))))
(define profile-enum-layout-score : i64
  (comptime
    (+
      (size-of (type ProfileChoice))
      (+
        (align-of (type ProfileChoice))
        (+ (size-of (type ProfileWide)) (size-of (type ProfileChoice)))))))

(define (profile-layout-use [value : ProfileWide]) : i64
  (+
    (struct-get value left)
    (+ (struct-get value right) profile-struct-layout-score)))

(define (main) : i64
  42)