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

#include "IOUserClient.h"
#include "IOObject.h"
#include "iokitd.h"
#include <IOKit/IOReturn.h>
#include <os/log.h>

extern "C" {
#include "iokitmigServer.h"
}

// XNU's is_io_service_open_extended (IOServiceOpen): the service makes the user client, and the client's port is the
// connection. A request that is well formed succeeds and the outcome is in *result; a connection exists only if
// *result is success.
kern_return_t is_io_service_open_extended
(
	mach_port_t service,
	task_t owningTask,
	uint32_t connect_type,
	NDR_record_t ndr,
	io_buf_ptr_t properties,
	mach_msg_type_number_t propertiesCnt,
	kern_return_t *result,
	mach_port_t *connection
)
{
	*connection = MACH_PORT_NULL;

	IOService* target = dynamic_cast<IOService*>(IOObject::lookup(service));
	if (!target || !MACH_PORT_VALID(owningTask))
		return kIOReturnBadArgument;

	// XNU refuses open properties too (the code that read them is #if 0 there).
	if (properties)
		return kIOReturnUnsupported;

	IOUserClient* client = nullptr;
	IOReturn res = target->newUserClient(connect_type, &client);
	if (res == kIOReturnSuccess)
		*connection = client->port();
	else
		os_log_error(OS_LOG_DEFAULT, "is_io_service_open_extended: %s refused connect type %u: %#x", target->className(), connect_type, res);

	// MIG leaves the task right to the routine once it succeeds; iokitd has no use for it.
	mach_port_deallocate(mach_task_self(), owningTask);
	*result = res;
	return KERN_SUCCESS;
}
