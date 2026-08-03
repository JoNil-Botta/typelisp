;; Extern-C references remain outside the public Slice ABI policy.
(extern (slice-read [s : (& s (Slice i64))]) : i64)