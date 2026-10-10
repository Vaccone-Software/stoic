# Time

Put an end on every wait.

@Metadata {
    @PageImage(purpose: card, source: "plate-time", alt: "An engraving of winged Time among classical statues, set in an arched niche, printed as two-colour static.")
    @PageColor(green)
}

## What it does

@Row {
    @Column(size: 3) {
        A deadline bounds how long work may take, and it reaches everything the work
        calls. When it passes, the work is cancelled with the cause `.deadline`, so
        code below can tell a timeout from a user who gave up. An inner timeout can
        narrow the deadline but never widen it.

        Work that ignores cancellation, such as a blocking system call, runs under
        ``abandoningAfter(_:label:limit:clock:qos:fileID:line:operation:)``: the caller
        stops waiting at the deadline, and the abandoned work is counted until it
        returns.
    }
    @Column {
        ![An engraving of winged Time among classical statues, set in an arched niche, printed as two-colour static.](plate-time)
    }
}

## Use it when

- A network call, file read or IPC round trip could hang.
- A user is waiting and an answer that comes late is no answer.
- A synchronous API cannot be cancelled and must not block the caller forever.

## Example

```swift
let profile = try await withTimeout(.seconds(5)) {
    try await api.fetchProfile()
}

let attributes = try await abandoningAfter(.seconds(2), label: "stat") {
    try FileManager.default.attributesOfItem(atPath: path)
}
```

## What happens if…

| …                                                     | Stoic                                                                                     |
| ----------------------------------------------------- | ----------------------------------------------------------------------------------------- |
| the deadline passes and the work honours cancellation | The work is cancelled with cause `.deadline`; its error passes through                    |
| the deadline passes and the work ignores cancellation | `withTimeout` waits for it; `abandoningAfter` returns at the deadline and counts the work |
| an inner timeout is longer than the outer deadline    | The outer deadline wins                                                                   |
| every slot for a label is held by abandoned work      | New calls are refused with `.abandonmentLimit`                                            |
| the Mac sleeps past the deadline                      | The deadline fires on wake                                                                |

The full contract, with every case, is `design/01-time-and-deadlines.md` in
the repository.

## The API

- ``withTimeout(_:clock:tolerance:label:fileID:line:operation:)``
- ``withDeadline(_:tolerance:label:fileID:line:operation:)``
- ``Deadline``
- ``abandoningAfter(_:label:limit:clock:qos:fileID:line:operation:)``
- ``CancellationCause``
- ``ExpiringWork``
