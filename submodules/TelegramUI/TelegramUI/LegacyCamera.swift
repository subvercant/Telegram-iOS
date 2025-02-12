import Foundation
import UIKit
import LegacyComponents
import Display
import TelegramCore
import Postbox
import SwiftSignalKit

func presentedLegacyCamera(context: AccountContext, peer: Peer, cameraView: TGAttachmentCameraView?, menuController: TGMenuSheetController?, parentController: ViewController, editingMedia: Bool, saveCapturedPhotos: Bool, mediaGrouping: Bool, initialCaption: String, sendMessagesWithSignals: @escaping ([Any]?) -> Void, recognizedQRCode: @escaping (String) -> Void = { _ in }) {
    let presentationData = context.sharedContext.currentPresentationData.with { $0 }
    let legacyController = LegacyController(presentation: .custom, theme: presentationData.theme)
    legacyController.supportedOrientations = ViewControllerSupportedOrientations(regularSize: .portrait, compactSize: .portrait)
    legacyController.statusBar.statusBarStyle = .Hide
    
    legacyController.deferScreenEdgeGestures = [.top]

    let isSecretChat = peer.id.namespace == Namespaces.Peer.SecretChat
    
    let controller: TGCameraController
    if let cameraView = cameraView, let previewView = cameraView.previewView() {
        controller = TGCameraController(context: legacyController.context, saveEditedPhotos: saveCapturedPhotos && !isSecretChat, saveCapturedMedia: saveCapturedPhotos && !isSecretChat, camera: previewView.camera, previewView: previewView, intent: TGCameraControllerGenericIntent)
        controller.inhibitMultipleCapture = editingMedia
    } else {
        controller = TGCameraController()
    }
    
    if #available(iOSApplicationExtension 11.0, iOS 11.0, *) {
    } else {
        controller.customPresentOverlayController = { [weak legacyController] generateController in
            guard let legacyController = legacyController, let generateController = generateController else {
                return
            }
            
            let presentationData = context.sharedContext.currentPresentationData.with { $0 }
            let overlayLegacyController = LegacyController(presentation: .custom, theme: presentationData.theme)
            overlayLegacyController.supportedOrientations = ViewControllerSupportedOrientations(regularSize: .portrait, compactSize: .portrait)
            overlayLegacyController.statusBar.statusBarStyle = .Hide
            
            let overlayController = generateController(overlayLegacyController.context)!
            
            overlayLegacyController.bind(controller: overlayController)
            overlayController.customDismissSelf = { [weak overlayLegacyController] in
                overlayLegacyController?.dismiss()
            }
            
            legacyController.present(overlayLegacyController, in: .window(.root))
        }
    }
    
    controller.isImportant = true
    controller.shouldStoreCapturedAssets = saveCapturedPhotos && !isSecretChat
    controller.allowCaptions = true
    controller.allowCaptionEntities = true
    controller.allowGrouping = mediaGrouping
    controller.inhibitDocumentCaptions = false
    controller.suggestionContext = legacySuggestionContext(account: context.account, peerId: peer.id)
    controller.recipientName = peer.displayTitle
    if (peer is TelegramUser) && peer.id != context.account.peerId {
        controller.hasTimer = true
    }
    
    let screenSize = parentController.view.bounds.size
    var startFrame = CGRect(x: 0, y: screenSize.height, width: screenSize.width, height: screenSize.height)
    if let cameraView = cameraView, let menuController = menuController {
        startFrame = menuController.view.convert(cameraView.previewView()!.frame, from: cameraView)
    }
    
    legacyController.bind(controller: controller)
    legacyController.controllerLoaded = { [weak controller] in
        if let controller = controller {
            cameraView?.detachPreviewView()
            controller.beginTransitionIn(from: startFrame)
            controller.view.disablesInteractiveTransitionGestureRecognizer = true
        }
    }
    
    controller.beginTransitionOut = { [weak controller, weak cameraView] in
        if let controller = controller, let cameraView = cameraView {
            cameraView.willAttachPreviewView()
            return controller.view.convert(cameraView.frame, from: cameraView.superview)
        } else {
            return CGRect()
        }
    }
    
    controller.finishedTransitionOut = { [weak cameraView, weak legacyController] in
        if let cameraView = cameraView {
            cameraView.attachPreviewView(animated: true)
        }
        legacyController?.dismiss()
    }
    
    controller.finishedWithResults = { [weak menuController, weak legacyController] overlayController, selectionContext, editingContext, currentItem in
        if let selectionContext = selectionContext, let editingContext = editingContext {
            let signals = TGCameraController.resultSignals(for: selectionContext, editingContext: editingContext, currentItem: currentItem, storeAssets: saveCapturedPhotos && !isSecretChat, saveEditedPhotos: saveCapturedPhotos && !isSecretChat, descriptionGenerator: legacyAssetPickerItemGenerator())
            sendMessagesWithSignals(signals)
        }
        
        menuController?.dismiss(animated: false)
        legacyController?.dismissWithAnimation()
    }
    
    controller.finishedWithPhoto = { [weak menuController, weak legacyController] overlayController, image, caption, entities, stickers, timer in
        if let image = image {
            let description = NSMutableDictionary()
            description["type"] = "capturedPhoto"
            description["image"] = image
            if let timer = timer {
                description["timer"] = timer
            }
            if let item = legacyAssetPickerItemGenerator()(description, caption, entities, nil) {
                sendMessagesWithSignals([SSignal.single(item)])
            }
        }
        
        menuController?.dismiss(animated: false)
        legacyController?.dismissWithAnimation()
    }
    
    controller.finishedWithVideo = { [weak menuController, weak legacyController] overlayController, videoURL, previewImage, duration, dimensions, adjustments, caption, entities, stickers, timer in
        if let videoURL = videoURL {
            let description = NSMutableDictionary()
            description["type"] = "video"
            description["url"] = videoURL.path
            if let previewImage = previewImage {
                description["previewImage"] = previewImage
            }
            if let adjustments = adjustments {
                description["adjustments"] = adjustments
            }
            description["duration"] = duration as NSNumber
            description["dimensions"] = NSValue(cgSize: dimensions)
            if let timer = timer {
                description["timer"] = timer
            }
            if let item = legacyAssetPickerItemGenerator()(description, caption, entities, nil) {
                sendMessagesWithSignals([SSignal.single(item)])
            }
        }
        menuController?.dismiss(animated: false)
        legacyController?.dismissWithAnimation()
    }
    
    controller.recognizedQRCode = { code in
        if let code = code {
            recognizedQRCode(code)
        }
    }
    
    parentController.present(legacyController, in: .window(.root))
}

