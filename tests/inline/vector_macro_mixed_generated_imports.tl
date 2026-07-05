;; vector_macro_mixed_generated_imports.tl - mixed bare and aliased generated
;; vector imports should converge without a whole-program macro restart loop.
(import stdlib.test)
(import stdlib.vector)
(import (vector.vector i64))
(import (vector.vector String) as svec)

(test
  vector-macro-mixed-bare-and-aliased-generated-imports
  (let
    [v : Vec (new)]
    [words : svec.Vec (svec.new)]
    (begin
      (push (&mut v) 10)
      (push (&mut v) 32)
      (svec.push (&mut words) "x")
      (test.assert-i64-eq
        (+ (len (& v)) (svec.len (& words)))
        3
        "mixed generated vector imports length"))))