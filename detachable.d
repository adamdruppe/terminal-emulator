
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

import arsd.detachableterminalemulatormessage;
import arsd.terminalemulator;
import arsd.eventloop;

import std.socket;

import psock = core.sys.posix.sys.socket;
import core.stdc.errno;
import core.sys.posix.unistd;

extern(C)
void detachable_terminal_sigint_handler(int sigNumber) nothrow @nogc {
	import arsd.eventloop;
	try { exit(); }
	catch(Exception e) {
		import core.sys.posix.signal;
		signal(SIGINT, SIG_DFL);
	}
}

static extern(C) char* ptsname(int);

version(standalone_detachable)
void main(string[] args) { detachableMain(args); }

void detachableMain(string[] args) {
	string sname;
	if(args.length > 1 && args[1].length) {
		sname = args[1];
	} else {
		import std.conv;
		import core.sys.posix.unistd;
		sname = to!string(getpid());
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
		if(!exists(socketDirectoryName()))
			mkdir(socketDirectoryName());
		auto dte = new DetachableTerminalEmulator(master, socketFileName(sname), sname);
		scope(exit) {
			import core.sys.posix.unistd;
			import std.string : toStringz;
			dte.dispose();
			unlink(toStringz(socketFileName(sname)));
			close(master);
		}

		try
			loop();
		catch(Throwable e) {
			import std.file;
			append("/tmp/arsd-te-exceptions.txt", e.toString());
		}
	}
	import std.process;
	auto cmd = environment.get("SHELL", "/bin/bash");
	startChild!startup(args.length > 2 ? args[2] : cmd, args.length > 2 ? args[2 .. $] : [cmd]);
}


class DetachableTerminalEmulator : TerminalEmulator {
	void writer(in void[] data) {
		sendOutputMessage(OutputMessageType.dataFromTerminal, data);
	}

	final void sendOutputMessage(OutputMessageType type, const(void)[] data) {
		if(socket != -1) {
			if(data.length)
				while(data.length) {
					auto sending = data;
					if(sending.length > 255) {
						sending = sending[0 .. 255];
					}

					data = data[sending.length .. $];

					ubyte[260] frame;
					frame[0] = type;
					assert(sending.length <= 255);
					frame[1] = cast(ubyte) sending.length;
					frame[2 .. 2 + sending.length] = cast(ubyte[]) sending[];

					auto mustSend = frame[0 .. 2 + sending.length];
						
					int tries = 4000;
					try_again:
					auto sent = psock.send(socket, frame.ptr, 2 + sending.length, 0);
					if(sent < 0 && (.errno == EAGAIN || .errno == EWOULDBLOCK)) {
						import core.thread;
						Thread.sleep(1.msecs);
						tries--;
						if(tries)
							goto try_again;
						else {
							socket = -1;
							return;
						}
					}
					if(sent != 2 + sending.length) {
						//, lastSocketError());
						socket = -1;
						return;
					}
					/*
					while(mustSend.length) {
						auto sent = socket.send(frame[0 .. 2 + sending.length]);
						if(sent <= 0) {
							if(wouldHaveBlocked()) // this shouldn't happen given how small this is but eh
								continue;
							throw new Exception("send fail");
						} else {
							mustSend = mustSend[sent .. $];
						}
					}
					*/
				}
			else {
				ubyte[2] frame;
				frame[0] = type;
				frame[1] = 0;
				psock.send(socket, frame.ptr, 2, 0);
				/*
				again:
				if(socket.send(frame) <= 0)
					if(wouldHaveBlocked())
						goto again;
				*/
			}
		}
	}

	override void mouseMotionTracking(bool b) {
		super.mouseMotionTracking(b);
		sendOutputMessage(b ? OutputMessageType.mouseTrackingOn : OutputMessageType.mouseTrackingOff, null);
	}

	mixin ForwardVirtuals!(writer);

	Socket listeningSocket;
	int socket = -1;
	void acceptConnection() {
		assert(listeningSocket !is null);

		import std.stdio; writeln("accept");

		auto socket = listeningSocket.accept();
		socket.blocking = false; // blocking is bad with the event loop, cuz it is edge triggered
		addFileEventListeners(cast(int) socket.handle, &socketReady, null, null);

		socket.tupleof[0] = cast(socket_t) -1; // wipe out the internal Phobos socket fd, so it doesn't get closed when it gets GC reaped
	}

	void socketError() {
		socket = -1;
	}

