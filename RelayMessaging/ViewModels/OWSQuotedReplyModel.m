//
//  Copyright (c) 2018 Open Whisper Systems. All rights reserved.
//

#import "OWSQuotedReplyModel.h"
#import "ConversationViewItem.h"
#import <RelayMessaging/RelayMessaging-Swift.h>
#import <RelayServiceKit/MIMETypeUtil.h>
#import <RelayServiceKit/OWSMessageSender.h>
#import <RelayServiceKit/TSAccountManager.h>
#import <RelayServiceKit/TSAttachmentPointer.h>
#import <RelayServiceKit/TSAttachmentStream.h>
#import <RelayServiceKit/TSIncomingMessage.h>
#import <RelayServiceKit/TSMessage.h>
#import <RelayServiceKit/TSOutgoingMessage.h>
#import <RelayServiceKit/TSQuotedMessage.h>
#import <RelayServiceKit/TSThread.h>

// View Model which has already fetched any thumbnail attachment.
@implementation OWSQuotedReplyModel

- (instancetype)initWithTimestamp:(uint64_t)timestamp
                         authorId:(NSString *)authorId
                             body:(NSString *_Nullable)body
                 attachmentStream:(nullable TSAttachmentStream *)attachmentStream
{
    return [self initWithTimestamp:timestamp
                          authorId:authorId
                              body:body
                    thumbnailImage:attachmentStream.thumbnailImage
                       contentType:attachmentStream.contentType
                    sourceFilename:attachmentStream.sourceFilename
                  attachmentStream:attachmentStream
        thumbnailAttachmentPointer:nil
           thumbnailDownloadFailed:NO];
}

- (instancetype)initWithTimestamp:(uint64_t)timestamp
                         authorId:(NSString *)authorId
                             body:(NSString *_Nullable)body
                   thumbnailImage:(nullable UIImage *)thumbnailImage;
{
    return [self initWithTimestamp:timestamp
                          authorId:authorId
                              body:body
                    thumbnailImage:thumbnailImage
                       contentType:nil
                    sourceFilename:nil
                  attachmentStream:nil
        thumbnailAttachmentPointer:nil
           thumbnailDownloadFailed:NO];
}

- (instancetype)initWithQuotedMessage:(TSQuotedMessage *)quotedMessage
                          transaction:(YapDatabaseReadTransaction *)transaction
{
    OWSAssert(quotedMessage.quotedAttachments.count <= 1);
    OWSAttachmentInfo *attachmentInfo = quotedMessage.quotedAttachments.firstObject;

    BOOL thumbnailDownloadFailed = NO;
    UIImage *_Nullable thumbnailImage;
    TSAttachmentPointer *attachmentPointer;
    if (attachmentInfo.thumbnailAttachmentStreamId) {
        TSAttachment *attachment =
            [TSAttachment fetchObjectWithUniqueID:attachmentInfo.thumbnailAttachmentStreamId transaction:transaction];

        TSAttachmentStream *attachmentStream;
        if ([attachment isKindOfClass:[TSAttachmentStream class]]) {
            attachmentStream = (TSAttachmentStream *)attachment;
            thumbnailImage = attachmentStream.image;
        }
    } else if (attachmentInfo.thumbnailAttachmentPointerId) {
        // download failed, or hasn't completed yet.
        TSAttachment *attachment =
            [TSAttachment fetchObjectWithUniqueID:attachmentInfo.thumbnailAttachmentPointerId transaction:transaction];

        if ([attachment isKindOfClass:[TSAttachmentPointer class]]) {
            attachmentPointer = (TSAttachmentPointer *)attachment;
            if (attachmentPointer.state == TSAttachmentPointerStateFailed) {
                thumbnailDownloadFailed = YES;
            }
        }
    }

    return [self initWithTimestamp:quotedMessage.timestamp
                          authorId:quotedMessage.authorId
                              body:quotedMessage.body
                    thumbnailImage:thumbnailImage
                       contentType:attachmentInfo.contentType
                    sourceFilename:attachmentInfo.sourceFilename
                  attachmentStream:nil
        thumbnailAttachmentPointer:attachmentPointer
           thumbnailDownloadFailed:thumbnailDownloadFailed];
}

- (instancetype)initWithTimestamp:(uint64_t)timestamp
                         authorId:(NSString *)authorId
                             body:(nullable NSString *)body
                   thumbnailImage:(nullable UIImage *)thumbnailImage
                      contentType:(nullable NSString *)contentType
                   sourceFilename:(nullable NSString *)sourceFilename
                 attachmentStream:(nullable TSAttachmentStream *)attachmentStream
       thumbnailAttachmentPointer:(nullable TSAttachmentPointer *)thumbnailAttachmentPointer
          thumbnailDownloadFailed:(BOOL)thumbnailDownloadFailed
{
    self = [super init];
    if (!self) {
        return self;
    }

    _timestamp = timestamp;
    _authorId = authorId;
    _body = body;
    _thumbnailImage = thumbnailImage;
    _contentType = contentType;
    _sourceFilename = sourceFilename;
    _attachmentStream = attachmentStream;
    _thumbnailAttachmentPointer = thumbnailAttachmentPointer;
    _thumbnailDownloadFailed = thumbnailDownloadFailed;

    return self;
}

