(import stdlib.byte_buf)
(import stdlib.crypto_sha256 as sha)
(import stdlib.net.tls_wire as wire)
(import stdlib.net.tls_transcript as transcript)
(import stdlib.test)

(define (hex-bytes [hex : String]) : byte_buf.ByteBuf
  (let
    [out : byte_buf.ByteBuf
      (byte_buf.with-capacity (/ (string-length (& hex)) 2))]
    [view : (& hex bytes) (byte_buf.str-as-bytes (& hex))]
    [index : i64 0]
    (while (< index (byte_buf.bytes-length view))
      (set!
        out
        (byte_buf.push
          out
          (cast
            (+
              (* 16 (wire.hex-digit (wire.read-be view index 1)))
              (wire.hex-digit (wire.read-be view (+ index 1) 1)))
            : u8)))
      (set! index (+ index 2)))
    out))

(define (new-transcript) : transcript.TlsTranscript
  (match (transcript.new (transcript.default-limits))
    [(TlsTranscriptNewOk state) state]
    [(TlsTranscriptNewErr _)
      (test.assert-true false "valid transcript limits")
      (init : transcript.TlsTranscript)]))

(define (require-ok [result : transcript.TlsTranscriptStatus]) : unit
  (match result
    [(TlsTranscriptOk) unit]
    [(TlsTranscriptErr _)
      (test.assert-true false "transcript operation succeeds")]))

(define (snapshot [state : (& state transcript.TlsTranscript)]) : sha.Sha256Digest
  (match (transcript.snapshot state)
    [(TlsTranscriptDigestOk digest) digest]
    [(TlsTranscriptDigestErr _)
      (test.assert-true false "snapshot succeeds")
      (sha.Sha256Digest (make-array u8 32))]))

(define (test-empty) : unit
  (let
    [state : transcript.TlsTranscript (new-transcript)]
    [before : sha.Sha256Digest (snapshot (& state))]
    [reader : wire.TlsHandshakeReader
      (wire.handshake-reader-new (wire.default-limits))]
    [frame : byte_buf.ByteBuf (hex-bytes "01000000")]
    (test.assert-owned-string-eq
      (sha.to-hex (& before))
      "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
      "empty transcript")
    (match (wire.handshake-reader-feed!
      (&mut reader)
      (byte_buf.as-bytes (& frame)))
      [(TlsWireOk) unit]
      [(TlsWireErr _) (test.assert-true false "feed frame")])
    (match (wire.handshake-reader-next! (&mut reader))
      [(TlsHandshakeReady _ _) unit]
      [_ (test.assert-true false "complete frame")])
    (require-ok (transcript.absorb! (&mut state) (& reader)))
    (let
      [after : sha.Sha256Digest (snapshot (& state))]
      (test.assert-false
        (sha.digest-eq? (& before) (& after))
        "include exact frame header"))
    unit))

(define (require-wire [result : wire.TlsWireCheck]) : unit
  (match result
    [(TlsWireOk) unit]
    [(TlsWireErr _) (test.assert-true false "valid wire fragment")]))

(define (hold [frame : (& frame bytes)]) : wire.TlsHandshakeReader
  (let
    [reader : wire.TlsHandshakeReader
      (wire.handshake-reader-new (wire.default-limits))]
    (require-wire (wire.handshake-reader-feed! (&mut reader) frame))
    (match (wire.handshake-reader-next! (&mut reader))
      [(TlsHandshakeReady _ _) unit]
      [_ (test.assert-true false "held complete frame")])
    reader))

(define (absorb-frame
  [state : (&mut state transcript.TlsTranscript)]
  [frame : (& frame bytes)]) : unit
  (let
    [reader : wire.TlsHandshakeReader (hold frame)]
    (require-ok (transcript.absorb! state (& reader)))))

(define (record-message [hex : String]) : byte_buf.ByteBuf
  (let
    [record : byte_buf.ByteBuf (hex-bytes hex)]
    (byte_buf.from-bytes-range
      (byte_buf.as-bytes (& record))
      5
      (- (byte_buf.len (& record)) 5))))

