/*
 This file is part of Darling.

 Copyright (C) 2026 Darling developers

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

// io_service_add_notification_bin, _ool and their 64-bit variants (IOServiceAddMatchingNotification); the string forms are
// unsupported, as in XNU.
//
// The notification object is an iterator over the services that match right now (none for a terminate
// notification), as the XNU server hands out. Known gap: the registry is built once when iokitd starts, so
// nothing is published or terminated later and the wake port never receives a message. The port is kept
// for the lifetime of the notification so its send right does not leak.

#include "iokitd.h"
#include "ServiceRegistry.h"
#include "IOIterator.h"
#include <IOKit/IOCFUnserialize.h>
#include <IOKit/IOKitKeys.h>
#include <IOKit/IOReturn.h>
#include <CoreFoundation/CFDictionary.h>
#include <os/log.h>
#include <cstring>
#include <stdexcept>
#import <Foundation/NSException.h>

extern "C" {
#include "iokitmigServer.h"
}

namespace
{
	class IONotification : public IOIterator
	{
	public:
		IONotification(const std::vector<IOObject*>& existing, mach_port_t wakePort)
		: IOIterator(existing), m_wakePort(wakePort)
		{
		}

		~IONotification() override
		{
			if (MACH_PORT_VALID(m_wakePort))
				mach_port_deallocate(mach_task_self(), m_wakePort);
		}
	private:
		mach_port_t m_wakePort;
	};

	enum class Encoding { Binary, BinaryThenXML };

	// False for a type the server does not know; *wanted says whether existing services are delivered at once.
	// Will-terminate and terminate notifications start empty, as in XNU's internal_io_service_add_notification.
	bool existingServicesWanted(const char* type, size_t maxLen, bool* wanted)
	{
		if (strnlen(type, maxLen) == maxLen)
			return false;

		if (!strcmp(type, kIOPublishNotification) || !strcmp(type, kIOFirstPublishNotification)
			|| !strcmp(type, kIOMatchedNotification) || !strcmp(type, kIOFirstMatchNotification))
		{
			*wanted = true;
			return true;
		}
		if (!strcmp(type, kIOTerminatedNotification) || !strcmp(type, kIOWillTerminateNotification))
		{
			*wanted = false;
			return true;
		}
		return false;
	}

	kern_return_t createNotification(const char* functionName, mach_port_t masterPort, const char* type,
		const char* matching, size_t matchingLen, Encoding encoding, mach_port_t wakePort, mach_port_t* notification)
	{
		if (masterPort != g_masterPort)
			return kIOReturnNotPrivileged;

		CFStringRef errorString = nullptr;
		CFTypeRef criteria = nullptr;
		kern_return_t failure = kIOReturnBadArgument;

		@try
		{
			try
			{
				criteria = IOCFUnserializeBinary(matching, matchingLen, nullptr, 0, &errorString);
				if (!criteria && encoding == Encoding::BinaryThenXML)
				{
					if (errorString)
						CFRelease(errorString);
					errorString = nullptr;
					// IOCFUnserialize reads to a NUL: refuse a buffer the client did not terminate.
					if (matchingLen == 0 || matching[matchingLen - 1] != '\0')
						throw std::runtime_error("matching is not NUL terminated");
					criteria = IOCFUnserialize(matching, nullptr, 0, &errorString);
				}
				if (!criteria)
					throwCFStringException(CFSTR("cannot parse 'matching': %@"), errorString);
				if (CFGetTypeID(criteria) != CFDictionaryGetTypeID())
					throw std::runtime_error("dictionary expected");

				// XNU looks at the type after the dictionary parsed: an unknown type is unsupported, not a bad argument.
				bool wantExisting;
				if (!existingServicesWanted(type, sizeof(io_name_t), &wantExisting))
				{
					failure = kIOReturnUnsupported;
					throw std::runtime_error("unknown notification type");
				}

				std::vector<IOObject*> existing;
				if (wantExisting)
					existing = ServiceRegistry::instance()->matchingServices((NSDictionary*) criteria);

				IONotification* object = new IONotification(existing, wakePort);
				*notification = object->port();
				object->releaseLater();

				CFRelease(criteria);
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

		if (criteria)
			CFRelease(criteria);
		if (errorString)
			CFRelease(errorString);
		return failure;
	}

	// Takes ownership of wakePort on success. On failure MIG destroys it with the request when the routine returns
	// the error itself; the _ool routines return success and report the error in *result, so they ask for it here.
	kern_return_t addNotification(const char* functionName, mach_port_t masterPort, const char* type,
		const char* matching, size_t matchingLen, Encoding encoding, mach_port_t wakePort,
		bool destroyWakePortOnFailure, mach_port_t* notification)
	{
		*notification = MACH_PORT_NULL;
		kern_return_t kr = createNotification(functionName, masterPort, type, matching, matchingLen, encoding, wakePort, notification);
		if (kr != kIOReturnSuccess && destroyWakePortOnFailure && MACH_PORT_VALID(wakePort))
			mach_port_deallocate(mach_task_self(), wakePort);
		return kr;
	}
}

// XNU answers the string variants with kIOReturnUnsupported: IOKit sends the binary or out-of-line forms.
kern_return_t is_io_service_add_notification
(
	mach_port_t master_port,
	io_name_t notification_type,
	io_string_t matching,
	mach_port_t wake_port,
	io_async_ref_t reference,
	mach_msg_type_number_t referenceCnt,
	mach_port_t *notification
)
{
	return kIOReturnUnsupported;
}

kern_return_t is_io_service_add_notification_64
(
	mach_port_t master_port,
	io_name_t notification_type,
	io_string_t matching,
	mach_port_t wake_port,
	io_async_ref64_t reference,
	mach_msg_type_number_t referenceCnt,
	mach_port_t *notification
)
{
	return kIOReturnUnsupported;
}

kern_return_t is_io_service_add_notification_ool
(
	mach_port_t master_port,
	io_name_t notification_type,
	io_buf_ptr_t matching,
	mach_msg_type_number_t matchingCnt,
	mach_port_t wake_port,
	io_async_ref_t reference,
	mach_msg_type_number_t referenceCnt,
	kern_return_t *result,
	mach_port_t *notification
)
{
	*result = addNotification(__FUNCTION__, master_port, notification_type, matching, matchingCnt,
		Encoding::BinaryThenXML, wake_port, true, notification);
	// The out-of-line buffer was mapped into this task for this request.
	vm_deallocate(mach_task_self(), (vm_address_t) matching, matchingCnt);
	return kIOReturnSuccess;
}

kern_return_t is_io_service_add_notification_ool_64
(
	mach_port_t master_port,
	io_name_t notification_type,
	io_buf_ptr_t matching,
	mach_msg_type_number_t matchingCnt,
	mach_port_t wake_port,
	io_async_ref64_t reference,
	mach_msg_type_number_t referenceCnt,
	kern_return_t *result,
	mach_port_t *notification
)
{
	*result = addNotification(__FUNCTION__, master_port, notification_type, matching, matchingCnt,
		Encoding::BinaryThenXML, wake_port, true, notification);
	// The out-of-line buffer was mapped into this task for this request.
	vm_deallocate(mach_task_self(), (vm_address_t) matching, matchingCnt);
	return kIOReturnSuccess;
}

kern_return_t is_io_service_add_notification_bin
(
	mach_port_t master_port,
	io_name_t notification_type,
	io_struct_inband_t matching,
	mach_msg_type_number_t matchingCnt,
	mach_port_t wake_port,
	io_async_ref_t reference,
	mach_msg_type_number_t referenceCnt,
	mach_port_t *notification
)
{
	return addNotification(__FUNCTION__, master_port, notification_type, matching, matchingCnt,
		Encoding::Binary, wake_port, false, notification);
}

kern_return_t is_io_service_add_notification_bin_64
(
	mach_port_t master_port,
	io_name_t notification_type,
	io_struct_inband_t matching,
	mach_msg_type_number_t matchingCnt,
	mach_port_t wake_port,
	io_async_ref64_t reference,
	mach_msg_type_number_t referenceCnt,
	mach_port_t *notification
)
{
	return addNotification(__FUNCTION__, master_port, notification_type, matching, matchingCnt,
		Encoding::Binary, wake_port, false, notification);
}
