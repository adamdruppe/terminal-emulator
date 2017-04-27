// this module defines a message you can shoot over the socket to a detachable emulator
module arsd.detachableterminalemulatormessage;

// FIXME: the messages are 24 bytes each... they could probably be a good amount less.

string socketFileName(string sessionName) {
	import std.algorithm;
	if(endsWith(sessionName, ".socket"))
		sessionName = sessionName[0 .. $ - ".socket".length];
	return socketDirectoryName() ~ "/" ~ sessionName ~ ".socket";
}

string socketDirectoryName() {
	import std.process;
	auto dirName = environment["HOME"] ~ "/.detachable-terminals";
	return dirName;
}

/*
	OutputMessages, from the terminal process itself, come in this format:
	ubyte: message type
	ubyte: message length
	bytes[] message

	Messages longer than 255 bytes must be broken up into several messages.
*/

enum OutputMessageType : ubyte {
	NULL,
	dataFromTerminal,
	remoteDetached,
	mouseTrackingOn,
	mouseTrackingOff,
}

align(1)
struct InputMessage {
	align(1):
	enum Type : ubyte {
		// key event
		KeyPressed,

		// character event
		CharacterPressed,

		// size event
		SizeChanged,

		// mouse event
		MouseMoved,
		MousePressed,
		MouseReleased,

		// paste event
		DataPasted,

		// special commands
		RedrawNow, // send all state over (perhaps should be merged with "active" and maybe send size changed info too. term as well?)


		// FIXME: implement these
		Inactive, // the user moved another screen to the front, stop redrawing (but still send new titles, icons, or bells)
		Active, // the user moved you to the front, resume redrawing normally

		// Initial connection things
		RequestStatus, // requests status about the backend - pid, etc.
		Attach, // attaches it and updates the status info
		Detach,
		// We also want redraw and title and such so I can just ask
		// for info about a socket and dump it to a terminal to like
		// quasi attach without actually attaching.
	}

	// for modifiers
	enum Shift = 1;
	enum Ctrl = 2;
	enum Alt = 4;

	short eventLength;
	Type type;

	struct MouseEvent {
	align(1):
		ubyte button;
		short x;
		short y;
		ubyte modifiers;
	}

	struct KeyEvent {
	align(1):
		int key;
		ubyte modifiers;
	}

	struct CharacterEvent {
	align(1):
		dchar character;
	}

	struct SizeEvent {
	align(1):
		short width;
		short height;
	}

	struct PasteEvent {
	align(1):
		short pastedTextLength;
		char[1] pastedText;
	}

	struct AttachEvent {
	align(1):
		int pid; // the pid of the attach instance
		short sessionNameLength;
		char[1] sessionName;
	}

	union {
	align(1):
		MouseEvent mouseEvent;
		KeyEvent keyEvent;
		CharacterEvent characterEvent;
		SizeEvent sizeEvent;
		PasteEvent pasteEvent;
		AttachEvent attachEvent;
	}
}

/*
struct OutputMessage {
	enum Type : ubyte {
		DataOutput
	}

	Type type;
	ushort length;

	struct DataOutputEvent {
		int dataLength;
		ubyte[1] data;
	}

	union {
		DataOutputEvent dataOutputEvent;
	}
}
*/
