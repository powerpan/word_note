import Foundation

public enum VersionedWordNoteSnapshot: Sendable {
    case v1(DecodedWordNoteSnapshot)
    case v2(DecodedWordNoteSnapshotV2)
}

public enum WordNoteSnapshotReader {
    public static func decode(_ data: Data) throws -> VersionedWordNoteSnapshot {
        guard data.count <= WordNoteSnapshotCodec.maximumDocumentBytes else { throw WordNoteSnapshotError.sizeLimit }
        let header: Header
        do {
            header = try JSONDecoder().decode(Header.self, from: data)
        } catch {
            throw WordNoteSnapshotError.invalidDocument
        }
        guard header.formatVersion == 1 else { throw WordNoteSnapshotError.unsupportedFormat }
        switch header.sourceSchemaVersion {
        case "1.0.0": return .v1(try WordNoteSnapshotCodec.decode(data))
        case "2.0.0": return .v2(try WordNoteSnapshotV2Codec.decode(data))
        default: throw WordNoteSnapshotError.unsupportedSchema
        }
    }

    private struct Header: Decodable {
        let formatVersion: Int
        let sourceSchemaVersion: String
    }
}
