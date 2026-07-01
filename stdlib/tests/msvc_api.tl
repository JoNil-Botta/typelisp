(cfg test (import stdlib.msvc))

(cfg test (test msvc-candidates (msvc.test-candidates-main)))

(cfg test (test msvc-toolset-fixture (msvc.test-toolset-fixture-main)))

(cfg test (test msvc-toolset-read-dir (msvc.test-toolset-read-dir-main)))

(cfg
  test
  (test msvc-toolset-scan-entries (msvc.test-toolset-scan-entries-main)))

(cfg test (test msvc-toolset-find (msvc.test-toolset-find-main)))

(cfg test (test msvc-sdk-scan (msvc.test-sdk-scan-main)))