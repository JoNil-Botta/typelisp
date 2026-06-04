;# MSVC tool discovery (#855): find link.exe and its command environment.
;#
;# Detect an already-configured MSVC command environment (a Developer Command
;# Prompt or equivalent) first. If that is absent, enumerate Visual Studio /
;# Build Tools instances through SetupConfiguration, combine the selected VC
;# toolset with Windows SDK discovery, and return the `PATH`, `LIB`, and
;# `INCLUDE` overrides needed to invoke the requested MSVC tool from a normal
;# shell.
;#
;# Usage: `(import "stdlib/msvc.tl")`
;#
;; requires-stage0-symbol: fs-mkdir-status,fs-remove-file-status,fs-remove-dir-status,fs-rename-status,fs-read-dir-status,fs-read-dir,fs-file-kind-status,fs-file-size-status,fs-file-size
;# ```typelisp
;# (import "stdlib/msvc.tl")
;# (define target : String "x86_64-pc-windows-msvc")
;# (define tool : String "link.exe")
;# (define resolved : ResultMsvcTool
;#   (msvc-find-tool (& target) (& tool)))
;# ```
(import "env.tl")

(import "io.tl")

(import "fs.tl")

(import "process.tl")

(import "string.tl")

(import "windows_sdk.tl")

(import "windows_setup.tl")

;: Resolved MSVC tool: executable path plus the command-environment overrides.
(defstruct MsvcTool
  (executable String)
  (path String)
  (lib String)
  (include String))

;: Structured MSVC discovery failures.
(defenum MsvcError
  (MsvcUnsupported String)
  (MsvcMissingEnvironment String)
  (MsvcToolNotFound String)
  (MsvcSetupUnavailable String))

;: Result type for MSVC tool discovery.
(defenum ResultMsvcTool
  (OkMsvcTool MsvcTool)
  (ErrMsvcTool MsvcError))

;: Optional resolved-path result for the PATH search.
(defenum MsvcMaybeString
  (MsvcNoString)
  (MsvcSomeString String))

;: Parsed version segment plus the index where parsing stopped.
(defstruct MsvcVersionCursor
  (value i64)
  (next i64))

;: Optional usable tool candidate while scanning setup instances.
(defenum MsvcMaybeToolCandidate
  (MsvcNoToolCandidate)
  (MsvcSomeToolCandidate MsvcTool String))

;: Return the resolved tool executable path.
(define (msvc-tool-executable [tool : MsvcTool]) : String
  (struct-get tool executable))

;: Return the PATH override for invoking the tool.
(define (msvc-tool-path [tool : MsvcTool]) : String
  (struct-get tool path))

;: Return the LIB override for invoking the tool.
(define (msvc-tool-lib [tool : MsvcTool]) : String
  (struct-get tool lib))

;: Return the INCLUDE override for invoking the tool.
(define (msvc-tool-include [tool : MsvcTool]) : String
  (struct-get tool include))

;: Return process environment overrides for invoking the tool.
(define (msvc-tool-process-env [tool : MsvcTool]) : ProcessEnvList
  (process-env-cons
    "PATH"
    (msvc-tool-path tool)
    (process-env-cons
      "LIB"
      (msvc-tool-lib tool)
      (process-env-cons "INCLUDE" (msvc-tool-include tool) (process-env-empty)))))

;: Render a discovery error as a diagnostic message.
(define (msvc-error-message [error : MsvcError]) : String
  (match error
    [(MsvcUnsupported message) message]
    [(MsvcMissingEnvironment message) message]
    [(MsvcToolNotFound message) message]
    [(MsvcSetupUnavailable message) message]))

;: Return true when the host path-list separator identifies Windows.
(define (msvc-host-windows?) : bool
  (string-eq (env-path-list-separator) ";"))

;: Return true when `target` is a v1-supported MSVC target triple.
(define (msvc-supported-target? [target : (& target str)]) : bool
  (string-eq target "x86_64-pc-windows-msvc"))

