;; Exercise clone hooks from named, generated and root owners.
(import stdlib.clone)
(import stdlib.string)
(import explicit_clone_generation_owner as named)

(defmacro (record-owner [T : type]) : Module
  `(begin
    (module generated_explicit_clone_record)
    (import stdlib.clone)
    (defstruct TLS2Record_Header
      (value ,T))
    (stdlib.clone.gen-clone TLS2Record_Header)))

(import (record-owner String) as generated)

(defstruct RootRecord
  (label String))

(clone.gen-clone RootRecord)

(defstruct CopyCell
  (rank i64))

(define (generated-and-root-ok?) : bool
  (let
    [record : generated.TLS2Record_Header
      (generated.TLS2Record_Header (string.append "gen" "erated"))]
    [record-copy : generated.TLS2Record_Header (clone.deep record)]
    [record-direct : generated.TLS2Record_Header
      (generated.clone-tls2-record-header (& record))]
    [root : RootRecord (RootRecord (string.append "ro" "ot"))]
    [root-copy : RootRecord (clone-root-record (& root))]
    [root-deep : RootRecord (clone.deep root)]
    [cell : CopyCell (CopyCell 42)]
    [cell-copy : CopyCell (clone.deep cell)]
    (set! record-copy.value "changed")
    (set! root-copy.label "changed")
    (and
      (string.eq record.value "generated")
      (string.eq record-copy.value "changed")
      (string.eq record-direct.value "generated")
      (string.eq root.label "root")
      (string.eq root-copy.label "changed")
      (string.eq root-deep.label "root")
      (= cell-copy.rank 42))))

(define (main) : i64
  (let
    [source : named.HTTPPacket (named.make-packet)]
    [copy : named.HTTPPacket (named.clone-http-packet (& source))]
    [deep-copy : named.HTTPPacket (clone.deep source)]
    [copy-started-valid : bool (named.packet-ok? (& copy))]
    (set! (array-ref copy.items 0) "changed")
    (set! (deref copy.boxed).rank 99)
    (if (and
      copy-started-valid
      (named.packet-ok? (& source))
      (named.packet-ok? (& deep-copy))
      (generated-and-root-ok?)
      (string.eq (array-ref copy.items 0) "changed"))
      42
      1)))