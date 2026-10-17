#if STOIC_CRYPTO
internal import Stoic

/// Reports the library's decisions through the ambient instrumentation.
///
/// What an event may carry: counts, flags, the kind of a failure, the purpose
/// a context was given (a constant the app chose), the name of a keyring, a
/// path. Never a key, a key identifier, a nonce, a context id or any
/// plaintext (design/24).
enum SealedEvents {
    static func record(_ event: Event) {
        Ambient.current.instrumentation.record(event)
    }
}
#endif
