// Guest test (plain arm64 Darling, iokitd running): IOServiceAddMatchingNotification against iokitd.
// iokitd answered every io_service_add_notification variant with KERN_NOT_SUPPORTED. It now answers as XNU's
// IOUserClient.cpp does: the binary and out-of-line forms return an iterator over the services that match when the
// notification is added (none for a terminate or will-terminate notification), a type it does not know is
// kIOReturnUnsupported, a request that does not go to the master port is kIOReturnNotPrivileged, and the string forms
// are kIOReturnUnsupported. Prints PASS or the first FAIL; exit status 0 on PASS.
//
// An async reference count above the limit is not tested: the MIG server stub (iokitmigServer.c) refuses such a message
// before any routine runs, so iokitd needs no check of its own.
//
// IOKit and CoreFoundation are declared by hand with the documented types, so no framework header is needed. Build:
// this file plus the MIG user stubs generated from iokitmig.defs (iokitmig64.c, for the raw routines), linked against
// Darling's IOKit and CoreFoundation (IOMasterPort reaches iokitd through the bootstrap server).
#include <mach/mach.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

typedef mach_port_t io_object_t, io_iterator_t;
typedef char io_name_t[128];
typedef struct IONotificationPort* IONotificationPortRef;
typedef void (*IOServiceMatchingCallback)(void* refcon, io_iterator_t iterator);

#define kIOReturnBadArgument ((kern_return_t)0xe00002c2)
#define kIOReturnNotPrivileged ((kern_return_t)0xe00002c1)
#define kIOReturnUnsupported ((kern_return_t)0xe00002c7)

extern kern_return_t IOMasterPort(mach_port_t, mach_port_t*);
extern void* IOServiceMatching(const char*);
extern kern_return_t IOServiceGetMatchingServices(mach_port_t, void*, io_iterator_t*);
extern IONotificationPortRef IONotificationPortCreate(mach_port_t);
extern void IONotificationPortDestroy(IONotificationPortRef);
extern kern_return_t IOServiceAddMatchingNotification(IONotificationPortRef, const io_name_t, void*, IOServiceMatchingCallback, void*, io_iterator_t*);
extern io_object_t IOIteratorNext(io_iterator_t);
extern kern_return_t IOObjectRelease(io_object_t);
extern void* IOCFSerialize(void*, unsigned long);
extern const uint8_t* CFDataGetBytePtr(void*);
extern long CFDataGetLength(void*);
extern void CFRelease(void*);

// The raw MIG user stubs (prototypes as in the generated iokitmig64.h).
extern kern_return_t io_service_add_notification(mach_port_t, char*, char*, mach_port_t, uint64_t*, mach_msg_type_number_t, mach_port_t*);
extern kern_return_t io_service_add_notification_ool(mach_port_t, char*, char*, mach_msg_type_number_t, mach_port_t, uint64_t*, mach_msg_type_number_t, kern_return_t*, mach_port_t*);
extern kern_return_t io_service_add_notification_bin(mach_port_t, char*, char*, mach_msg_type_number_t, mach_port_t, uint64_t*, mach_msg_type_number_t, mach_port_t*);

static void callback(void* refcon, io_iterator_t it) { (void)refcon; (void)it; }

static void expect(int condition, const char* what)
{
	if (!condition) {
		printf("FAIL: %s\n", what);
		exit(1);
	}
}

static void expect_kr(kern_return_t got, kern_return_t want, const char* what)
{
	if (got != want) {
		printf("FAIL: %s: kr=%#x, want %#x\n", what, (unsigned)got, (unsigned)want);
		exit(1);
	}
}

static int drain(io_iterator_t it)
{
	int n = 0;
	io_object_t o;
	while ((o = IOIteratorNext(it)) != 0) {
		IOObjectRelease(o);
		n++;
	}
	return n;
}

