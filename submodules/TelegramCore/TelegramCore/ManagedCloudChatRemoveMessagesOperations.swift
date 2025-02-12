import Foundation
#if os(macOS)
    import PostboxMac
    import SwiftSignalKitMac
    import MtProtoKitMac
    import TelegramApiMac
#else
    import Postbox
    import SwiftSignalKit
    import TelegramApi
    #if BUCK
        import MtProtoKit
    #else
        import MtProtoKitDynamic
    #endif
#endif

private final class ManagedCloudChatRemoveMessagesOperationsHelper {
    var operationDisposables: [Int32: Disposable] = [:]
    
    func update(_ entries: [PeerMergedOperationLogEntry]) -> (disposeOperations: [Disposable], beginOperations: [(PeerMergedOperationLogEntry, MetaDisposable)]) {
        var disposeOperations: [Disposable] = []
        var beginOperations: [(PeerMergedOperationLogEntry, MetaDisposable)] = []
        
        var hasRunningOperationForPeerId = Set<PeerId>()
        var validMergedIndices = Set<Int32>()
        for entry in entries {
            if !hasRunningOperationForPeerId.contains(entry.peerId) {
                hasRunningOperationForPeerId.insert(entry.peerId)
                validMergedIndices.insert(entry.mergedIndex)
                
                if self.operationDisposables[entry.mergedIndex] == nil {
                    let disposable = MetaDisposable()
                    beginOperations.append((entry, disposable))
                    self.operationDisposables[entry.mergedIndex] = disposable
                }
            }
        }
        
        var removeMergedIndices: [Int32] = []
        for (mergedIndex, disposable) in self.operationDisposables {
            if !validMergedIndices.contains(mergedIndex) {
                removeMergedIndices.append(mergedIndex)
                disposeOperations.append(disposable)
            }
        }
        
        for mergedIndex in removeMergedIndices {
            self.operationDisposables.removeValue(forKey: mergedIndex)
        }
        
        return (disposeOperations, beginOperations)
    }
    
    func reset() -> [Disposable] {
        let disposables = Array(self.operationDisposables.values)
        self.operationDisposables.removeAll()
        return disposables
    }
}

private func withTakenOperation(postbox: Postbox, peerId: PeerId, tagLocalIndex: Int32, _ f: @escaping (Transaction, PeerMergedOperationLogEntry?) -> Signal<Void, NoError>) -> Signal<Void, NoError> {
    return postbox.transaction { transaction -> Signal<Void, NoError> in
        var result: PeerMergedOperationLogEntry?
        transaction.operationLogUpdateEntry(peerId: peerId, tag: OperationLogTags.CloudChatRemoveMessages, tagLocalIndex: tagLocalIndex, { entry in
            if let entry = entry, let _ = entry.mergedIndex, (entry.contents is CloudChatRemoveMessagesOperation || entry.contents is CloudChatRemoveChatOperation || entry.contents is CloudChatClearHistoryOperation)  {
                result = entry.mergedEntry!
                return PeerOperationLogEntryUpdate(mergedIndex: .none, contents: .none)
            } else {
                return PeerOperationLogEntryUpdate(mergedIndex: .none, contents: .none)
            }
        })
        
        return f(transaction, result)
    } |> switchToLatest
}

func managedCloudChatRemoveMessagesOperations(postbox: Postbox, network: Network, stateManager: AccountStateManager) -> Signal<Void, NoError> {
    return Signal { _ in
        let helper = Atomic<ManagedCloudChatRemoveMessagesOperationsHelper>(value: ManagedCloudChatRemoveMessagesOperationsHelper())
        
        let disposable = postbox.mergedOperationLogView(tag: OperationLogTags.CloudChatRemoveMessages, limit: 10).start(next: { view in
            let (disposeOperations, beginOperations) = helper.with { helper -> (disposeOperations: [Disposable], beginOperations: [(PeerMergedOperationLogEntry, MetaDisposable)]) in
                return helper.update(view.entries)
            }
            
            for disposable in disposeOperations {
                disposable.dispose()
            }
            
            for (entry, disposable) in beginOperations {
                let signal = withTakenOperation(postbox: postbox, peerId: entry.peerId, tagLocalIndex: entry.tagLocalIndex, { transaction, entry -> Signal<Void, NoError> in
                    if let entry = entry {
                        if let operation = entry.contents as? CloudChatRemoveMessagesOperation {
                            if let peer = transaction.getPeer(entry.peerId) {
                                return removeMessages(postbox: postbox, network: network, stateManager: stateManager, peer: peer, operation: operation)
                            } else {
                                return .complete()
                            }
                        } else if let operation = entry.contents as? CloudChatRemoveChatOperation {
                            if let peer = transaction.getPeer(entry.peerId) {
                                return removeChat(transaction: transaction, postbox: postbox, network: network, stateManager: stateManager, peer: peer, operation: operation)
                            } else {
                                return .complete()
                            }
                        } else if let operation = entry.contents as? CloudChatClearHistoryOperation {
                            if let peer = transaction.getPeer(entry.peerId) {
                                return clearHistory(transaction: transaction, postbox: postbox, network: network, stateManager: stateManager, peer: peer, operation: operation)
                            } else {
                                return .complete()
                            }
                        } else {
                            assertionFailure()
                        }
                    }
                    return .complete()
                })
                |> then(postbox.transaction { transaction -> Void in
                    let _ = transaction.operationLogRemoveEntry(peerId: entry.peerId, tag: OperationLogTags.CloudChatRemoveMessages, tagLocalIndex: entry.tagLocalIndex)
                })
                
                disposable.set(signal.start())
            }
        })
        
        return ActionDisposable {
            let disposables = helper.with { helper -> [Disposable] in
                return helper.reset()
            }
            for disposable in disposables {
                disposable.dispose()
            }
            disposable.dispose()
        }
    }
}

