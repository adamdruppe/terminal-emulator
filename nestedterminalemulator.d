// to compile the magic d demangler:
// dmd nestedterminalemulator.d terminalemulator.d ~/arsd/terminal.d ~/arsd/color.d ~/arsd/eventloop.d -version=with_eventloop -version=d_demangle


/**
	This application does our terminal emulation inside another terminal, or the
	Windows console.
	
	Extended functions [s]are[/s] should be gracefully degraded as possible.

	Linux compile:
	dmd nestedterminalemulator.d terminalemulator.d arsd/terminal.d arsd/color.d arsd/eventloop.d -version=with_eventloop

	Windows compile:
	dmd nestedterminalemulator.d terminalemulator.d arsd\terminal.d arsd\color.d

	FIXME: underlining
*/

import arsd.terminal;
//import arsd.extendedterminalemulator;
import arsd.terminalemulator;


import core.stdc.stdio;
import arsd.color;

version(Windows)
	import core.sys.windows.windows;

version(Windows) extern(Windows) DWORD WaitForSingleObjectEx( HANDLE hHandle, DWORD dwMilliseconds, BOOL bAlertable);
version(Windows) extern(Windows) DWORD WaitForMultipleObjectsEx(DWORD  nCount,const HANDLE *lpHandles,BOOL   bWaitAll,DWORD  dwMilliseconds,BOOL   bAlertable);

version(use_libssh2)
void main(string[] args) {
	import arsd.libssh2;
	import std.socket;
	void startup(Socket socket, LIBSSH2_SESSION* sshSession, LIBSSH2_CHANNEL* sshChannel) {
		// FIXME: finish this
	}

	if(args.length <  6) {
		import std.format : format;
		import std.string : toStringz;
		auto msg = format("Provide a list of arguments like:\n%s font_size host port username keyfile\nSo for example: %s example.com 0 22 root /path/to/id_rsa\n(font size of 0 means use a system font)\nOn Windows, it might be helpful to create a shortcut with your options specified in the properties sheet command line option.", args[0], args[0]);

		import std.stdio;
		writeln(msg);
		return;
	}

	string host = args[2];
	import std.conv : to;
	short port = to!short(args[3]);
	string username = args[4];
	string keyfile = args[5];
	string expectedFingerprint = null;
	if(args.length > 6)
		expectedFingerprint = args[6];

	startChild!startup(host, port, username, keyfile, expectedFingerprint);
}
else version(Windows)
void main(string[] args) {
	if(args.length < 2) {
		import std.stdio;
		writeln("Give a command line to run like: plink.exe user@server.com -i keyfile /opt/serverside");
		return;
	}

	void startup(HANDLE inwritePipe, HANDLE outreadPipe) {
		auto terminal = Terminal(ConsoleOutputType.cellular);
		auto input = RealTimeConsoleInput(&terminal, ConsoleInputFlags.raw | ConsoleInputFlags.allInputEvents);

		SetConsoleMode(terminal.hConsole, ENABLE_PROCESSED_OUTPUT); // no more line wrapping so our last line outputted is cool
		SetConsoleMode(input.inputHandle, 0x80 /*ENABLE_EXTENDED_FLAGS*/ | ENABLE_MOUSE_INPUT | ENABLE_WINDOW_INPUT); // disabling processed input so ctrl+c comes through to us
		terminal._wrapAround = false;

		auto te = new NestedTerminalEmulator(inwritePipe, outreadPipe, &terminal);

		loop: while(true) {
			if(WaitForSingleObjectEx(input.inputHandle, INFINITE, true) == 0) {
				auto event = input.nextEvent();
				te.handleEvent(event);
			} else {
				// apc; the read handler will have already called so we don't have to worry about it
			}

			if(childDead)
				break;
		}
	}

	import std.string;
	startChild!startup(null, args[1..$].join(" "));
}
else version(Posix)
void main(string[] args) {
	void startup(int master) {
		auto terminal = Terminal(ConsoleOutputType.cellular);
		auto input = RealTimeConsoleInput(&terminal, ConsoleInputFlags.raw | ConsoleInputFlags.allInputEvents);
		terminal._wrapAround = false;

		auto te = new NestedTerminalEmulator(master, &terminal);

		/*
		import core.sys.posix.unistd;
		import core.sys.posix.fcntl;
		int nullRead = open("/dev/pts/13", O_RDONLY);
		int nullWrite = open("/dev/pts/13", O_WRONLY);
		assert(nullRead > 0);
		assert(nullWrite > 0);

		close(0);
		close(1);
		dup2(nullRead, 0);
		dup2(nullWrite, 1);
		*/
		//te.detach();

		import arsd.eventloop;
		addListener(&te.handleEvent);
		loop();

	}

	import std.process;
	auto cmd = environment.get("SHELL", "/bin/bash");
	startChild!startup(args.length > 1 ? args[1] : cmd, args.length > 1 ? args[1 .. $] : [cmd]);
}




