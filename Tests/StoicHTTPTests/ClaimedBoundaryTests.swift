import Stoic
import StoicSchema
import StoicTesting
import Testing

/// A boundary decodes through its schema and wraps what it decoded as a claim
/// (design/28, Writing down): shape is checked first, provenance after.
@Suite("Claims at a boundary")
struct ClaimedBoundaryTests {
    /// The boundary: bytes in, a well-formed claim out, or the schema's issues.
    static func receive(_ body: String) -> Result<Claimed<User>, ValidationFailure> {
        Result { () throws(ValidationFailure) in
            Claimed(try User.schema.decode(body, warnings: { _ in }))
        }
    }

    @Test(.failureMode("design/28", "a claimed value has the wrong shape"))
    func theSchemaRefusesTheShapeBeforeAnyVerifierIsAsked() throws {
        var verifierAsked = 0
        func verify(_ claim: Claimed<User>) -> Bool {
            verifierAsked += 1
            return claim.map(\.id).unverified() > 0
        }

        switch Self.receive(#"{"id": 0, "name": "Ada"}"#) {
        case .success(let claim): _ = verify(claim)
        case .failure(let failure): #expect(failure.errors.count == 1, "the id is out of range")
        }
        #expect(verifierAsked == 0, "a malformed claim never reaches a verifier")

        let wellFormed = try Self.receive(#"{"id": 42, "name": "Ada"}"#).get()
        #expect(verify(wellFormed))
        #expect(verifierAsked == 1)
    }
}
