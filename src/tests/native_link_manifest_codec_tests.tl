(import native_link_manifest_types as n)
(import native_link_manifest as manifest)
(import native_link_manifest_core as core)
(import native_link_manifest_codec as codec)
(import native_link_manifest_wire as wire)
(import native_link_manifest_binary as binary)
(import tests.native_link_manifest_test_support as support)
(import tests.native_link_manifest_oracle as oracle)
(import stdlib.serialize)
(import (serialize.serialize wire n.NativeLinkSemanticInput) as schema)
(import stdlib.iterator)
(import stdlib.string)
(import stdlib.test)

(include-bin linux-profile "../../tests/fixtures/native-link/linux-profile.in")

(include-bin
  linux-manifest
  "../../tests/fixtures/native-link/linux-manifest.in")

(include-bin linux-input "../../tests/fixtures/native-link/linux-input.in")

(include-bin
  windows-profile
  "../../tests/fixtures/native-link/windows-profile.in")

(include-bin
  windows-manifest
  "../../tests/fixtures/native-link/windows-manifest.in")

(include-bin windows-input "../../tests/fixtures/native-link/windows-input.in")

(define (golden?
  [windows : bool]
  [profile-bytes : (& p (__tl_dyn-array u8))]
  [manifest-bytes : (& m (__tl_dyn-array u8))]
  [input-bytes : (& i (__tl_dyn-array u8))]) : bool
  (let
    [input : n.NativeLinkSemanticInput (support.sample windows)]
    [limits : core.NativeLinkLimits (core.default-limits)]
    (match (codec.encode-profile-record (& input.profile) (& limits.wire))
      [(codec.NativeBytes bytes)
        (when (not (codec.bytes-equal? (& bytes) profile-bytes)) (return false))]
      [_ (return false)])
    (match (codec.encode-manifest-record (& input.manifest) (& limits.wire))
      [(codec.NativeBytes bytes)
        (when
          (not (codec.bytes-equal? (& bytes) manifest-bytes))
          (return false))]
      [_ (return false)])
    (match (manifest.encode (& input) (& limits))
      [(manifest.NativeCanonicalBytes bytes)
        (when (not (codec.bytes-equal? (& bytes) input-bytes)) (return false))]
      [_ (return false)])
    (match (oracle.decode input-bytes)
      [(oracle.OracleValue tree)
        (match (schema.decode tree)
          [(schema.Ok value)
            (match (manifest.encode (& value) (& limits))
              [(manifest.NativeCanonicalBytes bytes)
                (codec.bytes-equal? (& bytes) input-bytes)]
              [_ false])]
          [_ false])]
      [_ false])))

(test
  native-link-independent-linux-golden
  (test.assert-true
    (golden? false (& linux-profile) (& linux-manifest) (& linux-input))
    "native-link-independent-linux-golden"))

(test
  native-link-independent-windows-golden
  (test.assert-true
    (golden? true (& windows-profile) (& windows-manifest) (& windows-input))
    "native-link-independent-windows-golden"))

(test
  native-link-framing-and-truncation
  (test.assert-true
    (let
      [limits : core.NativeLinkLimits (core.default-limits)]
      [ok : bool true]
      (for [i (iterator.range 0 32)]
        (let
          [data : (__tl_dyn-array u8) (__tl_make-array u8 i)]
          (for [j (iterator.range 0 i)]
            (set! (array-ref data j) (array-ref linux-input j)))
          (when
            (match (manifest.decode (& data) (& limits))
              [(manifest.NativeSemanticInput _) true]
              [_ false])
            (set! ok false))
          (when
            (match (oracle.decode (& data))
              [(oracle.OracleValue _) true]
              [_ false])
            (set! ok false))))
      (for [i (iterator.range 0 32)]
        (let
          [data : (__tl_dyn-array u8) (clone linux-input)]
          (set! (array-ref data i) (bit-xor (array-ref data i) (cast 128 : u8)))
          (when
            (match (manifest.decode (& data) (& limits))
              [(manifest.NativeSemanticInput _) true]
              [_ false])
            (set! ok false))
          (when
            (match (oracle.decode (& data))
              [(oracle.OracleValue _) true]
              [_ false])
            (set! ok false))))
      ok)
    "native-link-framing-and-truncation"))

