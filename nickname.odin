//
// nickname.odin - User Nickname Management
//
// This file manages user nickname generation and validation including:
// - Connection-to-nickname mapping and cleanup
// - Memory management for nickname strings
//
package main

import pr "protocol"

is_nickname_valid :: proc(nickname: string) -> bool {
	if len(nickname) == 0 || len(nickname) > pr.MAX_NICKNAME_LENGTH {
		return false
	}

	for i := 0; i < len(nickname); i += 1 {
		ch := nickname[i]
		switch ch {
		case 'A' ..= 'Z', 'a' ..= 'z', '0' ..= '9', '-', '_', '.':
		// allowed
		case:
			return false
		}
	}

	return true
}
