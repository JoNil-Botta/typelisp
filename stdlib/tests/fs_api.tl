(cfg test (import stdlib.fs))
(cfg test (import stdlib.io))

(cfg
  test
  (test
    fs-api
    (if (= (fs.fs-test-api-main) 42)
      unit
      (io.panic "fs-api did not return 42"))))