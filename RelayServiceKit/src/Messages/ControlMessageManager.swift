//
//  ControlMessageManager.swift
//  Forsta
//
//  Created by Mark Descalzo on 6/22/18.
//  Copyright © 2018 Forsta. All rights reserved.
//

import Foundation

@objc
class ControlMessageManager : NSObject
{
    @objc static func processIncomingControlMessage(message: IncomingControlMessage)
    {
        switch message.controlMessageType {
        case FLControlMessageSyncRequestKey:
            self.handleMessageSyncRequest(message: message)
        case FLControlMessageProvisionRequestKey:
            self.handleProvisionRequest(message: message)
        case FLControlMessageThreadUpdateKey:
            self.handleThreadUpdate(message: message)
        case FLControlMessageThreadClearKey:
            self.handleThreadClear(message: message)
        case FLControlMessageThreadCloseKey:
            self.handleThreadClose(message: message)
        case FLControlMessageThreadArchiveKey:
            self.handleThreadArchive(message: message)
        case FLControlMessageThreadRestoreKey:
            self.handleThreadRestore(message: message)
        case FLControlMessageThreadDeleteKey:
            self.handleThreadDelete(message: message)
        case FLControlMessageThreadSnoozeKey:
            self.handleThreadSnooze(message: message)
        case FLControlMessageCallOfferKey:
            self.handleCallOffer(message: message)
        case FLControlMessageCallLeaveKey:
            self.handleCallLeave(message: message)
        case FLControlMessageCallICECandidates:
            self.handleCallICECandidates(message: message)
        default:
            Logger.info("Unhandled control message of type: \(message.controlMessageType)")
        }
    }
    
    static private func handleCallICECandidates(message: IncomingControlMessage)
    {
        Logger.info("Received callICECandidates message: \(message.forstaPayload)")
        
        if let callId = message.forstaPayload.object(forKey: "callId") {
            Logger.info("callId: \(callId)")
        }
        if let members = message.forstaPayload.object(forKey: "members") {
            Logger.info("members: \(members)")
        }
        if let originator = message.forstaPayload.object(forKey: "originator") {
            Logger.info("originator: \(originator)")
        }
        if let peerId = message.forstaPayload.object(forKey: "peerId") {
            Logger.info("peerId: \(peerId)")
        }
        if let icecandidates = message.forstaPayload.object(forKey: "icecandidates") {
            Logger.info("icecandidates: \(icecandidates)")
        }
    }
    
    static private func handleCallOffer(message: IncomingControlMessage)
    {
        guard #available(iOS 10.0, *) else {
            Logger.info("\(self.tag): Ignoring callOffer controler message due to iOS version.")
            return
        }
        
        
        let dataBlob = message.forstaPayload.object(forKey: "data") as? NSDictionary
        
        guard dataBlob != nil else {
            Logger.info("Received callOffer message with no data object.")
            return
        }
        
        let callId = dataBlob?.object(forKey: "callId") as? String
        let members = dataBlob?.object(forKey: "members") as? NSArray
        let originator = dataBlob?.object(forKey: "originator") as? String
        let peerId = dataBlob?.object(forKey: "peerId") as? String
        let offer = dataBlob?.object(forKey: "offer") as? NSDictionary
        
        
        guard callId != nil && members != nil && originator != nil && peerId != nil && offer != nil else {
            Logger.debug("Received callOffer message missing required objects.")
            return
        }
        
        let sdpString = offer?.object(forKey: "sdp") as? String
        
