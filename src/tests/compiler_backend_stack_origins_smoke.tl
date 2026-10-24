(import compiler_backend_stack_origins_tests as fixtures)

(define (main) : i64
  (fixtures.backend-stack-origins-colored-test)
  (fixtures.backend-stack-origins-producer-test)
  (fixtures.backend-stack-origins-rebase-test)
  (fixtures.backend-stack-origins-final-render-test)
  (fixtures.backend-stack-origins-splice-clone-test)
  (fixtures.backend-stack-origins-rmw-test)
  42)