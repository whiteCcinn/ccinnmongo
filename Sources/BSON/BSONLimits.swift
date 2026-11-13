/// Limits shared by every recursive BSON algorithm (decode, encode, parse, format).
public enum BSONLimits {
    /// Maximum nesting depth. MongoDB stores at most 100 levels; the margin covers reply envelopes.
    /// Bounding depth bounds recursion, which keeps stack usage safe on 512 KB secondary threads.
    public static let maximumDepth = 150

    /// Maximum size of a document MongoDB accepts (16 MiB), used for client-side validation.
    public static let maximumDocumentSize = 16 * 1024 * 1024
}
