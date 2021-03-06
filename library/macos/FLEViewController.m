// Copyright 2018 Google LLC
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

#import "FLEViewController.h"
#import "FLEViewController+Internal.h"

#import <FlutterEmbedder/FlutterEmbedder.h>

#import "FLEBasicMessageChannel.h"
#import "FLEJSONMessageCodec.h"
#import "FLEReshapeListener.h"
#import "FLETextInputPlugin.h"
#import "FLEView.h"

static NSString *const kXcodeExtraArgumentOne = @"-NSDocumentRevisionsDebugMode";
static NSString *const kXcodeExtraArgumentTwo = @"YES";

static NSString *const kICUBundleID = @"io.flutter.flutter_embedder";
static NSString *const kICUBundlePath = @"icudtl.dat";

static const int kDefaultWindowFramebuffer = 0;

#pragma mark - Private interface declaration.

/**
 * Private interface declaration for FLEViewController.
 */
@interface FLEViewController ()

/**
 * A list of additional responders to keyboard events. Keybord events are forwarded to all of them.
 */
@property NSMutableOrderedSet<NSResponder *> *additionalKeyResponders;

/**
 * Creates and registers plugins used by this view controller.
 */
- (void)addInternalPlugins;

/**
 * Identical to the public API except that |main| and |packages| are nullable (and assets and main
 * are swapped to make it clearer that they are the nullable pair; the public API is staying the
 * same for now to avoid needless thrashing for code using it). Per the TODO in the header, this API
 * should be reworked once we have decided whether both versions will stay.
 *
 * If main is nil, the engine will run in snapshot mode.
 */
- (BOOL)launchEngineInternalWithAssetsPath:(nonnull NSURL *)assets
                                  mainPath:(nullable NSURL *)main
                              packagesPath:(nullable NSURL *)packages
                                asHeadless:(BOOL)headless
                      commandLineArguments:(nonnull NSArray<NSString *> *)arguments;

/**
 * Creates a render config with callbacks based on whether the embedder is being run as a headless
 * server.
 */
+ (FlutterRendererConfig)createRenderConfigHeadless:(BOOL)headless;

/**
 * Creates the OpenGL context used as the resource context by the engine.
 */
- (void)createResourceContext;

/**
 * Makes the OpenGL context used by the engine for rendering optimization the
 * current context.
 */
- (void)makeResourceContextCurrent;

/**
 * Responds to system messages sent to this controller from the Flutter engine.
 */
- (void)handlePlatformMessage:(const FlutterPlatformMessage *)message;

/**
 * Converts |event| to a FlutterPointerEvent with the given phase, and sends it to the engine.
 */
- (void)dispatchMouseEvent:(nonnull NSEvent *)event phase:(FlutterPointerPhase)phase;

/**
 * Converts |event| to a key event channel message, and sends it to the engine.
 */
- (void)dispatchKeyEvent:(NSEvent *)event ofType:(NSString *)type;

/**
 * Converts |event| to a mouse event channel message, and sends it to the engine.
 */
- (void)dispatchExtendedMouseEvent:(NSEvent *)event ofType:(NSString *)type;

@end

#pragma mark - Static methods provided to engine configuration

/**
 * Makes the owned FlutterView the current context.
 */
static bool OnMakeCurrent(FLEViewController *controller) {
  [controller.view makeCurrentContext];
  return true;
}

/**
 * Clears the current context.
 */
static bool OnClearCurrent(FLEViewController *controller) {
  [NSOpenGLContext clearCurrentContext];
  return true;
}

/**
 * Flushes the GL context as part of the Flutter rendering pipeline.
 */
static bool OnPresent(FLEViewController *controller) {
  [controller.view onPresent];
  return true;
}

/**
 * Returns the framebuffer object whose color attachment the engine should render into.
 */
static uint32_t OnFBO(FLEViewController *controller) { return kDefaultWindowFramebuffer; }

/**
 * Handles the given platform message by dispatching to the controller.
 */
static void OnPlatformMessage(const FlutterPlatformMessage *message,
                              FLEViewController *controller) {
  [controller handlePlatformMessage:message];
}

/**
 * Makes the resource context the current context.
 */