;: These pins are independent SHA-256 calculations over RFC 8448 sections 3
;: and 5, not expectations computed with the implementation under test.
;: The ServerHello, server-Finished and client-Finished values also occur
;: verbatim in the RFC's key-derivation inputs. Every message boundary is pinned.
(define (boundary-pin [retry : bool] [index : i64]) : String
  (if retry
    (match index
      [0 "de7420cc7426d2f6b221edcc9c4bdc9bb0ab048b3ddd2411da7e3a01baea6c7e"]
      [1 "74eec04d09c926e86c0647c37ba4dc18d277eec3337e4608c4d829b77e2fd2b3"]
      [2 "9894cc5d431430bcccd9a33fb5a9f90435ac381114d847732bd8aed5de105048"]
      [3 "8aa8e828ec2f8a884fec95a3139de01c15a3daa7ff5bfc3f4bfcc21b438d7bf8"]
      [4 "115178780d62f39e6f701e21cec779e7661539a351857615604e678ee523a59f"]
      [5 "a303fd397938c2b5c3fb0dfb33bd6c46d890331e3be5ed3b8ea2be5218c3db1a"]
      [6 "5614a09dfce10c45e7a58394bd6dabbefaa1d838e7f4b74966fada310ef2e77b"]
      [7 "50f63cbf36b0dd049e7a0ba27d6455745ea2aaac54bb167f9950b2b7ce9509da"]
      [_ "0e8b349158b855fdcd0c11dbbc4e83e43caa6e483c6c65df53151888e50165f4"])
    (match index
      [0 "4db255f30da09a407c841720be831a06a5aa9b3662a5f44267d37706b73c2b8c"]
      [1 "860c06edc07858ee8e78f0e7428c58edd6b43f2ca3e6e95f02ed063cf0e1cad8"]
      [2 "28477e0227567481e5ee83016a3e447840200586cf01526781898a964a45caf9"]
      [3 "764d6632b3c35c3f3205e3499ac3edbaabb88295fba751461d3678e2e5ea0687"]
      [4 "edb7725fa7a3473b031ec8ef65a2485493900138a2b91291407d7951a06110ed"]
      [5 "9608102a0f1ccc6db6250b7b7e417b1a000eaada3daae4777a7686c9ff83df13"]
      [_ "209145a96ee8e2a122ff810047cc952684658d6049e86429426db87c54ad143d"])))

(define (check-tag
  [state : (& state transcript.TlsTranscript)]
  [boundary : transcript.TlsTranscriptBoundary]) : unit
  (let
    [before : transcript.TlsTranscript (copy-state state)]
    [expected : sha.Sha256Digest (snapshot state)]
    (match (transcript.snapshot-boundary state boundary)
      [(TlsTranscriptHashOk value)
        (match (transcript.boundary-digest value boundary)
          [(TlsTranscriptDigestOk actual)
            (test.assert-true
              (sha.digest-eq? (& actual) (& expected))
              "tagged RFC boundary")]
          [_ (test.assert-true false "tagged hash preserves expected tag")])]
      [_ (test.assert-true false "local boundary kind accepted")])
    (assert-state state (& before))))

(define (check-trace-tag
  [state : (& state transcript.TlsTranscript)]
  [retry : bool]
  [index : i64]) : unit
  (cond
    [(or (= index 0) (and retry (= index 2)))
      (check-tag state (transcript.ThroughClientHello))]
    [(=
        index
        (if retry
          3
          1))
      (check-tag state (transcript.ThroughServerHello))]
    [(=
        index
        (if retry
          5
          3))
      (check-tag state (transcript.BeforeCertificateVerify))]
    [(=
        index
        (if retry
          6
          4))
      (check-tag state (transcript.BeforeServerFinished))]
    [(=
      index
      (if retry
        7
        5))
      (check-tag state (transcript.ThroughServerFinished))
      (check-tag state (transcript.BeforeClientFinished))]
    [(=
        index
        (if retry
          8
          6))
      (check-tag state (transcript.ThroughClientFinished))]
    [else unit]))

(define (trace-bytes [retry : bool]) : byte_buf.ByteBuf
  (let
    [ch : byte_buf.ByteBuf
      (record-message
        (if retry
          (s5-ch1-record)
          (s3-ch-record)))]
    [sh : byte_buf.ByteBuf
      (if retry
        (hex-bytes (s5-sh))
        (record-message (s3-sh-record)))]
    [flight : byte_buf.ByteBuf
      (hex-bytes
        (if retry
          (s5-server-flight)
          (s3-server-flight)))]
    [finished : byte_buf.ByteBuf
      (hex-bytes
        (if retry
          (s5-client-finished)
          (s3-client-finished)))]
    [out : byte_buf.ByteBuf ch]
    (when
      retry
      (let
        [hrr : byte_buf.ByteBuf (hex-bytes (s5-hrr))]
        [ch2 : byte_buf.ByteBuf (record-message (s5-ch2-record))]
        (set! out (byte_buf.append-bytes out (byte_buf.as-bytes (& hrr))))
        (set! out (byte_buf.append-bytes out (byte_buf.as-bytes (& ch2))))))
    (set! out (byte_buf.append-bytes out (byte_buf.as-bytes (& sh))))
    (set! out (byte_buf.append-bytes out (byte_buf.as-bytes (& flight))))
    (byte_buf.append-bytes out (byte_buf.as-bytes (& finished)))))

