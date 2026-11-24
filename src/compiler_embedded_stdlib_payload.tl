;; Explicit compressed compile-only inputs for the embedded stdlib payload.
(import stdlib.string)

(include-str-lzss payload-arena "../stdlib/arena.tl")

(include-str-lzss payload-atomic "../stdlib/atomic.tl")

(include-str-lzss payload-args "../stdlib/args.tl")

(include-str-lzss payload-base64 "../stdlib/base64.tl")

(include-str-lzss payload-byte-buf "../stdlib/byte_buf.tl")

(include-str-lzss payload-byte-buf-core "../stdlib/byte_buf_core.tl")

(include-str-lzss payload-byte-le "../stdlib/byte_le.tl")

(include-str-lzss payload-byte-reader "../stdlib/byte_reader.tl")

(include-str-lzss payload-clone "../stdlib/clone.tl")

(include-str-lzss payload-cpu "../stdlib/cpu.tl")

(include-str-lzss payload-checked-size "../stdlib/checked_size.tl")

(include-str-lzss payload-comptime "../stdlib/comptime.tl")

(include-str-lzss payload-compress-adler32 "../stdlib/compress/adler32.tl")

(include-str-lzss payload-compress-deflate "../stdlib/compress/deflate.tl")

(include-str-lzss payload-compress-zlib "../stdlib/compress/zlib.tl")

(include-str-lzss
  payload-concurrency-registry
  "../stdlib/concurrency_registry.tl")

(include-str-lzss payload-core-macros "../stdlib/core_macros.tl")

(include-str-lzss payload-crypto-aes-core "../stdlib/crypto_aes_core.tl")

(include-str-lzss payload-crypto-hkdf-sha256 "../stdlib/crypto_hkdf_sha256.tl")

(include-str-lzss payload-crypto-hmac-sha256 "../stdlib/crypto_hmac_sha256.tl")

(include-str-lzss payload-crypto-secret "../stdlib/crypto_secret.tl")

(include-str-lzss payload-crypto-stack-scrub "../stdlib/crypto_stack_scrub.tl")

(include-str-lzss payload-crypto-sha1-git "../stdlib/crypto_sha1_git.tl")

(include-str-lzss payload-crypto-sha256 "../stdlib/crypto_sha256.tl")

(include-str-lzss payload-crypto-sha512 "../stdlib/crypto_sha512.tl")

(include-str-lzss payload-dense-list "../stdlib/dense_list.tl")

(include-str-lzss payload-env "../stdlib/env.tl")

(include-str-lzss payload-eq "../stdlib/eq.tl")

(include-str-lzss payload-ffi "../stdlib/ffi.tl")

(include-str-lzss payload-fs "../stdlib/fs.tl")

(include-str-lzss payload-format "../stdlib/format.tl")

(include-str-lzss payload-format-writer-core "../stdlib/format_writer_core.tl")

(include-str-lzss payload-hash "../stdlib/hash.tl")

(include-str-lzss payload-hashmap "../stdlib/hashmap.tl")

(include-str-lzss payload-local-ipc "../stdlib/local_ipc.tl")

(include-str-lzss payload-net "../stdlib/net.tl")

(include-str-lzss payload-net-dns-wire "../stdlib/net/dns/wire.tl")

(include-str-lzss
  payload-net-http-head-codec
  "../stdlib/net/http_head_codec.tl")

(include-str-lzss payload-net-http-trailer "../stdlib/net/http_trailer.tl")

(include-str-lzss
  payload-net-http-trailer-policy
  "../stdlib/net/http_trailer_policy.tl")

(include-str-lzss payload-net-http-types "../stdlib/net/http_types.tl")

(include-str-lzss payload-net-ip "../stdlib/net/ip.tl")

(include-str-lzss payload-net-dns-name "../stdlib/net/dns_name.tl")

(include-str-lzss
  payload-net-resolver-config
  "../stdlib/net/resolver_config.tl")

(include-str-lzss
  payload-net-resolver-config-linux
  "../stdlib/net/resolver_config_linux.tl")

(include-str-lzss payload-net-tls-wire "../stdlib/net/tls_wire.tl")

(include-str-lzss payload-net-tls-transcript "../stdlib/net/tls_transcript.tl")

(include-str-lzss payload-io-core "../stdlib/io_core.tl")

(include-str-lzss payload-io "../stdlib/io.tl")

(include-str-lzss payload-iterator "../stdlib/iterator.tl")

(include-str-lzss payload-json "../stdlib/json.tl")

(include-str-lzss payload-math "../stdlib/math.tl")

(include-str-lzss payload-msvc "../stdlib/msvc.tl")

(include-str-lzss payload-process "../stdlib/process.tl")

(include-str-lzss payload-process-borrowed "../stdlib/process_borrowed.tl")

