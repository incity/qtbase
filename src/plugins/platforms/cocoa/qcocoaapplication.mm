// Copyright (C) 2016 The Qt Company Ltd.
// Copyright (c) 2007-2008, Apple, Inc.
// SPDX-License-Identifier: BSD-3-Clause

#include <AppKit/AppKit.h>

#include "qcocoaapplication.h"

#include "qcocoaintrospection.h"
#include "qcocoaapplicationdelegate.h"
#include "qcocoahelpers.h"
#include "qcocoawindow.h"
#include <qguiapplication.h>
#include <qdebug.h>

QT_USE_NAMESPACE

static void qt_sendPostedMessage(NSEvent *event)
{
    // WARNING: data1 and data2 is truncated to from 64-bit to 32-bit on OS 10.5!
    // That is why we need to split the address in two parts:
    quint64 lower = [event data1];
    quint64 upper = [event data2];
    QCocoaPostMessageArgs *args = reinterpret_cast<QCocoaPostMessageArgs *>(lower | (upper << 32));
    // Special case for convenience: if the argument is an NSNumber, we unbox it directly.
    // Use NSValue instead if this behaviour is unwanted.
    id a1 = ([args->arg1 isKindOfClass:[NSNumber class]]) ? (id)[args->arg1 longValue] : args->arg1;
    id a2 = ([args->arg2 isKindOfClass:[NSNumber class]]) ? (id)[args->arg2 longValue] : args->arg2;
    switch (args->argCount) {
    case 0:
        [args->target performSelector:args->selector];
        break;
    case 1:
        [args->target performSelector:args->selector withObject:a1];
        break;
    case 3:
        [args->target performSelector:args->selector withObject:a1 withObject:a2];
        break;
    }

    delete args;
}

static const QByteArray q_macLocalEventType = QByteArrayLiteral("mac_generic_NSEvent");

static bool qt_filterEvent(NSEvent *event)
{
    if (qApp && qApp->eventDispatcher()->
            filterNativeEvent(q_macLocalEventType, static_cast<void*>(event), nullptr))
        return true;

    if (event.type == NSEventTypeApplicationDefined) {
        switch (static_cast<short>(event.subtype)) {
            case QtCocoaEventSubTypePostMessage:
                qt_sendPostedMessage(event);
                return true;
            default:
                break;
        }
    }

    return false;
}

static void qt_maybeSendKeyEquivalentUpEvent(NSEvent *event)
{
    // Cocoa is known for not sending key up events for key
    // equivalents, regardless of whether it's an actual
    // recognized key equivalent. We decide to force fate
    // and forward the key event to the key (focus) window.
    // However, non-Qt windows will not (and should not) get
    // any special treatment, only QWindow-owned NSWindows.
    if (event.type == NSEventTypeKeyUp && (event.modifierFlags & NSEventModifierFlagCommand)) {
        NSWindow *targetWindow = event.window;
        if ([targetWindow.class conformsToProtocol:@protocol(QNSWindowProtocol)])
            [targetWindow sendEvent:event];
    }
}

@implementation QNSApplication

- (void)QT_MANGLE_NAMESPACE(qt_sendEvent_original):(NSEvent *)event
{
    Q_UNUSED(event);
    // This method will only be used as a signature
    // template for the method we add into NSApplication
    // containing the original [NSApplication sendEvent:] implementation
}

- (void)QT_MANGLE_NAMESPACE(qt_sendEvent_replacement):(NSEvent *)event
{
    // This method (or its implementation to be precise) will
    // be called instead of sendEvent if redirection occurs.
    // 'self' will then be an instance of NSApplication
    // (and not QNSApplication)
    if (!qt_filterEvent(event)) {
        [self QT_MANGLE_NAMESPACE(qt_sendEvent_original):event];
        qt_maybeSendKeyEquivalentUpEvent(event);
    }
}

- (void)sendEvent:(NSEvent *)event
{
    // This method will be called if
    // no redirection occurs
    if (!qt_filterEvent(event)) {
        [super sendEvent:event];
        qt_maybeSendKeyEquivalentUpEvent(event);
    }
}

@end

QT_BEGIN_NAMESPACE

void qt_redirectNSApplicationSendEvent()
{
    if (QCoreApplication::testAttribute(Qt::AA_PluginApplication))
        // In a plugin we cannot chain sendEvent hooks: a second plugin could
        // store the implementation of the first, which during the program flow
        // can be unloaded.
        return;

    if ([NSApp isMemberOfClass:[QNSApplication class]]) {
        // No need to change implementation since Qt
        // already controls a subclass of NSApplication
        return;
    }

    // Change the implementation of [NSApplication sendEvent] to the
    // implementation of qt_sendEvent_replacement found in QNSApplication.
    // And keep the old implementation that gets overwritten inside a new
    // method 'qt_sendEvent_original' that we add to NSApplication
    qt_cocoa_change_implementation(
            [NSApplication class],
            @selector(sendEvent:),
            [QNSApplication class],
            @selector(QT_MANGLE_NAMESPACE(qt_sendEvent_replacement):),
            @selector(QT_MANGLE_NAMESPACE(qt_sendEvent_original):));
 }

void qt_resetNSApplicationSendEvent()
{
    if (QCoreApplication::testAttribute(Qt::AA_PluginApplication))
        return;


    qt_cocoa_change_back_implementation([NSApplication class],
                                         @selector(sendEvent:),
                                         @selector(QT_MANGLE_NAMESPACE(qt_sendEvent_original):));
}

QT_END_NAMESPACE
