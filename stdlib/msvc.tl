;# MSVC tool discovery (#855): find link.exe and its command environment.
;#
;# Detect an already-configured MSVC command environment (a Developer Command
;# Prompt or equivalent) first. If that is absent, scan the standard Visual
;# Studio / Build Tools install locations, combine the selected VC toolset with
;# Windows SDK discovery, and return the `PATH`, `LIB`, and `INCLUDE` overrides
;# needed to invoke the requested MSVC tool from a normal shell.
;#
;# Usage: `(import "stdlib/msvc.tl")`
;#
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
(import "vector.tl")

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

;: Usable VC toolset candidate found under a standard install location.
(defstruct MsvcToolset
  (root String)
  (version String))

;: Optional VC toolset result while scanning standard install locations.
(defenum MsvcMaybeToolset
  (MsvcNoToolset)
  (MsvcSomeToolset MsvcToolset))

;: Usable Windows SDK candidate with root and version.
(defstruct MsvcSdk
  (root String)
  (version String))

;: Optional Windows SDK result while scanning SDK roots.
(defenum MsvcMaybeSdk
  (MsvcNoSdk)
  (MsvcSomeSdk MsvcSdk))

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

;: Return vector-backed process environment overrides for invoking the tool.
(define (msvc-tool-process-env-vec [tool : MsvcTool]) : ProcessEnvVec
  (process-env-vec-append
    (process-env-vec-append
      (process-env-vec-append
        (process-env-vec-new)
        "PATH"
        (msvc-tool-path tool))
      "LIB"
      (msvc-tool-lib tool))
    "INCLUDE"
    (msvc-tool-include tool)))

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
  (let
    [supported : String "x86_64-pc-windows-msvc"]
    (string-eq-borrowed target (& supported))))

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
    [left-text : String (string-copy-borrowed left)]
    [right-text : String (string-copy-borrowed right)]
    (msvc-version-greater-owned? left-text right-text)))

;: Return true when `path` exists, mapping probe errors to false.
(define (msvc-path-exists? [path : (& path str)]) : bool
  (match (try-file-exists? path)
    [(OkIoBool exists) exists]
    [(ErrIoBool _) false]))

;: Return true when an owned path exists through the borrowed public helper.
(define (msvc-path-exists-owned? [path : String]) : bool
  (msvc-path-exists? (& path)))

;: Return true when an owned path exists and is a directory.
(define (msvc-dir-exists-owned? [path : String]) : bool
  (match (try-file-kind (& path))
    [(OkFsFileKind kind) (fs-file-kind-directory? kind)]
    [(ErrFsFileKind _) false]))

;: Join two filesystem path segments using the platform separator.
(define (msvc-path-join [left : String] [right : String]) : String
  (fs-path-join (& left) (& right)))

;: Join three filesystem path segments.
(define (msvc-path-join3 [a : String] [b : String] [c : String]) : String
  (msvc-path-join (msvc-path-join a b) c))

;: Join four filesystem path segments.
(define (msvc-path-join4 [a : String] [b : String] [c : String] [d : String]) : String
  (msvc-path-join (msvc-path-join3 a b c) d))

;: Join five filesystem path segments.
(define (msvc-path-join5
  [a : String]
  [b : String]
  [c : String]
  [d : String]
  [e : String]) : String
  (msvc-path-join (msvc-path-join4 a b c d) e))

;: Join six filesystem path segments.
(define (msvc-path-join6
  [a : String]
  [b : String]
  [c : String]
  [d : String]
  [e : String]
  [f : String]) : String
  (msvc-path-join (msvc-path-join5 a b c d e) f))

;: Search PATH directories for `tool`, returning the first existing candidate.
(define (msvc-search-dirs-vec-owned-from
  [dirs : StringVec]
  [index : i64]
  [tool : String]) : MsvcMaybeString
  (if (>= index (string-vec-len dirs))
    (MsvcNoString)
    (let
      [candidate : String (msvc-path-join (string-vec-get dirs index "") tool)]
      (if (msvc-path-exists-owned? candidate)
        (MsvcSomeString candidate)
        (msvc-search-dirs-vec-owned-from dirs (+ index 1) tool)))))

