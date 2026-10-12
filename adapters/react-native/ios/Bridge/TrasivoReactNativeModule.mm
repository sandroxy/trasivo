#import <React/RCTEventEmitter.h>
#import <React/RCTUtils.h>
#import "TrasivoReactNative-Swift.h"
#ifdef RCT_NEW_ARCH_ENABLED
#import <TrasivoSpec/TrasivoSpec.h>
#endif

@interface TrasivoReactNativeModule : RCTEventEmitter
#ifdef RCT_NEW_ARCH_ENABLED
<NativeTrasivoSpec>
#endif
@end

@implementation TrasivoReactNativeModule {
    TrasivoReactNativeCoordinator *_coordinator;
    BOOL _listening;
    BOOL _invalidated;
}
RCT_EXPORT_MODULE(Trasivo)
+ (BOOL)requiresMainQueueSetup { return YES; }
- (dispatch_queue_t)methodQueue { return dispatch_get_main_queue(); }
- (NSArray<NSString *> *)supportedEvents { return @[@"TrasivoEvent"]; }
- (void)startObserving { _listening = YES; }
- (void)stopObserving { _listening = NO; }

RCT_EXPORT_METHOD(execute:(NSString *)payload
                  resolve:(RCTPromiseResolveBlock)resolve
                  reject:(RCTPromiseRejectBlock)reject)
{
    if (_invalidated) {
        reject(@"runtime_closed", @"Trasivo runtime has closed.", nil);
        return;
    }
    if (!_coordinator) {
        __weak TrasivoReactNativeModule *weakSelf = self;
        _coordinator = [[TrasivoReactNativeCoordinator alloc]
            initWithEmit:^(NSString *event) {
                TrasivoReactNativeModule *owner = weakSelf;
                if (owner && owner->_listening) [owner sendEventWithName:@"TrasivoEvent" body:event];
            }
            presenter:^UIViewController * { return RCTPresentedViewController(); }];
    }
    [_coordinator execute:payload completion:^(NSString *result, NSString *error) {
        if (error) reject(error, @"Trasivo could not perform this operation.", nil);
        else resolve(result);
    }];
}

- (void)invalidate
{
    dispatch_async(dispatch_get_main_queue(), ^{
        self->_invalidated = YES;
        self->_listening = NO;
        [self->_coordinator close];
        self->_coordinator = nil;
    });
    [super invalidate];
}
#ifdef RCT_NEW_ARCH_ENABLED
- (std::shared_ptr<facebook::react::TurboModule>)getTurboModule:
    (const facebook::react::ObjCTurboModule::InitParams &)params
{
    return std::make_shared<facebook::react::NativeTrasivoSpecJSI>(params);
}
#endif
@end
