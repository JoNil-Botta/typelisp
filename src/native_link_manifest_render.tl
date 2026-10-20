;# Stable human inspection of the canonical tree. Byte strings are escaped
;# independently of locale and UTF-8 validity. The output is presentation,
;# never the semantic fingerprint or a command to execute.
(import native_link_manifest_wire as wire)
(import native_link_manifest_types as n)
(import native_link_manifest_core as core)
(import stdlib.byte_buf_core as buf)
(import stdlib.string)
(import stdlib.format)
(import stdlib.iterator)

(defstruct NativeTextWriter
  (bytes buf.ByteBufBuilder)
  (limit i64)
  (ok bool))

(defenum NativeTextResult
  (NativeText String)
  (NativeTextLimitExceeded))

(define (put! [w : (&mut w NativeTextWriter)] [byte : u8]) : unit
  (when
    w.ok
    (if (>= w.bytes.len w.limit)
      (set! w.ok false)
      (buf.byte-buf-builder-push (&mut w.bytes) byte))))

(define (text! [w : (&mut w NativeTextWriter)] [text : (& s str)]) : unit
  (let
    [i : i64 0]
    (while (and w.ok (< i (string.string-length text)))
      (put! w (cast (string.string-ref text i) : u8))
      (set! i (+ i 1)))))

(define (indent! [w : (&mut w NativeTextWriter)] [depth : i64]) : unit
  (put! w (cast 10 : u8))
  (for [i (iterator.range 0 (* depth 2))]
    (put! w (cast 32 : u8))))

(define (quoted! [w : (&mut w NativeTextWriter)] [text : (& s str)]) : unit
  (put! w (cast 34 : u8))
  (let
    [i : i64 0]
    [hex : String "0123456789abcdef"]
    (while (and w.ok (< i (string.string-length text)))
      (let
        [byte : u8 (cast (string.string-ref text i) : u8)]
        [c : i64 (cast byte : i64)]
        (cond
          [(or (= c 34) (= c 92))
            (put! w (cast 92 : u8))
            (put! w byte)]
          [(and (>= c 32) (< c 127)) (put! w byte)]
          [else
            (text! w "\\x")
            (put! w (cast (string.string-ref (& hex) (/ c 16)) : u8))
            (put! w (cast (string.string-ref (& hex) (% c 16)) : u8))]))
      (set! i (+ i 1))))
  (put! w (cast 34 : u8)))

(define (value!
  [w : (&mut w NativeTextWriter)]
  [value : (& v wire.Value)]
  [depth : i64]
  [options : (& o n.PresentationOptions)]) : unit
  (when (not w.ok) (return unit))
  (match value
    [(wire.Null) (text! w "null")]
    [(wire.Boolean value)
      (text!
        w
        (if value
          "true"
          "false"))]
    [(wire.Signed value)
      (let
        [text : String (string.int->string value)]
        (text! w (& text)))]
    [(wire.Unsigned value)
      (let
        [text : String (format.format "{}" value)]
        (text! w (& text)))]
    [(wire.ByteString text) (quoted! w (& text))]
    [(wire.Sequence values)
      (put! w (cast 91 : u8))
      (let
        [i : i64 0]
        (while (and w.ok (< i (deref values).len))
          (when (> i 0) (put! w (cast 44 : u8)))
          (indent! w (+ depth 1))
          (value! w (& (array-ref (deref values).slots i)) (+ depth 1) options)
          (set! i (+ i 1))))
      (when (> (deref values).len 0) (indent! w depth))
      (put! w (cast 93 : u8))]
    [(wire.Record fields)
      (put! w (cast 123 : u8))
      (let
        [i : i64 0]
        (while (and w.ok (< i (deref fields).len))
          (let
            [field : (& v wire.Field) (& (array-ref (deref fields).slots i))]
            (when (> i 0) (put! w (cast 44 : u8)))
            (indent! w (+ depth 1))
            (quoted! w (& field.key))
            (text! w ": ")
            (if (and
              (not options.show-content-identities)
              (string.eq (& field.key) "sha256"))
              (text! w "\"<content identity>\"")
              (value! w (& field.value) (+ depth 1) options)))
          (set! i (+ i 1))))
      (when (> (deref fields).len 0) (indent! w depth))
      (put! w (cast 125 : u8))]))

(define (render-tree
  [value : (& v wire.Value)]
  [options : (& o n.PresentationOptions)]
  [decision : (& d core.NativeCapabilityDecision)]
  [max-bytes : i64]) : NativeTextResult
  (when
    (or (< max-bytes 0) (> max-bytes 33554432))
    (return (NativeTextLimitExceeded)))
  (let
    [writer : NativeTextWriter
      (NativeTextWriter (buf.byte-buf-builder-new) max-bytes true)]
    (text! (&mut writer) "auto-capability: ")
    (let
      [representation : String
        (match decision.representation
          [(core.InternalRepresentationAvailable)
            "internal-representation-available"]
          [(core.ExternalAdapterAdmissionRequired)
            "external-adapter-admission-required"]
          [(core.UnsupportedRepresentation) "unsupported-representation"])]
      (text! (&mut writer) (& representation)))
    (text! (&mut writer) "\ncontent-closure-required: ")
    (text!
      (&mut writer)
      (if decision.requires-content-closure
        "true"
        "false"))
    (text! (&mut writer) "\nopaque-external-closure: ")
    (text!
      (&mut writer)
      (if decision.opaque-external-closure
        "true"
        "false"))
    (put! (&mut writer) (cast 10 : u8))
    (let
      [i : i64 0]
      (while (and writer.ok (< i decision.validation.count))
        (let
          [diagnostic : (& d core.NativeLinkDiagnostic)
            (& (array-ref decision.validation.diagnostics i))]
          [ordinal : String (string.int->string diagnostic.event-ordinal)]
          (text! (&mut writer) "reason ")
          (text! (&mut writer) (& ordinal))
          (text! (&mut writer) " ")
          (quoted! (&mut writer) (& diagnostic.field))
          (text! (&mut writer) ": ")
          (quoted! (&mut writer) (& diagnostic.detail))
          (put! (&mut writer) (cast 10 : u8)))
        (set! i (+ i 1))))
    (when
      decision.validation.truncated
      (text! (&mut writer) "diagnostics-truncated: true\n"))
    (text! (&mut writer) "native-link-v1 ")
    (value! (&mut writer) value 0 options)
    (put! (&mut writer) (cast 10 : u8))
    (if writer.ok
      (NativeText (buf.byte-buf-builder-to-string (& writer.bytes)))
      (NativeTextLimitExceeded))))