static bool OnMakeResourceCurrent(FLEViewController *controller) {
  [controller makeResourceContextCurrent];
  return true;
}

#pragma mark Static methods provided for headless engine configuration

static bool HeadlessOnMakeCurrent(FLEViewController *controller) { return false; }

static bool HeadlessOnClearCurrent(FLEViewController *controller) { return false; }

static bool HeadlessOnPresent(FLEViewController *controller) { return false; }

static uint32_t HeadlessOnFBO(FLEViewController *controller) { return kDefaultWindowFramebuffer; }

static bool HeadlessOnMakeResourceCurrent(FLEViewController *controller) { return false; }

#pragma mark - FLEViewController implementation.

@implementation FLEViewController {
  FlutterEngine _engine;

  // The additional context provided to the Flutter engine for resource loading.
  NSOpenGLContext *_resourceContext;

  // A mapping of channel names to the registered handlers for those channels.
  NSMutableDictionary<NSString *, FLEBinaryMessageHandler> *_messageHandlers;

  // The plugin used to handle text input. This is not an FLEPlugin, so must be owned separately.
  FLETextInputPlugin *_textInputPlugin;

  // A message channel for passing key events to the Flutter engine. This should be replaced with
  // an embedding API; see Issue #47.
  FLEBasicMessageChannel *_keyEventChannel;

  // A message channel for passing extended mouse events.
  FLEBasicMessageChannel *_mouseExtensionsEventChannel;

  // A method channel for reading/saving.
  FLEMethodChannel *_ioChannel;
}

@dynamic view;

/**
 * Performs initialization that's common between the different init paths.
 */
static void CommonInit(FLEViewController *controller) {
  controller->_messageHandlers = [[NSMutableDictionary alloc] init];
  controller->_additionalKeyResponders = [[NSMutableOrderedSet alloc] init];
}

- (instancetype)initWithCoder:(NSCoder *)coder {
  self = [super initWithCoder:coder];
  if (self != nil) {
    CommonInit(self);
  }
  return self;
}

- (instancetype)initWithNibName:(NSString *)nibNameOrNil bundle:(NSBundle *)nibBundleOrNil {
  self = [super initWithNibName:nibNameOrNil bundle:nibBundleOrNil];
  if (self != nil) {
    CommonInit(self);
  }
  return self;
}

- (void)dealloc {
  if (FlutterEngineShutdown(_engine) == kSuccess) {
    _engine = NULL;
  }
}

- (void)loadView {
  self.view = [[FLEView alloc] init];
}

#pragma mark - Public methods

- (BOOL)launchEngineWithAssetsPath:(NSURL *)assets
                        asHeadless:(BOOL)headless
              commandLineArguments:(NSArray<NSString *> *)arguments {
  return [self launchEngineInternalWithAssetsPath:assets
                                         mainPath:nil
                                     packagesPath:nil
                                       asHeadless:headless
                             commandLineArguments:arguments];
}

- (BOOL)launchEngineWithMainPath:(NSURL *)main
                      assetsPath:(NSURL *)assets
                    packagesPath:(NSURL *)packages
                      asHeadless:(BOOL)headless
            commandLineArguments:(NSArray<NSString *> *)arguments {
  return [self launchEngineInternalWithAssetsPath:assets
                                         mainPath:main
                                     packagesPath:packages
                                       asHeadless:headless
                             commandLineArguments:arguments];
}

- (id<FLEPluginRegistrar>)registrarForPlugin:(NSString *)pluginName {
  // Currently, the view controller acts as the registrar for all plugins, so the
  // name is ignored. It is part of the API to reduce churn in the future when
  // aligning more closely with the Flutter registrar system.
  return self;
}

#pragma mark - Framework-internal methods

- (void)addKeyResponder:(NSResponder *)responder {
  [self.additionalKeyResponders addObject:responder];
}

- (void)removeKeyResponder:(NSResponder *)responder {
  [self.additionalKeyResponders removeObject:responder];
}

#pragma mark - Private methods

