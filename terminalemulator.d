/**
	There should be a redraw thing that is given batches of instructions
	in here that the other thing just implements.

	FIXME: the save stack stuff should do cursor style too

	This is an extendible unix terminal emulator and some helper functions to help actually implement one.

	You'll have to subclass TerminalEmulator and implement the abstract functions as well as write a drawing function for it.

	See nestedterminalemulator.d or main.d for how I did it.
*/
module arsd.terminalemulator;

import arsd.color;

enum extensionMagicIdentifier = "ARSD Terminal Emulator binary extension data follows:";

interface NonCharacterData {
	//const(ubyte)[] serialize();
}

struct BrokenUpImage {
	int width;
	int height;
	TerminalEmulator.TerminalCell[] representation;
}

struct CustomGlyph {
	TrueColorImage image;
	dchar substitute;
}

/**
	An abstract class that does terminal emulation. You'll have to subclass it to make it work.

	The terminal implements a subset of what xterm does and then, optionally, some special features.

	Its linear mode (normal) screen buffer is infinitely long and infinitely wide. It is the responsibility
	of your subclass to do line wrapping, etc., for display. This i think is actually incompatible with xterm but meh.

	actually maybe it *should* automatically wrap them. idk. I think GNU screen does both. FIXME decide.

	Its cellular mode (alternate) screen buffer can be any size you want.
*/
class TerminalEmulator {
	/* override these to do stuff on the interface.
	You might be able to stub them out if there's no state maintained on the target, since TerminalEmulator maintains its own internal state */
	protected abstract void changeWindowTitle(string); /// the title of the window
	protected abstract void changeIconTitle(string); /// the shorter window/iconified window

	protected abstract void changeWindowIcon(IndexedImage); /// change the window icon. note this may be null

	protected abstract void changeCursorStyle(CursorStyle); /// cursor style

	protected abstract void changeTextAttributes(TextAttributes); /// current text output attributes
	protected abstract void soundBell(); /// sounds the bell
	protected abstract void sendToApplication(const(void)[]); /// send some data to the information

	protected abstract void copyToClipboard(string); /// copy the given data to the clipboard (or you can do nothing if you can't)
	protected abstract void pasteFromClipboard(void delegate(string)); /// requests a paste. we pass it a delegate that should accept the data

	// I believe \033[50~ and up are available for extensions everywhere.
	// when keys are shifted, xterm sends them as \033[1;2F for example with end. but is this even sane? how would we do it with say, F5?
	// apparently shifted F5 is ^[[15;2~
	// alt + f5 is ^[[15;3~
	// alt+shift+f5 is ^[[15;4~

	public void sendPasteData(string data) {
		if(bracketedPasteMode)
			sendToApplication("\033[200~");

		sendToApplication(data);

		if(bracketedPasteMode)
			sendToApplication("\033[201~");
	}

	bool dragging;
	int lastDragX, lastDragY;
	public bool sendMouseInputToApplication(int termX, int termY, MouseEventType type, MouseButton button, bool shift, bool ctrl) {
		if(termX < 0)
			termX = 0;
		if(termX >= screenWidth)
			termX = screenWidth - 1;
		if(termY < 0)
			termY = 0;
		if(termY >= screenHeight)
			termY = screenHeight - 1;

		version(Windows) {
			// I'm swapping these because my laptop doesn't have a middle button,
			// and putty swaps them too by default so whatevs.
			if(button == MouseButton.right)
				button = MouseButton.middle;
			else if(button == MouseButton.middle)
				button = MouseButton.right;
		}

		int baseEventCode() {
			int b;
			// lol the xterm mouse thing sucks like javascript! unbelievable
			// it doesn't support two buttons at once...
			if(button == MouseButton.left)
				b = 0;
			else if(button == MouseButton.right)
				b = 2;
			else if(button == MouseButton.middle)
				b = 1;
			else if(button == MouseButton.wheelUp)
				b = 64 | 0;
			else if(button == MouseButton.wheelDown)
				b = 64 | 1;
			else
				b = 3; // none pressed or button released

			if(shift)
				b |= 4;
			if(ctrl)
				b |= 16;

			return b;
		}


		if(type == MouseEventType.buttonReleased) {
			// X sends press and release on wheel events, but we certainly don't care about those
			if(button == MouseButton.wheelUp || button == MouseButton.wheelDown)
				return false;

			if(dragging) {
				auto text = getPlainText(selectionStart, selectionEnd);
				if(text.length) {
					copyToClipboard(text);
				}
			}

			dragging = false;
			if(mouseButtonReleaseTracking) {
				int b = baseEventCode;
				b |= 3; // always send none / button released
				sendToApplication("\033[M" ~ cast(char) (b | 32) ~ cast(char) (termX+1 + 32) ~ cast(char) (termY+1 + 32));
			}
		}

		if(type == MouseEventType.motion) {
			if(termX != lastDragX || termY != lastDragY) {
				lastDragY = termY;
				lastDragX = termX;
				if(mouseMotionTracking || (mouseButtonMotionTracking && button)) {
					int b = baseEventCode;
					sendToApplication("\033[M" ~ cast(char) ((b | 32) + 32) ~ cast(char) (termX+1 + 32) ~ cast(char) (termY+1 + 32));
				}

				if(dragging) {
					auto idx = termY * screenWidth + termX;

					// the no-longer-selected portion needs to be invalidated
					int start, end;
					if(idx > selectionEnd) {
						start = selectionEnd;
						end = idx;
					} else {
						start = idx;
						end = selectionEnd;
					}
					foreach(ref cell; (alternateScreenActive ? alternateScreen : normalScreen)[start .. end]) {
						cell.invalidated = true;
						cell.selected = false;
					}

					selectionEnd = idx;

					// and the freshly selected portion needs to be invalidated
					if(selectionStart > selectionEnd) {
						start = selectionEnd;
						end = selectionStart;
					} else {
						start = selectionStart;
						end = selectionEnd;
					}
					foreach(ref cell; (alternateScreenActive ? alternateScreen : normalScreen)[start .. end]) {
						cell.invalidated = true;
						cell.selected = true;
					}

					return true;
				}
			}
		}

		if(type == MouseEventType.buttonPressed) {
			// double click detection
			import std.datetime;
			static SysTime lastClickTime;
			static int consecutiveClicks = 1;

			if(button != MouseButton.wheelUp && button != MouseButton.wheelDown) {
				if(Clock.currTime() - lastClickTime < dur!"msecs"(250))
					consecutiveClicks++;
				else
					consecutiveClicks = 1;

				lastClickTime = Clock.currTime();
			}
			// end dbl click

			if(!(shift) && mouseButtonTracking) {
				int b = baseEventCode;

				int x = termX;
				int y = termY;
				x++; y++; // applications expect it to be one-based
				sendToApplication("\033[M" ~ cast(char) (b | 32) ~ cast(char) (x + 32) ~ cast(char) (y + 32));
			} else {
				if(button == MouseButton.middle) {
					pasteFromClipboard(&sendPasteData);
				}

				if(button == MouseButton.wheelUp) {
					scrollback(1);
					return true;
				}
				if(button == MouseButton.wheelDown) {
					scrollback(-1);
					return true;
				}

				if(button == MouseButton.left) {
					// we invalidate the old selection since it should no longer be highlighted...
					makeSelectionOffsetsSane(selectionStart, selectionEnd);

					auto activeScreen = (alternateScreenActive ? &alternateScreen : &normalScreen);
					foreach(ref cell; (*activeScreen)[selectionStart .. selectionEnd]) {
						cell.invalidated = true;
						cell.selected = false;
					}

					if(consecutiveClicks == 1) {
						selectionStart = termY * screenWidth + termX;
						selectionEnd = selectionStart;
					} else if(consecutiveClicks == 2) {
						selectionStart = termY * screenWidth + termX;
						selectionEnd = selectionStart;
						while(selectionStart > 0 && (*activeScreen)[selectionStart-1].ch != ' ') {
							selectionStart--;
						}

						while(selectionEnd < (*activeScreen).length && (*activeScreen)[selectionEnd].ch != ' ') {
							selectionEnd++;
						}

					} else if(consecutiveClicks == 3) {
						selectionStart = termY * screenWidth;
						selectionEnd = selectionStart + screenWidth;
					}
					dragging = true;
					lastDragX = termX;
					lastDragY = termY;

					// then invalidate the new selection as well since it should be highlighted
					foreach(ref cell; (alternateScreenActive ? alternateScreen : normalScreen)[selectionStart .. selectionEnd]) {
						cell.invalidated = true;
						cell.selected = true;
					}

					return true;
				}
				if(button == MouseButton.right) {
					auto oldSelectionEnd = selectionEnd;
					selectionEnd = termY * screenWidth + termX;

					if(selectionEnd < oldSelectionEnd) {
						auto tmp = selectionEnd;
						selectionEnd = oldSelectionEnd;
						oldSelectionEnd = tmp;
					}

					foreach(ref cell; (alternateScreenActive ? alternateScreen : normalScreen)[oldSelectionEnd .. selectionEnd]) {
						cell.invalidated = true;
						cell.selected = true;
					}

					auto text = getPlainText(selectionStart, selectionEnd);
					if(text.length) {
						copyToClipboard(text);
					}
					return true;
				}
			}
		}

		return false;
	}

	private int selectionStart; // an offset into the screen buffer
	private int selectionEnd; // ditto

