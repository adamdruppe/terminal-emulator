/**
	This is the graphical application for the terminal emulator.

	Linux compile:
	dmd main.d terminalemulator.d arsd/simpledisplay.d arsd/color.d arsd/eventloop.d -version=with_eventloop -debug arsd/png.d arsd/bmp.d arsd/stb_truetype.d -Jfont

	Windows compile:
	dmd main.d arsd\simpledisplay.d arsd\color.d -debug arsd\stb_truetype.d terminalemulator.d -Jfont arsd\png.d arsd\bmp.d


	The windows version expects serverside.d to be running on the other side and needs plink.exe available to speak ssh.
*/

// FIXME: blue text under the cursor is virtually impossible to see.

// You can edit this if you like to make the alt+keys do other stuff.
enum string[dchar] altMappings = [
	'a' : "Cool!",
	'A' : "Boss",

	'\'' : "\&ldquo;",
	'\"' : "\&rdquo;",
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

import arsd.color;

struct SRectangle {
	int left;
	int top;
	int right;
	int bottom;
}
version(Windows)
void main(string[] args) {
	import core.sys.windows.windows;
	void startup(HANDLE inwritePipe, HANDLE outreadPipe) {
		import std.conv;
		auto term = new TerminalEmulatorWindow(inwritePipe, outreadPipe, (args.length > 1) ? to!int(args[1]) : 0);

		term.window.eventLoop(10);
	}

	if(args.length < 2) {
		import std.stdio;
		writeln("Give a command line to run like: plink.exe user@server.com -i keyfile /opt/serverside");
		return;
	}

	import std.string;
	startChild!startup(null, args[2..$].join(" "));
}
else version(Posix)
void main(string[] args) {
	void startup(int master) {
		import std.conv;
		auto term = new TerminalEmulatorWindow(master, (args.length > 1) ? to!int(args[1]) : 0);
		import arsd.eventloop;
		loop();
		// 
	}

	try {
		import std.process;
		auto cmd = environment.get("SHELL", "/bin/bash");
		startChild!startup(args.length > 2 ? args[2] : cmd, args.length > 2 ? args[2 .. $] : [cmd]);
	} catch(Throwable t) {
		// we might not be run from a tty to print the message, so pop it up some other way.
		// I'm lazy so i'll just call xmessage. good enough to pop it up in the gui environment
		import std.process;
		auto pipes = pipeShell("xmessage -file -");
		pipes.stdin.write(t.toString());
		pipes.stdin.close();
	}
}

import simpledisplay;

static if(UsingSimpledisplayX11)
	import arsd.xwindows;

import stb_truetype;
struct XImagePainter {
	Image img;
	TtfFont* font;

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

	this(Image i, TtfFont* font) {
		this.img = i;
		this.font = font;

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

		auto srcPtr = i.getDataPointer() + i.offsetForTopLeftPixel();
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
			ptr[offR] = outlineColor.r;
			ptr[offG] = outlineColor.g;
			ptr[offB] = outlineColor.b;
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
			ptr[offR] = outlineColor.r;
			ptr[offG] = outlineColor.g;
			ptr[offB] = outlineColor.b;
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
			drawHorizontalLine(Point(upperLeft.x, upperLeft.y + height), width);
			drawVerticalLine(Point(upperLeft.x, upperLeft.y), height);
			drawVerticalLine(Point(upperLeft.x + width, upperLeft.y), height);
		}

		if(upperLeft.x + width < img.width && upperLeft.y + height < img.height) {
			auto fuck = getThing(upperLeft.x + width, upperLeft.y + height);
			fuck[offR] = fillColor.r;
			fuck[offG] = fillColor.g;
			fuck[offB] = fillColor.b;
		}

		if(fillColor.a) {
			auto ptr = getThing(upperLeft.x, upperLeft.y);
			foreach(i; 0 .. height) {
				auto iptr = ptr;
				foreach(x; 0 .. width) {
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
				if(i+1 != height) {
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

		GlyphInfo info;

		dchar ch;
		foreach(dchar c; text) {
			ch = c;
			break;
		}

		if(auto ptr = ch in characters) {
			info = *ptr;
		} else {
			info.bitmap = font.renderString(text, TerminalEmulatorWindow.fontSize, info.w, info.h);
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
	}
}

XImagePainter draw(Image i, TtfFont* font) {
	return XImagePainter(i, font);
}

class NonCharacterData_Image : NonCharacterData {
	Image data;

	this(Image data) {
		this.data = data;
	}
}

/**
	Makes a terminal emulator out of a SimpleWindow.
*/
class TerminalEmulatorWindow : TerminalEmulator {
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

		int ix, iy;
		foreach(ref cell; bi.representation) {
			cell.ch = dchar.init;

			Image data = new Image(fontWidth, fontHeight);
			foreach(y; 0 .. fontHeight) {
				if(y + iy >= mi.height)
					break;
				foreach(x; 0 .. fontWidth) {
					if(x + ix >= mi.width) {
						break;
					}
					data.putPixel(x, y, mi.imageData.colors[(iy + y) * mi.width + (ix + x)]);
				}
				// FIXME: fill it with a transparent pixel or at least the background color
				// if there's space left off the side due to not quite fitting in a perfect text cell
			}

			ix += fontWidth;

			if(ix >= mi.width) {
				ix = 0;
				iy += fontHeight;
			}

			cell.nonCharacterData = new NonCharacterData_Image(data);
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
		if(!focused) {
			static if(UsingSimpledisplayX11)
				arsd.xwindows.demandAttention(window, true);
		}
	}

	protected override void copyToClipboard(string text) {
		static if(UsingSimpledisplayX11)
			setPrimarySelection(window, text);
		else
			setClipboardText(window, text);
	}

	protected override void pasteFromClipboard(void delegate(in char[]) dg) {
		static if(UsingSimpledisplayX11)
			getPrimarySelection(window, dg);
		else
			getClipboardText(window, dg);
	}

	void resizeImage() {
		if(usingTtf)
			img = new Image(window.width, window.height);
	}
	mixin PtySupport!(resizeImage);

	import simpledisplay;
	version(Posix)
	import arsd.eventloop;

	TtfFont font;

	bool debugMode;


	bool usingTtf;

	version(Posix)
	this(int masterfd, int fontSize = 0) {
		master = masterfd;
		this(fontSize);
	}

	version(Windows)
	this(HANDLE stdin, HANDLE stdout, int fontSize = 0) {
		this.stdin = stdin;
		this.stdout = stdout;
		this(fontSize);
	}

	version(Windows)
	HFONT hFont;

	bool focused;

	this(int fontSize = 0) {
		if(fontSize) {
			this.usingTtf = true;
			this.fontSize = fontSize;
		}

		if(usingTtf) {
			font = TtfFont(cast(ubyte[]) import("monospace-2.ttf"));
			font.getStringSize("M", fontSize, fontWidth, fontHeight);
		} else {
			static if(UsingSimpledisplayX11) {
				xfontstr = "-*-fixed-medium-r-*-*-14-*-*-*-*-*-*-*";
				fontWidth = 7;
				fontHeight = 14;
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
			Resizablity.allowResizing);

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
			static if(UsingSimpledisplayX11)
				arsd.xwindows.demandAttention(window, false);
		};

		super(desiredWidth, desiredHeight);

		bool skipNextChar = false;

		window.setEventHandlers(
		delegate(MouseEvent ev) {
			int termX = (ev.x - paddingLeft) / fontWidth;
			int termY = (ev.y - paddingTop) / fontHeight;
			// FIXME: make sure termx and termy are in bounds

			if(sendMouseInputToApplication(termX, termY,
				cast(arsd.terminalemulator.MouseEventType) ev.type,
				cast(arsd.terminalemulator.MouseButton) ev.button,
				(ev.modifierState & ModifierState.shift) ? true : false,
				(ev.modifierState & ModifierState.ctrl) ? true : false
			))
				redraw();
		},
		delegate(KeyEvent ev) {
			if(ev.pressed == false)
				return;

			// debug stuff
			if((ev.modifierState & ModifierState.ctrl) && (ev.modifierState & ModifierState.shift) && ev.key == Key.F12) {
				debugMode = !debugMode;
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

				mixin(magic());

				default:
					// keep going, not special
			}

			// remapping of alt+key is possible too, at least on linux.
			static if(UsingSimpledisplayX11)
			if(ev.modifierState & ModifierState.alt) {
				if(ev.character in altMappings) {
					sendToApplication(altMappings[ev.character]);
					skipNextChar = true;
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

		version(Posix)
		addFileEventListeners(master, &readyToRead, null, null);

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
			auto clearColor = defaultTextAttributes.background;
			painter.outlineColor = clearColor;
			painter.fillColor = clearColor;
			painter.drawRectangle(Point(0, 0), window.width, window.height);
			clearScreenRequested = false;
		}

		if(usingTtf) {
			auto invalidated = redrawPainter(img.draw(&font), forceRedraw);
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

		version(Windows)
		static if(is(T == ScreenPainter)) {
			SelectObject(painter.impl.hdc, hFont);
		}

		int posx = paddingLeft;
		int posy = paddingTop;
		int x;
		foreach(idx, ref cell; alternateScreenActive ? alternateScreen : normalScreen) {
			if(!forceRedraw && !cell.invalidated && lastDrawAlternativeScreen == alternateScreenActive) {
				goto skipDrawing;
			}
			cell.invalidated = false;
			{

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

					painter.fillColor = reverse ? fgc : bgc;
					painter.outlineColor = reverse ? fgc : bgc;
					painter.drawRectangle(Point(posx, posy), fontWidth - 1, fontHeight - 1);
					painter.fillColor = Color.transparent;
					painter.outlineColor = reverse ? bgc : fgc;
				}
			}

				if(cell.ch != dchar.init) {
					char[4] str;
					import std.utf;
					if(cell.ch != ' ') // no point wasting time drawing spaces, which are nothing; the bg rectangle already did the important thing
					try {
					auto stride = encode(str, cell.ch);
					painter.drawText(Point(posx, posy), cast(immutable) str[0 .. stride]);
					} catch(Exception e) {
						import std.stdio;
						writeln(cast(uint) cell.ch, " :: ", e.msg);
					}
				} else if(cell.nonCharacterData !is null) {
					if(auto ncdi = cast(NonCharacterData_Image) cell.nonCharacterData) {
						painter.drawImage(Point(posx, posy), ncdi.data, Point(0, 0), fontWidth, fontHeight);
					}
				}

				if(cell.attributes.underlined)
					painter.drawLine(Point(posx, posy + fontHeight - 1), Point(posx + fontWidth - 1, posy + fontHeight - 1));
			skipDrawing:

				posx += fontWidth;
			x++;
			if(x == screenWidth) {
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
					painter.drawRectangle(Point(posx, posy), cursorWidth - 1, cursorHeight -1);
				break;
				case CursorStyle.underline:
					painter.drawRectangle(Point(posx, posy + cursorHeight - 2 - 1), cursorWidth, 2);
				break;
				case CursorStyle.bar:
					painter.drawRectangle(Point(posx, posy), 2, cursorHeight - 1);
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


