;# Windows SDK discovery helpers (#1016).
;#
;# This module models the Windows SDK include/lib/bin layout needed by the
;# future MSVC linker environment. The first slice honors `WindowsSdkDir` and
;# `WindowsSDKVersion` environment overrides and validates the resulting
;# filesystem layout before registry probing. Registry-backed discovery uses
;# the narrow `stdlib/windows_registry.tl` SDK install probe.
;#
;# Usage: `(import "stdlib/windows_sdk.tl")`
;#
;# ```typelisp
;# (import "stdlib/windows_sdk.tl")
;# (define sdk : ResultWindowsSdkLayout (windows-sdk-discover))
;# ```
(import "env.tl")

(import "io.tl")

(import "string.tl")

(import "windows_registry.tl")

;: Concrete Windows SDK paths needed by an x64 MSVC link environment.
(defstruct WindowsSdkLayout
  (root String)
  (version String)
  (include-ucrt String)
  (include-um String)
  (include-shared String)
  (lib-ucrt-x64 String)
  (lib-um-x64 String)
  (bin-x64 String))

;: Structured SDK discovery failures.
(defenum WindowsSdkError
  (WindowsSdkUnsupported String)
  (WindowsSdkMissingEnvironment String)
  (WindowsSdkInvalidLayout String)
  (WindowsSdkRegistryUnavailable String))

;: Result type for SDK discovery.
(defenum ResultWindowsSdkLayout
  (OkWindowsSdkLayout WindowsSdkLayout)
  (ErrWindowsSdkLayout WindowsSdkError))

;: Optional string used by layout validation.
(defenum WindowsSdkMaybeString
  (WindowsSdkNoString)
  (WindowsSdkSomeString String))

;: Return the SDK root directory.
(define (windows-sdk-root [layout : WindowsSdkLayout]) : String
  (struct-get layout root))

;: Return the SDK version directory name.
(define (windows-sdk-version [layout : WindowsSdkLayout]) : String
  (struct-get layout version))

;: Return the UCRT include directory.
(define (windows-sdk-include-ucrt [layout : WindowsSdkLayout]) : String
  (struct-get layout include-ucrt))

;: Return the UM include directory.
(define (windows-sdk-include-um [layout : WindowsSdkLayout]) : String
  (struct-get layout include-um))

;: Return the shared include directory.
(define (windows-sdk-include-shared [layout : WindowsSdkLayout]) : String
  (struct-get layout include-shared))

;: Return the x64 UCRT library directory.
(define (windows-sdk-lib-ucrt-x64 [layout : WindowsSdkLayout]) : String
  (struct-get layout lib-ucrt-x64))

;: Return the x64 UM library directory.
(define (windows-sdk-lib-um-x64 [layout : WindowsSdkLayout]) : String
  (struct-get layout lib-um-x64))

;: Return the x64 SDK tool directory.
(define (windows-sdk-bin-x64 [layout : WindowsSdkLayout]) : String
  (struct-get layout bin-x64))

;: Render a discovery error as a diagnostic message.
(define (windows-sdk-error-message [error : WindowsSdkError]) : String
  (match error
    [(WindowsSdkUnsupported message) message]
    [(WindowsSdkMissingEnvironment message) message]
    [(WindowsSdkInvalidLayout message) message]
    [(WindowsSdkRegistryUnavailable message) message]))

;: Return true when the host path-list separator identifies Windows.
(define (windows-sdk-host-windows?) : bool
  (string-eq (env-path-list-separator) ";"))

