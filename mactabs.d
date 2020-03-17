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

		loadDefaultFont();

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

	mixin SdpyDraw;
}
