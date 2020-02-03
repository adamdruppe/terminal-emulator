/+
	This is a modified version of main.d optimized for my old macbook
	which has a broken screen.
+/

// You can edit this if you like to make the alt+keys do other stuff.
enum string[dchar] altMappings = [
	//'t' : "θ",
	//'p' : "\u03c6",

	'\'' : "\&ldquo;",
	'\"' : "\&rdquo;",

	// unicode parens
	// \u27e8\u27e9 or \u3008\u3009 
];

enum tabHeight = 32;

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

int fontWidth;
int fontHeight;

SimpleWindow mw;
TerminalEmulatorWindow[] tabs;

void redrawAll(SimpleWindow mw) {
	// paint the dead spot on my monitor
	auto painter = mw.draw();
	painter.fillColor = Color(180, 180, 180);
	painter.outlineColor = Color.black;
	painter.drawRectangle(Point(1040, 0), Size(90, mw.height));

	auto tcf = Color(0, 0, 160);
	auto tc = Color(0, 0, 80);
	auto tca = Color(0, 200, 0);
	auto y = 0;
	foreach(tab; tabs) {
		auto pt = Point(1040 + 90, y);
		if(tab.wantsAttention)
			painter.fillColor = tca;
		else
			painter.fillColor = tab.window.focused ? tcf : tc;
		painter.drawRectangle(pt, Size(mw.width - 90 - 1040, tabHeight));
		painter.outlineColor = Color.white;
		if(tab.window.secret_icon)
			painter.drawImage(pt + Point(8, 8), tab.window.secret_icon);
		painter.drawText(pt + Point(32, 8), tab.window.title);
		painter.outlineColor = Color.black;
		y += tabHeight;
	}

	painter.fillColor = Color(0, 40, 0);
	painter.drawRectangle(Point(1040 + 90, y), Size(mw.width - 90 - 1040, mw.height - y));
}

void showTab(size_t tabNumber) {
	foreach(idx, tab; tabs) {
		if(idx == tabNumber) {
			tab.window.show();
			tab.window.focus();
		} else {
			tab.window.hide();
		}
	}
	mw.redrawAll();

}

void main(string[] args) {

	{
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
		}
	}

	mw = new SimpleWindow(
		1320,
		690,
		"Tabbed Terminal Emulator",
		OpenGlOptions.no,
		Resizability.allowResizing
	);

		import std.process;
		auto cmd = environment.get("SHELL", "/bin/bash");

	void startup(int master) {
		import std.conv;
		auto term = new TerminalEmulatorWindow(mw, master, (args.length > 1) ? to!int(args[1]) : 0);
	}

	void newTab() {
		startChild!startup(args.length > 2 ? args[2] : cmd, args.length > 2 ? args[2 .. $] : [cmd]);
		showTab(tabs.length-1);
	}

	mw.setEventHandlers(
		delegate (MouseEvent ev) {
			if(ev.type == arsd.simpledisplay.MouseEventType.buttonPressed) {
				if(ev.x > 1040 + 90) {
					auto tabNumber = ev.y / tabHeight;
					if(tabNumber < tabs.length) {
						showTab(tabNumber);
					} else if(tabNumber == tabs.length) {
						newTab();
						mw.redrawAll();
					}
				}
			}
		}
	);

	try {
		newTab();

		mw.redrawAll();

		mw.eventLoop(0);
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
		//EventLoop.get.exit();
		foreach(idx, tab; tabs) {
			if(tab is this) {
				tabs = tabs[0 .. idx] ~ tabs[idx + 1 .. $];
				if(idx < tabs.length)
					showTab(idx);
				else if(tabs.length)
					showTab(0);
				break;
			}
		}
		window.close();

		mw.redrawAll();
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
		mw.redrawAll();
	}
	protected override void changeWindowIcon(IndexedImage t) {
		if(window && t)
			window.icon = t;
		mw.redrawAll();
	}
	protected override void changeIconTitle(string) {}
	protected override void changeTextAttributes(TextAttributes) {}
	protected override void soundBell() {
		static if(UsingSimpledisplayX11)
			XBell(XDisplayConnection.get(), 50);
	}

	protected override void demandAttention() {
		window.requestAttention();
		this.wantsAttention = true;
		mw.redrawAll();
	}

	bool wantsAttention;

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
	}
	mixin PtySupport!(resizeImage);

	import arsd.simpledisplay;

	TtfFont font;

	bool debugMode;


	DebugWindow debugWindow;

	this(SimpleWindow parentWindow, int masterfd, int fontSize = 0) {
		master = masterfd;
		this(parentWindow, fontSize);
	}

	bool focused;

	this(SimpleWindow parentWindow, int fontSize = 0) {
		if(fontSize) {
			assert(0);
		}

		window = new SimpleWindow(
			1040,
			parentWindow.height,
			"Terminal Emulator",
			OpenGlOptions.no,
			Resizability.allowResizing,
			WindowTypes.nestedChild,
			0,
			parentWindow);

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
			wantsAttention = false;
			attentionReceived();
			mw.redrawAll();
		};

		super(window.width / fontWidth, window.height / fontHeight);

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

		version(Posix) {
			makeNonBlocking(master);
			auto listener = new PosixFdReader(&readyToRead, master);
			listener.onHup = () { requestExit(); listener.dispose(); };
			// no edge triggering, that has a nasty habit of locking us up
			/+
			addListener(delegate void(FileHup hup) {
				import core.sys.posix.unistd;
				close(hup.fd);
			});
			+/
		}

		tabs ~= this;

		flushGui();
	}

	SimpleWindow window;

	static int fontSize = 14;

	enum paddingLeft = 2;
	enum paddingTop = 1;

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

		redrawPainter(painter, forceRedraw);
	}

	bool lastDrawAlternativeScreen;
	final SRectangle redrawPainter(T)(T painter, bool forceRedraw) {
		SRectangle invalidated;

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

					auto fgc = cell.attributes.foregroundIndex == 256 ? defaultForeground : palette[cell.attributes.foregroundIndex & 0xff];
					auto bgc = cell.attributes.backgroundIndex == 256 ? defaultBackground : palette[cell.attributes.backgroundIndex & 0xff];

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
