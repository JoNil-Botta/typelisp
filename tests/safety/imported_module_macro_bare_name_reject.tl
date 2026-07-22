(import stdlib.vector)

;; Imported macros require their provider qualifier. The import above binds
;; `vector`, so this must be spelled `(vector.vector i64)`.
(import (vector i64) as vec)