;: Verify all boundaries under one coalesced fragment, every two-fragment
;: split, and byte-at-a-time feeds. Frame views are released before snapshots
;: are read, proving that no borrow is retained by the transcript.
(define (check-trace
  [input : (& input bytes)]
  [retry : bool]
  [split : i64]
  [chunk : i64]) : unit
  (let
    [state : transcript.TlsTranscript (new-transcript)]
    [reader : wire.TlsHandshakeReader
      (wire.handshake-reader-new (wire.default-limits))]
    [cursor : i64 0]
    [index : i64 0]
    [total : i64 (byte_buf.bytes-length input)]
    (while (< cursor total)
      (let
        [take : i64
          (if (= cursor 0)
            split
            chunk)]
        (when (> take (- total cursor)) (set! take (- total cursor)))
        (require-wire
          (wire.handshake-reader-feed!
            (&mut reader)
            (byte_buf.bytes-slice-view input cursor take)))
        (set! cursor (+ cursor take))
        (let
          [done : bool false]
          (while (not done)
            (match (wire.handshake-reader-next! (&mut reader))
              [(TlsHandshakeNeedMore) (set! done true)]
              [(TlsHandshakeFailed _)
                (test.assert-true false "trace wire parse")
                (set! done true)]
              [(TlsHandshakeReady _ _)
                (require-ok
                  (if (and retry (= index 1))
                    (transcript.hello-retry! (&mut state) (& reader))
                    (transcript.absorb! (&mut state) (& reader))))
                (let
                  [digest : sha.Sha256Digest (snapshot (& state))]
                  [again : sha.Sha256Digest (snapshot (& state))]
                  (test.assert-true
                    (sha.digest-eq? (& digest) (& again))
                    "repeated snapshot"))
                (let
                  [digest : sha.Sha256Digest (snapshot (& state))]
                  (test.assert-owned-string-eq
                    (sha.to-hex (& digest))
                    (boundary-pin retry index)
                    "RFC 8448 boundary"))
                (check-trace-tag (& state) retry index)
                (set! index (+ index 1))])))))
    (test.assert-i64-eq
      index
      (if retry
        9
        7)
      "all trace messages")
    (let
      [digest : sha.Sha256Digest (snapshot (& state))]
      (match (transcript.finalize! (&mut state))
        [(TlsTranscriptDigestOk final)
          (test.assert-true
            (sha.digest-eq? (& digest) (& final))
            "final digest equals snapshot")]
        [_ (test.assert-true false "finalization succeeds")]))))

(define (test-traces) : unit
  (let
    [retry-index : i64 0]
    (while (< retry-index 2)
      (let
        [retry : bool (= retry-index 1)]
        [input : byte_buf.ByteBuf (trace-bytes retry)]
        [length : i64 (byte_buf.len (& input))]
        [split : i64 1]
        (while (<= split length)
          (with-arena
            scratch
            (check-trace (byte_buf.as-bytes (& input)) retry split length))
          (set! split (+ split 1)))
        (with-arena
          scratch
          (check-trace (byte_buf.as-bytes (& input)) retry 1 1)))
      (set! retry-index (+ retry-index 1)))))

(define (copy-state [state : (& state transcript.TlsTranscript)]) : transcript.TlsTranscript
  (transcript.TlsTranscript
    (sha.Sha256State
      state.hash.words
      state.hash.block
      state.hash.block-length
      state.hash.byte-length
      state.hash.finalized)
    (transcript.TlsTranscriptLimits
      state.limits.max-frame-body
      state.limits.max-input)
    state.input-length
    (clone state.retry)
    (clone state.lifecycle)
    state.last-kind
    state.last-offset
    state.last-hello-retry))

;: Compare every state field, not only its digest, after rejected operations.
(define (assert-state
  [state : (& state transcript.TlsTranscript)]
  [before : (& before transcript.TlsTranscript)]) : unit
  (test.assert-true
    (= state.input-length before.input-length)
    "unchanged cumulative length")
  (test.assert-true (= state.retry before.retry) "unchanged retry state")
  (test.assert-true (= state.lifecycle before.lifecycle) "unchanged lifecycle")
  (test.assert-i64-eq state.last-kind before.last-kind "unchanged last kind")
  (test.assert-i64-eq
    state.last-offset
    before.last-offset
    "unchanged last offset")
  (test.assert-true
    (= state.last-hello-retry before.last-hello-retry)
    "unchanged HRR kind marker")
  (test.assert-true
    (= state.hash.byte-length before.hash.byte-length)
    "unchanged SHA length")
  (test.assert-true
    (= state.hash.finalized before.hash.finalized)
    "unchanged SHA lifecycle")
  (test.assert-i64-eq
    state.hash.block-length
    before.hash.block-length
    "unchanged SHA cursor")
  (let
    [index : i64 0]
    (while (< index 64)
      (test.assert-true
        (=
          (array-ref state.hash.block index)
          (array-ref before.hash.block index))
        "unchanged SHA block")
      (when
        (< index 8)
        (test.assert-true
          (=
            (array-ref state.hash.words index)
            (array-ref before.hash.words index))
          "unchanged SHA words"))
      (set! index (+ index 1)))))

