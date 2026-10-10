extension Dictionary where Key: Comparable {
    /// The values, in key order. Primitives that cancel or resume a set of
    /// tasks do it in this order: a dictionary's own order changes with every
    /// process's hash seed, which would make the order tasks become runnable
    /// — and so a simulation's replay of a seed — differ between processes.
    package var valuesInKeyOrder: [Value] {
        sorted { $0.key < $1.key }.map(\.value)
    }
}