func presentedLegacyShortcutCamera(context: AccountContext, saveCapturedMedia: Bool, saveEditedPhotos: Bool, mediaGrouping: Bool, parentController: ViewController) {
    let presentationData = context.sharedContext.currentPresentationData.with { $0 }
    let legacyController = LegacyController(presentation: .custom, theme: presentationData.theme)
    legacyController.supportedOrientations = ViewControllerSupportedOrientations(regularSize: .portrait, compactSize: .portrait)
    legacyController.statusBar.statusBarStyle = .Hide
    
    legacyController.deferScreenEdgeGestures = [.top]
    
    let controller = TGCameraController(context: legacyController.context, saveEditedPhotos: saveEditedPhotos, saveCapturedMedia: saveCapturedMedia)!
    controller.shortcut = false
    controller.isImportant = true
    controller.shouldStoreCapturedAssets = saveCapturedMedia
    controller.allowCaptions = true
    controller.allowCaptionEntities = true
    controller.allowGrouping = mediaGrouping
    
    let screenSize = parentController.view.bounds.size
    let startFrame = CGRect(x: 0, y: screenSize.height, width: screenSize.width, height: screenSize.height)
    
    legacyController.bind(controller: controller)
    legacyController.controllerLoaded = { [weak controller] in
        if let controller = controller {
            controller.beginTransitionIn(from: startFrame)
        }
    }
    
    controller.finishedTransitionOut = { [weak legacyController] in
        legacyController?.dismiss()
    }
    
    controller.customDismissBlock = { [weak legacyController] in
        legacyController?.dismiss()
    }
    
    controller.finishedWithResults = { [weak controller, weak parentController, weak legacyController] overlayController, selectionContext, editingContext, currentItem in
        if let selectionContext = selectionContext, let editingContext = editingContext {
            let signals = TGCameraController.resultSignals(for: selectionContext, editingContext: editingContext, currentItem: currentItem, storeAssets: saveCapturedMedia, saveEditedPhotos: saveEditedPhotos, descriptionGenerator: legacyAssetPickerItemGenerator())
            if let parentController = parentController {
                parentController.present(ShareController(context: context, subject: .fromExternal({ peerIds, text, account in
                    return legacyAssetPickerEnqueueMessages(account: account, signals: signals!)
                    |> `catch` { _ -> Signal<[EnqueueMessage], NoError> in
                        return .single([])
                    }
                    |> mapToSignal { messages -> Signal<ShareControllerExternalStatus, NoError> in
                        let resultSignals = peerIds.map({ peerId in
                            return enqueueMessages(account: account, peerId: peerId, messages: messages)
                            |> mapToSignal { _ -> Signal<ShareControllerExternalStatus, NoError> in
                                return .complete()
                            }
                        })
                        return combineLatest(resultSignals)
                        |> mapToSignal { _ -> Signal<ShareControllerExternalStatus, NoError> in
                            return .complete()
                        }
                        |> then(.single(ShareControllerExternalStatus.done))
                    }
                }), showInChat: nil, externalShare: false), in: .window(.root))
            }
        }
        
        //legacyController?.dismissWithAnimation()
    }
    
    parentController.present(legacyController, in: .window(.root))

    
    /*TGCameraControllerWindow *controllerWindow = [[TGCameraControllerWindow alloc] initWithManager:[[TGLegacyComponentsContext shared] makeOverlayWindowManager] parentController:TGAppDelegateInstance.rootController contentController:controller];
    controllerWindow.hidden = false;
    
    CGSize screenSize = TGScreenSize();
    if ([UIDevice currentDevice].userInterfaceIdiom == UIUserInterfaceIdiomPhone)
    controllerWindow.frame = CGRectMake(0, 0, screenSize.width, screenSize.height);
    
    CGRect startFrame = CGRectMake(0, screenSize.height, screenSize.width, screenSize.height);
    [controller beginTransitionInFromRect:startFrame];
    
    __weak TGCameraController *weakCameraController = controller;
    controller.finishedWithResults = ^(TGOverlayController *controller, TGMediaSelectionContext *selectionContext, TGMediaEditingContext *editingContext, id<TGMediaSelectableItem> currentItem)
    {
        __autoreleasing NSString *disabledMessage = nil;
        if (![TGApplicationFeatures isPhotoUploadEnabledForPeerType:TGApplicationFeaturePeerPrivate disabledMessage:&disabledMessage])
        {
            [TGCustomAlertView presentAlertWithTitle:TGLocalized(@"FeatureDisabled.Oops") message:disabledMessage cancelButtonTitle:TGLocalized(@"Common.OK") okButtonTitle:nil completionBlock:nil];
            return;
        }
        
        __strong TGCameraController *strongCameraController = weakCameraController;
        if (strongCameraController == nil)
        return;
        
        [TGCameraController showTargetController:[TGCameraController resultSignalsForSelectionContext:selectionContext editingContext:editingContext currentItem:currentItem storeAssets:false saveEditedPhotos:false descriptionGenerator:^id(id item, NSString *caption, NSArray *entities, __unused NSString *stickers)
            {
            if ([item isKindOfClass:[NSDictionary class]])
            {
            NSDictionary *dict = (NSDictionary *)item;
            NSString *type = dict[@"type"];
            
            if ([type isEqualToString:@"editedPhoto"])
            {
            NSMutableDictionary *result = [[NSMutableDictionary alloc] init];
            result[@"type"] = @"image";
            result[@"image"] = dict[@"image"];
            if (caption.length > 0)
            result[@"caption"] = caption;
            if (entities.count > 0)
            result[@"entities"] = entities;
            if (dict[@"stickers"] != nil)
            result[@"stickers"] = dict[@"stickers"];
            
            return result;
            }
            else if ([type isEqualToString:@"cameraVideo"])
            {
            NSMutableDictionary *result = [[NSMutableDictionary alloc] init];
            result[@"type"] = @"cameraVideo";
            result[@"url"] = dict[@"url"];
            if (dict[@"adjustments"] != nil)
            result[@"adjustments"] = dict[@"adjustments"];
            if (entities.count > 0)
            result[@"entities"] = entities;
            if (dict[@"stickers"] != nil)
            result[@"stickers"] = dict[@"stickers"];
            if (dict[@"previewImage"] != nil)
            result[@"previewImage"] = dict[@"previewImage"];
            
            return result;
            }
            }
            
            return nil;
            }] cameraController:strongCameraController resultController:controller navigationController:(TGNavigationController *)controller.navigationController];
    };*/
}
