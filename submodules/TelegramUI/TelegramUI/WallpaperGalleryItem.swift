import Foundation
import UIKit
import Display
import AsyncDisplayKit
import SwiftSignalKit
import Postbox
import TelegramCore
import LegacyComponents
import TelegramPresentationData
import TelegramUIPreferences

struct WallpaperGalleryItemArguments {
    let colorPreview: Bool
    let isColorsList: Bool
    let patternEnabled: Bool
    
    init(colorPreview: Bool = false, isColorsList: Bool = false, patternEnabled: Bool = false) {
        self.colorPreview = colorPreview
        self.isColorsList = isColorsList
        self.patternEnabled = patternEnabled
    }
}

class WallpaperGalleryItem: GalleryItem {
    let context: AccountContext
    let entry: WallpaperGalleryEntry
    let arguments: WallpaperGalleryItemArguments
    
    init(context: AccountContext, entry: WallpaperGalleryEntry, arguments: WallpaperGalleryItemArguments) {
        self.context = context
        self.entry = entry
        self.arguments = arguments
    }
    
    func node() -> GalleryItemNode {
        let node = WallpaperGalleryItemNode(context: self.context)
        node.setEntry(self.entry, arguments: self.arguments)
        return node
    }
    
    func updateNode(node: GalleryItemNode) {
        if let node = node as? WallpaperGalleryItemNode {
            node.setEntry(self.entry, arguments: self.arguments)
        }
    }
    
    func thumbnailItem() -> (Int64, GalleryThumbnailItem)? {
        return nil
    }
}

private let progressDiameter: CGFloat = 50.0
private let motionAmount: CGFloat = 32.0

private func reference(for resource: MediaResource, media: Media, message: Message?) -> MediaResourceReference {
    if let message = message {
        return .media(media: .message(message: MessageReference(message), media: media), resource: resource)
    }
    return .wallpaper(resource: resource)
}

final class WallpaperGalleryItemNode: GalleryItemNode {
    private let context: AccountContext
    var entry: WallpaperGalleryEntry?
    private var colorPreview: Bool = false
    private var contentSize: CGSize?
    private var arguments = WallpaperGalleryItemArguments()
    
    let wrapperNode: ASDisplayNode
    let imageNode: TransformImageNode
    private let statusNode: RadialStatusNode
    private let blurredNode: BlurredImageNode
    let cropNode: WallpaperCropNode
    
    private var blurButtonNode: WallpaperOptionButtonNode
    private var motionButtonNode: WallpaperOptionButtonNode
    private var patternButtonNode: WallpaperOptionButtonNode
    
    fileprivate let _ready = Promise<Void>()
    private let fetchDisposable = MetaDisposable()
    private let statusDisposable = MetaDisposable()
    private let colorDisposable = MetaDisposable()
    
    let subtitle = Promise<String?>(nil)
    let status = Promise<MediaResourceStatus>(.Local)
    let actionButton = Promise<UIBarButtonItem?>(nil)
    var action: (() -> Void)?
    var requestPatternPanel: ((Bool) -> Void)?
    
    private var validLayout: ContainerViewLayout?
    private var validOffset: CGFloat?
    
