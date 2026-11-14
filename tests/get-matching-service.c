// Guest test (Darling, iokitd running): finding and opening IOSurfaceRoot.
//
// IOServiceMatching(name) is {IOProviderClass: name}, which XNU's IOService::matchInternal answers with "the service
// is an instance of the class name" (metaCast). iokitd compared the key with the service's personality instead, and
// IOSurfaceRoot's personality names IOResources as its provider, so IOServiceMatching("IOSurfaceRoot") found nothing
// and IOServiceMatching("IOResources") found IOSurfaceRoot. io_service_get_matching_service_ool and
// io_service_open_extended answered KERN_NOT_SUPPORTED. This checks the XNU behaviour (IOUserClient.cpp):
//   - a service matches its own class and IOService, and nothing else it merely has in its personality;
//   - IOServiceOpen returns a connection for a service with a user client of that type, kIOReturnUnsupported for a
//     service or a type without one, kIOReturnBadArgument for a null task or an object that is not a service;
//   - the connection answers IOConnectCallMethod (an unknown selector is kIOReturnUnsupported);
//   - with RAW_MIG: the ool form of io_service_get_matching_service takes binary and XML, refuses a request that does
//     not go to the master port (kIOReturnNotPrivileged), garbage (kIOReturnBadArgument) and an unterminated XML
//     buffer, and answers kIOReturnNotFound for a dictionary nothing matches.
// Connect type 0 is the one the IOSurface framework of the dyld cache sends; other types Apple's IOSurfaceRoot has: NEEDS-REAL-MAC.
// Prints PASS or the first FAIL; exit status 0 on PASS.
//
// IOKit and CoreFoundation are declared by hand with the documented types, so no framework header is needed. Build as
// add-notification.c: this file plus (for RAW_MIG) the generated MIG user stubs, linked against Darling's IOKit and
// CoreFoundation; for arm64e leave RAW_MIG out and link the IOKit of the dyld cache.
#include <mach/mach.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

typedef mach_port_t io_object_t, io_iterator_t, io_service_t, io_connect_t;
typedef char io_name_t[128];

#define kIOReturnBadArgument ((kern_return_t)0xe00002c2)
#define kIOReturnNotPrivileged ((kern_return_t)0xe00002c1)
#define kIOReturnUnsupported ((kern_return_t)0xe00002c7)
#define kIOReturnNotFound ((kern_return_t)0xe00002f0)

extern kern_return_t IOMasterPort(mach_port_t, mach_port_t*);
extern void* IOServiceMatching(const char*);
extern void* IOServiceNameMatching(const char*);
extern io_service_t IOServiceGetMatchingService(mach_port_t, void*);
extern kern_return_t IOServiceGetMatchingServices(mach_port_t, void*, io_iterator_t*);
extern io_object_t IOIteratorNext(io_iterator_t);
extern kern_return_t IOObjectRelease(io_object_t);
extern kern_return_t IOObjectGetClass(io_object_t, io_name_t);
extern unsigned IOObjectConformsTo(io_object_t, const io_name_t);
extern kern_return_t IOServiceOpen(io_service_t, task_t, uint32_t, io_connect_t*);
extern kern_return_t IOServiceClose(io_connect_t);
extern kern_return_t IOConnectCallMethod(io_connect_t, uint32_t, const uint64_t*, uint32_t, const void*, size_t, uint64_t*, uint32_t*, void*, size_t*);

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

static int count(mach_port_t master, const char* cls)
{
	io_iterator_t it = 0;
	int n = 0;
	io_object_t o;
	expect_kr(IOServiceGetMatchingServices(master, IOServiceMatching(cls), &it), KERN_SUCCESS, "IOServiceGetMatchingServices");
	while ((o = IOIteratorNext(it)) != 0) {
		IOObjectRelease(o);
		n++;
	}
	IOObjectRelease(it);
	return n;
}

#ifdef RAW_MIG
extern void* IOCFSerialize(void*, unsigned long);
extern const uint8_t* CFDataGetBytePtr(void*);
extern long CFDataGetLength(void*);
extern void CFRelease(void*);
// The raw MIG user stub (prototype as in the generated iokitmig64.h).
extern kern_return_t io_service_get_matching_service_ool(mach_port_t, char*, mach_msg_type_number_t, kern_return_t*, mach_port_t*);