int main(void)
{
	mach_port_t master = MACH_PORT_NULL;
	expect(IOMasterPort(MACH_PORT_NULL, &master) == KERN_SUCCESS && MACH_PORT_VALID(master), "IOMasterPort returns iokitd's port");
	IONotificationPortRef np = IONotificationPortCreate(master);
	expect(np != NULL, "IONotificationPortCreate");

	// Through Darling's IOKit, which sends the binary form.
	const char* existing[] = {"IOServicePublish", "IOServiceFirstPublish", "IOServiceMatched", "IOServiceFirstMatch"};
	for (int i = 0; i < 4; i++) {
		io_iterator_t it = 0;
		expect_kr(IOServiceAddMatchingNotification(np, existing[i], IOServiceMatching("IOPlatformExpertDevice"), callback, NULL, &it),
		    KERN_SUCCESS, "adding a publish or match notification");
		expect(drain(it) == 1, "the iterator holds the one IOPlatformExpertDevice that exists");
		IOObjectRelease(it);
	}

	const char* terminate[] = {"IOServiceTerminate", "IOServiceWillTerminate"};
	for (int i = 0; i < 2; i++) {
		io_iterator_t it = 0;
		expect_kr(IOServiceAddMatchingNotification(np, terminate[i], IOServiceMatching("IOPlatformExpertDevice"), callback, NULL, &it),
		    KERN_SUCCESS, "adding a terminate or will-terminate notification");
		expect(drain(it) == 0, "a terminate notification starts empty");
		IOObjectRelease(it);
	}

	io_iterator_t it = 0;
	expect_kr(IOServiceAddMatchingNotification(np, "IOServiceMatched", IOServiceMatching("NoSuchClassAnywhere"), callback, NULL, &it),
	    KERN_SUCCESS, "a matching dictionary nothing matches is still a valid notification");
	expect(drain(it) == 0, "and its iterator is empty");
	IOObjectRelease(it);

	it = 0x7777;
	expect_kr(IOServiceAddMatchingNotification(np, "NotANotificationType", IOServiceMatching("IOPlatformExpertDevice"), callback, NULL, &it),
	    kIOReturnUnsupported, "an unknown notification type");

	// Raw routines. The wake port only has to be a valid port name for the request to be well formed.
	void* binary = IOCFSerialize(IOServiceMatching("IOPlatformExpertDevice"), 1 /* kIOCFSerializeToBinary */);
	void* xml = IOCFSerialize(IOServiceMatching("IOPlatformExpertDevice"), 0);
	expect(binary && xml, "serialize the matching dictionary");
	uint64_t reference[8] = {0};
	mach_port_t out = 0x7777;

	expect_kr(io_service_add_notification_bin(master, (char*)"IOServiceMatched", (char*)CFDataGetBytePtr(binary), (mach_msg_type_number_t)CFDataGetLength(binary),
	              MACH_PORT_NULL, reference, 1, &out),
	    KERN_SUCCESS, "the binary form to the master port");

	// A request to a port that is not the master port: a service object's port.
	io_iterator_t services = 0;
	expect_kr(IOServiceGetMatchingServices(master, IOServiceMatching("IOPlatformExpertDevice"), &services), KERN_SUCCESS, "find the platform expert");
	io_object_t service = IOIteratorNext(services);
	expect(service != 0, "the platform expert exists");
	out = 0x7777;
	expect_kr(io_service_add_notification_bin(service, (char*)"IOServiceMatched", (char*)CFDataGetBytePtr(binary), (mach_msg_type_number_t)CFDataGetLength(binary),
	              MACH_PORT_NULL, reference, 1, &out),
	    kIOReturnNotPrivileged, "a notification requested through a port that is not the master port");
	IOObjectRelease(service);
	IOObjectRelease(services);

	// The out-of-line form falls back to XML, which iokitd reads up to a NUL: a buffer the client did not terminate is
	// refused (it used to be read past its end), the same buffer with its NUL is accepted.
	long xmlLen = CFDataGetLength(xml);
	char* unterminated = malloc(xmlLen + 1);
	memcpy(unterminated, CFDataGetBytePtr(xml), xmlLen);
	unterminated[xmlLen] = 'x';
	while (xmlLen > 0 && unterminated[xmlLen - 1] == '\0')
		xmlLen--;
	kern_return_t result = 0x7777;
	out = 0x7777;
	expect_kr(io_service_add_notification_ool(master, (char*)"IOServiceMatched", unterminated, (mach_msg_type_number_t)xmlLen,
	              MACH_PORT_NULL, reference, 1, &result, &out),
	    KERN_SUCCESS, "the out-of-line form with an XML buffer without a NUL");
	expect_kr(result, kIOReturnBadArgument, "an XML buffer without a NUL is refused");
	unterminated[xmlLen] = '\0';
	out = 0x7777;
	expect_kr(io_service_add_notification_ool(master, (char*)"IOServiceMatched", unterminated, (mach_msg_type_number_t)xmlLen + 1,
	              MACH_PORT_NULL, reference, 1, &result, &out),
	    KERN_SUCCESS, "the out-of-line form with a NUL terminated XML buffer");
	expect_kr(result, KERN_SUCCESS, "a NUL terminated XML buffer is accepted");
	free(unterminated);

	// The string form is unsupported, as in XNU.
	out = 0x7777;
	expect_kr(io_service_add_notification(master, (char*)"IOServiceMatched", (char*)CFDataGetBytePtr(xml), MACH_PORT_NULL, reference, 1, &out),
	    kIOReturnUnsupported, "the string form");

	CFRelease(binary);
	CFRelease(xml);
	IONotificationPortDestroy(np);
	printf("PASS: IOServiceAddMatchingNotification against iokitd: types, unknown type, non-master port, string form\n");
	return 0;
}
