//
//  iconpingAppDelegate.m
//  iconping
//
//  Created by Salvatore Sanfilippo on 25/07/11.
//  Copyright Salvatore Sanfilippo. All rights reserved.
//

#import "iconpingAppDelegate.h"
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <stdlib.h>
#include <sys/time.h>

@implementation iconpingAppDelegate

@synthesize window;

struct ICMPHeader {
    uint8_t     type;
    uint8_t     code;
    uint16_t    checksum;
    uint16_t    identifier;
    uint16_t    sequenceNumber;
    // data...
    int64_t     sentTime;
};

#define ICMP_TYPE_ECHO_REPLY 0
#define ICMP_TYPE_ECHO_REQUEST 8

#define CONN_STATE_KO 0
#define CONN_STATE_SLOW 1
#define CONN_STATE_OK 2

/* This is the standard BSD checksum code, modified to use modern types. */
static uint16_t in_cksum(const void *buffer, size_t bufferLen)
{
    size_t              bytesLeft;
    int32_t             sum;
    const uint16_t *    cursor;
    union {
        uint16_t        us;
        uint8_t         uc[2];
    } last;
    uint16_t            answer;
    
    bytesLeft = bufferLen;
    sum = 0;
    cursor = buffer;
    
    /*
     * Our algorithm is simple, using a 32 bit accumulator (sum), we add
     * sequential 16 bit words to it, and at the end, fold back all the
     * carry bits from the top 16 bits into the lower 16 bits.
     */
    while (bytesLeft > 1) {
        sum += *cursor;
        cursor += 1;
        bytesLeft -= 2;
    }
    /* mop up an odd byte, if necessary */
    if (bytesLeft == 1) {
        last.uc[0] = * (const uint8_t *) cursor;
        last.uc[1] = 0;
        sum += last.us;
    }
    
    /* add back carry outs from top 16 bits to low 16 bits */
    sum = (sum >> 16) + (sum & 0xffff);     /* add hi 16 to low 16 */
    sum += (sum >> 16);                     /* add carry */
    answer = ~sum;                          /* truncate to 16 bits */
    
    return answer;
}

int setSocketNonBlocking(int fd) {
    int flags;
    
    /* Set the socket nonblocking.
     * Note that fcntl(2) for F_GETFL and F_SETFL can't be
     * interrupted by a signal. */
    if ((flags = fcntl(fd, F_GETFL)) == -1) return -1;
    if (fcntl(fd, F_SETFL, flags | O_NONBLOCK) == -1) return -1;
    return 0;
}

/* Return the UNIX time in microseconds */
int64_t ustime(void) {
    struct timeval tv;
    long long ust;
    
    gettimeofday(&tv, NULL);
    ust = ((int64_t)tv.tv_sec)*1000000;
    ust += tv.tv_usec;
    return ust;
}

- (void) sendPingwithId: (int) identifier andSeq: (int) seq {
    if (icmp_socket != -1) close(icmp_socket);
    
    int s = icmp_socket = socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP);
    struct sockaddr_in sa;
    struct ICMPHeader icmp;
    
    if (s == -1) return;
    inet_aton("8.8.8.8", &sa.sin_addr);
    setSocketNonBlocking(s);
    
    /* Note that we create always a new socket, with a different identifier
     * and sequence number. This is to avoid to read old replies to our ICMP
     * request, and to be sure that even in the case the user changes
     * connection, routing, interfaces, everything will continue to work. */
    icmp.type = ICMP_TYPE_ECHO_REQUEST;
    icmp.code = 0;
    icmp.checksum = 0;
    icmp.identifier = identifier;
    icmp.sequenceNumber = seq;
    icmp.sentTime = ustime();   
    icmp.checksum = in_cksum(&icmp,sizeof(icmp));
    
    sendto(s,&icmp,sizeof(icmp),0,(struct sockaddr*)&sa,sizeof(sa));
 }

- (void) receivePing {
    unsigned char packet[1024*16];
    struct ICMPHeader *reply;
    int s = icmp_socket;
    ssize_t nread = read(s,packet,sizeof(packet));
    int icmpoff;
    
    if (nread <= 0) return;
    NSLog(@"Received ICMP %d bytes\n", (int)nread);
    
    icmpoff = (packet[0]&0x0f)*4;
    NSLog(@"ICMP offset: %d\n", icmpoff);
    
    /* Don't process malformed packets. */
    if (nread < (icmpoff + (signed)sizeof(struct ICMPHeader))) return;
    reply = (struct ICMPHeader*) (packet+icmpoff);
    
    /* Make sure that identifier and sequence match */
    if (reply->identifier != icmp_id ||
        reply->sequenceNumber != icmp_seq)
    {
        return;
    }
    
    NSLog(@"OK received an ICMP packet that matches!\n");
    if (reply->sentTime > last_received_time) {
        last_rtt = (int)(ustime()-reply->sentTime)/1000;
        last_received_time = reply->sentTime;
        [myStatusItem setToolTip:[NSString stringWithFormat:@"rtt < %.1f seconds", (float)last_rtt/1000]];
    }
}

