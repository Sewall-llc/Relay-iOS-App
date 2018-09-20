//
//  Copyright (c) 2018 Open Whisper Systems. All rights reserved.
//

#import "OWSMessageManager.h"
#import "AppContext.h"
#import "AppReadiness.h"
#import "ContactsManagerProtocol.h"
#import "Cryptography.h"
#import "MimeTypeUtil.h"
#import "NSDate+OWS.h"
#import "NSString+SSK.h"
#import "NotificationsProtocol.h"
#import "OWSAttachmentsProcessor.h"
#import "OWSBlockingManager.h"
#import "OWSCallMessageHandler.h"
#import "OWSContact.h"
#import "OWSDevice.h"
#import "OWSDisappearingConfigurationUpdateInfoMessage.h"
#import "OWSDisappearingMessagesConfiguration.h"
#import "OWSDisappearingMessagesJob.h"
#import "OWSIdentityManager.h"
#import "OWSIncomingMessageFinder.h"
#import "OWSIncomingSentMessageTranscript.h"
#import "OWSMessageSender.h"
#import "OWSMessageUtils.h"
#import "OWSPrimaryStorage+SessionStore.h"
#import "OWSPrimaryStorage.h"
#import "OWSReadReceiptManager.h"
#import "OWSRecordTranscriptJob.h"
#import "ProfileManagerProtocol.h"
#import "TSAccountManager.h"
#import "TSAttachment.h"
#import "TSAttachmentPointer.h"
#import "TSAttachmentStream.h"
#import "TSThread.h"
#import "TSDatabaseView.h"
#import "TSIncomingMessage.h"
#import "TSInfoMessage.h"
#import "TSNetworkManager.h"
#import "TSOutgoingMessage.h"
#import "TSQuotedMessage.h"
#import "TextSecureKitEnv.h"
#import <RelayServiceKit/RelayServiceKit-Swift.h>
#import "FLCCSMJSONService.h"
//#import <YapDatabase/YapDatabase.h>

@import YapDatabase;

NS_ASSUME_NONNULL_BEGIN

@interface OWSMessageManager ()

@property (nonatomic, readonly) id<OWSCallMessageHandler> callMessageHandler;
@property (nonatomic, readonly) id<ContactsManagerProtocol> contactsManager;
@property (nonatomic, readonly) OWSPrimaryStorage *primaryStorage;
@property (nonatomic, readonly) OWSMessageSender *messageSender;
@property (nonatomic, readonly) OWSIncomingMessageFinder *incomingMessageFinder;
@property (nonatomic, readonly) OWSBlockingManager *blockingManager;
@property (nonatomic, readonly) OWSIdentityManager *identityManager;
@property (nonatomic, readonly) TSNetworkManager *networkManager;
@property (nonatomic, readonly) YapDatabaseConnection *dbConnection;

@end

#pragma mark -

@implementation OWSMessageManager

+ (instancetype)sharedManager
{
    static OWSMessageManager *sharedMyManager = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedMyManager = [[self alloc] initDefault];
    });
    return sharedMyManager;
}

- (instancetype)initDefault
{
    TSNetworkManager *networkManager = [TSNetworkManager sharedManager];
    OWSPrimaryStorage *primaryStorage = [OWSPrimaryStorage sharedManager];
    id<ContactsManagerProtocol> contactsManager = [TextSecureKitEnv sharedEnv].contactsManager;
    id<OWSCallMessageHandler> callMessageHandler = [TextSecureKitEnv sharedEnv].callMessageHandler;
    OWSIdentityManager *identityManager = [OWSIdentityManager sharedManager];
    OWSMessageSender *messageSender = [TextSecureKitEnv sharedEnv].messageSender;
    
    
    return [self initWithNetworkManager:networkManager
                         primaryStorage:primaryStorage
                     callMessageHandler:callMessageHandler
                        contactsManager:contactsManager
                        identityManager:identityManager
                          messageSender:messageSender];
}

- (instancetype)initWithNetworkManager:(TSNetworkManager *)networkManager
                        primaryStorage:(OWSPrimaryStorage *)primaryStorage
                    callMessageHandler:(id<OWSCallMessageHandler>)callMessageHandler
                       contactsManager:(id<ContactsManagerProtocol>)contactsManager
                       identityManager:(OWSIdentityManager *)identityManager
                         messageSender:(OWSMessageSender *)messageSender
{
    self = [super init];
    
    if (!self) {
        return self;
    }
    
    _primaryStorage = primaryStorage;
    _networkManager = networkManager;
    _callMessageHandler = callMessageHandler;
    _contactsManager = contactsManager;
    _identityManager = identityManager;
    _messageSender = messageSender;
    
    _dbConnection = primaryStorage.newDatabaseConnection;
    _incomingMessageFinder = [[OWSIncomingMessageFinder alloc] initWithPrimaryStorage:primaryStorage];
    _blockingManager = [OWSBlockingManager sharedManager];
    
    OWSSingletonAssert();
    OWSAssert(CurrentAppContext().isMainApp);
    
    [self startObserving];
    
    return self;
}

- (void)startObserving
{
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(yapDatabaseModified:)
                                                 name:YapDatabaseModifiedNotification
                                               object:OWSPrimaryStorage.sharedManager.dbNotificationObject];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(yapDatabaseModified:)
                                                 name:YapDatabaseModifiedExternallyNotification
                                               object:nil];
}

- (void)yapDatabaseModified:(NSNotification *)notification
{
    if (AppReadiness.isAppReady) {
        [OWSMessageUtils.sharedManager updateApplicationBadgeCount];
    } else {
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{
            [AppReadiness runNowOrWhenAppIsReady:^{
                [OWSMessageUtils.sharedManager updateApplicationBadgeCount];
            }];
        });
    }
}

#pragma mark - Blocking

- (BOOL)isEnvelopeBlocked:(SSKEnvelope *)envelope
{
    OWSAssert(envelope);
    
    return [_blockingManager isRecipientIdBlocked:envelope.source];
}

#pragma mark - message handling

- (void)processEnvelope:(SSKEnvelope *)envelope
          plaintextData:(NSData *_Nullable)plaintextData
            transaction:(YapDatabaseReadWriteTransaction *)transaction
{
    OWSAssert(envelope);
    OWSAssert(transaction);
    OWSAssert([TSAccountManager isRegistered]);
    OWSAssert(CurrentAppContext().isMainApp);
    
    DDLogInfo(@"%@ handling decrypted envelope: %@", self.logTag, [self descriptionForEnvelope:envelope]);
    
    if ([[NSUUID alloc] initWithUUIDString:envelope.source] == nil) {
        DDLogVerbose(
                     @"%@ incoming envelope has invalid source: %@", self.logTag, [self descriptionForEnvelope:envelope]);
        OWSFail(@"%@ incoming envelope has invalid source", self.logTag);
        return;
    }
    
    OWSAssert(envelope.source.length > 0);
    OWSAssert(![self isEnvelopeBlocked:envelope]);
    
    switch (envelope.type) {
        case SSKEnvelopeTypeCiphertext:
        case SSKEnvelopeTypePrekeyBundle:
            if (plaintextData) {
                [self handleEnvelope:envelope plaintextData:plaintextData transaction:transaction];
            } else {
                OWSFail(
                        @"%@ missing decrypted data for envelope: %@", self.logTag, [self descriptionForEnvelope:envelope]);
            }
            break;
        case SSKEnvelopeTypeReceipt:
            OWSAssert(!plaintextData);
            [self handleDeliveryReceipt:envelope transaction:transaction];
            break;
            // Other messages are just dismissed for now.
        case SSKEnvelopeTypeKeyExchange:
            DDLogWarn(@"Received Key Exchange Message, not supported");
            break;
        case SSKEnvelopeTypeUnknown:
            DDLogWarn(@"Received an unknown message type");
            break;
        default:
            DDLogWarn(@"Received unhandled envelope type: %d", (int)envelope.type);
            break;
    }
}