private func removeMessages(postbox: Postbox, network: Network, stateManager: AccountStateManager, peer: Peer, operation: CloudChatRemoveMessagesOperation) -> Signal<Void, NoError> {
    if peer.id.namespace == Namespaces.Peer.CloudChannel {
        if let inputChannel = apiInputChannel(peer) {
            var signal: Signal<Void, NoError> = .complete()
            for s in stride(from: 0, to: operation.messageIds.count, by: 100) {
                let ids = Array(operation.messageIds[s ..< min(s + 100, operation.messageIds.count)])
                let partSignal = network.request(Api.functions.channels.deleteMessages(channel: inputChannel, id: ids.map { $0.id }))
                |> map { result -> Api.messages.AffectedMessages? in
                    return result
                }
                |> `catch` { _ in
                    return .single(nil)
                }
                |> mapToSignal { result -> Signal<Void, NoError> in
                    if let result = result {
                        switch result {
                        case let .affectedMessages(pts, ptsCount):
                            stateManager.addUpdateGroups([.updateChannelPts(channelId: peer.id.id, pts: pts, ptsCount: ptsCount)])
                        }
                    }
                    return .complete()
                }
                signal = signal
                |> then(partSignal)
            }
            return signal
        } else {
            return .complete()
        }
    } else {
        var flags: Int32
        switch operation.type {
            case .forEveryone:
                flags = (1 << 0)
            default:
                flags = 0
        }
        
        var signal: Signal<Void, NoError> = .complete()
        for s in stride(from: 0, to: operation.messageIds.count, by: 100) {
            let ids = Array(operation.messageIds[s ..< min(s + 100, operation.messageIds.count)])
            let partSignal = network.request(Api.functions.messages.deleteMessages(flags: flags, id: ids.map { $0.id }))
            |> map { result -> Api.messages.AffectedMessages? in
                return result
            }
            |> `catch` { _ in
                return .single(nil)
            }
            |> mapToSignal { result -> Signal<Void, NoError> in
                if let result = result {
                    switch result {
                    case let .affectedMessages(pts, ptsCount):
                        stateManager.addUpdateGroups([.updatePts(pts: pts, ptsCount: ptsCount)])
                    }
                }
                return .complete()
            }
            
            signal = signal
            |> then(partSignal)
        }
        return signal
    }
}