	/// Send a non-character key sequence
	public bool sendKeyToApplication(TerminalKey key, bool shift = false, bool alt = false, bool ctrl = false, bool windows = false) {
		bool redrawRequired = false;

		// scrollback controls. Unlike xterm, I only want to do this on the normal screen, since alt screen
		// doesn't have scrollback anyway. Thus the key will be forwarded to the application.
		if((!alternateScreenActive || scrollingBack) && key == TerminalKey.PageUp && shift) {
			scrollback(10);
			return true;
		} else if((!alternateScreenActive || scrollingBack) && key == TerminalKey.PageDown && shift) {
			scrollback(-10);
			return true;
		} else if((!alternateScreenActive || scrollingBack)) { // && ev.key != Key.Shift && ev.key != Key.Shift_r) {
			if(endScrollback())
				redrawRequired = true;
		}



		void sendToApplicationModified(string s) {
			bool anyModifier = shift || alt || ctrl || windows;
			if(!anyModifier || applicationCursorKeys)
				sendToApplication(s); // FIXME: applicationCursorKeys can still be shifted i think but meh
			else {
				string modifierNumber;
				if(shift && alt && ctrl) modifierNumber = "8";
				if(alt && ctrl && !shift) modifierNumber = "7";
				if(shift && ctrl && !alt) modifierNumber = "6";
				if(ctrl && !shift && !alt) modifierNumber = "5";
				if(shift && alt && !ctrl) modifierNumber = "4";
				if(alt && !shift && !ctrl) modifierNumber = "3";
				if(shift && !alt && !ctrl) modifierNumber = "2";
				// FIXME: meta and windows
				// windows is an extension
				if(windows) {
					if(modifierNumber.length)
						modifierNumber = "2" ~ modifierNumber;
					else
						modifierNumber = "20";
					/* // the below is what we're really doing
					int mn = 0;
					if(modifierNumber.length)
						mn = modifierNumber[0] + '0';
					mn += 20;
					*/
				}

				string keyNumber;
				char terminator;

				if(s[$-1] == '~') {
					keyNumber = s[2 .. $-1];
					terminator = '~';
				} else {
					keyNumber = "1";
					terminator = s[$ - 1];
				}
				// the xterm style is last bit tell us what it is
				sendToApplication("\033[" ~ keyNumber ~ ";" ~ modifierNumber ~ terminator);
			}
		}

		alias TerminalKey Key;
		final switch(key) {
			case Key.Left: sendToApplicationModified(applicationCursorKeys ? "\033OD" : "\033[D"); break;
			case Key.Up: sendToApplicationModified(applicationCursorKeys ? "\033OA" : "\033[A"); break;
			case Key.Down: sendToApplicationModified(applicationCursorKeys ? "\033OB" : "\033[B"); break;
			case Key.Right: sendToApplicationModified(applicationCursorKeys ? "\033OC" : "\033[C"); break;

			case Key.Home: sendToApplicationModified(applicationCursorKeys ? "\033OH" : (1 ? "\033[H" : "\033[1~")); break;
			case Key.Insert: sendToApplicationModified("\033[2~"); break;
			case Key.Delete: sendToApplicationModified("\033[3~"); break;

			// the 1? is xterm vs gnu screen. but i really want xterm compatibility.
			case Key.End: sendToApplicationModified(applicationCursorKeys ? "\033OF" : (1 ? "\033[F" : "\033[4~")); break;
			case Key.PageUp: sendToApplicationModified("\033[5~"); break;
			case Key.PageDown: sendToApplicationModified("\033[6~"); break;

			// the first one here is preferred, the second option is what xterm does if you turn on the "old function keys" option, which most apps don't actually expect
			case Key.F1: sendToApplicationModified(1 ? "\033OP" : "\033[11~"); break;
			case Key.F2: sendToApplicationModified(1 ? "\033OQ" : "\033[12~"); break;
			case Key.F3: sendToApplicationModified(1 ? "\033OR" : "\033[13~"); break;
			case Key.F4: sendToApplicationModified(1 ? "\033OS" : "\033[14~"); break;
			case Key.F5: sendToApplicationModified("\033[15~"); break;
			case Key.F6: sendToApplicationModified("\033[17~"); break;
			case Key.F7: sendToApplicationModified("\033[18~"); break;
			case Key.F8: sendToApplicationModified("\033[19~"); break;
			case Key.F9: sendToApplicationModified("\033[20"); break;
			case Key.F10: sendToApplicationModified("\033[21~"); break;
			case Key.F11: sendToApplicationModified("\033[23~"); break;
			case Key.F12: sendToApplicationModified("\033[24~"); break;

			case Key.Escape: sendToApplicationModified("\033"); break;
		}

		return redrawRequired;
	}

	/// if a binary extension is triggered, the implementing class is responsible for figuring out how it should be made to fit into the screen buffer
	protected /*abstract*/ BrokenUpImage handleBinaryExtensionData(const(ubyte)[]) {
		return BrokenUpImage();
	}

	/// If you subclass this and return true, you can scroll on command without needing to redraw the entire screen;
	/// returning true here suppresses the automatic invalidation of scrolled lines (except the new one).
	protected bool scrollLines(int howMany, bool scrollUp) {
		return false;
	}

	// might be worth doing the redraw magic in here too.
	protected void drawTextSection(int x, int y, TextAttributes attributes, in dchar[] text, bool isAllSpaces) {
		// if you implement this it will always give you a continuous block on a single line. note that text may be a bunch of spaces, in that case you can just draw the bg color to clear the area
		// or you can redraw based on the invalidated flag on the buffer
	}
	// FIXME: what about image sections? maybe it is still necessary to loop through them

	/// Style of the cursor
	enum CursorStyle {
		block, /// a solid block over the position (like default xterm or many gui replace modes)
		underline, /// underlining the position (like the vga text mode default)
		bar, /// a bar on the left side of the cursor position (like gui insert modes)
	}

	// these can be overridden, but don't have to be
	TextAttributes defaultTextAttributes() {
		TextAttributes ta;

		ta.foregroundIndex = 256; // terminal.d uses this as Color.DEFAULT
		ta.backgroundIndex = 256;

		import std.process;
		// I'm using the environment for this because my programs and scripts
		// already know this variable and then it gets nicely inherited. It is
		// also easy to set without buggering with other arguments. So works for me.
		if(environment.get("ELVISBG") == "dark") {
			ta.foreground = Color.white;
			ta.background = Color.black;
		} else {
			ta.foreground = Color.black;
			ta.background = Color.white;
		}
		return ta;
	}

	Color[256] palette;

	/// .
	struct TextAttributes {
		bool bold; /// .
		bool blink; /// .
		bool invisible; /// .
		bool inverse; /// .
		bool underlined; /// .

		bool italic; /// .
		bool strikeout; /// .

		// if the high bit here is set, you should use the full Color values if possible, and the value here sans the high bit if not
		ushort foregroundIndex; /// .
		ushort backgroundIndex; /// .

		Color foreground; /// .
		Color background; /// .
	}

	/// represents one terminal cell
	struct TerminalCell {
		dchar ch = ' '; /// the character
		NonCharacterData nonCharacterData; /// iff ch == dchar.init. may still be null, in which case this cell should not be drawn at all.

		TextAttributes attributes; /// color, etc.
		bool invalidated = true; /// if it needs to be redrawn
		bool selected = false; /// if it is currently selected by the user (for being copied to the clipboard)
	}

	/// Cursor position, zero based. (0,0) == upper left. (0, 1) == second row, first column.
	struct CursorPosition {
		int x; /// .
		int y; /// .
		alias y row;
		alias x column;
	}

	// these public functions can be used to manipulate the terminal

	/// clear the screen
	void cls() {
		TerminalCell plain;
		plain.ch = ' ';
		plain.attributes = currentAttributes;
		foreach(i, ref cell; alternateScreenActive ? alternateScreen : normalScreen) {
			cell = plain;
		}
	}

	void makeSelectionOffsetsSane(ref int offsetStart, ref int offsetEnd) {
		auto buffer = &alternateScreen;

		if(offsetStart < 0)
			offsetStart = 0;
		if(offsetEnd < 0)
			offsetEnd = 0;
		if(offsetStart > (*buffer).length)
			offsetStart = (*buffer).length;
		if(offsetEnd > (*buffer).length)
			offsetEnd = (*buffer).length;

		// if it is backwards, we can flip it
		if(offsetEnd < offsetStart) {
			auto tmp = offsetStart;
			offsetStart = offsetEnd;
			offsetEnd = tmp;
		}
	}

	public string getPlainText(int offsetStart, int offsetEnd) {
		auto buffer = alternateScreenActive ? &alternateScreen : &normalScreen;

		makeSelectionOffsetsSane(offsetStart, offsetEnd);

		if(offsetStart == offsetEnd)
			return null;

		int x = offsetStart % screenWidth;
		int firstSpace = -1;
		string ret;
		foreach(cell; (*buffer)[offsetStart .. offsetEnd]) {
			ret ~= cell.ch;

			x++;
			if(x == screenWidth) {
				x = 0;
				if(firstSpace != -1) {
					// we ended with a bunch of spaces, let's replace them with a single newline so the next is more natural
					ret = ret[0 .. firstSpace];
					ret ~= "\n";
				}
			} else {
				if(cell.ch == ' ' && firstSpace == -1)
					firstSpace = ret.length;
				else if(cell.ch != ' ')
					firstSpace = -1;
			}
		}
		return ret;
	}

	void scrollDown(int count = 1) {
		if(cursorY + 1 < screenHeight) {
			TerminalCell plain;
			plain.ch = ' ';
			plain.attributes = defaultTextAttributes();
			plain.invalidated = true;
			foreach(i; 0 .. count) {
				// FIXME: should that be cursorY or scrollZoneTop?
				for(int y = scrollZoneBottom; y > cursorY; y--)
				foreach(x; 0 .. screenWidth) {
					ASS[y][x] = ASS[y - 1][x];
					ASS[y][x].invalidated = true;
				}

				foreach(x; 0 .. screenWidth)
					ASS[cursorY][x] = plain;
			}
		}
	}

	void scrollUp(int count = 1) {
		if(cursorY + 1 < screenHeight) {
			TerminalCell plain;
			plain.ch = ' ';
			plain.attributes = defaultTextAttributes();
			plain.invalidated = true;
			foreach(i; 0 .. count) {
				// FIXME: should that be cursorY or scrollZoneBottom?
				for(int y = scrollZoneTop; y < cursorY; y++)
				foreach(x; 0 .. screenWidth) {
					ASS[y][x] = ASS[y + 1][x];
					ASS[y][x].invalidated = true;
				}

				foreach(x; 0 .. screenWidth)
					ASS[cursorY][x] = plain;
			}
		}
	}


	int readingExtensionData = -1;
	string extensionData;

	immutable(dchar[dchar])* characterSet = null; // null means use regular UTF-8

