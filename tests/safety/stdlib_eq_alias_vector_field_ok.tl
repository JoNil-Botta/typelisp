;: A full-mode vector compares its elements through their owner equality hooks.
;: A field written through a generic alias resolves (#8474), and a vector-valued
;: field compares through the generated vector's own `eq-vec` owner hook, so
;: `(eq.gen Row)` accepts it.
(import stdlib.clone)
(import stdlib.eq)
(import stdlib.vector)
(import (vector.vector String) as svec)

(defstruct Row
  (fields svec.Vec))

(stdlib.clone.gen-clone Row)

(eq.gen Row)

(import (vector.vector Row) as row-vec)

(define (main) : i64
  (let
    [rows : row-vec.Vec (row-vec.new)]
    [fields : svec.Vec (svec.new)]
    [probe : Row (Row (svec.new))]
    (svec.push! fields "a")
    (row-vec.push! rows (Row fields))
    (if (row-vec.contains? (& rows) (& probe))
      0
      (row-vec.len (& rows)))))