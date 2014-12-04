
// dmd detachable.d message.d terminalemulator.d ~/arsd/terminal.d ~/arsd/color.d ~/arsd/eventloop.d -version=with_eventloop ~/d/dmd2/src/phobos/std/socket.d

/*
	This one sends stuff out in escape sequences kinda like nested terminal emulator

	but receives its input from a unix socket instead of a Terminal instance. This data
	should be already fairly well formatted, i.e. not escape sequences. Fuck that noise.
*/


/*
	A gnu screen replacement that goes hand in hand with our own terminal emulator.

	Features:
		detaching and reattaching
		creating new screens, switching, etc
		each screen should have all the state of a TerminalEmulator + extensions
		C-a [ might work just to enter scrollback mode via keyboard, but it doesn't need to be special because the scrollback buffer can be sent down as well.

	Controls I want to keep:
		C-a C-a: switch to previous
		C-a a: send C-a
		C-a 0-9: switch to screen
		C-a ": list screens
		C-a d: detach
		C-a c: create

		Maybes:
			C-a ': type window name, might be ok, but eh
			C-a A: rename
			C-a k: kill
			C-a l: refresh
			C-a SPACE: next window

			monitoring?
			display tabs?

		New:
			C-a t: toggle taskbar
			C-a C: connect to a particular socket
			C-a C-d: disconnect one socket, leaving the others up


	Extensions:
		detach current window into a new screen session. maybe.

	The titles should be
		inner title -- outer title

	Does not need screen sharing or locking.

	It does not have to be connected
*/

module arsd.detachableterminalemulator;

import arsd.terminalemulator;
import arsd.eventloop;

import std.socket;

extern(C)
void detachable_terminal_sigint_handler(int sigNumber) nothrow @nogc {
	import arsd.eventloop;
	try { exit(); }
	catch(Exception e) {
		import core.sys.posix.signal;
		signal(SIGINT, SIG_DFL);
	}
}

version(standalone_detachable)
void main(string[] args) { detachableMain(args); }

void detachableMain(string[] args) {
	string sname;
	if(args.length > 1) {
		sname = args[1];
	}

	//signal(SIGPIPE, SIG_IGN);
	import core.sys.posix.signal;
	signal(SIGINT, &detachable_terminal_sigint_handler);

	void startup(int master) {
		if(sname.length == 0) {
			import std.conv;
			import core.sys.posix.unistd;
			sname = to!string(getpid);
		}

		import std.process;
		import std.file;
		if(!exists(environment["HOME"] ~ "/.detachable-terminals"))
			mkdir(environment["HOME"] ~ "/.detachable-terminals");
		auto dte = new DetachableTerminalEmulator(master, environment["HOME"] ~ "/.detachable-terminals/" ~ sname);

		loop();

		import core.sys.posix.unistd;
		dte.dispose();
		unlink((environment["HOME"] ~ "/.detachable-terminals/" ~ sname ~ "\0").ptr);
		close(master);
	}
	startChild!startup(args.length > 2 ? args[2] : "/bin/bash", args.length > 2 ? args[2 .. $] : ["/bin/bash"]);
}


class DetachableTerminalEmulator : TerminalEmulator {
	void writer(in char[] data) {
		if(socket !is null)
			socket.send(data);
	}

	mixin ForwardVirtuals!(writer);

	Socket listeningSocket;
	Socket socket;
	void acceptConnection() {
		assert(listeningSocket !is null);

		if(socket !is null) {
			socket.close();
			removeFileEventListeners(socket.handle);
		}

		socket = listeningSocket.accept();
		addFileEventListeners(cast(int) socket.handle, &socketReady, null, null);
	}

	void socketReady() {
		assert(socket !is null);
		ubyte[4096] buffer;
		int l2 = 0;
		get_more:
		auto len = socket.receive(buffer[l2 .. $]);
		if(len <= 0) {
			// they closed, so we'll detach too
			socket.shutdown(SocketShutdown.BOTH);
			socket.close();
			removeFileEventListeners(cast(int) socket.handle);
			socket = null;
			return;
		}

		auto got = buffer[0 .. len + l2];
		assert(len > 4);

		while(got.length) {
			import arsd.detachableterminalemulatormessage;
			InputMessage* im = cast(InputMessage*) got.ptr;

			if(im.eventLength > got.length) {
				// not enough.... gotta read more.
				l2 = len;
				goto get_more;
			}

			got = got[im.eventLength .. $];

			// FIXME: if we don't get all the data in one go it shouldn't be fatal
			import std.string;
			assert(len >= im.eventLength, format("%d != %d", len, im.eventLength));

			final switch(im.type) {
				case InputMessage.Type.KeyPressed:
					if(sendKeyToApplication(cast(TerminalKey) im.keyEvent.key,
						(im.keyEvent.modifiers & InputMessage.Shift)?true:false,
						(im.keyEvent.modifiers & InputMessage.Alt)?true:false,
						(im.keyEvent.modifiers & InputMessage.Ctrl)?true:false))

						redraw();
				break;
				case InputMessage.Type.CharacterPressed:
					endScrollback();
					char[4] str;
					import std.utf;
					auto data = str[0 .. encode(str, im.characterEvent.character)];
					sendToApplication(data);
				break;
				case InputMessage.Type.SizeChanged:
					resizeTerminal(im.sizeEvent.width, im.sizeEvent.height);
				break;
				case InputMessage.Type.MouseMoved:
				case InputMessage.Type.MousePressed:
				case InputMessage.Type.MouseReleased:
					MouseEventType et;
					if(im.type == InputMessage.Type.MouseMoved)
						et = MouseEventType.motion;
					else if(im.type == InputMessage.Type.MousePressed)
						et = MouseEventType.buttonPressed;
					else if(im.type == InputMessage.Type.MouseReleased)
						et = MouseEventType.buttonReleased;

					if(sendMouseInputToApplication(im.mouseEvent.x, im.mouseEvent.y,
						et,
						cast(arsd.terminalemulator.MouseButton) im.mouseEvent.button,
						(im.mouseEvent.modifiers & InputMessage.Shift) ? true : false,
						(im.mouseEvent.modifiers & InputMessage.Ctrl) ? true : false
					))
						redraw;


				break;
				case InputMessage.Type.DataPasted:
					// FIXME
				break;
				case InputMessage.Type.RedrawNow:
					connectionActive = true;
					changeCursorStyle(cursorStyle);
					changeWindowTitle(windowTitle);
					changeWindowIcon(windowIcon);
					redraw(true);
				break;
				case InputMessage.Type.Active:
					connectionActive = true;
				break;
				case InputMessage.Type.Inactive:
					connectionActive = false;
				break;
			}
		}
	}

