(module spmd_unsafe_consumer)

(import fixture.src.lib as fixture)

(fixture.package-decls)

(define (main) : i64
  (let
    [leaked : (-> i64 i64)
      (unsafe
        package-unsafe-answer)]
    (leaked 42)))