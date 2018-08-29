//
//  Copyright (c) 2018 Open Whisper Systems. All rights reserved.
//

#import "OWSQRCodeScanningViewController.h"
#import <RelayMessaging/OWSViewController.h>

NS_ASSUME_NONNULL_BEGIN

@class OWSLinkedDevicesTableViewController;

@interface OWSLinkDeviceViewController : OWSViewController <OWSQRScannerDelegate>

@property OWSLinkedDevicesTableViewController *linkedDevicesTableViewController;

- (void)controller:(OWSQRCodeScanningViewController *)controller didDetectQRCodeWithString:(NSString *)string;

@end

NS_ASSUME_NONNULL_END