	bool readingEsc = false;
	ubyte[] esc;
	/// sends raw input data to the terminal as if the user typed it or whatever
	void sendRawInput(in ubyte[] data) {
	//import std.array;
	//assert(!readingEsc, replace(cast(string) esc, "\033", "\\"));
		foreach(b; data) {
			if(readingExtensionData >= 0) {
				if(readingExtensionData == extensionMagicIdentifier.length) {
					if(b) {
						if(b != 13 && b != 10)
							extensionData ~= b;
					} else {
						readingExtensionData = -1;
						import std.base64;
						auto got = handleBinaryExtensionData(Base64.decode(extensionData));

						auto rep = got.representation;
						foreach(y; 0 .. got.height) {
							foreach(x; 0 .. got.width) {
								addOutput(rep[0]);
								rep = rep[1 .. $];
							}
							newLine(true);
						}
					}
				} else {
					if(b == extensionMagicIdentifier[readingExtensionData])
						readingExtensionData++;
					else
						readingExtensionData = -1;
				}

				continue;
			}

			if(b == 0) {
				readingExtensionData = 0;
				extensionData = null;
				continue;
			}

			if(readingEsc) {
				if(b == 10) {
					readingEsc = false;
				}
				esc ~= b;

				if(esc.length == 1 && esc[0] == '7') {
					savedCursor = cursorPosition;
					esc = null;
					readingEsc = false;
				} else if(esc.length == 1 && esc[0] == 'M') {
					// reverse index
					esc = null;
					readingEsc = false;
					if(cursorY <= scrollZoneTop)
						scrollDown();
					else
						cursorY = cursorY - 1;
				} else if(esc.length == 1 && esc[0] == '=') {
					// application keypad
					esc = null;
					readingEsc = false;
				} else if(esc.length == 2 && esc[0] == '%' && esc[1] == 'G') {
					// UTF-8 mode
					esc = null;
					readingEsc = false;
				} else if(esc.length == 1 && esc[0] == '8') {
					cursorPosition = savedCursor;
					esc = null;
					readingEsc = false;
				} else if(esc.length == 1 && esc[0] == 'c') {
					// reset
					// FIXME
					esc = null;
					readingEsc = false;
				} else if(esc.length == 1 && esc[0] == '>') {
					// normal keypad
					esc = null;
					readingEsc = false;
				} else if(esc.length > 1 && (
					(esc[0] == '[' && (b >= 64 && b <= 126)) ||
					(esc[0] == ']' && b == '\007')))
				{
					tryEsc(esc);
					esc = null;
					readingEsc = false;
				} else if(esc.length == 3 && esc[0] == '%' && esc[1] == 'G') {
					// UTF-8 mode. ignored because we're always in utf-8 mode (though should we be?)
					esc = null;
					readingEsc = false;
				} else if(esc.length == 2 && esc[0] == ')') {
					// more character set selection. idk exactly how this works
					esc = null;
					readingEsc = false;
				} else if(esc.length == 2 && esc[0] == '(') {
					// xterm command for character set
					// FIXME: handling esc[1] == '0' would be pretty boss
					// and esc[1] == 'B' == united states
					if(esc[1] == '0')
						characterSet = &lineDrawingCharacterSet;
					else
						characterSet = null; // our default is UTF-8 and i don't care much about others anyway.

					esc = null;
					readingEsc = false;
				}
				continue;
			}

			if(b == 27) {
				readingEsc = true;
				debug if(esc !is null) {
					import std.stdio; writeln("discarding esc ", cast(string) esc);
				}
				esc = null;
				continue;
			}

			if(b == 13) {
				cursorX = 0;
				continue;
			}

			if(b == 7) {
				soundBell();
				continue;
			}

			if(b == 8) {
				cursorX = cursorX - 1;
				continue;
			}

			if(b == 9) {
				int howMany = 8 - (cursorX % 8);
				foreach(i; 0 .. howMany)
					addOutput(' '); // FIXME: it would be nice to actually put a tab character there for copy/paste accuracy (ditto with newlines actually)
				continue;
			}

//			std.stdio.writeln("READ ", data[w]);
			addOutput(b);
		}
	}


	/// construct
	this(int width, int height) {
		// initialization
		currentAttributes = defaultTextAttributes();
		cursorColor = Color.white;

		palette[] = xtermPalette[];

		resizeTerminal(width, height);

		// update the other thing
		if(windowTitle.length == 0)
			windowTitle = "Terminal Emulator";
		changeWindowTitle(windowTitle);
		changeIconTitle(iconTitle);
		changeTextAttributes(currentAttributes);
	}


	private {
		TerminalCell[] scrollbackMainScreen;
		bool scrollbackCursorShowing;
		int scrollbackCursorX;
		int scrollbackCursorY;
		protected bool scrollingBack;

		int currentScrollback;
	}

	// FIXME: if it is resized while scrolling back, stuff can get messed up

	void scrollback(int delta) {
		if(alternateScreenActive && !scrollingBack)
			return;

		if(!scrollingBack) {
			if(delta <= 0)
				return; // it does nothing to scroll down when not scrolling back
			startScrollback();
		}
		currentScrollback += delta;

		int max = scrollbackBuffer.length - screenHeight;
		if(max < 0)
			max = 0;
		if(currentScrollback > max)
			currentScrollback = max;

		if(currentScrollback <= 0)
			endScrollback();
		else {
			cls();
			showScrollbackOnScreen(alternateScreen, currentScrollback);
		}
	}

	private void startScrollback() {
		if(scrollingBack)
			return;
		currentScrollback = 0;
		scrollingBack = true;
		scrollbackCursorX = cursorX;
		scrollbackCursorY = cursorY;
		scrollbackCursorShowing = cursorShowing;
		scrollbackMainScreen = alternateScreen.dup;
		alternateScreenActive = true;

		cursorShowing = false;
	}

	bool endScrollback() {
		if(!scrollingBack)
			return false;
		scrollingBack = false;
		cursorX = scrollbackCursorX;
		cursorY = scrollbackCursorY;
		cursorShowing = scrollbackCursorShowing;
		alternateScreen = scrollbackMainScreen;
		alternateScreenActive = false;
		return true;
	}

	private void showScrollbackOnScreen(ref TerminalCell[] screen, int howFar) {
		int termination = scrollbackBuffer.length - howFar;
		if(termination < 0)
			termination = scrollbackBuffer.length;

		int start = termination - screenHeight;
		if(start < 0)
			start = 0;

		cursorX = 0;
		cursorY = 0;

		bool reflow; // FIXME: make this a config option or something

		if(reflow) {
			int numLines;
			foreach(line; scrollbackBuffer[start .. termination]) {
				numLines += 1 * ((line.length-1) / screenWidth);
			}

			while(numLines > screenHeight) {
				auto line = scrollbackBuffer[start];
				start++;
				numLines -= 1 * ((line.length-1) / screenWidth);
			}
		}

		TerminalCell overflowCell;
		overflowCell.ch = '\&raquo;';
		overflowCell.attributes.backgroundIndex = 3;
		overflowCell.attributes.foregroundIndex = 0;
		overflowCell.attributes.foreground = Color(40, 40, 40);
		overflowCell.attributes.background = Color.yellow;

		foreach(line; scrollbackBuffer[start .. termination]) {
			bool overflowed;
			foreach(cell; line) {
				cell.invalidated = true;
				if(overflowed)
					screen[cursorY * screenWidth + cursorX] = overflowCell;
				else
					screen[cursorY * screenWidth + cursorX] = cell;

				if(cursorX == screenWidth-1) {
					if(reflow) {
						cursorX = 0;
						cursorY = cursorY + 1;
					} else {
						overflowed = true;
					}
				} else
					cursorX = cursorX + 1;
			}
			cursorY = cursorY + 1;
			cursorX = 0;
		}

		cursorX = 0;
	}

	public void resizeTerminal(int w, int h) {
		if(w == screenWidth && h == screenHeight)
			return; // we're already good, do nothing to avoid wasting time and possibly losing a line (bash doesn't seem to like being told it "resized" to the same size)

		endScrollback(); // FIXME: hack

		screenWidth = w;
		screenHeight = h;

		normalScreen.length = screenWidth * screenHeight;
		alternateScreen.length = screenWidth * screenHeight;
		scrollZoneBottom = screenHeight - 1;

		// we need to make sure the state is sane all across the board, so first we'll clear everything...
		TerminalCell plain;
		plain.ch = ' ';
		plain.attributes = currentAttributes;
		plain.invalidated = true;
		foreach(ref c; normalScreen)
			c = plain;
		foreach(ref c; alternateScreen)
			c = plain;

		// then, in normal mode, we'll redraw using the scrollback buffer
		showScrollbackOnScreen(normalScreen, 0);
		// but in alternate mode, it is the application's responsibility

		// the property ensures these are within bounds so this set just forces that
		cursorY = cursorY;
		cursorX = cursorX;
	}