- (void)handleDeliveryReceipt:(SSKEnvelope *)envelope
                  transaction:(YapDatabaseReadWriteTransaction *)transaction
{
    OWSAssert(envelope);
    OWSAssert(transaction);
    
    // Old-style delivery notices don't include a "delivery timestamp".
    [self processDeliveryReceiptsFromRecipientId:envelope.source
                                  sentTimestamps:@[
                                                   @(envelope.timestamp),
                                                   ]
                               deliveryTimestamp:nil
                                     transaction:transaction];
}

// deliveryTimestamp is an optional parameter, since legacy
// delivery receipts don't have a "delivery timestamp".  Those
// messages repurpose the "timestamp" field to indicate when the
// corresponding message was originally sent.
- (void)processDeliveryReceiptsFromRecipientId:(NSString *)recipientId
                                sentTimestamps:(NSArray<NSNumber *> *)sentTimestamps
                             deliveryTimestamp:(NSNumber *_Nullable)deliveryTimestamp
                                   transaction:(YapDatabaseReadWriteTransaction *)transaction
{
    OWSAssert(recipientId);
    OWSAssert(sentTimestamps);
    OWSAssert(transaction);
    
    for (NSNumber *nsTimestamp in sentTimestamps) {
        uint64_t timestamp = [nsTimestamp unsignedLongLongValue];
        
        NSArray<TSOutgoingMessage *> *messages
        = (NSArray<TSOutgoingMessage *> *)[TSInteraction interactionsWithTimestamp:timestamp
                                                                           ofClass:[TSOutgoingMessage class]
                                                                   withTransaction:transaction];
        if (messages.count < 1) {
            // The service sends delivery receipts for "unpersisted" messages
            // like group updates, so these errors are expected to a certain extent.
            //
            // TODO: persist "early" delivery receipts.
            DDLogInfo(@"%@ Missing message for delivery receipt: %llu", self.logTag, timestamp);
        } else {
            if (messages.count > 1) {
                DDLogInfo(@"%@ More than one message (%lu) for delivery receipt: %llu",
                          self.logTag,
                          (unsigned long)messages.count,
                          timestamp);
            }
            for (TSOutgoingMessage *outgoingMessage in messages) {
                [outgoingMessage updateWithDeliveredRecipient:recipientId
                                            deliveryTimestamp:deliveryTimestamp
                                                  transaction:transaction];
            }
        }
    }
}

- (void)handleEnvelope:(SSKEnvelope *)envelope
         plaintextData:(NSData *)plaintextData
           transaction:(YapDatabaseReadWriteTransaction *)transaction
{
    OWSAssert(envelope);
    OWSAssert(plaintextData);
    OWSAssert(transaction);
    OWSAssert(envelope.timestamp > 0);
    OWSAssert(envelope.source.length > 0);
    OWSAssert(envelope.sourceDevice > 0);
    
    BOOL duplicateEnvelope = [self.incomingMessageFinder existsMessageWithTimestamp:envelope.timestamp
                                                                           sourceId:envelope.source
                                                                     sourceDeviceId:envelope.sourceDevice
                                                                        transaction:transaction];
    if (duplicateEnvelope) {
        DDLogInfo(@"%@ Ignoring previously received envelope from %@ with timestamp: %llu",
                  self.logTag,
                  envelopeAddress(envelope),
                  envelope.timestamp);
        return;
    }
    
    if (envelope.content != nil) {
        OWSSignalServiceProtosContent *content = [OWSSignalServiceProtosContent parseFromData:plaintextData];
        DDLogInfo(@"%@ handling content: <Content: %@>", self.logTag, [self descriptionForContent:content]);
        
        if (content.hasSyncMessage) {
            [self handleIncomingEnvelope:envelope withSyncMessage:content.syncMessage transaction:transaction];
            
            [[OWSDeviceManager sharedManager] setHasReceivedSyncMessage];
        } else if (content.hasDataMessage) {
            [self handleIncomingEnvelope:envelope withDataMessage:content.dataMessage transaction:transaction];
        } else if (content.hasCallMessage) {
            [self handleIncomingEnvelope:envelope withCallMessage:content.callMessage];
        } else if (content.hasNullMessage) {
            DDLogInfo(@"%@ Received null message.", self.logTag);
        } else if (content.hasReceiptMessage) {
            [self handleIncomingEnvelope:envelope withReceiptMessage:content.receiptMessage transaction:transaction];
        } else {
            DDLogWarn(@"%@ Ignoring envelope. Content with no known payload", self.logTag);
        }
    } else if (envelope.legacyMessage != nil) { // DEPRECATED - Remove after all clients have been upgraded.
        OWSSignalServiceProtosDataMessage *dataMessage =
        [OWSSignalServiceProtosDataMessage parseFromData:plaintextData];
        DDLogInfo(
                  @"%@ handling message: <DataMessage: %@ />", self.logTag, [self descriptionForDataMessage:dataMessage]);
        
        [self handleIncomingEnvelope:envelope withDataMessage:dataMessage transaction:transaction];
    } else {
        OWSProdInfoWEnvelope([OWSAnalyticsEvents messageManagerErrorEnvelopeNoActionablePayload], envelope);
    }
}

- (void)handleIncomingEnvelope:(SSKEnvelope *)envelope
               withDataMessage:(OWSSignalServiceProtosDataMessage *)dataMessage
                   transaction:(YapDatabaseReadWriteTransaction *)transaction
{
    OWSAssert(envelope);
    OWSAssert(dataMessage);
    OWSAssert(transaction);
    
    if (dataMessage.hasTimestamp) {
        if (dataMessage.timestamp <= 0) {
            DDLogError(@"%@ Ignoring message with invalid data message timestamp: %@", self.logTag, envelope.source);
            return;
        }
        // This prevents replay attacks by the service.
        if (dataMessage.timestamp != envelope.timestamp) {
            DDLogError(
                       @"%@ Ignoring message with non-matching data message timestamp: %@", self.logTag, envelope.source);
            return;
        }
    }
    
    if ([dataMessage hasProfileKey]) {
        NSData *profileKey = [dataMessage profileKey];
        NSString *recipientId = envelope.source;
        if (profileKey.length == kAES256_KeyByteLength) {
            [self.profileManager setProfileKeyData:profileKey forRecipientId:recipientId];
        } else {
            OWSFail(
                    @"Unexpected profile key length:%lu on message from:%@", (unsigned long)profileKey.length, recipientId);
        }
    }
    
    if ((dataMessage.flags & OWSSignalServiceProtosDataMessageFlagsEndSession) != 0) {
        [self handleEndSessionMessageWithEnvelope:envelope dataMessage:dataMessage transaction:transaction];
    } else if ((dataMessage.flags & OWSSignalServiceProtosDataMessageFlagsExpirationTimerUpdate) != 0) {
        [self handleExpirationTimerUpdateMessageWithEnvelope:envelope dataMessage:dataMessage transaction:transaction];
    } else if ((dataMessage.flags & OWSSignalServiceProtosDataMessageFlagsProfileKeyUpdate) != 0) {
        [self handleProfileKeyMessageWithEnvelope:envelope dataMessage:dataMessage];
    } else if (dataMessage.attachments.count > 0) {
        [self handleReceivedMediaWithEnvelope:envelope dataMessage:dataMessage transaction:transaction];
    } else {
        [self handleReceivedTextMessageWithEnvelope:envelope dataMessage:dataMessage transaction:transaction];
        
        if ([self isDataMessageGroupAvatarUpdate:dataMessage]) {
            DDLogVerbose(@"%@ Data message had group avatar attachment.  WE SHOULD'T GET THESE IN FORSTA LAND!", self.logTag);
            //            [self handleReceivedGroupAvatarUpdateWithEnvelope:envelope dataMessage:dataMessage transaction:transaction];
        }
    }
}

