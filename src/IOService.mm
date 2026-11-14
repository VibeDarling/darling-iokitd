/*
 This file is part of Darling.

 Copyright (C) 2020 Lubos Dolezel

 Darling is free software: you can redistribute it and/or modify
 it under the terms of the GNU General Public License as published by
 the Free Software Foundation, either version 3 of the License, or
 (at your option) any later version.

 Darling is distributed in the hope that it will be useful,
 but WITHOUT ANY WARRANTY; without even the implied warranty of
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 GNU General Public License for more details.

 You should have received a copy of the GNU General Public License
 along with Darling.  If not, see <http://www.gnu.org/licenses/>.
*/

#include "IOService.h"
#import <Foundation/NSArray.h>
#import <Foundation/NSString.h>

extern "C" {
#include "iokitmigServer.h"
}

IOService::IOService()
{

}

// https://unix.superglobalmegacorp.com/xnu/newsrc/iokit/KernelConfigTables.cpp.html
bool IOService::matches(NSDictionary* dict)
{
	NSDictionary* ourProps = matchingDictionary();

	for (NSString* key in dict)
	{
		NSObject* ourProp = ourProps[key];
		NSObject* expectedValue = dict[key];

		// XNU's IOService::matchInternal: IOProviderClass in a matching dictionary (IOServiceMatching) asks whether the
		// service is an instance of that class. It is not the service's personality key, which names its provider.
		if ([key isEqualToString: @"IOProviderClass"])
		{
			if (![expectedValue isKindOfClass: [NSString class]]
				|| !conformsTo([(NSString*) expectedValue UTF8String]))
				return false;
			continue;
		}

		if ([ourProp isKindOfClass:[NSArray class]])
		{
			NSArray* array = (NSArray*) ourProp;
			if (![array containsObject: expectedValue])
				return false;
		}
		else if (ourProp != nil)
		{
			if (![expectedValue isEqual: ourProp])
				return false;
		}
		else
		{
			if ([key isEqualToString: @"IONameMatch"])
			{
				if (![ourProps[@"IOClass"] isEqual: expectedValue])
					return false;
			}
			else
				return false;
		}
	}
	return true;
}

IOReturn IOService::newUserClient(uint32_t type, IOUserClient** client)
{
	*client = nullptr;
	return kIOReturnUnsupported;
}

bool IOService::conformsTo(const char* className)
{
	if (strcmp(className, "IOService") == 0)
		return true;
	return IOObject::conformsTo(className);
}

kern_return_t is_io_service_get_state
(
	mach_port_t service,
	uint64_t *state,
	uint32_t *busy_state,
	uint64_t *accumulated_busy_time
)
{
    IOService* e = dynamic_cast<IOService*>(IOObject::lookup(service));
	if (!e)
		return kIOReturnBadArgument;

	*state = e->state();
	*busy_state = e->busyState();
	*accumulated_busy_time = e->accumulatedBusyTime();

    return kIOReturnSuccess;
}
