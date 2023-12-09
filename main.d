// FIXME: teh ttf font thing can be removed now realistically

// FIXME: on Windows 8, the size event doesn't fire when you maximize the window

// FIXME: use_libssh2 should do keepalive.

// FIXME: ctrl+space is supposed to send \0.
// but otherwise they just -0x40

// some things do alt+thing as just being ESC followed by thing...

/+
	winpty notes:

	* it doesn't translate the cursor size commands from windows to esc.
	* it should be tested carefully.
+/

/**
	This is the graphical application for the terminal emulator.

	Linux compile:
	dmd main.d terminalemulator.d arsd/simpledisplay.d arsd/color.d -debug arsd/png.d arsd/bmp.d arsd/ttf.d -Jfont

	Windows compile:
	dmd main.d arsd\simpledisplay.d arsd\color.d -debug arsd\ttf.d terminalemulator.d -Jfont arsd\png.d arsd\bmp.d


	The windows version expects serverside.d to be running on the other side and needs plink.exe available to speak ssh unless
	you compile with -version=use_libssh2.
*/

// FIXME: blue text under the cursor is virtually impossible to see.

// You can edit this if you like to make the alt+keys do other stuff.
enum string[dchar] altMappings = [
	//'t' : "θ",
	//'p' : "\u03c6",

	'\'' : "\&ldquo;",
	'\"' : "\&rdquo;",

	// unicode parens
	// \u27e8\u27e9 or \u3008\u3009 
];

enum string[dchar] superMappings = [
	'j' : "Super!"
];

/*
	FIXME
	mouse tracking inside gnu screen always turns vim to visual mode.



echo -e '\033]50;-*-bitstream vera sans-*-*-*-*-*-*-*-*-*-*-*-*\007'
	changes the font in xterm

echo -e '\033[8]'
	sets the current params to default params in linux

	[10;n] - bell frequency in hz
	[11;n] - bell duration in msec
	[12;n] - bring console to the front

\033]4; num; txt
	ansi color in xterm
\033]10; txt
	tynamic text color

\033]R
	reset palette on linux
\033]Pnrrggbb
	change palette on linux, each thing after the P is hex
	messes up output on xterm


FIXME: lag on windows reading
The 'o' command in vim doesn't quite work right.

mutt inside gnu screen is broke

	Cool features:
		cursor shape can be changed
		cursor color can be changed



CSI P s L
Insert P s Line(s) (default = 1) (IL).
CSI P s M
Delete P s Line(s) (default = 1) (DL).
CSI P s P
Delete P s Character(s) (default = 1) (DCH).
CSI P s S
Scroll up P s lines (default = 1) (SU).
CSI P s T
Scroll down P s lines (default = 1) (SD).

	FIXME:

	focus in out tracking
	FocusIn/FocusOut

	// application end
	*) application mouse handling
	*) character sets for line drawing
	*) extensions
		* palette set and reset
		* change color with rgb

	// ui end
	*) automatic mouse selection
	*) scrollback UI
	*) speed

	// other
	*) nesting in other terminals
	*) gnu screen coolness
	*) windows version
*/

import arsd.terminalemulator;

import arsd.minigui;
import arsd.script;

import arsd.color;

class DebugWindow : MainWindow {
	SimpleWindow window;
	TerminalEmulatorWindow te;
	this(SimpleWindow window, TerminalEmulatorWindow te) {
		this.window = window;
		this.te = te;
		super("TE Debug", 300, 100);
		this.win.closeQuery = delegate void () {
			this.hide();
		};
		setMenuAndToolbarFromAnnotatedCode(this);
		this.win.beingOpenKeepsAppOpen = false;
	}

	@menu("File") {
		void Save_Scrollback() {
			getSaveFileName( (string s) {
				te.writeScrollbackToFile(s);
			});
		}
	}

	@menu("Debug") {
		version(Posix)
		void toggleDebugOutput() {
			te.debugMode = !te.debugMode;
		}
	}
}

version(Windows) {
	import core.sys.windows.windows;
	import core.sys.windows.winsock2;
}

