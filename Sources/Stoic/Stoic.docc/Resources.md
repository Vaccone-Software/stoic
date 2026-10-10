# Resources

Release what you acquire.

@Metadata {
    @PageImage(purpose: card, source: "plate-resources", alt: "An engraving of Atlas carrying the starry sky, set in an arched niche, printed as two-colour static.")
    @PageColor(green)
}

## What it does

@Row {
    @Column(size: 3) {
        A ``Scope`` owns what is acquired in it. When the scope ends, by success, failure
        or cancellation, the releases run in reverse order, shielded from cancellation
        and bounded in time. A release that fails is reported and does not change the
        outcome.

        Shared work follows the same rule. A ``TaskSlot`` keeps only the newest result,
        a ``SingleFlight`` runs one operation for many callers, and a ``Channel`` has a
        capacity and a stated answer for when it is full.
    }
    @Column {
        ![An engraving of Atlas carrying the starry sky, set in an arched niche, printed as two-colour static.](plate-resources)
    }
}

## Use it when

- A socket, file, process or session must be closed on every path out, cancellation included.
- Cleanup is asynchronous and must still run when the task is cancelled.
- Many callers want the same data, or only the newest request should win.

## Example

```swift
try await withScope { scope in
    let socket = try await scope.acquire { try await Socket.connect(host) }
                                  release: { socket, _ in await socket.close() }
    try await serve(socket)
}

let avatars = SingleFlight<URL, Data, any Error>(label: "avatars")
let data = try await avatars.run(url) { try await download(url) }
```

## What happens if…

| …                                                       | Stoic                                                                                             |
| ------------------------------------------------------- | ------------------------------------------------------------------------------------------------- |
| the body throws                                         | Finalizers run with `.failure(error)`, and the error is rethrown unchanged                        |
| the task is cancelled mid-body                          | Finalizers run, shielded, and `CancellationError` is rethrown                                     |
| a finalizer throws                                      | It is reported at error level, the remaining finalizers run, and the outcome is unchanged         |
| a finalizer hangs                                       | It is abandoned after its timeout and listed in `AbandonedWork`                                   |
| a forked child throws                                   | The body and siblings are cancelled; after cleanup, `ConcurrentFailure` carries every child error |
| a superseded `TaskSlot` task finishes after the new one | Its result is dropped, and `slot.superseded_late` is reported                                     |

The full contracts, with every case, are `design/04-scopes-and-resources.md` and
`design/03-concurrency.md` in the repository.

## The API

- ``Scope``
- ``TaskScope``
- ``Resource``
- ``Saga``
- ``Exit``
- ``TaskSlot``
- ``SingleFlight``
- ``Channel``
