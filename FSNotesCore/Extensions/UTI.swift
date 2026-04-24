import Foundation
import UniformTypeIdentifiers

public extension String {

    /// Returns the preferred MIME type tag for the receiver when treated as a UTI identifier.
    var utiMimeType: String? {
        return UTType(self)?.preferredMIMEType
    }

    /// Returns the canonical UTI identifier for the receiver when treated as a MIME type string.
    var mimeTypeUTI: String? {
        return UTType(mimeType: self)?.identifier
    }

    /// Returns the canonical UTI identifier for the receiver when treated as a filename extension.
    var fileExtensionUTI: String? {
        return UTType(filenameExtension: self)?.identifier
    }
}
