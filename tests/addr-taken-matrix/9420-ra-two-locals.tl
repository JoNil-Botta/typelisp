;; backend reload elision: two address-taken locals stay live in registers while
;; a call stores through the first one's address.
;; Expected exit 53 at --opt-level 0, 1 and 2.
(define (bump [p : (MutPtr i64)])
  (unsafe
    (ptr-write! p 9)))

(define (main) : i64
  (let
    [a : i64 41]
    [pa : (MutPtr i64)
      (unsafe
        (ptr-addr-of a))]
    [b : i64 3]
    [s : i64 (+ a b)]
    (bump pa)
    (+ s a)))