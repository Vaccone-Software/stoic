import Stoic
import StoicApple
import Testing

@Suite("Device conditions")
struct DeviceConditionsTests {
    @Test func theDeviceReportsPlausibleConditions() {
        let conditions = DeviceConditions.shared.current
        #expect(conditions.backoffFactor >= 1 && conditions.backoffFactor <= 8)
    }
}
