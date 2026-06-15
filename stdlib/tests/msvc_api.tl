(import stdlib.fs)

(import stdlib.io)

(import stdlib.msvc)

(import stdlib.test)

(import stdlib.vector)

(define (assert-owned-string-eq
  [actual : String]
  [expected : String]
  [message : String]) : unit
  (test.assert-string-eq (& actual) (& expected) message))

(define (expect-ok-string [result : io.ResultIoString] [message : String]) : String
  (match result
    [(io.OkIoString value) value]
    [(io.ErrIoString error)
      (io.panic (string-append message (io.io-error-message error)))]))

(define (assert-ok-unit [result : io.ResultIoUnit] [message : String]) : unit
  (match result
    [(io.OkIoUnit) unit]
    [(io.ErrIoUnit error) (io.panic (string-append message (io.io-error-message error)))]))

(define (mkdir-ok [path : String] [message : String]) : unit
  (assert-ok-unit (fs.try-mkdir-if-missing (& path)) message))

(define (write-ok [path : String] [contents : String] [message : String]) : unit
  (assert-ok-unit (io.try-write-file (& path) (& contents)) message))

(define (mkdir-toolset-bin [toolset-root : String]) : String
  (let
    [bin-root : String (msvc.msvc-path-join toolset-root "bin")]
    [host-root : String (msvc.msvc-path-join bin-root "Hostx64")]
    [target-root : String (msvc.msvc-path-join host-root "x64")]
    (begin
      (mkdir-ok bin-root "toolset bin root: ")
      (mkdir-ok host-root "toolset host root: ")
      (mkdir-ok target-root "toolset target root: ")
      target-root)))

(define (make-toolset-version
  [parent : String]
  [version : String]
  [with-tool : bool]) : String
  (let
    [toolset-root : String (msvc.msvc-path-join parent version)]
    (begin
      (mkdir-ok toolset-root "toolset version root: ")
      (let
        [target-root : String (mkdir-toolset-bin toolset-root)]
        (if with-tool
          (write-ok
            (msvc.msvc-path-join target-root "link.exe")
            "fake"
            "toolset tool: ")
          unit))
      toolset-root)))

(define (assert-toolset-scan [parent : String]) : unit
  (let
    [old-root : String (make-toolset-version parent "14.10.0" true)]
    [new-root : String (make-toolset-version parent "14.20.0" true)]
    [_ignored-root : String (make-toolset-version parent "14.99.0" false)]
    (match (msvc.msvc-find-toolset-in-parent parent "link.exe")
      [(msvc.MsvcSomeToolset toolset)
        (begin
          (assert-owned-string-eq
            (struct-get toolset version)
            "14.20.0"
            "toolset scan picks newest usable version")
          (assert-owned-string-eq
            (struct-get toolset root)
            new-root
            "toolset scan returns newest usable root")
          (test.assert-true
            (not (string-eq old-root new-root))
            "toolset roots are distinct"))]
      [(msvc.MsvcNoToolset) (io.panic "toolset scan found no usable version")])))

(define (mkdir-sdk-version-roots [sdk-root : String] [version : String]) : unit
  (let
    [lib-root : String (msvc.msvc-path-join sdk-root "Lib")]
    [include-root : String (msvc.msvc-path-join sdk-root "Include")]
    [lib-version : String (msvc.msvc-path-join lib-root version)]
    [include-version : String (msvc.msvc-path-join include-root version)]
    [um-root : String (msvc.msvc-path-join lib-version "um")]
    [ucrt-root : String (msvc.msvc-path-join lib-version "ucrt")]
    (begin
      (mkdir-ok lib-root "sdk lib root: ")
      (mkdir-ok include-root "sdk include root: ")
      (mkdir-ok lib-version "sdk lib version: ")
      (mkdir-ok include-version "sdk include version: ")
      (mkdir-ok um-root "sdk um root: ")
      (mkdir-ok (msvc.msvc-path-join um-root "x64") "sdk um x64: ")
      (mkdir-ok ucrt-root "sdk ucrt root: ")
      (mkdir-ok (msvc.msvc-path-join ucrt-root "x64") "sdk ucrt x64: ")
      (mkdir-ok
        (msvc.msvc-path-join include-version "shared")
        "sdk shared include: ")
      (mkdir-ok (msvc.msvc-path-join include-version "um") "sdk um include: ")
      (mkdir-ok (msvc.msvc-path-join include-version "ucrt") "sdk ucrt include: "))))

(define (make-sdk-version
  [sdk-root : String]
  [version : String]
  [usable : bool]) : unit
  (begin
    (mkdir-sdk-version-roots sdk-root version)
    (if usable
      (let
        [lib-version : String
          (msvc.msvc-path-join (msvc.msvc-path-join sdk-root "Lib") version)]
        (begin
          (write-ok
            (msvc.msvc-path-join
              (msvc.msvc-path-join lib-version "um/x64")
              "kernel32.lib")
            "kernel32"
            "sdk kernel32 lib: ")
          (write-ok
            (msvc.msvc-path-join (msvc.msvc-path-join lib-version "ucrt/x64") "ucrt.lib")
            "ucrt"
            "sdk ucrt lib: ")))
      unit)))

(define (assert-sdk-scan [sdk-root : String]) : unit
  (begin
    (make-sdk-version sdk-root "10.0.1" true)
    (make-sdk-version sdk-root "10.0.2" true)
    (make-sdk-version sdk-root "10.0.9" false)
    (match (msvc.msvc-find-sdk-in-root sdk-root)
      [(msvc.MsvcSomeSdk sdk)
        (begin
          (assert-owned-string-eq
            (struct-get sdk root)
            sdk-root
            "sdk scan returns root")
          (assert-owned-string-eq
            (struct-get sdk version)
            "10.0.2"
            "sdk scan picks newest usable version"))]
      [(msvc.MsvcNoSdk) (io.panic "sdk scan found no usable version")])))

(define (main) : i64
  (let
    [prefix : String "typelisp msvc vector scan"]
    [root : String
      (expect-ok-string
        (fs.try-create-temp-dir (& prefix))
        "create msvc test root: ")]
    [toolset-parent : String (msvc.msvc-path-join root "ToolsMSVC")]
    [sdk-root : String (msvc.msvc-path-join root "WindowsKits10")]
    (begin
      (mkdir-ok toolset-parent "toolset parent: ")
      (mkdir-ok sdk-root "sdk root: ")
      (test.assert-i64-eq
        (vector.string-vec-len (msvc.msvc-toolset-parent-candidates))
        8
        "standard toolset candidate count")
      (assert-toolset-scan toolset-parent)
      (assert-sdk-scan sdk-root)
      42)))