class NestedTerminalEmulator : TerminalEmulator {
	Terminal* terminal;
	//RealTimeConsoleInput* rtInput;

	version(Posix)
	void detach() {
		import core.sys.posix.unistd;
		if(fork()) {
			// the parent exits, leaving the parent terminal back to normal
			static import arsd.eventloop;
			arsd.eventloop.exit();
		} else {
			// while the child kinda floats in limbo
			//terminal = null;
		}
	}

	version(Windows)
	import core.sys.windows.windows;

	version(use_libssh2)
	import arsd.libssh2;

	version(use_libssh2)
	this(LIBSSH2_CHANNEL* sshChannel, Terminal* terminal) {
		this.sshChannel = sshChannel;
		this.terminal = terminal;
		super(terminal.width, terminal.height);
	}

	else version(Windows)
	this(HANDLE stdin, HANDLE stdout, Terminal* terminal) {
		this.stdin = stdin;
		this.stdout = stdout;
		this.terminal = terminal;
		//this.rtInput = rtInput;

		//this.rtInput = rtInput;

		super(terminal.width, terminal.height);

		version(Windows) {
			overlapped = new OVERLAPPED();
			overlapped.hEvent = cast(void*) this;

			//window.handleNativeEvent = &windowsRead;
			readyToReadWindows(0, 0, overlapped);
			redraw();
		}
	}
	else version(Posix)
	this(int master, Terminal* terminal) {
		this.master = master;
		this.terminal = terminal;
		//this.rtInput = rtInput;
		makeNonBlocking(master);
		addFileEventListeners(master, &readyToRead, null, null);

		if(terminal)
			super(terminal.width, terminal.height);
		else
			super(80, 25);
	}

	version(Windows)
	override TextAttributes defaultTextAttributes() {
		TextAttributes da;
		da.foregroundIndex = 256; // terminal.d's Color.DEFAULT
		da.backgroundIndex = 256;
		import arsd.color;
		da.foreground = Color(200, 200, 200);
		da.background = Color(0, 0, 0);
		return da;
	}

	void handleEvent(InputEvent event) {
	import std.conv;
		auto te = this;
		final switch(event.type) {
			// FIXME: what about Ctrl+Z? maybe terminal.d should catch that signal too. SIGSTOP i think tho could be SIGTSTP
			case InputEvent.Type.HangupEvent:
				version(with_eventloop)
					exit();
			break;
			case InputEvent.Type.CharacterEvent:
				auto ce = event.get!(InputEvent.Type.CharacterEvent);
				if(ce.eventType == CharacterEvent.Type.Released)
					return;

				endScrollback();
				char[4] str;
				import std.utf;
				auto data = str[0 .. encode(str, ce.character)];
				te.sendToApplication(data);
			break;
			case InputEvent.Type.SizeChangedEvent:
				auto ce = event.get!(InputEvent.Type.SizeChangedEvent);
				te.resizeTerminal(ce.newWidth, ce.newHeight);
			break;
			case InputEvent.Type.EndOfFileEvent:
				// FIXME: is this correct?
				te.sendToApplication("\004");
			break;
			case InputEvent.Type.UserInterruptionEvent:
				te.sendToApplication("\003");
			break;
			case InputEvent.Type.NonCharacterKeyEvent:
				auto ev = event.get!(InputEvent.Type.NonCharacterKeyEvent);
				if(ev.eventType == NonCharacterKeyEvent.Type.Pressed) {
					with(NonCharacterKeyEvent.Key)
					if(ev.key == escape)
						te.sendToApplication("\033");
					else
						// this is guaranteed to work since the enum values are the same by design
						if(te.sendKeyToApplication(cast(TerminalKey) ev.key,
							(ev.modifierState & ModifierState.shift)?true:false,
							(ev.modifierState & ModifierState.alt)?true:false,
							(ev.modifierState & ModifierState.control)?true:false))
							redraw();
				}
			break;
			case InputEvent.Type.PasteEvent:
				auto ev = event.get!(InputEvent.Type.PasteEvent);
				sendPasteData(ev.pastedText);
			break;
			case InputEvent.Type.MouseEvent:
				auto me = event.get!(InputEvent.Type.MouseEvent);

				if(sendMouseInputToApplication(me.x, me.y,
					cast(arsd.terminalemulator.MouseEventType) me.eventType,
					cast(arsd.terminalemulator.MouseButton) me.buttons,
					(me.modifierState & ModifierState.shift) ? true : false,
					(me.modifierState & ModifierState.control) ? true : false,
					(me.modifierState & ModifierState.alt) ? true : false
				))
					redraw();
			break;
			case InputEvent.Type.CustomEvent:
			break;
		}
	}

