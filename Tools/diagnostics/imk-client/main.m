#import <Cocoa/Cocoa.h>
#import <CoreFoundation/CoreFoundation.h>
#import <InputMethodKit/InputMethodKit.h>
#import <objc/runtime.h>
#import "IMKClientFixture.h"

static const NSTimeInterval ConnectionTimeoutSeconds = 5;
static const NSTimeInterval ServerLifetimeSeconds = 60;

// Each invocation is a separate process. Objective-C exceptions are reported;
// an abort or runtime trap is observed by the Python parent instead.
static void Emit(NSDictionary *fields) {
    NSData *encoded = [NSJSONSerialization dataWithJSONObject:fields options:0 error:nil];
    fwrite(encoded.bytes, 1, encoded.length, stdout);
    fputc('\n', stdout);
    fflush(stdout);
}

static NSString *RuntimeClass(id object) {
    return object ? @(object_getClassName(object)) : @"nil";
}

static NSDictionary *ClientDescription(id object) {
    return @{
        @"nil": @(object == nil),
        @"runtimeClass": RuntimeClass(object),
        @"isProxy": @(object && [object isProxy]),
        @"conformsToIMKTextInput": @(object && [object conformsToProtocol:@protocol(IMKTextInput)])
    };
}

@interface IMKInheritedDefaultController : IMKInputController
@end
@implementation IMKInheritedDefaultController
@end

static int ServeClient(NSString *name) {
    NSConnection *connection = [[NSConnection alloc] initWithReceivePort:[NSMachPort port] sendPort:nil];
    NSObject *client = [IMKDiagnosticClientFactory make];
    [connection setRootObject:client];
    if (![connection registerName:name]) {
        Emit(@{@"phase": @"server", @"registered": @NO});
        return 2;
    }
    Emit(@{@"phase": @"server", @"registered": @YES, @"client": ClientDescription(client)});
    // The parent stops only this child after the proxy case. The deadline is
    // an additional bound if the parent is interrupted.
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:ServerLifetimeSeconds];
    while ([connection isValid] && [deadline timeIntervalSinceNow] > 0) {
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:deadline];
    }
    [connection invalidate];
    return 0;
}