	/* FIXME: i want these to be private */
	protected {
		TextAttributes currentAttributes;
		CursorPosition cursorPosition;
		CursorPosition savedCursor;
		CursorStyle cursorStyle;
		Color cursorColor;
		string windowTitle;
		string iconTitle;

		IndexedImage windowIcon;
		IndexedImage[] iconStack;

		string[] titleStack;

		bool bracketedPasteMode;
		bool mouseButtonTracking;
		bool mouseMotionTracking;
		bool mouseButtonReleaseTracking;
		bool mouseButtonMotionTracking;

		void allMouseTrackingOff() {
			mouseMotionTracking = false;
			mouseButtonTracking = false;
			mouseButtonReleaseTracking = false;
			mouseButtonMotionTracking = false;
		}

		bool wraparoundMode = true;

		bool alternateScreenActive;
		bool cursorShowing = true;

		bool reverseVideo;
		bool applicationCursorKeys;

		bool scrollingEnabled = true;
		int scrollZoneTop;
		int scrollZoneBottom;

		int screenWidth;
		int screenHeight;
		// assert(alternateScreen.length = screenWidth * screenHeight);
		TerminalCell[] alternateScreen;
		TerminalCell[] normalScreen;

		// the lengths can be whatever
		TerminalCell[][] scrollbackBuffer;

		struct Helper2 {
			size_t row;
			TerminalEmulator t;
			this(TerminalEmulator t, size_t row) {
				this.t = t;
				this.row = row;
			}

			ref TerminalCell opIndex(size_t cell) {
				auto thing = t.alternateScreenActive ? &(t.alternateScreen) : &(t.normalScreen);
				return (*thing)[row * t.screenWidth + cell];
			}
		}

		struct Helper {
			TerminalEmulator t;
			this(TerminalEmulator t) {
				this.t = t;
			}

			Helper2 opIndex(size_t row) {
				return Helper2(t, row);
			}
		}

		@property Helper ASS() {
			return Helper(this);
		}

		@property int cursorX() { return cursorPosition.x; }
		@property int cursorY() { return cursorPosition.y; }
		@property void cursorX(int x) {
			if(x < 0)
				x = 0;
			if(x >= screenWidth)
				x = screenWidth - 1;
			cursorPosition.x = x;
		}
		@property void cursorY(int y) {
			if(y < 0)
				y = 0;
			if(y >= screenHeight)
				y = screenHeight - 1;
			cursorPosition.y = y;
		}

		void addOutput(string b) {
			foreach(c; b)
				addOutput(c);
		}

		TerminalCell[] currentScrollbackLine;
		int scrollbackWrappingAt = 0;
		dchar utf8Sequence;
		int utf8BytesRemaining;
		int currentUtf8Shift;
		bool newLineOnNext;
		void addOutput(ubyte b) {
			// this takes in bytes at a time, but since the input encoding is assumed to be UTF-8, we need to gather the bytes
			if(utf8BytesRemaining == 0) {
				// we're at the beginning of a sequence
				utf8Sequence = 0;
				if(b < 128) {
					utf8Sequence = cast(dchar) b;
					// one byte thing, do nothing more...
				} else {
					// the number of bytes in the sequence is the number of set bits in the first byte...
					uint shifted =0;
					bool there = false;
					ubyte checkingBit = 7;
					while(checkingBit) {
						if(!there && b & (1 << checkingBit))
							utf8BytesRemaining++;
						else
							there = true;
						if(there)
							shifted |= b & (1 << checkingBit);
						checkingBit--;
					}
					utf8BytesRemaining--; // since this current byte counts too
					currentUtf8Shift = utf8BytesRemaining * 6;

					shifted <<= (currentUtf8Shift + checkingBit);
					utf8Sequence = cast(dchar) shifted;
				}
			} else {
				// add this to the byte we're doing right now...
				utf8BytesRemaining--;
				currentUtf8Shift -= 6;
				if(!(b & 0b11000000) == 0b10000000) {
					// invalid utf-8 sequence,
					// discard it and try to continue
					utf8BytesRemaining = 0;
					return;
				}
				uint shifted = b;
				shifted &= 0b00111111;
				shifted <<= currentUtf8Shift;
				utf8Sequence |= shifted;
			}

			if(utf8BytesRemaining)
				return; // not enough data yet, wait for more before displaying anything

			if(utf8Sequence == 10) {
				newLineOnNext = false;
				auto cx = cursorX; // FIXME: this cx thing is a hack, newLine should prolly just do the right thing

				/*
				TerminalCell tc;
				tc.ch = utf8Sequence;
				tc.attributes = currentAttributes;
				tc.invalidated = true;
				addOutput(tc);
				*/

				newLine(true);
				cursorX = cx;
			} else {
				if(newLineOnNext) {
					newLineOnNext = false;
					// only if we're still on the right side...
					if(cursorX == screenWidth - 1)
						newLine(false);
				}
				TerminalCell tc;

				if(characterSet !is null) {
					if(auto replacement = utf8Sequence in *characterSet)
						utf8Sequence = *replacement;
				}
				tc.ch = utf8Sequence;
				tc.attributes = currentAttributes;
				tc.invalidated = true;

				addOutput(tc);
			}
		}

		bool insertMode = false;
		void newLine(bool commitScrollback) {
			if(!alternateScreenActive && commitScrollback) {
				scrollbackBuffer ~= currentScrollbackLine.dup;
				currentScrollbackLine = null;
				scrollbackWrappingAt = 0;
			}

			cursorX = 0;
			if(scrollingEnabled && cursorY >= scrollZoneBottom) {
				size_t idx = scrollZoneTop * screenWidth;
				foreach(l; scrollZoneTop .. scrollZoneBottom)
				foreach(i; 0 .. screenWidth) {
					if(alternateScreenActive) {
						alternateScreen[idx] = alternateScreen[idx + screenWidth];
						alternateScreen[idx].invalidated = true;
					} else {
						normalScreen[idx] = normalScreen[idx + screenWidth];
						normalScreen[idx].invalidated = true;
					}
					idx++;
				}
				foreach(i; 0 .. screenWidth) {
					if(alternateScreenActive) {
						alternateScreen[idx].ch = ' ';
						alternateScreen[idx].attributes = currentAttributes;
						alternateScreen[idx].invalidated = true;
					} else {
						normalScreen[idx].ch = ' ';
						normalScreen[idx].attributes = currentAttributes;
						normalScreen[idx].invalidated = true;
					}
					idx++;
				}
			} else {
				if(insertMode)
					scrollDown();
				else
					cursorY = cursorY + 1;
			}
		}


		void addOutput(TerminalCell tc) {
			if(alternateScreenActive) {
				alternateScreen[cursorY * screenWidth + cursorX] = tc;
			} else {
				normalScreen[cursorY * screenWidth + cursorX] = tc;

				TerminalCell plain;
				plain.ch = ' ';
				plain.attributes = currentAttributes;
				int lol = cursorX + scrollbackWrappingAt;
				while(lol >= currentScrollbackLine.length)
					currentScrollbackLine ~= plain;
				currentScrollbackLine[lol] = tc;
			}
			// FIXME: the wraparoundMode seems to help gnu screen but then it doesn't go away properly and that messes up bash...
			//if(wraparoundMode && cursorX == screenWidth - 1) {
			if(cursorX == screenWidth - 1) {
				// FIXME: should this check the scrolling zone instead?
				newLineOnNext = true;

				//if(!alternateScreenActive || cursorY < screenHeight - 1)
					//newLine(false);
				scrollbackWrappingAt = currentScrollbackLine.length;
			} else
				cursorX = cursorX + 1;

		}

		void tryEsc(ubyte[] esc) {
			int[] getArgsBase(int sidx, int[] defaults) {
				auto argsSection = cast(string) esc[sidx .. $-1];
				int[] args = defaults.dup;

				import std.string : split;
				import std.conv : to;
				foreach(i, arg; split(argsSection, ";")) {
					int value;
					if(arg.length)
						value = to!int(arg);
					else if(defaults.length > i)
						value = defaults[i];

					if(args.length > i)
						args[i] = value;
					else
						args ~= value;
				}

				return args;
			}
			int[] getArgs(int[] defaults...) {
				return getArgsBase(1, defaults);
			}

			// FIXME
			// from  http://invisible-island.net/xterm/ctlseqs/ctlseqs.html
			// check out this section: "Window manipulation (from dtterm, as well as extensions)"
			// especially the title stack, that should rock
			/*
P s = 2 2 ; 0 → Save xterm icon and window title on stack.
P s = 2 2 ; 1 → Save xterm icon title on stack.
P s = 2 2 ; 2 → Save xterm window title on stack.
P s = 2 3 ; 0 → Restore xterm icon and window title from stack.
P s = 2 3 ; 1 → Restore xterm icon title from stack.
P s = 2 3 ; 2 → Restore xterm window title from stack.

			*/

			if(esc[0] == ']' && esc.length > 1) {
				int idx = -1;
				foreach(i, e; esc)
					if(e == ';') {
						idx = i;
						break;
					}
				if(idx != -1) {
					auto arg = cast(string) esc[idx + 1 .. $-1];
					switch(cast(string) esc[1..idx]) {
						case "0":
							// icon name and window title
							windowTitle = iconTitle = arg;
							changeWindowTitle(windowTitle);
							changeIconTitle(iconTitle);
						break;
						case "1":
							// icon name
							iconTitle = arg;
							changeIconTitle(iconTitle);
						break;
						case "2":
							// window title
							windowTitle = arg;
							changeWindowTitle(windowTitle);
						break;
						case "12":
							arg = arg[1 ..$];
							if(arg.length) {
								cursorColor = Color.fromString(arg);
								foreach(ref p; cursorColor.components[0 .. 3])
									p ^= 0xff;
							} else
								cursorColor = Color.white;
						break;
						case "50":
							// change font
						break;
						case "52":
							// copy/paste control
							// echo -e "\033]52;p;?\007"
							// the p == primary
							// the data after it is either base64 stuff to copy or ? to request a paste

							if(arg == "p;?") {
								// i'm using this to request a paste. not quite compatible with xterm, but kinda
								// because xterm tends not to answer anyway.
								pasteFromClipboard(&sendPasteData);
							} else if(arg.length > 2 && arg[0 .. 2] == "p;") {
								auto info = arg[2 .. $];
								try {
									import std.base64;
									auto data = Base64.decode(info);
									copyToClipboard(cast(string) data);
								} catch(Exception e)  {}
							}
						break;
						case "4":
							// palette change or query
							        // set color #0 == black
							// echo -e '\033]4;0;black\007'
							/*
								echo -e '\033]4;9;?\007' ; cat

								^[]4;9;rgb:ffff/0000/0000^G
							*/

							// FIXME: if the palette changes, we should redraw so the change is immediately visible (as if we were using a real palette)
						break;
						case "104":
							// palette reset
							// reset color #0
							// echo -e '\033[104;0\007'
						break;
						/* Extensions */
						case "5000":
							// change window icon (send a base64 encoded image or something)
							/*
								The format here is width and height as a single char each
									'0'-'9' == 0-9
									'a'-'z' == 10 - 36
									anything else is invalid
								
								then a palette in hex rgba format (8 chars each), up to 26 entries

								then a capital Z

								if a palette entry == 'P', it means pull from the current palette (FIXME not implemented)

								then 256 characters between a-z (must be lowercase!) which are the palette entries for
								the pixels, top to bottom, left to right, so the image is 16x16. if it ends early, the
								rest of the data is assumed to be zero

								you can also do e.g. 22a, which means repeat a 22 times for some RLE.

								anything out of range aborts the operation
							*/

							auto img = readSmallTextImage(arg);
							windowIcon = img;
							changeWindowIcon(img);
						break;
						default:
							assert(0, "" ~ cast(char) esc[1]);
					}
				}
			} else if(esc[0] == '[' && esc.length > 1) {
				switch(esc[$-1]) {
					case 'n':
						switch(esc[$-2]) {
							import std.string;
							// request status report, reply OK
							case '5': sendToApplication("\033[0n"); break;
							// request cursor position
							case '6': sendToApplication(format("\033[%d;%dR", cursorY + 1, cursorX + 1)); break;
							default: assert(0, cast(string) esc);
						}
					break;
					case 'A': if(cursorY) cursorY = cursorY - getArgs(1)[0]; break;
					case 'B': if(cursorY != this.screenHeight - 1) cursorY = cursorY + getArgs(1)[0]; break;
					case 'D': if(cursorX) cursorX = cursorX - getArgs(1)[0]; break;
					case 'C': if(cursorX != this.screenWidth - 1) cursorX = cursorX + getArgs(1)[0]; break;

					case 'd': cursorY = getArgs(1)[0]-1; break;

					case 'E': cursorY = cursorY + getArgs(1)[0]; cursorX = 0; break;
					case 'F': cursorY = cursorY - getArgs(1)[0]; cursorX = 0; break;
					case 'G': cursorX = getArgs(1)[0] - 1; break;
					case 'H':
						auto got = getArgs(1, 1);
						cursorX = got[1] - 1;
						cursorY = got[0] - 1;
						newLineOnNext = false;
					break;
					case 'L':
						// insert lines
						scrollDown(getArgs(1)[0]);
					break;
					case 'M':
						// delete lines
						if(cursorY + 1 < screenHeight) {
							TerminalCell plain;
							plain.ch = ' ';
							plain.attributes = defaultTextAttributes();
							foreach(i; 0 .. getArgs(1)[0]) {
								foreach(y; cursorY .. scrollZoneBottom)
								foreach(x; 0 .. screenWidth) {
									ASS[y][x] = ASS[y + 1][x];
									ASS[y][x].invalidated = true;
								}
								foreach(x; 0 .. screenWidth) {
									ASS[scrollZoneBottom][x] = plain;
								}
							}
						}
					break;
					case 'K':
						auto arg = getArgs(0)[0];
						int start, end;
						if(arg == 0) {
							// clear from cursor to end of line
							start = cursorX;
							end = this.screenWidth;
						} else if(arg == 1) {
							// clear from cursor to beginning of line
							start = 0;
							end = cursorX + 1;
						} else if(arg == 2) {
							// clear entire line
							start = 0;
							end = this.screenWidth;
						}

						TerminalCell plain;
						plain.ch = ' ';
						plain.attributes = currentAttributes;

						for(int i = start; i < end; i++)
							ASS[cursorY]
								[i] = plain;
					break;
					case 'g':
						auto arg = getArgs(0)[0];
						TerminalCell plain;
						plain.ch = ' ';
						plain.attributes = currentAttributes;
						if(arg == 0) {
							// clear current column
							for(int i = 0; i < this.screenHeight; i++)
								ASS[i]
									[cursorY] = plain;
						} else if(arg == 3) {
							// clear all
							cls();
						}
					break;
					case 'q':
						// xterm also does blinks on the odd numbers (x-1)
						if(esc == "[0 q")
							cursorStyle = CursorStyle.block; // FIXME: restore default
						if(esc == "[2 q")
							cursorStyle = CursorStyle.block;
						else if(esc == "[4 q")
							cursorStyle = CursorStyle.underline;
						else if(esc == "[6 q")
							cursorStyle = CursorStyle.bar;

						changeCursorStyle(cursorStyle);
					break;
					case 't':
						// window commands
						// i might support more of these but for now i just want the stack stuff.

						auto args = getArgs(0, 0);
						if(args[0] == 22) {
							// save window title to stack
							// xterm says args[1] should tell if it is the window title, the icon title, or both, but meh
							titleStack ~= windowTitle;
							iconStack ~= windowIcon;
						} else if(args[0] == 23) {
							// restore from stack
							if(titleStack.length) {
								windowTitle = titleStack[$ - 1];
								changeWindowTitle(titleStack[$ - 1]);
								titleStack = titleStack[0 .. $ - 1];
							}

							if(iconStack.length) {
								windowIcon = iconStack[$ - 1];
								changeWindowIcon(iconStack[$ - 1]);
								iconStack = iconStack[0 .. $ - 1];
							}
						}
					break;
					case 'm':
						argsLoop: foreach(argIdx, arg; getArgs(0))
						switch(arg) {
							case 0:
							// normal
								currentAttributes = defaultTextAttributes;
							break;
							case 1:
								currentAttributes.bold = true;
							break;
							case 4:
								currentAttributes.underlined = true;
							break;
							case 5:
								currentAttributes.blink = true;
							break;
							case 7:
								currentAttributes.inverse = true;
							break;
							case 8:
								currentAttributes.invisible = true;
							break;
							case 22:
								currentAttributes.bold = false;
							break;
							case 24:
								currentAttributes.underlined = false;
							break;
							case 25:
								currentAttributes.blink = false;
							break;
							case 27:
								currentAttributes.inverse = false;
							break;
							case 28:
								currentAttributes.invisible = false;
							break;
							case 30:
							..
							case 37:
							// set foreground color
								/*
								Color nc;
								ubyte multiplier = currentAttributes.bold ? 255 : 127;
								nc.r = cast(ubyte)((arg - 30) & 1) * multiplier;
								nc.g = cast(ubyte)(((arg - 30) & 2)>>1) * multiplier;
								nc.b = cast(ubyte)(((arg - 30) & 4)>>2) * multiplier;
								nc.a = 255;
								*/
								currentAttributes.foregroundIndex = cast(ubyte)(arg - 30);
								currentAttributes.foreground = palette[arg-30 + (currentAttributes.bold ? 8 : 0)];
							break;
							case 38:
								// xterm 256 color set foreground color
								auto args = getArgs()[argIdx + 1 .. $];
								if(args[0] == 2) {
									// set color to closest match in palette. but since we have full support, we'll just take it directly
									currentAttributes.foreground = Color(args[1], args[2], args[3]);
									// and try to find a low default palette entry for maximum compatibility
									// 0x8000 == approximation
									currentAttributes.foregroundIndex = 0x8000 | cast(ushort) findNearestColor(xtermPalette[0 .. 16], currentAttributes.foreground);
								} else if(args[0] == 5) {
									// set to palette index
									currentAttributes.foreground = palette[args[1]];
									currentAttributes.foregroundIndex = cast(ushort) args[1];
								}
								break argsLoop;
							case 39:
							// default foreground color
								auto dflt = defaultTextAttributes();

								currentAttributes.foreground = dflt.foreground;
								currentAttributes.foregroundIndex = dflt.foregroundIndex;
							break;
							case 40:
							..
							case 47:
							// set background color
								/*
								Color nc;
								nc.r = cast(ubyte)((arg - 40) & 1) * 255;
								nc.g = cast(ubyte)(((arg - 40) & 2)>>1) * 255;
								nc.b = cast(ubyte)(((arg - 40) & 4)>>2) * 255;
								nc.a = 255;
								*/

								currentAttributes.backgroundIndex = cast(ubyte)(arg - 40);
								//currentAttributes.background = nc;
								currentAttributes.background = palette[arg-40];
							break;
							case 48:
								// xterm 256 color set background color
								auto args = getArgs()[argIdx + 1 .. $];
								if(args[0] == 2) {
									// set color to closest match in palette. but since we have full support, we'll just take it directly
									currentAttributes.background = Color(args[1], args[2], args[3]);

									// and try to find a low default palette entry for maximum compatibility
									// 0x8000 == this is an approximation
									currentAttributes.backgroundIndex = 0x8000 | cast(ushort) findNearestColor(xtermPalette[0 .. 8], currentAttributes.background);
								} else if(args[0] == 5) {
									// set to palette index
									currentAttributes.background = palette[args[1]];
									currentAttributes.backgroundIndex = cast(ushort) args[1];
								}

								break argsLoop;
							case 49:
							// default background color
								auto dflt = defaultTextAttributes();

								currentAttributes.background = dflt.background;
								currentAttributes.backgroundIndex = dflt.backgroundIndex;
							break;
							default:
								assert(0, cast(string) esc);
						}
					break;
					case 'J':
						// erase in display
						auto arg = getArgs(0)[0];
						switch(arg) {
							case 0:
								TerminalCell plain;
								plain.ch = ' ';
								plain.attributes = currentAttributes;
								// erase below
								foreach(i; cursorY * screenWidth + cursorX .. screenWidth * screenHeight) {
									if(alternateScreenActive)
										alternateScreen[i] = plain;
									else
										normalScreen[i] = plain;
								}
							break;
							case 1:
								// erase above
								assert(0, "FIXME");
							break;
							case 2:
								// erase all
								cls();
							break;
							default: assert(0, cast(string) esc);
						}
					break;
					case 'r':
						// set scrolling zone
							// default should be full size of window
						auto args = getArgs(1, screenHeight);

						scrollZoneTop = args[0] - 1;
						scrollZoneBottom = args[1] - 1;
					break;
					case 'h':
						if(esc[1] != '?')
						foreach(arg; getArgs())
						switch(arg) {
							case 4:
								insertMode = true;
							break;
							case 34:
								// no idea. vim inside screen sends it
							break;
							default: assert(0, cast(string) esc);
						}
						else
					//import std.stdio; writeln("h magic ", cast(string) esc);
						foreach(arg; getArgsBase(2, null))
							switch(arg) {
								case 1:
									// application cursor keys
									applicationCursorKeys = true;
								break;
								case 3:
									// 132 column mode
								break;
								case 4:
									// smooth scroll
								break;
								case 5:
									// reverse video
									reverseVideo = true;
								break;
								case 6:
									// origin mode
								break;
								case 7:
									// wraparound mode
									wraparoundMode = false;
									// FIXME: wraparoundMode i think is supposed to be off by default but then bash doesn't work right so idk, this gives the best results
								break;
								case 9:
									allMouseTrackingOff();
									mouseButtonTracking = true;
								break;
								case 12:
									// start blinking cursor
								break;
								case 1034:
									// meta keys????
								break;
								case 1049:
									// Save cursor as in DECSC and use Alternate Screen Buffer, clearing it first.
									alternateScreenActive = true;
									savedCursor = cursorPosition;
									cls();
								break;
								case 1000:
									// send mouse X&Y on button press and release
									allMouseTrackingOff();
									mouseButtonTracking = true;
									mouseButtonReleaseTracking = true;
								break;
								// case 1001: // hilight tracking, this is kinda weird so i don't think i want to implement it
								case 1002:
									allMouseTrackingOff();
									mouseButtonTracking = true;
									mouseButtonReleaseTracking = true;
									mouseButtonMotionTracking = true;
									// use cell motion mouse tracking
								break;
								case 1003:
									// ALL motion is sent
									allMouseTrackingOff();
									mouseButtonTracking = true;
									mouseButtonReleaseTracking = true;
									mouseMotionTracking = true;
								break;
								case 1005:
									// enable utf-8 mouse mode
								break;
								case 1048:
									savedCursor = cursorPosition;
								break;
								case 2004:
									bracketedPasteMode = true;
								break;
								case 1047:
								case 47:
									alternateScreenActive = true;
									cls();
								break;
								case 25:
									cursorShowing = true;
								break;
								/* Extensions */
								default: assert(0, cast(string) esc);
							}
					break;
					case 'l':
					//import std.stdio; writeln("l magic ", cast(string) esc);
						if(esc[1] != '?')
						foreach(arg; getArgs())
						switch(arg) {
							case 4:
								insertMode = false;
							break;
							case 34:
								// no idea. vim inside screen sends it
							break;
							default: assert(0, cast(string) esc);
						}
						else
						foreach(arg; getArgsBase(2, null))
							switch(arg) {
								case 1:
									// normal cursor keys
									applicationCursorKeys = false;
								break;
								case 3:
									// 80 column mode
								break;
								case 4:
									// smooth scroll
								break;
								case 5:
									// normal video
									reverseVideo = false;
								break;
								case 6:
									// normal cursor mode
								break;
								case 7:
									// wraparound mode
									wraparoundMode = true;
								break;
								case 12:
									// stop blinking cursor
								break;
								case 1034:
									// meta keys????
								break;
								case 1049:
									alternateScreenActive = false;
									cursorPosition = savedCursor;
									wraparoundMode = true;
								break;
								case 9:
								case 1000:
								case 1002:
								case 1003:
									allMouseTrackingOff();
								break;
								case 1048:
									cursorPosition = savedCursor;
								break;
								case 2004:
									bracketedPasteMode = false;
								break;
								case 1047:
								case 47:
									alternateScreenActive = false;
								break;
								case 25:
									cursorShowing = false;
								break;
								default: assert(0, cast(string) esc);
							}
					break;
					case 'X':
						// erase characters
						auto count = getArgs(1)[0];
						TerminalCell plain;
						plain.ch = ' ';
						plain.attributes = currentAttributes;
						foreach(cnt; 0 .. count) {
							ASS[cursorY][cnt + cursorX] = plain;
						}
					break;
					case 'S':
						auto count = getArgs(1)[0];
						// scroll up
						scrollUp(count);
					break;
					case 'T':
						auto count = getArgs(1)[0];
						// scroll down
						scrollDown(count);
					break;
					case 'P':
						auto count = getArgs(1)[0];
						// delete characters

						foreach(cnt; 0 .. count) {
							for(int i = cursorX; i < this.screenWidth-1; i++) {
								ASS[cursorY][i] = ASS[cursorY][i + 1];
								ASS[cursorY][i].invalidated = true;
							}

							ASS[cursorY][this.screenWidth-1].ch = ' ';
							ASS[cursorY][this.screenWidth-1].invalidated = true;
						}
					break;
					case '@':
						// insert blank characters
						auto count = getArgs(1)[0];
						foreach(idx; 0 .. count) {
							for(int i = this.screenWidth - 1; i > cursorX; i--) {
								ASS[cursorY][i] = ASS[cursorY][i - 1];
								ASS[cursorY][i].invalidated = true;
							}
							ASS[cursorY][cursorX].ch = ' ';
							ASS[cursorY][cursorX].invalidated = true;
						}
					break;
					case 'c':
						// send device attributes
						// FIXME: what am i supposed to do here?
						sendToApplication("\033[>0;138;0c");
					break;
					default:
						assert(0, "" ~ cast(string) esc);
				}
			} else {
				assert(0, cast(string) esc);
			}
		}
	}
}