(define (require-error [result : transcript.TlsTranscriptStatus]) : transcript.TlsTranscriptError
  (match result
    [(TlsTranscriptErr error) error]
    [_
      (test.assert-true false "expected typed rejection")
      (transcript.TlsTranscriptInvalidState)]))

(define (test-retry-errors) : unit
  (let
    [ch : byte_buf.ByteBuf (record-message (s5-ch1-record))]
    [hrr : byte_buf.ByteBuf (hex-bytes (s5-hrr))]
    [other : byte_buf.ByteBuf (hex-bytes "08000000")]
    [reader : wire.TlsHandshakeReader (hold (byte_buf.as-bytes (& hrr)))]
    [state : transcript.TlsTranscript (new-transcript)]
    [empty : transcript.TlsTranscript (copy-state (& state))]
    (match (require-error (transcript.hello-retry! (&mut state) (& reader)))
      [(TlsTranscriptRetryUnavailable 0) unit]
      [_ (test.assert-true false "retry before ClientHello")])
    (assert-state (& state) (& empty))
    (absorb-frame (&mut state) (byte_buf.as-bytes (& ch)))
    (let
      [before : transcript.TlsTranscript (copy-state (& state))]
      (match (require-error (transcript.absorb! (&mut state) (& reader)))
        [(TlsTranscriptFrameKind 0 2) unit]
        [_ (test.assert-true false "HRR requires replacement")])
      (assert-state (& state) (& before))
      (let
        [wrong : wire.TlsHandshakeReader (hold (byte_buf.as-bytes (& ch)))]
        (match (require-error (transcript.hello-retry! (&mut state) (& wrong)))
          [(TlsTranscriptFrameKind 0 1) unit]
          [_ (test.assert-true false "retry requires HRR kind")]))
      (assert-state (& state) (& before)))
    (require-ok (transcript.hello-retry! (&mut state) (& reader)))
    (match (transcript.snapshot-boundary
      (& state)
      (transcript.ThroughServerHello))
      [(TlsTranscriptHashErr (TlsTranscriptBoundaryMismatch 0 2 _)) unit]
      [_
        (test.assert-true
          false
          "HRR is not the ServerHello traffic-key boundary")])
    (let
      [before : transcript.TlsTranscript (copy-state (& state))]
      (match (require-error (transcript.hello-retry! (&mut state) (& reader)))
        [(TlsTranscriptRetryUnavailable 0) unit]
        [_ (test.assert-true false "single replacement only")])
      (assert-state (& state) (& before)))
    (let
      [late : transcript.TlsTranscript (new-transcript)]
      (absorb-frame (&mut late) (byte_buf.as-bytes (& ch)))
      (absorb-frame (&mut late) (byte_buf.as-bytes (& other)))
      (let
        [before : transcript.TlsTranscript (copy-state (& late))]
        (match (require-error (transcript.hello-retry! (&mut late) (& reader)))
          [(TlsTranscriptRetryUnavailable 0) unit]
          [_ (test.assert-true false "later input retires retry eligibility")])
        (assert-state (& late) (& before))))))

