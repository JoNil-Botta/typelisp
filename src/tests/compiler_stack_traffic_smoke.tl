(import compiler_stack_traffic_tests as traffic_tests)

(define (main) : i64
  (traffic_tests.compiler-stack-traffic-self-test)
  42)