// These match the numbers in terminal.d, so you can just cast it back and forth
// and the names match simpledisplay.d so you can convert that automatically too
enum TerminalKey : int {
	Escape = 0x1b, /// .
	F1 = 0x70, /// .
	F2 = 0x71, /// .
	F3 = 0x72, /// .
	F4 = 0x73, /// .
	F5 = 0x74, /// .
	F6 = 0x75, /// .
	F7 = 0x76, /// .
	F8 = 0x77, /// .
	F9 = 0x78, /// .
	F10 = 0x79, /// .
	F11 = 0x7A, /// .
	F12 = 0x7B, /// .
	Left = 0x25, /// .
	Right = 0x27, /// .
	Up = 0x26, /// .
	Down = 0x28, /// .
	Insert = 0x2d, /// .
	Delete = 0x2e, /// .
	Home = 0x24, /// .
	End = 0x23, /// .
	PageUp = 0x21, /// .
	PageDown = 0x22, /// .
}

/* These match simpledisplay.d which match terminal.d, so you can just cast them */

enum MouseEventType : int {
	motion = 0,
	buttonPressed = 1,
	buttonReleased = 2,
}

enum MouseButton : int {
	// these names assume a right-handed mouse
	left = 1,
	right = 2,
	middle = 4,
	wheelUp = 8,
	wheelDown = 16,
}



