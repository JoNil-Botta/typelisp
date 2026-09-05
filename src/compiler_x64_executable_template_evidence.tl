;; Rich reviewed evidence rows for compiler-owned x86-64 templates.
(import compiler_x64_executable_template as x64)
(import compiler_x64_executable_template_catalog as catalog)
(import stdlib.hash)
(import stdlib.io)
(import stdlib.string)

(defenum CompilerX64TemplateAbi
  (InternalX64)
  (SystemV)
  (Win64))

(defenum CompilerX64TemplateFeature
  (Always)
  (Alloc)
  (RegionMark)
  (RegionReset)
  (Profile)
  (StartupProfile)
  (TlciMacroEntry)
  (Backtrace)
  (ArenaDebug)
  (ProfileArenaDebug)
  (AllocProfile)
  (AllocArenaDebug)
  (AllocProfileArenaDebug)
  (RegionResetProfile)
  (RegionResetArenaDebug)
  (RegionResetProfileArenaDebug)
  (NativeEntryStartupProfile)
  (NativeEntryBacktrace)
  (NativeEntry))

(defenum CompilerX64TemplateContributionKind
  (RuntimeFunctions)
  (Startup)
  (TlciBridge)
  (ExternalFiberCallback)
  (ExternalExceptionCallback)
  (ByteFragment)
  (MixedRuntimeBundle))

(defenum CompilerX64TemplateTerminalBehavior
  (FallsThrough)
  (Returns)
  (TailTransfers)
  (TerminatesProcess)
  (SuspendsOrTerminates)
  (ReturnsOrTerminates)
  (Mixed)
  (Unknown))

(defstruct CompilerX64ExecutableTemplate
  (id x64.CompilerX64ExecutableTemplateId)
  (schema i64)
  (producer String)
  (target x64.CompilerX64TemplateTarget)
  (abi CompilerX64TemplateAbi)
  (feature CompilerX64TemplateFeature)
  (render-kind x64.CompilerX64TemplateRenderKind)
  (contribution-kind CompilerX64TemplateContributionKind)
  (entry-anchor String)
  ;; Ordered newline-delimited interior anchors; empty means none.
  (interior-anchors String)
  (end-anchor String)
  ;; Data-only unwind/metadata rows that describe this executable contribution.
  (related-data String)
  (terminal CompilerX64TemplateTerminalBehavior)
  (events String)
  (event-count i64)
  ;; -1 marks a structured/dynamic contribution whose exact payload is supplied
  ;; to the semantic-identity encoder by its owning producer.
  (expected-rendered-size i64)
  (expected-rendered-hash i64))

(define (compiler-x64-template-related-data
  [id : x64.CompilerX64ExecutableTemplateId]) : String
  (match id
    [(x64.CompilerX64ExecutableTemplateId.WindowsObjectStartContribution)
      ".pdata:_tl_start..L_tl_start_end->.L_tl_start_xdata|xdata-size=8|xdata-hash=2141552412"]
    [(x64.CompilerX64ExecutableTemplateId.WindowsObjectMainFiberContribution)
      ".pdata:.L_tl_main_fiber..L_tl_main_fiber_end->.L_tl_start_xdata|xdata-size=8|xdata-hash=2141552412"]
    [(x64.CompilerX64ExecutableTemplateId.WindowsObjectOverflowFilterContribution)
      ".pdata:.L_tl_stack_overflow_filter..L_tl_stack_overflow_filter_end->.L_tl_start_xdata|xdata-size=8|xdata-hash=2141552412"]
    [_ ""]))

(define (compiler-x64-template-catalog-decode [encoded : String]) : String
  (let
    [length : i64 (string.string-length (& encoded))]
    [out : (__tl_dyn-array u8) (__tl_make-array u8 length)]
    [read-at : i64 0]
    [write-at : i64 0]
    (begin
      (while (< read-at length)
        (let
          [current : char (string.string-ref (& encoded) read-at)]
          (if (= current '\\')
            (if (>= (+ read-at 1) length)
              (io.panic "x64 executable template: truncated catalog escape")
              (let
                [escaped : char (string.string-ref (& encoded) (+ read-at 1))]
                (begin
                  (cond
                    [(= escaped 'n')
                      (set! (array-ref out write-at) (cast '\n' : u8))]
                    [(= escaped '\\')
                      (set! (array-ref out write-at) (cast '\\' : u8))]
                    [else
                      (io.panic
                        "x64 executable template: unknown catalog escape")])
                  (set! read-at (+ read-at 2)))))
            (begin
              (set! (array-ref out write-at) (cast current : u8))
              (set! read-at (+ read-at 1))))
          (set! write-at (+ write-at 1))))
      (unsafe
        (string-from-bytes (ptr-cast (__tl_array-data out) : (Ptr u8)) write-at)))))