// TODO: Should be handled by control message
//- (void)sendGroupInfoRequest:(NSData *)groupId
//                    envelope:(SSKEnvelope *)envelope
//                 transaction:(YapDatabaseReadWriteTransaction *)transaction
//{
//    OWSAssert(groupId.length > 0);
//    OWSAssert(envelope);
//    OWSAssert(transaction);
//
//    if (groupId.length < 1) {
//        return;
//    }
//
//    DDLogInfo(@"%@ Sending group info request: %@", self.logTag, envelopeAddress(envelope));
//
//    NSString *recipientId = envelope.source;
//
//    TSThread *thread = [TSThread getOrCreateThreadWithId:recipientId transaction:transaction];
//
//    OWSSyncGroupsRequestMessage *syncGroupsRequestMessage =
//        [[OWSSyncGroupsRequestMessage alloc] initWithThread:thread groupId:groupId];
//    [self.messageSender enqueueMessage:syncGroupsRequestMessage
//        success:^{
//            DDLogWarn(@"%@ Successfully sent Request Group Info message.", self.logTag);
//        }
//        failure:^(NSError *error) {
//            DDLogError(@"%@ Failed to send Request Group Info message with error: %@", self.logTag, error);
//        }];
//}

- (id<ProfileManagerProtocol>)profileManager
{
    return [TextSecureKitEnv sharedEnv].profileManager;
}

- (void)handleIncomingEnvelope:(SSKEnvelope *)envelope
            withReceiptMessage:(OWSSignalServiceProtosReceiptMessage *)receiptMessage
                   transaction:(YapDatabaseReadWriteTransaction *)transaction
{
    OWSAssert(envelope);
    OWSAssert(receiptMessage);
    OWSAssert(transaction);
    
    PBArray *messageTimestamps = receiptMessage.timestamp;
    NSMutableArray<NSNumber *> *sentTimestamps = [NSMutableArray new];
    for (int i = 0; i < messageTimestamps.count; i++) {
        UInt64 timestamp = [messageTimestamps uint64AtIndex:i];
        [sentTimestamps addObject:@(timestamp)];
    }
    
    switch (receiptMessage.type) {
        case OWSSignalServiceProtosReceiptMessageTypeDelivery:
            DDLogVerbose(@"%@ Processing receipt message with delivery receipts.", self.logTag);
            [self processDeliveryReceiptsFromRecipientId:envelope.source
                                          sentTimestamps:sentTimestamps
                                       deliveryTimestamp:@(envelope.timestamp)
                                             transaction:transaction];
            return;
        case OWSSignalServiceProtosReceiptMessageTypeRead:
            DDLogVerbose(@"%@ Processing receipt message with read receipts.", self.logTag);
            [OWSReadReceiptManager.sharedManager processReadReceiptsFromRecipientId:envelope.source
                                                                     sentTimestamps:sentTimestamps
                                                                      readTimestamp:envelope.timestamp];
            break;
        default:
            DDLogInfo(@"%@ Ignoring receipt message of unknown type: %d.", self.logTag, (int)receiptMessage.type);
            return;
    }
}

- (void)handleIncomingEnvelope:(SSKEnvelope *)envelope
               withCallMessage:(OWSSignalServiceProtosCallMessage *)callMessage
{
    OWSAssert(envelope);
    OWSAssert(callMessage);
    
    if ([callMessage hasProfileKey]) {
        NSData *profileKey = [callMessage profileKey];
        NSString *recipientId = envelope.source;
        [self.profileManager setProfileKeyData:profileKey forRecipientId:recipientId];
    }
    
    // By dispatching async, we introduce the possibility that these messages might be lost
    // if the app exits before this block is executed.  This is fine, since the call by
    // definition will end if the app exits.
    dispatch_async(dispatch_get_main_queue(), ^{
        if (callMessage.hasOffer) {
            [self.callMessageHandler receivedOffer:callMessage.offer fromCallerId:envelope.source];
        } else if (callMessage.hasAnswer) {
            [self.callMessageHandler receivedAnswer:callMessage.answer fromCallerId:envelope.source];
        } else if (callMessage.iceUpdate.count > 0) {
            for (OWSSignalServiceProtosCallMessageIceUpdate *iceUpdate in callMessage.iceUpdate) {
                [self.callMessageHandler receivedIceUpdate:iceUpdate fromCallerId:envelope.source];
            }
        } else if (callMessage.hasHangup) {
            DDLogVerbose(@"%@ Received CallMessage with Hangup.", self.logTag);
            [self.callMessageHandler receivedHangup:callMessage.hangup fromCallerId:envelope.source];
        } else if (callMessage.hasBusy) {
            [self.callMessageHandler receivedBusy:callMessage.busy fromCallerId:envelope.source];
        } else {
            OWSProdInfoWEnvelope([OWSAnalyticsEvents messageManagerErrorCallMessageNoActionablePayload], envelope);
        }
    });
}

// TODO:  Handled by control message
//- (void)handleReceivedGroupAvatarUpdateWithEnvelope:(SSKEnvelope *)envelope
//                                        dataMessage:(OWSSignalServiceProtosDataMessage *)dataMessage
//                                        transaction:(YapDatabaseReadWriteTransaction *)transaction
//{
//    OWSAssert(envelope);
//    OWSAssert(dataMessage);
//    OWSAssert(transaction);
//
//    TSGroupThread *_Nullable groupThread =
//        [TSGroupThread threadWithGroupId:dataMessage.group.id transaction:transaction];
//    if (!groupThread) {
//        OWSFail(@"%@ Missing group for group avatar update", self.logTag);
//        return;
//    }
//
//    OWSAssert(groupThread);
//    OWSAttachmentsProcessor *attachmentsProcessor =
//        [[OWSAttachmentsProcessor alloc] initWithAttachmentProtos:@[ dataMessage.group.avatar ]
//                                                   networkManager:self.networkManager
//                                                      transaction:transaction];
//
//    if (!attachmentsProcessor.hasSupportedAttachments) {
//        DDLogWarn(@"%@ received unsupported group avatar envelope", self.logTag);
//        return;
//    }
//    [attachmentsProcessor fetchAttachmentsForMessage:nil
//        transaction:transaction
//        success:^(TSAttachmentStream *attachmentStream) {
//            [groupThread updateAvatarWithAttachmentStream:attachmentStream];
//        }
//        failure:^(NSError *error) {
//            DDLogError(@"%@ failed to fetch attachments for group avatar sent at: %llu. with error: %@",
//                self.logTag,
//                envelope.timestamp,
//                error);
//        }];
//}

