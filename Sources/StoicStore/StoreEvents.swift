internal import Stoic

/// Reports the store's decisions through the ambient instrumentation.
enum StoreEvents {
    static func record(_ event: Event) {
        Ambient.current.instrumentation.record(event)
    }
}