version(Windows) {
	extern(Windows) int WSAAsyncSelect(SOCKET, HWND, uint, int);
	enum int FD_CLOSE = 1 << 5;
	enum int FD_READ = 1 << 0;
	enum int WM_USER = 1024;
}

version(use_libssh2)
	import arsd.libssh2;

version(use_libssh2)
void main(string[] args) {
	import std.socket;
	void startup(Socket socket, LIBSSH2_SESSION* sshSession, LIBSSH2_CHANNEL* sshChannel) {
		import std.conv;
		auto term = new TerminalEmulatorWindow(sshChannel, (args.length > 1) ? to!int(args[1]) : 0);
		auto timer = new Timer(30 * 1000, {
			int next;
			int err = libssh2_keepalive_send(sshSession, &next);
			if (err) {
         			// blargh... close the window?
			}
		});
		version(Posix) {
			auto listener = new PosixFdReader(&term.readyToRead, cast(int) socket.handle);
			// FIXME? I don't remember why this was here.
			globalHupHandler = (int fd, int) {
				import core.sys.posix.unistd;
				close(fd);
				EventLoop.get.exit();
			};
			term.eventLoop(0);
		} else version(Windows) {
			if(WSAAsyncSelect(socket.handle, term.window.hwnd, WM_USER + 150, FD_CLOSE | FD_READ))
				throw new Exception("WSAAsyncSelect");
			term.window.handleNativeEvent = delegate int(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam, out int mustReturn) {
				if(hwnd !is term.window.impl.hwnd)
					return 1; // we don't care...
				switch(msg) {
					case WM_USER + 150: // socket activity
						switch(LOWORD(lParam)) {
							case FD_READ:
								if(term.readyToRead(0))
									term.window.close();
							break;
							case FD_CLOSE:
								term.window.close();
							break;
							default:
								// nothing
						}
					break;
					default: return 1; // not handled, pass it on
				}
				return 0;
			};
			term.window.eventLoop(0);
		} else static assert(0);
		// 
	}

	if(args.length <  6) {
		import std.format : format;
		import std.string : toStringz;
		auto msg = format("Provide a list of arguments like:\n%s font_size host port username keyfile\nSo for example: %s 0 example.com 22 root /path/to/id_rsa\n(font size of 0 means use a system font)\nOn Windows, it might be helpful to create a shortcut with your options specified in the properties sheet command line option.", args[0], args[0]);

		version(Windows)
			MessageBoxA(null, toStringz(msg), "Couldn't start up", 0);
		else {
			import std.stdio;
			writeln(msg);
		}
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
	import core.sys.windows.windows;

	version(winpty) {
		void startup(HPCON hpc, HANDLE inwritePipe, HANDLE outreadPipe) {
			import std.conv;
			auto term = new TerminalEmulatorWindow(hpc, inwritePipe, outreadPipe, (args.length > 1) ? to!int(args[1]) : 0);

			term.window.eventLoop(0);
		}

	} else {
		void startup(HANDLE inwritePipe, HANDLE outreadPipe) {
			import std.conv;
			auto term = new TerminalEmulatorWindow(inwritePipe, outreadPipe, (args.length > 1) ? to!int(args[1]) : 0);

			term.window.eventLoop(0);
		}
	}

	int size;
	string[] cmdArgs;

	version(winpty) {
		if(args.length < 2) {
			size = 0;
			cmdArgs = ["cmd.exe"];
		} else {
			cmdArgs = args[2 .. $];
		}

	} else {
		if(args.length < 2) {
			import std.stdio;
			writeln("Give a font size and command line to run like: 0 plink.exe user@server.com -i keyfile /opt/serverside");
			return;
		}
	}

	import std.string;
	startChild!startup(null, cmdArgs.join(" "));
}
else version(Posix)
void main(string[] args) {
	void startup(int master) {
		import std.conv;
		auto term = new TerminalEmulatorWindow(master, (args.length > 1) ? to!int(args[1]) : 0);
		term.window.eventLoop(0);
		// 
	}

	//try {
		import std.process;
		auto cmd = environment.get("SHELL", "/bin/bash");
		startChild!startup(args.length > 2 ? args[2] : cmd, args.length > 2 ? args[2 .. $] : [cmd]);
	//} catch(Throwable t) {
	version(none) {
		//import std.stdio;
		//writeln(t.toString());
		// we might not be run from a tty to print the message, so pop it up some other way.
		// I'm lazy so i'll just call xmessage. good enough to pop it up in the gui environment
		version(linux) {
		import std.process;
		auto pipes = pipeShell("xmessage -file -");
		pipes.stdin.write(t.toString());
		pipes.stdin.close();
		} else version(Windows) 
			MessageBoxA(null, "Exception", toStringz(t.toString()), 0);
	}
}

import arsd.simpledisplay;

import arsd.ttf;
struct XImagePainter {
	Image img;
	TtfFont* ttfFont;
	int fontWidth;

	void notifyCursorPosition(int, int, int, int) {}

	immutable {
		int nextLineAdjustment;
		int offR;
		int offB;
		int offG;
		int bpp;
	}
	ubyte* data;
	ubyte* ending;

	ubyte[] getThing(int x, int y) {
		auto d = data + y * nextLineAdjustment + x * bpp;
		return d[0 .. ending - d];
	}

	this(Image i, TtfFont* ttfFont, int fontWidth) {
		this.img = i;
		this.ttfFont = ttfFont;
		this.fontWidth = fontWidth;

		 nextLineAdjustment = img.adjustmentForNextLine();
		 offR = img.redByteOffset();
		 offB = img.blueByteOffset();
		 offG = img.greenByteOffset();
		 bpp = img.bytesPerPixel();
		 data = img.getDataPointer() + img.offsetForTopLeftPixel();

		 ending = img.getDataPointer() + img.height * img.bytesPerLine();
	}

	void drawImage(Point upperLeft, Image i, Point upperLeftOfImage, int w, int h) {
		auto destPtr = data + upperLeft.y * nextLineAdjustment + upperLeft.x * bpp;

		if(w > i.width)
			w = i.width;
		if(w > i.height)
			w = i.height;

		auto srcPtr = i.getDataPointer() + i.offsetForPixel(upperLeftOfImage.x, upperLeftOfImage.y);
		auto srcAdvance = i.adjustmentForNextLine();
		auto srcBpp = i.bytesPerPixel();

		foreach(y; 0 .. h) {
			auto sp = srcPtr;
			auto dp = destPtr;
			foreach(x; 0 .. w) {
				dp[offR] = sp[offR];
				dp[offG] = sp[offG];
				dp[offB] = sp[offB];

				sp += srcBpp;
				dp += bpp;
			}

			srcPtr += srcAdvance;
			destPtr += nextLineAdjustment;
		}
	}

	Color fillColor;
	Color outlineColor;

	RasterOp rasterOp;

	void drawLine(Point from, Point to) {
		if(from.x == to.x)
			drawVerticalLine(from, to.y - from.y);
		else if(from.y == from.y)
			drawHorizontalLine(from, to.x - from.x);
		else assert(0);
	}

	void drawHorizontalLine(in Point p, in int length) {
		if(p.y >= img.height || p.x >= img.width)
			return;
		if(p.y < 0)
			return;
		if(p.x < 0)
			return;

		if(p.x + length > img.width) {
			return;
		}



		auto ptr = getThing(p.x, p.y);
		foreach(i; 0 .. length) {
			if(rasterOp == RasterOp.normal) {
				ptr[offR] = outlineColor.r;
				ptr[offG] = outlineColor.g;
				ptr[offB] = outlineColor.b;
			} else {
				ptr[offR] ^= outlineColor.r;
				ptr[offG] ^= outlineColor.g;
				ptr[offB] ^= outlineColor.b;
			}
			ptr = ptr[bpp .. $];
		}
	}

	void drawVerticalLine(in Point p, in int length) {
		if(p.y >= img.height || p.x >= img.width)
			return;
		if(p.y < 0)
			return;
		if(p.x < 0)
			return;

		if(p.y + length > img.height) {
			return;
		}

		auto ptr = getThing(p.x, p.y);
		foreach(i; 0 .. length) {
			if(rasterOp == RasterOp.normal) {
				ptr[offR] = outlineColor.r;
				ptr[offG] = outlineColor.g;
				ptr[offB] = outlineColor.b;
			} else {
				ptr[offR] ^= outlineColor.r;
				ptr[offG] ^= outlineColor.g;
				ptr[offB] ^= outlineColor.b;
			}
			if(i+1 != length) {
				version(Windows)
					ptr = (ptr.ptr + nextLineAdjustment)[0 .. 100000];
				else
				ptr = ptr[nextLineAdjustment .. $];
			}
		}
	}

	void drawRectangle(Point upperLeft, int width, int height) {
		if(upperLeft.y >= img.height || upperLeft.x >= img.width)
			return;
		if(upperLeft.y < 0)
			upperLeft.y = 0;
		if(upperLeft.x < 0)
			upperLeft.x = 0;

		if(upperLeft.y + height > img.height) {
			height = img.height - upperLeft.y;
		}
		if(upperLeft.x + width > img.width) {
			width = img.width - upperLeft.x;
		}

		if(outlineColor.a) {
			drawHorizontalLine(upperLeft, width);
			drawHorizontalLine(Point(upperLeft.x, upperLeft.y + height - 1), width);
			drawVerticalLine(Point(upperLeft.x, upperLeft.y + 1), height - 2);
			drawVerticalLine(Point(upperLeft.x + width - 1, upperLeft.y + 1), height - 2);
		}

		if(fillColor.a) {
			auto ptr = getThing(upperLeft.x + 1, upperLeft.y + 1);
			foreach(i; 1 .. height - 1) {
				auto iptr = ptr;
				foreach(x; 1 .. width - 1) {
					if(rasterOp == RasterOp.normal) {
						iptr[offR] = fillColor.r;
						iptr[offG] = fillColor.g;
						iptr[offB] = fillColor.b;
					} else {
						iptr[offR] ^= fillColor.r;
						iptr[offG] ^= fillColor.g;
						iptr[offB] ^= fillColor.b;
					}
					iptr = iptr[bpp .. $];
				}
				if(i+1 != height-1) {
					version(Windows)
						ptr = (ptr.ptr + nextLineAdjustment)[0 .. 100000];
					else
						ptr = ptr[nextLineAdjustment .. $];
				}
			}
		}
	}

	static struct GlyphInfo {
		ubyte[] bitmap;
		int w;
		int h;
	}

	void drawText(Point up, string text) {
		// since this is monospace, w and h shouldn't change regardless
		static GlyphInfo[dchar] characters;

		foreach(dchar ch; text) {
			GlyphInfo info;

			if(auto ptr = ch in characters) {
				info = *ptr;
			} else {
				char[4] buffer;
				import std.utf;
				auto slice = buffer[0 .. encode(buffer, ch)];
				info.bitmap = ttfFont.renderString(slice, TerminalEmulatorWindow.fontSize, info.w, info.h);
				characters[ch] = info;
			}

			auto surface = getThing(up.x, up.y);
			auto bmp = info.bitmap;
			for (int j=0; j < info.h; ++j) {
				auto line = surface;
				for (int i=0; i < info.w; ++i) {
					if(line.length == 0)
						return;
					auto a = bmp[0];
					bmp = bmp[1 .. $];

					// alpha blending right here, inline
					auto bgr = line[offR];
					auto bgg = line[offG];
					auto bgb = line[offB];
					line[offR] = cast(ubyte) (outlineColor.r * a / 255 + bgr * (255 - a) / 255);
					line[offG] = cast(ubyte) (outlineColor.g * a / 255 + bgg * (255 - a) / 255);
					line[offB] = cast(ubyte) (outlineColor.b * a / 255 + bgb * (255 - a) / 255);
					/*
					if(a > 128) {
					line[offR] = 0;
					line[offG] = 0;
					line[offB] = 0;
					}
					*/

					line = line[bpp .. $];
				}

				version(Windows)
					{}
				else
					if(nextLineAdjustment >= surface.length)
						break;

				if(j +1 != info.h) {
					version(Windows)
						surface = (surface.ptr + nextLineAdjustment)[0 .. 100000];
					else
						surface = surface[nextLineAdjustment .. $];
				}
			}

			up.x += fontWidth;
		}
	}
}

XImagePainter draw(Image i, TtfFont* ttfFont, int fontWidth) {
	return XImagePainter(i, ttfFont, fontWidth);
}

/**
	Makes a terminal emulator out of a SimpleWindow.
*/
class TerminalEmulatorWindow : TerminalEmulator {

	override void requestExit() {
		EventLoop.get.exit();
	}

	protected override void changeCursorStyle(CursorStyle s) { }

	protected override void changeWindowTitle(string t) {
		if(window && t.length)
			window.title = t;
	}
	protected override void changeWindowIcon(IndexedImage t) {
		if(window && t)
			window.icon = t;
	}
	protected override void changeIconTitle(string) {}
	protected override void changeTextAttributes(TextAttributes) {}
	protected override void soundBell() {
		static if(UsingSimpledisplayX11)
			XBell(XDisplayConnection.get(), 50);
	}

	protected override void demandAttention() {
		window.requestAttention();
	}

	protected override void copyToPrimary(string text) {
		// on Windows, there is no separate PRIMARY thing,
		// so just using the normal system clipboard.
		//
		// this is usually what I personally want anyway.
		static if(UsingSimpledisplayX11)
			setPrimarySelection(window, text);
		else
			setClipboardText(window, text);
	}

	protected override void pasteFromPrimary(void delegate(in char[]) dg) {
		static if(UsingSimpledisplayX11)
			getPrimarySelection(window, dg);
		else
			getClipboardText(window, (in char[] dataIn) {
				char[] data;
				// change Windows \r\n to plain \n
				foreach(char ch; dataIn)
					if(ch != 13)
						data ~= ch;
				dg(data);
			});
	}

	protected override void copyToClipboard(string text) {
		setClipboardText(window, text);
	}

	protected override void pasteFromClipboard(void delegate(in char[]) dg) {
		getClipboardText(window, (in char[] dataIn) {
			char[] data;
			// change Windows \r\n to plain \n
			foreach(char ch; dataIn)
				if(ch != 13)
					data ~= ch;
			dg(data);
		});
	}

	void resizeImage() {
		if(usingTtf)
			img = new Image(window.width, window.height);
	}
	mixin PtySupport!(resizeImage);

	import arsd.simpledisplay;

	TtfFont ttfFont;

	bool debugMode;


	bool usingTtf;

	DebugWindow debugWindow;

	version(use_libssh2)
	this(LIBSSH2_CHANNEL* sshChannel, int fontSize = 0) {
		this.sshChannel = sshChannel;
		this(fontSize);
	}
	else version(Posix)
	this(int masterfd, int fontSize = 0) {
		master = masterfd;
		this(fontSize);
	}
	else version(Windows) {
		version(winpty)
			this(HPCON hpc, HANDLE stdin, HANDLE stdout, int fontSize = 0) {
				this.hpc = hpc;
				this.stdin = stdin;
				this.stdout = stdout;
				this(fontSize);
			}
		else
			this(HANDLE stdin, HANDLE stdout, int fontSize = 0) {
				this.stdin = stdin;
				this.stdout = stdout;
				this(fontSize);
			}
	}

	version(winpty)
		HPCON hpc;

	bool focused;

	/+
		FIXME:
			osc 1337 base64 image rom term2 lol.

			image support in attach.

			key the keyboard input controls more DRY
	+/

	override void requestRedraw() {
		redraw();
	}

	this(int fontSize = 0) {
		if(fontSize) {
			//this.usingTtf = true;
			//this.fontSize = fontSize;
		} else version(Windows) {
			if(GetSystemMetrics(SM_CYSCREEN) > 1024)
				this.fontSize = 16;
		}

		if(usingTtf) {
			assert(0, " no longer implemented ");
			//ttfFont = TtfFont(cast(ubyte[]) import("monospace-2.ttf"));
			// ttfFont.getStringSize("M", fontSize, fontWidth, fontHeight);
		} else {
			if(fontSize) {
				version(Windows) {
					this.font = new OperatingSystemFont("Consolas", fontSize);
					if(this.font.isNull)
						this.font = new OperatingSystemFont("Courier New", fontSize);
				} else
					this.font = new OperatingSystemFont("Deja Vu Sans Mono", fontSize);
				if(this.font.isNull || !this.font.isMonospace) {
					loadDefaultFont();
				} else {
					fontWidth = font.averageWidth;
					fontHeight = font.height;
				}
			} else
				loadDefaultFont();
		}

		auto desiredWidth = 80;
		auto desiredHeight = 24;

		window = new SimpleWindow(
			fontWidth * desiredWidth + paddingLeft * 2,
			fontHeight * desiredHeight + paddingTop * 2,
			"Terminal Emulator",
			OpenGlOptions.no,
			Resizability.allowResizing,
			WindowTypes.normal,
			WindowFlags.alwaysRequestMouseMotionEvents);

		static if(UsingSimpledisplayX11) {
			auto display = XDisplayConnection.get();
			XDefineCursor(display, window.impl.window, XCreateFontCursor(display, 152 /* XC_xterm */));
		}

		window.windowResized = (int w, int h) {
			this.resizeTerminal(w / fontWidth, h / fontHeight);
			clearScreenRequested = true;
			redraw();
		};

		window.onFocusChange = (bool got) {
			focused = got;
			attentionReceived();
		};

		super(desiredWidth, desiredHeight);

		window.setEventHandlers(
		delegate(MouseEvent ev) {
			int termX = (ev.x - paddingLeft) / fontWidth;
			int termY = (ev.y - paddingTop) / fontHeight;
			// FIXME: make sure termx and termy are in bounds

			arsd.terminalemulator.MouseButton modiferStateToMouseButton() {
				// crappy terminal can only report one button at a time anyway,
				// so doing this in order of precedence 
				if(ev.modifierState & ModifierState.leftButtonDown)
					return arsd.terminalemulator.MouseButton.left;
				if(ev.modifierState & ModifierState.rightButtonDown)
					return arsd.terminalemulator.MouseButton.right;
				if(ev.modifierState & ModifierState.middleButtonDown)
					return arsd.terminalemulator.MouseButton.middle;
				return cast(arsd.terminalemulator.MouseButton) 0;
			}

			if(sendMouseInputToApplication(termX, termY,
				cast(arsd.terminalemulator.MouseEventType) ev.type,
				ev.type == MouseEventType.motion ? modiferStateToMouseButton : cast(arsd.terminalemulator.MouseButton) ev.button,
				(ev.modifierState & ModifierState.shift) ? true : false,
				(ev.modifierState & ModifierState.ctrl) ? true : false,
				(ev.modifierState & ModifierState.alt) ? true : false
			))
				redraw();
		},
		delegate(KeyEvent ev) {
			if(ev.pressed == false)
				return;

			// debug stuff
			if((ev.modifierState & ModifierState.ctrl) && (ev.modifierState & ModifierState.shift) && ev.key == Key.F12) {
				if(debugWindow is null)
					debugWindow = new DebugWindow(window, this);
				debugWindow.show();
				return;
			}

			version(none)
			if(ev.key == Key.F11) {
				import std.datetime;
				auto r = benchmark!({
					//this.cls();
					this.redraw(ev.modifierState & ModifierState.shift ? true : false);
				})(ev.modifierState & ModifierState.shift ? 2 : 200);
				import std.conv;
				addOutput(to!string(r[0].msecs) ~ "\n");
				return;
			}

			// end debug stuff

			static if(UsingSimpledisplayX11)
				if(ev.modifierState & ModifierState.windows) {
					if(ev.key in superMappings) {
						sendToApplication(superMappings[ev.key]);
						//skipNextChar = true;
						return;
					}
			}

			defaultKeyHandler!Key(
				ev.key,
				(ev.modifierState & ModifierState.shift)?true:false,
				(ev.modifierState & ModifierState.alt)?true:false,
				(ev.modifierState & ModifierState.ctrl)?true:false,
				(ev.modifierState & ModifierState.windows)?true:false
			);

			return; // the character event handler will do others
		},
		(dchar c) {
			defaultCharHandler(c);
		});

		version(use_libssh2) {

		} else
		version(Posix) {
			makeNonBlocking(master);
			auto listener = new PosixFdReader(&readyToRead, master);
			listener.onHup = () { EventLoop.get.exit(); };
			// no edge triggering, that has a nasty habit of locking us up
			/+
			addListener(delegate void(FileHup hup) {
				import core.sys.posix.unistd;
				close(hup.fd);
			});
			+/
		} else 
		version(winpty) {
			auto whr = new WindowsHandleReader(&readyToReadPty, inputEvent);
		} else
		version(Windows) {
			overlapped = new OVERLAPPED();
			overlapped.hEvent = cast(void*) this;

			//window.handleNativeEvent = &windowsRead;
			readyToReadWindows(0, 0, overlapped);
			redraw();
		}

		flushGui();

		/*
		bool odd;
		setInterval( {
			odd = !odd;
			auto painter = window.draw();
			painter.fillColor =odd ? Color.blue : Color.green;
			painter.drawRectangle(Point(0, 0), 200, 200);
		}, 1000);
		setTimeout(&window.close, 10000);
		*/
	}

	SimpleWindow window;

	static int fontSize = 14;

	Image img;

	bool clearScreenRequested = true;
	void redraw(bool forceRedraw = false) {
		auto painter = window.draw();
		if(clearScreenRequested) {
			version(with_24_bit_color)
				auto clearColor = defaultTextAttributes.background;
			else
				auto clearColor = defaultBackground;
			painter.outlineColor = clearColor;
			painter.fillColor = clearColor;
			painter.drawRectangle(Point(0, 0), window.width, window.height);
			clearScreenRequested = false;
			forceRedraw = true;
		}

		if(usingTtf) {
			auto invalidated = redrawPainter(img.draw(&ttfFont, fontWidth), forceRedraw);
			if(invalidated.right || invalidated.bottom)
			painter.drawImage(Point(0, 0), img, Point(invalidated.left, invalidated.top), invalidated.right, invalidated.bottom);
		} else
			redrawPainter(painter, forceRedraw);
	}

	mixin SdpyDraw;
}


/+
	use this code in the forkpty child to just forward stuff

			termios old;
                        tcgetattr(0, &old);
                        auto n = old;

                        auto f = ICANON;
                        f |= ECHO;

			n.c_lflag &= ~f;
                        tcsetattr(0, TCSANOW, &n);
			for(;;)
			if(fgetc(stdin) == 'f'){
				printf("bye\n");
				break;
			}



	and the parent of forkpty

		/*
			// for running inside a terminal emulator, we want
			// echo to be turned off since the pty echos for us
			termios old;
                        tcgetattr(0, &old);
                        auto n = old;

                        auto f = ICANON;
                        f |= ECHO;

                        n.c_lflag &= ~f;
                        tcsetattr(0, TCSANOW, &n);

			scope(exit)
				tcsetattr(0, TCSANOW, &old);
		*/



+/

		/+
		// for testing in a terminal emulator
		string line;
		FILE* log;
		log = fopen("log.bin", "wb");
		scope(exit) fclose(log);

		for(;;) {
				byte[1024] data;
				int shit = ishit(master);
				if(shit&2) {
					// read data from the fake terminal
					int len = read(master, data.ptr, 1024);
					if(len < 0)
						throw new Exception("fuck me");
					for(int w = 0; w < len; w++) {
						fputc(data[w], stdout);
						fputc(data[w],log);
					}

					fflush(stdout);
				}
				if(shit&1){
					// forward data from stdin to the fake terminal
					int count = read(0, data.ptr, 1024);//readln();
					char[] wtf;
					wtf.length = count;
					wtf[0..count] = cast(char[]) data[0..count];
					line ~= wtf;
					if(line == "FUCK\n"){ printf("bye asshole\n"); return 0;}
					if(line[count-1] == '\n')
						line = "";

					write(master, data.ptr, count);
				}

		//		wait(0);
		}
		+/


