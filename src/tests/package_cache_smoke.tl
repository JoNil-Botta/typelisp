;; package_cache_smoke.tl - Runnable package cache helper smoke (#2002).
(import "../package_cache_core.tl")

(define (main) : i64
  (package-cache-self-test))