static void raw_ool(mach_port_t master, mach_port_t service)
{
	void* binary = IOCFSerialize(IOServiceMatching("IOSurfaceRoot"), 1 /* kIOCFSerializeToBinary */);
	void* xml = IOCFSerialize(IOServiceMatching("IOSurfaceRoot"), 0);
	void* nothing = IOCFSerialize(IOServiceMatching("NoSuchClassAnywhere"), 1);
	expect(binary && xml && nothing, "serialize the matching dictionaries");
	kern_return_t result = 0x7777;
	mach_port_t out = 0x7777;

	expect(io_service_get_matching_service_ool(master, (char*)CFDataGetBytePtr(binary), (mach_msg_type_number_t)CFDataGetLength(binary), &result, &out) == KERN_SUCCESS
	    && result == KERN_SUCCESS && MACH_PORT_VALID(out), "ool, binary: finds IOSurfaceRoot");
	io_name_t cls = "";
	expect_kr(IOObjectGetClass(out, cls), KERN_SUCCESS, "class of the ool result");
	expect(strcmp(cls, "IOSurfaceRoot") == 0, "the ool result is IOSurfaceRoot");
	IOObjectRelease(out);

	out = 0x7777;
	expect(io_service_get_matching_service_ool(master, (char*)CFDataGetBytePtr(xml), (mach_msg_type_number_t)CFDataGetLength(xml), &result, &out) == KERN_SUCCESS
	    && result == KERN_SUCCESS && MACH_PORT_VALID(out), "ool, XML (NUL terminated): finds IOSurfaceRoot");
	IOObjectRelease(out);

	// The XML a client built without the terminating NUL: IOCFUnserialize reads to a NUL, so it must be refused.
	{
		size_t n = (size_t)CFDataGetLength(xml);
		char* copy = malloc(n);
		memcpy(copy, CFDataGetBytePtr(xml), n);
		while (n && copy[n - 1] == '\0')
			n--;
		out = 0x7777;
		expect(io_service_get_matching_service_ool(master, copy, (mach_msg_type_number_t)n, &result, &out) == KERN_SUCCESS
		    && result == kIOReturnBadArgument, "ool, unterminated XML");
		free(copy);
	}

	out = 0x7777;
	expect(io_service_get_matching_service_ool(master, (char*)CFDataGetBytePtr(nothing), (mach_msg_type_number_t)CFDataGetLength(nothing), &result, &out) == KERN_SUCCESS
	    && result == kIOReturnNotFound && !MACH_PORT_VALID(out), "ool, a class nothing matches");

	out = 0x7777;
	char garbage[16] = "not a dictionary";
	expect(io_service_get_matching_service_ool(master, garbage, sizeof(garbage), &result, &out) == KERN_SUCCESS
	    && result == kIOReturnBadArgument, "ool, garbage");

	out = 0x7777;
	expect(io_service_get_matching_service_ool(service, (char*)CFDataGetBytePtr(binary), (mach_msg_type_number_t)CFDataGetLength(binary), &result, &out) == KERN_SUCCESS
	    && result == kIOReturnNotPrivileged, "ool, sent to a service port instead of the master port");

	CFRelease(binary);
	CFRelease(xml);
	CFRelease(nothing);
}
#endif

int main(void)
{
	mach_port_t master = MACH_PORT_NULL;
	expect(IOMasterPort(MACH_PORT_NULL, &master) == KERN_SUCCESS && MACH_PORT_VALID(master), "IOMasterPort returns iokitd's port");

	io_service_t surface = IOServiceGetMatchingService(master, IOServiceMatching("IOSurfaceRoot"));
	expect(MACH_PORT_VALID(surface), "IOServiceMatching(IOSurfaceRoot) finds the service");
	io_name_t cls = "";
	expect_kr(IOObjectGetClass(surface, cls), KERN_SUCCESS, "IOObjectGetClass");
	expect(strcmp(cls, "IOSurfaceRoot") == 0, "the service is an IOSurfaceRoot");
	expect(IOObjectConformsTo(surface, "IOService"), "IOSurfaceRoot conforms to IOService");

	io_service_t byName = IOServiceGetMatchingService(master, IOServiceNameMatching("IOSurfaceRoot"));
	expect(MACH_PORT_VALID(byName), "IOServiceNameMatching(IOSurfaceRoot) finds the service");
	IOObjectRelease(byName);

	expect(count(master, "IOSurfaceRoot") == 1, "exactly one IOSurfaceRoot");
	expect(count(master, "IOService") >= 2, "every service is an IOService");
	expect(count(master, "IOResources") == 0, "IOResources is IOSurfaceRoot's provider, not a class it has");
	expect(count(master, "NoSuchClassAnywhere") == 0, "an unknown class matches nothing");
	expect(!MACH_PORT_VALID(IOServiceGetMatchingService(master, IOServiceMatching("NoSuchClassAnywhere"))), "no service for an unknown class");

	io_connect_t connect = 0;
	expect_kr(IOServiceOpen(surface, mach_task_self(), 0, &connect), KERN_SUCCESS, "IOServiceOpen(IOSurfaceRoot, type 0)");
	expect(MACH_PORT_VALID(connect), "a connection port came back");
	uint64_t scalars[1] = {0};
	expect_kr(IOConnectCallMethod(connect, 0xffff, scalars, 0, NULL, 0, NULL, NULL, NULL, NULL), kIOReturnUnsupported, "an unknown selector on the connection");
	expect_kr(IOServiceClose(connect), KERN_SUCCESS, "IOServiceClose");

	io_connect_t rejected = 0x7777;
	expect_kr(IOServiceOpen(surface, mach_task_self(), 7, &rejected), kIOReturnUnsupported, "IOServiceOpen with a connect type IOSurfaceRoot lacks");
	expect(!MACH_PORT_VALID(rejected), "no connection for it");
	expect_kr(IOServiceOpen(surface, MACH_PORT_NULL, 0, &rejected), kIOReturnBadArgument, "IOServiceOpen without an owning task");
	expect_kr(IOServiceOpen(master, mach_task_self(), 0, &rejected), kIOReturnBadArgument, "IOServiceOpen of a port that is not a service");

	io_service_t platform = IOServiceGetMatchingService(master, IOServiceMatching("IOPlatformExpertDevice"));
	expect(MACH_PORT_VALID(platform), "IOPlatformExpertDevice exists");
	expect_kr(IOServiceOpen(platform, mach_task_self(), 0, &rejected), kIOReturnUnsupported, "IOServiceOpen of a service without a user client");
	IOObjectRelease(platform);

#ifdef RAW_MIG
	raw_ool(master, surface);
#endif

	IOObjectRelease(surface);
	printf("PASS\n");
	return 0;
}
