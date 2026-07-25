;; tlci_native_wildcard_arms.tl - drive the wildcard arms of the tlci
;; `(match (type-kind T) ...)` bodies through whichever macro route the compiler
;; selects, so the embedded (native) and comment-modified-root (interpreted)
;; routes can be compared for byte-identical assembly.
;;
;; `stdlib.hash/hash` matches `"unit"` and generates its module in the wildcard
;; arm, so every type except `unit` goes through it; `stdlib.eq/inline-eq`
;; dispatches its supported kinds by literal and raises a comptime error in the
;; wildcard arm. Both arms were interpreted per invocation until #5658.
;; Exit code: 42
(import stdlib.eq)
(import stdlib.hash)

(defstruct Pt
  (x i64)
  (y i64))

(import (hash.hash i64) as hash_i64)
(import (hash.hash String) as hash_str)
(import (hash.hash Pt) as hash_pt)
(import (eq.eq Pt) as eq_pt)

(define (main) : i64
  (if (and
    (eq_pt.eq (Pt 3 4) (Pt 3 4))
    (not (eq_pt.eq (Pt 3 4) (Pt 3 5)))
    (= (hash_pt.hash (Pt 3 4)) (hash_pt.hash (Pt 3 4)))
    (!= (hash_pt.hash (Pt 3 4)) (hash_pt.hash (Pt 3 5)))
    (= (hash_i64.hash 7) (hash_i64.hash 7))
    (!= (hash_i64.hash 7) (hash_i64.hash 8))
    (= (hash_str.hash "abc") (hash_str.hash "abc"))
    (!= (hash_str.hash "abc") (hash_str.hash "abd")))
    42
    1))