(test
  native-link-semantic-mutations-change-bytes
  (test.assert-true
    (let
      [input : n.NativeLinkSemanticInput (support.sample false)]
      [limits : core.NativeLinkLimits (core.default-limits)]
      [before : codec.NativeBytesResult
        (codec.encode-input-record (& input) (& limits.wire))]
      (match before
        [(codec.NativeBytes bytes)
          (let
            [ok : bool true]
            (for [index (iterator.range 0 7)]
              (let
                [changed : n.NativeLinkSemanticInput (clone input)]
                (match index
                  [0 (set! changed.manifest.artifact-id "different.app")]
                  [1
                    (set!
                      (array-ref changed.manifest.events 0).id
                      "another-event")]
                  [2
                    (set!
                      (array-ref changed.manifest.events 0).provenance
                      (n.CommandLineOrigin (cast 2 : u64)))]
                  [3
                    (set!
                      changed.manifest.reproducibility
                      (n.ExplicitExternalCompatibility))]
                  [4 (set! changed.profile.version (cast 2 : u32))]
                  [5
                    (set! changed.profile.windows.stack-reserve (cast 1 : u64))]
                  [_ (set! changed.profile.debug.deterministic false)])
                (match (codec.encode-input-record (& changed) (& limits.wire))
                  [(codec.NativeBytes after)
                    (when
                      (codec.bytes-equal? (& bytes) (& after))
                      (set! ok false))]
                  [_ (set! ok false)])))
            ok)]
        [_ false]))
    "native-link-semantic-mutations-change-bytes"))

(test
  native-link-declared-set-insertion-order
  (test.assert-true
    (let
      [input : n.NativeLinkSemanticInput (support.sample true)]
      [changed : n.NativeLinkSemanticInput (clone input)]
      [limits : core.NativeLinkLimits (core.default-limits)]
      (for [i (iterator.range 0 17)]
        (let
          [j : i64 (- 33 i)]
          [row : n.CapabilityRow
            (clone (array-ref changed.profile.capabilities i))]
          (set!
            (array-ref changed.profile.capabilities i)
            (clone (array-ref changed.profile.capabilities j)))
          (set! (array-ref changed.profile.capabilities j) row)))
      (for [i (iterator.range 0 6)]
        (let
          [j : i64 (- 11 i)]
          [row : n.SystemImport (clone (array-ref changed.profile.imports i))]
          (set!
            (array-ref changed.profile.imports i)
            (clone (array-ref changed.profile.imports j)))
          (set! (array-ref changed.profile.imports j) row)))
      (match (manifest.encode (& input) (& limits))
        [(manifest.NativeCanonicalBytes a)
          (match (manifest.encode (& changed) (& limits))
            [(manifest.NativeCanonicalBytes b) (codec.bytes-equal? (& a) (& b))]
            [_ false])]
        [_ false]))
    "native-link-declared-set-insertion-order"))

(test
  native-link-presentation-and-operational-values
  (test.assert-true
    (let
      [input : n.NativeLinkSemanticInput (support.sample false)]
      [limits : core.NativeLinkLimits (core.default-limits)]
      [plain : n.PresentationOptions (n.PresentationOptions false)]
      [full : n.PresentationOptions (n.PresentationOptions true)]
      [posix : n.NativeLinkInvocation
        (n.NativeLinkInvocation
          (__tl_make-array n.NativeRootBinding 0)
          "/tmp/out"
          "/usr/bin/ld"
          (cast 1 : u32))]
      [windows : n.NativeLinkInvocation
        (n.NativeLinkInvocation
          (__tl_make-array n.NativeRootBinding 0)
          "C:\\work\\out.exe"
          "C:\\tools\\link.exe"
          (cast 32 : u32))]
      [before : manifest.NativeCanonicalResult
        (manifest.encode (& input) (& limits))]
      (match (manifest.render-human (& input) (& plain) 1048576 (& limits))
        [(manifest.NativeRendered a)
          (match (manifest.render-human (& input) (& full) 1048576 (& limits))
            [(manifest.NativeRendered b)
              (and
                (not (string.eq (& a) (& b)))
                (= posix.worker-count (cast 1 : u32))
                (= windows.worker-count (cast 32 : u32))
                (match before
                  [(manifest.NativeCanonicalBytes bytes)
                    (match (manifest.encode (& input) (& limits))
                      [(manifest.NativeCanonicalBytes after)
                        (codec.bytes-equal? (& bytes) (& after))]
                      [_ false])]
                  [_ false]))]
            [_ false])]
        [_ false]))
    "native-link-presentation-and-operational-values"))