(define (compiler-x64-template-abi-from-catalog [value : (& value str)]) : CompilerX64TemplateAbi
  (let
    [tag : i64 (catalog.compiler-x64-template-catalog-tag value)]
    (if (or (< tag 0) (>= tag 3))
      (io.panic "x64 executable template: unknown catalog ABI")
      (unsafe
        (ptr-read (ptr-cast (ptr-addr-of tag) : (Ptr CompilerX64TemplateAbi)))))))

(define (compiler-x64-template-feature-from-catalog [value : (& value str)]) : CompilerX64TemplateFeature
  (let
    [tag : i64 (catalog.compiler-x64-template-catalog-tag value)]
    (if (or (< tag 0) (>= tag 19))
      (io.panic "x64 executable template: evidence enum tag is out of range")
      (unsafe
        (ptr-read
          (ptr-cast (ptr-addr-of tag) : (Ptr CompilerX64TemplateFeature)))))))

(define (compiler-x64-template-contribution-kind-from-catalog
  [value : (& value str)]) : CompilerX64TemplateContributionKind
  (let
    [tag : i64 (catalog.compiler-x64-template-catalog-tag value)]
    (if (or (< tag 0) (>= tag 7))
      (io.panic "x64 executable template: evidence enum tag is out of range")
      (unsafe
        (ptr-read
          (ptr-cast
            (ptr-addr-of tag)
            : (Ptr CompilerX64TemplateContributionKind)))))))

(define (compiler-x64-template-terminal-from-catalog [value : (& value str)]) : CompilerX64TemplateTerminalBehavior
  (let
    [tag : i64 (catalog.compiler-x64-template-catalog-tag value)]
    (if (or (< tag 0) (>= tag 8))
      (io.panic "x64 executable template: evidence enum tag is out of range")
      (unsafe
        (ptr-read
          (ptr-cast
            (ptr-addr-of tag)
            : (Ptr CompilerX64TemplateTerminalBehavior)))))))

(define (compiler-x64-template-row
  [id : x64.CompilerX64ExecutableTemplateId]
  [producer : String]
  [target : x64.CompilerX64TemplateTarget]
  [abi : CompilerX64TemplateAbi]
  [feature : CompilerX64TemplateFeature]
  [render-kind : x64.CompilerX64TemplateRenderKind]
  [contribution-kind : CompilerX64TemplateContributionKind]
  [entry-anchor : String]
  [interior-anchors : String]
  [end-anchor : String]
  [terminal : CompilerX64TemplateTerminalBehavior]
  [events : String]
  [event-count : i64]
  [expected-rendered-size : i64]
  [expected-rendered-hash : i64]) : CompilerX64ExecutableTemplate
  (CompilerX64ExecutableTemplate
    id
    1
    producer
    target
    abi
    feature
    render-kind
    contribution-kind
    entry-anchor
    interior-anchors
    end-anchor
    (compiler-x64-template-related-data id)
    terminal
    events
    event-count
    expected-rendered-size
    expected-rendered-hash))

(define (compiler-x64-template-id-name
  [id : x64.CompilerX64ExecutableTemplateId]) : String
  (let
    [data : String (catalog.compiler-x64-template-catalog-data-shared-view)]
    [row-start : i64
      (catalog.compiler-x64-template-catalog-row-start
        (& data)
        (catalog.compiler-x64-template-id-index id))]
    [row-end : i64
      (catalog.compiler-x64-template-catalog-row-end (& data) row-start)]
    (catalog.compiler-x64-template-catalog-field (& data) row-start row-end 1)))

