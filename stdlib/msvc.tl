;;;; MSVC tool discovery (#855): find link.exe and its command environment.
;;;;
;;;; v1 slice: detect an already-configured MSVC command environment (a
;;;; Developer Command Prompt or equivalent) by locating the requested tool on
;;;; `PATH` and reading the `PATH`, `LIB`, and `INCLUDE` overrides needed to
;;;; invoke it. Locating the newest Visual Studio toolset through the
;;;; SetupConfiguration enumerator is reported as a structured unavailable
;;;; diagnostic until MSVC tool selection consumes that runtime surface (#855).
;;;;
;;;; Usage: `(import "stdlib/msvc.tl")`
;;;;
;;;; ```typelisp
;;;; (import "stdlib/msvc.tl")
;;;; (define tool : ResultMsvcTool
;;;;   (msvc-find-tool "x86_64-pc-windows-msvc" "link.exe"))
;;;; ```
(import "stdlib/env.tl")

(import "stdlib/io.tl")

(import "stdlib/fs.tl")

(import "stdlib/string.tl")

;;; Resolved MSVC tool: executable path plus the command-environment overrides.
(defstruct MsvcTool
  (executable String)
  (path String)
  (lib String)
  (include String))

;;; Structured MSVC discovery failures.
(defenum MsvcError
  (MsvcUnsupported String)
  (MsvcMissingEnvironment String)
  (MsvcToolNotFound String)
  (MsvcSetupUnavailable String))

;;; Result type for MSVC tool discovery.
(defenum ResultMsvcTool
  (OkMsvcTool MsvcTool)
  (ErrMsvcTool MsvcError))

;;; Optional resolved-path result for the PATH search.
(defenum MsvcMaybeString
  (MsvcNoString)
  (MsvcSomeString String))

;;; Return the resolved tool executable path.
(define (msvc-tool-executable [tool : MsvcTool]) : String
  (struct-get tool executable))

;;; Return the PATH override for invoking the tool.
(define (msvc-tool-path [tool : MsvcTool]) : String
  (struct-get tool path))

;;; Return the LIB override for invoking the tool.
(define (msvc-tool-lib [tool : MsvcTool]) : String
  (struct-get tool lib))

;;; Return the INCLUDE override for invoking the tool.
(define (msvc-tool-include [tool : MsvcTool]) : String
  (struct-get tool include))

;;; Render a discovery error as a diagnostic message.
(define (msvc-error-message [error : MsvcError]) : String
  (match error
    [(MsvcUnsupported message) message]
    [(MsvcMissingEnvironment message) message]
    [(MsvcToolNotFound message) message]
    [(MsvcSetupUnavailable message) message]))

;;; Return true when the host path-list separator identifies Windows.
(define (msvc-host-windows?) : bool
  (string-eq (env-path-list-separator) ";"))

;;; Return true when `target` is a v1-supported MSVC target triple.
(define (msvc-supported-target? [target : String]) : bool
  (string-eq target "x86_64-pc-windows-msvc"))

;;; Return true when `path` exists, mapping probe errors to false.
(define (msvc-path-exists? [path : String]) : bool
  (match (try-file-exists? path)
    [(OkIoBool exists) exists]
    [(ErrIoBool _) false]))

;;; Search PATH directories for `tool`, returning the first existing candidate.
(define (msvc-search-dirs [dirs : EnvStringList] [tool : String]) : MsvcMaybeString
  (match dirs
    [(EnvStringNil) (MsvcNoString)]
    [(EnvStringCons dir rest)
      (let
        [candidate : String (fs-path-join dir tool)]
        (if (msvc-path-exists? candidate)
          (MsvcSomeString candidate)
          (msvc-search-dirs rest tool)))]))

;;; Locate `tool` on the PATH environment variable.
(define (msvc-find-on-path [tool : String]) : MsvcMaybeString
  (match (env-path-list "PATH")
    [(EnvNoStringList) (MsvcNoString)]
    [(EnvSomeStringList dirs) (msvc-search-dirs dirs tool)]))

;;; Read an environment variable or the empty string when it is unset.
(define (msvc-env-or-empty [name : String]) : String
  (match (env-get name)
    [(EnvSomeString value) value]
    [(EnvNoString) ""]))

;;; Build a configured tool result once the executable path is known.
(define (msvc-configured-result [executable : String]) : ResultMsvcTool
  (match (env-get "LIB")
    [(EnvNoString)
      (ErrMsvcTool
        (MsvcMissingEnvironment
          "msvc: LIB is not set; run from a Developer Command Prompt (toolset selection is tracked by #855)"))]
    [(EnvSomeString lib)
      (match (env-get "INCLUDE")
        [(EnvNoString)
          (ErrMsvcTool
            (MsvcMissingEnvironment
              "msvc: INCLUDE is not set; run from a Developer Command Prompt (toolset selection is tracked by #855)"))]
        [(EnvSomeString include)
          (OkMsvcTool
            (MsvcTool executable (msvc-env-or-empty "PATH") lib include))])]))

;;; Detect a configured MSVC command environment and resolve `tool`.
(define (msvc-find-tool-configured [tool : String]) : ResultMsvcTool
  (match (msvc-find-on-path tool)
    [(MsvcSomeString executable) (msvc-configured-result executable)]
    [(MsvcNoString)
      (ErrMsvcTool
        (MsvcToolNotFound
          (string-append
            (string-append "msvc: could not find " tool)
            " on PATH; run from a Developer Command Prompt or install Visual Studio Build Tools (newest-toolset selection is tracked by #855)")))]))

;;; Report that SetupConfiguration-based toolset selection is not yet wired.
(define (msvc-find-tool-from-setup [target : String] [tool : String]) : ResultMsvcTool
  (ErrMsvcTool
    (MsvcSetupUnavailable
      "msvc: Visual Studio SetupConfiguration tool selection is not implemented yet (#855)")))

;;; Find an MSVC tool such as `link.exe` and its command environment.
;;;
;;; The v1 slice resolves the tool from an already-configured Developer Command
;;; Prompt environment. When no such environment is present the caller should
;;; fall back to `msvc-find-tool-from-setup`, which is tracked by #855.
(define (msvc-find-tool [target : String] [tool : String]) : ResultMsvcTool
  (if (not (msvc-host-windows?))
    (ErrMsvcTool
      (MsvcUnsupported
        "msvc: tool discovery is unsupported on non-Windows hosts"))
    (if (not (msvc-supported-target? target))
      (ErrMsvcTool
        (MsvcUnsupported (string-append "msvc: unsupported target " target)))
      (msvc-find-tool-configured tool))))