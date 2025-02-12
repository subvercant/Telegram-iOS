import Foundation
import UIKit
import Postbox
import TelegramCore
import SwiftSignalKit
import Display
#if BUCK
import WebPImage
#else
import WebP
#endif

public struct EmojiThumbnailResourceId: MediaResourceId {
    public let emoji: String
    
    public var uniqueId: String {
        return "emoji-thumb-\(self.emoji)"
    }
    
    public var hashValue: Int {
        return self.emoji.hashValue
    }
    
    public func isEqual(to: MediaResourceId) -> Bool {
        if let to = to as? EmojiThumbnailResourceId {
            return self.emoji == to.emoji
        } else {
            return false
        }
    }
}

public class EmojiThumbnailResource: TelegramMediaResource {
    public let emoji: String
    
    public init(emoji: String) {
        self.emoji = emoji
    }
    
    public required init(decoder: PostboxDecoder) {
        self.emoji = decoder.decodeStringForKey("e", orElse: "")
    }
    
    public func encode(_ encoder: PostboxEncoder) {
        encoder.encodeString(self.emoji, forKey: "e")
    }
    
    public var id: MediaResourceId {
        return EmojiThumbnailResourceId(emoji: self.emoji)
    }
    
    public func isEqual(to: MediaResource) -> Bool {
        if let to = to as? EmojiThumbnailResource {
            return self.emoji == to.emoji
        } else {
            return false
        }
    }
}

public struct EmojiSpriteResourceId: MediaResourceId {
    public let packId: UInt8
    public let stickerId: UInt8
    
    public var uniqueId: String {
        return "emoji-sprite-\(self.packId)-\(self.stickerId)"
    }
    
    public var hashValue: Int {
        return self.packId.hashValue &* 31 &+ self.stickerId.hashValue
    }
    
    public func isEqual(to: MediaResourceId) -> Bool {
        if let to = to as? EmojiSpriteResourceId {
            return self.packId == to.packId && self.stickerId == to.stickerId
        } else {
            return false
        }
    }
}

public class EmojiSpriteResource: TelegramMediaResource {
    public let packId: UInt8
    public let stickerId: UInt8
    
    public init(packId: UInt8, stickerId: UInt8) {
        self.packId = packId
        self.stickerId = stickerId
    }
    
    public required init(decoder: PostboxDecoder) {
        self.packId = UInt8(decoder.decodeInt32ForKey("p", orElse: 0))
        self.stickerId = UInt8(decoder.decodeInt32ForKey("s", orElse: 0))
    }
    
    public func encode(_ encoder: PostboxEncoder) {
        encoder.encodeInt32(Int32(self.packId), forKey: "p")
        encoder.encodeInt32(Int32(self.stickerId), forKey: "s")
    }
    
    public var id: MediaResourceId {
        return EmojiSpriteResourceId(packId: self.packId, stickerId: self.stickerId)
    }
    
    public func isEqual(to: MediaResource) -> Bool {
        if let to = to as? EmojiSpriteResource {
            return self.packId == to.packId && self.stickerId == to.stickerId
        } else {
            return false
        }
    }
}

private var emojiMapping: [String: (UInt8, UInt8, UInt8)] = {
    let path = frameworkBundle.path(forResource: "Emoji", ofType: "mapping")!
    
    var mapping: [String: (UInt8, UInt8, UInt8)] = [:]
    if let data = try? Data(contentsOf: URL(fileURLWithPath: path)) {
        let buffer = ReadBuffer(data: data)
        var count: Int32 = 0
        buffer.read(&count, offset: 0, length: 4)
        if count > 0 {
            for i in 0 ..< count {
                var length: UInt8 = 0
                buffer.read(&length, offset: 0, length: 1)
                let data = Data(bytes: buffer.memory.assumingMemoryBound(to: UInt8.self).advanced(by: buffer.offset), count: Int(length))
                buffer.skip(Int(length))
                var packId: UInt8 = 0
                buffer.read(&packId, offset: 0, length: 1)
                var stickerId: UInt8 = 0
                buffer.read(&stickerId, offset: 0, length: 1)
                var tileId: UInt8 = 0
                buffer.read(&tileId, offset: 0, length: 1)
                
                if let emoji = String(data: data, encoding: .utf8) {
                    mapping[emoji] = (packId, stickerId, tileId)
                }
            }
        }
    }
    return mapping
}()