- (void)applicationDidFinishLaunching:(NSNotification *)aNotification
{
    NSBundle *bundle = [NSBundle mainBundle];
    /*
    [NSTimer scheduledTimerWithTimeInterval:0.1 target:self selector:@selector(timerHandler:) userInfo:nil repeats:YES];
     */
    NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:
                                [self methodSignatureForSelector:@selector(timerHandler:)]];
    [invocation setTarget:self];
    [invocation setSelector:@selector(timerHandler:)];
    [[NSRunLoop mainRunLoop] addTimer:[NSTimer timerWithTimeInterval:0.1 invocation:invocation repeats:YES] forMode:NSRunLoopCommonModes];

    myMenu = [[NSMenu alloc] initWithTitle:@"Menu Title"];
    NSMenuItem *menuItem = [[NSMenuItem alloc] initWithTitle:@"Quit Icon Ping" action:@selector(exitAction) keyEquivalent:@"q"];
    [menuItem setEnabled:YES];
  
    statusMenuItem = [[NSMenuItem alloc] initWithTitle:@"..." action:nil keyEquivalent:@""];
    [statusMenuItem setEnabled:NO];
    
    openAtStartupMenuItem = [[NSMenuItem alloc] initWithTitle:@"Open at startup" action:@selector(toggleStartupAction) keyEquivalent:@""];
    [openAtStartupMenuItem setEnabled:YES];
    if ([self loginItemExists]) [openAtStartupMenuItem setState:NSOnState];
    
    [myMenu addItem: statusMenuItem];
    [myMenu addItem: openAtStartupMenuItem];
    [myMenu addItem: menuItem];

    myStatusItem = [[[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength] retain];
    
    myStatusImageOK = [[NSImage alloc] initWithContentsOfFile: [bundle pathForResource:@"iconok" ofType:@"png"]];
    myStatusImageSLOW = [[NSImage alloc] initWithContentsOfFile: [bundle pathForResource:@"iconslow" ofType:@"png"]];
    myStatusImageKO = [[NSImage alloc] initWithContentsOfFile: [bundle pathForResource:@"iconko" ofType:@"png"]];
    [myStatusItem setImage:myStatusImageKO];
    [myStatusItem setMenu: myMenu];
    [self changeConnectionState: CONN_STATE_KO];
    
    icmp_socket = -1;
    last_received_time = 0;
    last_rtt = 0;
    icmp_id = random()&0xffff;
    icmp_seq = random()&0xffff;
}

- (void) timerHandler: (NSTimer *) t
{
    static long clicks = -1;
    int state;
    int64_t elapsed;
    
    clicks++;
    if ((clicks % 10) == 0) {
        NSLog(@"Sending ping\n");
        
        [self sendPingwithId:icmp_id andSeq: icmp_seq];
    }
    [self receivePing];
    
    /* Update the current state accordingly */
    elapsed = (ustime() - last_received_time)/1000; /* in milliseconds */
    if (elapsed > 3000) {
        state = CONN_STATE_KO;
    } else if (last_rtt < 300) {
        state = CONN_STATE_OK;
    } else {
        state = CONN_STATE_SLOW;
    }
    if (state != connection_state) {
        [self changeConnectionState: state];
    }
}

- (void) changeConnectionState: (int) state
{
    if (state == CONN_STATE_KO) {
        [myStatusItem setImage:myStatusImageKO];
        [statusMenuItem setTitle:@"No Connection!"];
    } else if (state == CONN_STATE_OK) {
        [myStatusItem setImage:myStatusImageOK];
        [statusMenuItem setTitle:@"Connection OK"];
    } else if (state == CONN_STATE_SLOW) {
        [myStatusItem setImage:myStatusImageSLOW];
        [statusMenuItem setTitle:@"Connection is slow"];
    }
    connection_state = state;
}

- (void) exitAction {
    exit(0);
}

- (void) toggleStartupAction {
    if ([self toggleLoginItem]) {
        [openAtStartupMenuItem setState:NSOnState];
    } else {
        [openAtStartupMenuItem setState:NSOffState];
    }
}