;; Independently counted frame for {"a": null}: 32-byte header, 9-byte root,
;; 4-byte field count, 4-byte key length, one key byte and a 9-byte null.
(test
  native-link-exact-resource-boundaries
  (let
    [fields : (__tl_dyn-array wire.Field) (__tl_make-array wire.Field 1)]
    (set! (array-ref fields 0) (wire.Field "a" (wire.Null)))
    (let
      [tree : wire.Value (wire.Record (box (wire.FieldSeq fields 1)))]
      [encoding : binary.Limits (binary.Limits 59 2 1 1 1 119 8507)]
      [decoding : binary.Limits (binary.Limits 59 2 1 1 1 62 8544)]
      [ok : bool true]
      (match (binary.encode
        (& tree)
        (binary.SemanticInputDocument)
        (& encoding))
        [(binary.Encoded bytes)
          (when
            (not
              (match (binary.decode
                (& bytes)
                (binary.SemanticInputDocument)
                (& decoding))
                [(binary.Decoded _) true]
                [_ false]))
            (set! ok false))
          (for [i (iterator.range 0 7)]
            (let
              [a : binary.Limits (clone encoding)]
              [b : binary.Limits (clone decoding)]
              (match i
                [0
                  (set! a.max-bytes 58)
                  (set! b.max-bytes 58)]
                [1
                  (set! a.max-nodes 1)
                  (set! b.max-nodes 1)]
                [2
                  (set! a.max-depth 0)
                  (set! b.max-depth 0)]
                [3
                  (set! a.max-string-bytes 0)
                  (set! b.max-string-bytes 0)]
                [4
                  (set! a.max-record-fields 0)
                  (set! b.max-record-fields 0)]
                [5
                  (set! a.max-work 118)
                  (set! b.max-work 61)]
                [_
                  (set! a.max-retained-bytes 8506)
                  (set! b.max-retained-bytes 8543)])
              (when
                (match (binary.encode
                  (& tree)
                  (binary.SemanticInputDocument)
                  (& a))
                  [(binary.Encoded _) true]
                  [_ false])
                (set! ok false))
              (when
                (match (binary.decode
                  (& bytes)
                  (binary.SemanticInputDocument)
                  (& b))
                  [(binary.Decoded _) true]
                  [_ false])
                (set! ok false))))]
        [_ (set! ok false)])
      (test.assert-true
        ok
        "all seven exact resource limits pass, each one-below rejects"))))

(test
  native-link-malformed-small-tree-every-truncation
  (let
    [fields : (__tl_dyn-array wire.Field) (__tl_make-array wire.Field 2)]
    [limits : binary.Limits (binary.default-limits)]
    [ok : bool true]
    (set! (array-ref fields 0) (wire.Field "a" (wire.Boolean true)))
    (set! (array-ref fields 1) (wire.Field "b" (wire.Signed -1)))
    (let
      [tree : wire.Value (wire.Record (box (wire.FieldSeq fields 2)))]
      (match (binary.encode (& tree) (binary.SemanticInputDocument) (& limits))
        [(binary.Encoded bytes)
          (for [length (iterator.range 0 (array-length bytes))]
            (let
              [short : (__tl_dyn-array u8) (__tl_make-array u8 length)]
              (for [i (iterator.range 0 length)]
                (set! (array-ref short i) (array-ref bytes i)))
              (when
                (match (binary.decode
                  (& short)
                  (binary.SemanticInputDocument)
                  (& limits))
                  [(binary.Decoded _) true]
                  [_ false])
                (set! ok false))
              (when
                (match (oracle.decode (& short))
                  [(oracle.OracleValue _) true]
                  [_ false])
                (set! ok false))))]
        [_ (set! ok false)]))
    (test.assert-true ok "every incomplete frame is rejected by both decoders")))

