;; The TypeLisp side of the shared-object library check: a `--no-entry` module
;; whose string literal descriptor names its bytes. A sectioned library object
;; gives each literal its own quoted `.rodata.<label>` section, and the
;; shared-object code model must still move the relocated descriptor out of
;; read-only data. scripts/verify-linux-shared-object-code-model.sh builds it.
(define (greeting) : String
  "shared-object library greeting")