- (TSQuotedMessage *)buildQuotedMessage
{
    NSArray *attachments = self.attachmentStream ? @[ self.attachmentStream ] : @[];

    return [[TSQuotedMessage alloc] initWithTimestamp:self.timestamp
                                             authorId:self.authorId
                                                 body:self.body
                          quotedAttachmentsForSending:attachments];
}

+ (nullable instancetype)quotedReplyForConversationViewItem:(ConversationViewItem *)conversationItem
                                                transaction:(YapDatabaseReadTransaction *)transaction;
{
    OWSAssert(conversationItem);
    OWSAssert(transaction);

    TSMessage *message = (TSMessage *)conversationItem.interaction;
    if (![message isKindOfClass:[TSMessage class]]) {
        OWSFail(@"%@ unexpected reply message: %@", self.logTag, message);
        return nil;
    }

    TSThread *thread = [message threadWithTransaction:transaction];
    OWSAssert(thread);

    uint64_t timestamp = message.timestamp;

    NSString *_Nullable authorId = ^{
        if ([message isKindOfClass:[TSOutgoingMessage class]]) {
            return [TSAccountManager localUID];
        } else if ([message isKindOfClass:[TSIncomingMessage class]]) {
            return [(TSIncomingMessage *)message authorId];
        } else {
            OWSFail(@"%@ Unexpected message type: %@", self.logTag, message.class);
            return (NSString * _Nullable) nil;
        }
    }();
    OWSAssert(authorId.length > 0);
    
    if (conversationItem.contactShare) {
        ContactShareViewModel *contactShare = conversationItem.contactShare;
        
        // TODO We deliberately always pass `nil` for `thumbnailImage`, even though we might have a contactShare.avatarImage
        // because the QuotedReplyViewModel has some hardcoded assumptions that only quoted attachments have
        // thumbnails. Until we address that we want to be consistent about neither showing nor sending the
        // contactShare avatar in the quoted reply.
        return [[OWSQuotedReplyModel alloc] initWithTimestamp:timestamp
                                                     authorId:authorId
                                                         body:[@"👤 " stringByAppendingString:contactShare.displayName]
                                               thumbnailImage:nil];
        
    }

    NSString *_Nullable quotedText = message.body;
    BOOL hasText = quotedText.length > 0;
    BOOL hasAttachment = NO;

    TSAttachment *_Nullable attachment = [message attachmentWithTransaction:transaction];
    TSAttachmentStream *quotedAttachment;
    if (attachment && [attachment isKindOfClass:[TSAttachmentStream class]]) {

        TSAttachmentStream *attachmentStream = (TSAttachmentStream *)attachment;

        // If the attachment is "oversize text", try the quote as a reply to text, not as
        // a reply to an attachment.
        if (!hasText && [OWSMimeTypeOversizeTextMessage isEqualToString:attachment.contentType]) {
            hasText = YES;
            quotedText = @"";

            NSData *_Nullable oversizeTextData = [NSData dataWithContentsOfFile:attachmentStream.filePath];
            if (oversizeTextData) {
                // We don't need to include the entire text body of the message, just
                // enough to render a snippet.  kOversizeTextMessageSizeThreshold is our
                // limit on how long text should be in protos since they'll be stored in
                // the database. We apply this constant here for the same reasons.
                NSString *_Nullable oversizeText =
                    [[NSString alloc] initWithData:oversizeTextData encoding:NSUTF8StringEncoding];
                // First, truncate to the rough max characters.
                NSString *_Nullable truncatedText =
                    [oversizeText substringToIndex:kOversizeTextMessageSizeThreshold - 1];
                // But kOversizeTextMessageSizeThreshold is in _bytes_, not characters,
                // so we need to continue to trim the string until it fits.
                while (truncatedText && truncatedText.length > 0 &&
                    [truncatedText dataUsingEncoding:NSUTF8StringEncoding].length
                        >= kOversizeTextMessageSizeThreshold) {
                    // A very coarse binary search by halving is acceptable, since
                    // kOversizeTextMessageSizeThreshold is much longer than our target
                    // length of "three short lines of text on any device we might
                    // display this on.
                    //
                    // The search will always converge since in the worst case (namely
                    // a single character which in utf-8 is >= 1024 bytes) the loop will
                    // exit when the string is empty.
                    truncatedText = [truncatedText substringToIndex:truncatedText.length / 2];
                }
                if ([truncatedText dataUsingEncoding:NSUTF8StringEncoding].length < kOversizeTextMessageSizeThreshold) {
                    quotedText = truncatedText;
                } else {
                    OWSFail(@"%@ Missing valid text snippet.", self.logTag);
                }
            }
        } else {
            quotedAttachment = attachmentStream;
            hasAttachment = YES;
        }
    }

    if (!hasText && !hasAttachment) {
        OWSFail(@"%@ quoted message has neither text nor attachment", self.logTag);
        quotedText = @"";
        hasText = YES;
    }

    return [[OWSQuotedReplyModel alloc] initWithTimestamp:timestamp
                                                 authorId:authorId
                                                     body:quotedText
                                         attachmentStream:quotedAttachment];
}


@end