/*
mixin template ImageSupport() {
	import arsd.png;
	import arsd.bmp;
}
*/


/* helper functions that are generally useful but not necessarily required */

version(Posix) {
	extern(C) static int forkpty(int* master, /*int* slave,*/ void* name, void* termp, void* winp);
	pragma(lib, "util");

	/// this is good
	void startChild(alias masterFunc)(string program, string[] args) {
		import core.sys.posix.termios;
		import core.sys.posix.signal;
		import core.sys.posix.sys.wait;
		__gshared static int childrenAlive = 0;
		extern(C) nothrow static @nogc
		void childdead(int) {
			childrenAlive--;

			try {
			import arsd.eventloop;
			if(childrenAlive == 0)
				wait(null);
				exit();
			} catch(Exception e){}
		}

		signal(SIGCHLD, &childdead);

		int master;
		int pid = forkpty(&master, null, null, null);
		if(pid == -1)
			throw new Exception("forkpty");
		if(pid == 0) {
			import std.process;
			environment["TERM"] = "xterm"; // we're closest to an xterm, so definitely want to pretend to be one to the child processes
			environment["TERM_EXTENSIONS"] = "arsd"; // announce our extensions

			environment["LANG"] = "en_US.UTF-8"; // tell them that utf8 rox (FIXME: what about non-US?)

			import core.sys.posix.unistd;

			execl("/bin/bash", "/bin/bash", null); // FIXME
		} else {
			childrenAlive = 1;
			masterFunc(master);
		}
	}
}
version(Windows) {
	import core.sys.windows.windows;

	extern(Windows)
		BOOL PeekNamedPipe(HANDLE, LPVOID, DWORD, LPDWORD, LPDWORD, LPDWORD);
	extern(Windows)
		BOOL GetOverlappedResult(HANDLE,OVERLAPPED*,LPDWORD,BOOL);
	extern(Windows)
		BOOL ReadFileEx(HANDLE, LPVOID, DWORD, OVERLAPPED*, void*);
	extern(Windows)
		BOOL PostMessageA(HWND hWnd,UINT Msg,WPARAM wParam,LPARAM lParam);

	extern(Windows)
		BOOL PostThreadMessageA(DWORD, UINT, WPARAM, LPARAM);
	extern(Windows)
		BOOL RegisterWaitForSingleObject( PHANDLE phNewWaitObject, HANDLE hObject, void* Callback, PVOID Context, ULONG dwMilliseconds, ULONG dwFlags);
	extern(Windows)
		BOOL SetHandleInformation(HANDLE, DWORD, DWORD);
	extern(Windows)
	HANDLE CreateNamedPipeA(
		LPCTSTR lpName,
		DWORD dwOpenMode,
		DWORD dwPipeMode,
		DWORD nMaxInstances,
		DWORD nOutBufferSize,
		DWORD nInBufferSize,
		DWORD nDefaultTimeOut,
		LPSECURITY_ATTRIBUTES lpSecurityAttributes
	);
	extern(Windows)
	BOOL UnregisterWait(HANDLE);

	__gshared HANDLE waitHandle;
	__gshared bool childDead;
	extern(Windows)
	void childCallback(void* tidp, bool) {
		auto tid = cast(DWORD) tidp;
		UnregisterWait(waitHandle);

		PostThreadMessageA(tid, WM_QUIT, 0, 0);
		childDead = true;
		//stupidThreadAlive = false;
	}



	extern(Windows)
	void SetLastError(DWORD);

	/// this is good. best to call it with plink.exe so it can talk to unix
	/// note that plink asks for the password out of band, so it won't actually work like that.
	/// thus specify the password on the command line or better yet, use a private key file
	/// e.g.
	/// startChild!something("plink.exe", "plink.exe user@server -i key.ppk \"/home/user/terminal-emulator/serverside\"");
	void startChild(alias masterFunc)(string program, string commandLine) {
		import core.sys.windows.windows;
		// thanks for a random person on stack overflow for this function
		static BOOL MyCreatePipeEx(
			PHANDLE lpReadPipe,
			PHANDLE lpWritePipe,
			LPSECURITY_ATTRIBUTES lpPipeAttributes,
			DWORD nSize,
			DWORD dwReadMode,
			DWORD dwWriteMode
		)
		{
			HANDLE ReadPipeHandle, WritePipeHandle;
			DWORD dwError;
			CHAR[MAX_PATH] PipeNameBuffer;

			if (nSize == 0) {
				nSize = 4096;
			}

			static int PipeSerialNumber = 0;

			import core.stdc.string;
			import core.stdc.stdio;

			sprintf(PipeNameBuffer.ptr,
				"\\\\.\\Pipe\\TerminalEmulatorPipe.%08x.%08x".ptr,
				GetCurrentProcessId(),
				PipeSerialNumber++
			);

			ReadPipeHandle = CreateNamedPipeA(
				PipeNameBuffer.ptr,
				1/*PIPE_ACCESS_INBOUND*/ | dwReadMode,
				0/*PIPE_TYPE_BYTE*/ | 0/*PIPE_WAIT*/,
				1,             // Number of pipes
				nSize,         // Out buffer size
				nSize,         // In buffer size
				120 * 1000,    // Timeout in ms
				lpPipeAttributes
			);

			if (! ReadPipeHandle) {
				return FALSE;
			}

			WritePipeHandle = CreateFileA(
				PipeNameBuffer.ptr,
				GENERIC_WRITE,
				0,                         // No sharing
				lpPipeAttributes,
				OPEN_EXISTING,
				FILE_ATTRIBUTE_NORMAL | dwWriteMode,
				null                       // Template file
			);

			if (INVALID_HANDLE_VALUE == WritePipeHandle) {
				dwError = GetLastError();
				CloseHandle( ReadPipeHandle );
				SetLastError(dwError);
				return FALSE;
			}

			*lpReadPipe = ReadPipeHandle;
			*lpWritePipe = WritePipeHandle;
			return( TRUE );
		}





		import std.conv;

		SECURITY_ATTRIBUTES saAttr;
		saAttr.nLength = SECURITY_ATTRIBUTES.sizeof;
		saAttr.bInheritHandle = true;
		saAttr.lpSecurityDescriptor = null;

		HANDLE inreadPipe;
		HANDLE inwritePipe;
		if(CreatePipe(&inreadPipe, &inwritePipe, &saAttr, 0) == 0)
			throw new Exception("CreatePipe");
		if(!SetHandleInformation(inwritePipe, 1/*HANDLE_FLAG_INHERIT*/, 0))
			throw new Exception("SetHandleInformation");
		HANDLE outreadPipe;
		HANDLE outwritePipe;
		if(MyCreatePipeEx(&outreadPipe, &outwritePipe, &saAttr, 0, FILE_FLAG_OVERLAPPED, 0) == 0)
			throw new Exception("CreatePipe");
		if(!SetHandleInformation(outreadPipe, 1/*HANDLE_FLAG_INHERIT*/, 0))
			throw new Exception("SetHandleInformation");

		STARTUPINFO startupInfo;
		startupInfo.cb = startupInfo.sizeof;

		startupInfo.dwFlags = STARTF_USESTDHANDLES;
		startupInfo.hStdInput = inreadPipe;
		startupInfo.hStdOutput = outwritePipe;
		startupInfo.hStdError = GetStdHandle(STD_ERROR_HANDLE);//outwritePipe;

		PROCESS_INFORMATION pi;
		import std.conv;

		if(commandLine.length > 255)
			throw new Exception("command line too long");
		char[256] cmdLine;
		cmdLine[0 .. commandLine.length] = commandLine[];
		cmdLine[commandLine.length] = 0;
		import std.string;
		if(CreateProcessA(program is null ? null : toStringz(program), cmdLine.ptr, null, null, true, 0/*0x08000000 /* CREATE_NO_WINDOW */, null /* environment */, null, &startupInfo, &pi) == 0)
			throw new Exception("CreateProcess " ~ to!string(GetLastError()));

		if(RegisterWaitForSingleObject(&waitHandle, pi.hProcess, &childCallback, cast(void*) GetCurrentThreadId(), INFINITE, 4 /* WT_EXECUTEINWAITTHREAD */ | 8 /* WT_EXECUTEONLYONCE */) == 0)
			throw new Exception("RegisterWaitForSingleObject");

		masterFunc(inwritePipe, outreadPipe);

		//stupidThreadAlive = false;

		//term.stupidThread.join();

		CloseHandle(inwritePipe);
		CloseHandle(outreadPipe);

		CloseHandle(pi.hThread);
		CloseHandle(pi.hProcess);
	}
}

