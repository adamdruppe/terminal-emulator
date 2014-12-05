// this module defines a message you can shoot over the socket to a detachable emulator
module arsd.detachableterminalemulatormessage;

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

struct InputMessage {
	enum Type : int {
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
	}

	// for modifiers
	enum Shift = 1;
	enum Ctrl = 2;
	enum Alt = 4;

	int eventLength;
	Type type;

	struct MouseEvent {
		int button;
		int x;
		int y;
		ubyte modifiers;
	}

	struct KeyEvent {
		int key;
		ubyte modifiers;
	}

	struct CharacterEvent {
		dchar character;
	}

	struct SizeEvent {
		int width;
		int height;
	}

	struct PasteEvent {
		int pastedTextLength;
		char[1] pastedText;
	}

	union {
		MouseEvent mouseEvent;
		KeyEvent keyEvent;
		CharacterEvent characterEvent;
		SizeEvent sizeEvent;
		PasteEvent pasteEvent;
	}
}

/*
struct OutputMessage {
	ubyte type;
	ushort length;
	ubyte[1] data;
}
*/