    init(context: AccountContext) {
        self.context = context
        
        self.wrapperNode = ASDisplayNode()
        self.imageNode = TransformImageNode()
        self.imageNode.contentAnimations = .subsequentUpdates
        self.cropNode = WallpaperCropNode()
        self.statusNode = RadialStatusNode(backgroundNodeColor: UIColor(white: 0.0, alpha: 0.6))
        self.statusNode.frame = CGRect(x: 0.0, y: 0.0, width: progressDiameter, height: progressDiameter)
        self.statusNode.isUserInteractionEnabled = false
        
        self.blurredNode = BlurredImageNode()
        
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        self.blurButtonNode = WallpaperOptionButtonNode(title: presentationData.strings.WallpaperPreview_Blurred, value: .check(false))
        self.blurButtonNode.setEnabled(false)
        self.motionButtonNode = WallpaperOptionButtonNode(title: presentationData.strings.WallpaperPreview_Motion, value: .check(false))
        self.motionButtonNode.setEnabled(false)
        self.patternButtonNode = WallpaperOptionButtonNode(title: presentationData.strings.WallpaperPreview_Pattern, value: .check(false))
        self.patternButtonNode.setEnabled(false)
        
        super.init()
        
        self.clipsToBounds = true
        self.backgroundColor = .black
        
        self.imageNode.imageUpdated = { [weak self] _ in
            self?._ready.set(.single(Void()))
        }
        
        self.imageNode.view.contentMode = .scaleAspectFill
        self.imageNode.clipsToBounds = true
        
        self.addSubnode(self.wrapperNode)
        self.addSubnode(self.statusNode)
        
        self.addSubnode(self.blurButtonNode)
        self.addSubnode(self.motionButtonNode)
        self.addSubnode(self.patternButtonNode)
        
        self.blurButtonNode.addTarget(self, action: #selector(self.toggleBlur), forControlEvents: .touchUpInside)
        self.motionButtonNode.addTarget(self, action: #selector(self.toggleMotion), forControlEvents: .touchUpInside)
        self.patternButtonNode.addTarget(self, action: #selector(self.togglePattern), forControlEvents: .touchUpInside)
    }
    
    deinit {
        self.fetchDisposable.dispose()
        self.statusDisposable.dispose()
        self.colorDisposable.dispose()
    }
    
    var cropRect: CGRect? {
        guard let entry = self.entry else {
            return nil
        }
        switch entry {
            case .asset, .contextResult:
                return self.cropNode.cropRect
            default:
                return nil
        }
    }
    
    override func ready() -> Signal<Void, NoError> {
        return self._ready.get()
    }
    
    @objc private func actionPressed() {
        self.action?()
    }
    
    func setEntry(_ entry: WallpaperGalleryEntry, arguments: WallpaperGalleryItemArguments) {
        let previousArguments = self.arguments
        self.arguments = arguments
        
        if self.arguments.colorPreview != previousArguments.colorPreview {
            if self.arguments.colorPreview {
                self.imageNode.contentAnimations = []
            } else {
                self.imageNode.contentAnimations = .subsequentUpdates
            }
        }
        
        if self.entry != entry || self.arguments.colorPreview != previousArguments.colorPreview {
            let previousEntry = self.entry
            self.entry = entry
            if previousEntry != entry {
                self.preparePatternEditing()
            }
            
            self.patternButtonNode.isSelected = self.arguments.patternEnabled
            
            let imagePromise = Promise<UIImage?>()
            
            let signal: Signal<(TransformImageArguments) -> DrawingContext?, NoError>
            let fetchSignal: Signal<FetchResourceSourceType, FetchResourceError>
            let statusSignal: Signal<MediaResourceStatus, NoError>
            let subtitleSignal: Signal<String?, NoError>
            var actionSignal: Signal<UIBarButtonItem?, NoError> = .single(nil)
            var colorSignal: Signal<UIColor, NoError> = serviceColor(from: imagePromise.get())
            var color: UIColor?
            
            let displaySize: CGSize
            let contentSize: CGSize
            
            let presentationData = self.context.sharedContext.currentPresentationData.with { $0 }
            let defaultAction = UIBarButtonItem(image: generateTintedImage(image: UIImage(bundleImageName: "Chat/Input/Accessory Panels/MessageSelectionAction"), color: presentationData.theme.rootController.navigationBar.accentTextColor), style: .plain, target: self, action: #selector(self.actionPressed))
            let progressAction = UIBarButtonItem(customDisplayNode: ProgressNavigationButtonNode(color: presentationData.theme.rootController.navigationBar.accentTextColor))
            
            var isBlurrable = true
            
            switch entry {
                case let .wallpaper(wallpaper, message):
                    switch wallpaper {
                        case .builtin:
                            displaySize = CGSize(width: 1308.0, height: 2688.0).fitted(CGSize(width: 1280.0, height: 1280.0)).dividedByScreenScale().integralFloor
                            contentSize = displaySize
                            signal = settingsBuiltinWallpaperImage(account: context.account)
                            fetchSignal = .complete()
                            statusSignal = .single(.Local)
                            subtitleSignal = .single(nil)
                            colorSignal = chatServiceBackgroundColor(wallpaper: wallpaper, mediaBox: self.context.account.postbox.mediaBox)
                            isBlurrable = false
                        case let .color(color):
                            displaySize = CGSize(width: 1.0, height: 1.0)
                            contentSize = displaySize
                            signal = solidColor(UIColor(rgb: UInt32(bitPattern: color)))
                            fetchSignal = .complete()
                            statusSignal = .single(.Local)
                            subtitleSignal = .single(nil)
                            actionSignal = .single(defaultAction)
                            colorSignal = chatServiceBackgroundColor(wallpaper: wallpaper, mediaBox: self.context.account.postbox.mediaBox)
                            isBlurrable = false
                            //self.backgroundColor = UIColor(rgb: UInt32(bitPattern: color))
                        case let .file(file):
                            let dimensions = file.file.dimensions ?? CGSize(width: 100.0, height: 100.0)
                            contentSize = dimensions
                            displaySize = dimensions.dividedByScreenScale().integralFloor
                            
                            var convertedRepresentations: [ImageRepresentationWithReference] = []
                            for representation in file.file.previewRepresentations {
                                convertedRepresentations.append(ImageRepresentationWithReference(representation: representation, reference: reference(for: representation.resource, media: file.file, message: message)))
                            }
                            convertedRepresentations.append(ImageRepresentationWithReference(representation: .init(dimensions: dimensions, resource: file.file.resource), reference: reference(for: file.file.resource, media: file.file, message: message)))
                            
                            if file.isPattern {
                                var patternColor = UIColor(rgb: 0xd6e2ee, alpha: 0.5)
                                var patternIntensity: CGFloat = 0.5
                                if let color = file.settings.color {
                                    if let intensity = file.settings.intensity {
                                        patternIntensity = CGFloat(intensity) / 100.0
                                    }
                                    patternColor = UIColor(rgb: UInt32(bitPattern: color), alpha: patternIntensity)
                                }
                                
                                self.backgroundColor = patternColor.withAlphaComponent(1.0)
                                
                                if let previousEntry = previousEntry, case let .wallpaper(wallpaper, _) = previousEntry, case let .file(previousFile) = wallpaper, file.id == previousFile.id && (file.settings.color != previousFile.settings.color || file.settings.intensity != previousFile.settings.intensity) && self.colorPreview == self.arguments.colorPreview {
                                    
                                    let makeImageLayout = self.imageNode.asyncLayout()
                                    Queue.concurrentDefaultQueue().async {
                                        let apply = makeImageLayout(TransformImageArguments(corners: ImageCorners(), imageSize: displaySize, boundingSize: displaySize, intrinsicInsets: UIEdgeInsets(), emptyColor: patternColor))
                                        Queue.mainQueue().async {
                                            if self.colorPreview {
                                                apply()
                                            }
                                        }
                                    }
                                    return
                                } else if let offset = self.validOffset, self.arguments.colorPreview && fabs(offset) > 0.0 {
                                    return
                                }
                                else {
                                    color = patternColor
                                }
                                
                                self.colorPreview = self.arguments.colorPreview
                                
                                signal = patternWallpaperImage(account: context.account, accountManager: context.sharedContext.accountManager, representations: convertedRepresentations, mode: self.arguments.colorPreview ? .fastScreen : .screen, autoFetchFullSize: true)
                                colorSignal = chatServiceBackgroundColor(wallpaper: wallpaper, mediaBox: context.account.postbox.mediaBox)
                                
                                isBlurrable = false
                            } else {
                                let fileReference: FileMediaReference
                                if let message = message {
                                    fileReference = .message(message: MessageReference(message), media: file.file)
                                } else {
                                    fileReference = .standalone(media: file.file)
                                }
                                signal = wallpaperImage(account: context.account, accountManager: context.sharedContext.accountManager, fileReference: fileReference, representations: convertedRepresentations, alwaysShowThumbnailFirst: true, autoFetchFullSize: false)
                            }
                            fetchSignal = fetchedMediaResource(postbox: context.account.postbox, reference: convertedRepresentations[convertedRepresentations.count - 1].reference)
                            let account = context.account
                            statusSignal = context.sharedContext.accountManager.mediaBox.resourceStatus(file.file.resource)
                            |> take(1)
                            |> mapToSignal { status -> Signal<MediaResourceStatus, NoError> in
                                if case .Local = status {
                                    return .single(status)
                                } else {
                                    return account.postbox.mediaBox.resourceStatus(file.file.resource)
                                }
                            }
                            if let fileSize = file.file.size {
                                subtitleSignal = .single(dataSizeString(fileSize))
                            } else {
                                subtitleSignal = .single(nil)
                            }
                            actionSignal = .single(defaultAction)
                        case let .image(representations, _):
                            if let largestSize = largestImageRepresentation(representations) {
                                contentSize = largestSize.dimensions
                                displaySize = largestSize.dimensions.dividedByScreenScale().integralFloor
                                
                                let convertedRepresentations: [ImageRepresentationWithReference] = representations.map({ ImageRepresentationWithReference(representation: $0, reference: .wallpaper(resource: $0.resource)) })
                                signal = wallpaperImage(account: context.account, accountManager: context.sharedContext.accountManager, representations: convertedRepresentations, alwaysShowThumbnailFirst: true, autoFetchFullSize: false)
                                
                                if let largestIndex = convertedRepresentations.index(where: { $0.representation == largestSize }) {
                                    fetchSignal = fetchedMediaResource(postbox: context.account.postbox, reference: convertedRepresentations[largestIndex].reference)
                                } else {
                                    fetchSignal = .complete()
                                }
                                let account = context.account
                                statusSignal = context.sharedContext.accountManager.mediaBox.resourceStatus(largestSize.resource)
                                |> take(1)
                                |> mapToSignal { status -> Signal<MediaResourceStatus, NoError> in
                                    if case .Local = status {
                                        return .single(status)
                                    } else {
                                        return account.postbox.mediaBox.resourceStatus(largestSize.resource)
                                    }
                                }
                                if let fileSize = largestSize.resource.size {
                                    subtitleSignal = .single(dataSizeString(fileSize))
                                } else {
                                    subtitleSignal = .single(nil)
                                }
                                
                                actionSignal = self.context.wallpaperUploadManager!.stateSignal()
                                |> filter { state in
                                    return state.wallpaper == wallpaper
                                }
                                |> map { state in
                                    switch state {
                                        case .uploading:
                                            return progressAction
                                        case .uploaded:
                                            return defaultAction
                                        default:
                                            return nil
                                    }
                                }
                            } else {
                                displaySize = CGSize(width: 1.0, height: 1.0)
                                contentSize = displaySize
                                signal = .never()
                                fetchSignal = .complete()
                                statusSignal = .single(.Local)
                                subtitleSignal = .single(nil)
                            }
                    }
                    self.cropNode.removeFromSupernode()
                case let .asset(asset):
                    let dimensions = CGSize(width: asset.pixelWidth, height: asset.pixelHeight)
                    contentSize = dimensions
                    displaySize = dimensions.dividedByScreenScale().integralFloor
                    signal = photoWallpaper(postbox: context.account.postbox, photoLibraryResource: PhotoLibraryMediaResource(localIdentifier: asset.localIdentifier, uniqueId: arc4random64()))
                    fetchSignal = .complete()
                    statusSignal = .single(.Local)
                    subtitleSignal = .single(nil)
                    self.wrapperNode.addSubnode(self.cropNode)
                case let .contextResult(result):
                    var imageDimensions: CGSize?
                    var imageResource: TelegramMediaResource?
                    var thumbnailDimensions: CGSize?
                    var thumbnailResource: TelegramMediaResource?
                    switch result {
                    case let .externalReference(_, _, _, _, _, _, content, thumbnail, _):
                        if let content = content {
                            imageResource = content.resource
                        }
                        if let thumbnail = thumbnail {
                            thumbnailResource = thumbnail.resource
                            thumbnailDimensions = thumbnail.dimensions
                        }
                        if let dimensions = content?.dimensions {
                            imageDimensions = dimensions
                        }
                    case let .internalReference(_, _, _, _, _, image, _, _):
                        if let image = image {
                            if let imageRepresentation = imageRepresentationLargerThan(image.representations, size: CGSize(width: 1000.0, height: 800.0)) {
                                imageDimensions = imageRepresentation.dimensions
                                imageResource = imageRepresentation.resource
                            }
                            if let thumbnailRepresentation = smallestImageRepresentation(image.representations) {
                                thumbnailDimensions = thumbnailRepresentation.dimensions
                                thumbnailResource = thumbnailRepresentation.resource
                            }
                        }
                    }
                    
                    if let imageResource = imageResource, let imageDimensions = imageDimensions {
                        contentSize = imageDimensions
                        displaySize = imageDimensions.dividedByScreenScale().integralFloor
                        
                        var representations: [TelegramMediaImageRepresentation] = []
                        if let thumbnailResource = thumbnailResource, let thumbnailDimensions = thumbnailDimensions {
                            representations.append(TelegramMediaImageRepresentation(dimensions: thumbnailDimensions, resource: thumbnailResource))
                        }
                        representations.append(TelegramMediaImageRepresentation(dimensions: imageDimensions, resource: imageResource))
                        let tmpImage = TelegramMediaImage(imageId: MediaId(namespace: 0, id: 0), representations: representations, immediateThumbnailData: nil, reference: nil, partialReference: nil)
                        
                        signal = chatMessagePhoto(postbox: context.account.postbox, photoReference: .standalone(media: tmpImage))
                        fetchSignal = fetchedMediaResource(postbox: context.account.postbox, reference: .media(media: .standalone(media: tmpImage), resource: imageResource))
                        statusSignal = context.account.postbox.mediaBox.resourceStatus(imageResource)
                    } else {
                        displaySize = CGSize(width: 1.0, height: 1.0)
                        contentSize = displaySize
                        signal = .never()
                        fetchSignal = .complete()
                        statusSignal = .single(.Local)
                    }
                    subtitleSignal = .single(nil)
                    self.wrapperNode.addSubnode(self.cropNode)
            }
            self.contentSize = contentSize
            
            if self.cropNode.supernode == nil {
                self.imageNode.contentMode = .scaleAspectFill
                self.wrapperNode.addSubnode(self.imageNode)
            } else {
                self.imageNode.contentMode = .scaleToFill
            }
            
            self.imageNode.setSignal(signal, dispatchOnDisplayLink: false)
            self.imageNode.asyncLayout()(TransformImageArguments(corners: ImageCorners(), imageSize: displaySize, boundingSize: displaySize, intrinsicInsets: UIEdgeInsets(), emptyColor: color))()
            self.imageNode.imageUpdated = { [weak self] image in
                if let strongSelf = self {
                    var image = isBlurrable ? image : nil
                    if let imageToScale = image {
                        let actualSize = CGSize(width: imageToScale.size.width * imageToScale.scale, height: imageToScale.size.height * imageToScale.scale)
                        if actualSize.width > 1280.0 || actualSize.height > 1280.0 {
                            image = TGScaleImageToPixelSize(image, actualSize.fitted(CGSize(width: 1280.0, height: 1280.0)))
                        }
                    }
                    strongSelf.blurredNode.image = image
                    imagePromise.set(.single(image))
                }
            }
            self.fetchDisposable.set(fetchSignal.start())
            
            let statusForegroundColor = UIColor.white
            self.statusDisposable.set((statusSignal
            |> deliverOnMainQueue).start(next: { [weak self] status in
                if let strongSelf = self {
                    let state: RadialStatusNodeState
                    var local = false
                    switch status {
                        case let .Fetching(_, progress):
                            let adjustedProgress = max(progress, 0.027)
                            state = .progress(color: statusForegroundColor, lineWidth: nil, value: CGFloat(adjustedProgress), cancelEnabled: false)
                        case .Local:
                            state = .none
                            local = true
                        case .Remote:
                            state = .progress(color: statusForegroundColor, lineWidth: nil, value: 0.027, cancelEnabled: false)
                    }
                    strongSelf.statusNode.transitionToState(state, completion: {})
                    
                    strongSelf.blurButtonNode.setEnabled(local)
                    strongSelf.motionButtonNode.setEnabled(local)
                    strongSelf.patternButtonNode.setEnabled(local)
                }
            }))
            
            self.subtitle.set(subtitleSignal |> deliverOnMainQueue)
            self.status.set(statusSignal |> deliverOnMainQueue)
            self.actionButton.set(actionSignal |> deliverOnMainQueue)
            
            self.colorDisposable.set((colorSignal
            |> deliverOnMainQueue).start(next: { [weak self] color in
                self?.statusNode.backgroundNodeColor = color
                self?.patternButtonNode.buttonColor = color
                self?.blurButtonNode.buttonColor = color
                self?.motionButtonNode.buttonColor = color
            }))
            
            if let layout = self.validLayout {
                //self.updateButtonsLayout(layout: layout, offset: CGPoint(), transition: animated ? .animated(duration: 0.2, curve: .easeInOut) : .immediate)
            }
        } else if self.arguments.patternEnabled != previousArguments.patternEnabled {
            self.patternButtonNode.isSelected = self.arguments.patternEnabled
            
            if let layout = self.validLayout {
                self.updateButtonsLayout(layout: layout, offset: CGPoint(), transition: .immediate)
            }
        }
    }
    
    override func screenFrameUpdated(_ frame: CGRect) {
        let offset = -frame.minX
        guard self.validOffset != offset else {
            return
        }
        self.validOffset = offset
        if let layout = self.validLayout {
            self.updateWrapperLayout(layout: layout, offset: offset, transition: .immediate)
            self.updateButtonsLayout(layout: layout, offset: CGPoint(x: offset, y: 0.0), transition: .immediate)
        }
    }
    
    func updateDismissTransition(_ value: CGFloat) {
        if let layout = self.validLayout {
            self.updateButtonsLayout(layout: layout, offset: CGPoint(x: 0.0, y: value), transition: .immediate)
        }
    }
    
    var options: WallpaperPresentationOptions {
        get {
            var options: WallpaperPresentationOptions = []
            if self.blurButtonNode.isSelected {
                options.insert(.blur)
            }
            if self.motionButtonNode.isSelected {
                options.insert(.motion)
            }
            return options
        }
        set {
            self.setBlurEnabled(newValue.contains(.blur), animated: false)
            self.blurButtonNode.isSelected = newValue.contains(.blur)
            
            self.setMotionEnabled(newValue.contains(.motion), animated: false)
            self.motionButtonNode.isSelected = newValue.contains(.motion)
        }
    }
    
    @objc func toggleBlur() {
        let value = !self.blurButtonNode.isSelected
        self.blurButtonNode.setSelected(value, animated: true)
        self.setBlurEnabled(value, animated: true)
    }
    
    func setBlurEnabled(_ enabled: Bool, animated: Bool) {
        let blurRadius: CGFloat = 45.0
        
        var animated = animated
        if animated, let layout = self.validLayout {
            animated = min(layout.size.width, layout.size.height) > 321.0
        } else {
            animated = false
        }
        
        if enabled {
            if self.blurredNode.supernode == nil {
                if self.cropNode.supernode != nil {
                    self.blurredNode.frame = self.imageNode.bounds
                    self.imageNode.addSubnode(self.blurredNode)
                } else {
                    self.blurredNode.frame = self.imageNode.bounds
                    self.imageNode.addSubnode(self.blurredNode)
                }
            }
            
            if animated {
                self.blurredNode.blurView.blurRadius = 0.0
                UIView.animate(withDuration: 0.3, delay: 0.0, options: UIViewAnimationOptions(rawValue: 7 << 16), animations: {
                    self.blurredNode.blurView.blurRadius = blurRadius
                }, completion: nil)
            } else {
                self.blurredNode.blurView.blurRadius = blurRadius
            }
        } else {
            if self.blurredNode.supernode != nil {
                if animated {
                    UIView.animate(withDuration: 0.3, delay: 0.0, options: UIViewAnimationOptions(rawValue: 7 << 16), animations: {
                        self.blurredNode.blurView.blurRadius = 0.0
                    }, completion: { finished in
                        if finished {
                            self.blurredNode.removeFromSupernode()
                        }
                    })
                } else {
                    self.blurredNode.removeFromSupernode()
                }
            }
        }
    }
    
    @objc func toggleMotion() {
        let value = !self.motionButtonNode.isSelected
        self.motionButtonNode.setSelected(value, animated: true)
        self.setMotionEnabled(value, animated: true)
    }
    
    var isPatternEnabled: Bool {
        return self.patternButtonNode.isSelected
    }
    
    @objc func togglePattern() {
        let value = !self.patternButtonNode.isSelected
        self.patternButtonNode.setSelected(value, animated: true)
        
        self.requestPatternPanel?(value)
    }
    
    private func preparePatternEditing() {
        if let entry = self.entry, case let .wallpaper(wallpaper, _) = entry, case let .file(file) = wallpaper {
            if let size = file.file.dimensions?.fitted(CGSize(width: 1280.0, height: 1280.0)) {
                let _ = self.context.account.postbox.mediaBox.cachedResourceRepresentation(file.file.resource, representation: CachedPatternWallpaperMaskRepresentation(size: size), complete: false, fetch: true).start()
            }
        }
    }
    
    func setMotionEnabled(_ enabled: Bool, animated: Bool) {
        if enabled {
            let horizontal = UIInterpolatingMotionEffect(keyPath: "center.x", type: .tiltAlongHorizontalAxis)
            horizontal.minimumRelativeValue = motionAmount
            horizontal.maximumRelativeValue = -motionAmount
            
            let vertical = UIInterpolatingMotionEffect(keyPath: "center.y", type: .tiltAlongVerticalAxis)
            vertical.minimumRelativeValue = motionAmount
            vertical.maximumRelativeValue = -motionAmount
            
            let group = UIMotionEffectGroup()
            group.motionEffects = [horizontal, vertical]
            self.wrapperNode.view.addMotionEffect(group)
            
            let scale = (self.frame.width + motionAmount * 2.0) / self.frame.width
            if animated {
                self.wrapperNode.layer.animateScale(from: 1.0, to: scale, duration: 0.2, removeOnCompletion: false)
            } else {
                self.wrapperNode.transform = CATransform3DMakeScale(scale, scale, 1.0)
            }
        } else {
            let position = self.wrapperNode.layer.presentation()?.position
            
            for effect in self.wrapperNode.view.motionEffects {
                self.wrapperNode.view.removeMotionEffect(effect)
            }
            
            let scale = (self.frame.width + motionAmount * 2.0) / self.frame.width
            if animated {
                self.wrapperNode.layer.animateScale(from: scale, to: 1.0, duration: 0.2, removeOnCompletion: false)
                if let position = position {
                    self.wrapperNode.layer.animatePosition(from: position, to: self.wrapperNode.layer.position, duration: 0.2)
                }
            } else {
                self.wrapperNode.transform = CATransform3DIdentity
            }
        }
    }
    
    func updateWrapperLayout(layout: ContainerViewLayout, offset: CGFloat, transition: ContainedViewLayoutTransition) {
        var appliedOffset: CGFloat = 0.0
        if self.arguments.isColorsList {
            appliedOffset = offset
        }
        transition.updatePosition(node: self.wrapperNode, position: CGPoint(x: layout.size.width / 2.0 + appliedOffset, y: layout.size.height / 2.0))
    }
    
    func updateButtonsLayout(layout: ContainerViewLayout, offset: CGPoint, transition: ContainedViewLayoutTransition) {
        let patternButtonSize = self.patternButtonNode.measure(layout.size)
        let blurButtonSize = self.blurButtonNode.measure(layout.size)
        let motionButtonSize = self.motionButtonNode.measure(layout.size)
        
        let maxButtonWidth = max(patternButtonSize.width, max(blurButtonSize.width, motionButtonSize.width))
        let buttonSize = CGSize(width: maxButtonWidth, height: 30.0)
        let alpha = 1.0 - min(1.0, max(0.0, abs(offset.y) / 50.0))
        
        var additionalYOffset: CGFloat = 0.0
        if self.patternButtonNode.isSelected {
            additionalYOffset = -190.0
        }
        
        let leftButtonFrame = CGRect(origin: CGPoint(x: floor(layout.size.width / 2.0 - buttonSize.width - 10.0) + offset.x, y: layout.size.height - 49.0 - layout.intrinsicInsets.bottom - 54.0 + offset.y + additionalYOffset), size: buttonSize)
        let centerButtonFrame = CGRect(origin: CGPoint(x: floor((layout.size.width - buttonSize.width) / 2.0) + offset.x, y: layout.size.height - 49.0 - layout.intrinsicInsets.bottom - 54.0 + offset.y + additionalYOffset), size: buttonSize)
        let rightButtonFrame = CGRect(origin: CGPoint(x: ceil(layout.size.width / 2.0 + 10.0) + offset.x, y: layout.size.height - 49.0 - layout.intrinsicInsets.bottom - 54.0 + offset.y + additionalYOffset), size: buttonSize)
        
        var patternAlpha: CGFloat = 0.0
        var patternFrame = centerButtonFrame
        
        var blurAlpha: CGFloat = 0.0
        var blurFrame = centerButtonFrame
        
        var motionFrame = centerButtonFrame
        var motionAlpha: CGFloat = 0.0
        
        if let entry = self.entry {
            switch entry {
                case .asset:
                    blurAlpha = 1.0
                    blurFrame = leftButtonFrame
                    motionAlpha = 1.0
                    motionFrame = rightButtonFrame
                case .contextResult:
                    blurAlpha = 1.0
                    blurFrame = leftButtonFrame
                    motionAlpha = 1.0
                    motionFrame = rightButtonFrame
                case let .wallpaper(wallpaper, _):
                    switch wallpaper {
                        case .builtin:
                            motionAlpha = 1.0
                        case .color:
                            patternAlpha = 1.0
                            if self.patternButtonNode.isSelected {
                                patternFrame = leftButtonFrame
                                motionAlpha = 1.0
                                motionFrame = rightButtonFrame
                            }
                        case .image:
                            blurAlpha = 1.0
                            blurFrame = leftButtonFrame
                            motionAlpha = 1.0
                            motionFrame = rightButtonFrame
                        case let .file(file):
                            if file.isPattern {
                                motionAlpha = 1.0
                                if self.arguments.isColorsList {
                                    patternAlpha = 1.0
                                    if self.patternButtonNode.isSelected {
                                        patternFrame = leftButtonFrame
                                    }
                                    motionFrame = rightButtonFrame
                                }
                            } else {
                                blurAlpha = 1.0
                                blurFrame = leftButtonFrame
                                motionAlpha = 1.0
                                motionFrame = rightButtonFrame
                            }
                    }
            }
        }
        
        transition.updateFrame(node: self.patternButtonNode, frame: patternFrame)
        transition.updateAlpha(node: self.patternButtonNode, alpha: patternAlpha * alpha)
        
        transition.updateFrame(node: self.blurButtonNode, frame: blurFrame)
        transition.updateAlpha(node: self.blurButtonNode, alpha: blurAlpha * alpha)
        
        transition.updateFrame(node: self.motionButtonNode, frame: motionFrame)
        transition.updateAlpha(node: self.motionButtonNode, alpha: motionAlpha * alpha)
    }
    
    override func containerLayoutUpdated(_ layout: ContainerViewLayout, navigationBarHeight: CGFloat, transition: ContainedViewLayoutTransition) {
        super.containerLayoutUpdated(layout, navigationBarHeight: navigationBarHeight, transition: transition)
        
        var offset: CGFloat = 0.0
        if let validOffset = self.validOffset {
            offset = validOffset
        }
        
        self.wrapperNode.bounds = CGRect(origin: CGPoint(), size: layout.size)
        self.updateWrapperLayout(layout: layout, offset: offset, transition: transition)
        
        if self.cropNode.supernode == nil {
            self.imageNode.frame = self.wrapperNode.bounds
            self.blurredNode.frame = self.imageNode.frame
        } else {
            self.cropNode.frame = self.wrapperNode.bounds
            self.cropNode.containerLayoutUpdated(layout, transition: transition)
            
            if self.cropNode.supernode != nil, let contentSize = self.contentSize, self.cropNode.zoomableContent == nil {
                let fittedSize = TGScaleToFit(self.cropNode.bounds.size, contentSize)
                self.cropNode.zoomableContent = (contentSize, self.imageNode)
                self.cropNode.zoom(to: CGRect(x: (contentSize.width - fittedSize.width) / 2.0, y: (contentSize.height - fittedSize.height) / 2.0, width: fittedSize.width, height: fittedSize.height))
            }
            self.blurredNode.frame = self.imageNode.bounds
        }
        
        var additionalYOffset: CGFloat = 0.0
        if self.patternButtonNode.isSelected {
            additionalYOffset = -190.0
        }
        
        self.statusNode.frame = CGRect(x: layout.safeInsets.left + floorToScreenPixels((layout.size.width - layout.safeInsets.left - layout.safeInsets.right - progressDiameter) / 2.0), y: floorToScreenPixels((layout.size.height + additionalYOffset - progressDiameter) / 2.0), width: progressDiameter, height: progressDiameter)
        
        self.updateButtonsLayout(layout: layout, offset: CGPoint(x: offset, y: 0.0), transition: transition)
        
        self.validLayout = layout
    }
    
    override func visibilityUpdated(isVisible: Bool) {
        super.visibilityUpdated(isVisible: isVisible)
    }
}
