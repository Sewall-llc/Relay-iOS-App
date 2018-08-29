//
//  Copyright (c) 2018 Open Whisper Systems. All rights reserved.
//

import Foundation
import PromiseKit
import RelayServiceKit

@objc(OWSSessionResetJob)
public class SessionResetJob: NSObject {

    let TAG = "SessionResetJob"

    let recipientId: String
    let thread: TSThread
    let primaryStorage: OWSPrimaryStorage
    let messageSender: MessageSender

    @objc public required init(recipientId: String, thread: TSThread, messageSender: MessageSender, primaryStorage: OWSPrimaryStorage) {
        self.thread = thread
        self.recipientId = recipientId
        self.messageSender = messageSender
        self.primaryStorage = primaryStorage
    }

    func run() {
        Logger.info("\(TAG) Local user reset session.")

        let dbConnection = OWSPrimaryStorage.shared().newDatabaseConnection()
        dbConnection.asyncReadWrite { (transaction) in
            Logger.info("\(self.TAG) deleting sessions for recipient: \(self.recipientId)")
            self.primaryStorage.deleteAllSessions(forContact: self.recipientId, protocolContext: transaction)

            DispatchQueue.main.async {
                let endSessionMessage = EndSessionMessage(timestamp: NSDate.ows_millisecondTimeStamp(), in: self.thread)

                self.messageSender.enqueue(endSessionMessage, success: {
                    dbConnection.asyncReadWrite { (transaction) in
                        // Archive the just-created session since the recipient should delete their corresponding
                        // session upon receiving and decrypting our EndSession message.
                        // Otherwise if we send another message before them, they wont have the session to decrypt it.
                        self.primaryStorage.archiveAllSessions(forContact: self.recipientId, protocolContext: transaction)
                    }
                    Logger.info("\(self.TAG) successfully sent EndSessionMessage.")
                    let message = TSInfoMessage(timestamp: NSDate.ows_millisecondTimeStamp(),
                                                in: self.thread,
                                                infoMessageType: TSInfoMessageType.typeSessionDidEnd)
                    message.save()
                }, failure: {error in
                    dbConnection.asyncReadWrite { (transaction) in
                        // Even though this is the error handler - which means probably the recipient didn't receive the message
                        // there's a chance that our send did succeed and the server just timed out our repsonse or something.
                        // Since the cost of sending a future message using a session the recipient doesn't have is so high,
                        // we archive the session just in case.
                        //
                        // Archive the just-created session since the recipient should delete their corresponding
                        // session upon receiving and decrypting our EndSession message.
                        // Otherwise if we send another message before them, they wont have the session to decrypt it.
                        self.primaryStorage.archiveAllSessions(forContact: self.recipientId, protocolContext: transaction)
                    }
                    Logger.error("\(self.TAG) failed to send EndSessionMessage with error: \(error.localizedDescription)")
                })
            }
            }
        }

    @objc public class func run(thread: TSThread, messageSender: MessageSender, primaryStorage: OWSPrimaryStorage) {
        for uid in thread.participantIds {
            if uid != TSAccountManager.localUID() {
                let job = self.init(recipientId: uid,
                                    thread: thread,
                                    messageSender: messageSender,
                                    primaryStorage: primaryStorage)
                job.run()
           }
        }
    }
}