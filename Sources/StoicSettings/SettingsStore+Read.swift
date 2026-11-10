internal import StoicJSON
public import StoicSchema
internal import StoicStore

extension SettingsStore {
    /// The store's read of a settings file's bytes, with no file: what
    /// ``open(at:schema:format:unknownKeys:fileSystem:options:)`` would make of
    /// them (design/18, design/32).
    ///
    /// Its decode options for `format` (lenient: a field that does not read
    /// falls back to its default, with a repair), an app-owned file's envelope
    /// unwrapped (and a plain JSON file from before the store read as it is), a
    /// hand-edited file's dialect and header keys set aside, and a repeated
    /// key's warning as the store words it. It is what a compatibility check is
    /// given as `reading:`, so released settings files are read the way the
    /// store reads them: a check whose options differ from the real reader's
    /// proves the wrong thing.
    ///
    /// - Parameters:
    ///   - bytes: The file, exactly as it is on disk.
    ///   - schema: The settings' schema.
    ///   - format: Whose file it is.
    ///   - options: The store's options; ``Options/handEdited`` says the
    ///     dialect and the header of a hand-edited file.
    /// - Returns: The value, if no issue is an error, and every issue.
    public static func read(
        _ bytes: [UInt8], schema: Schema<Value>, format: Format = .appOwned, options: Options = Options()
    ) -> Decoded<Value> {
        switch format {
        case .appOwned:
            let decodeOptions = DecodeOptions(mode: .lenient)
            guard EnvelopedFile.isEnveloped(bytes) else {
                // A plain JSON file from before the store, as `open` adopts it.
                return schema.decodeReporting(bytes, options: decodeOptions)
            }
            let opened = EnvelopedFile.payload(of: bytes)
            guard let payload = opened.payload else {
                return Decoded(value: nil, issues: [
                    Issue(code: .invalidFormat, parameters: ["reason": .string("the file's envelope is not intact: \(opened.problem ?? "")")]),
                ])
            }
            return schema.decodeReporting(payload, options: decodeOptions)
        case .handEdited:
            var decodeOptions = DecodeOptions.lenient
            decodeOptions.parse = options.handEdited.parseOptions
            return decodeHandEdited(bytes, schema: schema, options: decodeOptions, header: options.handEdited.fileHeader).decoded
        }
    }

    /// A hand-edited file's bytes as the store reads them: its header keys set
    /// aside (the schema never sees them), and a repeated key's warning as the
    /// store words it. The document is `nil` when the text does not parse; the
    /// issues then hold the parse failure, with its line and column.
    static func decodeHandEdited(
        _ bytes: [UInt8], schema: Schema<Value>, options: DecodeOptions, header: SettingsFileHeader
    ) -> (document: JSONDocument?, decoded: Decoded<Value>) {
        let document: JSONDocument
        do throws(JSONParseError) {
            document = try JSONDocument(parsing: bytes, options: options.parse).removingRootMembers(header.keys)
        } catch {
            return (nil, schema.decodeReporting(bytes, options: options))
        }
        let decoded = schema.decode(document, options: options)
        return (document, Decoded(value: decoded.value, issues: annotatingRepeats(decoded.issues)))
    }
}
