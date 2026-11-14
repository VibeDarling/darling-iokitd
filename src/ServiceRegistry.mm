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

#include "iokitd.h"
#include "ServiceRegistry.h"
#include <IOKit/IOCFUnserialize.h>
#include <CoreFoundation/CFString.h>
#include <IOKit/IOReturn.h>
#include <os/log.h>
#include <stdexcept>
#include <memory>
#import <Foundation/NSException.h>
#include "IOIterator.h"

extern "C" {
#include "iokitmigServer.h"
}

ServiceRegistry* ServiceRegistry::instance()
{
	static ServiceRegistry reg;
	return &reg;
}

std::vector<IOObject*> ServiceRegistry::matchingServices(NSDictionary* criteria) const
{
	std::vector<IOObject*> matching;

	for (auto it = m_registeredServices.begin(); it != m_registeredServices.end(); it++)
	{
		if ((*it)->matches(criteria))
			matching.push_back(*it);
	}

	return matching;
}

IOIterator* ServiceRegistry::iteratorForMatchingServices(NSDictionary* criteria) const
{
	return new IOIterator(matchingServices(criteria));
}

IOService* ServiceRegistry::firstMatchingService(NSDictionary* criteria) const
{
	for (auto it = m_registeredServices.begin(); it != m_registeredServices.end(); it++)
	{
		if ((*it)->matches(criteria))
			return *it;
	}
	return nullptr;
}

void ServiceRegistry::registerService(IOService* service)
{
	m_registeredServices.push_back(service);
}

kern_return_t is_io_service_get_matching_services_ool
(
	mach_port_t master_port,
	io_buf_ptr_t matching,
	mach_msg_type_number_t matchingCnt,
	kern_return_t *result,
	mach_port_t *existing
)
{
	CFStringRef errorString = nullptr;
	@try
	{
		try
		{
			CFTypeRef criteria = IOCFUnserializeBinary(matching, matchingCnt, nullptr, 0, &errorString);
			if (!criteria)
			{
				// IOCFUnserialize reads to a NUL: refuse a buffer the client did not terminate.
				if (matchingCnt == 0 || matching[matchingCnt - 1] != '\0')
					throw std::runtime_error("io_service_get_matching_services_ool(): matching is not NUL terminated");
				criteria = IOCFUnserialize(matching, nullptr, 0, &errorString);
			}

			if (!criteria)
				throwCFStringException(CFSTR("io_service_get_matching_services_ool(): cannot parse 'matching': %@"), errorString);

			if (CFGetTypeID(criteria) != CFDictionaryGetTypeID())
			{
				CFRelease(criteria);
				throw std::runtime_error("io_service_get_matching_services_ool(): dictionary expected");
			}

			IOIterator* iterator = ServiceRegistry::instance()->iteratorForMatchingServices((NSDictionary*) criteria);
			CFRelease(criteria);

			*existing = iterator->port();
			iterator->releaseLater();

			if (result)
				*result = kIOReturnSuccess;

			return kIOReturnSuccess;
		}
		catch (const std::exception& e)
		{
			os_log_error(OS_LOG_DEFAULT, "is_io_service_get_matching_services_ool: %s", e.what());
			if (errorString)
				CFRelease(errorString);

			if (result)
				*result = kIOReturnBadArgument;
			return kIOReturnBadArgument;
		}
		catch (...)
		{
			os_log_error(OS_LOG_DEFAULT, "is_io_service_get_matching_services_ool: unknown C++ exception");
			if (errorString)
				CFRelease(errorString);

			if (result)
				*result = kIOReturnBadArgument;
			return kIOReturnBadArgument;
		}
	}
	@catch (NSException* e)
	{
		os_log_error(OS_LOG_DEFAULT, "is_io_service_get_matching_services_ool: NSException: %s", [[e description] UTF8String]);
		if (errorString)
			CFRelease(errorString);

		if (result)
			*result = kIOReturnBadArgument;
		return kIOReturnBadArgument;
	}
}

kern_return_t is_io_service_get_matching_services_bin
(
	mach_port_t master_port,
	io_struct_inband_t matching,
	mach_msg_type_number_t matchingCnt,
	mach_port_t *existing
)
{
	CFStringRef errorString = nullptr;
	@try
	{
		try
		{
			CFTypeRef criteria = IOCFUnserializeBinary(matching, matchingCnt, nullptr, 0, &errorString);

			if (!criteria)
				throwCFStringException(CFSTR("io_service_get_matching_services_bin(): cannot parse 'matching': %@"), errorString);
			
			if (CFGetTypeID(criteria) != CFDictionaryGetTypeID())
			{
				CFRelease(criteria);
				throw std::runtime_error("io_service_get_matching_services_bin(): dictionary expected");
			}

			// Criteria example:
			// IOProviderClass -> IODisplayConnect
			IOIterator* iterator = ServiceRegistry::instance()->iteratorForMatchingServices((NSDictionary*) criteria);
			CFRelease(criteria);

			*existing = iterator->port();

			iterator->releaseLater();

			return kIOReturnSuccess;
		}
		catch (const std::exception& e)
		{
			os_log_error(OS_LOG_DEFAULT, "is_io_service_get_matching_services_bin: %s", e.what());
			if (errorString)
				CFRelease(errorString);

			return kIOReturnBadArgument;
		}
		catch (...)
		{
			os_log_error(OS_LOG_DEFAULT, "is_io_service_get_matching_services_bin: unknown C++ exception");
			if (errorString)
				CFRelease(errorString);

			return kIOReturnBadArgument;
		}
	}
	@catch (NSException* e)
	{
		os_log_error(OS_LOG_DEFAULT, "is_io_service_get_matching_services_bin: NSException: %s", [[e description] UTF8String]);
		if (errorString)
			CFRelease(errorString);

		return kIOReturnBadArgument;
	}
}

