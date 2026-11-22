;; backend reload elision: the pointer local itself is address-taken, and a call
;; retargets it; the later deref must reload the pointer from its slot.
;; Expected exit 12 at --opt-level 0, 1 and 2.
(define (retarget [pp : (MutPtr (MutPtr i64))] [q : (MutPtr i64)])
  (unsafe
    (ptr-write! pp q)))

(define (main) : i64
  (let
    [v : i64 5]
    [w : i64 7]
    [pv : (MutPtr i64)
      (unsafe
        (ptr-addr-of v))]
    [pw : (MutPtr i64)
      (unsafe
        (ptr-addr-of w))]
    [pp : (MutPtr (MutPtr i64))
      (unsafe
        (ptr-addr-of pv))]
    [d : i64
      (unsafe
        (ptr-read pv))]
    (retarget pp pw)
    (+
      d
      (unsafe
        (ptr-read pv)))))