private func matchingEmojiEntry(_ emoji: String) -> (UInt8, UInt8, UInt8)? {
    if let entry = emojiMapping[emoji] {
        return entry
    }
    var trimmedEmoji: String?
    if emoji.unicodeScalars.count > 0 {
        if emoji.unicodeScalars.count > 1 {
            if emoji.unicodeScalars[emoji.unicodeScalars.index(after: emoji.unicodeScalars.startIndex)] == "\u{fe0f}" {
                var scalars = emoji.unicodeScalars
                scalars.remove(at: emoji.unicodeScalars.index(after: emoji.unicodeScalars.startIndex))
                if let entry = emojiMapping[String(scalars)] {
                    return entry
                }
            }
            trimmedEmoji = String(emoji.unicodeScalars.prefix(emoji.unicodeScalars.count - 1))
            if let trimmedEmoji = trimmedEmoji, let entry = emojiMapping[trimmedEmoji] {
                return entry
            }
        }
        if let entry = emojiMapping["\(emoji)\u{fe0f}"] {
            return entry
        }
    }
    var special: String?
    if emoji == "\u{01f48f}" {
        special = "👩‍❤️‍💋‍👨"
    } else if emoji == "\u{01f491}" {
        special = "👩‍❤️‍👨"
    } else if emoji == "\u{01f46a}" {
        special = "👨‍👩‍👦"
    }
    if let special = special, let entry = emojiMapping[special] {
        return entry
    }
    
    let manSuffix = "\u{200d}\u{2642}\u{fe0f}"
    let womanSuffix = "\u{200d}\u{2640}\u{fe0f}"
    var preferredSuffix = womanSuffix
    
    let defaultMaleEmojis = ["\u{01f46e}", "\u{01f473}", "\u{1f477}", "\u{1f482}", "\u{01f575}", "\u{01f471}", "\u{01f647}", "\u{01f6b6}", "\u{01f3c3}", "\u{01f3cc}", "\u{01f3c4}", "\u{01f3ca}", "\u{26f9}", "\u{01f3cb}", "\u{01f6b4}", "\u{01f6b5}"]
    if defaultMaleEmojis.contains(emoji) {
        preferredSuffix = manSuffix
    }
    if let trimmedEmoji = trimmedEmoji, defaultMaleEmojis.contains(trimmedEmoji) {
        preferredSuffix = manSuffix
    }
    
    if let entry = emojiMapping["\(emoji)\(preferredSuffix)"] {
        return entry
    }
    if let trimmedEmoji = trimmedEmoji, let entry = emojiMapping["\(trimmedEmoji)\(preferredSuffix)"] {
        return entry
    }
    return nil
}

func messageTextIsElligibleForLargeEmoji(_ emoji: String) -> Bool {
    for emoji in emoji.emojis {
        if let _ = matchingEmojiEntry(emoji) {
        } else {
            return false
        }
    }
    return true
}

func largeEmoji(postbox: Postbox, emoji: String, outline: Bool = true) -> Signal<(TransformImageArguments) -> DrawingContext?, NoError> {
    var dataSignals: [Signal<MediaResourceData, NoError>] = []
    for emoji in emoji.emojis {
        let thumbnailResource = EmojiThumbnailResource(emoji: emoji)
        let thumbnailRepresentation = CachedEmojiThumbnailRepresentation(outline: outline)
        let thumbnailSignal = postbox.mediaBox.cachedResourceRepresentation(thumbnailResource, representation: thumbnailRepresentation, complete: true, fetch: true)
        
        if let entry = matchingEmojiEntry(emoji) {
            let spriteResource = EmojiSpriteResource(packId: entry.0, stickerId: entry.1)
            let representation = CachedEmojiRepresentation(tile: entry.2, outline: outline)
            let signal: Signal<MediaResourceData?, NoError> = .single(nil) |> then(postbox.mediaBox.cachedResourceRepresentation(spriteResource, representation: representation, complete: true, fetch: true) |> map(Optional.init))
            
            let dataSignal = thumbnailSignal
            |> mapToSignal { thumbnailData -> Signal<MediaResourceData, NoError> in
                return signal
                |> map { data in
                    if let data = data {
                        return data
                    } else {
                        return thumbnailData
                    }
                }
            }
            dataSignals.append(dataSignal)
        } else {
            dataSignals.append(thumbnailSignal)
        }
    }

    return combineLatest(queue: nil, dataSignals)
    |> map { datas in
        return { arguments in
            let context = DrawingContext(size: arguments.drawingSize, clear: true)
            
            var sourceImages: [UIImage] = []
            for resourceData in datas {
                if let data = try? Data(contentsOf: URL(fileURLWithPath: resourceData.path), options: []), let image = UIImage(data: data, scale: UIScreen.main.scale) {
                    sourceImages.append(image)
                }
            }
            
            context.withFlippedContext { c in
                var offset: CGFloat = 12.0
                for image in sourceImages {
                    c.draw(image.cgImage!, in: CGRect(origin: CGPoint(x: offset, y: floor((arguments.drawingSize.height -
                    image.size.height) / 2.0)), size: image.size))
                    offset += 52.0 + 7.0
                }
            }
            
            return context
        }
    }
}

