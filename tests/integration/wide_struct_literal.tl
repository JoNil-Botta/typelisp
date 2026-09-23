;; Well-typed twin of tests/safety/wide_struct_literal_reject.tl (#7921): f1001
;; of the written-out Wide compares as the i64 it is, and the members on both
;; sides of the former 1000-member stride keep their own values.
(import wide_struct_literal_decls as decls)

(define (main) : i64
  (let
    [w : decls.Wide (decls.make)]
    [n : decls.Next (decls.Next true false true false)]
    (if (and
      (= w.f999 1000)
      (= w.f1000 1001)
      (= w.f1001 1002)
      (= w.f1002 1003)
      (= w.tail 0)
      n.a
      (not n.b))
      42
      1)))