import Foundation
import Testing

@testable import ShowMyCopy

struct Base32Tests {
    /// RFC 4648 §10 test vectors.
    @Test(arguments: [
        ("", ""),
        ("MY======", "f"),
        ("MZXQ====", "fo"),
        ("MZXW6===", "foo"),
        ("MZXW6YQ=", "foob"),
        ("MZXW6YTB", "fooba"),
        ("MZXW6YTBOI======", "foobar"),
    ])
    func decodesTheReferenceVectors(encoded: String, decoded: String) throws {
        #expect(try Base32.decode(encoded) == Data(decoded.utf8))
    }

    @Test func decodesTheUsualAuthenticatorSecret() throws {
        #expect(try Base32.decode("JBSWY3DPEHPK3PXP") == Data("Hello!".utf8) + Data([0xDE, 0xAD, 0xBE, 0xEF]))
    }

    @Test(arguments: ["MZXW6YTBOI", "mzxw6ytboi", "MZXW 6YTB OI", "mzxw-6ytb-oi", "MZXW6YTBOI==", "MZXW6YTBOI======"])
    func acceptsHowPeopleWriteSecrets(text: String) throws {
        #expect(try Base32.decode(text) == Data("foobar".utf8))
    }

    @Test(arguments: ["MZXW6YT1", "MZXW6YT8", "MZXW6YT0", "MZXW6Y!B", "MZXW6YTБ", "MZ=W6YTB"])
    func rejectsCharactersOutsideTheAlphabet(text: String) {
        #expect(throws: Base32.DecodingError.self) {
            try Base32.decode(text)
        }
    }

    @Test(arguments: ["M", "MZX", "MZXW6Y", "MZXW6YTBO"])
    func rejectsTextThatStopsInsideAByte(text: String) {
        #expect(throws: Base32.DecodingError.truncated) {
            try Base32.decode(text)
        }
    }

    @Test func ignoresLeftoverBitsOfTheLastCharacter() throws {
        // "MZ" decodes to "f" like "MY": the three low bits of Z are leftovers, which authenticators ignore.
        #expect(try Base32.decode("MZ") == Data("f".utf8))
    }
}