private final class Buffer {
    var data = Data()
}

func fetchEmojiSpriteResource(postbox: Postbox, network: Network, resource: EmojiSpriteResource) -> Signal<MediaResourceDataFetchResult, MediaResourceDataFetchError> {
    let packName = "P\(resource.packId)_by_AEStickerBot"
    
    return loadedStickerPack(postbox: postbox, network: network, reference: .name(packName), forceActualized: false)
    |> introduceError(MediaResourceDataFetchError.self)
    |> mapToSignal { result -> Signal<MediaResourceDataFetchResult, MediaResourceDataFetchError> in
        switch result {
            case let .result(_, items, _):
                if let sticker = items[Int(resource.stickerId)] as? StickerPackItem {
                    return Signal { subscriber in
                        guard let fetchResource = postbox.mediaBox.fetchResource else {
                            return EmptyDisposable
                        }

                        subscriber.putNext(.reset)

                        let fetch = fetchResource(sticker.file.resource, .single([(0 ..< Int.max, .default)]), nil)
                        let buffer = Atomic<Buffer>(value: Buffer())
                        let disposable = fetch.start(next: { result in
                            switch result {
                            case .reset:
                                let _ = buffer.with { buffer in
                                    buffer.data.count = 0
                                }
                            case .resourceSizeUpdated:
                                break
                            case .progressUpdated:
                                break
                            case let .moveLocalFile(path):
                                if let data = try? Data(contentsOf: URL(fileURLWithPath: path)) {
                                    let _ = buffer.with { buffer in
                                        buffer.data = data
                                    }
                                    let _ = try? FileManager.default.removeItem(atPath: path)
                                }
                            case let .moveTempFile(file):
                                if let data = try? Data(contentsOf: URL(fileURLWithPath: file.path)) {
                                    let _ = buffer.with { buffer in
                                        buffer.data = data
                                    }
                                }
                                TempBox.shared.dispose(file)
                            case .copyLocalItem:
                                assertionFailure()
                                break
                            case let .replaceHeader(data, range):
                                let _ = buffer.with { buffer in
                                    if buffer.data.count < range.count {
                                        buffer.data.count = range.count
                                    }
                                    buffer.data.withUnsafeMutableBytes { (bytes: UnsafeMutablePointer<UInt8>) -> Void in
                                        data.copyBytes(to: bytes, from: range)
                                    }
                                }
                            case let .dataPart(resourceOffset, data, range, _):
                                let _ = buffer.with { buffer in
                                    if buffer.data.count < resourceOffset + range.count {
                                        buffer.data.count = resourceOffset + range.count
                                    }
                                    buffer.data.withUnsafeMutableBytes { (bytes: UnsafeMutablePointer<UInt8>) -> Void in
                                        data.copyBytes(to: bytes.advanced(by: resourceOffset), from: range)
                                    }
                                }
                            }
                        }, completed: {
                            let image = buffer.with { buffer -> UIImage? in
                                return WebP.convert(fromWebP: buffer.data)
                            }
                            if let image = image, let data = UIImagePNGRepresentation(image) {
                                subscriber.putNext(.dataPart(resourceOffset: 0, data: data, range: 0 ..< data.count, complete: true))
                                subscriber.putCompletion()
                            }
                        })

                        return ActionDisposable {
                            disposable.dispose()
                        }
                    }
                } else {
                    return .complete()
                }

            default:
                return .complete()
        }
    }
}
