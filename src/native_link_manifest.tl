;# Pure admission boundary for #7367/#7368, #7099/#7103 and #7266. No filesystem,
;# environment, process, target writer or discovery service is reachable here.
(import native_link_manifest_types as n)
(import native_link_manifest_core as core)
(import native_link_manifest_codec as codec)
(import native_link_manifest_binary as binary)
(import native_link_manifest_render as render)

(defenum NativeSemanticError
  (NativeInvalid core.NativeLinkValidation)
  (NativeCodecFailure codec.NativeCodecError)
  (NativePresentationLimit))

(defenum NativeCanonicalResult
  (NativeCanonicalBytes (__tl_dyn-array u8))
  (NativeCanonicalRejected NativeSemanticError))

(defenum NativeSemanticResult
  (NativeSemanticInput n.NativeLinkSemanticInput)
  (NativeSemanticRejected NativeSemanticError))

(defenum NativeFingerprintResult
  (NativeFingerprint n.ContentIdentity)
  (NativeFingerprintRejected NativeSemanticError))

(defenum NativeRenderResult
  (NativeRendered String)
  (NativeRenderRejected NativeSemanticError))

(define (encode
  [input : (& i n.NativeLinkSemanticInput)]
  [limits : (& l core.NativeLinkLimits)]) : NativeCanonicalResult
  (let
    [validation : core.NativeLinkValidation (core.validate input limits)]
    (when
      (not validation.ok)
      (return (NativeCanonicalRejected (NativeInvalid validation))))
    (match (codec.encode-input-record input (& limits.wire))
      [(codec.NativeBytes data) (NativeCanonicalBytes data)]
      [(codec.NativeEncodeFailed error)
        (NativeCanonicalRejected (NativeCodecFailure error))])))

(define (decode
  [data : (& b (__tl_dyn-array u8))]
  [limits : (& l core.NativeLinkLimits)]) : NativeSemanticResult
  (when
    (not (core.valid-limits? limits))
    (return
      (NativeSemanticRejected (NativeInvalid (core.new-validation limits)))))
  (match (codec.decode-input-record data (& limits.wire))
    [(codec.NativeInputFailed error)
      (NativeSemanticRejected (NativeCodecFailure error))]
    [(codec.NativeInput input)
      (let
        [validation : core.NativeLinkValidation
          (core.validate (& input) limits)]
        (if validation.ok
          (NativeSemanticInput input)
          (NativeSemanticRejected (NativeInvalid validation))))]))

;: This digest identifies the canonical link/profile projection. Cache users
;: must separately admit the observed file/tool closure, including opaque argv.
(define (fingerprint
  [input : (& i n.NativeLinkSemanticInput)]
  [limits : (& l core.NativeLinkLimits)]) : NativeFingerprintResult
  (match (encode input limits)
    [(NativeCanonicalRejected error) (NativeFingerprintRejected error)]
    [(NativeCanonicalBytes bytes)
      (match (codec.digest-bytes bytes)
        [(codec.NativeDigest identity) (NativeFingerprint identity)]
        [(codec.NativeDigestFailed error)
          (NativeFingerprintRejected (NativeCodecFailure error))])]))

(define (render-human
  [input : (& i n.NativeLinkSemanticInput)]
  [options : (& o n.PresentationOptions)]
  [max-bytes : i64]
  [limits : (& l core.NativeLinkLimits)]) : NativeRenderResult
  (when
    (not (core.valid-limits? limits))
    (return (NativeRenderRejected (NativeInvalid (core.new-validation limits)))))
  (when
    (or
      (< max-bytes 0)
      (> max-bytes 33554432)
      (> max-bytes (/ limits.wire.max-retained-bytes 8)))
    (return (NativeRenderRejected (NativePresentationLimit))))
  (match (encode input limits)
    [(NativeCanonicalRejected error) (NativeRenderRejected error)]
    [(NativeCanonicalBytes bytes)
      (match (binary.decode
        (& bytes)
        (binary.SemanticInputDocument)
        (& limits.wire))
        [(binary.DecodeFailed error)
          (NativeRenderRejected (NativeCodecFailure (codec.WireError error)))]
        [(binary.Decoded tree)
          (let
            [decision : core.NativeCapabilityDecision
              (core.classify input (core.AutoBackend) limits)]
            (match (render.render-tree (& tree) options (& decision) max-bytes)
              [(render.NativeText text) (NativeRendered text)]
              [_ (NativeRenderRejected (NativePresentationLimit))]))])]))