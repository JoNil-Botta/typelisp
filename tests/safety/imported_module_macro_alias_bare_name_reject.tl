(import stdlib.vector as v)

;; Provider aliases qualify imported macros; they do not rename the macro.
;; This must be spelled `(v.vector i64)`.
(import (v i64) as vec)