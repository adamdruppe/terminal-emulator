// FIXME: on Windows 8, the size event doesn't fire when you maximize the window

// FIXME: use_libssh2 should do keepalive.

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

struct SRectangle {
	int left;
	int top;
	int right;
	int bottom;
}

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
			term.window.handleNativeEvent = delegate int(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam) {
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

	version(winpty) {

	} else {
		if(args.length < 2) {
			import std.stdio;
			writeln("Give a font size and command line to run like: 0 plink.exe user@server.com -i keyfile /opt/serverside");
			return;
		}
	}

	import std.string;
	startChild!startup(null, args[2..$].join(" "));
}
else version(Posix)
void main(string[] args) {
	void startup(int master) {
		import std.conv;
		auto term = new TerminalEmulatorWindow(master, (args.length > 1) ? to!int(args[1]) : 0);
		term.window.eventLoop(0);
		// 
	}

	try {
		import std.process;
		auto cmd = environment.get("SHELL", "/bin/bash");
		startChild!startup(args.length > 2 ? args[2] : cmd, args.length > 2 ? args[2 .. $] : [cmd]);
	} catch(Throwable t) {
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
	TtfFont* font;
	int fontWidth;

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

	this(Image i, TtfFont* font, int fontWidth) {
		this.img = i;
		this.font = font;
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
				info.bitmap = font.renderString(slice, TerminalEmulatorWindow.fontSize, info.w, info.h);
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

XImagePainter draw(Image i, TtfFont* font, int fontWidth) {
	return XImagePainter(i, font, fontWidth);
}

class NonCharacterData_Image : NonCharacterData {
	Image data;
	int imageOffsetX;
	int imageOffsetY;

	this(Image data, int x, int y) {
		this.data = data;
		this.imageOffsetX = x;
		this.imageOffsetY = y;
	}
}

/**
	Makes a terminal emulator out of a SimpleWindow.
*/
class TerminalEmulatorWindow : TerminalEmulator {

	override void requestExit() {
		EventLoop.get.exit();
	}


	protected override BrokenUpImage handleBinaryExtensionData(const(ubyte)[] binaryData) {
		TrueColorImage mi;

		if(binaryData.length > 8 && binaryData[1] == 'P' && binaryData[2] == 'N' && binaryData[3] == 'G') {
			import arsd.png;
			mi = imageFromPng(readPng(binaryData)).getAsTrueColorImage();
		} else if(binaryData.length > 8 && binaryData[0] == 'B' && binaryData[1] == 'M') {
			import arsd.bmp;
			mi = readBmp(binaryData).getAsTrueColorImage();
		} else {
			return BrokenUpImage();
		}

		BrokenUpImage bi;
		bi.width = mi.width / fontWidth + ((mi.width%fontWidth) ? 1 : 0);
		bi.height = mi.height / fontHeight + ((mi.height%fontHeight) ? 1 : 0);

		bi.representation.length = bi.width * bi.height;

		Image data = Image.fromMemoryImage(mi);

		int ix, iy;
		foreach(ref cell; bi.representation) {
			/*
			Image data = new Image(fontWidth, fontHeight);
			foreach(y; 0 .. fontHeight) {
				foreach(x; 0 .. fontWidth) {
					if(x + ix >= mi.width || y + iy >= mi.height) {
						data.putPixel(x, y, defaultTextAttributes.background);
						continue;
					}
					data.putPixel(x, y, mi.imageData.colors[(iy + y) * mi.width + (ix + x)]);
				}
			}
			*/

			cell.nonCharacterData = new NonCharacterData_Image(data, ix, iy);

			ix += fontWidth;

			if(ix >= mi.width) {
				ix = 0;
				iy += fontHeight;
			}

		}

		return bi;
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

	TtfFont font;

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

	version(Windows)
	HFONT hFont;

	version(winpty)
		HPCON hpc;

	bool focused;

	this(int fontSize = 0) {
		if(fontSize) {
			this.usingTtf = true;
			this.fontSize = fontSize;
		} else version(Windows) {
			if(GetSystemMetrics(SM_CYSCREEN) > 1024)
				this.fontSize = 16;
		}

		if(usingTtf) {
			font = TtfFont(cast(ubyte[]) import("monospace-2.ttf"));
			font.getStringSize("M", fontSize, fontWidth, fontHeight);
		} else {
			static if(UsingSimpledisplayX11) {
				auto font = new OperatingSystemFont("fixed", 14, FontWeight.medium);
				if(font.isNull) {
					// didn't work, it is using a
					// fallback, prolly fixed-13 is best
					xfontstr = "-*-fixed-medium-r-*-*-13-*-*-*-*-*-*-*";
					fontWidth = 6;
					fontHeight = 13;
				} else {
					xfontstr = "-*-fixed-medium-r-*-*-14-*-*-*-*-*-*-*";
					fontWidth = 7;
					fontHeight = 14;
				}
			} else version(Windows) {
				hFont = CreateFontA(this.fontSize, 0, 0, 0, 0, false, 0, 0, 0, 0, 0, 0, 0, "Courier New");
				fontHeight = this.fontSize;
				fontWidth = fontHeight / 2;
			}
		}

		auto desiredWidth = 80;
		auto desiredHeight = 24;

		window = new SimpleWindow(
			fontWidth * desiredWidth + paddingLeft * 2,
			fontHeight * desiredHeight + paddingTop * 2,
			"Terminal Emulator",
			OpenGlOptions.no,
			Resizability.allowResizing);

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

		bool skipNextChar = false;

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


			// special keys

			string magic() {
				string code;
				foreach(member; __traits(allMembers, TerminalKey))
					if(member != "Escape")
						code ~= "case Key." ~ member ~ ": if(sendKeyToApplication(TerminalKey." ~ member ~ "
							, (ev.modifierState & ModifierState.shift)?true:false
							, (ev.modifierState & ModifierState.alt)?true:false
							, (ev.modifierState & ModifierState.ctrl)?true:false
							, (ev.modifierState & ModifierState.windows)?true:false
						)) redraw(); break;";
				return code;
			}


			switch(ev.key) {
				//// I want the escape key to send twice to differentiate it from
				//// other escape sequences easily.
				//case Key.Escape: sendToApplication("\033"); break;

				case Key.V:
				case Key.C:
					if((ev.modifierState & ModifierState.shift) && (ev.modifierState & ModifierState.ctrl)) {
						skipNextChar = true;
						if(ev.key == Key.V)
							pasteFromClipboard(&sendPasteData);
						else if(ev.key == Key.C)
							copyToClipboard(getSelectedText());
						/+
						if(sendKeyToApplication(
							TerminalKey.Insert,
							ev.key == Key.V, // shift+insert pastes...
							false,
							ev.key == Key.C, // ctrl+insert copies...
							false
						)) redraw();
						+/
					}
				break;

				// expansion of my own for like shift+enter to terminal.d users
				case Key.Enter:
				case Key.Backspace:
				case Key.Tab:
					if(ev.modifierState & (ModifierState.shift | ModifierState.alt | ModifierState.ctrl)) {
						skipNextChar = true;
						if(sendKeyToApplication(
							cast(TerminalKey) (
								ev.key == Key.Enter ? '\n' :
								ev.key == Key.Tab ? '\t' :
								ev.key == Key.Backspace ? '\b' :
									0 /* assert(0) */
							)
							, (ev.modifierState & ModifierState.shift)?true:false
							, (ev.modifierState & ModifierState.alt)?true:false
							, (ev.modifierState & ModifierState.ctrl)?true:false
							, (ev.modifierState & ModifierState.windows)?true:false
						)) redraw();
					}
				break;

				mixin(magic());

				default:
					// keep going, not special
			}

			// remapping of alt+key is possible too, at least on linux.
			static if(UsingSimpledisplayX11) {
				if(ev.modifierState & ModifierState.alt) {
					//import std.stdio;
					if(ev.key in altMappings) {
						sendToApplication(altMappings[ev.key]);
						//skipNextChar = true;
					}
					else {
						char[4] str;
						import std.utf;
						auto data = str[0 .. encode(str, cast(dchar) ev.key)];
						char[5] f;
						f[0] = '\033';
						f[1 .. 1 + data.length] = data[];
						sendToApplication(f[0 .. 1 + data.length]);
					}
				}
			}

			static if(UsingSimpledisplayX11)
				if(ev.modifierState & ModifierState.windows) {
					if(ev.key in superMappings) {
						sendToApplication(superMappings[ev.key]);
						//skipNextChar = true;
					}
			}

			return; // the character event handler will do others
		},
		(dchar c) {
			if(skipNextChar) {
				skipNextChar = false;
				return;
			}

			endScrollback();
			char[4] str;
			import std.utf;
			if(c == '\n') c = '\r'; // terminal seem to expect enter to send 13 instead of 10
			auto data = str[0 .. encode(str, c)];

			// on X11, the delete key can send a 127 character too, but that shouldn't be sent to the terminal since xterm shoots \033[3~ instead, which we handle in the KeyEvent handler.
			if(c != 127)
				sendToApplication(data);
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

	int fontWidth;
	int fontHeight;

	static int fontSize = 14;

	enum paddingLeft = 2;
	enum paddingTop = 1;

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
			auto invalidated = redrawPainter(img.draw(&font, fontWidth), forceRedraw);
			if(invalidated.right || invalidated.bottom)
			painter.drawImage(Point(0, 0), img, Point(invalidated.left, invalidated.top), invalidated.right, invalidated.bottom);
		} else
			redrawPainter(painter, forceRedraw);
	}

	bool lastDrawAlternativeScreen;
	final SRectangle redrawPainter(T)(T painter, bool forceRedraw) {
		SRectangle invalidated;

		// FIXME: anything we can do to make this faster is good
		// on both, the XImagePainter could use optimizations
		// on both, drawing blocks would probably be good too - not just one cell at a time, find whole blocks of stuff
		// on both it might also be good to keep scroll commands high level somehow. idk.

		// FIXME on Windows it would definitely help a lot to do just one ExtTextOutW per line, if possible. the current code is brutally slow

		// Or also see https://docs.microsoft.com/en-us/windows/desktop/api/wingdi/nf-wingdi-polytextoutw

		version(Windows)
		static if(is(T == ScreenPainter)) {
			SelectObject(painter.impl.hdc, hFont);
		}


		int posx = paddingLeft;
		int posy = paddingTop;


		char[512] bufferText;
		bool hasBufferedInfo;
		int bufferTextLength;
		Color bufferForeground;
		Color bufferBackground;
		int bufferX = -1;
		int bufferY = -1;
		bool bufferReverse;
		void flushBuffer() {
			if(!hasBufferedInfo) {
				return;
			}

			assert(posx - bufferX - 1 > 0);

			painter.fillColor = bufferReverse ? bufferForeground : bufferBackground;
			painter.outlineColor = bufferReverse ? bufferForeground : bufferBackground;

			painter.drawRectangle(Point(bufferX, bufferY), posx - bufferX, fontHeight);
			painter.fillColor = Color.transparent;
			// Hack for contrast!
			if(bufferBackground == Color.black && !bufferReverse) {
				// brighter than normal in some cases so i can read it easily
				painter.outlineColor = contrastify(bufferForeground);
			} else if(bufferBackground == Color.white && !bufferReverse) {
				// darker than normal so i can read it
				painter.outlineColor = antiContrastify(bufferForeground);
			} else if(bufferForeground == bufferBackground) {
				// color on itself, I want it visible too
				auto hsl = toHsl(bufferForeground, true);
				if(hsl[2] < 0.5)
					hsl[2] += 0.5;
				else
					hsl[2] -= 0.5;
				painter.outlineColor = fromHsl(hsl[0], hsl[1], hsl[2]);

			} else {
				// normal
				painter.outlineColor = bufferReverse ? bufferBackground : bufferForeground;
			}

			// FIXME: make sure this clips correctly
			painter.drawText(Point(bufferX, bufferY), cast(immutable) bufferText[0 .. bufferTextLength]);

			hasBufferedInfo = false;

			bufferReverse = false;
			bufferTextLength = 0;
			bufferX = -1;
			bufferY = -1;
		}



		int x;
		foreach(idx, ref cell; alternateScreenActive ? alternateScreen : normalScreen) {
			if(!forceRedraw && !cell.invalidated && lastDrawAlternativeScreen == alternateScreenActive) {
				flushBuffer();
				goto skipDrawing;
			}
			cell.invalidated = false;
			version(none) if(bufferX == -1) { // why was this ever here?
				bufferX = posx;
				bufferY = posy;
			}

			if(!cell.hasNonCharacterData) {

				invalidated.left = posx < invalidated.left ? posx : invalidated.left;
				invalidated.top = posy < invalidated.top ? posy : invalidated.top;
				int xmax = posx + fontWidth;
				int ymax = posy + fontHeight;
				invalidated.right = xmax > invalidated.right ? xmax : invalidated.right;
				invalidated.bottom = ymax > invalidated.bottom ? ymax : invalidated.bottom;

				// FIXME: this could be more efficient, simpledisplay could get better graphics context handling
				{

					bool reverse = (cell.attributes.inverse != reverseVideo);
					if(cell.selected)
						reverse = !reverse;

					version(with_24_bit_color) {
						auto fgc = cell.attributes.foreground;
						auto bgc = cell.attributes.background;

						if(!(cell.attributes.foregroundIndex & 0xff00)) {
							// this refers to a specific palette entry, which may change, so we should use that
							fgc = palette[cell.attributes.foregroundIndex];
						}
						if(!(cell.attributes.backgroundIndex & 0xff00)) {
							// this refers to a specific palette entry, which may change, so we should use that
							bgc = palette[cell.attributes.backgroundIndex];
						}

					} else {
						auto fgc = cell.attributes.foregroundIndex == 256 ? defaultForeground : palette[cell.attributes.foregroundIndex & 0xff];
						auto bgc = cell.attributes.backgroundIndex == 256 ? defaultBackground : palette[cell.attributes.backgroundIndex & 0xff];
					}

					if(fgc != bufferForeground || bgc != bufferBackground || reverse != bufferReverse)
						flushBuffer();
					bufferReverse = reverse;
					bufferBackground = bgc;
					bufferForeground = fgc;
				}
			}

				if(!cell.hasNonCharacterData) {
					char[4] str;
					import std.utf;
					// now that it is buffered, we do want to draw it this way...
					//if(cell.ch != ' ') { // no point wasting time drawing spaces, which are nothing; the bg rectangle already did the important thing
						try {
							auto stride = encode(str, cell.ch);
							if(bufferTextLength + stride > bufferText.length)
								flushBuffer();
							bufferText[bufferTextLength .. bufferTextLength + stride] = str[0 .. stride];
							bufferTextLength += stride;

							if(bufferX == -1) {
								bufferX = posx;
								bufferY = posy;
							}
							hasBufferedInfo = true;
						} catch(Exception e) {
							import std.stdio;
							writeln(cast(uint) cell.ch, " :: ", e.msg);
						}
					//}
				} else if(cell.nonCharacterData !is null) {
					//import std.stdio; writeln(cast(void*) cell.nonCharacterData);
					if(auto ncdi = cast(NonCharacterData_Image) cell.nonCharacterData) {
						flushBuffer();
						painter.outlineColor = Color.black;
						painter.fillColor = Color.black;
						painter.drawRectangle(Point(posx, posy), fontWidth, fontHeight);
						painter.drawImage(Point(posx, posy), ncdi.data, Point(ncdi.imageOffsetX, ncdi.imageOffsetY), fontWidth, fontHeight);
					}
				}

				if(!cell.hasNonCharacterData)
				if(cell.attributes.underlined) {
					// the posx adjustment is because the buffer assumes it is going
					// to be flushed after advancing, but here, we're doing it mid-character
					// FIXME: we should just underline the whole thing consecutively, with the buffer
					posx += fontWidth;
					flushBuffer();
					posx -= fontWidth;
					painter.drawLine(Point(posx, posy + fontHeight - 1), Point(posx + fontWidth, posy + fontHeight - 1));
				}
			skipDrawing:

				posx += fontWidth;
			x++;
			if(x == screenWidth) {
				flushBuffer();
				x = 0;
				posy += fontHeight;
				posx = paddingLeft;
			}
		}

		if(cursorShowing) {
			painter.fillColor = cursorColor;
			painter.outlineColor = cursorColor;
			painter.rasterOp = RasterOp.xor;

			posx = cursorPosition.x * fontWidth + paddingLeft;
			posy = cursorPosition.y * fontHeight + paddingTop;

			int cursorWidth = fontWidth;
			int cursorHeight = fontHeight;

			final switch(cursorStyle) {
				case CursorStyle.block:
					painter.drawRectangle(Point(posx, posy), cursorWidth, cursorHeight);
				break;
				case CursorStyle.underline:
					painter.drawRectangle(Point(posx, posy + cursorHeight - 2), cursorWidth, 2);
				break;
				case CursorStyle.bar:
					painter.drawRectangle(Point(posx, posy), 2, cursorHeight);
				break;
			}
			painter.rasterOp = RasterOp.normal;

			// since the cursor draws over the cell, we need to make sure it is redrawn each time too
			auto buffer = alternateScreenActive ? (&alternateScreen) : (&normalScreen);
			if(cursorX >= 0 && cursorY >= 0 && cursorY < screenHeight && cursorX < screenWidth) {
				(*buffer)[cursorY * screenWidth + cursorX].invalidated = true;
			}

			invalidated.left = posx < invalidated.left ? posx : invalidated.left;
			invalidated.top = posy < invalidated.top ? posy : invalidated.top;
			int xmax = posx + fontWidth;
			int ymax = xmax + fontHeight;
			invalidated.right = xmax > invalidated.right ? xmax : invalidated.right;
			invalidated.bottom = ymax > invalidated.bottom ? ymax : invalidated.bottom;
		}

		lastDrawAlternativeScreen = alternateScreenActive;

		return invalidated;
	}

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


// black bg, make the colors more visible
Color contrastify(Color c) {
	if(c == Color(0xcd, 0, 0))
		return Color.fromHsl(0, 1.0, 0.75);
	else if(c == Color(0, 0, 0xcd))
		return Color.fromHsl(240, 1.0, 0.75);
	else if(c == Color(229, 229, 229))
		return Color(0x99, 0x99, 0x99);
	else if(c == Color.black)
		return Color(128, 128, 128);
	else return c;
}

// white bg, make them more visible
Color antiContrastify(Color c) {
	if(c == Color(0xcd, 0xcd, 0))
		return Color.fromHsl(60, 1.0, 0.25);
	else if(c == Color(0, 0xcd, 0xcd))
		return Color.fromHsl(180, 1.0, 0.25);
	else if(c == Color(229, 229, 229))
		return Color(0x99, 0x99, 0x99);
	else if(c == Color.white)
		return Color(128, 128, 128);
	else return c;
}
