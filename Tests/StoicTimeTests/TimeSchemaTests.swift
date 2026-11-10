import Stoic
import StoicSchema
import StoicSchemaTesting
import StoicTesting
import StoicTime
import Testing

@Suite("Time schemas")
struct TimeSchemaTests {
    @Test func everyLeafPassesItsSuite() {
        expectSchemaSuite(Schema<Moment>.moment, seed: 1, cases: 300)
        expectSchemaSuite(Schema<PlainDate>.plainDate, seed: 2, cases: 300)
        expectSchemaSuite(Schema<PlainTime>.plainTime, seed: 3, cases: 300)
        expectSchemaSuite(Schema<PlainDateTime>.plainDateTime, seed: 4, cases: 300)
        expectSchemaSuite(Schema<ZonedDateTime>.zonedDateTime, seed: 5, cases: 300)
        expectSchemaSuite(Schema<Period>.period, seed: 6, cases: 300)
        expectSchemaSuite(Schema<TimeZoneID>.timeZoneID, seed: 7, cases: 300)
    }

    /// A date where a moment is expected, or a moment where a date is: one
    /// `invalid_format` issue that says which form it is, never a value read
    /// by guessing (midnight UTC, or the date part).
    @Test(.failureMode("design/26", "a plain date is decoded from a moment's text, or the reverse"))
    func aPlainDateAndAMomentDoNotReadAsEachOther() {
        let asMoment = Moment.schema.decodeReporting(#""2027-03-14""#)
        #expect(asMoment.value == nil)
        #expect(asMoment.errors.map(\.code) == [.invalidFormat])
        #expect(asMoment.errors.first?.message.contains("a date without a time") == true, "\(asMoment.errors)")

        let asDate = PlainDate.schema.decodeReporting(#""2026-11-09T18:34:12.425Z""#)
        #expect(asDate.value == nil)
        #expect(asDate.errors.map(\.code) == [.invalidFormat])
        #expect(asDate.errors.first?.message.contains("a date with a time is a date-time or a moment") == true, "\(asDate.errors)")

        let localAsMoment = Moment.schema.decodeReporting(#""2027-03-14T09:00:00""#)
        #expect(localAsMoment.errors.first?.message.contains("names no instant") == true)
        let momentAsLocal = PlainDateTime.schema.decodeReporting(#""2027-03-14T09:00:00Z""#)
        #expect(momentAsLocal.errors.first?.message.contains("with an offset it is a moment") == true)

        #expect(Moment.schema.decodeReporting(#""2026-11-09T18:34:12.425Z""#).value?.rfc3339 == "2026-11-09T18:34:12.425Z")
        #expect(PlainDate.schema.decodeReporting(#""2027-03-14""#).value?.description == "2027-03-14")
    }

    @Test func aMomentTheTextCannotWriteIsReported() {
        let beyond = Moment(sinceEpoch: .seconds(Int64.max / 2))
        #expect(Schema<Moment>.moment.validate(beyond).map(\.code) == [.outOfRange], "a moment the text cannot write")
    }
}