- (void)handleReceivedMediaWithEnvelope:(SSKEnvelope *)envelope
                            dataMessage:(OWSSignalServiceProtosDataMessage *)dataMessage
                            transaction:(YapDatabaseReadWriteTransaction *)transaction
{
    OWSAssert(envelope);
    OWSAssert(dataMessage);
    OWSAssert(transaction);
    
    TSThread *_Nullable thread = [self threadForEnvelope:envelope dataMessage:dataMessage transaction:transaction];
    if (!thread) {
        OWSFail(@"%@ ignoring media message for unknown group.", self.logTag);
        return;
    }
    
    OWSAttachmentsProcessor *attachmentsProcessor =
    [[OWSAttachmentsProcessor alloc] initWithAttachmentProtos:dataMessage.attachments
                                               networkManager:self.networkManager
                                                  transaction:transaction];
    if (!attachmentsProcessor.hasSupportedAttachments) {
        DDLogWarn(@"%@ received unsupported media envelope", self.logTag);
        return;
    }
    
    TSIncomingMessage *_Nullable createdMessage = [self handleReceivedEnvelope:envelope
                                                               withDataMessage:dataMessage
                                                                 attachmentIds:attachmentsProcessor.attachmentIds
                                                                   transaction:transaction];
    
    if (!createdMessage) {
        return;
    }
    
    DDLogDebug(@"%@ incoming attachment message: %@", self.logTag, createdMessage.debugDescription);
    
    [attachmentsProcessor fetchAttachmentsForMessage:createdMessage
                                         transaction:transaction
                                             success:^(TSAttachmentStream *attachmentStream) {
                                                 DDLogDebug(@"%@ successfully fetched attachment: %@ for message: %@",
                                                            self.logTag,
                                                            attachmentStream,
                                                            createdMessage);
                                             }
                                             failure:^(NSError *error) {
                                                 DDLogError(
                                                            @"%@ failed to fetch attachments for message: %@ with error: %@", self.logTag, createdMessage, error);
                                             }];
}

- (void)handleIncomingEnvelope:(SSKEnvelope *)envelope
               withSyncMessage:(OWSSignalServiceProtosSyncMessage *)syncMessage
                   transaction:(YapDatabaseReadWriteTransaction *)transaction
{
    OWSAssert(envelope);
    OWSAssert(syncMessage);
    OWSAssert(transaction);
    OWSAssert([TSAccountManager isRegistered]);
    
    NSString *localNumber = [TSAccountManager localUID];
    if (![localNumber isEqualToString:envelope.source]) {
        // Sync messages should only come from linked devices.
        OWSProdErrorWEnvelope([OWSAnalyticsEvents messageManagerErrorSyncMessageFromUnknownSource], envelope);
        return;
    }
    
    if (syncMessage.hasSent) {
        OWSIncomingSentMessageTranscript *transcript =
        [[OWSIncomingSentMessageTranscript alloc] initWithProto:syncMessage.sent
                                                    transaction:transaction];
        
        OWSRecordTranscriptJob *recordJob =
        [[OWSRecordTranscriptJob alloc] initWithIncomingSentMessageTranscript:transcript];
        
        OWSSignalServiceProtosDataMessage *dataMessage = syncMessage.sent.message;
        OWSAssert(dataMessage);
        NSString *destination = syncMessage.sent.destination;
        if (dataMessage && destination.length > 0 && dataMessage.hasProfileKey) {
            // If we observe a linked device sending our profile key to another
            // user, we can infer that that user belongs in our profile whitelist.
            if (dataMessage.hasGroup) {
                [self.profileManager addGroupIdToProfileWhitelist:dataMessage.group.id];
            } else {
                [self.profileManager addUserToProfileWhitelist:destination];
            }
        }
        
        if ([self isDataMessageGroupAvatarUpdate:syncMessage.sent.message]) {
            // These are handled by control message in Forsta land
            DDLogDebug(@"%@: Received unhandled old style avatar update message", self.logTag);
            //            [recordJob runWithAttachmentHandler:^(TSAttachmentStream *attachmentStream) {
            //                [self.dbConnection readWriteWithBlock:^(YapDatabaseReadWriteTransaction *transaction) {
            //                    TSGroupThread *_Nullable groupThread =
            //                        [TSGroupThread threadWithGroupId:dataMessage.group.id transaction:transaction];
            //                    if (!groupThread) {
            //                        OWSFail(@"%@ ignoring sync group avatar update for unknown group.", self.logTag);
            //                        return;
            //                    }
            //
            //                    [groupThread updateAvatarWithAttachmentStream:attachmentStream transaction:transaction];
            //                }];
            //            }
            //                                    transaction:transaction];
        } else {
            [recordJob runWithAttachmentHandler:^(TSAttachmentStream *attachmentStream) {
                DDLogDebug(@"%@ successfully fetched transcript attachment: %@", self.logTag, attachmentStream);
            }
                                    transaction:transaction];
        }
    } else if (syncMessage.hasRequest) {
        if (syncMessage.request.type == OWSSignalServiceProtosSyncMessageRequestTypeBlocked) {
            DDLogInfo(@"%@ Received request for block list", self.logTag);
            [_blockingManager syncBlockedPhoneNumbers];
        } else {
            DDLogWarn(@"%@ ignoring unsupported sync request message", self.logTag);
        }
    } else if (syncMessage.hasBlocked) {
        NSArray<NSString *> *blockedPhoneNumbers = [syncMessage.blocked.numbers copy];
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            [self.blockingManager setBlockedPhoneNumbers:blockedPhoneNumbers sendSyncMessage:NO];
        });
    } else if (syncMessage.read.count > 0) {
        DDLogInfo(@"%@ Received %ld read receipt(s)", self.logTag, (u_long)syncMessage.read.count);
        [OWSReadReceiptManager.sharedManager processReadReceiptsFromLinkedDevice:syncMessage.read
                                                                   readTimestamp:envelope.timestamp
                                                                     transaction:transaction];
    } else if (syncMessage.hasVerified) {
        DDLogInfo(@"%@ Received verification state for %@", self.logTag, syncMessage.verified.destination);
        [self.identityManager processIncomingSyncMessage:syncMessage.verified transaction:transaction];
    } else {
        DDLogWarn(@"%@ Ignoring unsupported sync message.", self.logTag);
    }
}


- (void)handleEndSessionMessageWithEnvelope:(SSKEnvelope *)envelope
                                dataMessage:(OWSSignalServiceProtosDataMessage *)dataMessage
                                transaction:(YapDatabaseReadWriteTransaction *)transaction
{
    OWSAssert(envelope);
    OWSAssert(dataMessage);
    OWSAssert(transaction);
    
    __block NSDictionary *jsonPayload = [FLCCSMJSONService payloadDictionaryFromMessageBody:dataMessage.body];
    
    NSDictionary *dataBlob = [jsonPayload objectForKey:@"data"];
    if ([dataBlob allKeys].count == 0) {
        DDLogDebug(@"Received message contained no data object.");
        return;
    }
    
    // Process per messageType
    NSString *threadId = [jsonPayload objectForKey:@"threadId"];
    
    TSThread *thread = [TSThread getOrCreateThreadWithId:threadId transaction:transaction];
    
    [[[TSInfoMessage alloc] initWithTimestamp:[NSDate ows_millisecondTimeStamp]
                                     inThread:thread
                              infoMessageType:TSInfoMessageTypeSessionDidEnd] saveWithTransaction:transaction];
    
    [self.primaryStorage deleteAllSessionsForContact:envelope.source protocolContext:transaction];
}

