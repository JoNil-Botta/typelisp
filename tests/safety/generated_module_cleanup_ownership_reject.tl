;; A generated struct field of a cleanup-owning type needs :owned.
(defmacro (cleanup-field [T : type (:kind i64 struct)]) : Module
  (let
    [module-name : Expr
      (expr-var (string-append "generated.cleanup_field." (type-key T)))]
    `(begin
      (module ,module-name)
      (defstruct GeneratedCleanupValue
        (value ,T)))))

(define cleanup-file-handle-total : i64
  0)

(define (cleanup-file-handle-fd [fd : i64]) : unit
  (set! cleanup-file-handle-total (+ cleanup-file-handle-total fd)))

(defstruct FileHandle
  (:cleanup cleanup-file-handle)
  (fd i64 (:cleanup cleanup-file-handle-fd)))

(import (cleanup-field i64) as cleanup_i64)
(import (cleanup-field FileHandle) as cleanup_file)

(define (main) : i64
  42)