;: Return true when `c` is a path separator accepted by Windows.
(define (windows-sdk-separator-char? [c : char]) : bool
  (if (char-eq c #/')
    true
    (char-eq c #\\')))

;: Return true when `text` ends with a path separator.
(define (windows-sdk-ends-with-separator? [text : (& text str)]) : bool
  (let
    [n : i64 (string-length text)]
    (if (= n 0)
      false
      (windows-sdk-separator-char? (string-ref text (- n 1))))))

;: Trim trailing path separators from `text`.
(define (windows-sdk-trim-trailing-separators-from
  [text : (& text str)]
  [n : i64]) : String
  (if (= n 0)
    ""
    (if (windows-sdk-separator-char? (string-ref text (- n 1)))
      (windows-sdk-trim-trailing-separators-from text (- n 1))
      (substring text 0 n))))

;: Trim trailing path separators from `text`.
(define (windows-sdk-trim-trailing-separators [text : (& text str)]) : String
  (windows-sdk-trim-trailing-separators-from text (string-length text)))

;: Trim an owned string through the borrowed public helper.
(define (windows-sdk-trim-trailing-separators-owned [text : String]) : String
  (windows-sdk-trim-trailing-separators (& text)))

;: Return true when `root` contains a forward slash separator.
(define (windows-sdk-root-contains-forward-slash? [root : (& root str)]) : bool
  (let
    [n : i64 (string-length root)]
    [i : i64 0]
    [found : bool false]
    (begin
      (while (and (not found) (< i n))
        (if (char-eq (string-ref root i) #/')
          (set! found true)
          (set! i (+ i 1))))
      found)))

;: Pick a path separator compatible with `root`.
(define (windows-sdk-root-separator [root : (& root str)]) : String
  (if (windows-sdk-root-contains-forward-slash? root)
    "/"
    "\\"))

;: Pick a path separator compatible with an owned root string.
(define (windows-sdk-root-separator-owned [root : String]) : String
  (windows-sdk-root-separator (& root)))

;: Join two owned path components without normalizing interior separators.
(define (windows-sdk-path-join2-owned [left : String] [right : String]) : String
  (let
    [clean-left : String (windows-sdk-trim-trailing-separators-owned left)]
    [clean-right : String (windows-sdk-trim-trailing-separators-owned right)]
    (if (string-eq clean-left "")
      clean-right
      (if (string-eq clean-right "")
        clean-left
        (string-append
          (string-append
            clean-left
            (windows-sdk-root-separator-owned clean-left))
          clean-right)))))

;: Join two path components without normalizing interior separators.
(define (windows-sdk-path-join2 [left : (& left str)] [right : (& right str)]) : String
  (let
    [empty : String ""]
    [left-text : String (string-append left (& empty))]
    [right-text : String (string-append right (& empty))]
    (windows-sdk-path-join2-owned left-text right-text)))

;: Join three owned path components.
(define (windows-sdk-path-join3-owned [a : String] [b : String] [c : String]) : String
  (windows-sdk-path-join2-owned (windows-sdk-path-join2-owned a b) c))

;: Join three path components.
(define (windows-sdk-path-join3 [a : (& a str)] [b : (& b str)] [c : (& c str)]) : String
  (let
    [empty : String ""]
    [a-text : String (string-append a (& empty))]
    [b-text : String (string-append b (& empty))]
    [c-text : String (string-append c (& empty))]
    (windows-sdk-path-join3-owned a-text b-text c-text)))

;: Join four owned path components.
(define (windows-sdk-path-join4-owned
  [a : String]
  [b : String]
  [c : String]
  [d : String]) : String
  (windows-sdk-path-join2-owned (windows-sdk-path-join3-owned a b c) d))

;: Join four path components.
(define (windows-sdk-path-join4
  [a : (& a str)]
  [b : (& b str)]
  [c : (& c str)]
  [d : (& d str)]) : String
  (let
    [empty : String ""]
    [a-text : String (string-append a (& empty))]
    [b-text : String (string-append b (& empty))]
    [c-text : String (string-append c (& empty))]
    [d-text : String (string-append d (& empty))]
    (windows-sdk-path-join4-owned a-text b-text c-text d-text)))

;: Join five owned path components.
(define (windows-sdk-path-join5-owned
  [a : String]
  [b : String]
  [c : String]
  [d : String]
  [e : String]) : String
  (windows-sdk-path-join2-owned (windows-sdk-path-join4-owned a b c d) e))

;: Join five path components.
(define (windows-sdk-path-join5
  [a : (& a str)]
  [b : (& b str)]
  [c : (& c str)]
  [d : (& d str)]
  [e : (& e str)]) : String
  (let
    [empty : String ""]
    [a-text : String (string-append a (& empty))]
    [b-text : String (string-append b (& empty))]
    [c-text : String (string-append c (& empty))]
    [d-text : String (string-append d (& empty))]
    [e-text : String (string-append e (& empty))]
    (windows-sdk-path-join5-owned a-text b-text c-text d-text e-text)))

;: Build a layout from an SDK root and version string without probing it.
(define (windows-sdk-layout-from-root-version
  [root : (& root str)]
  [version : (& version str)]) : WindowsSdkLayout
  (let
    [empty : String ""]
    [root-text : String (string-append root (& empty))]
    [version-text : String (string-append version (& empty))]
    [clean-root : String (windows-sdk-trim-trailing-separators-owned root-text)]
    [clean-version : String
      (windows-sdk-trim-trailing-separators-owned version-text)]
    (WindowsSdkLayout
      clean-root
      clean-version
      (windows-sdk-path-join4-owned clean-root "Include" clean-version "ucrt")
      (windows-sdk-path-join4-owned clean-root "Include" clean-version "um")
      (windows-sdk-path-join4-owned clean-root "Include" clean-version "shared")
      (windows-sdk-path-join5-owned clean-root "Lib" clean-version "ucrt" "x64")
      (windows-sdk-path-join5-owned clean-root "Lib" clean-version "um" "x64")
      (windows-sdk-path-join4-owned clean-root "bin" clean-version "x64"))))

;: Return true when a path exists, mapping probe errors to false.
(define (windows-sdk-path-exists? [path : (& path str)]) : bool
  (match (try-file-exists? path)
    [(OkIoBool exists) exists]
    [(ErrIoBool _) false]))

;: Return true when an owned path exists through the borrowed public helper.
(define (windows-sdk-path-exists-owned? [path : String]) : bool
  (windows-sdk-path-exists? (& path)))

;: Return the first missing required directory in `layout`.
(define (windows-sdk-first-missing-path [layout : WindowsSdkLayout]) : WindowsSdkMaybeString
  (cond
    [(not (windows-sdk-path-exists-owned? (windows-sdk-root layout)))
      (WindowsSdkSomeString (windows-sdk-root layout))]
    [(not (windows-sdk-path-exists-owned? (windows-sdk-include-ucrt layout)))
      (WindowsSdkSomeString (windows-sdk-include-ucrt layout))]
    [(not (windows-sdk-path-exists-owned? (windows-sdk-include-um layout)))
      (WindowsSdkSomeString (windows-sdk-include-um layout))]
    [(not (windows-sdk-path-exists-owned? (windows-sdk-include-shared layout)))
      (WindowsSdkSomeString (windows-sdk-include-shared layout))]
    [(not (windows-sdk-path-exists-owned? (windows-sdk-lib-ucrt-x64 layout)))
      (WindowsSdkSomeString (windows-sdk-lib-ucrt-x64 layout))]
    [(not (windows-sdk-path-exists-owned? (windows-sdk-lib-um-x64 layout)))
      (WindowsSdkSomeString (windows-sdk-lib-um-x64 layout))]
    [(not (windows-sdk-path-exists-owned? (windows-sdk-bin-x64 layout)))
      (WindowsSdkSomeString (windows-sdk-bin-x64 layout))]
    [else (WindowsSdkNoString)]))

;: Validate a root/version pair and return a complete SDK layout.
(define (windows-sdk-layout-from-root-version-checked
  [root : (& root str)]
  [version : (& version str)]) : ResultWindowsSdkLayout
  (if (string-eq root "")
    (ErrWindowsSdkLayout
      (WindowsSdkMissingEnvironment "windows-sdk: WindowsSdkDir is empty"))
    (if (string-eq version "")
      (ErrWindowsSdkLayout
        (WindowsSdkMissingEnvironment "windows-sdk: WindowsSDKVersion is empty"))
      (let
        [layout : WindowsSdkLayout
          (windows-sdk-layout-from-root-version root version)]
        (match (windows-sdk-first-missing-path layout)
          [(WindowsSdkNoString) (OkWindowsSdkLayout layout)]
          [(WindowsSdkSomeString path)
            (ErrWindowsSdkLayout
              (WindowsSdkInvalidLayout
                (string-append "windows-sdk: missing SDK path: " path)))])))))

;: Return true when at least one SDK override environment variable is present.
(define (windows-sdk-env-present?) : bool
  (let
    [name : String "WindowsSdkDir"]
    (match (env-get (& name))
      [(EnvSomeString _) true]
      [(EnvNoString)
        (let
          [name : String "WindowsSDKVersion"]
          (match (env-get (& name))
            [(EnvSomeString _) true]
            [(EnvNoString) false]))])))

;: Discover and validate an SDK layout from environment overrides.
(define (windows-sdk-discover-from-env) : ResultWindowsSdkLayout
  (let
    [name : String "WindowsSdkDir"]
    (match (env-get (& name))
      [(EnvNoString)
        (ErrWindowsSdkLayout
          (WindowsSdkMissingEnvironment "windows-sdk: WindowsSdkDir is not set"))]
      [(EnvSomeString root)
        (let
          [name : String "WindowsSDKVersion"]
          (match (env-get (& name))
            [(EnvNoString)
              (ErrWindowsSdkLayout
                (WindowsSdkMissingEnvironment
                  "windows-sdk: WindowsSDKVersion is not set"))]
            [(EnvSomeString version)
              (windows-sdk-layout-from-root-version-checked
                (& root)
                (& version))]))])))

;: Validate a root/version pair found in the registry.
(define (windows-sdk-layout-from-registry-root-version-checked
  [root : (& root str)]
  [version : (& version str)]) : ResultWindowsSdkLayout
  (if (string-eq root "")
    (ErrWindowsSdkLayout
      (WindowsSdkRegistryUnavailable
        "windows-sdk: registry KitsRoot10 is empty"))
    (if (string-eq version "")
      (ErrWindowsSdkLayout
        (WindowsSdkRegistryUnavailable
          "windows-sdk: registry SDK version is empty"))
      (windows-sdk-layout-from-root-version-checked root version))))

;: Discover and validate an SDK layout from the Windows registry.
(define (windows-sdk-discover-from-registry) : ResultWindowsSdkLayout
  (match (windows-registry-sdk-install)
    [(OkWindowsRegistrySdkInstall install)
      (let
        [root : String (windows-registry-sdk-root install)]
        [version : String (windows-registry-sdk-version install)]
        (windows-sdk-layout-from-registry-root-version-checked
          (& root)
          (& version)))]
    [(ErrWindowsRegistrySdkInstall error)
      (ErrWindowsSdkLayout
        (WindowsSdkRegistryUnavailable (windows-registry-error-message error)))]))

;: Discover the Windows SDK using environment overrides before registry probing.
(define (windows-sdk-discover) : ResultWindowsSdkLayout
  (if (not (windows-sdk-host-windows?))
    (ErrWindowsSdkLayout
      (WindowsSdkUnsupported "windows-sdk: unsupported on non-Windows hosts"))
    (if (windows-sdk-env-present?)
      (windows-sdk-discover-from-env)
      (windows-sdk-discover-from-registry))))