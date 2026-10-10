# Lifecycle

Start in order, stop in reverse, keep it running.

@Metadata {
    @PageImage(purpose: card, source: "plate-lifecycle", alt: "An engraving of Hercules fighting the Hydra, set in an arched niche, printed as two-colour static.")
    @PageColor(green)
}

## What it does

@Row {
    @Column(size: 3) {
        A ``StateMachine`` makes work belong to a state. The work starts when the machine
        enters the state and is cancelled when it leaves, so a late result from an earlier
        visit is dropped. A ``Supervisor`` keeps long-lived work running: it restarts a
        child that fails, after a backoff, and stops everything and says so when restarting
        stops helping.

        A ``ServiceGraph`` starts an app's services in dependency order, side by side where
        they are independent, and stops them in reverse. If a start fails, or the app is
        cancelled, everything already started is stopped.
    }
    @Column {
        ![An engraving of Hercules fighting the Hydra, set in an arched niche, printed as two-colour static.](plate-lifecycle)
    }
}

## Use it when

- A feature has phases, and work must belong to one phase rather than leak into the next.
- Background work, such as a sync engine or an event tap, must stay running, and a hang must be noticed.
- Services depend on each other and must start and stop in order.

## Example

```swift
let database = ServiceKey<Database>("database")
let graph = try ServiceGraph(label: "app") {
    Provide(database) { _ in try await Database.open(url) } stop: { db, _ in await db.close() }
}
try await graph.run { services in
    try await Supervisor(label: "app") {
        Child("sync") { _ in try await SyncEngine(services[database]).run() }
    }.run()
}
```

## What happens if…

| …                                   | Stoic                                                                                    |
| ----------------------------------- | ---------------------------------------------------------------------------------------- |
| services need each other            | The initialiser throws `cycle`, with the path, before anything starts                    |
| a start throws or times out         | Other starts are cancelled, started services are stopped, and `run` throws `startFailed` |
| a state is left while its work runs | The work is cancelled                                                                    |
| restarts exceed the intensity       | All children are stopped and `SupervisorEscalation` is thrown                            |
| a child stops beating               | After `misses` intervals past `grace`, it is stopped and restarted                       |
| the Mac sleeps                      | The liveness clock stops, so no child is taken for hung                                  |

The full contracts, with every case, are `design/07-state-machines.md`,
`design/08-services-and-lifecycle.md` and `design/09-supervision.md` in the repository.

## The API

- ``StateMachine``
- ``Transition``
- ``StateTimeout``
- ``StateGraph``
- ``Supervisor``
- ``Child``
- ``RestartPolicy``
- ``HeartbeatPolicy``
- ``SupervisorEscalation``
- ``ServiceGraph``
- ``ServiceKey``
- ``Provide``
- ``ServiceGraphError``
