//
//  Copyright (c) 2018 Open Whisper Systems. All rights reserved.
//

#import "BlockListViewController.h"
#import "AddToBlockListViewController.h"
#import "BlockListUIUtils.h"
#import "ContactTableViewCell.h"
#import "ContactsViewHelper.h"
#import "OWSTableViewController.h"
#import "PhoneNumber.h"
#import "UIFont+OWS.h"
#import "UIView+OWS.h"
#import <RelayMessaging/Environment.h>
//#import <RelayMessaging/OWSContactsManager.h>
#import <RelayServiceKit/OWSBlockingManager.h>

NS_ASSUME_NONNULL_BEGIN

@interface BlockListViewController () <ContactsViewHelperDelegate>

@property (nonatomic, readonly) ContactsViewHelper *contactsViewHelper;

@property (nonatomic, readonly) OWSTableViewController *tableViewController;

@end

#pragma mark -

@implementation BlockListViewController

- (void)loadView
{
    [super loadView];

    _contactsViewHelper = [[ContactsViewHelper alloc] initWithDelegate:self];

    self.title
        = NSLocalizedString(@"SETTINGS_BLOCK_LIST_TITLE", @"Label for the block list section of the settings view");

    _tableViewController = [OWSTableViewController new];
    [self.view addSubview:self.tableViewController.view];
    [_tableViewController.view autoPinWidthToSuperview];
    [_tableViewController.view autoPinToTopLayoutGuideOfViewController:self withInset:0];
    [_tableViewController.view autoPinEdgeToSuperviewEdge:ALEdgeBottom];
    self.tableViewController.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableViewController.tableView.estimatedRowHeight = 60;

    [self updateTableContents];
}

#pragma mark - Table view data source

- (void)updateTableContents
{
    OWSTableContents *contents = [OWSTableContents new];

    __weak BlockListViewController *weakSelf = self;
    ContactsViewHelper *helper = self.contactsViewHelper;

    // Add section

    OWSTableSection *addSection = [OWSTableSection new];
    addSection.footerTitle = NSLocalizedString(
        @"BLOCK_BEHAVIOR_EXPLANATION", @"An explanation of the consequences of blocking another user.");

    [addSection
        addItem:[OWSTableItem
                    disclosureItemWithText:NSLocalizedString(@"SETTINGS_BLOCK_LIST_ADD_BUTTON",
                                               @"A label for the 'add phone number' button in the block list table.")
                               actionBlock:^{
                                   AddToBlockListViewController *vc = [[AddToBlockListViewController alloc] init];
                                   [weakSelf.navigationController pushViewController:vc animated:YES];
                               }]];
    [contents addSection:addSection];

    // Blocklist section

    OWSTableSection *blocklistSection = [OWSTableSection new];
    NSArray<NSString *> *blockedPhoneNumbers =
        [helper.blockedPhoneNumbers sortedArrayUsingSelector:@selector(compare:)];
    for (NSString *phoneNumber in blockedPhoneNumbers) {
        [blocklistSection addItem:[OWSTableItem
                                      itemWithCustomCellBlock:^{
                                          ContactTableViewCell *cell = [ContactTableViewCell new];
                                          [cell configureWithRecipientId:phoneNumber
                                                         contactsManager:helper.contactsManager];
                                          return cell;
                                      }
                                      customRowHeight:UITableViewAutomaticDimension
                                      actionBlock:^{
                                          [BlockListUIUtils showUnblockPhoneNumberActionSheet:phoneNumber
                                                                           fromViewController:weakSelf
                                                                              blockingManager:helper.blockingManager
                                                                              contactsManager:helper.contactsManager
                                                                              completionBlock:nil];
                                      }]];
    }
    [contents addSection:blocklistSection];

    self.tableViewController.contents = contents;
}

#pragma mark - ContactsViewHelperDelegate

- (void)contactsViewHelperDidUpdateContacts
{
    [self updateTableContents];
}

- (BOOL)shouldHideLocalNumber
{
    return YES;
}

@end

NS_ASSUME_NONNULL_END