	this(int master, string socketName) {
		this.master = master;
		addFileEventListeners(master, &readyToRead, null, null);

		listeningSocket = new Socket(AddressFamily.UNIX, SocketType.STREAM);
		addFileEventListeners(cast(int) listeningSocket.handle, &acceptConnection, null, null);
		listeningSocket.bind(new UnixAddress(socketName));
		listeningSocket.listen(8);

		super(80, 25);
	}

	void dispose() {
		if(listeningSocket !is null) {
			listeningSocket.shutdown(SocketShutdown.BOTH);
			listeningSocket.close();
		}
		if(socket !is null) {
			socket.shutdown(SocketShutdown.BOTH);
			socket.close();
		}
	}

	bool debugMode;
	mixin PtySupport!(doNothing);

	version(Posix)
	import arsd.eventloop;

	bool connectionActive = false;

	bool lastDrawAlternativeScreen;
	void redraw(bool forceRedraw = false) {
		if(socket is null || !connectionActive)
			return;


		int x, y;


		// I'm just using these to help send the crap out with the buffering...
		import std.process;
		environment["TERM"] = "xterm";
		static import terminal_module = terminal;
		auto terminal = terminal_module.Terminal(terminal_module.ConsoleOutputType.minimalProcessing, -1, cast(int) socket.handle, null /* FIXME? */);
		terminal._wrapAround = false;

		// these are about ensuring the caching doesn't break between calls given invalidation...
		terminal._currentForeground = -1;
		terminal._currentBackground = -1;
		bool isFirst = true;

		terminal.hideCursor();

		foreach(idx, ref cell; alternateScreenActive ? alternateScreen : normalScreen) {
			ushort tfg, tbg;
			if(!forceRedraw && !cell.invalidated && lastDrawAlternativeScreen == alternateScreenActive) {
				goto skipDrawing;
			}
			cell.invalidated = false;

			//auto bg = (cell.attributes.inverse != reverseVideo) ? cell.attributes.foreground : cell.attributes.background;
			//auto fg = (cell.attributes.inverse != reverseVideo) ? cell.attributes.background : cell.attributes.foreground;

			{
				import t = terminal;
				// we always work with indexes, so the fallback flag is irrelevant here
				tbg = cell.attributes.backgroundIndex & ~0x8000;
				tfg = cell.attributes.foregroundIndex & ~0x8000;

				if(cell.attributes.bold)
					tfg |= t.Bright;
			}
			if(cell.ch != dchar.init) {
				char[4] str;
				import std.utf;
				try {
					auto stride = encode(str, cell.ch);

					terminal.moveTo(x, y, isFirst ? terminal_module.ForceOption.alwaysSend : terminal_module.ForceOption.automatic);
					isFirst = false;

					bool reverse = cell.attributes.inverse != reverseVideo; /* != == ^ btw */
					if(cell.selected)
						reverse = !reverse;

					// reducing it to 16 color
					// FIXME: this sucks, it should do something more sane for palette support like findNearestColor()
					// or even reducing our palette and changing the console palette in Windows for best results

					// and xterm 256 color too can just forward it. and of course if we're nested in ourselves, we can just use
					// a 24 bit extension command.
					tfg &= 0xff0f;
					tbg &= 0xff0f;

					terminal.color(tfg, tbg, terminal_module.ForceOption.automatic, reverse);
					terminal.write(cast(immutable) str[0 .. stride]);
				} catch(Exception e) {
				}
			} else if(cell.nonCharacterData !is null) {
				// something maybe
			}

			skipDrawing:
			x++;
			if(x == screenWidth) {
				x = 0;
				y++;
			}
		}

		if(cursorShowing) {
			terminal.moveTo(cursorX, cursorY, forceRedraw ? terminal_module.ForceOption.alwaysSend : terminal_module.ForceOption.automatic);
			terminal.showCursor();
		}

		lastDrawAlternativeScreen = alternateScreenActive;

		terminal.flush();
	}
}