;: Return true when `c` is an ASCII decimal digit.
(define (msvc-digit? [c : char]) : bool
  (let
    [code : i64 (cast c : i64)]
    (and (>= code (cast #0' : i64)) (<= code (cast #9' : i64)))))

;: Return the numeric value of an ASCII decimal digit, or zero otherwise.
(define (msvc-digit-value [c : char]) : i64
  (if (msvc-digit? c)
    (- (cast c : i64) (cast #0' : i64))
    0))

;: Read one dotted numeric version segment starting at `index`.
(define (msvc-version-read-segment [version : String] [index : i64]) : MsvcVersionCursor
  (let
    [n : i64 (string-length version)]
    [i : i64 index]
    [value : i64 0]
    [done : bool false]
    (begin
      (while (and (< i n) (not done))
        (let
          [c : char (string-ref version i)]
          (if (char-eq c #.')
            (set! done true)
            (begin
              (if (msvc-digit? c)
                (set! value (+ (* value 10) (msvc-digit-value c)))
                unit)
              (set! i (+ i 1))))))
      (MsvcVersionCursor value i))))

;: Advance past a dotted version separator if one is present.
(define (msvc-version-next-index [version : String] [index : i64]) : i64
  (let
    [n : i64 (string-length version)]
    (if (and (< index n) (char-eq (string-ref version index) #.'))
      (+ index 1)
      index)))

;: Return true when owned `left` is a newer dotted numeric version than `right`.
(define (msvc-version-greater-owned? [left : String] [right : String]) : bool
  (let
    [left-len : i64 (string-length left)]
    [right-len : i64 (string-length right)]
    [left-index : i64 0]
    [right-index : i64 0]
    [greater : bool false]
    [done : bool false]
    (begin
      (while (and
        (not done)
        (or (< left-index left-len) (< right-index right-len)))
        (let
          [left-segment : MsvcVersionCursor
            (msvc-version-read-segment left left-index)]
          [right-segment : MsvcVersionCursor
            (msvc-version-read-segment right right-index)]
          [left-value : i64 (struct-get left-segment value)]
          [right-value : i64 (struct-get right-segment value)]
          (if (> left-value right-value)
            (begin
              (set! greater true)
              (set! done true))
            (if (< left-value right-value)
              (set! done true)
              (begin
                (set!
                  left-index
                  (msvc-version-next-index left (struct-get left-segment next)))
                (set!
                  right-index
                  (msvc-version-next-index
                    right
                    (struct-get right-segment next))))))))
      greater)))

;: Return true when `left` is a newer dotted numeric version than `right`.
(define (msvc-version-greater? [left : (& left str)] [right : (& right str)]) : bool
  (let
    [empty : String ""]
    [left-text : String (string-append left (& empty))]
    [right-text : String (string-append right (& empty))]
    (msvc-version-greater-owned? left-text right-text)))

;: Return true when `path` exists, mapping probe errors to false.
(define (msvc-path-exists? [path : (& path str)]) : bool
  (match (try-file-exists? path)
    [(OkIoBool exists) exists]
    [(ErrIoBool _) false]))

;: Return true when an owned path exists through the borrowed public helper.
(define (msvc-path-exists-owned? [path : String]) : bool
  (msvc-path-exists? (& path)))

;: Join two filesystem path segments using the platform separator.
(define (msvc-path-join [left : String] [right : String]) : String
  (fs-path-join (& left) (& right)))

;: Search PATH directories for `tool`, returning the first existing candidate.
(define (msvc-search-dirs-owned [dirs : EnvStringList] [tool : String]) : MsvcMaybeString
  (match dirs
    [(EnvStringNil) (MsvcNoString)]
    [(EnvStringCons dir rest)
      (let
        [candidate : String (msvc-path-join dir tool)]
        (if (msvc-path-exists-owned? candidate)
          (MsvcSomeString candidate)
          (msvc-search-dirs-owned rest tool)))]))

;: Search PATH directories for `tool`, returning the first existing candidate.
(define (msvc-search-dirs [dirs : EnvStringList] [tool : (& tool str)]) : MsvcMaybeString
  (let
    [empty : String ""]
    [tool-text : String (string-append tool (& empty))]
    (msvc-search-dirs-owned dirs tool-text)))

;: Locate `tool` on the PATH environment variable.
(define (msvc-find-on-path [tool : (& tool str)]) : MsvcMaybeString
  (let
    [name : String "PATH"]
    (match (env-path-list (& name))
      [(EnvNoStringList) (MsvcNoString)]
      [(EnvSomeStringList dirs) (msvc-search-dirs dirs tool)])))

;: Read an environment variable or the empty string when it is unset.
(define (msvc-env-or-empty [name : (& name str)]) : String
  (match (env-get name)
    [(EnvSomeString value) value]
    [(EnvNoString) ""]))

;: Read an owned environment variable name or the empty string when it is unset.
(define (msvc-env-or-empty-owned [name : String]) : String
  (msvc-env-or-empty (& name)))

;: Join owned `head` before an optional PATH-style suffix.
(define (msvc-path-list-prepend-owned [head : String] [tail : String]) : String
  (if (string-eq tail "")
    head
    (string-append (string-append head (env-path-list-separator)) tail)))

;: Join `head` before an optional PATH-style suffix.
(define (msvc-path-list-prepend [head : (& head str)] [tail : (& tail str)]) : String
  (let
    [empty : String ""]
    [head-text : String (string-append head (& empty))]
    [tail-text : String (string-append tail (& empty))]
    (msvc-path-list-prepend-owned head-text tail-text)))

;: Join two owned required PATH-style entries.
(define (msvc-path-list-join2-owned [a : String] [b : String]) : String
  (string-append (string-append a (env-path-list-separator)) b))

;: Join two required PATH-style entries.
(define (msvc-path-list-join2 [a : (& a str)] [b : (& b str)]) : String
  (let
    [empty : String ""]
    [a-text : String (string-append a (& empty))]
    [b-text : String (string-append b (& empty))]
    (msvc-path-list-join2-owned a-text b-text)))

;: Join three owned required PATH-style entries.
(define (msvc-path-list-join3-owned [a : String] [b : String] [c : String]) : String
  (msvc-path-list-join2-owned (msvc-path-list-join2-owned a b) c))

;: Join three required PATH-style entries.
(define (msvc-path-list-join3 [a : (& a str)] [b : (& b str)] [c : (& c str)]) : String
  (let
    [empty : String ""]
    [a-text : String (string-append a (& empty))]
    [b-text : String (string-append b (& empty))]
    [c-text : String (string-append c (& empty))]
    (msvc-path-list-join3-owned a-text b-text c-text)))

;: Join four owned required PATH-style entries.
(define (msvc-path-list-join4-owned
  [a : String]
  [b : String]
  [c : String]
  [d : String]) : String
  (msvc-path-list-join2-owned (msvc-path-list-join3-owned a b c) d))

;: Join four required PATH-style entries.
(define (msvc-path-list-join4
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
    (msvc-path-list-join4-owned a-text b-text c-text d-text)))

;: Join an optional inherited path list after required entries.
(define (msvc-path-list-join3-with-tail-owned
  [a : String]
  [b : String]
  [c : String]
  [tail : String]) : String
  (msvc-path-list-prepend-owned (msvc-path-list-join3-owned a b c) tail))

;: Join an optional inherited path list after required entries.
(define (msvc-path-list-join3-with-tail
  [a : (& a str)]
  [b : (& b str)]
  [c : (& c str)]
  [tail : (& tail str)]) : String
  (let
    [empty : String ""]
    [a-text : String (string-append a (& empty))]
    [b-text : String (string-append b (& empty))]
    [c-text : String (string-append c (& empty))]
    [tail-text : String (string-append tail (& empty))]
    (msvc-path-list-join3-with-tail-owned a-text b-text c-text tail-text)))

;: Join an optional inherited path list after two required entries.
(define (msvc-path-list-join2-with-tail-owned
  [a : String]
  [b : String]
  [tail : String]) : String
  (msvc-path-list-prepend-owned (msvc-path-list-join2-owned a b) tail))

;: Join an optional inherited path list after two required entries.
(define (msvc-path-list-join2-with-tail
  [a : (& a str)]
  [b : (& b str)]
  [tail : (& tail str)]) : String
  (let
    [empty : String ""]
    [a-text : String (string-append a (& empty))]
    [b-text : String (string-append b (& empty))]
    [tail-text : String (string-append tail (& empty))]
    (msvc-path-list-join2-with-tail-owned a-text b-text tail-text)))

;: Join an optional inherited path list after four required entries.
(define (msvc-path-list-join4-with-tail-owned
  [a : String]
  [b : String]
  [c : String]
  [d : String]
  [tail : String]) : String
  (msvc-path-list-prepend-owned (msvc-path-list-join4-owned a b c d) tail))

;: Join an optional inherited path list after four required entries.
(define (msvc-path-list-join4-with-tail
  [a : (& a str)]
  [b : (& b str)]
  [c : (& c str)]
  [d : (& d str)]
  [tail : (& tail str)]) : String
  (let
    [empty : String ""]
    [a-text : String (string-append a (& empty))]
    [b-text : String (string-append b (& empty))]
    [c-text : String (string-append c (& empty))]
    [d-text : String (string-append d (& empty))]
    [tail-text : String (string-append tail (& empty))]
    (msvc-path-list-join4-with-tail-owned a-text b-text c-text d-text tail-text)))

;: Build a configured tool result once the executable path is known.
(define (msvc-configured-result [executable : String]) : ResultMsvcTool
  (let
    [name : String "LIB"]
    (match (env-get (& name))
      [(EnvNoString)
        (ErrMsvcTool
          (MsvcMissingEnvironment
            "msvc: LIB is not set; run from a Developer Command Prompt (toolset selection is tracked by #855)"))]
      [(EnvSomeString lib)
        (let
          [name : String "INCLUDE"]
          (match (env-get (& name))
            [(EnvNoString)
              (ErrMsvcTool
                (MsvcMissingEnvironment
                  "msvc: INCLUDE is not set; run from a Developer Command Prompt (toolset selection is tracked by #855)"))]
            [(EnvSomeString include)
              (OkMsvcTool
                (MsvcTool
                  executable
                  (msvc-env-or-empty-owned "PATH")
                  lib
                  include))]))])))

;: Detect a configured MSVC command environment and resolve `tool`.
(define (msvc-find-tool-configured [tool : (& tool str)]) : ResultMsvcTool
  (match (msvc-find-on-path tool)
    [(MsvcSomeString executable) (msvc-configured-result executable)]
    [(MsvcNoString)
      (ErrMsvcTool
        (MsvcToolNotFound
          (string-append
            (string-append "msvc: could not find " tool)
            " on PATH; run from a Developer Command Prompt or install Visual Studio Build Tools (newest-toolset selection is tracked by #855)")))]))

;: Return a user-provided `VCToolsVersion` if one is set.
(define (msvc-vc-tools-version-from-env) : MsvcMaybeString
  (let
    [name : String "VCToolsVersion"]
    (match (env-get (& name))
      [(EnvSomeString value)
        (let
          [trimmed : String (string-trim value)]
          (if (string-eq trimmed "")
            (MsvcNoString)
            (MsvcSomeString trimmed)))]
      [(EnvNoString) (MsvcNoString)])))

;: Path to an instance's default VC toolset version marker file.
(define (msvc-default-vc-tools-version-path [instance : WindowsSetupInstance]) : String
  (windows-sdk-path-join5-owned
    (windows-setup-instance-installation-path instance)
    "VC"
    "Auxiliary"
    "Build"
    "Microsoft.VCToolsVersion.default.txt"))

;: Read the default VC toolset version advertised by a Visual Studio instance.
(define (msvc-default-vc-tools-version [instance : WindowsSetupInstance]) : MsvcMaybeString
  (let
    [path : String (msvc-default-vc-tools-version-path instance)]
    (match (try-read-file (& path))
      [(OkIoString contents)
        (let
          [trimmed : String (string-trim contents)]
          (if (string-eq trimmed "")
            (MsvcNoString)
            (MsvcSomeString trimmed)))]
      [(ErrIoString _) (MsvcNoString)])))

;: Pick the VC toolset version, honoring `VCToolsVersion` when present.
(define (msvc-vc-tools-version [instance : WindowsSetupInstance]) : MsvcMaybeString
  (match (msvc-vc-tools-version-from-env)
    [(MsvcSomeString version) (MsvcSomeString version)]
    [(MsvcNoString) (msvc-default-vc-tools-version instance)]))

;: Path to the selected VC toolset root.
(define (msvc-toolset-root
  [instance : WindowsSetupInstance]
  [version : (& version str)]) : String
  (let
    [empty : String ""]
    [version-text : String (string-append version (& empty))]
    (windows-sdk-path-join5-owned
      (windows-setup-instance-installation-path instance)
      "VC"
      "Tools"
      "MSVC"
      version-text)))

;: Path to the selected host-x64/target-x64 MSVC binary directory.
(define (msvc-toolset-bin-x64 [toolset-root : (& toolset-root str)]) : String
  (let
    [empty : String ""]
    [toolset-root-text : String (string-append toolset-root (& empty))]
    (windows-sdk-path-join4-owned toolset-root-text "bin" "Hostx64" "x64")))

;: Path to the selected host-x64/target-x64 MSVC binary directory.
(define (msvc-toolset-bin-x64-owned [toolset-root : String]) : String
  (msvc-toolset-bin-x64 (& toolset-root)))

;: Path to the selected x64 MSVC library directory.
(define (msvc-toolset-lib-x64 [toolset-root : (& toolset-root str)]) : String
  (let
    [empty : String ""]
    [toolset-root-text : String (string-append toolset-root (& empty))]
    (windows-sdk-path-join3-owned toolset-root-text "lib" "x64")))

;: Path to the selected x64 MSVC library directory.
(define (msvc-toolset-lib-x64-owned [toolset-root : String]) : String
  (msvc-toolset-lib-x64 (& toolset-root)))

;: Path to the selected MSVC include directory.
(define (msvc-toolset-include [toolset-root : (& toolset-root str)]) : String
  (let
    [empty : String ""]
    [toolset-root-text : String (string-append toolset-root (& empty))]
    (windows-sdk-path-join2-owned toolset-root-text "include")))

;: Path to the selected MSVC include directory.
(define (msvc-toolset-include-owned [toolset-root : String]) : String
  (msvc-toolset-include (& toolset-root)))

;: Path to `tool` inside a selected MSVC toolset.
(define (msvc-toolset-executable
  [toolset-root : (& toolset-root str)]
  [tool : (& tool str)]) : String
  (let
    [empty : String ""]
    [toolset-root-text : String (string-append toolset-root (& empty))]
    [tool-text : String (string-append tool (& empty))]
    (windows-sdk-path-join2-owned
      (msvc-toolset-bin-x64-owned toolset-root-text)
      tool-text)))

;: Path to `tool` inside a selected MSVC toolset.
(define (msvc-toolset-executable-owned [toolset-root : String] [tool : String]) : String
  (msvc-toolset-executable (& toolset-root) (& tool)))

;: Build the PATH override for a discovered tool.
(define (msvc-setup-path
  [toolset-root : (& toolset-root str)]
  [sdk : WindowsSdkLayout]) : String
  (let
    [empty : String ""]
    [toolset-root-text : String (string-append toolset-root (& empty))]
    [tail : String (msvc-env-or-empty-owned "PATH")]
    (msvc-path-list-join2-with-tail-owned
      (msvc-toolset-bin-x64-owned toolset-root-text)
      (windows-sdk-bin-x64 sdk)
      tail)))

;: Build the PATH override for a discovered tool.
(define (msvc-setup-path-owned [toolset-root : String] [sdk : WindowsSdkLayout]) : String
  (msvc-setup-path (& toolset-root) sdk))

;: Build the LIB override for a discovered tool.
(define (msvc-setup-lib
  [toolset-root : (& toolset-root str)]
  [sdk : WindowsSdkLayout]) : String
  (let
    [empty : String ""]
    [toolset-root-text : String (string-append toolset-root (& empty))]
    [tail : String (msvc-env-or-empty-owned "LIB")]
    (msvc-path-list-join3-with-tail-owned
      (msvc-toolset-lib-x64-owned toolset-root-text)
      (windows-sdk-lib-ucrt-x64 sdk)
      (windows-sdk-lib-um-x64 sdk)
      tail)))

;: Build the LIB override for a discovered tool.
(define (msvc-setup-lib-owned [toolset-root : String] [sdk : WindowsSdkLayout]) : String
  (msvc-setup-lib (& toolset-root) sdk))

;: Build the INCLUDE override for a discovered tool.
(define (msvc-setup-include
  [toolset-root : (& toolset-root str)]
  [sdk : WindowsSdkLayout]) : String
  (let
    [empty : String ""]
    [toolset-root-text : String (string-append toolset-root (& empty))]
    [tail : String (msvc-env-or-empty-owned "INCLUDE")]
    (msvc-path-list-join4-with-tail-owned
      (msvc-toolset-include-owned toolset-root-text)
      (windows-sdk-include-ucrt sdk)
      (windows-sdk-include-um sdk)
      (windows-sdk-include-shared sdk)
      tail)))

;: Build the INCLUDE override for a discovered tool.
(define (msvc-setup-include-owned
  [toolset-root : String]
  [sdk : WindowsSdkLayout]) : String
  (msvc-setup-include (& toolset-root) sdk))

;: Return the first missing VC toolset path, or `MsvcNoString`.
(define (msvc-first-missing-toolset-path
  [toolset-root : (& toolset-root str)]
  [tool : (& tool str)]) : MsvcMaybeString
  (let
    [empty : String ""]
    [toolset-root-text : String (string-append toolset-root (& empty))]
    [tool-text : String (string-append tool (& empty))]
    (cond
      [(not (msvc-path-exists-owned? toolset-root-text))
        (MsvcSomeString toolset-root-text)]
      [(not
          (msvc-path-exists-owned?
            (msvc-toolset-bin-x64-owned toolset-root-text)))
        (MsvcSomeString (msvc-toolset-bin-x64-owned toolset-root-text))]
      [(not
          (msvc-path-exists-owned?
            (msvc-toolset-lib-x64-owned toolset-root-text)))
        (MsvcSomeString (msvc-toolset-lib-x64-owned toolset-root-text))]
      [(not
          (msvc-path-exists-owned?
            (msvc-toolset-include-owned toolset-root-text)))
        (MsvcSomeString (msvc-toolset-include-owned toolset-root-text))]
      [(not
          (msvc-path-exists-owned?
            (msvc-toolset-executable-owned toolset-root-text tool-text)))
        (MsvcSomeString
          (msvc-toolset-executable-owned toolset-root-text tool-text))]
      [else (MsvcNoString)])))

;: Try to construct a tool result from one Visual Studio instance.
(define (msvc-tool-from-instance
  [instance : WindowsSetupInstance]
  [sdk : WindowsSdkLayout]
  [tool : (& tool str)]) : ResultMsvcTool
  (match (msvc-vc-tools-version instance)
    [(MsvcNoString)
      (ErrMsvcTool
        (MsvcSetupUnavailable
          (string-append
            "msvc: could not read VCToolsVersion or "
            (msvc-default-vc-tools-version-path instance))))]
    [(MsvcSomeString version)
      (let
        [empty : String ""]
        [tool-text : String (string-append tool (& empty))]
        [toolset-root : String (msvc-toolset-root instance (& version))]
        (match (msvc-first-missing-toolset-path (& toolset-root) tool)
          [(MsvcSomeString missing)
            (ErrMsvcTool
              (MsvcSetupUnavailable
                (string-append "msvc: missing MSVC toolset path: " missing)))]
          [(MsvcNoString)
            (OkMsvcTool
              (MsvcTool
                (msvc-toolset-executable-owned toolset-root tool-text)
                (msvc-setup-path-owned toolset-root sdk)
                (msvc-setup-lib-owned toolset-root sdk)
                (msvc-setup-include-owned toolset-root sdk)))]))]))

;: Keep the newest usable setup candidate seen so far.
(define (msvc-select-newest-candidate
  [best : MsvcMaybeToolCandidate]
  [tool : MsvcTool]
  [installation-version : (& installation-version str)]) : MsvcMaybeToolCandidate
  (let
    [empty : String ""]
    [installation-version-text : String
      (string-append installation-version (& empty))]
    (match best
      [(MsvcNoToolCandidate)
        (MsvcSomeToolCandidate tool installation-version-text)]
      [(MsvcSomeToolCandidate best-tool best-version)
        (if (msvc-version-greater-owned? installation-version-text best-version)
          (MsvcSomeToolCandidate tool installation-version-text)
          (MsvcSomeToolCandidate best-tool best-version))])))

;: Search all Visual Studio instances for the newest usable requested tool.
(define (msvc-find-tool-in-instances
  [instances : WindowsSetupInstanceList]
  [sdk : WindowsSdkLayout]
  [tool : (& tool str)]
  [best : MsvcMaybeToolCandidate]
  [last-error : String]) : ResultMsvcTool
  (match instances
    [(WindowsSetupInstanceNil)
      (match best
        [(MsvcSomeToolCandidate resolved _) (OkMsvcTool resolved)]
        [(MsvcNoToolCandidate)
          (ErrMsvcTool
            (MsvcSetupUnavailable
              (if (string-eq last-error "")
                "msvc: no Visual Studio / Build Tools instances were reported by SetupConfiguration"
                last-error)))])]
    [(WindowsSetupInstanceCons instance rest)
      (match (msvc-tool-from-instance instance sdk tool)
        [(OkMsvcTool resolved)
          (msvc-find-tool-in-instances
            rest
            sdk
            tool
            (let
              [installation-version : String
                (windows-setup-instance-installation-version instance)]
              (msvc-select-newest-candidate
                best
                resolved
                (& installation-version)))
            last-error)]
        [(ErrMsvcTool error)
          (msvc-find-tool-in-instances
            rest
            sdk
            tool
            best
            (msvc-error-message error))])]))

;: Locate a tool through SetupConfiguration and Windows SDK discovery.
(define (msvc-find-tool-from-setup
  [target : (& target str)]
  [tool : (& tool str)]) : ResultMsvcTool
  (if (not (msvc-host-windows?))
    (ErrMsvcTool
      (MsvcUnsupported
        "msvc: tool discovery is unsupported on non-Windows hosts"))
    (if (not (msvc-supported-target? target))
      (ErrMsvcTool
        (MsvcUnsupported (string-append "msvc: unsupported target " target)))
      (match (windows-sdk-discover)
        [(ErrWindowsSdkLayout error)
          (ErrMsvcTool
            (MsvcSetupUnavailable
              (string-append
                "msvc: Windows SDK discovery failed: "
                (windows-sdk-error-message error))))]
        [(OkWindowsSdkLayout sdk)
          (match (windows-setup-instances)
            [(ErrWindowsSetupInstances error)
              (ErrMsvcTool
                (MsvcSetupUnavailable
                  (string-append
                    "msvc: SetupConfiguration discovery failed: "
                    (windows-setup-error-message error))))]
            [(OkWindowsSetupInstances instances)
              (msvc-find-tool-in-instances
                instances
                sdk
                tool
                (MsvcNoToolCandidate)
                "")])]))))

;: Find an MSVC tool such as `link.exe` and its command environment.
;:
;: The configured Developer Command Prompt path is preferred. Otherwise this
;: falls back to SetupConfiguration + Windows SDK discovery.
(define (msvc-find-tool [target : (& target str)] [tool : (& tool str)]) : ResultMsvcTool
  (if (not (msvc-host-windows?))
    (ErrMsvcTool
      (MsvcUnsupported
        "msvc: tool discovery is unsupported on non-Windows hosts"))
    (if (not (msvc-supported-target? target))
      (ErrMsvcTool
        (MsvcUnsupported (string-append "msvc: unsupported target " target)))
      (match (msvc-find-tool-configured tool)
        [(OkMsvcTool resolved) (OkMsvcTool resolved)]
        [(ErrMsvcTool _) (msvc-find-tool-from-setup target tool)]))))