/*
 
 The MIT License

 Copyright (c) 2010 Justin Williams, Second Gear
 Copyright (c) 2010 Salvatore Sanfilippo, antirez@gmail.com

 The following code was adapted by Salvatore Sanfilippo for iconping needs.
 
 Permission is hereby granted, free of charge, to any person obtaining a copy
 of this software and associated documentation files (the "Software"), to deal
 in the Software without restriction, including without limitation the rights
 to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 copies of the Software, and to permit persons to whom the Software is
 furnished to do so, subject to the following conditions:
 
 The above copyright notice and this permission notice shall be included in
 all copies or substantial portions of the Software.
 
 THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
 THE SOFTWARE.
 
 */


- (void)enableLoginItemWithLoginItemsReference:(LSSharedFileListRef )theLoginItemsRefs ForPath:(NSString *)appPath {
	// We call LSSharedFileListInsertItemURL to insert the item at the bottom of Login Items list.
	CFURLRef url = (CFURLRef)[NSURL fileURLWithPath:appPath];
	LSSharedFileListItemRef item = LSSharedFileListInsertItemURL(theLoginItemsRefs, kLSSharedFileListItemLast, NULL, NULL, url, NULL, NULL);		
	if (item)
		CFRelease(item);
}

- (void)disableLoginItemWithLoginItemsReference:(LSSharedFileListRef )theLoginItemsRefs ForPath:(NSString *)appPath {
	UInt32 seedValue;
	CFURLRef thePath;
	// We're going to grab the contents of the shared file list (LSSharedFileListItemRef objects)
	// and pop it in an array so we can iterate through it to find our item.
	CFArrayRef loginItemsArray = LSSharedFileListCopySnapshot(theLoginItemsRefs, &seedValue);
	for (id item in (NSArray *)loginItemsArray) {		
		LSSharedFileListItemRef itemRef = (LSSharedFileListItemRef)item;
		if (LSSharedFileListItemResolve(itemRef, 0, (CFURLRef*) &thePath, NULL) == noErr) {
			if ([[(NSURL *)thePath path] hasPrefix:appPath]) {
				LSSharedFileListItemRemove(theLoginItemsRefs, itemRef); // Deleting the item
			}
			CFRelease(thePath);
		}		
	}
	CFRelease(loginItemsArray);
}

- (BOOL)loginItemExistsWithLoginItemReference:(LSSharedFileListRef)theLoginItemsRefs ForPath:(NSString *)appPath {
	BOOL found = NO;  
	UInt32 seedValue;
	CFURLRef thePath;
	
	// We're going to grab the contents of the shared file list (LSSharedFileListItemRef objects)
	// and pop it in an array so we can iterate through it to find our item.
	CFArrayRef loginItemsArray = LSSharedFileListCopySnapshot(theLoginItemsRefs, &seedValue);
	for (id item in (NSArray *)loginItemsArray) {    
		LSSharedFileListItemRef itemRef = (LSSharedFileListItemRef)item;
		if (LSSharedFileListItemResolve(itemRef, 0, (CFURLRef*) &thePath, NULL) == noErr) {
			if ([[(NSURL *)thePath path] hasPrefix:appPath]) {
				found = YES;
                CFRelease(thePath);
				break;
			} else {
                CFRelease(thePath);
            }
		}
	}
	CFRelease(loginItemsArray);
	
	return found;
}

- (BOOL)loginItemExists {
	// This will retrieve the path for the application
	// For example, /Applications/test.app
	NSString * appPath = [[NSBundle mainBundle] bundlePath];
    BOOL retval = NO;
    
	LSSharedFileListRef loginItems = LSSharedFileListCreate(NULL, kLSSharedFileListSessionLoginItems, NULL);
	if ([self loginItemExistsWithLoginItemReference:loginItems ForPath:appPath]) {
		retval = YES;
	}
	CFRelease(loginItems);
    return retval;
}

- (BOOL)toggleLoginItem {
	NSString * appPath = [[NSBundle mainBundle] bundlePath];
    BOOL retval;
	
	// Create a reference to the shared file list.
	LSSharedFileListRef loginItems = LSSharedFileListCreate(NULL, kLSSharedFileListSessionLoginItems, NULL);
	if (loginItems) {
		if (![self loginItemExistsWithLoginItemReference:loginItems ForPath:appPath]) {
			[self enableLoginItemWithLoginItemsReference:loginItems ForPath:appPath];
            retval = YES;
		} else {
			[self disableLoginItemWithLoginItemsReference:loginItems ForPath:appPath];
            retval = NO;
        }
	}
	CFRelease(loginItems);
    return retval;
}

@end
