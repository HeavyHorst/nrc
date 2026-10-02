#+build darwin, linux
package nbio

import "core:net"

/*
Creates a socket, sets non blocking mode and relates it to the given IO

Inputs:
- io:       The IO instance to initialize the socket on/with
- family:   Should this be an IP4 or IP6 socket
- protocol: The type of socket (TCP or UDP)

Returns:
- socket: The opened socket
- err:    A network error that happened while opening
*/
open_socket :: proc(_: ^IO, family: net.Address_Family, protocol: net.Socket_Protocol) -> (socket: net.Any_Socket, err: net.Network_Error) {
	socket, err = net.create_socket(family, protocol)
	if err != nil do return

	err = _prepare_socket(socket)
	if err != nil do net.close(socket)
	return
}

_prepare_socket :: proc(socket: net.Any_Socket) -> net.Network_Error {
	net.set_option(socket, .Reuse_Address, true) or_return
	net.set_option(socket, .TCP_Nodelay, true) or_return
	net.set_blocking(socket, false) or_return
	return nil
}