;: Search PATH directories for `tool`, returning the first existing candidate.
(define (msvc-search-dirs-vec-owned [dirs : StringVec] [tool : String]) : MsvcMaybeString
  (msvc-search-dirs-vec-owned-from dirs 0 tool))

;: Search PATH directories for `tool`, returning the first existing candidate.
(define (msvc-search-dirs-owned [dirs : EnvStringList] [tool : String]) : MsvcMaybeString
  (msvc-search-dirs-vec-owned (env-string-list-to-vec dirs) tool))

;: Search PATH directories for `tool`, returning the first existing candidate.
(define (msvc-search-dirs-vec [dirs : StringVec] [tool : (& tool str)]) : MsvcMaybeString
  (let
    [tool-text : String (string-copy-borrowed tool)]
    (msvc-search-dirs-vec-owned dirs tool-text)))

;: Search PATH directories for `tool`, returning the first existing candidate.
(define (msvc-search-dirs [dirs : EnvStringList] [tool : (& tool str)]) : MsvcMaybeString
  (let
    [tool-text : String (string-copy-borrowed tool)]
    (msvc-search-dirs-owned dirs tool-text)))

;: Locate `tool` on the PATH environment variable.
(define (msvc-find-on-path [tool : (& tool str)]) : MsvcMaybeString
  (let
    [name : String "PATH"]
    (match (env-path-list-vec (& name))
      [(EnvNoStringVec) (MsvcNoString)]
      [(EnvSomeStringVec dirs) (msvc-search-dirs-vec dirs tool)])))

;: Read an environment variable or the empty string when it is unset.
(define (msvc-env-or-empty [name : (& name str)]) : String
  (match (env-get name)
    [(EnvSomeString value) value]
    [(EnvNoString) ""]))

;: Read an owned environment variable name or the empty string when it is unset.
(define (msvc-env-or-empty-owned [name : String]) : String
  (msvc-env-or-empty (& name)))

;: Read an owned environment variable name, or return `fallback`.
(define (msvc-env-or-default-owned [name : String] [fallback : String]) : String
  (let
    [value : String (msvc-env-or-empty-owned name)]
    (if (string-eq value "")
      fallback
      value)))

;: Join owned `head` before an optional PATH-style suffix.
(define (msvc-path-list-prepend-owned [head : String] [tail : String]) : String
  (if (string-eq tail "")
    head
    (string-append (string-append head (env-path-list-separator)) tail)))

;: Join `head` before an optional PATH-style suffix.
(define (msvc-path-list-prepend [head : (& head str)] [tail : (& tail str)]) : String
  (let
    [head-text : String (string-copy-borrowed head)]
    [tail-text : String (string-copy-borrowed tail)]
    (msvc-path-list-prepend-owned head-text tail-text)))

;: Join two owned required PATH-style entries.
(define (msvc-path-list-join2-owned [a : String] [b : String]) : String
  (string-append (string-append a (env-path-list-separator)) b))

;: Join two required PATH-style entries.
(define (msvc-path-list-join2 [a : (& a str)] [b : (& b str)]) : String
  (let
    [a-text : String (string-copy-borrowed a)]
    [b-text : String (string-copy-borrowed b)]
    (msvc-path-list-join2-owned a-text b-text)))

;: Join three owned required PATH-style entries.
(define (msvc-path-list-join3-owned [a : String] [b : String] [c : String]) : String
  (msvc-path-list-join2-owned (msvc-path-list-join2-owned a b) c))