- (void)addInternalPlugins {
  _textInputPlugin = [[FLETextInputPlugin alloc] initWithViewController:self];
  _keyEventChannel =
      [FLEBasicMessageChannel messageChannelWithName:@"flutter/keyevent"
                                     binaryMessenger:self
                                               codec:[FLEJSONMessageCodec sharedInstance]];
  _mouseExtensionsEventChannel =
      [FLEBasicMessageChannel messageChannelWithName:@"flutter/mouseExtensions"
                                     binaryMessenger:self
                                               codec:[FLEJSONMessageCodec sharedInstance]];
  _ioChannel = [FLEMethodChannel methodChannelWithName:@"flutter/ioExtensions"
                                       binaryMessenger:self
                                                 codec:[FLEJSONMethodCodec sharedInstance]];
  __weak FLEViewController *weakSelf = self;
  [_ioChannel setMethodCallHandler:^(FLEMethodCall *call, FLEMethodResult result) {
    [weakSelf handleIOMethodCall:call result:result];
  }];
}

- (void)handleIOMethodCall:(FLEMethodCall *)call result:(FLEMethodResult)result {
  NSString *method = call.methodName;
  if ([method isEqualToString:@"write"]) {
    NSString *filename = call.arguments[0];
    NSString *contents = call.arguments[1];
    NSString* filepath = [filename stringByReplacingOccurrencesOfString: @"~" withString:NSHomeDirectory()];
    NSError *error;
    [contents writeToFile:filepath atomically:YES encoding:NSUTF8StringEncoding error:&error];
    if(error != nil)
    {
      result([[FLEMethodError alloc] initWithCode:@"error"
                                  message:@"Failed to write to file"
                                  details:nil]);
    }
    else
    {
      result(nil);
    }
  } else if ([method isEqualToString:@"read"]) {
    NSString *filename = call.arguments[0];
    NSError *error;
    NSString* filepath = [filename stringByReplacingOccurrencesOfString: @"~" withString:NSHomeDirectory()];
    NSString *fileContents = [NSString stringWithContentsOfFile:filepath encoding:NSUTF8StringEncoding error:&error];
    result(fileContents);
  } else {
    NSLog(@"Unhandled text input method '%@'", method);
    result(FLEMethodNotImplemented);
  }
  
}

- (BOOL)launchEngineInternalWithAssetsPath:(NSURL *)assets
                                  mainPath:(NSURL *)main
                              packagesPath:(NSURL *)packages
                                asHeadless:(BOOL)headless
                      commandLineArguments:(NSArray<NSString *> *)arguments {
  if (_engine != NULL) {
    return NO;
  }

  // Set up the resource context. This is done here rather than in viewDidLoad as there's no
  // guarantee that viewDidLoad will be called before the engine is started, and the context must
  // be valid by that point.
  [self createResourceContext];

  const FlutterRendererConfig config = [FLEViewController createRenderConfigHeadless:headless];

  // Register internal plugins before starting the engine.
  [self addInternalPlugins];

  // Strip out the Xcode-added -NSDocumentRevisionsDebugMode YES.
  // TODO: Improve command line argument handling.
  const unsigned long argc = arguments.count;
  unsigned long unused = 0;
  const char **command_line_args = (const char **)malloc(argc * sizeof(const char *));
  for (int i = 0; i < argc; ++i) {
    if ([arguments[i] isEqualToString:kXcodeExtraArgumentOne] && (i + 1 < argc) &&
        [arguments[i + 1] isEqualToString:kXcodeExtraArgumentTwo]) {
      unused += 2;
      ++i;
      continue;
    }
    command_line_args[i - unused] = [arguments[i] UTF8String];
  }

  NSString *icuData = [[NSBundle bundleWithIdentifier:kICUBundleID] pathForResource:kICUBundlePath
                                                                             ofType:nil];

  const FlutterProjectArgs args = {
      .struct_size = sizeof(FlutterProjectArgs),
      .assets_path = assets.fileSystemRepresentation,
      .main_path = (main != nil) ? main.fileSystemRepresentation : "",
      .packages_path = (packages != nil) ? packages.fileSystemRepresentation : "",
      .icu_data_path = icuData.UTF8String,
      .command_line_argc = (int)(argc - unused),
      .command_line_argv = command_line_args,
      .platform_message_callback = (FlutterPlatformMessageCallback)OnPlatformMessage,
  };

  BOOL result = FlutterEngineRun(FLUTTER_ENGINE_VERSION, &config, &args, (__bridge void *)(self),
                                 &_engine) == kSuccess;
  free(command_line_args);
  return result;
}

