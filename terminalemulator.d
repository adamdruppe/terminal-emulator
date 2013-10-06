/**
	This is an extendible unix terminal emulator and some helper functions to help actually implement one.

	You'll have to subclass TerminalEmulator and implement the abstract functions as well as write a drawing function for it.

	See nestedterminalemulator.d or main.d for how I did it.
*/
module arsd.terminalemulator;

import arsd.color;

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
	protected abstract void changeTextAttributes(TextAttributes); /// current text output attributes
	protected abstract void soundBell(); /// sounds the bell
	protected abstract void sendToApplication(const(void)[]); /// send some data to the information

	// I believe \033[50~ and up are available for extensions everywhere.
	// when keys are shifted, xterm sends them as \033[1;2F for example with end. but is this even sane? how would we do it with say, F5?
	// apparently shifted F5 is ^[[15;2~
	// alt + f5 is ^[[15;3~
	// alt+shift+f5 is ^[[15;4~

	/// Send a non-character key sequence
	public void sendKeyToApplication(TerminalKey key, bool shift = false, bool alt = false, bool ctrl = false, bool windows = false) {
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
	}

	/// if a binary extension is triggered, the implementing class is responsible for figuring out how it should be made to fit into the screen buffer
	protected /*abstract*/ BrokenUpImage handleBinaryExtensionData(const(ubyte)[]) {
		return BrokenUpImage();
	}

	bool newlineHack; // not sure what's up with this but it helps get around gnu screen bugs
		// maybe \n should always just advance, so \r\n is how you go ahead. i don't know though that seems wrong on unix

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

		ta.foreground = Color.black;
		ta.background = Color.white;
		return ta;
	}

	/// .
	struct TextAttributes {
		bool bold; /// .
		bool blink; /// .
		bool invisible; /// .
		bool inverse; /// .
		bool underlined; /// .

		bool italic; /// .
		bool strikeout; /// .

		// these are just hacks for the nested emulator and may be removed
		ushort foregroundIndex;
		ushort backgroundIndex;

		// maybe these should be indexes into the palette...
		Color foreground; /// .
		Color background; /// .
	}

	/// represents one terminal cell
	struct TerminalCell {
		dchar ch = ' '; /// the character
		NonCharacterData nonCharacterData; /// iff ch == dchar.init. may still be null, in which case this cell should not be drawn at all.

		TextAttributes attributes; /// color, etc.
		bool invalidated = true; /// if it needs to be redrawn
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

	bool readingExtensionData;
	string extensionData;

	bool readingEsc = false;
	ubyte[] esc;
	/// sends raw input data to the terminal as if the user typed it or whatever
	void sendRawInput(in ubyte[] data) {
	//import std.array;
	//assert(!readingEsc, replace(cast(string) esc, "\033", "\\"));
		foreach(b; data) {
			if(readingExtensionData) {
				if(b) {
					if(b != 13 && b != 10)
						extensionData ~= b;
				} else {
					readingExtensionData = false;
					import std.base64;
					auto got = handleBinaryExtensionData(Base64.decode(extensionData));

					auto rep = got.representation;
					foreach(y; 0 .. got.height) {
						foreach(x; 0 .. got.width) {
							addOutput(rep[0]);
							rep = rep[1 .. $];
						}
						addOutput(10);
					}
				}

				continue;
			}

			if(b == 0) {
				readingExtensionData = true;
				extensionData = null;
				continue;
			}

			if(readingEsc) {
				esc ~= b;

				if(esc.length == 1 && esc[0] == '7') {
					savedCursor = cursorPosition;
					esc = null;
					readingEsc = false;
				} else if(esc.length == 1 && esc[0] == 'M') {
					// reverse index
					esc = null;
					readingEsc = false;
					if(cursorY == 0)
						scrollDown();
					else
						cursorY = cursorY - 1;
				} else if(esc.length == 1 && esc[0] == '=') {
					// application keypad
					esc = null;
					readingEsc = false;
				} else if(esc.length == 1 && esc[0] == '8') {
					cursorPosition = savedCursor;
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

		resizeTerminal(width, height);

		// update the other thing
		changeWindowTitle(windowTitle);
		changeIconTitle(iconTitle);
		changeTextAttributes(currentAttributes);
	}


	private {
		TerminalCell[] scrollbackMainScreen;
		bool scrollbackCursorShowing;
		int scrollbackCursorX;
		int scrollbackCursorY;
		bool scrollingBack;

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

		bool bracketedPasteMode;
		bool mouseButtonTracking;
		bool mouseMotionTracking;
		bool mouseButtonReleaseTracking;
		bool mouseHighlightTracking;

		void allMouseTrackingOff() {
			mouseMotionTracking = false;
			mouseButtonTracking = false;
			mouseButtonReleaseTracking = false;
			mouseHighlightTracking = false;
		}

		bool wraparoundMode = true;

		bool alternateScreenActive;
		bool cursorShowing = true;

		bool reverseVideo;
		bool applicationCursorKeys;

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
		//bool newLineOnNext;
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
				import std.string;
				assert((b & 0b11000000) == 0b10000000, format("invalid utf 8 sequence on input %b",utf8Sequence));
				uint shifted = b;
				shifted &= 0b00111111;
				shifted <<= currentUtf8Shift;
				utf8Sequence |= shifted;
			}

			if(utf8BytesRemaining)
				return; // not enough data yet, wait for more before displaying anything

			if(utf8Sequence == 10) {
				auto cx = cursorX; // FIXME: this cx thing is a hack, newLine should prolly just do the right thing
				newLine(true);
				cursorX = cx;
			} else {
				//if(newLineOnNext)
					//newLine();
				//newLineOnNext = false;
				TerminalCell tc;
				tc.ch = utf8Sequence;
				tc.attributes = currentAttributes;
				tc.invalidated = true;

				addOutput(tc);
			}
		}

		void newLine(bool commitScrollback) {
			if(!alternateScreenActive && commitScrollback) {
				scrollbackBuffer ~= currentScrollbackLine.dup;
				currentScrollbackLine = null;
				scrollbackWrappingAt = 0;
			}

			cursorX = 0;
			if(cursorY == scrollZoneBottom) {
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
			if((!newlineHack) && cursorX == screenWidth - 1) {
				//newLineOnNext = true;
				newLine(false);
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

			if(esc[0] == ']' && esc.length > 1) {
				auto arg = cast(string) esc[3 .. $-1];
				switch(cast(string) esc[1..3]) {
					case "0;":
						// icon name and window title
						windowTitle = iconTitle = arg;
						changeWindowTitle(windowTitle);
						changeIconTitle(iconTitle);
					break;
					case "1;":
						// icon name
						iconTitle = arg;
						changeIconTitle(iconTitle);
					break;
					case "2;":
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
					default:
						assert(0, "" ~ cast(char) esc[1]);
				}
			} else if(esc[0] == '[' && esc.length > 1) {
				switch(esc[$-1]) {
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
					break;
					case 'm':
						foreach(arg; getArgs(0))
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
								Color nc;
								ubyte multiplier = currentAttributes.bold ? 255 : 127;
								nc.r = cast(ubyte)((arg - 30) & 1) * multiplier;
								nc.g = cast(ubyte)(((arg - 30) & 2)>>1) * multiplier;
								nc.b = cast(ubyte)(((arg - 30) & 4)>>2) * multiplier;
								nc.a = 255;
								currentAttributes.foregroundIndex = cast(ubyte)(arg - 30);
								currentAttributes.foreground = nc;
							break;
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
								Color nc;
								nc.r = cast(ubyte)((arg - 40) & 1) * 255;
								nc.g = cast(ubyte)(((arg - 40) & 2)>>1) * 255;
								nc.b = cast(ubyte)(((arg - 40) & 4)>>2) * 255;
								nc.a = 255;

								currentAttributes.backgroundIndex = cast(ubyte)(arg - 40);
								currentAttributes.background = nc;
							break;
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
								case 1002:
									allMouseTrackingOff();
									mouseButtonTracking = true;
									mouseButtonReleaseTracking = true;
									mouseHighlightTracking = true;
									// motion should only be sent upon release...
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
								break;
								case 25:
									cursorShowing = true;
								break;
								default: assert(0, cast(string) esc);
							}
					break;
					case 'l':
					//import std.stdio; writeln("l magic ", cast(string) esc);
						if(esc[1] != '?')
						foreach(arg; getArgs())
						switch(arg) {
							case 4:
								// insert mode
								// I think this has to change the newline function
								newlineHack = true;
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
		__gshared static int childrenAlive = 0;
		extern(C) nothrow static
		void childdead(int) {
			childrenAlive--;

			try {
			import arsd.eventloop;
			if(childrenAlive == 0)
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
			environment["TERM_EXTENSIONS"] = "arsd"; // we're closest to an xterm, so definitely want to pretend to be one to the child processes

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


	override void resizeTerminal(int w, int h) {
		resizeHelper();

		super.resizeTerminal(w, h);

		version(Posix) {
			import core.sys.posix.termios;
			winsize win;
			win.ws_col = cast(ushort) w;
			win.ws_row = cast(ushort) h;

			import core.sys.posix.sys.ioctl;
			ioctl(master, TIOCSWINSZ, &win);
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
					);
			}
			super.sendRawInput(data);

			redraw();
		}
	}
}