(define (compiler-x64-template-registry-row
  [id : x64.CompilerX64ExecutableTemplateId]) : CompilerX64ExecutableTemplate
  (let
    [data : String (catalog.compiler-x64-template-catalog-data-shared-view)]
    [row-start : i64
      (catalog.compiler-x64-template-catalog-row-start
        (& data)
        (catalog.compiler-x64-template-id-index id))]
    [row-end : i64
      (catalog.compiler-x64-template-catalog-row-end (& data) row-start)]
    [producer : String
      (catalog.compiler-x64-template-catalog-field (& data) row-start row-end 2)]
    [target : String
      (catalog.compiler-x64-template-catalog-field (& data) row-start row-end 3)]
    [abi : String
      (catalog.compiler-x64-template-catalog-field (& data) row-start row-end 4)]
    [feature : String
      (catalog.compiler-x64-template-catalog-field (& data) row-start row-end 5)]
    [render-kind : String
      (catalog.compiler-x64-template-catalog-field (& data) row-start row-end 6)]
    [contribution-kind : String
      (catalog.compiler-x64-template-catalog-field (& data) row-start row-end 7)]
    [entry-anchor : String
      (catalog.compiler-x64-template-catalog-field (& data) row-start row-end 8)]
    [interior-anchors : String
      (compiler-x64-template-catalog-decode
        (catalog.compiler-x64-template-catalog-field
          (& data)
          row-start
          row-end
          9))]
    [end-anchor : String
      (catalog.compiler-x64-template-catalog-field
        (& data)
        row-start
        row-end
        10)]
    [terminal : String
      (catalog.compiler-x64-template-catalog-field
        (& data)
        row-start
        row-end
        11)]
    [events : String
      (compiler-x64-template-catalog-decode
        (catalog.compiler-x64-template-catalog-field
          (& data)
          row-start
          row-end
          12))]
    [event-count : String
      (catalog.compiler-x64-template-catalog-field
        (& data)
        row-start
        row-end
        13)]
    [expected-rendered-size : String
      (catalog.compiler-x64-template-catalog-field
        (& data)
        row-start
        row-end
        14)]
    [expected-rendered-hash : String
      (catalog.compiler-x64-template-catalog-field
        (& data)
        row-start
        row-end
        15)]
    (compiler-x64-template-row
      id
      producer
      (catalog.compiler-x64-template-target-from-catalog (& target))
      (compiler-x64-template-abi-from-catalog (& abi))
      (compiler-x64-template-feature-from-catalog (& feature))
      (catalog.compiler-x64-template-render-kind-from-catalog (& render-kind))
      (compiler-x64-template-contribution-kind-from-catalog
        (& contribution-kind))
      entry-anchor
      interior-anchors
      end-anchor
      (compiler-x64-template-terminal-from-catalog (& terminal))
      events
      (catalog.compiler-x64-template-catalog-int-range
        (& event-count)
        0
        (string.string-length (& event-count)))
      (catalog.compiler-x64-template-catalog-int-range
        (& expected-rendered-size)
        0
        (string.string-length (& expected-rendered-size)))
      (catalog.compiler-x64-template-catalog-int-range
        (& expected-rendered-hash)
        0
        (string.string-length (& expected-rendered-hash))))))

(define (compiler-x64-template-rendered-payload-valid?
  [row : CompilerX64ExecutableTemplate]
  [rendered : (& rendered str)]) : bool
  (or
    (< row.expected-rendered-size 0)
    (and
      (= (string.string-length rendered) row.expected-rendered-size)
      (= (stdlib.hash.string-key rendered) row.expected-rendered-hash))))

(define (compiler-x64-template-row-valid-for?
  [row : CompilerX64ExecutableTemplate]
  [target : x64.CompilerX64TemplateTarget]
  [render-kind : x64.CompilerX64TemplateRenderKind]) : bool
  (and
    (= row.schema 1)
    (> (string.string-length (& row.producer)) 0)
    (=
      (x64.compiler-x64-template-enum-tag row.target)
      (x64.compiler-x64-template-enum-tag row.abi))
    (if (= (x64.compiler-x64-template-enum-tag row.render-kind) 1)
      (and
        (= (string.string-length (& row.entry-anchor)) 0)
        (= (string.string-length (& row.interior-anchors)) 0)
        (= (string.string-length (& row.end-anchor)) 0))
      (and
        (> (string.string-length (& row.entry-anchor)) 0)
        (> (string.string-length (& row.end-anchor)) 0)))
    (x64.compiler-x64-template-target-matches? row.target target)
    (=
      (x64.compiler-x64-template-enum-tag row.render-kind)
      (x64.compiler-x64-template-enum-tag render-kind))))