        guard sdpString != nil else {
            Logger.debug("sdb string missing from call offer.")
            return
        }
        
        
        //        let callOffer = CallOffer(callId: callId!, members: members!, originator: originator!, peerId: peerId!, sdpString: sdpString!)
        //
        //        Environment.shared().callService.handleReceivedOffer(offer: callOffer)
    }
    
    static private func handleCallLeave(message: IncomingControlMessage)
    {
        //        Logger.info("Received callLeave message: \(message.forstaPayload)")
        // FIXME: Message processing stops while call is pending.
        
        let dataBlob = message.forstaPayload.object(forKey: "data") as? NSDictionary
        
        guard dataBlob != nil else {
            Logger.info("Received callLeave message with no data object.")
            return
        }
        
        let callId = dataBlob?.object(forKey: "callId") as? String
        
        guard callId != nil else {
            Logger.info("Received callLeave message without callId.")
            return
        }
        
        //        Environment.endCall(withId: callId!)
        
    }
    
    static private func handleThreadUpdate(message: IncomingControlMessage)
    {
        if let dataBlob = message.forstaPayload.object(forKey: "data") as? NSDictionary {
            if let threadUpdates = dataBlob.object(forKey: "threadUpdates") as? NSDictionary {
                
                let thread = message.thread
                let senderId = (message.forstaPayload.object(forKey: "sender") as! NSDictionary).object(forKey: "userId") as! String
                
                var sender: RelayRecipient?
                OWSPrimaryStorage.shared().dbReadConnection.asyncRead { (transaction) in
                    sender = RelayRecipient.registeredRecipient(forRecipientId: senderId, transaction: transaction)
                }
                
                // Handle thread name change
                if let threadTitle = threadUpdates.object(forKey: FLThreadTitleKey) as? String {
                    OWSPrimaryStorage.shared().dbReadWriteConnection.asyncReadWrite { (transaction) in
                        
                        if thread.title != threadTitle {
                            thread.title = threadTitle
                            
                            var customMessage: String? = nil
                            var infoMessage: TSInfoMessage? = nil
                            
                            if sender != nil {
                                let format = NSLocalizedString("THREAD_TITLE_UPDATE_MESSAGE", comment: "") as NSString
                                customMessage = NSString.init(format: format as NSString, (sender?.fullName)!()) as String
                                
                                infoMessage = TSInfoMessage.init(timestamp: message.timestamp,
                                                                 in: thread,
                                                                 infoMessageType: TSInfoMessageType.typeConversationUpdate,
                                                                 customMessage: customMessage!)
                                
                            } else {
                                infoMessage = TSInfoMessage.init(timestamp: message.timestamp,
                                                                 in: thread,
                                                                 infoMessageType: TSInfoMessageType.typeConversationUpdate)
                            }
                            
                            infoMessage?.save(with: transaction)
                            thread.save(with: transaction)
                        }
                    }
                }
                
                // Handle change to participants
                if let expression = threadUpdates.object(forKey: FLExpressionKey) as? String {
                    if thread.universalExpression != expression {
                        CCSMCommManager.asyncTagLookup(with: expression,
                                                       success: { (lookupResults) in
                                                        OWSPrimaryStorage.shared().dbReadWriteConnection.asyncReadWrite({ (transaction) in
                                                            let newParticipants = NSCountedSet.init(array: lookupResults["userids"] as! [String])
                                                            
                                                            //  Handle participants leaving
                                                            let leaving = NSCountedSet.init(array: thread.participantIds)
                                                            leaving.minus(newParticipants as! Set<AnyHashable>)
                                                            
                                                            for uid in leaving as! Set<String> {
                                                                var customMessage: String? = nil
                                                                
                                                                
                                                                if uid == TSAccountManager.localUID() {
                                                                    customMessage = NSLocalizedString("GROUP_YOU_LEFT", comment: "")
                                                                } else {
                                                                    let recipient = RelayRecipient.registeredRecipient(forRecipientId: uid, transaction: transaction)
                                                                    let format = NSLocalizedString("GROUP_MEMBER_LEFT", comment: "") as NSString
                                                                    customMessage = NSString.init(format: format as NSString, (recipient?.fullName())!) as String
                                                                }
                                                                let infoMessage = TSInfoMessage.init(timestamp: message.timestamp,
                                                                                                     in: thread,
                                                                                                     infoMessageType: TSInfoMessageType.typeConversationUpdate,
                                                                                                     customMessage: customMessage!)
                                                                infoMessage.save(with: transaction)
                                                            }
                                                            
                                                            //  Handle participants leaving
                                                            let joining = newParticipants.copy() as! NSCountedSet
                                                            joining.minus(NSCountedSet.init(array: thread.participantIds) as! Set<AnyHashable>)
                                                            for uid in joining as! Set<String> {
                                                                var customMessage: String? = nil
                                                                
                                                                if uid == TSAccountManager.localUID() {
                                                                    customMessage = NSLocalizedString("GROUP_YOU_JOINED", comment: "")
                                                                } else {
                                                                    let recipient = RelayRecipient.registeredRecipient(forRecipientId: uid, transaction: transaction)
                                                                    let format = NSLocalizedString("GROUP_MEMBER_JOINED", comment: "") as NSString
                                                                    customMessage = NSString.init(format: format as NSString, (recipient?.fullName())!) as String
                                                                }
                                                                let infoMessage = TSInfoMessage.init(timestamp: message.timestamp,
                                                                                                     in: thread,
                                                                                                     infoMessageType: TSInfoMessageType.typeConversationUpdate,
                                                                                                     customMessage: customMessage!)
                                                                infoMessage.save(with: transaction)
                                                            }
                                                            
                                                            thread.participantIds = lookupResults["userids"] as! [String]
                                                            thread.prettyExpression = lookupResults["pretty"] as? String
                                                            thread.universalExpression = lookupResults["universal"] as? String
                                                            thread.save(with: transaction)
                                                        })
                                                        
                                                        
                        },
                                                       failure: { (error) in
                                                        Logger.error("\(self.tag): TagMath lookup failed on thread participationupdate. Error: \(error.localizedDescription)")
                        })
                    }
                }
                
                // Handle change to avatar
                if ((message.attachmentPointers) != nil) {
                    if (message.attachmentPointers?.count)! > 0 {
                        var properties: Array<Dictionary<String, String>> = []
                        for pointer in message.attachmentPointers! {
                            properties.append(["name" : pointer.fileName ])
                        }
                        
                        OWSPrimaryStorage.shared().dbReadWriteConnection.readWrite({ (transaction) in
                            let attachmentsProcessor = OWSAttachmentsProcessor.init(attachmentProtos: message.attachmentPointers!,
                                                                                    networkManager: TSNetworkManager.shared(),
                                                                                    transaction: transaction)
                            
                            if attachmentsProcessor.hasSupportedAttachments {
                                attachmentsProcessor.fetchAttachments(for: nil,
                                                                      primaryStorage: OWSPrimaryStorage.shared(),
                                                                      success: { (attachmentStream) in
                                                                        thread.image = attachmentStream.image()
                                                                        thread.save(with: transaction)
                                                                        attachmentStream.remove(with: transaction)
                                                                        let formatString = NSLocalizedString("THREAD_IMAGE_CHANGED_MESSAGE", comment: "")
                                                                        var messageString: String? = nil
                                                                        if sender?.uniqueId == TSAccountManager.localUID() {
                                                                            messageString = String.localizedStringWithFormat(formatString, NSLocalizedString("YOU_STRING", comment: ""))
                                                                        } else {
                                                                            let nameString: String = ((sender != nil) ? (sender?.fullName())! as String : NSLocalizedString("UNKNOWN_CONTACT_NAME", comment: ""))
                                                                            messageString = String.localizedStringWithFormat(formatString, nameString)
                                                                        }
                                                                        let infoMessage = TSInfoMessage.init(timestamp: message.timestamp,
                                                                                                             in: thread,
                                                                                                             infoMessageType: TSInfoMessageType.typeConversationUpdate,
                                                                                                             customMessage: messageString!)
                                                                        infoMessage.save(with: transaction)
                                }) { (error) in
                                    Logger.error("\(self.tag): Failed to fetch attachments for avatar with error: \(error.localizedDescription)")
                                }
                            }
                        })
                    }
                }
            }
        }
    }
    
    static private func handleThreadClear(message: IncomingControlMessage)
    {
        Logger.info("\(self.tag): Recieved Unimplemented control message type: \(message.controlMessageType)")
    }
    
    static private func handleThreadClose(message: IncomingControlMessage)
    {
        // Treat these as archive messages
        self.handleThreadArchive(message: message)
    }
    
    static private func handleThreadArchive(message: IncomingControlMessage)
    {
        OWSPrimaryStorage.shared().dbReadWriteConnection.asyncReadWrite { transaction in
            let threadId = message.forstaPayload.object(forKey: FLThreadIDKey) as! String
            if let thread = TSThread.fetch(uniqueId: threadId) {
                thread.archiveThread(with: transaction, referenceDate: NSDate.ows_date(withMillisecondsSince1970: message.timestamp))
                Logger.debug("\(self.tag): Archived thread: \(String(describing: thread.uniqueId))")
            }
        }
    }
    
    static private func handleThreadRestore(message: IncomingControlMessage)
    {
        OWSPrimaryStorage.shared().dbReadWriteConnection.asyncReadWrite { transaction in
            let threadId = message.forstaPayload.object(forKey: FLThreadIDKey) as! String
            if let thread = TSThread.fetch(uniqueId: threadId) {
                thread.unarchiveThread(with: transaction)
                Logger.debug("\(self.tag): Unarchived thread: \(String(describing: thread.uniqueId))")
            }
        }
    }
    
    static private func handleThreadDelete(message: IncomingControlMessage)
    {
        Logger.info("\(self.tag): Recieved Unimplemented control message type: \(message.controlMessageType)")
    }
    
    static private func handleThreadSnooze(message: IncomingControlMessage)
    {
        Logger.info("\(self.tag): Recieved Unimplemented control message type: \(message.controlMessageType)")
    }
    
    static private func handleProvisionRequest(message: IncomingControlMessage)
    {
        if let senderId: String = (message.forstaPayload.object(forKey: "sender") as! NSDictionary).object(forKey: "userId") as? String,
            let dataBlob: Dictionary<String, Any?> = message.forstaPayload.object(forKey: "data") as? Dictionary<String, Any?> {
            
            if !(senderId == FLSupermanDevID || senderId == FLSupermanStageID || senderId == FLSupermanProdID){
                Logger.error("\(self.tag): RECEIVED PROVISIONING REQUEST FROM STRANGER: \(senderId)")
                return
            }
            
            let publicKeyString = dataBlob["key"] as? String
            let deviceUUID = dataBlob["uuid"] as? String
            
            if publicKeyString?.count == 0 || deviceUUID?.count == 0 {
                Logger.error("\(self.tag): Received malformed provisionRequest control message. Bad data payload.")
                return
            }
            FLDeviceRegistrationService.sharedInstance().provisionOtherDevice(withPublicKey: publicKeyString!, andUUID: deviceUUID!)
        } else {
            Logger.error("\(self.tag): Received malformed provisionRequest control message.")
        }
    }
    
    static private func handleMessageSyncRequest(message: IncomingControlMessage)
    {
        Logger.info("\(self.tag): Recieved Unimplemented control message type: \(message.controlMessageType)")
    }
    
    // MARK: - Logging
    static public func tag() -> NSString
    {
        return "[\(self.classForCoder())]" as NSString
    }
    
}