+ (FlutterRendererConfig)createRenderConfigHeadless:(BOOL)headless {
  if (headless) {
    const FlutterRendererConfig config = {
        .type = kOpenGL,
        .open_gl.struct_size = sizeof(FlutterOpenGLRendererConfig),
        .open_gl.make_current = (BoolCallback)HeadlessOnMakeCurrent,
        .open_gl.clear_current = (BoolCallback)HeadlessOnClearCurrent,
        .open_gl.present = (BoolCallback)HeadlessOnPresent,
        .open_gl.fbo_callback = (UIntCallback)HeadlessOnFBO,
        .open_gl.make_resource_current = (BoolCallback)HeadlessOnMakeResourceCurrent};
    return config;
  } else {
    const FlutterRendererConfig config = {
        .type = kOpenGL,
        .open_gl.struct_size = sizeof(FlutterOpenGLRendererConfig),
        .open_gl.make_current = (BoolCallback)OnMakeCurrent,
        .open_gl.clear_current = (BoolCallback)OnClearCurrent,
        .open_gl.present = (BoolCallback)OnPresent,
        .open_gl.fbo_callback = (UIntCallback)OnFBO,
        .open_gl.make_resource_current = (BoolCallback)OnMakeResourceCurrent};
    return config;
  }
}

- (void)createResourceContext {
  NSOpenGLContext *viewContext = ((NSOpenGLView *)self.view).openGLContext;
  _resourceContext = [[NSOpenGLContext alloc] initWithFormat:viewContext.pixelFormat
                                                shareContext:viewContext];
}

- (void)makeResourceContextCurrent {
  [_resourceContext makeCurrentContext];
}

- (void)handlePlatformMessage:(const FlutterPlatformMessage *)message {
  NSData *messageData = [NSData dataWithBytesNoCopy:(void *)message->message
                                             length:message->message_size
                                       freeWhenDone:NO];
  NSString *channel = @(message->channel);
  __block const FlutterPlatformMessageResponseHandle *responseHandle = message->response_handle;

  FLEBinaryReply binaryResponseHandler = ^(NSData *response) {
    if (responseHandle) {
      FlutterEngineSendPlatformMessageResponse(self->_engine, responseHandle, response.bytes,
                                               response.length);
      responseHandle = NULL;
    } else {
      NSLog(@"Error: Message responses can be sent only once. Ignoring duplicate response "
             "on channel '%@'.",
            channel);
    }
  };

  FLEBinaryMessageHandler channelHandler = _messageHandlers[channel];
  if (channelHandler) {
    channelHandler(messageData, binaryResponseHandler);
  } else {
    binaryResponseHandler(nil);
  }
}

- (void)dispatchMouseEvent:(NSEvent *)event phase:(FlutterPointerPhase)phase {
  NSPoint locationInView = [self.view convertPoint:event.locationInWindow fromView:nil];
  NSPoint locationInBackingCoordinates = [self.view convertPointToBacking:locationInView];
  const FlutterPointerEvent flutterEvent = {
      .struct_size = sizeof(flutterEvent),
      .phase = phase,
      .x = locationInBackingCoordinates.x,
      .y = -locationInBackingCoordinates.y,  // convertPointToBacking makes this negative.
      .timestamp = event.timestamp * NSEC_PER_MSEC,
  };
  FlutterEngineSendPointerEvent(_engine, &flutterEvent, 1);
}

- (void)dispatchExtendedMouseEvent:(NSEvent *)event ofType:(NSString *)type {
  NSPoint locationInView = [self.view convertPoint:event.locationInWindow fromView:nil];
  NSPoint locationInBackingCoordinates = [self.view convertPointToBacking:locationInView];
  
  [_mouseExtensionsEventChannel sendMessage:@{
    @"type" : type,
    @"x" : @(locationInBackingCoordinates.x),
    @"y" : @(locationInBackingCoordinates.y)
  }];
}

