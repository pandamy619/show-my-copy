import Foundation

/// Base32 as in RFC 4648 §6, the alphabet authenticator secrets are written in (`JBSWY3DPEHPK3PXP`).
enum Base32 {
    enum DecodingError: Error, Equatable, Sendable {
        /// A character outside `A–Z`, `2–7`, padding, spaces and hyphens. Lower case is accepted.
        case invalidCharacter(Character)
        /// The text stops in the middle of a byte: 1, 3 or 6 characters over a multiple of 8.
        case truncated
    }

    /// Decodes the text as people and apps write secrets: upper or lower case, with or without `=` padding, and
    /// with spaces or hyphens between groups, which are ignored. Leftover bits of the last character are ignored, as
    /// every authenticator does.
    static func decode(_ text: String) throws(DecodingError) -> Data {
        var bytes = Data()
        var buffer: UInt32 = 0
        var bufferedBits = 0
        var characters = 0
        var pastPadding = false
        for character in text where character != " " && character != "-" {
            if character == "=" {
                pastPadding = true
                continue
            }
            guard !pastPadding, let value = value(of: character) else { throw .invalidCharacter(character) }
            characters += 1
            buffer = (buffer << 5) | UInt32(value)
            bufferedBits += 5
            if bufferedBits >= 8 {
                bufferedBits -= 8
                bytes.append(UInt8(truncatingIfNeeded: buffer >> UInt32(bufferedBits)))
                buffer &= (1 << UInt32(bufferedBits)) - 1
            }
        }
        switch characters % 8 {
        case 1, 3, 6:
            throw .truncated
        default:
            return bytes
        }
    }

    private static func value(of character: Character) -> UInt8? {
        guard let ascii = character.asciiValue else { return nil }
        switch ascii {
        case UInt8(ascii: "A")...UInt8(ascii: "Z"):
            return ascii - UInt8(ascii: "A")
        case UInt8(ascii: "a")...UInt8(ascii: "z"):
            return ascii - UInt8(ascii: "a")
        case UInt8(ascii: "2")...UInt8(ascii: "7"):
            return ascii - UInt8(ascii: "2") + 26
        default:
            return nil
        }
    }
}
