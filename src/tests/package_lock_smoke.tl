;; package_lock_smoke.tl - Runnable package lockfile helper smoke (#1993).
(import "../package_lock_core.tl")

(define (main) : i64
  (package-lock-self-test))