/// Implementation of TerminalEmulator's abstract functions that forward them to output
mixin template ForwardVirtuals(alias writer) {
	static import arsd.color;

	protected override void changeCursorStyle(CursorStyle style) {
		// FIXME: this should probably just import utility
		final switch(style) {
			case TerminalEmulator.CursorStyle.block:
				writer("\033[2 q");
			break;
			case TerminalEmulator.CursorStyle.underline:
				writer("\033[4 q");
			break;
			case TerminalEmulator.CursorStyle.bar:
				writer("\033[6 q");
			break;
		}
	}

	protected override void changeWindowTitle(string t) {
		import std.process;
		if(t.length && environment["TERM"] != "linux")
			writer("\033]0;"~t~"\007");
	}

	protected override void changeWindowIcon(arsd.color.IndexedImage t) {
		if(t !is null) {
			// forward it via our extension. xterm and such seems to ignore this so we should be ok just sending
			writer("\033]5000;" ~ encodeSmallTextImage(t) ~ "\007");
		}
	}

	protected override void changeIconTitle(string) {} // FIXME
	protected override void changeTextAttributes(TextAttributes) {} // FIXME
	protected override void soundBell() {
		writer("\007");
	}
	protected override void copyToClipboard(string text) {
		// this is xterm compatible, though xterm rarely implements it
		import std.base64;
				// idk why the cast is needed here
		writer("\033]52;p;"~Base64.encode(cast(ubyte[])text)~"\007");
	}
	protected override void pasteFromClipboard(void delegate(string) dg) {
		// this is a slight extension. xterm invented the string - it means request the primary selection -
		// but it generally doesn't actually get a reply. so i'm using it to request the primary which will be
		// sent as a pasted strong.
		// (xterm prolly doesn't do it by default because it is potentially insecure, letting a naughty app steal your clipboard data, but meh, any X application can do that too and it is useful here for nesting.)
		writer("\033]52;p;?\007");
	}
}

/// you can pass this as PtySupport's arguments when you just don't care
final void doNothing() {}

/// You must implement a function called redraw() and initialize the members in your constructor
mixin template PtySupport(alias resizeHelper) {
	// Initialize these!
	version(Windows) {
		import core.sys.windows.windows;
		HANDLE stdin;
		HANDLE stdout;
	}
	version(Posix) {
		int master;
	}

	// for resizing...
	version(Windows)
		enum bool useIoctl = false;
	version(Posix)
		bool useIoctl = true;


	override void resizeTerminal(int w, int h) {
		resizeHelper();

		super.resizeTerminal(w, h);

		if(useIoctl) {
			version(Posix) {
				import core.sys.posix.sys.ioctl;
				winsize win;
				win.ws_col = cast(ushort) w;
				win.ws_row = cast(ushort) h;

				ioctl(master, TIOCSWINSZ, &win);
			} else assert(0);
		} else {
			// this is a special command that my serverside program understands- it will be interpreted as nonsense if you don't run serverside...
			sendToApplication(cast(ubyte[]) [cast(ubyte) 254, cast(ubyte) w, cast(ubyte) h]);
		}
	}

	protected override void sendToApplication(const(void)[] data) {
		version(Windows) {
			import std.conv;
			uint written;
			if(WriteFile(stdin, data.ptr, data.length, &written, null) == 0)
				throw new Exception("WriteFile " ~ to!string(GetLastError()));
		} else {
			import core.sys.posix.unistd;
			while(data.length) {
				int sent = write(master, data.ptr, data.length);
				if(sent < 0)
					throw new Exception("write");
				data = data[sent .. $];
			}
		}
	}

	version(Windows) {
		OVERLAPPED* overlapped;
		bool overlappedBufferLocked;
		ubyte[4096] overlappedBuffer;
		extern(Windows)
		static final void readyToReadWindows(DWORD errorCode, DWORD numberOfBytes, OVERLAPPED* overlapped) {
			assert(overlapped !is null);
			typeof(this) w = cast(typeof(this)) overlapped.hEvent;

			if(numberOfBytes) {
				w.sendRawInput(w.overlappedBuffer[0 .. numberOfBytes]);
				w.redraw();
			}
			import std.conv;

			if(ReadFileEx(w.stdout, w.overlappedBuffer.ptr, w.overlappedBuffer.length, overlapped, &readyToReadWindows) == 0) {
				if(GetLastError() == 997)
				{ } // there's pending i/o, let's just ignore for now and it should tell us later that it completed
				else
				throw new Exception("ReadFileEx " ~ to!string(GetLastError()));
			} else {
			}
		}
	}
	version(Posix) {
		void readyToRead(int fd) {
			import core.sys.posix.unistd;
			ubyte[4096] buffer;
			int len = read(fd, buffer.ptr, 4096);
			if(len < 0)
				throw new Exception("read failed");

			auto data = buffer[0 .. len];

			if(debugMode) {
				import std.array; import std.stdio; writeln("GOT ", data, "\nOR ", 
					replace(cast(string) data, "\033", "\\")
					.replace("\010", "^H")
					.replace("\r", "^M")
					.replace("\n", "^J")
					);
			}
			super.sendRawInput(data);

			redraw();
		}
	}
}

string encodeSmallTextImage(IndexedImage ii) {
	char encodeNumeric(int c) {
		if(c < 10)
			return cast(char)(c + '0');
		if(c < 10 + 26)
			return cast(char)(c - 10 + 'a');
		assert(0);
	}

	string s;
	s ~= encodeNumeric(ii.width);
	s ~= encodeNumeric(ii.height);

	foreach(entry; ii.palette)
		s ~= entry.toRgbaHexString();
	s ~= "Z";

	ubyte rleByte;
	int rleCount;

	void rleCommit() {
		if(rleByte >= 26)
			assert(0); // too many colors for us to handle
		if(rleCount == 0)
			goto finish;
		if(rleCount == 1) {
			s ~= rleByte + 'a';
			goto finish;
		}

		import std.conv;
		s ~= to!string(rleCount);
		s ~= rleByte + 'a';

		finish:
			rleByte = 0;
			rleCount = 0;
	}

	foreach(b; ii.data) {
		if(b == rleByte)
			rleCount++;
		else {
			rleCommit();
			rleByte = b;
			rleCount = 1;
		}
	}

	rleCommit();

	return s;
}

IndexedImage readSmallTextImage(string arg) {
	auto origArg = arg;
	int width;
	int height;

	int readNumeric(char c) {
		if(c >= '0' && c <= '9')
			return c - '0';
		if(c >= 'a' && c <= 'z')
			return c - 'a' + 10;
		return 0;
	}

	if(arg.length > 2) {
		width = readNumeric(arg[0]);
		height = readNumeric(arg[1]);
		arg = arg[2 .. $];
	}

	import std.conv;
	assert(width == 16, to!string(width));
	assert(height == 16, to!string(width));

	Color[] palette;
	ubyte[256] data;
	int didx = 0;
	bool readingPalette = true;
	outer: while(arg.length) {
		if(readingPalette) {
			if(arg[0] == 'Z') {
				readingPalette = false;
				continue;
			}
			if(arg.length < 8)
				break;
			foreach(a; arg[0..8]) {
				// if not strict hex, forget it
				if(!((a >= '0' && a <= '9') || (a >= 'a' && a <= 'z') || (a >= 'A' && a <= 'Z')))
					break outer;
			}
			palette ~= Color.fromString(arg[0 .. 8]);
			arg = arg[8 .. $];
		} else {
			char[3] rleChars;
			int rlePos;
			while(arg.length && arg[0] >= '0' && arg[0] <= '9') {
				rleChars[rlePos] = arg[0];
				arg = arg[1 .. $];
				rlePos++;
				if(rlePos >= rleChars.length)
					break;
			}
			if(arg.length == 0)
				break;

			int rle;
			if(rlePos == 0)
				rle = 1;
			else {
				// 100
				// rleChars[0] == '1'
				foreach(c; rleChars[0 .. rlePos]) {
					rle *= 10;
					rle += c - '0';
				}
			}

			foreach(i; 0 .. rle) {
				if(arg[0] >= 'a' && arg[0] <= 'z')
					data[didx] = cast(ubyte)(arg[0] - 'a');

				didx++;
				if(didx == data.length)
					break outer;
			}

			arg = arg[1 .. $];
		}
	}

	// width, height, palette, data is set up now

	if(palette.length) {
		auto ii = new IndexedImage(width, height);
		ii.palette = palette;
		ii.data = data.dup;
		return ii;
	}// else assert(0, origArg);
	return null;
}