- (void)handleExpirationTimerUpdateMessageWithEnvelope:(SSKEnvelope *)envelope
                                           dataMessage:(OWSSignalServiceProtosDataMessage *)dataMessage
                                           transaction:(YapDatabaseReadWriteTransaction *)transaction
{
    OWSAssert(envelope);
    OWSAssert(dataMessage);
    OWSAssert(transaction);
    
    TSThread *_Nullable thread = [self threadForEnvelope:envelope dataMessage:dataMessage transaction:transaction];
    if (!thread) {
        OWSFail(@"%@ ignoring expiring messages update for unknown group.", self.logTag);
        return;
    }
    
    OWSDisappearingMessagesConfiguration *disappearingMessagesConfiguration;
    if (dataMessage.hasExpireTimer && dataMessage.expireTimer > 0) {
        DDLogInfo(@"%@ Expiring messages duration turned to %u for thread %@",
                  self.logTag,
                  (unsigned int)dataMessage.expireTimer,
                  thread);
        disappearingMessagesConfiguration =
        [[OWSDisappearingMessagesConfiguration alloc] initWithThreadId:thread.uniqueId
                                                               enabled:YES
                                                       durationSeconds:dataMessage.expireTimer];
    } else {
        DDLogInfo(@"%@ Expiring messages have been turned off for thread %@", self.logTag, thread);
        disappearingMessagesConfiguration = [[OWSDisappearingMessagesConfiguration alloc]
                                             initWithThreadId:thread.uniqueId
                                             enabled:NO
                                             durationSeconds:OWSDisappearingMessagesConfigurationDefaultExpirationDuration];
    }
    OWSAssert(disappearingMessagesConfiguration);
    [disappearingMessagesConfiguration saveWithTransaction:transaction];
    NSString *name = [self.contactsManager displayNameForRecipientId:envelope.source];
    OWSDisappearingConfigurationUpdateInfoMessage *message =
    [[OWSDisappearingConfigurationUpdateInfoMessage alloc] initWithTimestamp:[NSDate ows_millisecondTimeStamp]
                                                                      thread:thread
                                                               configuration:disappearingMessagesConfiguration
                                                         createdByRemoteName:name
                                                      createdInExistingGroup:NO];
    [message saveWithTransaction:transaction];
}

- (void)handleProfileKeyMessageWithEnvelope:(SSKEnvelope *)envelope
                                dataMessage:(OWSSignalServiceProtosDataMessage *)dataMessage
{
    OWSAssert(envelope);
    OWSAssert(dataMessage);
    
    NSString *recipientId = envelope.source;
    if (!dataMessage.hasProfileKey) {
        OWSFail(
                @"%@ received profile key message without profile key from: %@", self.logTag, envelopeAddress(envelope));
        return;
    }
    NSData *profileKey = dataMessage.profileKey;
    if (profileKey.length != kAES256_KeyByteLength) {
        OWSFail(@"%@ received profile key of unexpected length:%lu from:%@",
                self.logTag,
                (unsigned long)profileKey.length,
                envelopeAddress(envelope));
        return;
    }
    
    id<ProfileManagerProtocol> profileManager = [TextSecureKitEnv sharedEnv].profileManager;
    [profileManager setProfileKeyData:profileKey forRecipientId:recipientId];
}

- (void)handleReceivedTextMessageWithEnvelope:(SSKEnvelope *)envelope
                                  dataMessage:(OWSSignalServiceProtosDataMessage *)dataMessage
                                  transaction:(YapDatabaseReadWriteTransaction *)transaction
{
    OWSAssert(envelope);
    OWSAssert(dataMessage);
    OWSAssert(transaction);
    
    [self handleReceivedEnvelope:envelope withDataMessage:dataMessage attachmentIds:@[] transaction:transaction];
}


// TODO:  Handled by control message
//- (void)sendGroupUpdateForThread:(TSGroupThread *)gThread message:(TSOutgoingMessage *)message
//{
//    OWSAssert(gThread);
//    OWSAssert(gThread.groupModel);
//    OWSAssert(message);
//
//    if (gThread.groupModel.groupImage) {
//        NSData *data = UIImagePNGRepresentation(gThread.groupModel.groupImage);
//        DataSource *_Nullable dataSource = [DataSourceValue dataSourceWithData:data fileExtension:@"png"];
//        [self.messageSender enqueueTemporaryAttachment:dataSource
//            contentType:OWSMimeTypeImagePng
//            inMessage:message
//            success:^{
//                DDLogDebug(@"%@ Successfully sent group update with avatar", self.logTag);
//            }
//            failure:^(NSError *error) {
//                DDLogError(@"%@ Failed to send group avatar update with error: %@", self.logTag, error);
//            }];
//    } else {
//        [self.messageSender enqueueMessage:message
//            success:^{
//                DDLogDebug(@"%@ Successfully sent group update", self.logTag);
//            }
//            failure:^(NSError *error) {
//                DDLogError(@"%@ Failed to send group update with error: %@", self.logTag, error);
//            }];
//    }
//}

// TODO:  Handled by control message
//- (void)handleGroupInfoRequest:(SSKEnvelope *)envelope
//                   dataMessage:(OWSSignalServiceProtosDataMessage *)dataMessage
//                   transaction:(YapDatabaseReadWriteTransaction *)transaction
//{
//    OWSAssert(envelope);
//    OWSAssert(dataMessage);
//    OWSAssert(transaction);
//    OWSAssert(dataMessage.group.type == OWSSignalServiceProtosGroupContextTypeRequestInfo);
//
//    NSData *groupId = dataMessage.hasGroup ? dataMessage.group.id : nil;
//    if (!groupId) {
//        OWSFail(@"Group info request is missing group id.");
//        return;
//    }
//
//    DDLogWarn(
//        @"%@ Received 'Request Group Info' message for group: %@ from: %@", self.logTag, groupId, envelope.source);
//
//    TSGroupThread *_Nullable gThread = [TSGroupThread threadWithGroupId:dataMessage.group.id transaction:transaction];
//    if (!gThread) {
//        DDLogWarn(@"%@ Unknown group: %@", self.logTag, groupId);
//        return;
//    }
//
//    // Ensure sender is in the group.
//    if (![gThread.groupModel.groupMemberIds containsObject:envelope.source]) {
//        DDLogWarn(@"%@ Ignoring 'Request Group Info' message for non-member of group. %@ not in %@",
//            self.logTag,
//            envelope.source,
//            gThread.groupModel.groupMemberIds);
//        return;
//    }
//
//    // Ensure we are in the group.
//    OWSAssert([TSAccountManager isRegistered]);
//    NSString *localNumber = [TSAccountManager localUID];
//    if (![gThread.groupModel.groupMemberIds containsObject:localNumber]) {
//        DDLogWarn(@"%@ Ignoring 'Request Group Info' message for group we no longer belong to.", self.logTag);
//        return;
//    }
//
//    NSString *updateGroupInfo =
//        [gThread.groupModel getInfoStringAboutUpdateTo:gThread.groupModel contactsManager:self.contactsManager];
//
//    uint32_t expiresInSeconds = [gThread disappearingMessagesDurationWithTransaction:transaction];
//    TSOutgoingMessage *message = [TSOutgoingMessage outgoingMessageInThread:gThread
//                                                           groupMetaMessage:TSGroupMessageUpdate
//                                                           expiresInSeconds:expiresInSeconds];
//
//    [message updateWithCustomMessage:updateGroupInfo transaction:transaction];
//    // Only send this group update to the requester.
//    [message updateWithSendingToSingleGroupRecipient:envelope.source transaction:transaction];
//
//    [self sendGroupUpdateForThread:gThread message:message];
//}

