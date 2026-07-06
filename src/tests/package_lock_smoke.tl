;; package_lock_smoke.tl - Runnable package lockfile helper smoke.
(import package_lock_core)

(define (main) : i64
  (package_lock_core.package-lock-self-test))