static int Diagnose(NSString *caseName, NSString *connectionName) {
    [NSApplication sharedApplication];
    Class controllerClass = [IMKInputController class];
    if ([caseName isEqualToString:@"nil-client-override"]) {
        controllerClass = [IMKNilClientOverrideController class];
    } else if ([caseName isEqualToString:@"default-init"]) {
        controllerClass = [IMKInheritedDefaultController class];
    }

    NSString *identifier = [@"dev.azookey.diagnose.imk." stringByAppendingString:[NSUUID UUID].UUIDString];
    NSString *serverName = [identifier stringByAppendingString:@".connection"];
    NSURL *directory = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:identifier]];
    NSURL *bundleURL = [directory URLByAppendingPathComponent:@"InputMethodTests.bundle"];
    NSURL *contentsURL = [bundleURL URLByAppendingPathComponent:@"Contents"];
    NSError *directoryError = nil;
    if (![[NSFileManager defaultManager] createDirectoryAtURL:contentsURL
                                withIntermediateDirectories:YES attributes:nil error:&directoryError]) {
        Emit(@{@"phase": @"bundle", @"error": directoryError.description ?: @"unknown"});
        return 3;
    }
    NSDictionary *properties = @{
        @"CFBundleIdentifier": identifier,
        @"CFBundleName": @"InputMethodTests",
        @"CFBundlePackageType": @"BNDL",
        @"CFBundleVersion": @"1",
        @"LSBackgroundOnly": @YES,
        @"InputMethodConnectionName": serverName,
        @"InputMethodServerControllerClass": NSStringFromClass(controllerClass),
        @"tsInputMethodCharacterRepertoireKey": @[@"Latn", @"Hira", @"Kana"]
    };
    if (![properties writeToURL:[contentsURL URLByAppendingPathComponent:@"Info.plist"] atomically:YES]) {
        Emit(@{@"phase": @"bundle", @"error": @"metadata write failed"});
        return 3;
    }
    CFBundleRef registeredBundle = CFBundleCreate(kCFAllocatorDefault, (__bridge CFURLRef)bundleURL);
    BOOL coreResolved = CFBundleGetBundleWithIdentifier((__bridge CFStringRef)identifier) != NULL;
    NSBundle *bundle = [NSBundle bundleWithIdentifier:identifier];
    Emit(@{@"phase": @"bundle", @"coreResolved": @(coreResolved),
           @"foundationResolved": @(bundle != nil), @"controllerClass": NSStringFromClass(controllerClass)});
    if (!registeredBundle || !coreResolved || !bundle) {
        return 4;
    }

    IMKServer *server = [[IMKServer alloc] initWithName:serverName bundleIdentifier:identifier];
    Emit(@{@"phase": @"server", @"initialized": @(server != nil)});
    if (!server) {
        return 5;
    }

    id suppliedClient = nil;
    NSConnection *clientConnection = nil;
    if ([caseName isEqualToString:@"direct-client"]) {
        suppliedClient = [IMKDiagnosticClientFactory make];
    } else if ([caseName isEqualToString:@"connection-root-proxy"]) {
        clientConnection = [NSConnection connectionWithRegisteredName:connectionName host:nil];
        [clientConnection setReplyTimeout:ConnectionTimeoutSeconds];
        [clientConnection setRequestTimeout:ConnectionTimeoutSeconds];
        suppliedClient = [clientConnection rootProxy];
        if (!suppliedClient) {
            Emit(@{@"phase": @"proxy", @"initialized": @NO});
            return 6;
        }
        [suppliedClient setProtocolForProxy:@protocol(IMKTextInput)];
    }
    Emit(@{@"phase": @"before-controller", @"suppliedClient": ClientDescription(suppliedClient)});

    IMKInputController *controller = nil;
    if ([caseName isEqualToString:@"nil-client-override"]) {
        controller = [[IMKNilClientOverrideController alloc] initWithServer:server];
    } else if ([caseName isEqualToString:@"default-init"]) {
#if INCLUDE_DEFAULT_INITIALIZER
        controller = [[IMKInheritedDefaultController alloc] init];
#else
        Emit(@{@"phase": @"controller", @"error": @"default initializer not compiled in this executable"});
        return 7;
#endif
    } else {
        controller = [[IMKInputController alloc] initWithServer:server delegate:nil client:suppliedClient];
    }
    Emit(@{@"phase": @"controller", @"initialized": @(controller != nil),
           @"runtimeClass": RuntimeClass(controller)});
    if (!controller) {
        return 8;
    }

    id<IMKTextInput, NSObject> returnedClient = [controller client];
    Emit(@{@"phase": @"client-return", @"client": ClientDescription(returnedClient)});
    if (returnedClient) {
        [returnedClient setMarkedText:@"診断" selectionRange:NSMakeRange(2, 0)
                    replacementRange:NSMakeRange(NSNotFound, 0)];
        NSUInteger markedLength = [returnedClient length];
        [returnedClient insertText:@"確定" replacementRange:NSMakeRange(NSNotFound, 0)];
        Emit(@{@"phase": @"calls", @"markedLength": @(markedLength),
               @"lengthAfterInsert": @([returnedClient length]),
               @"identifier": [returnedClient uniqueClientIdentifierString] ?: @"nil",
               @"supportsUnicode": @([returnedClient supportsUnicode])});
    }
    // Keep the registered bundle and the peer available through controller
    // teardown so an initialization result is not confused with fixture cleanup.
    returnedClient = nil;
    controller = nil;
    server = nil;
    [clientConnection invalidate];
    CFRelease(registeredBundle);
    [[NSFileManager defaultManager] removeItemAtURL:directory error:nil];
    return 0;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSString *caseName = argc > 1 ? @(argv[1]) : @"missing-case";
        NSString *connectionName = argc > 2 ? @(argv[2]) : @"";
        Emit(@{@"phase": @"start", @"case": caseName});
        @try {
            if ([caseName isEqualToString:@"serve-client"]) {
                return ServeClient(connectionName);
            }
            return Diagnose(caseName, connectionName);
        } @catch (NSException *exception) {
            Emit(@{@"phase": @"exception", @"name": exception.name ?: @"nil",
                   @"reason": exception.reason ?: @"nil"});
            return 10;
        }
    }
}