- (void)dispatchKeyEvent:(NSEvent *)event ofType:(NSString *)type {
  [_keyEventChannel sendMessage:@{
    @"keymap" : @"android",
    @"type" : type,
    @"keyCode" : @(event.keyCode),
  }];
}

#pragma mark - FLEReshapeListener

/**
 * Responds to view reshape by notifying the engine of the change in dimensions.
 */
- (void)viewDidReshape:(NSOpenGLView *)view {
  CGRect scaledBounds = [view convertRectToBacking:view.bounds];
  const FlutterWindowMetricsEvent event = {
      .struct_size = sizeof(event),
      .width = scaledBounds.size.width,
      .height = scaledBounds.size.height,
      .pixel_ratio = scaledBounds.size.width / view.bounds.size.width,
  };
  FlutterEngineSendWindowMetricsEvent(_engine, &event);
}

#pragma mark - FLEBinaryMessenger

- (void)sendOnChannel:(nonnull NSString *)channel message:(nullable NSData *)message {
  FlutterPlatformMessage platformMessage = {
      .struct_size = sizeof(FlutterPlatformMessage),
      .channel = [channel UTF8String],
      .message = message.bytes,
      .message_size = message.length,
  };

  FlutterResult result = FlutterEngineSendPlatformMessage(_engine, &platformMessage);
  if (result != kSuccess) {
    NSLog(@"Failed to send message to Flutter engine on channel '%@' (%d).", channel, result);
  }
}

- (void)setMessageHandlerOnChannel:(nonnull NSString *)channel
              binaryMessageHandler:(nullable FLEBinaryMessageHandler)handler {
  _messageHandlers[channel] = [handler copy];
}

#pragma mark - FLEPluginRegistrar

- (id<FLEBinaryMessenger>)messenger {
  return self;
}

- (void)addMethodCallDelegate:(nonnull id<FLEPlugin>)delegate
                      channel:(nonnull FLEMethodChannel *)channel {
  [channel setMethodCallHandler:^(FLEMethodCall *call, FLEMethodResult result) {
    [delegate handleMethodCall:call result:result];
  }];
}

#pragma mark - NSResponder

- (BOOL)acceptsFirstResponder {
  return YES;
}

- (BOOL)acceptsMouseMovedEvents {
  return YES;
}

- (void)keyDown:(NSEvent *)event {
  [self dispatchKeyEvent:event ofType:@"keydown"];
  for (NSResponder *responder in self.additionalKeyResponders) {
    if ([responder respondsToSelector:@selector(keyDown:)]) {
      [responder keyDown:event];
    }
  }
}

- (void)keyUp:(NSEvent *)event {
  [self dispatchKeyEvent:event ofType:@"keyup"];
  for (NSResponder *responder in self.additionalKeyResponders) {
    if ([responder respondsToSelector:@selector(keyUp:)]) {
      [responder keyUp:event];
    }
  }
}

- (void)mouseDown:(NSEvent *)event {
  [self dispatchMouseEvent:event phase:kDown];
}

- (void)mouseUp:(NSEvent *)event {
  [self dispatchMouseEvent:event phase:kUp];
}

- (void)mouseDragged:(NSEvent *)event {
  [self dispatchMouseEvent:event phase:kMove];
}

- (void)mouseMoved:(NSEvent *)event {
  [self dispatchExtendedMouseEvent: event ofType:@"move"];
}

- (void)rightMouseDown:(NSEvent *)event {
  [self dispatchExtendedMouseEvent: event ofType:@"rightDown"];
}

- (void)rightMouseUp:(NSEvent *)event {
  [self dispatchExtendedMouseEvent: event ofType:@"rightUp"];
}

- (void)scrollWheel:(NSEvent *)event {
  NSPoint locationInView = [self.view convertPoint:event.locationInWindow fromView:nil];
  NSPoint locationInBackingCoordinates = [self.view convertPointToBacking:locationInView];
  
  [_mouseExtensionsEventChannel sendMessage:@{
    @"type" : @"wheel",
    @"x" : @(locationInBackingCoordinates.x),
    @"y" : @(locationInBackingCoordinates.y),
    @"dy": @(event.scrollingDeltaY)
  }];
}
@end