kern_return_t is_io_service_get_matching_services
(
	mach_port_t master_port,
	io_string_t matching,
	mach_port_t *existing
)
{
	CFStringRef errorString = nullptr;
	@try
	{
		try
		{
			CFTypeRef criteria = IOCFUnserialize(matching, nullptr, 0, &errorString);

			if (!criteria)
				throwCFStringException(CFSTR("io_service_get_matching_services(): cannot parse 'matching': %@"), errorString);
			
			if (CFGetTypeID(criteria) != CFDictionaryGetTypeID())
			{
				CFRelease(criteria);
				throw std::runtime_error("io_service_get_matching_services(): dictionary expected");
			}

			IOIterator* iterator = ServiceRegistry::instance()->iteratorForMatchingServices((NSDictionary*) criteria);
			CFRelease(criteria);

			*existing = iterator->port();

			iterator->releaseLater();

			return kIOReturnSuccess;
		}
		catch (const std::exception& e)
		{
			os_log_error(OS_LOG_DEFAULT, "is_io_service_get_matching_services: %s", e.what());
			if (errorString)
				CFRelease(errorString);

			return kIOReturnBadArgument;
		}
		catch (...)
		{
			os_log_error(OS_LOG_DEFAULT, "is_io_service_get_matching_services: unknown C++ exception");
			if (errorString)
				CFRelease(errorString);

			return kIOReturnBadArgument;
		}
	}
	@catch (NSException* e)
	{
		os_log_error(OS_LOG_DEFAULT, "is_io_service_get_matching_services: NSException: %s", [[e description] UTF8String]);
		if (errorString)
			CFRelease(errorString);

		return kIOReturnBadArgument;
	}
}

namespace
{
	struct CFReleaser
	{
		void operator()(CFTypeRef object) const { CFRelease(object); }
	};

	// The matching dictionary of io_service_get_matching_service_bin and _ool, as XNU's
	// internal_io_service_get_matching_service takes it. Binary first; the ool form then tries XML, as IOKitLib sends
	// it when binary serialisation is off. IOCFUnserialize reads to a NUL: refuse a buffer the client did not terminate.
	kern_return_t copyMatchingService(const char* functionName, mach_port_t masterPort, const char* matching,
		mach_msg_type_number_t matchingLen, bool xmlFallback, mach_port_t* service)
	{
		*service = MACH_PORT_NULL;
		if (masterPort != g_masterPort)
			return kIOReturnNotPrivileged;

		@try
		{
			try
			{
				CFStringRef errorString = nullptr;
				CFTypeRef parsed = IOCFUnserializeBinary(matching, matchingLen, nullptr, 0, &errorString);
				if (!parsed && xmlFallback)
				{
					if (errorString)
						CFRelease(errorString);
					errorString = nullptr;
					if (matchingLen == 0 || matching[matchingLen - 1] != '\0')
						throw std::runtime_error("matching is not NUL terminated");
					parsed = IOCFUnserialize(matching, nullptr, 0, &errorString);
				}
				if (errorString)
					CFRelease(errorString);
				std::unique_ptr<const void, CFReleaser> criteria(parsed);

				if (!criteria)
					throw std::runtime_error("cannot parse 'matching'");
				if (CFGetTypeID(criteria.get()) != CFDictionaryGetTypeID())
					throw std::runtime_error("dictionary expected");

				IOService* matched = ServiceRegistry::instance()->firstMatchingService((NSDictionary*) criteria.get());
				if (!matched)
					return kIOReturnNotFound;

				*service = matched->port();
				return kIOReturnSuccess;
			}
			catch (const std::exception& e)
			{
				os_log_error(OS_LOG_DEFAULT, "%s: %s", functionName, e.what());
			}
			catch (...)
			{
				os_log_error(OS_LOG_DEFAULT, "%s: unknown C++ exception", functionName);
			}
		}
		@catch (NSException* e)
		{
			os_log_error(OS_LOG_DEFAULT, "%s: NSException: %s", functionName, [[e description] UTF8String]);
		}
		return kIOReturnBadArgument;
	}
}

kern_return_t is_io_service_get_matching_service_bin
(
	mach_port_t master_port,
	io_struct_inband_t matching,
	mach_msg_type_number_t matchingCnt,
	mach_port_t *service
)
{
	return copyMatchingService(__func__, master_port, matching, matchingCnt, false, service);
}

// Like XNU, once the request is well formed the routine succeeds and the outcome is in *result.
kern_return_t is_io_service_get_matching_service_ool
(
	mach_port_t master_port,
	io_buf_ptr_t matching,
	mach_msg_type_number_t matchingCnt,
	kern_return_t *result,
	mach_port_t *service
)
{
	*result = copyMatchingService(__func__, master_port, matching, matchingCnt, true, service);
	vm_deallocate(mach_task_self(), (vm_address_t) matching, matchingCnt);
	return KERN_SUCCESS;
}