(define (test-limits-and-lifecycle) : unit
  (let
    [frame : byte_buf.ByteBuf (hex-bytes "0100000161")]
    [reader : wire.TlsHandshakeReader (hold (byte_buf.as-bytes (& frame)))]
    [state : transcript.TlsTranscript (new-transcript)]
    (set! state.limits.max-frame-body 0)
    (set! reader.base 91)
    (match (require-error (transcript.absorb! (&mut state) (& reader)))
      [(TlsTranscriptFrameTooLarge 92 1 0) unit]
      [_ (test.assert-true false "frame budget offset")])
    (test.assert-true
      (= state.input-length (cast 0 : u64))
      "frame refusal is atomic")
    (set! state.limits.max-frame-body 1)
    (set! state.limits.max-input (cast 4 : u64))
    (match (require-error (transcript.absorb! (&mut state) (& reader)))
      [(TlsTranscriptInputTooLong 91 _ _ _) unit]
      [_ (test.assert-true false "cumulative budget")])
    (set! state.limits.max-input (cast 5 : u64))
    (require-ok (transcript.absorb! (&mut state) (& reader)))
    (let
      [before : transcript.TlsTranscript (copy-state (& state))]
      [digest : sha.Sha256Digest (snapshot (& state))]
      (assert-state (& state) (& before))
      (set!
        (array-ref digest.octets 0)
        (bit-xor (sha.digest-byte (& digest) 0) (cast 1 : u8)))
      (assert-state (& state) (& before)))
    (match (transcript.finalize! (&mut state))
      [(TlsTranscriptDigestOk _) unit]
      [_ (test.assert-true false "finalize live")])
    (let
      [before : transcript.TlsTranscript (copy-state (& state))]
      (match (require-error (transcript.absorb! (&mut state) (& reader)))
        [(TlsTranscriptNotLive (TlsTranscriptFinalized)) unit]
        [_ (test.assert-true false "finalized absorption")])
      (match (transcript.finalize! (&mut state))
        [(TlsTranscriptDigestErr
            (TlsTranscriptNotLive (TlsTranscriptFinalized)))
          unit]
        [_ (test.assert-true false "double finalize")])
      (assert-state (& state) (& before)))
    (transcript.close! (&mut state))
    (transcript.close! (&mut state))
    (match (transcript.snapshot (& state))
      [(TlsTranscriptDigestErr (TlsTranscriptNotLive (TlsTranscriptClosed)))
        unit]
      [_ (test.assert-true false "closed snapshot")])
    (match (require-error (transcript.hello-retry! (&mut state) (& reader)))
      [(TlsTranscriptNotLive (TlsTranscriptClosed)) unit]
      [_ (test.assert-true false "closed retry")]))
  (let
    [state : transcript.TlsTranscript (new-transcript)]
    [frame : byte_buf.ByteBuf (hex-bytes "08000000")]
    [reader : wire.TlsHandshakeReader (hold (byte_buf.as-bytes (& frame)))]
    (set! state.limits.max-input (sha.max-byte-length))
    (set! state.input-length (- (sha.max-byte-length) (cast 1 : u64)))
    (set! state.hash.byte-length state.input-length)
    (set! state.hash.block-length 62)
    (let
      [before : transcript.TlsTranscript (copy-state (& state))]
      (match (require-error (transcript.absorb! (&mut state) (& reader)))
        [(TlsTranscriptShaError 0 (Sha256MessageTooLong current additional))
          (test.assert-true
            (= current before.hash.byte-length)
            "SHA count preserved")
          (test.assert-true
            (= additional (cast 4 : u64))
            "SHA addition preserved")]
        [_ (test.assert-true false "underlying SHA overflow propagates")])
      (assert-state (& state) (& before))))
  (match (transcript.new (transcript.TlsTranscriptLimits -1 (cast 0 : u64)))
    [(TlsTranscriptNewErr (TlsTranscriptInvalidLimits)) unit]
    [_ (test.assert-true false "negative body budget")]))

;: Every raw type/body mutation is hashed exactly. Every length mutation either
;: leaves an incomplete reader, is rejected at the wire limit, or changes the
;: exact first frame. No failure is allowed to publish partial transcript state.
(define (test-mutations) : unit
  (let
    [original : byte_buf.ByteBuf (hex-bytes "01000008000300ff0a0d8055")]
    [baseline : transcript.TlsTranscript (new-transcript)]
    (absorb-frame (&mut baseline) (byte_buf.as-bytes (& original)))
    (let
      [expected : sha.Sha256Digest (snapshot (& baseline))]
      [iteration : i64 0]
      [seed : u32 0x7719cafe]
      (while (< iteration 524)
        (with-arena
          scratch
          (let
            [mutated : byte_buf.ByteBuf
              (byte_buf.from-bytes (byte_buf.as-bytes (& original)))]
            [state : transcript.TlsTranscript (new-transcript)]
            [before : transcript.TlsTranscript (copy-state (& state))]
            [reader : wire.TlsHandshakeReader
              (wire.handshake-reader-new (clone (wire.default-limits)))]
            [position : i64
              (if (< iteration 12)
                iteration
                (cast (% seed (cast 12 : u32)) : i64))]
            (set!
              seed
              (+ (* seed (cast 1664525 : u32)) (cast 1013904223 : u32)))
            (set!
              (array-ref mutated.slots position)
              (bit-xor
                (byte_buf.ref (& mutated) position)
                (cast (+ 1 (% seed (cast 255 : u32))) : u8)))
            (match (wire.handshake-reader-feed!
              (&mut reader)
              (byte_buf.as-bytes (& mutated)))
              [(TlsWireErr _) unit]
              [(TlsWireOk)
                (match (wire.handshake-reader-next! (&mut reader))
                  [(TlsHandshakeReady _ _)
                    (match (transcript.absorb! (&mut state) (& reader))
                      [(TlsTranscriptOk)
                        (let
                          [actual : sha.Sha256Digest (snapshot (& state))]
                          (test.assert-false
                            (sha.digest-eq? (& actual) (& expected))
                            "mutated exact encoding changes hash"))]
                      [(TlsTranscriptErr _) (assert-state (& state) (& before))])]
                  [_
                    (match (transcript.absorb! (&mut state) (& reader))
                      [(TlsTranscriptErr (TlsTranscriptNoFrame _)) unit]
                      [_
                        (test.assert-true
                          false
                          "incomplete frame cannot enter transcript")])
                    (assert-state (& state) (& before))])])))
        (set! iteration (+ iteration 1))))))