// workaround dmd bug fixed in next release
//static immutable Color[256] xtermPalette = [
Color[] xtermPalette() { return [
	Color(0, 0, 0),
	Color(0xcd, 0, 0),
	Color(0, 0xcd, 0),
	Color(0xcd, 0xcd, 0),
	Color(0, 0, 0xee),
	Color(0xcd, 0, 0xcd),
	Color(0, 0xcd, 0xcd),
	Color(229, 229, 229),
	Color(127, 127, 127),
	Color(255, 0, 0),
	Color(0, 255, 0),
	Color(255, 255, 0),
	Color(92, 92, 255),
	Color(255, 0, 255),
	Color(0, 255, 255),
	Color(255, 255, 255),
	Color(0, 0, 0),
	Color(0, 0, 95),
	Color(0, 0, 135),
	Color(0, 0, 175),
	Color(0, 0, 215),
	Color(0, 0, 255),
	Color(0, 95, 0),
	Color(0, 95, 95),
	Color(0, 95, 135),
	Color(0, 95, 175),
	Color(0, 95, 215),
	Color(0, 95, 255),
	Color(0, 135, 0),
	Color(0, 135, 95),
	Color(0, 135, 135),
	Color(0, 135, 175),
	Color(0, 135, 215),
	Color(0, 135, 255),
	Color(0, 175, 0),
	Color(0, 175, 95),
	Color(0, 175, 135),
	Color(0, 175, 175),
	Color(0, 175, 215),
	Color(0, 175, 255),
	Color(0, 215, 0),
	Color(0, 215, 95),
	Color(0, 215, 135),
	Color(0, 215, 175),
	Color(0, 215, 215),
	Color(0, 215, 255),
	Color(0, 255, 0),
	Color(0, 255, 95),
	Color(0, 255, 135),
	Color(0, 255, 175),
	Color(0, 255, 215),
	Color(0, 255, 255),
	Color(95, 0, 0),
	Color(95, 0, 95),
	Color(95, 0, 135),
	Color(95, 0, 175),
	Color(95, 0, 215),
	Color(95, 0, 255),
	Color(95, 95, 0),
	Color(95, 95, 95),
	Color(95, 95, 135),
	Color(95, 95, 175),
	Color(95, 95, 215),
	Color(95, 95, 255),
	Color(95, 135, 0),
	Color(95, 135, 95),
	Color(95, 135, 135),
	Color(95, 135, 175),
	Color(95, 135, 215),
	Color(95, 135, 255),
	Color(95, 175, 0),
	Color(95, 175, 95),
	Color(95, 175, 135),
	Color(95, 175, 175),
	Color(95, 175, 215),
	Color(95, 175, 255),
	Color(95, 215, 0),
	Color(95, 215, 95),
	Color(95, 215, 135),
	Color(95, 215, 175),
	Color(95, 215, 215),
	Color(95, 215, 255),
	Color(95, 255, 0),
	Color(95, 255, 95),
	Color(95, 255, 135),
	Color(95, 255, 175),
	Color(95, 255, 215),
	Color(95, 255, 255),
	Color(135, 0, 0),
	Color(135, 0, 95),
	Color(135, 0, 135),
	Color(135, 0, 175),
	Color(135, 0, 215),
	Color(135, 0, 255),
	Color(135, 95, 0),
	Color(135, 95, 95),
	Color(135, 95, 135),
	Color(135, 95, 175),
	Color(135, 95, 215),
	Color(135, 95, 255),
	Color(135, 135, 0),
	Color(135, 135, 95),
	Color(135, 135, 135),
	Color(135, 135, 175),
	Color(135, 135, 215),
	Color(135, 135, 255),
	Color(135, 175, 0),
	Color(135, 175, 95),
	Color(135, 175, 135),
	Color(135, 175, 175),
	Color(135, 175, 215),
	Color(135, 175, 255),
	Color(135, 215, 0),
	Color(135, 215, 95),
	Color(135, 215, 135),
	Color(135, 215, 175),
	Color(135, 215, 215),
	Color(135, 215, 255),
	Color(135, 255, 0),
	Color(135, 255, 95),
	Color(135, 255, 135),
	Color(135, 255, 175),
	Color(135, 255, 215),
	Color(135, 255, 255),
	Color(175, 0, 0),
	Color(175, 0, 95),
	Color(175, 0, 135),
	Color(175, 0, 175),
	Color(175, 0, 215),
	Color(175, 0, 255),
	Color(175, 95, 0),
	Color(175, 95, 95),
	Color(175, 95, 135),
	Color(175, 95, 175),
	Color(175, 95, 215),
	Color(175, 95, 255),
	Color(175, 135, 0),
	Color(175, 135, 95),
	Color(175, 135, 135),
	Color(175, 135, 175),
	Color(175, 135, 215),
	Color(175, 135, 255),
	Color(175, 175, 0),
	Color(175, 175, 95),
	Color(175, 175, 135),
	Color(175, 175, 175),
	Color(175, 175, 215),
	Color(175, 175, 255),
	Color(175, 215, 0),
	Color(175, 215, 95),
	Color(175, 215, 135),
	Color(175, 215, 175),
	Color(175, 215, 215),
	Color(175, 215, 255),
	Color(175, 255, 0),
	Color(175, 255, 95),
	Color(175, 255, 135),
	Color(175, 255, 175),
	Color(175, 255, 215),
	Color(175, 255, 255),
	Color(215, 0, 0),
	Color(215, 0, 95),
	Color(215, 0, 135),
	Color(215, 0, 175),
	Color(215, 0, 215),
	Color(215, 0, 255),
	Color(215, 95, 0),
	Color(215, 95, 95),
	Color(215, 95, 135),
	Color(215, 95, 175),
	Color(215, 95, 215),
	Color(215, 95, 255),
	Color(215, 135, 0),
	Color(215, 135, 95),
	Color(215, 135, 135),
	Color(215, 135, 175),
	Color(215, 135, 215),
	Color(215, 135, 255),
	Color(215, 175, 0),
	Color(215, 175, 95),
	Color(215, 175, 135),
	Color(215, 175, 175),
	Color(215, 175, 215),
	Color(215, 175, 255),
	Color(215, 215, 0),
	Color(215, 215, 95),
	Color(215, 215, 135),
	Color(215, 215, 175),
	Color(215, 215, 215),
	Color(215, 215, 255),
	Color(215, 255, 0),
	Color(215, 255, 95),
	Color(215, 255, 135),
	Color(215, 255, 175),
	Color(215, 255, 215),
	Color(215, 255, 255),
	Color(255, 0, 0),
	Color(255, 0, 95),
	Color(255, 0, 135),
	Color(255, 0, 175),
	Color(255, 0, 215),
	Color(255, 0, 255),
	Color(255, 95, 0),
	Color(255, 95, 95),
	Color(255, 95, 135),
	Color(255, 95, 175),
	Color(255, 95, 215),
	Color(255, 95, 255),
	Color(255, 135, 0),
	Color(255, 135, 95),
	Color(255, 135, 135),
	Color(255, 135, 175),
	Color(255, 135, 215),
	Color(255, 135, 255),
	Color(255, 175, 0),
	Color(255, 175, 95),
	Color(255, 175, 135),
	Color(255, 175, 175),
	Color(255, 175, 215),
	Color(255, 175, 255),
	Color(255, 215, 0),
	Color(255, 215, 95),
	Color(255, 215, 135),
	Color(255, 215, 175),
	Color(255, 215, 215),
	Color(255, 215, 255),
	Color(255, 255, 0),
	Color(255, 255, 95),
	Color(255, 255, 135),
	Color(255, 255, 175),
	Color(255, 255, 215),
	Color(255, 255, 255),
	Color(8, 8, 8),
	Color(18, 18, 18),
	Color(28, 28, 28),
	Color(38, 38, 38),
	Color(48, 48, 48),
	Color(58, 58, 58),
	Color(68, 68, 68),
	Color(78, 78, 78),
	Color(88, 88, 88),
	Color(98, 98, 98),
	Color(98, 98, 98),
	Color(118, 118, 118),
	Color(128, 128, 128),
	Color(138, 138, 138),
	Color(148, 148, 148),
	Color(158, 158, 158),
	Color(168, 168, 168),
	Color(178, 178, 178),
	Color(188, 188, 188),
	Color(198, 198, 198),
	Color(208, 208, 208),
	Color(218, 218, 218),
	Color(228, 228, 228),
	Color(238, 238, 238),
];
}

static shared immutable dchar[dchar] lineDrawingCharacterSet;
shared static this() {
	lineDrawingCharacterSet = [
		'a' : ':',
		'j' : '+',
		'k' : '+',
		'l' : '+',
		'm' : '+',
		'n' : '+',
		'q' : '-',
		't' : '+',
		'u' : '+',
		'v' : '+',
		'w' : '+',
		'x' : '|',
	];

	// this is what they SHOULD be but the font i use doesn't support all these
	// the ascii fallback above looks pretty good anyway though.
	version(none)
	lineDrawingCharacterSet = [
		'a' : '\u2592',
		'j' : '\u2518',
		'k' : '\u2510',
		'l' : '\u250c',
		'm' : '\u2514',
		'n' : '\u253c',
		'q' : '\u2500',
		't' : '\u251c',
		'u' : '\u2524',
		'v' : '\u2534',
		'w' : '\u252c',
		'x' : '\u2502',
	];
}
