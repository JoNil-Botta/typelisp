(import compiler_backend_text_origins_tests as fixtures)

(define (main) : i64
  (fixtures.text-origin-construction-test)
  (fixtures.text-origin-scratch-test)
  (fixtures.text-origin-boundaries-test)
  (fixtures.text-origin-macro-test)
  (fixtures.text-origin-record-test)
  42)