(test
  native-link-bounded-differential-byte-mutations
  (let
    [limits : binary.Limits (binary.default-limits)]
    [ok : bool true]
    [seed : u64 (cast 7037 : u64)]
    (for [_i (iterator.range 0 96)]
      (let
        [data : (__tl_dyn-array u8) (clone linux-input)]
        (set!
          seed
          (+
            (* seed (cast 6364136223846793005 : u64))
            (cast 1442695040888963407 : u64)))
        (let
          [at : i64 (cast (% seed (cast (array-length data) : u64)) : i64)]
          (set!
            (array-ref data at)
            (bit-xor
              (array-ref data at)
              (cast
                (shl 1 (cast (bit-and (shr seed 32) (cast 7 : u64)) : i64))
                : u8))))
        (let
          [accepted : bool false]
          [independent : bool false]
          (match (binary.decode
            (& data)
            (binary.SemanticInputDocument)
            (& limits))
            [(binary.Decoded tree)
              (set! accepted true)
              (match (binary.encode
                (& tree)
                (binary.SemanticInputDocument)
                (& limits))
                [(binary.Encoded bytes)
                  (when
                    (not (codec.bytes-equal? (& data) (& bytes)))
                    (set! ok false))]
                [_ (set! ok false)])]
            [_ unit])
          (match (oracle.decode (& data))
            [(oracle.OracleValue tree)
              (set! independent true)
              (match (binary.encode
                (& tree)
                (binary.SemanticInputDocument)
                (& limits))
                [(binary.Encoded bytes)
                  (when
                    (not (codec.bytes-equal? (& data) (& bytes)))
                    (set! ok false))]
                [_ (set! ok false)])]
            [_ unit])
          (when (!= accepted independent) (set! ok false)))))
    (test.assert-true
      ok
      "independent readers agree and every accepted mutation re-encodes exactly")))

(include-bin linux-human "../../tests/fixtures/native-link/linux.expected")

(include-bin windows-human "../../tests/fixtures/native-link/windows.expected")

(define (same-text? [text : (& t str)] [bytes : (& b (__tl_dyn-array u8))]) : bool
  (when (!= (string.string-length text) (array-length bytes)) (return false))
  (for [i (iterator.range 0 (array-length bytes))]
    (when
      (!= (cast (string.string-ref text i) : u8) (array-ref bytes i))
      (return false)))
  true)

(test
  native-link-independent-human-goldens
  (let
    [limits : core.NativeLinkLimits (core.default-limits)]
    [options : n.PresentationOptions (n.PresentationOptions false)]
    (for [target (iterator.range 0 2)]
      (let
        [input : n.NativeLinkSemanticInput (support.sample (= target 1))]
        (match (manifest.render-human (& input) (& options) 1048576 (& limits))
          [(manifest.NativeRendered text)
            (test.assert-true
              (if (= target 0)
                (same-text? (& text) (& linux-human))
                (same-text? (& text) (& windows-human)))
              "bounded stable rendering includes ordered provenance, controls and auto capability decision")]
          [_ (test.assert-true false "human golden must render")])
        (test.assert-true
          (match (manifest.render-human (& input) (& options) 1 (& limits))
            [(manifest.NativeRenderRejected (manifest.NativePresentationLimit))
              true]
            [_ false])
          "header and tree share one byte limit")))))

(test
  native-link-invalid-semantic-limits-reject-before-decode
  (let
    [limits : core.NativeLinkLimits (core.default-limits)]
    [input : n.NativeLinkSemanticInput (support.sample false)]
    [options : n.PresentationOptions (n.PresentationOptions false)]
    (set! limits.max-events -1)
    (match (manifest.decode (& linux-input) (& limits))
      [(manifest.NativeSemanticRejected (manifest.NativeInvalid validation))
        (test.assert-true
          (and
            (not validation.ok)
            (not validation.complete)
            (support.has-reason? (& validation) (core.InvalidLimit)))
          "invalid semantic limit rejects at the public decode boundary")]
      [_ (test.assert-true false "invalid semantic decode limit")])
    (match (manifest.render-human (& input) (& options) 1024 (& limits))
      [(manifest.NativeRenderRejected (manifest.NativeInvalid validation))
        (test.assert-true
          (support.has-reason? (& validation) (core.InvalidLimit))
          "invalid limits precede rendering")]
      [_ (test.assert-true false "invalid semantic render limit")])))