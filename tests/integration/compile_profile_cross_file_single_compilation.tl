;; compile_profile_cross_file_single_compilation.tl - plan P1 single-compilation
;; invariant. Three separate modules (three files) each import the same generated
;; instantiation (vector i64). The program-global content-addressed memo
;; materializes and typechecks that identity exactly once; the two later importers
;; resolve through the memo and emit only marker/alias imports, so the run records
;; a single materialization for the identity and at least two
;; generated_module_memo_hits.
(import cross_single_a as a)
(import cross_single_b as b)
(import cross_single_c as c)

(define (main) : i64
  (if (= (+ (a.count) (+ (b.count) (c.count))) 0)
    42
    0))