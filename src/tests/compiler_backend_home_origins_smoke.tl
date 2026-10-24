(import compiler_backend_home_origins_tests as fixtures)

(define (main) : i64
  (fixtures.home-origin-tests)
  (fixtures.home-origin-fixed-staging-test)
  42)