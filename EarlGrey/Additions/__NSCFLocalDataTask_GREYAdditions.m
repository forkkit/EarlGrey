//
// Copyright 2016 Google Inc.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//      http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//

#import "Additions/__NSCFLocalDataTask_GREYAdditions.h"

#include <objc/runtime.h>

#import "Additions/NSURL+GREYAdditions.h"
#import "Common/GREYFatalAsserts.h"
#import "Common/GREYSwizzler.h"
#import "Synchronization/GREYAppStateTracker.h"
#import "Synchronization/GREYAppStateTrackerObject.h"

@implementation __NSCFLocalDataTask_GREYAdditions

+ (void)load {
  @autoreleasepool {
    GREYSwizzler *swizzler = [[GREYSwizzler alloc] init];
    // Note that we swizzle __NSCFLocalDataTask instead of NSURLSessionTask because on iOS 7.0
    // swizzling NSURLSessionTask causes a silent failure i.e. swizzling succeeds here but the
    // actual invocation of resume does not get routed to the swizzled method. Instead if we
    // swizzle __NSCFLocalDataTask it works on iOS 7.0 and 8.0. This is possibly because
    // __NSCFLocalDataTask is some kind of the internal class in use for iOS 7.0.
    Class class = NSClassFromString(@"__NSCFLocalDataTask");
    IMP newImplementation = [[self class] instanceMethodForSelector:@selector(greyswizzled_resume)];
    BOOL swizzleSuccess = [swizzler swizzleClass:class
                               addInstanceMethod:@selector(greyswizzled_resume)
                              withImplementation:newImplementation
                    andReplaceWithInstanceMethod:@selector(resume)];
    GREYFatalAssertWithMessage(swizzleSuccess, @"Could not swizzle resume in %@", class);

    newImplementation = [[self class] instanceMethodForSelector:@selector(greyswizzled_setState:)];
    // __NSCFLocalDataTask is the internal class used by NSURLSessionTask for web requests.
    swizzleSuccess = [swizzler swizzleClass:class
                          addInstanceMethod:@selector(greyswizzled_setState:)
                         withImplementation:newImplementation
               andReplaceWithInstanceMethod:NSSelectorFromString(@"setState:")];
    GREYFatalAssertWithMessage(swizzleSuccess, @"Could not swizzle setState in %@", class);
  }
}

#pragma mark - Swizzled Implementations

/**
 *  A swizzled implementation __NSCFLocalDataTask::resume, used for tracking tasks that are about to
 *  begin.
 */
- (void)greyswizzled_resume {
  NSURLSessionTask *task = (NSURLSessionTask *)self;
  if ([[task currentRequest].URL grey_shouldSynchronize]) {
    // Monitor the "state" value to synchronize with the task completion.
    GREYAppStateTrackerObject *object = TRACK_STATE_FOR_OBJECT(kGREYPendingNetworkRequest, self);
    // Use OBJC_ASSOCIATION_RETAIN here to make both reads and writes atomic.
    // The method below (setState:) which reads and writes this associated object can be
    // invoked on background threads. This can cause a race condition where the object
    // is set to nil by one thread and read by another. The read gets a deallocated
    // instance of the object back which causes EXC_BAD_ACCESS. Using OBJC_ASSOCIATION_RETAIN
    // prevents this.
    objc_setAssociatedObject(self,
                             @selector(greyswizzled_setState:),
                             object,
                             OBJC_ASSOCIATION_RETAIN);
  }
  INVOKE_ORIGINAL_IMP(void, @selector(greyswizzled_resume));
}

/**
 *  A swizzled implementation __NSCFLocalDataTask::setState:, used for tracking state changes.
 *
 *  @param newState The new state value to be set.
 */
- (void)greyswizzled_setState:(NSURLSessionTaskState)newState {
  GREYAppStateTrackerObject *object =
      objc_getAssociatedObject(self, @selector(greyswizzled_setState:));
  if (object) {
    BOOL terminalState = (newState == NSURLSessionTaskStateCompleted) ||
        (newState == NSURLSessionTaskStateSuspended);
    if (terminalState) {
      UNTRACK_STATE_FOR_OBJECT(kGREYPendingNetworkRequest, object);
      objc_setAssociatedObject(self,
                               @selector(greyswizzled_setState:),
                               nil,
                               OBJC_ASSOCIATION_ASSIGN);
    }
  }
  INVOKE_ORIGINAL_IMP1(void,
                       @selector(greyswizzled_setState:),
                       newState);
}

@end
