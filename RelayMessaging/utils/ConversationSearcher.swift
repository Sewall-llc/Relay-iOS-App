//
//  Copyright (c) 2018 Open Whisper Systems. All rights reserved.
//

import Foundation
import RelayServiceKit

public class ConversationSearchResult: Comparable {
    public let thread: ThreadViewModel

    public let messageId: String?
    public let messageDate: Date?

    public let snippet: String?

    private let sortKey: UInt64

    init(thread: ThreadViewModel, sortKey: UInt64, messageId: String? = nil, messageDate: Date? = nil, snippet: String? = nil) {
        self.thread = thread
        self.sortKey = sortKey
        self.messageId = messageId
        self.messageDate = messageDate
        self.snippet = snippet
    }

    // Mark: Comparable

    public static func < (lhs: ConversationSearchResult, rhs: ConversationSearchResult) -> Bool {
        return lhs.sortKey < rhs.sortKey
    }

    // MARK: Equatable

    public static func == (lhs: ConversationSearchResult, rhs: ConversationSearchResult) -> Bool {
        return lhs.thread.threadRecord.uniqueId == rhs.thread.threadRecord.uniqueId &&
            lhs.messageId == rhs.messageId
    }
}

public class ContactSearchResult: Comparable {
    public let relayRecipient: RelayRecipient
    public let contactsManager: ContactsManagerProtocol

    public var recipientId: String {
        return relayRecipient.uniqueId
    }

    init(relayRecipient: RelayRecipient, contactsManager: ContactsManagerProtocol) {
        self.relayRecipient = relayRecipient
        self.contactsManager = contactsManager
    }

    // Mark: Comparable

    public static func < (lhs: ContactSearchResult, rhs: ContactSearchResult) -> Bool {
        return lhs.contactsManager.compare(recipient: lhs.relayRecipient, with: rhs.relayRecipient) == .orderedAscending
    }

    // MARK: Equatable

    public static func == (lhs: ContactSearchResult, rhs: ContactSearchResult) -> Bool {
        return lhs.recipientId == rhs.recipientId
    }
}

public class SearchResultSet {
    public let searchText: String
    public let conversations: [ConversationSearchResult]
    public let contacts: [ContactSearchResult]
    public let messages: [ConversationSearchResult]

    public init(searchText: String, conversations: [ConversationSearchResult], contacts: [ContactSearchResult], messages: [ConversationSearchResult]) {
        self.searchText = searchText
        self.conversations = conversations
        self.contacts = contacts
        self.messages = messages
    }

    public class var empty: SearchResultSet {
        return SearchResultSet(searchText: "", conversations: [], contacts: [], messages: [])
    }

    public var isEmpty: Bool {
        return conversations.isEmpty && contacts.isEmpty && messages.isEmpty
    }
}

@objc
public class ConversationSearcher: NSObject {

    private let finder: FullTextSearchFinder

    @objc
    public static let shared: ConversationSearcher = ConversationSearcher()
    override private init() {
        finder = FullTextSearchFinder()
        super.init()
    }

