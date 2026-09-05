;; Closed parser for reviewed x86-64 template control/frame events.
(import stdlib.string)

(defenum CompilerX64TemplateEventKind
  (DirectCall)
  (IndirectCall)
  (HardwareReturn)
  (DirectTailJump)
  (IndirectTailJump)
  (LocalBranch)
  (StackAdjust)
  (StackRebase)
  (SaveRegister)
  (RestoreRegister)
  (IncomingStackRead)
  (IncomingStackWrite)
  (TerminalProcessTransfer)
  (ExternalContextSwitch)
  (ExternalCallbackEntry)
  (Unsupported))

(defstruct CompilerX64TemplateEvent
  (kind CompilerX64TemplateEventKind)
  (detail String))

(defenum ResultCompilerX64TemplateEvent
  (Ok CompilerX64TemplateEvent)
  (Err String))

(defstruct CompilerX64TemplateEventSeq
  (transcript String)
  (count i64))

(define (compiler-x64-template-event-count-transcript [text : (& text str)]) : i64
  (let
    [n : i64 (string.string-length text)]
    [at : i64 0]
    [count : i64 0]
    (begin
      (while (< at n)
        (begin
          (when
            (or (= at 0) (= (string.string-ref text (- at 1)) '\n'))
            (set! count (+ count 1)))
          (set! at (+ at 1))))
      count)))

(define (compiler-x64-template-events [transcript : (& transcript str)]) : CompilerX64TemplateEventSeq
  (let
    [owned : String
      (string.substring transcript 0 (string.string-length transcript))]
    [count : i64
      (if (= (string.string-length transcript) 0)
        0
        (compiler-x64-template-event-count-transcript transcript))]
    (CompilerX64TemplateEventSeq owned count)))

(define (compiler-x64-template-event-code-index [code : char]) : i64
  (string.index-of-byte "CIRTJBAXSUDWPFE" 0 (cast code : u8)))

(define (compiler-x64-template-event-kind-from-code [code : char]) : CompilerX64TemplateEventKind
  (let
    [index : i64 (compiler-x64-template-event-code-index code)]
    [tag : i64
      (if (< index 0)
        15
        index)]
    (unsafe
      (ptr-read
        (ptr-cast (ptr-addr-of tag) : (Ptr CompilerX64TemplateEventKind))))))

(define (compiler-x64-template-event-code-known? [code : char]) : bool
  (or (>= (compiler-x64-template-event-code-index code) 0) (= code 'O')))

(define (compiler-x64-template-event-ref
  [events : (& events CompilerX64TemplateEventSeq)]
  [index : i64]) : ResultCompilerX64TemplateEvent
  (if (or (< index 0) (>= index events.count))
    (ResultCompilerX64TemplateEvent.Err
      "x64 executable template: event index out of bounds")
    (let
      [text : String events.transcript]
      [n : i64 (string.string-length text)]
      [at : i64 0]
      [row : i64 0]
      [start : i64 0]
      [done : bool false]
      (begin
        (while (and (not done) (< at n))
          (if (= (string.string-ref text at) '\n')
            (if (= row index)
              (set! done true)
              (begin
                (set! row (+ row 1))
                (set! start (+ at 1))
                (set! at (+ at 1))))
            (set! at (+ at 1))))
        (let
          [end : i64
            (if done
              at
              n)]
          [code : char (string.string-ref text start)]
          [detail-start : i64
            (if (and
              (< (+ start 1) end)
              (= (string.string-ref text (+ start 1)) ':'))
              (+ start 2)
              end)]
          [detail : String
            (string.substring text detail-start (- end detail-start))]
          (if (not (compiler-x64-template-event-code-known? code))
            (ResultCompilerX64TemplateEvent.Err
              "x64 executable template: unknown event family")
            (if (and (= code 'O') (= (string.string-length detail) 0))
              (ResultCompilerX64TemplateEvent.Err
                "x64 executable template: unsupported event needs provenance")
              (ResultCompilerX64TemplateEvent.Ok
                (CompilerX64TemplateEvent
                  (compiler-x64-template-event-kind-from-code code)
                  detail)))))))))