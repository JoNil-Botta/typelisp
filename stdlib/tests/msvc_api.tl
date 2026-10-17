(cfg test (import stdlib.msvc))
(cfg test (import stdlib.process))
(cfg test (import stdlib.test))

(cfg
  test
  (test
    msvc-tool-borrowed-environment
    (let
      [tool : msvc.MsvcTool (msvc.MsvcTool "link" "path" "lib" "include")]
      [env : process.ProcessEnvList (msvc.tool-process-env tool)]
      [env-vec : process.ProcessEnvVec (msvc.tool-process-env-vec tool)]
      [rows : process.ProcessEnvList (process.env-vec-to-list env-vec)]
      (test.assert-string-eq (msvc.tool-path tool) "path" "borrowed PATH")
      (test.assert-string-eq (msvc.tool-lib tool) "lib" "borrowed LIB")
      (test.assert-string-eq
        (msvc.tool-include tool)
        "include"
        "borrowed INCLUDE")
      (set! tool.path "changed")
      (set! tool.lib "changed")
      (set! tool.include "changed")
      (test.assert-i64-eq (process.env-count env) 3 "owned environment count")
      (test.assert-i64-eq
        (process.env-count rows)
        3
        "owned vector environment count")
      (test.assert-string-eq
        (& (process.env-value-ref env 0))
        "path"
        "owned PATH")
      (test.assert-string-eq
        (& (process.env-value-ref env 1))
        "lib"
        "owned LIB")
      (test.assert-string-eq
        (& (process.env-value-ref env 2))
        "include"
        "owned INCLUDE")
      (test.assert-string-eq
        (& (process.env-value-ref rows 0))
        "path"
        "vector PATH")
      (test.assert-string-eq
        (& (process.env-value-ref rows 1))
        "lib"
        "vector LIB")
      (test.assert-string-eq
        (& (process.env-value-ref rows 2))
        "include"
        "vector INCLUDE"))))

(cfg test (test msvc-candidates (msvc.test-candidates-main)))

(cfg test (test msvc-toolset-fixture (msvc.test-toolset-fixture-main)))

(cfg test (test msvc-toolset-read-dir (msvc.test-toolset-read-dir-main)))

(cfg
  test
  (test msvc-toolset-scan-entries (msvc.test-toolset-scan-entries-main)))

(cfg test (test msvc-toolset-find (msvc.test-toolset-find-main)))

(cfg test (test msvc-sdk-scan (msvc.test-sdk-scan-main)))