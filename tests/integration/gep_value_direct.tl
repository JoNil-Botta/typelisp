(import "stdlib/io.tl")
(import stdlib.string)

;; FORCING TEST for GAP6b: a variable-index GEP used AS A VALUE (an address
;; materialization, not a fused load/store) composes its element address in ONE
;; leaq off the register-homed base and index -- not through two staging copies.
;;
;; `string.string-append` (inlined into `cat` at opt2) computes the destination
;; address `dest_data + a_len` for its second memcpy: a byte-scale (scale-1) GEP
;; whose result is a VALUE (the memcpy pointer argument), not a load/store, so it
;; is emitted as a standalone GEP. Before GAP6b the backend staged both operands:
;;     movq %rBASE, %rdi
;;     movq %rIDX,  %r8
;;     addq %r8, %rdi
;; After GAP6b the homes compose directly:
;;     leaq (%rBASE, %rIDX, 1), %rdi
;;
;; The never-taken self-recursion blocks the opt2 inliner from folding `cat`
;; away. A wrong address corrupts the concatenation (length != 5) -> not 42;
;; target/gep-value-gate.sh asserts the leaq reads the register homes directly.
(define (cat [a : String] [b : String] [poke : i64]) : String
  (if (< poke 0)
    (cat a b (+ poke 1))
    (string.string-append a b)))

(define (main) : i64
  (let
    [s : String (cat "abc" "de" 0)]
    (if (= (string.string-length s) 5)
      42
      1)))