;: Join three required PATH-style entries.
(define (msvc-path-list-join3 [a : (& a str)] [b : (& b str)] [c : (& c str)]) : String
  (let
    [a-text : String (string-copy-borrowed a)]
    [b-text : String (string-copy-borrowed b)]
    [c-text : String (string-copy-borrowed c)]
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
    [a-text : String (string-copy-borrowed a)]
    [b-text : String (string-copy-borrowed b)]
    [c-text : String (string-copy-borrowed c)]
    [d-text : String (string-copy-borrowed d)]
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
    [a-text : String (string-copy-borrowed a)]
    [b-text : String (string-copy-borrowed b)]
    [c-text : String (string-copy-borrowed c)]
    [tail-text : String (string-copy-borrowed tail)]
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
    [a-text : String (string-copy-borrowed a)]
    [b-text : String (string-copy-borrowed b)]
    [tail-text : String (string-copy-borrowed tail)]
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
    [a-text : String (string-copy-borrowed a)]
    [b-text : String (string-copy-borrowed b)]
    [c-text : String (string-copy-borrowed c)]
    [d-text : String (string-copy-borrowed d)]
    [tail-text : String (string-copy-borrowed tail)]
    (msvc-path-list-join4-with-tail-owned a-text b-text c-text d-text tail-text)))