(define (main) : i64
  (test-empty)
  (test-traces)
  (test-retry-errors)
  (test-limits-and-lifecycle)
  (test-mutations)
  (test-boundaries)
  (test-refusals)
  42)

;: Resource refusal on HRR leaves ClientHello1 eligible, and the exact work
;: limit succeeds. Also exercise unready, synthetic and corrupted held inputs.
(define (test-refusals) : unit
  (let
    [ch : byte_buf.ByteBuf (record-message (s5-ch1-record))]
    [hrr : byte_buf.ByteBuf (hex-bytes (s5-hrr))]
    [reader : wire.TlsHandshakeReader (hold (byte_buf.as-bytes (& hrr)))]
    [state : transcript.TlsTranscript (new-transcript)]
    (absorb-frame (&mut state) (byte_buf.as-bytes (& ch)))
    (set! state.limits.max-input (cast 391 : u64))
    (let
      [before : transcript.TlsTranscript (copy-state (& state))]
      (match (require-error (transcript.hello-retry! (&mut state) (& reader)))
        [(TlsTranscriptInputTooLong 0 current additional maximum)
          (test.assert-true
            (= current (cast 180 : u64))
            "CH1 counts toward work")
          (test.assert-true
            (= additional (cast 212 : u64))
            "synthetic and HRR count toward work")
          (test.assert-true (= maximum (cast 391 : u64)) "configured HRR limit")]
        [_ (test.assert-true false "HRR cumulative bound")])
      (assert-state (& state) (& before)))
    (set! state.limits.max-input (cast 392 : u64))
    (require-ok (transcript.hello-retry! (&mut state) (& reader)))
    (test.assert-true
      (= state.input-length (cast 392 : u64))
      "exact cumulative work")
    (test.assert-true
      (= state.hash.byte-length (cast 212 : u64))
      "replacement hash stream length"))
  (let
    [state : transcript.TlsTranscript (new-transcript)]
    [empty : wire.TlsHandshakeReader
      (wire.handshake-reader-new (wire.default-limits))]
    [synthetic : byte_buf.ByteBuf (hex-bytes "fe000000")]
    [reader : wire.TlsHandshakeReader (hold (byte_buf.as-bytes (& synthetic)))]
    [before : transcript.TlsTranscript (copy-state (& state))]
    (match (require-error (transcript.absorb! (&mut state) (& empty)))
      [(TlsTranscriptNoFrame 0) unit]
      [_ (test.assert-true false "zero additional frames")])
    (match (require-error (transcript.absorb! (&mut state) (& reader)))
      [(TlsTranscriptFrameKind 0 254) unit]
      [_ (test.assert-true false "external message_hash rejected")])
    (set! reader.held 3)
    (match (require-error (transcript.absorb! (&mut state) (& reader)))
      [(TlsTranscriptInvalidFrame 0) unit]
      [_ (test.assert-true false "partial held header refused")])
    (set! reader.failed true)
    (set!
      reader.error
      (wire.TlsWireError
        wire.error-message-too-large
        17
        wire.alert-decode-error))
    (match (require-error (transcript.absorb! (&mut state) (& reader)))
      [(TlsTranscriptWireError error)
        (test.assert-i64-eq error.offset 17 "wire failure offset preserved")]
      [_ (test.assert-true false "failed reader cannot contribute")])
    (assert-state (& state) (& before))))

(test tls-transcript-rfc8448 (test-traces))

(test
  tls-transcript-state-and-mutations
  (test-empty)
  (test-retry-errors)
  (test-limits-and-lifecycle)
  (test-mutations)
  (test-boundaries)
  (test-refusals))