	version(Windows) {
		protected override void changeWindowIcon(IndexedImage t) {
			if(t !is null) {
				// FIXME: i might be able to change this with GetConsoleWindow
			}
		}

		protected override void changeIconTitle(string) {} // doesn't matter
		protected override void changeTextAttributes(TextAttributes) {} // ditto
		protected override void soundBell() {
			if(terminal)
			terminal.writeStringRaw("\007");
		}
		protected override void copyToClipboard(string text) {
			arsd.simpledisplay.setClipboardText(simpleWindowConsole, text);
		}
		protected override void pasteFromClipboard(void delegate(in char[]) dg) {
			arsd.simpledisplay.getClipboardText(simpleWindowConsole, dg);
		}
		protected override void changeCursorStyle(CursorStyle s) {

		}
	} else {
		void writeRaw(in char[] s) {
			if(terminal)
				terminal.writeStringRaw(s);
		}
		mixin ForwardVirtuals!writeRaw;
	}

	protected override void changeWindowTitle(string t) {
		if(terminal && t.length)
			terminal.setTitle(t);
	}

	version(Windows) {
		static import arsd.simpledisplay; // this is for copy/paste
		private arsd.simpledisplay.SimpleWindow _simpleWindowConsole;
		protected arsd.simpledisplay.SimpleWindow simpleWindowConsole() {
			if(_simpleWindowConsole is null) {
				auto handle = arsd.simpledisplay.GetConsoleWindow();
				_simpleWindowConsole = new arsd.simpledisplay.SimpleWindow(handle);
			}
			return _simpleWindowConsole;
		}
	}

	bool debugMode;
	mixin PtySupport!(doNothing);

	version(d_demangle) {
		void readyToRead(int fd) {
			import core.sys.posix.unistd;
			ubyte[4096] buffer;
			int len = read(fd, buffer.ptr, 4096);
			if(len < 0)
				throw new Exception("read failed");

			auto data = buffer[0 .. len];

			import std.regex;
			char[] dem(Captures!(char[], uint) m) {
				import core.demangle;
				return "\033[1m" ~ demangle(m.hit) ~ "\033[22m";
			}
			data = cast(typeof(data)) replace!dem(cast(char[]) data, regex("_D[a-zA-Z0-9_]+", "g"));

			super.sendRawInput(data);

			redraw();
		}
	}


	version(Posix)
	import arsd.eventloop;

	bool lastDrawAlternativeScreen;
	// FIXME: a lot of code duplication between this and detachable
	void redraw(bool forceRedraw = false) {
		int x, y;
		if(terminal is null)
			return;

		if(cursorShowing)
			terminal.autoHideCursor();
		else
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

				version(Windows) {
					ushort b, r;

					if(tfg != 256) {
						b = tfg & 1;
						r = (tfg & 4) >> 2;
						tfg &= 0b0000_0010;
						tfg |= b << 2;
						tfg |= r;
					}

					if(tbg != 256) {
						b = tbg & 1;
						r = (tbg & 4) >> 2;
						tbg &= 0b0000_0010;
						tbg |= b << 2;
						tbg |= r;
					}
				}

				if(cell.attributes.bold)
					tfg |= t.Bright;
			}
			if(cell.ch != dchar.init) {
				char[4] str;
				import std.utf;
				try {
					auto stride = encode(str, cell.ch);

					// on Windows, we hacked the mode above so terminal.d doesn't track the console correctly
					// see also for a potential improvement:
					// http://msdn.microsoft.com/en-us/library/windows/desktop/ms687404%28v=vs.85%29.aspx
					terminal.moveTo(x, y);

					bool reverse = cell.attributes.inverse != reverseVideo; /* != == ^ btw */
					if(cell.selected)
						reverse = !reverse;

					// reducing it to 16 color
					// FIXME: this sucks, it should do something more sane for palette support like findNearestColor()
					// or even reducing our palette and changing the console palette in Windows for best results

					// and xterm 256 color too can just forward it. and of course if we're nested in ourselves, we can just use
					// a 24 bit extension command.
					tfg &= 0xff0f;
					terminal.color(tfg, tbg, ForceOption.automatic, reverse);
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
			terminal.moveTo(cursorX, cursorY);
			terminal.autoShowCursor();
		}

		lastDrawAlternativeScreen = alternateScreenActive;

		terminal.flush();
	}
}