;: Build a configured tool result once the executable path is known.
(define (msvc-configured-result [executable : String]) : ResultMsvcTool
  (let
    [name : String "LIB"]
    (match (env-get (& name))
      [(EnvNoString)
        (ErrMsvcTool
          (MsvcMissingEnvironment
            "msvc: LIB is not set; run from a Developer Command Prompt or use auto-discovery"))]
      [(EnvSomeString lib)
        (let
          [name : String "INCLUDE"]
          (match (env-get (& name))
            [(EnvNoString)
              (ErrMsvcTool
                (MsvcMissingEnvironment
                  "msvc: INCLUDE is not set; run from a Developer Command Prompt or use auto-discovery"))]
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
      (let
        [tool-text : String (string-copy-borrowed tool)]
        (ErrMsvcTool
          (MsvcToolNotFound
            (string-append
              (string-append "msvc: could not find " tool-text)
              " on PATH; run from a Developer Command Prompt or install Visual Studio Build Tools"))))]))

;: Program Files root used by ordinary Visual Studio SKUs.
(define (msvc-program-files) : String
  (msvc-env-or-default-owned "ProgramFiles" "C:/Program Files"))

;: Program Files (x86) root used by Build Tools and Windows Kits.
(define (msvc-program-files-x86) : String
  (msvc-env-or-default-owned "ProgramFiles(x86)" "C:/Program Files (x86)"))

;: Return a standard Visual Studio VC toolset parent directory.
(define (msvc-vs-toolset-parent
  [program-files : String]
  [year : String]
  [edition : String]) : String
  (msvc-path-join6
    program-files
    "Microsoft Visual Studio"
    year
    edition
    "VC"
    "Tools/MSVC"))

;: Candidate Visual Studio / Build Tools toolset parent directories.
(define (msvc-toolset-parent-candidates) : StringVec
  (let
    [pf : String (msvc-program-files)]
    [pfx : String (msvc-program-files-x86)]
    [items : StringVec (string-vec-with-capacity 8)]
    (begin
      (set!
        items
        (string-vec-push items (msvc-vs-toolset-parent pf "2022" "Enterprise")))
      (set!
        items
        (string-vec-push
          items
          (msvc-vs-toolset-parent pf "2022" "Professional")))
      (set!
        items
        (string-vec-push items (msvc-vs-toolset-parent pf "2022" "Community")))
      (set!
        items
        (string-vec-push items (msvc-vs-toolset-parent pfx "2022" "BuildTools")))
      (set!
        items
        (string-vec-push items (msvc-vs-toolset-parent pf "2019" "Enterprise")))
      (set!
        items
        (string-vec-push
          items
          (msvc-vs-toolset-parent pf "2019" "Professional")))
      (set!
        items
        (string-vec-push items (msvc-vs-toolset-parent pf "2019" "Community")))
      (string-vec-push items (msvc-vs-toolset-parent pfx "2019" "BuildTools")))))

;: Return the bin directory for host x64 -> target x64 tools.
(define (msvc-toolset-bin-dir [toolset-root : String]) : String
  (msvc-path-join4 toolset-root "bin" "Hostx64" "x64"))

;: Return a tool executable path inside a toolset root.
(define (msvc-toolset-tool-path [toolset-root : String] [tool : String]) : String
  (msvc-path-join (msvc-toolset-bin-dir toolset-root) tool))

;: Scan one VC Tools/MSVC parent for the newest version containing `tool`.
(define (msvc-toolset-scan-entries
  [entries : StringVec]
  [index : i64]
  [parent : String]
  [tool : String]
  [best-root : String]
  [best-version : String]
  [has-best : bool]) : MsvcMaybeToolset
  (if (>= index (string-vec-len entries))
    (if has-best
      (MsvcSomeToolset (MsvcToolset best-root best-version))
      (MsvcNoToolset))
    (let
      [version : String (string-vec-get entries index "")]
      [toolset-root : String (msvc-path-join parent version)]
      [tool-path : String (msvc-toolset-tool-path toolset-root tool)]
      [usable : bool (msvc-path-exists-owned? tool-path)]
      [newer : bool
        (if has-best
          (msvc-version-greater-owned? version best-version)
          true)]
      (if (and usable newer)
        (msvc-toolset-scan-entries
          entries
          (+ index 1)
          parent
          tool
          toolset-root
          version
          true)
        (msvc-toolset-scan-entries
          entries
          (+ index 1)
          parent
          tool
          best-root
          best-version
          has-best)))))

;: Return the newest toolset under one parent, if any.
(define (msvc-find-toolset-in-parent [parent : String] [tool : String]) : MsvcMaybeToolset
  (match (try-read-dir-vec (& parent))
    [(OkIoStringVec entries)
      (msvc-toolset-scan-entries entries 0 parent tool "" "" false)]
    [(ErrIoStringVec _) (MsvcNoToolset)]))

;: Return true when `candidate` should replace the current best toolset.
(define (msvc-toolset-candidate-newer?
  [candidate : MsvcToolset]
  [best-version : String]
  [has-best : bool]) : bool
  (if has-best
    (msvc-version-greater-owned? (struct-get candidate version) best-version)
    true))

;: Scan standard Visual Studio locations for the newest toolset containing `tool`.
(define (msvc-find-toolset-parents
  [parents : StringVec]
  [index : i64]
  [tool : String]
  [best-root : String]
  [best-version : String]
  [has-best : bool]) : MsvcMaybeToolset
  (if (>= index (string-vec-len parents))
    (if has-best
      (MsvcSomeToolset (MsvcToolset best-root best-version))
      (MsvcNoToolset))
    (let
      [parent : String (string-vec-get parents index "")]
      (match (msvc-find-toolset-in-parent parent tool)
        [(MsvcNoToolset)
          (msvc-find-toolset-parents
            parents
            (+ index 1)
            tool
            best-root
            best-version
            has-best)]
        [(MsvcSomeToolset candidate)
          (if (msvc-toolset-candidate-newer? candidate best-version has-best)
            (msvc-find-toolset-parents
              parents
              (+ index 1)
              tool
              (struct-get candidate root)
              (struct-get candidate version)
              true)
            (msvc-find-toolset-parents
              parents
              (+ index 1)
              tool
              best-root
              best-version
              has-best))]))))

;: Find the newest installed VC toolset containing `tool`.
(define (msvc-find-toolset [tool : String]) : MsvcMaybeToolset
  (msvc-find-toolset-parents
    (msvc-toolset-parent-candidates)
    0
    tool
    ""
    ""
    false))

;: Candidate Windows SDK roots.
(define (msvc-sdk-root-candidates) : StringVec
  (let
    [env-root : String (msvc-env-or-empty-owned "WindowsSdkDir")]
    [pfx : String (msvc-program-files-x86)]
    [pf : String (msvc-program-files)]
    [items : StringVec (string-vec-with-capacity 3)]
    (begin
      (if (string-eq env-root "")
        unit
        (set! items (string-vec-push items env-root)))
      (set!
        items
        (string-vec-push items (msvc-path-join3 pfx "Windows Kits" "10")))
      (string-vec-push items (msvc-path-join3 pf "Windows Kits" "10")))))

;: Return the root for one Windows SDK version.
(define (msvc-sdk-version-root [sdk-root : String] [version : String]) : String
  (msvc-path-join (msvc-path-join sdk-root "Lib") version))

;: Return the SDK um/x64 library directory.
(define (msvc-sdk-um-lib-dir [sdk : MsvcSdk]) : String
  (msvc-path-join4
    (struct-get sdk root)
    "Lib"
    (struct-get sdk version)
    "um/x64"))

;: Return the SDK ucrt/x64 library directory.
(define (msvc-sdk-ucrt-lib-dir [sdk : MsvcSdk]) : String
  (msvc-path-join4
    (struct-get sdk root)
    "Lib"
    (struct-get sdk version)
    "ucrt/x64"))

;: Return one SDK include directory.
(define (msvc-sdk-include-dir [sdk : MsvcSdk] [name : String]) : String
  (msvc-path-join4
    (struct-get sdk root)
    "Include"
    (struct-get sdk version)
    name))

;: Return true when a Windows SDK version has the pieces needed by link.exe.
(define (msvc-sdk-version-usable? [sdk-root : String] [version : String]) : bool
  (let
    [lib-root : String (msvc-sdk-version-root sdk-root version)]
    [kernel32 : String (msvc-path-join3 lib-root "um/x64" "kernel32.lib")]
    [ucrt : String (msvc-path-join3 lib-root "ucrt/x64" "ucrt.lib")]
    [include-root : String
      (msvc-path-join (msvc-path-join sdk-root "Include") version)]
    (and
      (msvc-path-exists-owned? kernel32)
      (msvc-path-exists-owned? ucrt)
      (msvc-dir-exists-owned? (msvc-path-join include-root "shared"))
      (msvc-dir-exists-owned? (msvc-path-join include-root "um"))
      (msvc-dir-exists-owned? (msvc-path-join include-root "ucrt")))))

;: Scan one Windows SDK root for the newest usable version.
(define (msvc-sdk-scan-entries
  [entries : StringVec]
  [index : i64]
  [sdk-root : String]
  [best-version : String]
  [has-best : bool]) : MsvcMaybeSdk
  (if (>= index (string-vec-len entries))
    (if has-best
      (MsvcSomeSdk (MsvcSdk sdk-root best-version))
      (MsvcNoSdk))
    (let
      [version : String (string-vec-get entries index "")]
      [usable : bool (msvc-sdk-version-usable? sdk-root version)]
      [newer : bool
        (if has-best
          (msvc-version-greater-owned? version best-version)
          true)]
      (if (and usable newer)
        (msvc-sdk-scan-entries entries (+ index 1) sdk-root version true)
        (msvc-sdk-scan-entries
          entries
          (+ index 1)
          sdk-root
          best-version
          has-best)))))

;: Return the newest usable SDK under one root, if any.
(define (msvc-find-sdk-in-root [sdk-root : String]) : MsvcMaybeSdk
  (let
    [lib-dir : String (msvc-path-join sdk-root "Lib")]
    (match (try-read-dir-vec (& lib-dir))
      [(OkIoStringVec entries)
        (msvc-sdk-scan-entries entries 0 sdk-root "" false)]
      [(ErrIoStringVec _) (MsvcNoSdk)])))

;: Return true when `candidate` should replace the current best SDK.
(define (msvc-sdk-candidate-newer?
  [candidate : MsvcSdk]
  [best-version : String]
  [has-best : bool]) : bool
  (if has-best
    (msvc-version-greater-owned? (struct-get candidate version) best-version)
    true))

;: Scan standard Windows SDK roots.
(define (msvc-find-sdk-roots
  [roots : StringVec]
  [index : i64]
  [best-root : String]
  [best-version : String]
  [has-best : bool]) : MsvcMaybeSdk
  (if (>= index (string-vec-len roots))
    (if has-best
      (MsvcSomeSdk (MsvcSdk best-root best-version))
      (MsvcNoSdk))
    (let
      [root : String (string-vec-get roots index "")]
      (match (msvc-find-sdk-in-root root)
        [(MsvcNoSdk)
          (msvc-find-sdk-roots
            roots
            (+ index 1)
            best-root
            best-version
            has-best)]
        [(MsvcSomeSdk candidate)
          (if (msvc-sdk-candidate-newer? candidate best-version has-best)
            (msvc-find-sdk-roots
              roots
              (+ index 1)
              (struct-get candidate root)
              (struct-get candidate version)
              true)
            (msvc-find-sdk-roots
              roots
              (+ index 1)
              best-root
              best-version
              has-best))]))))

;: Find the newest usable Windows SDK.
(define (msvc-find-sdk) : MsvcMaybeSdk
  (msvc-find-sdk-roots (msvc-sdk-root-candidates) 0 "" "" false))

;: Build an auto-discovered MSVC tool result from a toolset and SDK.
(define (msvc-auto-result
  [toolset : MsvcToolset]
  [sdk : MsvcSdk]
  [tool : String]) : MsvcTool
  (let
    [toolset-root : String (struct-get toolset root)]
    [bin-dir : String (msvc-toolset-bin-dir toolset-root)]
    [toolset-lib : String (msvc-path-join3 toolset-root "lib" "x64")]
    [toolset-include : String (msvc-path-join toolset-root "include")]
    [sdk-um-lib : String (msvc-sdk-um-lib-dir sdk)]
    [sdk-ucrt-lib : String (msvc-sdk-ucrt-lib-dir sdk)]
    [sdk-shared-include : String (msvc-sdk-include-dir sdk "shared")]
    [sdk-um-include : String (msvc-sdk-include-dir sdk "um")]
    [sdk-ucrt-include : String (msvc-sdk-include-dir sdk "ucrt")]
    (MsvcTool
      (msvc-toolset-tool-path toolset-root tool)
      (msvc-path-list-prepend-owned bin-dir (msvc-env-or-empty-owned "PATH"))
      (msvc-path-list-join3-with-tail-owned
        toolset-lib
        sdk-um-lib
        sdk-ucrt-lib
        (msvc-env-or-empty-owned "LIB"))
      (msvc-path-list-join4-with-tail-owned
        toolset-include
        sdk-shared-include
        sdk-um-include
        sdk-ucrt-include
        (msvc-env-or-empty-owned "INCLUDE")))))

;: Discover a Visual Studio toolset and Windows SDK from standard locations.
(define (msvc-find-tool-auto [tool : (& tool str)]) : ResultMsvcTool
  (let
    [tool-text : String (string-copy-borrowed tool)]
    (match (msvc-find-toolset tool-text)
      [(MsvcNoToolset)
        (ErrMsvcTool
          (MsvcToolNotFound
            (string-append
              (string-append "msvc: could not discover " tool-text)
              " under standard Visual Studio Build Tools locations")))]
      [(MsvcSomeToolset toolset)
        (match (msvc-find-sdk)
          [(MsvcNoSdk)
            (ErrMsvcTool
              (MsvcSetupUnavailable
                "msvc: could not discover a usable Windows SDK under standard locations"))]
          [(MsvcSomeSdk sdk)
            (OkMsvcTool (msvc-auto-result toolset sdk tool-text))])])))

;: Find an MSVC tool such as `link.exe` and its command environment.
;:
;: Resolves the tool from a configured Developer Command Prompt environment
;: first, then from standard Visual Studio / Windows SDK install locations.
(define (msvc-find-tool [target : (& target str)] [tool : (& tool str)]) : ResultMsvcTool
  (if (not (msvc-host-windows?))
    (ErrMsvcTool
      (MsvcUnsupported
        "msvc: tool discovery is unsupported on non-Windows hosts"))
    (if (not (msvc-supported-target? target))
      (ErrMsvcTool
        (let
          [target-text : String (string-copy-borrowed target)]
          (MsvcUnsupported
            (string-append "msvc: unsupported target " target-text))))
      (match (msvc-find-tool-configured tool)
        [(OkMsvcTool resolved) (OkMsvcTool resolved)]
        [(ErrMsvcTool _) (msvc-find-tool-auto tool)]))))