;: Boundary creation validates only the last kind; no full ordering is inferred.
(define (test-boundaries) : unit
  (let
    [state : transcript.TlsTranscript (new-transcript)]
    [ch : byte_buf.ByteBuf (hex-bytes "01000000")]
    [sh : byte_buf.ByteBuf (hex-bytes "02000000")]
    [before : transcript.TlsTranscript (copy-state (& state))]
    (match (transcript.snapshot-boundary
      (& state)
      (transcript.ThroughServerHello))
      [(TlsTranscriptHashErr (TlsTranscriptBoundaryMismatch _ _ _)) unit]
      [_ (test.assert-true false "empty cannot be labelled ServerHello")])
    (assert-state (& state) (& before))
    (absorb-frame (&mut state) (byte_buf.as-bytes (& ch)))
    (match (transcript.snapshot-boundary
      (& state)
      (transcript.ThroughClientHello))
      [(TlsTranscriptHashOk value)
        (let
          [expected : sha.Sha256Digest (snapshot (& state))]
          (match (transcript.boundary-digest
            value
            (transcript.ThroughClientHello))
            [(TlsTranscriptDigestOk actual)
              (test.assert-true
                (sha.digest-eq? (& expected) (& actual))
                "tagged digest exact")]
            [_ (test.assert-true false "matching boundary tag")])
          (match (transcript.boundary-digest
            value
            (transcript.ThroughServerHello))
            [(TlsTranscriptDigestErr (TlsTranscriptWrongBoundary _ _)) unit]
            [_ (test.assert-true false "consumer must check tag")])
          (absorb-frame (&mut state) (byte_buf.as-bytes (& sh)))
          (match (transcript.boundary-digest
            value
            (transcript.ThroughClientHello))
            [(TlsTranscriptDigestOk actual)
              (test.assert-true
                (sha.digest-eq? (& expected) (& actual))
                "tagged snapshot owns independent digest")]
            [_ (test.assert-true false "tagged snapshot survives continuation")]))]
      [_ (test.assert-true false "ClientHello boundary accepted")])
    (match (transcript.snapshot-boundary
      (& state)
      (transcript.BeforeCertificateVerify))
      [(TlsTranscriptHashErr (TlsTranscriptBoundaryMismatch _ 2 _)) unit]
      [_ (test.assert-true false "wrong immediate predecessor rejected")]))
  (match (transcript.boundary-digest
    (ptr-null : (Ptr transcript.TlsTranscriptHash))
    (transcript.ThroughServerHello))
    [(TlsTranscriptDigestErr (TlsTranscriptInvalidHash)) unit]
    [_ (test.assert-true false "null tagged hash rejected")]))

(define (s3-ch-record) : String
  "16030100c4010000c00303cb34ecb1e78163ba1c38c6dacb196a6dffa21a8d9912ec18a2ef6283024dece7000006130113031302010000910000000b0009000006736572766572ff01000100000a00140012001d0017001800190100010101020103010400230000003300260024001d002099381de560e4bd43d23d8e435a7dbafeb3c06e51c13cae4d5413691e529aaf2c002b0003020304000d0020001e040305030603020308040805080604010501060102010402050206020202002d00020101001c00024001")

(define (s3-sh-record) : String
  "160303005a020000560303a6af06a4121860dc5e6e60249cd34c95930c8ac5cb1434dac155772ed3e2692800130100002e00330024001d0020c9828876112095fe66762bdbf7c672e156d6cc253b833df1dd69b1b04e751f0f002b00020304")

(define (s3-server-flight) : String
  "080000240022000a00140012001d00170018001901000101010201030104001c00024001000000000b0001b9000001b50001b0308201ac30820115a003020102020102300d06092a864886f70d01010b0500300e310c300a06035504031303727361301e170d3136303733303031323335395a170d3236303733303031323335395a300e310c300a0603550403130372736130819f300d06092a864886f70d010101050003818d0030818902818100b4bb498f8279303d980836399b36c6988c0c68de55e1bdb826d3901a2461eafd2de49a91d015abbc9a95137ace6c1af19eaa6af98c7ced43120998e187a80ee0ccb0524b1b018c3e0b63264d449a6d38e22a5fda430846748030530ef0461c8ca9d9efbfae8ea6d1d03e2bd193eff0ab9a8002c47428a6d35a8d88d79f7f1e3f0203010001a31a301830090603551d1304023000300b0603551d0f0404030205a0300d06092a864886f70d01010b05000381810085aad2a0e5b9276b908c65f73a7267170618a54c5f8a7b337d2df7a594365417f2eae8f8a58c8f8172f9319cf36b7fd6c55b80f21a03015156726096fd335e5e67f2dbf102702e608ccae6bec1fc63a42a99be5c3eb7107c3c54e9b9eb2bd5203b1c3b84e0a8b2f759409ba3eac9d91d402dcc0cc8f8961229ac9187b42b4de100000f000084080400805a747c5d88fa9bd2e55ab085a61015b7211f824cd484145ab3ff52f1fda8477b0b7abc90db78e2d33a5c141a078653fa6bef780c5ea248eeaaa785c4f394cab6d30bbe8d4859ee511f602957b15411ac027671459e46445c9ea58c181e818e95b8c3fb0bf3278409d3be152a3da5043e063dda65cdf5aea20d53dfacd42f74f3140000209b9b141d906337fbd2cbdce71df4deda4ab42c309572cb7fffee5454b78f0718")