- (TSIncomingMessage *_Nullable)handleReceivedEnvelope:(SSKEnvelope *)envelope
                                       withDataMessage:(OWSSignalServiceProtosDataMessage *)dataMessage
                                         attachmentIds:(NSArray<NSString *> *)attachmentIds
                                           transaction:(YapDatabaseReadWriteTransaction *)transaction
{
    ////////////////////
    OWSAssert(envelope);
    OWSAssert(dataMessage);
    OWSAssert(transaction);
    
    uint64_t timestamp = envelope.timestamp;
    NSString *body = dataMessage.body;
    
    //  Catch incoming messages and process the new way.
    __block NSDictionary *jsonPayload = [FLCCSMJSONService payloadDictionaryFromMessageBody:body];
    
    NSDictionary *dataBlob = [jsonPayload objectForKey:@"data"];
    if ([dataBlob allKeys].count == 0) {
        DDLogDebug(@"Received message contained no data object.");
        return nil;
    }
    
    // Process per messageType
    if ([[jsonPayload objectForKey:@"messageType"] isEqualToString:@"control"]) {
        NSString *controlMessageType = [dataBlob objectForKey:@"control"];
        DDLogInfo(@"Control message received: %@", controlMessageType);
        
        NSString *threadId = [jsonPayload objectForKey:@"threadId"];
        if (threadId.length > 0) {
            __block TSThread *thread = nil;
            [self.dbConnection readWriteWithBlock:^(YapDatabaseReadWriteTransaction * _Nonnull transaction) {
                thread = [TSThread getOrCreateThreadWithId:threadId transaction:transaction];
            }];
            
            IncomingControlMessage *controlMessage = [[IncomingControlMessage alloc] initWithThread:thread
                                                                                             author:envelope.source
                                                                                              relay:envelope.relay
                                                                                            payload:jsonPayload
                                                                                        attachments:dataMessage.attachments];
            [ControlMessageManager processIncomingControlMessageWithMessage:controlMessage];
        }
        return nil;
        
    } else if ([[jsonPayload objectForKey:@"messageType"] isEqualToString:@"content"]) {
        // Process per Thread type
        if ([[jsonPayload objectForKey:@"threadType"] isEqualToString:@"conversation"] ||
            [[jsonPayload objectForKey:@"threadType"] isEqualToString:@"announcement"]) {
            return [self handleThreadContentMessageWithEnvelope:envelope
                                                withDataMessage:dataMessage
                                                  attachmentIds:attachmentIds
                                                    transaction:transaction];
        } else {
            DDLogDebug(@"Unhandled thread type: %@", [jsonPayload objectForKey:@"threadType"]);
            return nil;
        }
    } else {
        DDLogDebug(@"Unhandled message type: %@", [jsonPayload objectForKey:@"messageType"]);
        return nil;
    }
    
    ////////////////
    //    OWSContact *_Nullable contact = [OWSContacts contactForDataMessage:dataMessage transaction:transaction];
    //
    //    if (dataMessage.group.type == OWSSignalServiceProtosGroupContextTypeRequestInfo) {
    //        [self handleGroupInfoRequest:envelope dataMessage:dataMessage transaction:transaction];
    //        return nil;
    //    }
    //
    //    if (groupId.length > 0) {
    //        NSMutableSet *newMemberIds = [NSMutableSet setWithArray:dataMessage.group.members];
    //        for (NSString *recipientId in newMemberIds) {
    //            if (!recipientId.isValidE164) {
    //                DDLogVerbose(@"%@ incoming group update has invalid group member: %@",
    //                    self.logTag,
    //                    [self descriptionForEnvelope:envelope]);
    //                OWSFail(@"%@ incoming group update has invalid group member", self.logTag);
    //                return nil;
    //            }
    //        }
    //
    //        // Group messages create the group if it doesn't already exist.
    //        //
    //        // We distinguish between the old group state (if any) and the new group state.
    //        TSGroupThread *_Nullable oldGroupThread = [TSGroupThread threadWithGroupId:groupId transaction:transaction];
    //        if (oldGroupThread) {
    //            // Don't trust other clients; ensure all known group members remain in the
    //            // group unless it is a "quit" message in which case we should only remove
    //            // the quiting member below.
    //            [newMemberIds addObjectsFromArray:oldGroupThread.groupModel.groupMemberIds];
    //        }
    //
    //        switch (dataMessage.group.type) {
    //            case OWSSignalServiceProtosGroupContextTypeUpdate: {
    //                // Ensures that the thread exists but doesn't update it.
    //                TSGroupThread *newGroupThread =
    //                    [TSGroupThread getOrCreateThreadWithGroupId:groupId transaction:transaction];
    //
    //
    //                uint64_t now = [NSDate ows_millisecondTimeStamp];
    //                TSGroupModel *newGroupModel = [[TSGroupModel alloc] initWithTitle:dataMessage.group.name
    //                                                                        memberIds:newMemberIds.allObjects
    //                                                                            image:oldGroupThread.groupModel.groupImage
    //                                                                          groupId:dataMessage.group.id];
    //                NSString *updateGroupInfo = [newGroupThread.groupModel getInfoStringAboutUpdateTo:newGroupModel
    //                                                                                  contactsManager:self.contactsManager];
    //                newGroupThread.groupModel = newGroupModel;
    //                [newGroupThread saveWithTransaction:transaction];
    //
    //                [[[TSInfoMessage alloc] initWithTimestamp:now
    //                                                 inThread:newGroupThread
    //                                              messageType:TSInfoMessageTypeConversationUpdate
    //                                            customMessage:updateGroupInfo] saveWithTransaction:transaction];
    //
    //                if (dataMessage.hasExpireTimer && dataMessage.expireTimer > 0) {
    //                    [[OWSDisappearingMessagesJob sharedJob]
    //                        becomeConsistentWithDisappearingDuration:dataMessage.expireTimer
    //                                                          thread:newGroupThread
    //                                           appearBeforeTimestamp:now
    //                                      createdByRemoteContactName:nil
    //                                          createdInExistingGroup:YES
    //                                                     transaction:transaction];
    //                }
    //
    //                return nil;
    //            }
    //            case OWSSignalServiceProtosGroupContextTypeQuit: {
    //                if (!oldGroupThread) {
    //                    DDLogInfo(@"%@ ignoring quit group message from unknown group.", self.logTag);
    //                    return nil;
    //                }
    //                [newMemberIds removeObject:envelope.source];
    //                oldGroupThread.groupModel.groupMemberIds = [newMemberIds.allObjects mutableCopy];
    //                [oldGroupThread saveWithTransaction:transaction];
    //
    //                NSString *nameString = [self.contactsManager displayNameForPhoneIdentifier:envelope.source];
    //                NSString *updateGroupInfo =
    //                    [NSString stringWithFormat:NSLocalizedString(@"GROUP_MEMBER_LEFT", @""), nameString];
    //                [[[TSInfoMessage alloc] initWithTimestamp:[NSDate ows_millisecondTimeStamp]
    //                                                 inThread:oldGroupThread
    //                                              messageType:TSInfoMessageTypeConversationUpdate
    //                                            customMessage:updateGroupInfo] saveWithTransaction:transaction];
    //                return nil;
    //            }
    //            case OWSSignalServiceProtosGroupContextTypeDeliver: {
    //                if (!oldGroupThread) {
    //                    OWSFail(@"%@ ignoring deliver group message from unknown group.", self.logTag);
    //                    return nil;
    //                }
    //
    //                if (body.length == 0 && attachmentIds.count < 1 && !contact) {
    //                    DDLogWarn(@"%@ ignoring empty incoming message from: %@ for group: %@ with timestamp: %lu",
    //                        self.logTag,
    //                        envelopeAddress(envelope),
    //                        groupId,
    //                        (unsigned long)timestamp);
    //                    return nil;
    //                }
    //
    //                TSQuotedMessage *_Nullable quotedMessage = [TSQuotedMessage quotedMessageForDataMessage:dataMessage
    //                                                                                                 thread:oldGroupThread
    //                                                                                            transaction:transaction];
    //
    //                DDLogDebug(@"%@ incoming message from: %@ for group: %@ with timestamp: %lu",
    //                    self.logTag,
    //                    envelopeAddress(envelope),
    //                    groupId,
    //                    (unsigned long)timestamp);
    //
    //                TSIncomingMessage *incomingMessage =
    //                    [[TSIncomingMessage alloc] initIncomingMessageWithTimestamp:timestamp
    //                                                                       inThread:oldGroupThread
    //                                                                       authorId:envelope.source
    //                                                                 sourceDeviceId:envelope.sourceDevice
    //                                                                    messageBody:body
    //                                                                  attachmentIds:attachmentIds
    //                                                               expiresInSeconds:dataMessage.expireTimer
    //                                                                  quotedMessage:quotedMessage
    //                                                                   contactShare:contact];
    //
    //                [self finalizeIncomingMessage:incomingMessage
    //                                       thread:oldGroupThread
    //                                     envelope:envelope
    //                                  transaction:transaction];
    //                return incomingMessage;
    //            }
    //            default: {
    //                DDLogWarn(@"%@ Ignoring unknown group message type: %d", self.logTag, (int)dataMessage.group.type);
    //                return nil;
    //            }
    //        }
    //    } else {
    //        if (body.length == 0 && attachmentIds.count < 1 && !contact) {
    //            DDLogWarn(@"%@ ignoring empty incoming message from: %@ with timestamp: %lu",
    //                self.logTag,
    //                envelopeAddress(envelope),
    //                (unsigned long)timestamp);
    //            return nil;
    //        }
    //
    //        DDLogDebug(@"%@ incoming message from: %@ with timestamp: %lu",
    //            self.logTag,
    //            envelopeAddress(envelope),
    //            (unsigned long)timestamp);
    //        TSThread *thread =
    //            [TSThread getOrCreateThreadWithId:envelope.source transaction:transaction];
    //
    //        TSQuotedMessage *_Nullable quotedMessage = [TSQuotedMessage quotedMessageForDataMessage:dataMessage
    //                                                                                         thread:thread
    //                                                                                    transaction:transaction];
    //
    //        TSIncomingMessage *incomingMessage =
    //            [[TSIncomingMessage alloc] initIncomingMessageWithTimestamp:timestamp
    //                                                               inThread:thread
    //                                                               authorId:[thread contactIdentifier]
    //                                                         sourceDeviceId:envelope.sourceDevice
    //                                                            messageBody:body
    //                                                          attachmentIds:attachmentIds
    //                                                       expiresInSeconds:dataMessage.expireTimer
    //                                                          quotedMessage:quotedMessage
    //                                                           contactShare:contact];
    
    // TODO: Investigate this finalize method
    //        [self finalizeIncomingMessage:incomingMessage
    //                               thread:thread
    //                             envelope:envelope
    //                          transaction:transaction];
    //        return incomingMessage;
    //    }
}

