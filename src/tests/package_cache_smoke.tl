;; package_cache_smoke.tl - Runnable package cache helper smoke.
(import package_cache_core)

(define (main) : i64
  (package_cache_core.package-cache-self-test))