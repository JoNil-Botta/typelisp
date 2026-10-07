(module cleanup_hook_unsafe_dep)

;; An unsafe declaration another module names as a cleanup hook (#8267).
(unsafe
  (define (raw-close [fd : i64]) : unit
    unit))

(define (safe-close [fd : i64]) : unit
  unit)