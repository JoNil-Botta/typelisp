;;;; Windows SDK discovery helpers (#1016).
;;;;
;;;; This module models the Windows SDK include/lib/bin layout needed by the
;;;; future MSVC linker environment. The first slice honors `WindowsSdkDir` and
;;;; `WindowsSDKVersion` environment overrides and validates the resulting
;;;; filesystem layout before any registry probing. Registry-backed discovery is
;;;; reported as a structured unavailable diagnostic until the narrow registry
;;;; runtime primitive lands.
;;;;
;;;; Usage: `(import "stdlib/windows_sdk.tl")`
;;;;
;;;; ```typelisp
;;;; (import "stdlib/windows_sdk.tl")
;;;; (define sdk : ResultWindowsSdkLayout (windows-sdk-discover))
;;;; ```
(import "stdlib/env.tl")

(import "stdlib/io.tl")

(import "stdlib/string.tl")

;;; Concrete Windows SDK paths needed by an x64 MSVC link environment.
(defstruct WindowsSdkLayout
  (root String)
  (version String)
  (include-ucrt String)
  (include-um String)
  (include-shared String)
  (lib-ucrt-x64 String)
  (lib-um-x64 String)
  (bin-x64 String))

;;; Structured SDK discovery failures.
(defenum WindowsSdkError
  (WindowsSdkUnsupported String)
  (WindowsSdkMissingEnvironment String)
  (WindowsSdkInvalidLayout String)
  (WindowsSdkRegistryUnavailable String))

;;; Result type for SDK discovery.
(defenum ResultWindowsSdkLayout
  (OkWindowsSdkLayout WindowsSdkLayout)
  (ErrWindowsSdkLayout WindowsSdkError))

;;; Optional string used by layout validation.
(defenum WindowsSdkMaybeString
  (WindowsSdkNoString)
  (WindowsSdkSomeString String))

;;; Return the SDK root directory.
(define (windows-sdk-root [layout : WindowsSdkLayout]) : String
  (struct-get layout root))

;;; Return the SDK version directory name.
(define (windows-sdk-version [layout : WindowsSdkLayout]) : String
  (struct-get layout version))

;;; Return the UCRT include directory.
(define (windows-sdk-include-ucrt [layout : WindowsSdkLayout]) : String
  (struct-get layout include-ucrt))

;;; Return the UM include directory.
(define (windows-sdk-include-um [layout : WindowsSdkLayout]) : String
  (struct-get layout include-um))

;;; Return the shared include directory.
(define (windows-sdk-include-shared [layout : WindowsSdkLayout]) : String
  (struct-get layout include-shared))

;;; Return the x64 UCRT library directory.
(define (windows-sdk-lib-ucrt-x64 [layout : WindowsSdkLayout]) : String
  (struct-get layout lib-ucrt-x64))

;;; Return the x64 UM library directory.
(define (windows-sdk-lib-um-x64 [layout : WindowsSdkLayout]) : String
  (struct-get layout lib-um-x64))

;;; Return the x64 SDK tool directory.
(define (windows-sdk-bin-x64 [layout : WindowsSdkLayout]) : String
  (struct-get layout bin-x64))

;;; Render a discovery error as a diagnostic message.
(define (windows-sdk-error-message [error : WindowsSdkError]) : String
  (match error
    [(WindowsSdkUnsupported message) message]
    [(WindowsSdkMissingEnvironment message) message]
    [(WindowsSdkInvalidLayout message) message]
    [(WindowsSdkRegistryUnavailable message) message]))

;;; Return true when the host path-list separator identifies Windows.
(define (windows-sdk-host-windows?) : bool
  (string-eq (env-path-list-separator) ";"))

;;; Return true when `c` is a path separator accepted by Windows.
(define (windows-sdk-separator-char? [c : char]) : bool
  (if (char-eq c #/')
    true
    (char-eq c #\\')))

;;; Return true when `text` ends with a path separator.
(define (windows-sdk-ends-with-separator? [text : String]) : bool
  (let
    [n : i64 (string-length text)]
    (if (= n 0)
      false
      (windows-sdk-separator-char? (string-ref text (- n 1))))))

;;; Trim trailing path separators from `text`.
(define (windows-sdk-trim-trailing-separators-from [text : String] [n : i64]) : String
  (if (= n 0)
    ""
    (if (windows-sdk-separator-char? (string-ref text (- n 1)))
      (windows-sdk-trim-trailing-separators-from text (- n 1))
      (substring text 0 n))))

;;; Trim trailing path separators from `text`.
(define (windows-sdk-trim-trailing-separators [text : String]) : String
  (windows-sdk-trim-trailing-separators-from text (string-length text)))

;;; Pick a path separator compatible with `root`.
(define (windows-sdk-root-separator [root : String]) : String
  (if (string-contains root "/")
    "/"
    "\\"))

;;; Join two path components without normalizing interior separators.
(define (windows-sdk-path-join2 [left : String] [right : String]) : String
  (let
    [clean-left : String (windows-sdk-trim-trailing-separators left)]
    [clean-right : String (windows-sdk-trim-trailing-separators right)]
    (if (string-eq clean-left "")
      clean-right
      (if (string-eq clean-right "")
        clean-left
        (string-append
          (string-append clean-left (windows-sdk-root-separator clean-left))
          clean-right)))))

;;; Join three path components.
(define (windows-sdk-path-join3 [a : String] [b : String] [c : String]) : String
  (windows-sdk-path-join2 (windows-sdk-path-join2 a b) c))

;;; Join four path components.
(define (windows-sdk-path-join4
  [a : String]
  [b : String]
  [c : String]
  [d : String]) : String
  (windows-sdk-path-join2 (windows-sdk-path-join3 a b c) d))

;;; Join five path components.
(define (windows-sdk-path-join5
  [a : String]
  [b : String]
  [c : String]
  [d : String]
  [e : String]) : String
  (windows-sdk-path-join2 (windows-sdk-path-join4 a b c d) e))

;;; Build a layout from an SDK root and version string without probing it.
(define (windows-sdk-layout-from-root-version
  [root : String]
  [version : String]) : WindowsSdkLayout
  (let
    [clean-root : String (windows-sdk-trim-trailing-separators root)]
    [clean-version : String (windows-sdk-trim-trailing-separators version)]
    (WindowsSdkLayout
      clean-root
      clean-version
      (windows-sdk-path-join4 clean-root "Include" clean-version "ucrt")
      (windows-sdk-path-join4 clean-root "Include" clean-version "um")
      (windows-sdk-path-join4 clean-root "Include" clean-version "shared")
      (windows-sdk-path-join5 clean-root "Lib" clean-version "ucrt" "x64")
      (windows-sdk-path-join5 clean-root "Lib" clean-version "um" "x64")
      (windows-sdk-path-join4 clean-root "bin" clean-version "x64"))))

;;; Return true when a path exists, mapping probe errors to false.
(define (windows-sdk-path-exists? [path : String]) : bool
  (match (try-file-exists? path)
    [(OkIoBool exists) exists]
    [(ErrIoBool _) false]))

;;; Return the first missing required directory in `layout`.
(define (windows-sdk-first-missing-path [layout : WindowsSdkLayout]) : WindowsSdkMaybeString
  (if (not (windows-sdk-path-exists? (windows-sdk-root layout)))
    (WindowsSdkSomeString (windows-sdk-root layout))
    (if (not (windows-sdk-path-exists? (windows-sdk-include-ucrt layout)))
      (WindowsSdkSomeString (windows-sdk-include-ucrt layout))
      (if (not (windows-sdk-path-exists? (windows-sdk-include-um layout)))
        (WindowsSdkSomeString (windows-sdk-include-um layout))
        (if (not (windows-sdk-path-exists? (windows-sdk-include-shared layout)))
          (WindowsSdkSomeString (windows-sdk-include-shared layout))
          (if (not (windows-sdk-path-exists? (windows-sdk-lib-ucrt-x64 layout)))
            (WindowsSdkSomeString (windows-sdk-lib-ucrt-x64 layout))
            (if (not (windows-sdk-path-exists? (windows-sdk-lib-um-x64 layout)))
              (WindowsSdkSomeString (windows-sdk-lib-um-x64 layout))
              (if (not (windows-sdk-path-exists? (windows-sdk-bin-x64 layout)))
                (WindowsSdkSomeString (windows-sdk-bin-x64 layout))
                (WindowsSdkNoString)))))))))

;;; Validate a root/version pair and return a complete SDK layout.
(define (windows-sdk-layout-from-root-version-checked
  [root : String]
  [version : String]) : ResultWindowsSdkLayout
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

;;; Return true when at least one SDK override environment variable is present.
(define (windows-sdk-env-present?) : bool
  (match (env-get "WindowsSdkDir")
    [(EnvSomeString _) true]
    [(EnvNoString)
      (match (env-get "WindowsSDKVersion")
        [(EnvSomeString _) true]
        [(EnvNoString) false])]))

;;; Discover and validate an SDK layout from environment overrides.
(define (windows-sdk-discover-from-env) : ResultWindowsSdkLayout
  (match (env-get "WindowsSdkDir")
    [(EnvNoString)
      (ErrWindowsSdkLayout
        (WindowsSdkMissingEnvironment "windows-sdk: WindowsSdkDir is not set"))]
    [(EnvSomeString root)
      (match (env-get "WindowsSDKVersion")
        [(EnvNoString)
          (ErrWindowsSdkLayout
            (WindowsSdkMissingEnvironment
              "windows-sdk: WindowsSDKVersion is not set"))]
        [(EnvSomeString version)
          (windows-sdk-layout-from-root-version-checked root version)])]))

;;; Report that registry-backed SDK discovery is not implemented in this slice.
(define (windows-sdk-discover-from-registry) : ResultWindowsSdkLayout
  (ErrWindowsSdkLayout
    (WindowsSdkRegistryUnavailable
      "windows-sdk: registry-backed SDK discovery is not implemented yet")))

;;; Discover the Windows SDK using environment overrides before registry probing.
(define (windows-sdk-discover) : ResultWindowsSdkLayout
  (if (not (windows-sdk-host-windows?))
    (ErrWindowsSdkLayout
      (WindowsSdkUnsupported "windows-sdk: unsupported on non-Windows hosts"))
    (if (windows-sdk-env-present?)
      (windows-sdk-discover-from-env)
      (windows-sdk-discover-from-registry))))