(define (s3-client-finished) : String
  "14000020a8ec436d677634ae525ac1fcebe11a039ec17694fac6e98527b642f2edd5ce61")

(define (s5-ch1-record) : String
  "16030100b4010000b00303b0b1c5a5aa37c5919f2ed1d5c6fff7fcb7849716945a2b8cee9258a346677b6f000006130113031302010000810000000b0009000006736572766572ff01000100000a00080006001d00170018003300260024001d0020e8e8e3f3b93a25ed97a14a7dcacb8a272c6288e585c6484d05262fcad062ad1f002b0003020304000d0020001e040305030603020308040805080604010501060102010402050206020202002d00020101001c00024001")

(define (s5-hrr) : String
  "020000ac0303cf21ad74e59a6111be1d8c021e65b891c2a211167abb8c5e079e09e2c8a8339c001301000084003300020017002c0074007271dcd04bb88bc3189119398a00000000eefafc76c146b823b096f8aacad365dd0030953f4edf625636e5f21bb2e23fcc654b1b5b40318d10d137abcbb87574e36e8a1f025f7dfa5d6e50781b5eda4aa15b0c8be778257d16aa3030e9e7841dd9e4c0342267e8ca0caf571fb2b7cff0f934b0002b00020304")

(define (s5-ch2-record) : String
  "1603030200010001fc0303b0b1c5a5aa37c5919f2ed1d5c6fff7fcb7849716945a2b8cee9258a346677b6f000006130113031302010001cd0000000b0009000006736572766572ff01000100000a00080006001d001700180033004700450017004104a6da7392ec591e17abfd535964b99894d13befb221b3def2ebe3830eac8f0151812677c4d6d2237e85cf01d6910cfb83954e76ba7352830534159897e8065780002b0003020304000d0020001e040305030603020308040805080604010501060102010402050206020202002c0074007271dcd04bb88bc3189119398a00000000eefafc76c146b823b096f8aacad365dd0030953f4edf625636e5f21bb2e23fcc654b1b5b40318d10d137abcbb87574e36e8a1f025f7dfa5d6e50781b5eda4aa15b0c8be778257d16aa3030e9e7841dd9e4c0342267e8ca0caf571fb2b7cff0f934b0002d00020101001c00024001001500af00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000")

(define (s5-sh) : String
  "020000770303bb341d847fd789c47c387172dc0c9bf147fccacb5043d86ca4c598d3ff571b9800130100004f003300450017004104583e054b7a66672ae020ad9d2686fcc85b5ad41a134a0f03ee72b893052bd85b4c8de6776f5b04ac07d83540eab3e3d9c547bc6528c4317d294686093a6cad7d002b00020304")

(define (s5-server-flight) : String
  "080000180016000a0008000600170018001d001c00024001000000000b0001b9000001b50001b0308201ac30820115a003020102020102300d06092a864886f70d01010b0500300e310c300a06035504031303727361301e170d3136303733303031323335395a170d3236303733303031323335395a300e310c300a0603550403130372736130819f300d06092a864886f70d010101050003818d0030818902818100b4bb498f8279303d980836399b36c6988c0c68de55e1bdb826d3901a2461eafd2de49a91d015abbc9a95137ace6c1af19eaa6af98c7ced43120998e187a80ee0ccb0524b1b018c3e0b63264d449a6d38e22a5fda430846748030530ef0461c8ca9d9efbfae8ea6d1d03e2bd193eff0ab9a8002c47428a6d35a8d88d79f7f1e3f0203010001a31a301830090603551d1304023000300b0603551d0f0404030205a0300d06092a864886f70d01010b05000381810085aad2a0e5b9276b908c65f73a7267170618a54c5f8a7b337d2df7a594365417f2eae8f8a58c8f8172f9319cf36b7fd6c55b80f21a03015156726096fd335e5e67f2dbf102702e608ccae6bec1fc63a42a99be5c3eb7107c3c54e9b9eb2bd5203b1c3b84e0a8b2f759409ba3eac9d91d402dcc0cc8f8961229ac9187b42b4de100000f0000840804008033ab13d4462707231b5dcae6c8190b63d1dabc74f28c395370da0b07e5b83066d0246a31acd95df475bfd799a4a70d33ad93d3a317a9b2c0d237a5685b219e774112e391a247607d1aeff1bbd0a39f382ee1a5fe88ae99ec59228e6497e45d48ce275a6d5ef40d169fb6f9d33b052ed3dcdd6b5a48baafffbcb290128415bd38140000208863e6bfb0420a927fa27f34336a70ae426e968e3eb884945b96856dba3976d1")

(define (s5-client-finished) : String
  "1400002023f52fdb0709a55bd7f79b991f25484087bcfd4d4380b12326a52a28b2e368e1")