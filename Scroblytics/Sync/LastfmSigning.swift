import Foundation
import CryptoKit

/// Last.fm's method-signature algorithm (`api_sig`), used to authenticate
/// every write/auth call the read-only sync layer never needed. Isolated on
/// its own, with no network dependency, specifically so it can be verified
/// against a known-correct reference computation before anything is wired
/// into a live request — this is the piece most likely to have a subtle bug
/// (parameter ordering, encoding, a forgotten param) if built and tested only
/// end-to-end.
///
/// Algorithm (per Last.fm's documented spec): every parameter except
/// `format`, sorted alphabetically by key, concatenated as
/// `key1value1key2value2...` with no separators, the shared secret appended
/// at the end, then MD5 hex digest of the UTF-8 bytes. Values are NOT
/// URL-encoded before hashing — only the raw UTF-8 text matters.
enum LastfmSigning {
    static func sign(params: [String: String], secret: String) -> String {
        let base = params.keys.sorted().map { "\($0)\(params[$0]!)" }.joined()
        let digest = Insecure.MD5.hash(data: Data((base + secret).utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