(include-str-lzss payload-process-runtime "../stdlib/process_runtime.tl")

(include-str-lzss payload-profile "../stdlib/profile.tl")

(include-str-lzss payload-queue "../stdlib/queue.tl")

(include-str-lzss payload-random "../stdlib/random.tl")

(include-str-lzss payload-result "../stdlib/result.tl")

(include-str-lzss payload-runtime "../stdlib/runtime.tl")

(include-str-lzss payload-serialize "../stdlib/serialize.tl")

(include-str-lzss payload-sort "../stdlib/sort.tl")

(include-str-lzss payload-sync "../stdlib/sync.tl")

(include-str-lzss payload-string "../stdlib/string.tl")

(include-str-lzss payload-string-utf8 "../stdlib/string_utf8.tl")

(include-str-lzss payload-str-cat "../stdlib/str_cat.tl")

(include-str-lzss payload-str-cat-runtime "../stdlib/str_cat_runtime.tl")

(include-str-lzss payload-test "../stdlib/test.tl")

(include-str-lzss payload-thread "../stdlib/thread.tl")

(include-str-lzss payload-time "../stdlib/time.tl")

(include-str-lzss payload-text-buf "../stdlib/text_buf.tl")

(include-str-lzss payload-text-buf-borrowed "../stdlib/text_buf_borrowed.tl")

(include-str-lzss payload-text-buf-family "../stdlib/text_buf_family.tl")

(include-str-lzss payload-vector "../stdlib/vector.tl")

(include-str-lzss payload-io-caller-result "../stdlib/io_caller_result.tl")

(include-str-lzss payload-option "../stdlib/option.tl")

(include-str-lzss payload-set "../stdlib/set.tl")

(include-str-lzss
  payload-string-caller-result
  "../stdlib/string_caller_result.tl")

(include-str-lzss payload-asn1-der "../stdlib/asn1_der.tl")

(include-str-lzss payload-pem "../stdlib/pem.tl")

(include-str-lzss payload-x509-time "../stdlib/x509_time.tl")

(include-str-lzss payload-x509 "../stdlib/x509.tl")

(defenum CompilerEmbeddedStdlibPayload
  (CompilerEmbeddedStdlibPayloadNone)
  (CompilerEmbeddedStdlibPayloadSome (__tl_dyn-array u8) i64))

