//
//  Copyright (c) 2018 Open Whisper Systems. All rights reserved.
//

import UIKit
import RelayServiceKit

@objc class GroupTableViewCell: UITableViewCell {

    let TAG = "[GroupTableViewCell]"

    private let avatarView = AvatarImageView()
    private let nameLabel = UILabel()
    private let subtitleLabel = UILabel()

    init() {
        super.init(style: .default, reuseIdentifier: TAG)

        // Font config
        nameLabel.font = .ows_dynamicTypeBody
        subtitleLabel.font = UIFont.ows_regularFont(withSize: 11.0)
        subtitleLabel.textColor = UIColor.FL_darkGray()

        // Layout

        avatarView.autoSetDimension(.width, toSize: CGFloat(kContactCellAvatarSize))
        avatarView.autoPinToSquareAspectRatio()

        let textRows = UIStackView(arrangedSubviews: [nameLabel, subtitleLabel])
        textRows.axis = .vertical
        textRows.alignment = .leading

        let columns = UIStackView(arrangedSubviews: [avatarView, textRows])
        columns.axis = .horizontal
        columns.alignment = .center
        columns.spacing = kContactCellAvatarTextMargin

        self.contentView.addSubview(columns)
        columns.autoPinEdgesToSuperviewMargins()
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc
    public func configure(thread: TSThread, contactsManager: FLContactsManager) {
        if let groupName = thread.title, !groupName.isEmpty {
            self.nameLabel.text = groupName
        } else {
            self.nameLabel.text = MessageStrings.newGroupDefaultTitle
        }

        let groupMemberIds: [String] = thread.participantIds
        let groupMemberNames = groupMemberIds.map { (recipientId: String) in
            contactsManager.displayName(forRecipientId: recipientId)!
        }.joined(separator: ", ")
        self.subtitleLabel.text = groupMemberNames

        self.avatarView.image = OWSAvatarBuilder.buildImage(thread: thread, diameter: kContactCellAvatarSize, contactsManager: contactsManager)
    }

}