private func removeChat(transaction: Transaction, postbox: Postbox, network: Network, stateManager: AccountStateManager, peer: Peer, operation: CloudChatRemoveChatOperation) -> Signal<Void, NoError> {
    if peer.id.namespace == Namespaces.Peer.CloudChannel {
        if let inputChannel = apiInputChannel(peer) {
            let signal: Signal<Api.Updates, MTRpcError>
            if operation.deleteGloballyIfPossible {
                signal = network.request(Api.functions.channels.deleteChannel(channel: inputChannel))
                |> `catch` { _ -> Signal<Api.Updates, MTRpcError> in
                    return network.request(Api.functions.channels.leaveChannel(channel: inputChannel))
                }
            } else {
                signal = network.request(Api.functions.channels.leaveChannel(channel: inputChannel))
            }
            
            let reportSignal: Signal<Api.Bool, NoError>
            if let inputPeer = apiInputPeer(peer), operation.reportChatSpam {
                reportSignal = network.request(Api.functions.messages.reportSpam(peer: inputPeer))
                    |> `catch` { _ -> Signal<Api.Bool, NoError> in
                        return .single(.boolFalse)
                    }
            } else {
                reportSignal = .single(.boolTrue)
            }
            
            return combineLatest(signal
            |> map { result -> Api.Updates? in
                return result
            }
            |> `catch` { _ in
                return .single(nil)
            }, reportSignal)
            |> mapToSignal { updates, _ in
                if let updates = updates {
                    stateManager.addUpdates(updates)
                }
                return .complete()
            }
        } else {
            return .complete()
        }
    } else if peer.id.namespace == Namespaces.Peer.CloudGroup {
        let deleteUser: Signal<Void, NoError> = network.request(Api.functions.messages.deleteChatUser(chatId: peer.id.id, userId: Api.InputUser.inputUserSelf))
        |> map { result -> Api.Updates? in
            return result
        }
        |> `catch` { _ in
            return .single(nil)
        }
        |> mapToSignal { updates in
            if let updates = updates {
                stateManager.addUpdates(updates)
            }
            return .complete()
        }
        let reportSignal: Signal<Void, NoError>
        if let inputPeer = apiInputPeer(peer), operation.reportChatSpam {
            reportSignal = network.request(Api.functions.messages.reportSpam(peer: inputPeer))
            |> mapToSignal { _ -> Signal<Void, MTRpcError> in
                return .complete()
            }
            |> `catch` { _ -> Signal<Void, NoError> in
                return .complete()
            }
        } else {
            reportSignal = .complete()
        }
        let deleteMessages: Signal<Void, NoError>
        if let inputPeer = apiInputPeer(peer), let topMessageId = operation.topMessageId ?? transaction.getTopPeerMessageId(peerId: peer.id, namespace: Namespaces.Message.Cloud) {
            deleteMessages = requestClearHistory(postbox: postbox, network: network, stateManager: stateManager, inputPeer: inputPeer, maxId: topMessageId.id, justClear: false, type: operation.deleteGloballyIfPossible ? .forEveryone : .forLocalPeer)
        } else {
            deleteMessages = .complete()
        }
        return deleteMessages
        |> then(deleteUser)
        |> then(reportSignal)
        |> then(postbox.transaction { transaction -> Void in
            clearHistory(transaction: transaction, mediaBox: postbox.mediaBox, peerId: peer.id)
        })
    } else if peer.id.namespace == Namespaces.Peer.CloudUser {
        if let inputPeer = apiInputPeer(peer) {
            let reportSignal: Signal<Void, NoError>
            if let inputPeer = apiInputPeer(peer), operation.reportChatSpam {
                reportSignal = network.request(Api.functions.messages.reportSpam(peer: inputPeer))
                |> mapToSignal { _ -> Signal<Void, MTRpcError> in
                    return .complete()
                }
                |> `catch` { _ -> Signal<Void, NoError> in
                    return .complete()
                }
            } else {
                reportSignal = .complete()
            }
            return requestClearHistory(postbox: postbox, network: network, stateManager: stateManager, inputPeer: inputPeer, maxId: operation.topMessageId?.id ?? Int32.max - 1, justClear: false, type: operation.deleteGloballyIfPossible ? .forEveryone : .forLocalPeer)
            |> then(reportSignal)
            |> then(postbox.transaction { transaction -> Void in
                clearHistory(transaction: transaction, mediaBox: postbox.mediaBox, peerId: peer.id)
            })
        } else {
            return .complete()
        }
    } else {
        return .complete()
    }
}

private func requestClearHistory(postbox: Postbox, network: Network, stateManager: AccountStateManager, inputPeer: Api.InputPeer, maxId: Int32, justClear: Bool, type: InteractiveMessagesDeletionType) -> Signal<Void, NoError> {
    var flags: Int32 = 0
    if justClear {
        flags |= 1 << 0
    }
    if case .forEveryone = type {
        flags |= 1 << 1
    }
    let signal = network.request(Api.functions.messages.deleteHistory(flags: flags, peer: inputPeer, maxId: maxId))
    |> map { result -> Api.messages.AffectedHistory? in
        return result
    }
    |> `catch` { _ -> Signal<Api.messages.AffectedHistory?, Bool> in
        return .fail(true)
    }
    |> mapToSignal { result -> Signal<Void, Bool> in
        if let result = result {
            switch result {
                case let .affectedHistory(pts, ptsCount, offset):
                    stateManager.addUpdateGroups([.updatePts(pts: pts, ptsCount: ptsCount)])
                    if offset == 0 {
                        return .fail(true)
                    } else {
                        return .complete()
                    }
            }
        } else {
            return .fail(true)
        }
    }
    return (signal |> restart)
    |> `catch` { _ -> Signal<Void, NoError> in
        return .complete()
    }
}

private func clearHistory(transaction: Transaction, postbox: Postbox, network: Network, stateManager: AccountStateManager, peer: Peer, operation: CloudChatClearHistoryOperation) -> Signal<Void, NoError> {
    if peer.id.namespace == Namespaces.Peer.CloudGroup || peer.id.namespace == Namespaces.Peer.CloudUser {
        if let inputPeer = apiInputPeer(peer) {
            return requestClearHistory(postbox: postbox, network: network, stateManager: stateManager, inputPeer: inputPeer, maxId: operation.topMessageId.id, justClear: true, type: operation.type)
        } else {
            return .complete()
        }
    } else if peer.id.namespace == Namespaces.Peer.CloudChannel, let inputChannel = apiInputChannel(peer) {
        return network.request(Api.functions.channels.deleteHistory(channel: inputChannel, maxId: operation.topMessageId.id))
        |> `catch` { _ -> Signal<Api.Bool, NoError> in
            return .single(.boolFalse)
        }
        |> mapToSignal { _ -> Signal<Void, NoError> in
            return .complete()
        }
    } else {
        assertionFailure()
        return .complete()
    }
}