;; Embedded compressed buffers are immutable process-lifetime storage. Decoding
;; allocates the uncompressed source independently, so copying every compressed
;; byte here only adds transient work. Take an explicit shallow view of that
;; permanent storage instead.
(defmacro (compiler-embedded-stdlib-payload-copy
  [payload : Expr]
  [index : Expr]) : CompilerEmbeddedStdlibPayload
  `(CompilerEmbeddedStdlibPayloadSome
    (unsafe
      (ptr-read (ptr-addr-of ,payload)))
    ,index))

(define (compiler-embedded-stdlib-payload-container) : (__tl_dyn-array u8)
  (unsafe
    (ptr-read (ptr-addr-of payload-arena))))

(define (compiler-embedded-stdlib-payload-lookup [suffix : String]) : CompilerEmbeddedStdlibPayload
  (cond
    [(string.eq suffix "arena.tl")
      (compiler-embedded-stdlib-payload-copy payload-arena 0)]
    [(string.eq suffix "atomic.tl")
      (compiler-embedded-stdlib-payload-copy payload-atomic 1)]
    [(string.eq suffix "args.tl")
      (compiler-embedded-stdlib-payload-copy payload-args 2)]
    [(string.eq suffix "base64.tl")
      (compiler-embedded-stdlib-payload-copy payload-base64 3)]
    [(string.eq suffix "byte_buf.tl")
      (compiler-embedded-stdlib-payload-copy payload-byte-buf 4)]
    [(string.eq suffix "byte_buf_core.tl")
      (compiler-embedded-stdlib-payload-copy payload-byte-buf-core 5)]
    [(string.eq suffix "byte_le.tl")
      (compiler-embedded-stdlib-payload-copy payload-byte-le 6)]
    [(string.eq suffix "byte_reader.tl")
      (compiler-embedded-stdlib-payload-copy payload-byte-reader 7)]
    [(string.eq suffix "clone.tl")
      (compiler-embedded-stdlib-payload-copy payload-clone 8)]
    [(string.eq suffix "cpu.tl")
      (compiler-embedded-stdlib-payload-copy payload-cpu 9)]
    [(string.eq suffix "checked_size.tl")
      (compiler-embedded-stdlib-payload-copy payload-checked-size 10)]
    [(string.eq suffix "comptime.tl")
      (compiler-embedded-stdlib-payload-copy payload-comptime 11)]
    [(string.eq suffix "compress/adler32.tl")
      (compiler-embedded-stdlib-payload-copy payload-compress-adler32 12)]
    [(string.eq suffix "compress/deflate.tl")
      (compiler-embedded-stdlib-payload-copy payload-compress-deflate 13)]
    [(string.eq suffix "compress/zlib.tl")
      (compiler-embedded-stdlib-payload-copy payload-compress-zlib 14)]
    [(string.eq suffix "concurrency_registry.tl")
      (compiler-embedded-stdlib-payload-copy payload-concurrency-registry 15)]
    [(string.eq suffix "core_macros.tl")
      (compiler-embedded-stdlib-payload-copy payload-core-macros 16)]
    [(string.eq suffix "crypto_aes_core.tl")
      (compiler-embedded-stdlib-payload-copy payload-crypto-aes-core 17)]
    [(string.eq suffix "crypto_hkdf_sha256.tl")
      (compiler-embedded-stdlib-payload-copy payload-crypto-hkdf-sha256 18)]
    [(string.eq suffix "crypto_hmac_sha256.tl")
      (compiler-embedded-stdlib-payload-copy payload-crypto-hmac-sha256 19)]
    [(string.eq suffix "crypto_secret.tl")
      (compiler-embedded-stdlib-payload-copy payload-crypto-secret 20)]
    [(string.eq suffix "crypto_stack_scrub.tl")
      (compiler-embedded-stdlib-payload-copy payload-crypto-stack-scrub 21)]
    [(string.eq suffix "crypto_sha1_git.tl")
      (compiler-embedded-stdlib-payload-copy payload-crypto-sha1-git 22)]
    [(string.eq suffix "crypto_sha256.tl")
      (compiler-embedded-stdlib-payload-copy payload-crypto-sha256 23)]
    [(string.eq suffix "crypto_sha512.tl")
      (compiler-embedded-stdlib-payload-copy payload-crypto-sha512 24)]
    [(string.eq suffix "dense_list.tl")
      (compiler-embedded-stdlib-payload-copy payload-dense-list 25)]
    [(string.eq suffix "env.tl")
      (compiler-embedded-stdlib-payload-copy payload-env 26)]
    [(string.eq suffix "eq.tl")
      (compiler-embedded-stdlib-payload-copy payload-eq 27)]
    [(string.eq suffix "ffi.tl")
      (compiler-embedded-stdlib-payload-copy payload-ffi 28)]
    [(string.eq suffix "fs.tl")
      (compiler-embedded-stdlib-payload-copy payload-fs 29)]
    [(string.eq suffix "format.tl")
      (compiler-embedded-stdlib-payload-copy payload-format 30)]
    [(string.eq suffix "format_writer_core.tl")
      (compiler-embedded-stdlib-payload-copy payload-format-writer-core 31)]
    [(string.eq suffix "hash.tl")
      (compiler-embedded-stdlib-payload-copy payload-hash 32)]
    [(string.eq suffix "hashmap.tl")
      (compiler-embedded-stdlib-payload-copy payload-hashmap 33)]
    [(string.eq suffix "local_ipc.tl")
      (compiler-embedded-stdlib-payload-copy payload-local-ipc 34)]
    [(string.eq suffix "net.tl")
      (compiler-embedded-stdlib-payload-copy payload-net 35)]
    [(string.eq suffix "net/dns/wire.tl")
      (compiler-embedded-stdlib-payload-copy payload-net-dns-wire 36)]
    [(string.eq suffix "net/http_head_codec.tl")
      (compiler-embedded-stdlib-payload-copy payload-net-http-head-codec 37)]
    [(string.eq suffix "net/http_trailer.tl")
      (compiler-embedded-stdlib-payload-copy payload-net-http-trailer 38)]
    [(string.eq suffix "net/http_trailer_policy.tl")
      (compiler-embedded-stdlib-payload-copy payload-net-http-trailer-policy 39)]
    [(string.eq suffix "net/http_types.tl")
      (compiler-embedded-stdlib-payload-copy payload-net-http-types 40)]
    [(string.eq suffix "net/ip.tl")
      (compiler-embedded-stdlib-payload-copy payload-net-ip 41)]
    [(string.eq suffix "net/dns_name.tl")
      (compiler-embedded-stdlib-payload-copy payload-net-dns-name 42)]
    [(string.eq suffix "net/resolver_config.tl")
      (compiler-embedded-stdlib-payload-copy payload-net-resolver-config 43)]
    [(string.eq suffix "net/resolver_config_linux.tl")
      (compiler-embedded-stdlib-payload-copy
        payload-net-resolver-config-linux
        44)]
    [(string.eq suffix "net/tls_wire.tl")
      (compiler-embedded-stdlib-payload-copy payload-net-tls-wire 45)]
    [(string.eq suffix "net/tls_transcript.tl")
      (compiler-embedded-stdlib-payload-copy payload-net-tls-transcript 46)]
    [(string.eq suffix "io_core.tl")
      (compiler-embedded-stdlib-payload-copy payload-io-core 47)]
    [(string.eq suffix "io.tl")
      (compiler-embedded-stdlib-payload-copy payload-io 48)]
    [(string.eq suffix "iterator.tl")
      (compiler-embedded-stdlib-payload-copy payload-iterator 49)]
    [(string.eq suffix "json.tl")
      (compiler-embedded-stdlib-payload-copy payload-json 50)]
    [(string.eq suffix "math.tl")
      (compiler-embedded-stdlib-payload-copy payload-math 51)]
    [(string.eq suffix "msvc.tl")
      (compiler-embedded-stdlib-payload-copy payload-msvc 52)]
    [(string.eq suffix "process.tl")
      (compiler-embedded-stdlib-payload-copy payload-process 53)]
    [(string.eq suffix "process_borrowed.tl")
      (compiler-embedded-stdlib-payload-copy payload-process-borrowed 54)]
    [(string.eq suffix "process_runtime.tl")
      (compiler-embedded-stdlib-payload-copy payload-process-runtime 55)]
    [(string.eq suffix "profile.tl")
      (compiler-embedded-stdlib-payload-copy payload-profile 56)]
    [(string.eq suffix "queue.tl")
      (compiler-embedded-stdlib-payload-copy payload-queue 57)]
    [(string.eq suffix "random.tl")
      (compiler-embedded-stdlib-payload-copy payload-random 58)]
    [(string.eq suffix "result.tl")
      (compiler-embedded-stdlib-payload-copy payload-result 59)]
    [(string.eq suffix "runtime.tl")
      (compiler-embedded-stdlib-payload-copy payload-runtime 60)]
    [(string.eq suffix "serialize.tl")
      (compiler-embedded-stdlib-payload-copy payload-serialize 61)]
    [(string.eq suffix "sort.tl")
      (compiler-embedded-stdlib-payload-copy payload-sort 62)]
    [(string.eq suffix "sync.tl")
      (compiler-embedded-stdlib-payload-copy payload-sync 63)]
    [(string.eq suffix "string.tl")
      (compiler-embedded-stdlib-payload-copy payload-string 64)]
    [(string.eq suffix "string_utf8.tl")
      (compiler-embedded-stdlib-payload-copy payload-string-utf8 65)]
    [(string.eq suffix "str_cat.tl")
      (compiler-embedded-stdlib-payload-copy payload-str-cat 66)]
    [(string.eq suffix "str_cat_runtime.tl")
      (compiler-embedded-stdlib-payload-copy payload-str-cat-runtime 67)]
    [(string.eq suffix "test.tl")
      (compiler-embedded-stdlib-payload-copy payload-test 68)]
    [(string.eq suffix "thread.tl")
      (compiler-embedded-stdlib-payload-copy payload-thread 69)]
    [(string.eq suffix "time.tl")
      (compiler-embedded-stdlib-payload-copy payload-time 70)]
    [(string.eq suffix "text_buf.tl")
      (compiler-embedded-stdlib-payload-copy payload-text-buf 71)]
    [(string.eq suffix "text_buf_borrowed.tl")
      (compiler-embedded-stdlib-payload-copy payload-text-buf-borrowed 72)]
    [(string.eq suffix "text_buf_family.tl")
      (compiler-embedded-stdlib-payload-copy payload-text-buf-family 73)]
    [(string.eq suffix "vector.tl")
      (compiler-embedded-stdlib-payload-copy payload-vector 74)]
    [(string.eq suffix "io_caller_result.tl")
      (compiler-embedded-stdlib-payload-copy payload-io-caller-result 75)]
    [(string.eq suffix "option.tl")
      (compiler-embedded-stdlib-payload-copy payload-option 76)]
    [(string.eq suffix "set.tl")
      (compiler-embedded-stdlib-payload-copy payload-set 77)]
    [(string.eq suffix "string_caller_result.tl")
      (compiler-embedded-stdlib-payload-copy payload-string-caller-result 78)]
    [(string.eq suffix "asn1_der.tl")
      (compiler-embedded-stdlib-payload-copy payload-asn1-der 79)]
    [(string.eq suffix "pem.tl")
      (compiler-embedded-stdlib-payload-copy payload-pem 80)]
    [(string.eq suffix "x509_time.tl")
      (compiler-embedded-stdlib-payload-copy payload-x509-time 81)]
    [(string.eq suffix "x509.tl")
      (compiler-embedded-stdlib-payload-copy payload-x509 82)]
    [else (CompilerEmbeddedStdlibPayloadNone)]))