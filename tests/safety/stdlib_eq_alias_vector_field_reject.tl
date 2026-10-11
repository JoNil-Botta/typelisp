;: A full-mode vector reflects its element for `contains?` equality. A field
;: written through a generic alias resolves (#8474), and a vector-valued field
;: is then rejected for its dynamic buffer, as a dynamic array is.
(import stdlib.vector)
(import (vector.vector String) as svec)

(defstruct Row
  (fields svec.Vec))

(import (vector.vector Row) as row-vec)

(define (main) : i64
  (let
    [rows : row-vec.Vec (row-vec.new)]
    (row-vec.len (& rows))))