#pragma mark - message handlers by type
-(TSIncomingMessage *)handleThreadContentMessageWithEnvelope:(SSKEnvelope *)envelope
                                             withDataMessage:(OWSSignalServiceProtosDataMessage *)dataMessage
                                               attachmentIds:(NSArray<NSString *> *)attachmentIds
                                                 transaction:(YapDatabaseReadWriteTransaction *)transaction
{
    NSDictionary *jsonPayload = [FLCCSMJSONService payloadDictionaryFromMessageBody:dataMessage.body];
    NSString *threadId = [jsonPayload objectForKey:FLThreadIDKey];
    
    // getOrCreate a thread and an incomingMessage
    TSThread *thread = [TSThread getOrCreateThreadWithId:threadId transaction:transaction];
    
//    NSDictionary *distribution = [jsonPayload objectForKey:@"distribution"];
//    NSString *expression = [distribution objectForKey:@"expression"];
//    if (expression.length > 0) {
//        thread.universalExpression = expression;
//    }
//    thread.participantIds = @[ envelope.source, TSAccountManager.localUID ];
    
    [thread updateWithPayload:jsonPayload];
    [thread saveWithTransaction:transaction];

    
    // Check to see if we already have this message
    
    TSIncomingMessage *incomingMessage = [TSIncomingMessage fetchObjectWithUniqueID:[jsonPayload objectForKey:@"messageId"] transaction:transaction];
    
    if (incomingMessage == nil) {
        incomingMessage = [[TSIncomingMessage alloc] initIncomingMessageWithTimestamp:envelope.timestamp
                                                                             inThread:thread
                                                                             authorId:envelope.source
                                                                       sourceDeviceId:envelope.sourceDevice
                                                                          messageBody:dataMessage.body
                                                                        attachmentIds:attachmentIds
                                                                     expiresInSeconds:dataMessage.expireTimer
                                                                        quotedMessage:nil
                                                                         contactShare:nil];
        
        incomingMessage.uniqueId = [jsonPayload objectForKey:@"messageId"];
        incomingMessage.messageType = [jsonPayload objectForKey:@"messageType"];
    }
    incomingMessage.forstaPayload = [jsonPayload mutableCopy];
    
    // This SHOULD no longer be necessary
    // Android & web client allow attachments to be sent with body.
    //    if (attachmentIds.count > 0 && incomingMessage.plainTextBody.length > 0) {
    //        incomingMessage.hasAnnotation = YES;
    //        // We want the text to be displayed under the attachment
    //        uint64_t textMessageTimestamp = envelope.timestamp + 1;
    //        TSIncomingMessage *textMessage = [[TSIncomingMessage alloc] initWithTimestamp:textMessageTimestamp
    //                                                                             inThread:thread
    //                                                                             authorId:envelope.source
    //                                                                          messageBody:@""];
    //        textMessage.plainTextBody = incomingMessage.plainTextBody;
    //        textMessage.attributedTextBody = incomingMessage.attributedTextBody;
    //        textMessage.expiresInSeconds = dataMessage.expireTimer;
    //        textMessage.messageType = @"content";
    //        [textMessage save];
    //    }
    [incomingMessage saveWithTransaction:transaction];
    
    if (incomingMessage && thread) {
        // In case we already have a read receipt for this new message (happens sometimes).
        [self finalizeIncomingMessage:incomingMessage
                               thread:thread
                             envelope:envelope
                          transaction:transaction];
        
        return incomingMessage;
        //        OWSReadReceiptsProcessor *readReceiptsProcessor =
        //        [[OWSReadReceiptsProcessor alloc] initWithIncomingMessage:incomingMessage
        //                                                   storageManager:self.storageManager];
        //        [readReceiptsProcessor process];
        //
        //        [self.disappearingMessagesJob becomeConsistentWithConfigurationForMessage:incomingMessage
        //                                                                  contactsManager:self.contactsManager];
        //
        //        // TODO Delay notification by 100ms?
        //        // It's pretty annoying when you're phone keeps buzzing while you're having a conversation on Desktop.
        //
        //        NSString *senderName = [Environment.shared.contactsManager nameStringForContactId:envelope.source];
        //        [[TextSecureKitEnv sharedEnv].notificationsManager notifyUserForIncomingMessage:incomingMessage
        //                                                                                   from:senderName
        //                                                                               inThread:thread];
        //        return incomingMessage;
    } else {
        DDLogDebug(@"Unable to process incoming message.");
        return nil;
    }
}


