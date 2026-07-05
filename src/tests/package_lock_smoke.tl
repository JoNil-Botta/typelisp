;; package_lock_smoke.tl - Runnable package lockfile helper smoke.
(import "../package_lock_core.tl")

(define (main) : i64
  (package-lock-self-test))