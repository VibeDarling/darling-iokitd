// Guest test (plain arm64 Darling, iokitd running): io_service_get_matching_services_ool with a matching dictionary
// in XML. IOCFUnserialize reads to a NUL, so a buffer the client did not terminate must be refused instead of being
// read past its end; the same buffer with its NUL still works. Prints PASS or the first FAIL; exit status 0 on PASS.
// IOKit and CoreFoundation are declared by hand. Build: this file plus the MIG user stubs generated from
// iokitmig.defs (iokitmig64.c), linked against Darling's IOKit and CoreFoundation.
#include <mach/mach.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

#define kIOReturnBadArgument ((kern_return_t)0xe00002c2)

extern kern_return_t IOMasterPort(mach_port_t, mach_port_t*);
extern void* IOServiceMatching(const char*);
extern void* IOCFSerialize(void*, unsigned long);
extern const uint8_t* CFDataGetBytePtr(void*);
extern long CFDataGetLength(void*);
extern void CFRelease(void*);
extern kern_return_t io_service_get_matching_services_ool(mach_port_t, char*, mach_msg_type_number_t, kern_return_t*, mach_port_t*);

static void expect(int condition, const char* what)
{
	if (!condition) {
		printf("FAIL: %s\n", what);
		exit(1);
	}
}

int main(void)
{
	mach_port_t master = MACH_PORT_NULL;
	expect(IOMasterPort(MACH_PORT_NULL, &master) == KERN_SUCCESS && MACH_PORT_VALID(master), "IOMasterPort returns iokitd's port");
	void* xml = IOCFSerialize(IOServiceMatching("IOPlatformExpertDevice"), 0);
	expect(xml != NULL, "serialize the matching dictionary");

	long len = CFDataGetLength(xml);
	char* buffer = malloc(len + 1);
	memcpy(buffer, CFDataGetBytePtr(xml), len);
	buffer[len] = 'x';
	while (len > 0 && buffer[len - 1] == '\0')
		len--;

	kern_return_t result = 0x7777;
	mach_port_t existing = 0x7777;
	kern_return_t kr = io_service_get_matching_services_ool(master, buffer, (mach_msg_type_number_t)len, &result, &existing);
	expect(kr != KERN_SUCCESS || result != KERN_SUCCESS, "an XML buffer without a NUL is refused");
	expect(kr == kIOReturnBadArgument || result == kIOReturnBadArgument, "and the error is kIOReturnBadArgument");

	buffer[len] = '\0';
	result = 0x7777;
	existing = 0x7777;
	kr = io_service_get_matching_services_ool(master, buffer, (mach_msg_type_number_t)len + 1, &result, &existing);
	expect(kr == KERN_SUCCESS && result == KERN_SUCCESS && MACH_PORT_VALID(existing), "the same buffer with its NUL is accepted");

	free(buffer);
	CFRelease(xml);
	printf("PASS: io_service_get_matching_services_ool refuses an XML buffer without a NUL\n");
	return 0;
}
