//
//  PrivateBridge.h
//  VirtualApple
//
//  Created by whbex on 06.04.2025.
//

#import <Foundation/Foundation.h>
#import <Virtualization/Virtualization.h>

@interface _VZMacHardwareModelDescriptor : NSObject
- (void) setPlatformVersion:(NSInteger)version;
- (void) setISA:(NSInteger)isa;
- (void) setBoardID:(NSInteger)id;

@end

@interface VZMacHardwareModel (Private)
+ (VZMacHardwareModel *)_hardwareModelWithDescriptor:(_VZMacHardwareModelDescriptor *)descriptor;
@end