- (void)finalizeIncomingMessage:(TSIncomingMessage *)incomingMessage
                         thread:(TSThread *)thread
                       envelope:(SSKEnvelope *)envelope
                    transaction:(YapDatabaseReadWriteTransaction *)transaction
{
    OWSAssert(thread);
    OWSAssert(incomingMessage);
    OWSAssert(envelope);
    OWSAssert(transaction);
    
    OWSAssert([TSAccountManager isRegistered]);
    
    if (!thread) {
        OWSFail(@"%@ Can't finalize without thread", self.logTag);
        return;
    }
    if (!incomingMessage) {
        OWSFail(@"%@ Can't finalize missing message", self.logTag);
        return;
    }
    
    [incomingMessage saveWithTransaction:transaction];
    
    // Any messages sent from the current user - from this device or another - should be automatically marked as read.
    if ([envelope.source isEqualToString:TSAccountManager.localUID]) {
        // Don't send a read receipt for messages sent by ourselves.
        [incomingMessage markAsReadAtTimestamp:envelope.timestamp sendReadReceipt:NO transaction:transaction];
    }
    
    TSQuotedMessage *_Nullable quotedMessage = incomingMessage.quotedMessage;
    if (quotedMessage && quotedMessage.thumbnailAttachmentPointerId) {
        // We weren't able to derive a local thumbnail, so we'll fetch the referenced attachment.
        TSAttachmentPointer *attachmentPointer =
        [TSAttachmentPointer fetchObjectWithUniqueID:quotedMessage.thumbnailAttachmentPointerId
                                         transaction:transaction];
        
        if ([attachmentPointer isKindOfClass:[TSAttachmentPointer class]]) {
            OWSAttachmentsProcessor *attachmentProcessor =
            [[OWSAttachmentsProcessor alloc] initWithAttachmentPointer:attachmentPointer
                                                        networkManager:self.networkManager];
            
            DDLogDebug(
                       @"%@ downloading thumbnail for message: %lu", self.logTag, (unsigned long)incomingMessage.timestamp);
            [attachmentProcessor fetchAttachmentsForMessage:incomingMessage
                                                transaction:transaction
                                                    success:^(TSAttachmentStream *_Nonnull attachmentStream) {
                                                        [self.dbConnection
                                                         asyncReadWriteWithBlock:^(YapDatabaseReadWriteTransaction *_Nonnull transaction) {
                                                             [incomingMessage setQuotedMessageThumbnailAttachmentStream:attachmentStream];
                                                             [incomingMessage saveWithTransaction:transaction];
                                                         }];
                                                    }
                                                    failure:^(NSError *_Nonnull error) {
                                                        DDLogWarn(@"%@ failed to fetch thumbnail for message: %lu with error: %@",
                                                                  self.logTag,
                                                                  (unsigned long)incomingMessage.timestamp,
                                                                  error);
                                                    }];
        }
    }
    
    OWSContact *_Nullable contact = incomingMessage.contactShare;
    if (contact && contact.avatarAttachmentId) {
        TSAttachmentPointer *attachmentPointer =
        [TSAttachmentPointer fetchObjectWithUniqueID:contact.avatarAttachmentId transaction:transaction];
        
        if (![attachmentPointer isKindOfClass:[TSAttachmentPointer class]]) {
            OWSFail(@"%@ in %s avatar attachmentPointer was unexpectedly nil", self.logTag, __PRETTY_FUNCTION__);
        } else {
            OWSAttachmentsProcessor *attachmentProcessor =
            [[OWSAttachmentsProcessor alloc] initWithAttachmentPointer:attachmentPointer
                                                        networkManager:self.networkManager];
            
            DDLogDebug(@"%@ downloading contact avatar for message: %lu",
                       self.logTag,
                       (unsigned long)incomingMessage.timestamp);
            [attachmentProcessor fetchAttachmentsForMessage:incomingMessage
                                                transaction:transaction
                                                    success:^(TSAttachmentStream *_Nonnull attachmentStream) {
                                                        [self.dbConnection
                                                         asyncReadWriteWithBlock:^(YapDatabaseReadWriteTransaction *_Nonnull transaction) {
                                                             [incomingMessage touchWithTransaction:transaction];
                                                         }];
                                                    }
                                                    failure:^(NSError *_Nonnull error) {
                                                        DDLogWarn(@"%@ failed to fetch contact avatar for message: %lu with error: %@",
                                                                  self.logTag,
                                                                  (unsigned long)incomingMessage.timestamp,
                                                                  error);
                                                    }];
        }
    }
    // In case we already have a read receipt for this new message (this happens sometimes).
    [OWSReadReceiptManager.sharedManager applyEarlyReadReceiptsForIncomingMessage:incomingMessage
                                                                      transaction:transaction];
    
    [[OWSDisappearingMessagesJob sharedJob] becomeConsistentWithConfigurationForMessage:incomingMessage
                                                                        contactsManager:self.contactsManager
                                                                            transaction:transaction];
    
    // Update thread preview in inbox
    [thread touchWithTransaction:transaction];
    
    [[TextSecureKitEnv sharedEnv].notificationsManager notifyUserForIncomingMessage:incomingMessage
                                                                           inThread:thread
                                                                    contactsManager:self.contactsManager
                                                                        transaction:transaction];
}

#pragma mark - helpers

- (BOOL)isDataMessageGroupAvatarUpdate:(OWSSignalServiceProtosDataMessage *)dataMessage
{
    return dataMessage.hasGroup && dataMessage.group.type == OWSSignalServiceProtosGroupContextTypeUpdate
    && dataMessage.group.hasAvatar;
}

/**
 * @returns
 *   Group or Contact thread for message, creating a new contact thread if necessary,
 *   but never creating a new group thread.
 */
- (nullable TSThread *)threadForEnvelope:(SSKEnvelope *)envelope
                             dataMessage:(OWSSignalServiceProtosDataMessage *)dataMessage
                             transaction:(YapDatabaseReadWriteTransaction *)transaction
{
    OWSAssert(envelope);
    OWSAssert(dataMessage);
    OWSAssert(transaction);
    
    NSDictionary *jsonPayload = [FLCCSMJSONService payloadDictionaryFromMessageBody:dataMessage.body];
    NSString *threadId = [jsonPayload objectForKey:@"threadId"];
    
    TSThread *thread = [TSThread getOrCreateThreadWithId:threadId transaction:transaction];
    
    
    return thread;
}

@end

NS_ASSUME_NONNULL_END