    public func results(searchText: String,
                        transaction: YapDatabaseReadTransaction,
                        contactsManager: ContactsManagerProtocol) -> SearchResultSet {

        var conversations: [ConversationSearchResult] = []
        var contacts: [ContactSearchResult] = []
        var messages: [ConversationSearchResult] = []

        var existingConversationRecipientIds: Set<String> = Set()

        self.finder.enumerateObjects(searchText: searchText, transaction: transaction) { (match: Any, snippet: String?) in

            if let thread = match as? TSThread {
                let threadViewModel = ThreadViewModel(thread: thread, transaction: transaction)
                let sortKey = NSDate.ows_millisecondsSince1970(for: threadViewModel.lastMessageDate)
                let searchResult = ConversationSearchResult(thread: threadViewModel, sortKey: sortKey)

//                if let contactThread = thread as? TSThread {
//                    let recipientId = contactThread.contactIdentifier()
//                    existingConversationRecipientIds.insert(recipientId)
//                }

                conversations.append(searchResult)
            } else if let message = match as? TSMessage {
                let thread = message.thread(with: transaction)

                let threadViewModel = ThreadViewModel(thread: thread, transaction: transaction)
                let sortKey = message.timestamp
                let searchResult = ConversationSearchResult(thread: threadViewModel,
                                                            sortKey: sortKey,
                                                            messageId: message.uniqueId,
                                                            messageDate: NSDate.ows_date(withMillisecondsSince1970: message.timestamp),
                                                            snippet: snippet)

                messages.append(searchResult)
            } else if let relayRecipient = match as? RelayRecipient {
                let searchResult = ContactSearchResult(relayRecipient: relayRecipient, contactsManager: contactsManager)
                contacts.append(searchResult)
            } else {
                owsFail("\(self.logTag) in \(#function) unhandled item: \(match)")
            }
        }

        // Only show contacts which were not included in an existing 1:1 conversation.
        var otherContacts: [ContactSearchResult] = contacts.filter { !existingConversationRecipientIds.contains($0.recipientId) }

        // Order the conversation and message results in reverse chronological order.
        // The contact results are pre-sorted by display name.
        conversations.sort(by: >)
        messages.sort(by: >)
        // Order "other" contact results by display name.
        otherContacts.sort()

        return SearchResultSet(searchText: searchText, conversations: conversations, contacts: otherContacts, messages: messages)
    }

    @objc(filterThreads:withSearchText:)
    public func filterThreads(_ threads: [TSThread], searchText: String) -> [TSThread] {
        guard searchText.trimmingCharacters(in: .whitespacesAndNewlines).count > 0 else {
            return threads
        }

        return threads.filter { thread in
//            switch thread {
//            case let groupThread as TSGroupThread:
                return self.groupThreadSearcher.matches(item: thread, query: searchText)
//            case let contactThread as TSThread:
//                return self.contactThreadSearcher.matches(item: contactThread, query: searchText)
//            default:
//                owsFail("Unexpected thread type: \(thread)")
//                return false
//            }
        }
    }

    @objc(filterGroupThreads:withSearchText:)
    public func filterGroupThreads(_ groupThreads: [ TSThread ], searchText: String) -> [ TSThread ] {
        guard searchText.trimmingCharacters(in: .whitespacesAndNewlines).count > 0 else {
            return groupThreads
        }

        return groupThreads.filter { groupThread in
            return self.groupThreadSearcher.matches(item: groupThread, query: searchText)
        }
    }

    @objc(filterSignalAccounts:withSearchText:)
    public func filterSignalAccounts(_ signalAccounts: [SignalAccount], searchText: String) -> [SignalAccount] {
        guard searchText.trimmingCharacters(in: .whitespacesAndNewlines).count > 0 else {
            return signalAccounts
        }

        return signalAccounts.filter { signalAccount in
            self.signalAccountSearcher.matches(item: signalAccount, query: searchText)
        }
    }

    // MARK: Searchers

    private lazy var groupThreadSearcher: Searcher<TSThread> = Searcher { (groupThread: TSThread) in
        let groupName = groupThread.title
        let memberStrings = groupThread.participantIds.map { recipientId in
            self.indexingString(recipientId: recipientId)
            }.joined(separator: " ")

        return "\(memberStrings) \(groupName ?? "")"
    }

//    private lazy var contactThreadSearcher: Searcher<TSThread> = Searcher { (contactThread: TSThread) in
//        let recipientId = contactThread.contactIdentifier()
//        return self.indexingString(recipientId: recipientId)
//    }

    private lazy var signalAccountSearcher: Searcher<SignalAccount> = Searcher { (signalAccount: SignalAccount) in
        let recipientId = signalAccount.recipientId
        return self.indexingString(recipientId: recipientId)
    }

    private var contactsManager: FLContactsManager {
        return Environment.current()!.contactsManager
    }

    private func indexingString(recipientId: String) -> String {
        let recipientName = contactsManager.displayName(forRecipientId: recipientId)
        let tagName = contactsManager.recipient(withId: recipientId)?.flTag?.slug

        return "\(recipientId) \(recipientName ?? "") \(tagName ?? "")"
    }
}
