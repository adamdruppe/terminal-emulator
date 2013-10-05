/**
	This application does our terminal emulation inside another terminal, or the
	Windows console.
	
	Extended functions [s]are[/s] should be gracefully degraded as possible.

	Linux compile:
	dmd nestedterminalemulator.d terminalemulator.d arsd/terminal.d arsd/color.d arsd/eventloop.d -version=with_eventloop

	Windows compile:
	dmd nestedterminalemulator.d terminalemulator.d arsd\terminal.d arsd\color.d
*/

import terminal;
//import arsd.extendedterminalemulator;
import arsd.terminalemulator;


import core.stdc.stdio;
import arsd.color;

version(Windows)
	import core.sys.windows.windows;

version(Windows) extern(Windows) DWORD WaitForSingleObjectEx( HANDLE hHandle, DWORD dwMilliseconds, BOOL bAlertable);

version(Windows)
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
		SetConsoleMode(input.inputHandle, ENABLE_MOUSE_INPUT | ENABLE_WINDOW_INPUT); // disabling processed input so ctrl+c comes through to us

		auto te = new NestedTerminalEmulator(inwritePipe, outreadPipe, &terminal, &input);

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

		auto te = new NestedTerminalEmulator(master, &terminal, &input);

		import arsd.eventloop;
		addListener(&te.handleEvent);
		loop();

	}

	startChild!startup(args.length > 1 ? args[1] : "/bin/bash", args.length > 1 ? args[1 .. $] : ["/bin/bash"]);
}




class NestedTerminalEmulator : TerminalEmulator {
	Terminal* terminal;
	RealTimeConsoleInput* rtInput;

	version(Windows)
	import core.sys.windows.windows;

	version(Windows)
	this(HANDLE stdin, HANDLE stdout, Terminal* terminal, RealTimeConsoleInput* rtInput) {
		this.stdin = stdin;
		this.stdout = stdout;
		this.terminal = terminal;
		this.rtInput = rtInput;

		super(terminal.width, terminal.height);

		version(Windows) {
			overlapped = new OVERLAPPED();
			overlapped.hEvent = cast(void*) this;

			//window.handleNativeEvent = &windowsRead;
			readyToReadWindows(0, 0, overlapped);
			redraw();
		}
	}
	

	version(Posix)
	this(int master, Terminal* terminal, RealTimeConsoleInput* rtInput) {
		this.master = master;
		this.terminal = terminal;
		this.rtInput = rtInput;
		addFileEventListeners(master, &readyToRead, null, null);

		super(terminal.width, terminal.height);
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
		auto te = this;
		final switch(event.type) {
				// FIXME: what about Ctrl+Z? maybe terminal.d should catch that signal too. SIGSTOP i think tho could be SIGTSTP
				// and SIGHUP would perhaps be good to handle too
			case InputEvent.Type.CharacterEvent:
				auto ce = event.get!(InputEvent.Type.CharacterEvent);
				if(ce.eventType == CharacterEvent.Type.Released)
					return;

				char[4] str;
				import std.utf;
				auto data = str[0 .. encode(str, ce.character)];
				te.sendToApplication(data);
			break;
			case InputEvent.Type.SizeChangedEvent:
				auto ce = event.get!(InputEvent.Type.SizeChangedEvent);
				te.resizeTerminal(ce.newWidth, ce.newHeight);
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
						te.sendKeyToApplication(cast(TerminalKey) ev.key);
				}
			break;
			case InputEvent.Type.PasteEvent:
				//terminal.writef("\t%s\n", event.get!(InputEvent.Type.PasteEvent));
			break;
			case InputEvent.Type.MouseEvent:
				//terminal.writef("\t%s\n", event.get!(InputEvent.Type.MouseEvent));
			break;
			case InputEvent.Type.CustomEvent:
			break;
		}
	}


	protected override void changeWindowTitle(string t) {
		if(terminal && t.length)
			terminal.setTitle(t);
	}
	protected override void changeIconTitle(string) {}
	protected override void changeTextAttributes(TextAttributes) {}
	protected override void soundBell() { }

	bool debugMode;
	mixin PtySupport!(doNothing);

	version(Posix)
	import arsd.eventloop;

	bool lastDrawAlternativeScreen;
	void redraw(bool forceRedraw = false) {
		int x, y;

		terminal.hideCursor();

		foreach(ref cell; alternateScreenActive ? alternateScreen : normalScreen) {
			if(!forceRedraw && !cell.invalidated && lastDrawAlternativeScreen == alternateScreenActive) {
				goto skipDrawing;
			}
			cell.invalidated = false;

			auto bg = (cell.attributes.inverse != reverseVideo) ? cell.attributes.foreground : cell.attributes.background;
			auto fg = (cell.attributes.inverse != reverseVideo) ? cell.attributes.background : cell.attributes.foreground;

			ushort tfg, tbg;
			{
				import t = terminal;
				tfg = cell.attributes.foregroundIndex;
				tbg = cell.attributes.backgroundIndex;

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
					version(Windows)
						terminal.moveTo(x, y, ForceOption.alwaysSend);
					else
					terminal.moveTo(x, y);
					terminal.color(tfg, tbg);
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
			terminal.showCursor();
		}

		lastDrawAlternativeScreen = alternateScreenActive;

		terminal.flush();
	}
}