	void socketReady(int fd) {
		ubyte[4096] buffer;
		int l2 = 0;
		get_more:
		auto len = psock.recv(fd, buffer.ptr + l2, buffer.length - l2, 0);
		//import std.stdio; writeln(fd, " recv ", len);
		if(len <= 0) {
			// we got it all if it would have blocked
			if(.errno == EAGAIN || .errno == EWOULDBLOCK)
				return;
			// they closed, so we'll detach too
			import std.stdio;
			writeln("closing ", fd, " ", .errno,  " l2 =", l2);
			psock.shutdown(fd, psock.SHUT_RDWR);
			close(fd);
			removeFileEventListeners(fd);
			if(socket == fd)
				socket = -1;
			return;
		}

		auto got = buffer[0 .. len + l2];
		assert(len >= InputMessage.type.offsetof + InputMessage.type.sizeof);

		while(got.length) {
			InputMessage* im = cast(InputMessage*) got.ptr;

			if(im.eventLength > got.length) {
				// not enough.... gotta read more.
				l2 = cast(int) len;
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
						(im.mouseEvent.modifiers & InputMessage.Ctrl) ? true : false,
						(im.mouseEvent.modifiers & InputMessage.Alt) ? true : false
					))
						redraw;
				break;
				case InputMessage.Type.DataPasted:
					sendPasteData(im.pasteEvent.pastedText.ptr[0 .. im.pasteEvent.pastedTextLength]);
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
				case InputMessage.Type.Detach:
					// FIXME
				break;
				case InputMessage.Type.Attach:
					// FIXME
					if(this.socket != -1) {
						import std.stdio; writeln("detached from ", this.socket);
						sendOutputMessage(OutputMessageType.remoteDetached, null);
						close(this.socket);
						removeFileEventListeners(this.socket);
					}

					socket = fd;

					// import std.stdio; writeln("attached to ", fd);
				break;
				case InputMessage.Type.RequestStatus:
					// FIXME
					// status should give: 1) current title, 2) last 3 lines of output (or something), 3) where it is attached

					import std.conv;
					import core.sys.posix.sys.socket;
					import core.stdc.string;

					string message;
					message ~= "\t";
					message ~= windowTitle;
					message ~= "\n";

					auto pts = ptsname(master);
					message ~= "\t";
					message ~= pts[0 .. strlen(pts)];
					message ~= "\n";

					version(linux) {
						static struct ucred {
							pid_t pid;
							uid_t uid;
							gid_t gid;
						}
						ucred credentials;
						uint ucredLength = cast(uint) credentials.sizeof;
						if(this.socket == -1) {
							message ~= "\tDetached\n";

						} else if(getsockopt(this.socket, SOL_SOCKET, 17 /* SO_PEERCRED */, &credentials, &ucredLength) == 0) {
							message ~= "\tAttached to: " ~ to!string(credentials.pid) ~ "\n";
							message ~= "\tAttached by: " ~ to!string(credentials.uid) ~ "\n";
						}
					}

					psock.send(fd, message.ptr, message.length, 0);

					// import std.stdio; writeln("request status");

					close(fd);
					removeFileEventListeners(fd);
				break;
			}
		}

		goto get_more;
	}

	this(int master, string socketName, string title) {
		this.master = master;
		makeNonBlocking(master);
		addFileEventListeners(master, &readyToRead, null, null);

		listeningSocket = new Socket(AddressFamily.UNIX, SocketType.STREAM);
		addFileEventListeners(cast(int) listeningSocket.handle, &acceptConnection, null, null);
		listeningSocket.bind(new UnixAddress(socketName));
		listeningSocket.listen(8);

		windowTitle = title;

		super(80, 25);
	}

	void dispose() {
		if(listeningSocket !is null) {
			listeningSocket.shutdown(SocketShutdown.BOTH);
			listeningSocket.close();
		}
		if(socket != -1) {
			psock.shutdown(socket, psock.SHUT_RDWR);
			close(socket);
			socket = -1;
		}
	}

	bool debugMode;
	mixin PtySupport!(doNothing);

	version(Posix)
	import arsd.eventloop;

	bool connectionActive = false;

	bool lastDrawAlternativeScreen;
	// FIXME: a lot of code duplication between this and nestedterminalemulator
	void redraw(bool forceRedraw = false) {
		if(socket == -1 || !connectionActive)
			return;


		int x, y;


		// I'm just using these to help send the crap out with the buffering...
		import std.process;
		environment["TERM"] = "xterm";
		static import terminal_module = arsd.terminal;
		auto terminal = terminal_module.Terminal(terminal_module.ConsoleOutputType.minimalProcessing, -1, -1, null /* FIXME? */);
		terminal._writeDelegate = &writer;
		terminal._wrapAround = false;

		// these are about ensuring the caching doesn't break between calls given invalidation...
		terminal._currentForeground = -1;
		terminal._currentBackground = -1;
		bool isFirst = true;

		if(cursorShowing)
			terminal.autoHideCursor();
		else
			terminal.hideCursor();

		foreach(idx, ref cell; alternateScreenActive ? alternateScreen : normalScreen) {
			ushort tfg, tbg;

			version(with_24_bit_color) {
			auto bg = (cell.attributes.inverse != reverseVideo) ? cell.attributes.foreground : cell.attributes.background;
			auto fg = (cell.attributes.inverse != reverseVideo) ? cell.attributes.background : cell.attributes.foreground;
			}

			if(!forceRedraw && !cell.invalidated && lastDrawAlternativeScreen == alternateScreenActive) {
				goto skipDrawing;
			}
			cell.invalidated = false;

			{
				import t = arsd.terminal;
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

					version(with_24_bit_color)
					if(reverse) {
						auto tmp = fg;
						fg = bg;
						bg = tmp;
					}

					// reducing it to 16 color
					// FIXME: this sucks, it should do something more sane for palette support like findNearestColor()
					// or even reducing our palette and changing the console palette in Windows for best results

					// and xterm 256 color too can just forward it. and of course if we're nested in ourselves, we can just use
					// a 24 bit extension command.
					tfg &= 0xff0f;
					tbg &= 0xff0f;

					//if(cell.attributes.foregroundIndex & 0x8000)
						//terminal.setTrueColor(terminal_module.RGB(fg.r, fg.g, fg.b), terminal_module.RGB(bg.r, bg.g, bg.b), terminal_module.ForceOption.automatic);
					//else
						terminal.color(tfg, tbg, terminal_module.ForceOption.automatic, reverse);
					terminal.underline = cell.attributes.underlined;
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
			terminal.autoShowCursor();
		}

		lastDrawAlternativeScreen = alternateScreenActive;

		terminal.flush();
	}
}
